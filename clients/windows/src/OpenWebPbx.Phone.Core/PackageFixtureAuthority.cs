// SPDX-License-Identifier: AGPL-3.0-or-later
#if PHONE_PACKAGE_FIXTURE
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenWebPbx.Phone.Core;

public static partial class PackageFixture
{
    internal sealed record HostContext(int Schema, string Producer, string Nonce, string Root, string SourceCommit, int HostProcessId, long HostStartedUtcTicks, string HostExecutable, string UserSid, string MachineName, string FamilyName, string DataParent, string CoreSha256, string HelperCoreSha256, string HelperSha256, string IssuedUtc, string ExpiresUtc);
    internal sealed record NativeIdentity(string Name, string Publisher, string FamilyName, string InstalledPath);
    [StructLayout(LayoutKind.Sequential)]
    private struct NativePackageId { public uint Reserved, Architecture; public ulong Version; public IntPtr Name, Publisher, ResourceId, PublisherId; }
    private delegate int NativeString(ref uint length, StringBuilder? value);
    [DllImport("kernel32.dll")] private static extern int GetCurrentPackageId(ref uint length, IntPtr buffer);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetCurrentPackageFamilyName(ref uint length, StringBuilder? value);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetCurrentPackagePath(ref uint length, StringBuilder? value);

