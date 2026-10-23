// SPDX-License-Identifier: AGPL-3.0-or-later
#if PHONE_PACKAGE_FIXTURE
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Security.AccessControl;
using System.Security.Principal;
namespace OpenWebPbx.Phone.Core;
/// <summary>Hosted development package only. This type and its public test key do not exist in a production assembly.</summary>
public static class PackageFixture
{
    private sealed record Options(string Nonce, string Root, string PublicKey, string FeedBase);
    private static readonly Lazy<Options> Value = new(Read);
    private static Options Read()
    {
        if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" || Environment.GetEnvironmentVariable("GITHUB_REPOSITORY") != "embire2/openwebpbx") throw new InvalidOperationException("Only a disposable hosted Windows package fixture may run.");
        using var input = typeof(PackageFixture).Assembly.GetManifestResourceStream("OpenWebPbx.Phone.PackageFixture.json") ?? throw new InvalidOperationException(); using var memory = new MemoryStream(); input.CopyTo(memory); if (memory.Length > 8192) throw new InvalidOperationException();
        var options = JsonSerializer.Deserialize<Options>(memory.ToArray()) ?? throw new InvalidOperationException(); var temp = Environment.GetEnvironmentVariable("RUNNER_TEMP") ?? throw new InvalidOperationException();
        if (!Regex.IsMatch(options.Nonce, "^[a-f0-9]{32}$") || !Path.GetFullPath(options.Root).Equals(Path.Combine(Path.GetFullPath(temp), "phone-package-" + options.Nonce), StringComparison.OrdinalIgnoreCase) || !Directory.Exists(options.Root) || options.PublicKey.Length is < 400 or > 2048 || options.PublicKey.Contains("PRIVATE", StringComparison.Ordinal)) throw new InvalidOperationException();
        if (!Uri.TryCreate(options.FeedBase, UriKind.Absolute, out var origin) || origin.Scheme != "http" || origin.Host != "127.0.0.1" || origin.Port <= 1024 || origin.UserInfo != "" || origin.AbsolutePath != "/" || origin.Query != "" || origin.Fragment != "") throw new InvalidOperationException();
        return options;
    }
    public static void ObserveProcessEntry()
    {
        // Diagnostic only: a broker may omit job environment variables. This never
        // changes Read() or authorizes a fixture that the ordinary guard refuses.
        try
        {
            if (!OperatingSystem.IsWindows()) return;
            using var input = typeof(PackageFixture).Assembly.GetManifestResourceStream("OpenWebPbx.Phone.PackageFixture.json"); if (input is null) return;
            using var memory = new MemoryStream(); input.CopyTo(memory); if (memory.Length > 8192) return;
            var options = JsonSerializer.Deserialize<Options>(memory.ToArray()); if (options is null || !Regex.IsMatch(options.Nonce, "^[a-f0-9]{32}$") || !Path.IsPathFullyQualified(options.Root) || Path.GetFileName(options.Root) != "phone-package-" + options.Nonce) return;
            var directory = new DirectoryInfo(options.Root); if (!directory.Exists) return;
            for (var parent = directory; parent is not null; parent = parent.Parent) if ((parent.Attributes & FileAttributes.ReparsePoint) != 0) return;
            var acl = directory.GetAccessControl(); var sid = WindowsIdentity.GetCurrent().User!.Value; var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
            if (!acl.AreAccessRulesProtected || rules.Length != 2) return;
            foreach (var rule in rules) if (rule.AccessControlType != AccessControlType.Allow || rule.IdentityReference.Value != sid && rule.IdentityReference.Value != "S-1-5-18" || (rule.FileSystemRights & FileSystemRights.FullControl) != FileSystemRights.FullControl) return;
            var temp = Environment.GetEnvironmentVariable("RUNNER_TEMP"); using var output = new FileStream(Path.Combine(options.Root, "fixture-startup.json"), FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            JsonSerializer.Serialize(output, new { schema = 1, producer = "PackageFixtureStartup", state = "observed", actions_match = Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true", hosted_match = Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") == "github-hosted", repo_match = Environment.GetEnvironmentVariable("GITHUB_REPOSITORY") == "embire2/openwebpbx", runner_temp_present = temp is not null, runner_temp_matches = temp is not null && Path.GetFullPath(options.Root).Equals(Path.Combine(Path.GetFullPath(temp), "phone-package-" + options.Nonce), StringComparison.OrdinalIgnoreCase) });
        }
        catch { }
    }
    public static bool Enabled => Value.Value is not null;
    public static string Root => Value.Value.Root;
    public static string IdentityName => "OpenWebPBX.FreePhone.Dev." + Value.Value.Nonce[..16];
    public static string Publisher => "CN=FreePhone Development " + Value.Value.Nonce;
    public static string InstanceKey => "OpenWebPBX-FreePhone-Development-" + Value.Value.Nonce;
    public static string StartupTaskId => "FreePhoneDevelopment" + Value.Value.Nonce;
    public static RSA OpenKey() { var key = RSA.Create(); try { key.ImportFromPem(Value.Value.PublicKey); if (key.KeySize != 3072) throw new InvalidOperationException(); return key; } catch { key.Dispose(); throw; } }
    public static Uri Map(Uri canonical)
    {
        if (canonical == ReleaseDownload.Catalogue) return new(new Uri(Value.Value.FeedBase), "catalogue");
        if (canonical.AbsoluteUri == "https://github.com/embire2/openwebpbx/releases/download/windows-phone-v1.0.1/OpenWebPBX-Free-Phone-1.0.1-win-x64.msixbundle") return new(new Uri(Value.Value.FeedBase), "package");
        throw new InvalidOperationException("A package fixture request escaped its two owned loopback resources.");
    }
}
#endif
