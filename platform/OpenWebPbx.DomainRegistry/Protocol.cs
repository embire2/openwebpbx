// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
namespace OpenWebPbx.DomainRegistry;
public sealed record RegistryOptions(string ConnectionString, string CpanelEndpoint, string CpanelUsername, string CpanelToken) {
    public const string Zone = "openwebpbx.com";
    public string ListenUrl { get; init; } = "http://127.0.0.1:5095";
    public int MaximumLeasesPerInstance { get; init; } = 50;
    public static RegistryOptions Read(string path) {
        for (var item = Path.GetFullPath(path); item is not null; item = Path.GetDirectoryName(item))
            if ((File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Linked registry configuration refused.");
        if (!OperatingSystem.IsWindows() && (File.GetUnixFileMode(path) & (UnixFileMode.OtherRead | UnixFileMode.OtherWrite | UnixFileMode.OtherExecute | UnixFileMode.GroupWrite)) != 0)
            throw new InvalidOperationException("Private registry configuration required.");
        var value = JsonSerializer.Deserialize<RegistryOptions>(File.ReadAllText(path), Json.Options) ?? throw new InvalidOperationException("Registry configuration required.");
        if (string.IsNullOrWhiteSpace(value.ConnectionString) || !Uri.TryCreate(value.CpanelEndpoint, UriKind.Absolute, out var endpoint) || endpoint.Scheme != "https" || endpoint.UserInfo != "" || endpoint.Query != "" || endpoint.Fragment != "" || endpoint.AbsolutePath != "/" || value.CpanelUsername.Length == 0 || value.CpanelToken.Length == 0 || value.MaximumLeasesPerInstance is < 1 or > 50)
            throw new InvalidOperationException("Review the private registry configuration.");
        var listen = new Uri(value.ListenUrl);
        if (listen.Scheme != "http" || listen.Host != "127.0.0.1") throw new InvalidOperationException("The registry must remain loopback behind its trusted HTTPS proxy.");
        return value;
    }
}
public static class Json {
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, MaxDepth = 8 };
}
public sealed record ChallengeRequest(string PublicKey, string ServerHost);
public sealed record LeaseRequest(string Challenge, string PublicKey, string ServerHost, Guid TenantUuid, Guid DomainUuid, string Label, bool Enabled, long Revision, bool Move, string Signature);
public sealed record ChallengeReply(string Challenge, DateTimeOffset ExpiresAt);
public sealed record LeaseReply(string Hostname, string ServerHost, string State, bool Enabled, long Revision);
public sealed class Refused(string category, int status = 400) : Exception(category) { public int Status { get; } = status; }
public static partial class Protocol {
    [GeneratedRegex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$")]
    private static partial Regex HostPattern();
    [GeneratedRegex("^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$")]
    private static partial Regex LabelPattern();
    [GeneratedRegex("^[0-9a-f]{64}$")]
    private static partial Regex NoncePattern();
    private static readonly HashSet<string> Reserved = new("www mail smtp imap pop ftp cpcontacts cpcalendars webmail cpanel whm autodiscover autoconfig domains api admin portal status updates releases download downloads support legal privacy terms delete ns ns1 ns2 localhost test staging dev beta call pbx acme".Split(' '), StringComparer.Ordinal);
    public static string Host(string host) {
        if (string.IsNullOrEmpty(host) || System.Net.IPAddress.TryParse(host, out _) || host != host.ToLowerInvariant() || host.Length > 253 || !HostPattern().IsMatch(host) || host.EndsWith(".local") || host.EndsWith(".localhost") || host.EndsWith(".invalid") || host == RegistryOptions.Zone || host.EndsWith("." + RegistryOptions.Zone))
            throw new Refused("invalid_server_hostname");
        return host;
    }
    public static string Label(string label) { if (label is null || !LabelPattern().IsMatch(label)) throw new Refused("invalid_tenant_label"); return label; }
    public static bool IsReserved(string label) => Reserved.Contains(label) || label.StartsWith("xn--", StringComparison.Ordinal);
    public static string KeyHash(string encoded) {
        try {
            if (encoded is null || encoded.Length is < 80 or > 200) throw new CryptographicException();
            var bytes = Convert.FromBase64String(encoded); using var key = ECDsa.Create(); key.ImportSubjectPublicKeyInfo(bytes, out var read);
            if (read != bytes.Length || key.KeySize != 256 || key.ExportParameters(false).Curve.Oid.Value != "1.2.840.10045.3.1.7") throw new CryptographicException();
            return Convert.ToHexStringLower(SHA256.HashData(bytes));
        } catch (Exception error) when (error is CryptographicException or FormatException) { throw new Refused("invalid_instance_key"); }
    }
    public static byte[] Proof(string nonce, string hash, string host) => Encoding.ASCII.GetBytes($"openwebpbx-instance-v1\n{nonce}\n{hash}\n{host}\n");
    public static byte[] Message(LeaseRequest value, string hash) => Encoding.UTF8.GetBytes($"openwebpbx-tenant-v1\n{value.Challenge}\n{value.ServerHost}\n{hash}\n{value.TenantUuid:D}\n{value.DomainUuid:D}\n{value.Label}\n{(value.Enabled ? 1 : 0)}\n{value.Revision}\n{(value.Move ? 1 : 0)}\n");
    public static string Verify(LeaseRequest value) {
        Host(value.ServerHost); Label(value.Label);
        if (value.Challenge is null || !NoncePattern().IsMatch(value.Challenge) || value.Signature is null || value.TenantUuid == Guid.Empty || value.DomainUuid == Guid.Empty || value.Revision < 0) throw new Refused("invalid_lease_request");
        var hash = KeyHash(value.PublicKey);
        try {
            using var key = ECDsa.Create(); key.ImportSubjectPublicKeyInfo(Convert.FromBase64String(value.PublicKey), out _);
            if (value.Signature.Length > 200 || !key.VerifyData(Message(value, hash), Convert.FromBase64String(value.Signature), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)) throw new CryptographicException();
        } catch (Exception error) when (error is CryptographicException or FormatException) { throw new Refused("invalid_signature", 403); }
        return hash;
    }
    public static string CollisionLabel(string label, string key, Guid domain) => label[..Math.Min(label.Length, 36)] + "-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.ASCII.GetBytes(key + domain.ToString("D"))))[..10];
}
