namespace OpenWebPbx.Server;

// Windows maintenance uses the same native sharing lock as setup, restore and
// upgrades. The dedicated hold survives a controller crash; it contains no
// database credentials and only the privileged maintenance helpers remove it.
public static class WindowsCallRecordLease
{
    public static FileStream? TryAcquire(string stateRoot)
    {
        var root = Path.GetFullPath(stateRoot);
        for (var path = root; path is not null; path = Path.GetDirectoryName(path))
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Call-record maintenance paths must be ordinary directories.");
        }
        var lockPath = Path.Combine(root, "upgrade.lock");
        if ((File.GetAttributes(lockPath) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
            throw new IOException("The call-record maintenance lock is unavailable.");
        FileStream lease;
        try { lease = new FileStream(lockPath, FileMode.Open, FileAccess.Read, FileShare.Read); }
        catch (IOException error) when (OperatingSystem.IsWindows() && (error.HResult & 0xffff) is 32 or 33)
        { return null; }
        try
        {
            try
            {
                _ = File.GetAttributes(Path.Combine(root, "call-records.hold"));
                lease.Dispose();
                return null;
            }
            catch (FileNotFoundException) { }
            // The state root was already verified and remains protected. A
            // different I/O/permission error is not evidence of an absent hold.
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }
}