    internal static byte[] ReadBounded(Stream input, int limit)
    {
        byte[] bytes = new byte[limit + 1]; int used = 0;
        while (true) { int read = input.Read(bytes, used, bytes.Length - used); used += read; if (used > limit) throw new InvalidDataException("Fixture context exceeds its bound."); if (read == 0) return bytes[..used]; }
    }
    private static void Ordinary(string path, bool directory)
    {
        FileSystemInfo? item = directory ? new DirectoryInfo(path) : new FileInfo(path);
        if (!item.Exists || ((item.Attributes & FileAttributes.Directory) != 0) != directory) throw new InvalidOperationException("The fixture context input is missing.");
        while (item is not null) { if ((item.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("The fixture context is linked."); item = item is FileInfo file ? file.Directory : ((DirectoryInfo)item).Parent; }
    }
    internal static void ProtectedRoot(string root, string userSid)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        Ordinary(root, true); var acl = new DirectoryInfo(root).GetAccessControl(); var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (!acl.AreAccessRulesProtected || rules.Length != 2 || rules[0].IdentityReference.Value == rules[1].IdentityReference.Value || userSid != WindowsIdentity.GetCurrent().User?.Value) throw new InvalidOperationException("The fixture root ownership differs.");
        foreach (var rule in rules) if (rule.AccessControlType != AccessControlType.Allow || rule.IdentityReference.Value != userSid && rule.IdentityReference.Value != "S-1-5-18" || (rule.FileSystemRights & FileSystemRights.FullControl) != FileSystemRights.FullControl) throw new InvalidOperationException("The fixture root permissions differ.");
    }
    internal static bool ValidateEnvironment(Options options, IReadOnlyDictionary<string, string?> observed)
    {
        bool complete = true;
        foreach (var expected in ExpectedEnvironment(options)) { observed.TryGetValue(expected.Key, out var value); if (string.IsNullOrEmpty(value)) complete = false; else if (!string.Equals(value, expected.Value, expected.Key == "RUNNER_TEMP" ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw new InvalidOperationException("A nonempty fixture environment value conflicts."); }
        return complete;
    }
    private static Dictionary<string, string> ExpectedEnvironment(Options options) => new() { ["GITHUB_ACTIONS"] = "true", ["RUNNER_ENVIRONMENT"] = "github-hosted", ["GITHUB_REPOSITORY"] = "embire2/openwebpbx", ["RUNNER_TEMP"] = Path.GetDirectoryName(Path.GetFullPath(options.Root))! };
    internal static void LiveHost(Options options)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        if (!Regex.IsMatch(options.SourceCommit, "^[a-f0-9]{40}$") || options.HostProcessId < 1 || options.HostProcessId == Environment.ProcessId || options.HostStartedUtcTicks < 1 || !Path.IsPathFullyQualified(options.HostExecutable) || options.MachineName != Environment.MachineName || options.UserSid != WindowsIdentity.GetCurrent().User?.Value) throw new InvalidOperationException("The compiled fixture host differs.");
        using var host = Process.GetProcessById(options.HostProcessId);
        if (host.HasExited || host.StartTime.ToUniversalTime().Ticks != options.HostStartedUtcTicks || !string.Equals(host.MainModule?.FileName, options.HostExecutable, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("The original fixture host is no longer live.");
    }
    internal static void ValidateContext(Options options, HostContext context, string sid, string machine, DateTimeOffset now)
    {
        if (context.Schema != 1 || context.Producer != "PackageHostContext" || context.Nonce != options.Nonce || !string.Equals(context.Root, options.Root, StringComparison.OrdinalIgnoreCase) || context.SourceCommit != options.SourceCommit || context.HostProcessId != options.HostProcessId || context.HostStartedUtcTicks != options.HostStartedUtcTicks || !string.Equals(context.HostExecutable, options.HostExecutable, StringComparison.OrdinalIgnoreCase) || context.UserSid != options.UserSid || context.UserSid != sid || context.MachineName != options.MachineName || context.MachineName != machine) throw new InvalidOperationException("The fixture host context binding differs.");
        if (!Regex.IsMatch(context.FamilyName, "^OpenWebPBX\\.FreePhone\\.Dev\\." + options.Nonce[..16] + "_[a-z0-9]{13}$") || !Regex.IsMatch(context.CoreSha256, "^[a-f0-9]{64}$") || !Regex.IsMatch(context.HelperCoreSha256, "^[a-f0-9]{64}$") || !Regex.IsMatch(context.HelperSha256, "^[a-f0-9]{64}$") || !Path.IsPathFullyQualified(context.DataParent)) throw new InvalidOperationException("The fixture package context differs.");
        // The guarded parent obtains this from ApplicationDataManager for the
        // actual PFN. Do not reconstruct it through potentially redirected AppData.
        var localState = Path.GetDirectoryName(context.DataParent); var packageData = localState is null ? null : Path.GetDirectoryName(localState);
        if (Path.GetFileName(context.DataParent) != "OpenWebPBX Free Phone" || Path.GetFileName(localState) != "LocalState" || Path.GetFileName(packageData) != context.FamilyName) throw new InvalidOperationException("The current-user fixture data path differs.");
        const string format = "yyyy-MM-dd'T'HH:mm:ss'Z'";
        if (!DateTimeOffset.TryParseExact(context.IssuedUtc, format, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var issued) || !DateTimeOffset.TryParseExact(context.ExpiresUtc, format, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var expires) || issued > now.AddMinutes(1) || expires <= now || expires <= issued || expires - issued > TimeSpan.FromHours(2)) throw new InvalidOperationException("The fixture context is expired or outside its lifetime.");
    }
    internal static HostContext ReadContext(Stream input)
    {
        byte[] bytes = ReadBounded(input, 16384);
        using var document = JsonDocument.Parse(bytes); var names = new HashSet<string>(StringComparer.Ordinal); foreach (var property in document.RootElement.EnumerateObject()) if (!names.Add(property.Name)) throw new InvalidOperationException("Fixture context repeats a field.");
        if (!names.SetEquals(typeof(HostContext).GetProperties().Select(property => property.Name))) throw new InvalidOperationException("Fixture context fields differ.");
        return JsonSerializer.Deserialize<HostContext>(bytes) ?? throw new InvalidOperationException();
    }
    private static HostContext Context(Options options, bool helper = false)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        string path = Path.Combine(options.Root, "fixture-host-context.json"); Ordinary(path, false);
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read); var context = ReadContext(file); ValidateContext(options, context, WindowsIdentity.GetCurrent().User!.Value, Environment.MachineName, DateTimeOffset.UtcNow);
        Ordinary(typeof(PackageFixture).Assembly.Location, false);
        if (Hash(typeof(PackageFixture).Assembly.Location) != (helper ? context.HelperCoreSha256 : context.CoreSha256)) throw new InvalidOperationException("The actual fixture core bytes differ.");
        return context;
    }
    private static string NativeText(NativeString get)
    {
        uint length = 0; if (get(ref length, null) != 122 || length is < 3 or > 1024) throw new InvalidOperationException("The native fixture package text is unavailable.");
        var text = new StringBuilder((int)length); if (get(ref length, text) != 0 || text.Length is < 2 or > 1023) throw new InvalidOperationException(); return text.ToString();
    }
    internal static NativeIdentity? CurrentIdentity()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        uint length = 0; int status = GetCurrentPackageId(ref length, IntPtr.Zero); if (status == 15700) return null;
        if (status != 122 || length < Marshal.SizeOf<NativePackageId>() || length > 4096) throw new InvalidOperationException("The actual fixture package identity is unavailable.");
        IntPtr buffer = Marshal.AllocHGlobal((int)length);
        try { if (GetCurrentPackageId(ref length, buffer) != 0) throw new InvalidOperationException(); var id = Marshal.PtrToStructure<NativePackageId>(buffer); if (id.Architecture != 9) throw new InvalidOperationException(); return new(Marshal.PtrToStringUni(id.Name) ?? "", Marshal.PtrToStringUni(id.Publisher) ?? "", NativeText(GetCurrentPackageFamilyName), NativeText(GetCurrentPackagePath)); }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    internal static void ValidateIdentity(Options options, HostContext context, NativeIdentity identity, string executable)
    {
        if (identity.Name != "OpenWebPBX.FreePhone.Dev." + options.Nonce[..16] || identity.Publisher != "CN=FreePhone Development " + options.Nonce || identity.FamilyName != context.FamilyName || !Path.IsPathFullyQualified(identity.InstalledPath) || !string.Equals(executable, Path.Combine(identity.InstalledPath, "OpenWebPbx.Phone.App.exe"), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("The actual brokered fixture package differs.");
    }
    private static string Hash(string path) { using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read); if (file.Length is < 1 or > 32 * 1024 * 1024) throw new InvalidOperationException(); return Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant(); }
    private static void StagedHelper(HostContext context, string executable)
    {
        string directory = Path.GetDirectoryName(Path.GetFullPath(executable))!;
        if (Path.GetFileName(executable) != "OpenWebPbx.Phone.Updater.exe" || !Regex.IsMatch(Path.GetFileName(directory), "^helper-[a-f0-9]{32}$") || !string.Equals(Path.GetDirectoryName(directory), Path.Combine(context.DataParent, "direct", "updates"), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("The fixture helper scope differs.");
        Ordinary(executable, false); Ordinary(Path.Combine(directory, "OpenWebPbx.Phone.Core.dll"), false);
        if (Hash(executable) != context.HelperSha256 || Hash(Path.Combine(directory, "OpenWebPbx.Phone.Core.dll")) != context.HelperCoreSha256) throw new InvalidOperationException("The actual fixture helper bytes differ.");
    }
    private static void AuthorizeProcess(Options options)
    {
        string stage = "root"; bool rootChecked = false;
        try
        {
            ProtectedRoot(options.Root, options.UserSid); rootChecked = true; stage = "live_host"; LiveHost(options);
            stage = "environment"; bool inherited = ValidateEnvironment(options, ExpectedEnvironment(options).Keys.ToDictionary(key => key, Environment.GetEnvironmentVariable));
            stage = "native_identity"; var identity = CurrentIdentity();
            if (identity is not null)
            {
                stage = "context"; var context = Context(options); stage = "package_identity"; ValidateIdentity(options, context, identity, Environment.ProcessPath!); Ordinary(identity.InstalledPath, true);
                ObserveAuthority(options, "authorized", "package_identity", null); return;
            }
            stage = "helper_environment"; if (!inherited) throw new InvalidOperationException("An unpackaged fixture must inherit its guarded host context.");
            string published = Path.Combine(options.Root, "app", "updater", "OpenWebPbx.Phone.Updater.exe");
            if (string.Equals(Environment.ProcessPath, published, StringComparison.OrdinalIgnoreCase)) { Ordinary(published, false); return; }
            stage = "staged_helper"; StagedHelper(Context(options, true), Environment.ProcessPath!);
        }
        catch (Exception error) { if (rootChecked) ObserveAuthority(options, "refused", stage, error); throw; }
    }
    private static void ObserveAuthority(Options options, string state, string stage, Exception? error)
    {
        // Closed first-app observation only; failure never changes the actual guard result.
        try
        {
            if (Path.GetFileName(Environment.ProcessPath) != "OpenWebPbx.Phone.App.exe") return;
            using var output = new FileStream(Path.Combine(options.Root, "fixture-authority.json"), FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            JsonSerializer.Serialize(output, new { schema = 1, producer = "PackageFixtureAuthority", state, stage, error_type = error?.GetType().Name, hresult = error?.HResult }); output.Flush(true);
        }
        catch { }
    }
    public static void ConfigureUpdaterChild(ProcessStartInfo start)
    {
        var options = Value.Value; ProtectedRoot(options.Root, options.UserSid); LiveHost(options); var context = Context(options); var identity = CurrentIdentity() ?? throw new InvalidOperationException();
        ValidateIdentity(options, context, identity, Environment.ProcessPath!); StagedHelper(context, start.FileName);
        foreach (var expected in ExpectedEnvironment(options)) { if (start.Environment.TryGetValue(expected.Key, out var present) && !string.IsNullOrEmpty(present) && !string.Equals(present, expected.Value, expected.Key == "RUNNER_TEMP" ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) throw new InvalidOperationException("The fixture child environment conflicts."); start.Environment[expected.Key] = expected.Value; }
    }
}
#endif
