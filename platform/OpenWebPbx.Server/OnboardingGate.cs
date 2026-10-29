using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Npgsql;

namespace OpenWebPbx.Server;

/// <summary>Local, independent verification of the central registration grant before new calls.</summary>
public sealed class OnboardingGate(IConfiguration configuration)
{
    public const string Issuer = "https://call.openweb.co.za/api/v1";
    public const string KeyId = "installation-2026-a";
    private static readonly string MarkerPath = OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX-Installation", "onboarding-required")
        : "/etc/openwebpbx-installation/onboarding-required";
    private int required = configuration.GetValue("Onboarding:Required", false) || MarkerPresent() ? 1 : 0;
    private int complete;
    public bool RegistrationRequired => Volatile.Read(ref required) != 0 && Volatile.Read(ref complete) == 0;
    public sealed record SetupInformation(string Url, string UserCode);
    public SetupInformation? Setup()
    {
        if (!RegistrationRequired) return null;
        try
        {
            using var document = ReadDocument(Path.Combine(StateRoot, "tenant-domains", "setup.json"), 8192);
            var root = document.RootElement;
            var code = root.GetProperty("user_code").GetString();
            var expected = "https://openwebpbx.com/wizard#code=" + code;
            if (code is null || !Regex.IsMatch(code, "^[A-F0-9]{5}-[A-F0-9]{5}$", RegexOptions.CultureInvariant)
                || root.GetProperty("verification_uri_complete").GetString() != expected
                || !Timestamp(root.GetProperty("expires_at").GetString()!, out var until) || until <= DateTimeOffset.UtcNow) return null;
            return new SetupInformation(expected, code);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or ArgumentException or KeyNotFoundException) { return null; }
    }
    private string StateRoot => configuration["Onboarding:StateRoot"] ?? (OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX") : "/var/lib/openwebpbx");
    private string WebRoot => configuration["Onboarding:WebRoot"] ?? (OperatingSystem.IsWindows() ? @"C:\OpenWebPBX\web" : "/var/www/fusionpbx");

    public sealed record DomainAccess(bool Required, IReadOnlySet<Guid> Domains)
    {
        public bool Allows(Guid domain) => !Required || Domains.Contains(domain);
        public Guid[] Identifiers => Domains.ToArray();
    }
    private static readonly DomainAccess Legacy = new(false, new HashSet<Guid>());
    private static readonly DomainAccess Blocked = new(true, new HashSet<Guid>());

    // This marker is deliberately outside every instance-backup restore root.
    // Broken/unreadable paths remain required rather than becoming an offline bypass.
    private static bool MarkerPresent()
    {
        try
        {
            if (Path.Exists(MarkerPath) || File.Exists(MarkerPath) || Directory.Exists(MarkerPath) || new FileInfo(MarkerPath).LinkTarget is not null) return true;
            var parent = Path.GetDirectoryName(MarkerPath)!;
            return Path.Exists(parent) && (!Directory.Exists(parent) || (File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return true; }
    }
    private DomainAccess Publish(DomainAccess access, int expected)
    {
        Volatile.Write(ref required, access.Required ? 1 : 0);
        Volatile.Write(ref complete, access.Required && expected > 0 && access.Domains.Count == expected ? 1 : 0);
        return access;
    }

    public async Task<DomainAccess> Read(NpgsqlConnection db, CancellationToken ct)
    {
        var enforced = configuration.GetValue("Onboarding:Required", false) || MarkerPresent();
        await using (var installed = new NpgsqlCommand("select to_regclass('v_pbx_onboarding_policy') is not null", db))
        {
            if (await installed.ExecuteScalarAsync(ct) is not true) return Publish(enforced ? Blocked : Legacy, 0);
        }
        string host = "", keyHash = "";
        await using (var policy = new NpgsqlCommand("select required,canonical_host,instance_key_hash from v_pbx_onboarding_policy where singleton=true", db))
        await using (var reader = await policy.ExecuteReaderAsync(ct))
            if (await reader.ReadAsync(ct)) { enforced |= reader.GetBoolean(0); host = reader.GetString(1); keyHash = reader.GetString(2); }
        if (!enforced) return Publish(Legacy, 0);
        Publish(Blocked, 0);
        try
        {
            if (!Hostname(host) || !Regex.IsMatch(keyHash, "^[a-f0-9]{64}$", RegexOptions.CultureInvariant)) return Blocked;
            using var identity = ReadDocument(Path.Combine(StateRoot, "tenant-domains", "instance-public.json"), 16384);
            ExactFields(identity.RootElement, ["schema", "server_host", "key_hash", "public_key"]);
            if (identity.RootElement.GetProperty("schema").GetInt32() != 1
                || identity.RootElement.GetProperty("server_host").GetString() != host
                || identity.RootElement.GetProperty("key_hash").GetString() != keyHash) return Blocked;
            var encodedKey = identity.RootElement.GetProperty("public_key").GetString()!;
            var publicKey = Convert.FromBase64String(encodedKey);
            if (Convert.ToBase64String(publicKey) != encodedKey || publicKey.Length is < 80 or > 256
                || Convert.ToHexStringLower(SHA256.HashData(publicKey)) != keyHash) return Blocked;
            using (var key = ECDsa.Create())
            {
                key.ImportSubjectPublicKeyInfo(publicKey, out var read);
                if (read != publicKey.Length || key.KeySize != 256 || key.ExportParameters(false).Curve.Oid.Value != "1.2.840.10045.3.1.7") return Blocked;
            }
            var pem = ReadBytes(Path.Combine(WebRoot, "resources", "keys", "installation-authority.pem"), 16384, false);
            using var transport = ReadDocument(Path.Combine(StateRoot, "tenant-domains", "ready.json"), 16384);
            ExactFields(transport.RootElement, transport.RootElement.TryGetProperty("authorizations", out var authorizations)
                ? ["schema", "server_host", "key_hash", "aliases", "authorizations"] : ["schema", "server_host", "key_hash", "aliases"]);
            if (authorizations.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Object)) return Blocked;
            if (transport.RootElement.GetProperty("schema").GetInt32() != 1
                || transport.RootElement.GetProperty("server_host").GetString() != host
                || transport.RootElement.GetProperty("key_hash").GetString() != keyHash
                || transport.RootElement.GetProperty("aliases").ValueKind != JsonValueKind.Object) return Blocked;
            var result = new HashSet<Guid>(); var count = 0;
            await using var command = new NpgsqlCommand("""
                select s.domain_uuid,s.tenant_uuid,s.service_uuid,o.account_tenant_uuid,o.requested_label,o.server_host,o.key_hash,
                    o.activation::text,a.hostname
                from v_pbx_services s join v_pbx_tenants t using(tenant_uuid)
                join v_domains d on d.domain_uuid=s.domain_uuid
                join v_users u on u.user_uuid=t.owner_user_uuid
                left join v_pbx_onboarding o on o.domain_uuid=s.domain_uuid and o.tenant_uuid=s.tenant_uuid
                    and o.service_uuid=s.service_uuid and o.owner_user_uuid=t.owner_user_uuid
                left join v_pbx_tenant_domains a on a.domain_uuid=s.domain_uuid and a.tenant_uuid=s.tenant_uuid
                    and a.service_uuid=s.service_uuid and a.requested_label=o.requested_label and a.key_hash=o.key_hash
                    and a.server_host=o.server_host and a.state='ready' and a.desired_enabled and a.certificate_not_after>now()
                where t.enabled and d.domain_enabled::text='true' and u.user_enabled::text='true'
                order by s.domain_uuid limit 1001
                """, db);
            await using var rows = await command.ExecuteReaderAsync(ct);
            while (await rows.ReadAsync(ct))
            {
                count++;
                if (count > 1000) return Blocked;
                if (Enumerable.Range(3, 6).Any(rows.IsDBNull) || rows.GetString(5) != host || rows.GetString(6) != keyHash) continue;
                var domain = rows.GetGuid(0); var tenant = rows.GetGuid(1); var label = rows.GetString(4); var alias = rows.GetString(8);
                if (!ManagedHostname(alias) || !transport.RootElement.GetProperty("aliases").TryGetProperty(alias, out var until)
                    || until.ValueKind != JsonValueKind.String || !Timestamp(until.GetString()!, out var transportExpiry)
                    || transportExpiry <= DateTimeOffset.UtcNow) continue;
                try
                {
                    VerifyReceipt(rows.GetString(7), System.Text.Encoding.UTF8.GetString(pem),
                        new Dictionary<string, string> { ["account_tenant_uuid"] = rows.GetGuid(3).ToString("D"),
                            ["local_tenant_uuid"] = tenant.ToString("D"), ["domain_uuid"] = domain.ToString("D"),
                            ["key_hash"] = keyHash, ["server_host"] = host, ["label"] = label }, DateTimeOffset.UtcNow);
                    result.Add(domain);
                }
                catch (Exception ex) when (ex is InvalidDataException or JsonException or CryptographicException or FormatException or InvalidOperationException) { }
            }
            return Publish(new DomainAccess(true, result), count);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or CryptographicException
            or FormatException or InvalidOperationException or ArgumentException or NpgsqlException) { return Blocked; }
    }

    public async Task<bool> Allows(Guid domain, NpgsqlDataSource data, CancellationToken ct)
    {
        await using var db = await data.OpenConnectionAsync(ct);
        return (await Read(db, ct)).Allows(domain);
    }

    internal static void VerifyReceipt(string envelope, string pem, IReadOnlyDictionary<string, string> bindings, DateTimeOffset now)
    {
        using var doc = JsonDocument.Parse(envelope, new JsonDocumentOptions { MaxDepth = 6 });
        var root = doc.RootElement; ExactFields(root, ["key_id", "algorithm", "payload", "signature"]);
        if (root.GetProperty("key_id").GetString() != KeyId || root.GetProperty("algorithm").GetString() != "RS256") throw new InvalidDataException("Invalid registration authority.");
        var raw = Decode(root.GetProperty("payload").GetString(), 8192); var signature = Decode(root.GetProperty("signature").GetString(), 1024);
        using var rsa = RSA.Create(); rsa.ImportFromPem(pem);
        if (rsa.KeySize is < 3072 or > 8192 || !rsa.VerifyData(raw, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) throw new InvalidDataException("Invalid registration signature.");
        using var payload = JsonDocument.Parse(raw, new JsonDocumentOptions { MaxDepth = 6 }); var p = payload.RootElement;
        ExactFields(p, ["schema", "issuer", "audience", "installation_uuid", "account_tenant_uuid", "local_tenant_uuid", "domain_uuid", "key_hash", "server_host", "label", "issued_at", "expires_at", "generation"]);
        if (p.GetProperty("schema").GetInt32() != 1 || p.GetProperty("issuer").GetString() != Issuer
            || p.GetProperty("audience").GetString() != "openwebpbx-installation" || p.GetProperty("generation").GetInt64() < 1) throw new InvalidDataException("Invalid registration scope.");
        foreach (var key in new[] { "installation_uuid", "account_tenant_uuid", "local_tenant_uuid", "domain_uuid" })
            if (!Guid.TryParseExact(p.GetProperty(key).GetString(), "D", out var id) || id.ToString("D") != p.GetProperty(key).GetString()) throw new InvalidDataException("Invalid registration identity.");
        foreach (var key in new[] { "account_tenant_uuid", "local_tenant_uuid", "domain_uuid", "key_hash", "server_host", "label" })
            if (!bindings.TryGetValue(key, out var expected) || p.GetProperty(key).GetString() != expected) throw new InvalidDataException("Registration belongs to another PBX.");
        if (!Regex.IsMatch(p.GetProperty("key_hash").GetString()!, "^[a-f0-9]{64}$", RegexOptions.CultureInvariant)
            || !Hostname(p.GetProperty("server_host").GetString()!)
            || !Regex.IsMatch(p.GetProperty("label").GetString()!, "^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", RegexOptions.CultureInvariant)
            || p.GetProperty("label").GetString()!.StartsWith("xn--", StringComparison.Ordinal)) throw new InvalidDataException("Invalid registration address.");
        if (!Timestamp(p.GetProperty("issued_at").GetString()!, out var issued) || !Timestamp(p.GetProperty("expires_at").GetString()!, out var expires)
            || issued > now.AddMinutes(5) || expires <= now || expires <= issued || expires - issued > TimeSpan.FromDays(366)) throw new InvalidDataException("Registration has expired or the server clock needs review.");
    }
    private static byte[] Decode(string? value, int limit)
    {
        if (string.IsNullOrEmpty(value) || value.Length > limit * 2 || !Regex.IsMatch(value, "^[A-Za-z0-9_-]+$", RegexOptions.CultureInvariant)) throw new InvalidDataException("Invalid registration encoding.");
        var raw = Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + new string('=', (4 - value.Length % 4) % 4));
        if (raw.Length > limit || Convert.ToBase64String(raw).TrimEnd('=').Replace('+', '-').Replace('/', '_') != value) throw new InvalidDataException("Invalid registration encoding.");
        return raw;
    }
    private static void ExactFields(JsonElement value, string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Invalid registration object.");
        var actual = value.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).ToArray();
        if (!actual.SequenceEqual(names.Order(StringComparer.Ordinal))) throw new InvalidDataException("Unexpected registration fields.");
    }
    private static bool Timestamp(string value, out DateTimeOffset result)
    {
        result = default;
        return Regex.IsMatch(value, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,6})?(?:Z|\\+00:00)$", RegexOptions.CultureInvariant)
            && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out result);
    }
    private static bool Hostname(string value) => value.Length <= 253 && value == value.ToLowerInvariant()
        && Regex.IsMatch(value, "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$", RegexOptions.CultureInvariant);
    private static bool ManagedHostname(string value) => Regex.IsMatch(value, "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\\.openwebpbx\\.com$", RegexOptions.CultureInvariant);
    private static JsonDocument ReadDocument(string path, int maximum) => JsonDocument.Parse(ReadBytes(path, maximum, true), new JsonDocumentOptions { MaxDepth = 6 });
    private static byte[] ReadBytes(string path, int maximum, bool owned)
    {
        var file = new FileInfo(path);
        for (FileSystemInfo? node = file; node is not null; node = node is FileInfo f ? f.Directory : ((DirectoryInfo)node).Parent)
            if ((node.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Registration state contains a link.");
        if (!file.Exists || file.Length is < 1 || file.Length > maximum) throw new IOException("Registration state unavailable.");
        if (!OperatingSystem.IsWindows())
        {
            if ((File.GetUnixFileMode(path) & (UnixFileMode.GroupWrite | UnixFileMode.OtherWrite)) != 0) throw new IOException("Registration state is writable.");
            if (owned && !RootOwned(path)) throw new IOException("Registration state owner is invalid.");
        }
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (stream.Length is < 1 || stream.Length > maximum) throw new IOException("Registration state unavailable.");
        var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes); return bytes;
    }
    [DllImport("libc", EntryPoint = "statx", SetLastError = true)]
    private static extern int Statx(int directory, string path, int flags, uint mask, IntPtr data);
    private static bool RootOwned(string path)
    {
        var buffer = Marshal.AllocHGlobal(256);
        try { return Statx(-100, path, 0x100, 0x7ff, buffer) == 0 && Marshal.ReadInt32(buffer, 20) == 0; }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
