// SPDX-License-Identifier: AGPL-3.0-or-later
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace OpenWebPbx.PackageAudit;

public sealed record ReaderResult(int ExitCode, string Stdout, string Stderr);

public static class NativeImportProcess
{
    private static async Task<string> ReadBounded(Stream stream, int limit, CancellationToken token)
    {
        byte[] bytes = new byte[limit + 1];
        int used = 0;
        while (true)
        {
            int count = await stream.ReadAsync(bytes.AsMemory(used, bytes.Length - used), token).ConfigureAwait(false);
            used += count;
            if (used > limit) throw new InvalidDataException("Native import output exceeds its fixed bound.");
            if (count == 0) return new UTF8Encoding(false, true).GetString(bytes, 0, used);
        }
    }

    // Shared with the process finally below; preserve the actual original exception object.
    public static void Complete(Exception primary, Action cleanup)
    {
        try { cleanup(); }
        catch (Exception cleanupFailure)
        {
            if (primary == null) throw;
            try
            {
                primary.Data["reader_cleanup_error_type"] = cleanupFailure.GetType().Name;
                primary.Data["reader_cleanup_hresult"] = cleanupFailure.HResult;
            }
            catch { /* Diagnostic attachment cannot replace the original failure. */ }
        }
        if (primary != null) ExceptionDispatchInfo.Capture(primary).Throw();
    }

    public static ReaderResult Run(string executable, string[] arguments, string directory, int seconds)
    {
        if (seconds < 1 || seconds > 15) throw new ArgumentOutOfRangeException(nameof(seconds));
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        start.Environment["VSLANG"] = "1033";
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        using var child = Process.Start(start) ?? throw new InvalidOperationException("Reader process did not start.");
        DateTime created = child.StartTime.ToUniversalTime();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        Task<string> stdout = ReadBounded(child.StandardOutput.BaseStream, 4 * 1024 * 1024, deadline.Token);
        Task<string> stderr = ReadBounded(child.StandardError.BaseStream, 64 * 1024, deadline.Token);
        Exception primary = null;
        ReaderResult result = null;
        try
        {
            while (!child.WaitForExit(20))
            {
                if (stdout.IsFaulted) stdout.GetAwaiter().GetResult();
                if (stderr.IsFaulted) stderr.GetAwaiter().GetResult();
                deadline.Token.ThrowIfCancellationRequested();
            }
            result = new ReaderResult(child.ExitCode, stdout.GetAwaiter().GetResult(), stderr.GetAwaiter().GetResult());
        }
        catch (Exception error) { primary = error; }
        Complete(primary, () =>
        {
            deadline.Cancel();
            if (!child.HasExited)
            {
                if (child.StartTime.ToUniversalTime() != created || !string.Equals(child.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Refuse a foreign dependency reader.");
                child.Kill(true);
                if (!child.WaitForExit(10000)) throw new TimeoutException("The owned dependency reader remains.");
            }
            // Cancellation stops the owned pipe reads even if a child descendant retained a handle.
            try { Task.WhenAll(stdout, stderr).Wait(1000); }
            catch (AggregateException) { /* The original output/cancellation error is retained above. */ }
            if (!stdout.IsCompleted || !stderr.IsCompleted) throw new TimeoutException("The owned reader pipe did not close.");
        });
        return result;
    }
}
