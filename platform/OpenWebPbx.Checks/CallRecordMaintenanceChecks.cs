using OpenWebPbx.Server;

internal static class CallRecordMaintenanceChecks
{
    internal static int Run()
    {
        if (!OperatingSystem.IsWindows()) return 0;
        var root = Path.Combine(Path.GetTempPath(), "openweb-cdr-lease-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var checks = 0;
        void Check(bool condition) { if (!condition) throw new Exception("Call-record maintenance control failed."); checks++; }
        void Refuse(Action action) { var refused = false; try { action(); } catch (IOException) { refused = true; } Check(refused); }
        var mutex = Path.Combine(root, "upgrade.lock");
        var hold = Path.Combine(root, "call-records.hold");
        try
        {
            Refuse(() => WindowsCallRecordLease.TryAcquire(root)?.Dispose());
            File.WriteAllBytes(mutex, []);
            using (var lease = WindowsCallRecordLease.TryAcquire(root))
            {
                Check(lease is not null);
                Refuse(() => { using var writer = new FileStream(mutex, FileMode.Open, FileAccess.ReadWrite, FileShare.None); });
            }
            using (var writer = new FileStream(mutex, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                Check(WindowsCallRecordLease.TryAcquire(root) is null);
            File.WriteAllText(hold, "maintenance");
            Check(WindowsCallRecordLease.TryAcquire(root) is null);
            // A malformed marker and a directory both keep maintenance in
            // place; neither is treated as an activation instruction.
            File.WriteAllBytes(hold, [0, 255, 0]);
            Check(WindowsCallRecordLease.TryAcquire(root) is null);
            File.Delete(hold);
            Directory.CreateDirectory(hold);
            Check(WindowsCallRecordLease.TryAcquire(root) is null);
            Directory.Delete(hold);
            using (var lease = WindowsCallRecordLease.TryAcquire(root)) Check(lease is not null);
            // Releasing a deferred reader must leave the privileged writer
            // able to acquire the actual lock for recovery.
            File.WriteAllText(hold, "maintenance");
            Check(WindowsCallRecordLease.TryAcquire(root) is null);
            using (var writer = new FileStream(mutex, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) Check(writer.CanWrite);
            File.Delete(hold);
            File.Delete(mutex);
            Directory.CreateDirectory(mutex);
            Refuse(() => WindowsCallRecordLease.TryAcquire(root)?.Dispose());
            Directory.Delete(mutex);
            Refuse(() => WindowsCallRecordLease.TryAcquire(root)?.Dispose());
            Check(Directory.GetFileSystemEntries(root).Length == 0);
            return checks;
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
