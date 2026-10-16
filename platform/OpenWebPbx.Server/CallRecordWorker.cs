using System.Diagnostics;

namespace OpenWebPbx.Server;

// The native spool survives service restarts. The importer retains a file until its database work succeeds.
public sealed class CallRecordWorker(IConfiguration settings, ILogger<CallRecordWorker> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
        do
        {
            try { await Tick(ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogWarning("Call-record import will retry ({ErrorType}).", ex.GetType().Name); }
        } while (await timer.WaitForNextTickAsync(ct));
    }

    public async Task Tick(CancellationToken ct)
    {
        var web = settings["CallRecords:WebRoot"] ?? (OperatingSystem.IsWindows() ? @"C:\OpenWebPBX\Web" : "/var/www/fusionpbx");
        var php = settings["CallRecords:Php"] ?? (OperatingSystem.IsWindows() ? @"C:\OpenWebPBX\php\php.exe" : "/usr/bin/php");
        var script = Path.Combine(web, "app", "pbx_setup", "call_records.php");
        if (!File.Exists(php) || !File.Exists(script)) throw new IOException("Call-record importer is unavailable.");
        using var process = new Process { StartInfo = new ProcessStartInfo(php) { UseShellExecute = false, CreateNoWindow = true,
            WorkingDirectory = web, RedirectStandardOutput = true, RedirectStandardError = true } };
        process.StartInfo.ArgumentList.Add(script);
        if (!process.Start()) throw new IOException("Call-record importer could not start.");
        // Drain without retaining/logging record contents or unbounded legacy PHP diagnostics.
        static async Task Drain(StreamReader reader) { var buffer = new char[2048]; while (await reader.ReadAsync(buffer) > 0) { } }
        var stdout = Drain(process.StandardOutput); var stderr = Drain(process.StandardError);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(45));
        try { await process.WaitForExitAsync(timeout.Token); }
        finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None); } await Task.WhenAll(stdout, stderr); }
        if (process.ExitCode != 0) throw new IOException("Call-record importer retained unfinished work.");
    }
}
