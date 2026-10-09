using System.Diagnostics;
using System.Text.Json;

namespace OpenWebPbx.Updater;

public sealed class PlatformInstaller(UpdaterPaths paths)
{
    public async Task<int> Run(string? archive, string? feed, string? version, bool check, bool recover, CancellationToken ct, bool automatic = false)
    {
        if (!File.Exists(paths.Helper)) throw new FileNotFoundException("The installed update helper is unavailable.");
        var start = new ProcessStartInfo(OperatingSystem.IsWindows() ? "powershell.exe" : "/usr/bin/python3")
        { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        if (OperatingSystem.IsWindows())
        {
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", paths.Helper }) start.ArgumentList.Add(argument);
            if (recover) start.ArgumentList.Add("-Recover");
            else
            {
                foreach (var argument in new[] { "-Archive", archive!, "-FeedEnvelope", feed!, "-TargetVersion", version! }) start.ArgumentList.Add(argument);
                if (check) start.ArgumentList.Add("-Check");
                if (automatic) start.ArgumentList.Add("-Automatic");
            }
        }
        else
        {
            start.ArgumentList.Add(paths.Helper);
            if (recover) start.ArgumentList.Add("--recover");
            else
            {
                foreach (var argument in new[] { "--archive", archive!, "--feed-envelope", feed!, "--target-version", version! }) start.ArgumentList.Add(argument);
                if (check) start.ArgumentList.Add("--check");
                if (automatic) start.ArgumentList.Add("--automatic");
            }
        }
        var logPath = Path.Combine(paths.Data, "logs", "install-" + DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".log");
        await using var log = new FileStream(logPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        using var process = Process.Start(start) ?? throw new IOException("The update helper could not start.");
        using var gate = new SemaphoreSlim(1, 1);
        async Task Drain(StreamReader reader)
        {
            var chars = new char[4096];
            while (true)
            {
                var count = await reader.ReadAsync(chars); if (count == 0) return;
                await gate.WaitAsync();
                try { if (log.Length < 16 * 1024 * 1024) await log.WriteAsync(System.Text.Encoding.UTF8.GetBytes(chars.AsSpan(0, count).ToString())); }
                finally { gate.Release(); }
            }
        }
        // Once a transaction starts, cancellation must not kill its backup/rollback.
        // The helper's durable journal and boot recovery own interrupted transactions.
        await Task.WhenAll(Drain(process.StandardOutput), Drain(process.StandardError), process.WaitForExitAsync());
        await log.FlushAsync(CancellationToken.None); return process.ExitCode;
    }
    public string? JournalState()
    {
        if (!File.Exists(paths.InstallJournal)) return null;
        using var json = JsonDocument.Parse(UpdateJson.ReadBytes(paths.InstallJournal, 262144));
        return json.RootElement.GetProperty("state").GetString();
    }
    public void RestartUpdater()
    {
        if (!OperatingSystem.IsWindows()) { Environment.Exit(0); return; }
        var start = new ProcessStartInfo("schtasks.exe") { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "/Run", "/TN", "OpenWebPBX-Updater-Restart" }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("The updater restart task is unavailable.");
        process.WaitForExit(); if (process.ExitCode != 0) throw new IOException("The updater restart task did not start.");
    }
}
