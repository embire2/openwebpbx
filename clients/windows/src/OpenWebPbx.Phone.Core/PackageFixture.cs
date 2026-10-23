// SPDX-License-Identifier: AGPL-3.0-or-later
#if PHONE_PACKAGE_FIXTURE
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
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
    public static bool Enabled => Value.Value is not null;
    public static string Root => Value.Value.Root;
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
