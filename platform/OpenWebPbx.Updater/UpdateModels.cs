using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenWebPbx.Updater;

public sealed record ReleaseAsset(string Platform, string Name, string Url, long Bytes, string Sha256, string MinimumVersion);
public sealed record VerifiedRelease(string Version, long Sequence, string PayloadSha256, DateTimeOffset PublishedAt, DateTimeOffset ExpiresAt, ReleaseAsset Asset);
public sealed record TrustState(long Sequence, string PayloadSha256);
public sealed record FailedInstall(string Version, string AssetSha256);
public sealed record UpdatePolicy(string Mode, int MaintenanceHour, int MaintenanceDuration);
public sealed record UpdateCommand(Guid Id, string Action, DateTimeOffset CreatedAt = default);
public sealed record WorkerJournal(Guid? CommandId, string? Action, string? TargetVersion, string State, DateTimeOffset UpdatedAt, string? AssetSha256 = null);
public sealed record UpdateStatus(string State, string Message, string InstalledVersion, string? AvailableVersion = null,
    long ProgressBytes = 0, long TotalBytes = 0, DateTimeOffset? CheckedAt = null, string? LastSuccessVersion = null);

public static partial class UpdateJson
{
    public static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, PropertyNameCaseInsensitive = false };
    public static T Read<T>(string file, int limit = 262144) => JsonSerializer.Deserialize<T>(ReadBytes(file, limit), Options) ?? throw new InvalidDataException("Update state is incomplete.");
    public static byte[] ReadBytes(string file, int limit)
    {
        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > limit) throw new InvalidDataException("Update metadata exceeds its limit.");
        var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes); return bytes;
    }
    public static void Write<T>(string file, T value)
        => WriteBytes(file, JsonSerializer.SerializeToUtf8Bytes(value, Options));
    public static void WriteBytes(string file, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        var temp = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { stream.Write(bytes); stream.Flush(flushToDisk: true); }
            if (OperatingSystem.IsWindows()) {
                if (!MoveFileEx(temp, file, 0x1 | 0x8)) throw new IOException("Update state could not be committed.", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
            } else {
                File.Move(temp, file, overwrite: true);
                var directory = Open(Path.GetDirectoryName(file)!, 0x10000); // Linux O_DIRECTORY
                if (directory < 0) throw new IOException("Update state directory could not be opened for syncing.");
                try { if (Fsync(directory) != 0) throw new IOException("Update state directory could not be synced."); }
                finally { Close(directory); }
            }
        }
        finally { File.Delete(temp); }
    }
    [DllImport("kernel32.dll", EntryPoint = "MoveFileExW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool MoveFileEx(string oldName, string newName, int flags);
    [DllImport("libc", EntryPoint = "open", SetLastError = true)] private static extern int Open(string path, int flags);
    [DllImport("libc", EntryPoint = "fsync", SetLastError = true)] private static extern int Fsync(int fd);
    [DllImport("libc", EntryPoint = "close")] private static extern int Close(int fd);
    [GeneratedRegex(@"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$", RegexOptions.CultureInvariant)]
    private static partial Regex VersionPattern();
    public static Version Version(string text) => VersionPattern().IsMatch(text) && System.Version.TryParse(text, out var version)
        ? version : throw new InvalidDataException("A release version is invalid.");
    public static bool InWindow(UpdatePolicy policy, DateTimeOffset now) => (now.UtcDateTime.Hour - policy.MaintenanceHour + 24) % 24 < policy.MaintenanceDuration;
}

public sealed class UpdaterPaths
{
    public const string FeedUrl = "https://github.com/embire2/openwebpbx/releases/latest/download/update-manifest.json";
    public string Data { get; }
    public string PublicStatus { get; }
    public string InstalledVersionPath { get; }
    public string Helper { get; }
    public string Platform { get; }
    public string Downloads => Path.Combine(Data, "downloads");
    public string Staging => Path.Combine(Data, "staging");
    public string Trust => Path.Combine(Data, "trust.json");
    public string Journal => Path.Combine(Data, "worker-journal.json");
    public string InstallJournal => Path.Combine(Data, "install-journal.json");
    public string Feed => Path.Combine(Data, "feed-envelope.json");
    public string FailedInstall => Path.Combine(Data, "failed-install.json");
    public string Status => Path.Combine(Data, "status.json");
    public UpdaterPaths(IConfiguration configuration)
    {
        if (RuntimeInformation.OSArchitecture != Architecture.X64 || RuntimeInformation.ProcessArchitecture != Architecture.X64)
            throw new PlatformNotSupportedException("This updater requires an x64 installation.");
        var windows = OperatingSystem.IsWindows();
        if (!windows && (!OperatingSystem.IsLinux() || !File.Exists("/etc/os-release") || !IsDebian13(File.ReadAllLines("/etc/os-release"))))
            throw new PlatformNotSupportedException("This updater requires Windows x64 or Debian 13 amd64.");
        Platform = windows ? "windows-x64" : "debian13-amd64";
        var privateRoot = windows ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX") : "/var/lib/openwebpbx";
        Data = configuration["Updater:DataDirectory"] ?? Path.Combine(privateRoot, "updates");
        PublicStatus = configuration["Updater:PublicStatus"] ?? (windows ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX-Status", "updates.json") : "/run/openwebpbx-updater/status.json");
        InstalledVersionPath = configuration["Updater:InstalledVersionPath"] ?? (windows ? Path.Combine(privateRoot, "installation.json") : "/var/www/fusionpbx/VERSION");
        Helper = configuration["Updater:Helper"] ?? (windows ? @"C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1" : "/opt/openwebpbx/tools/upgrade.py");
    }
    public static bool IsDebian13(IEnumerable<string> lines)
    {
        var values = lines.Where(line => !line.TrimStart().StartsWith('#') && line.Contains('='))
            .Select(line => line.Split('=', 2)).ToDictionary(parts => parts[0].Trim(), parts => parts[1].Trim().Trim('"', '\''), StringComparer.Ordinal);
        return values.GetValueOrDefault("ID") == "debian" && values.GetValueOrDefault("VERSION_ID") == "13";
    }
    public string InstalledVersion()
    {
        string value;
        if (OperatingSystem.IsWindows())
        { using var state = JsonDocument.Parse(UpdateJson.ReadBytes(InstalledVersionPath, 65536)); value = state.RootElement.GetProperty("Version").GetString()!; }
        else value = File.ReadAllText(InstalledVersionPath).Trim();
        UpdateJson.Version(value); return value;
    }
    public void Prepare()
    {
        foreach (var path in new[] { Data, Downloads, Staging, Path.Combine(Data, "logs") })
        { Directory.CreateDirectory(path); if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); }
    }
    public static string PinnedKey()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("OpenWebPbx.Updater.release-public.pem") ?? throw new InvalidOperationException("Release verification key is unavailable.");
        using var reader = new StreamReader(stream); return reader.ReadToEnd();
    }
}
