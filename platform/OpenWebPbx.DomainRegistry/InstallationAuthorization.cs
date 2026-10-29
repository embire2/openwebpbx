// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace OpenWebPbx.DomainRegistry;

public sealed record InstallationBinding(Guid InstallationUuid, Guid AccountTenantUuid, long Generation, DateTimeOffset ExpiresAt);
public sealed class InstallationAuthorization(RegistryOptions options) {
    public const string Issuer = "https://call.openweb.co.za/api/v1";
    public const string KeyId = "installation-2026-a";
    private static byte[] Decode(string? value, int maximum) {
        if (value is null || value.Length > maximum * 2 || !Regex.IsMatch(value,"^[A-Za-z0-9_-]+$")) throw new Refused("installation_authorization_invalid",403);
        var text=value.Replace('-','+').Replace('_','/');text+=new string('=',(4-text.Length%4)%4);
        var bytes=Convert.FromBase64String(text);
        if (bytes.Length>maximum || Convert.ToBase64String(bytes).TrimEnd('=').Replace('+','-').Replace('/','_')!=value) throw new Refused("installation_authorization_invalid",403);
        return bytes;
    }
    public InstallationBinding Verify(string envelope, LeaseRequest request, string keyHash) {
        try {
            if (envelope.Length>16384) throw new Refused("installation_authorization_invalid",403);
            using var doc=JsonDocument.Parse(envelope,new JsonDocumentOptions{MaxDepth=8});var root=doc.RootElement;
            if (!root.EnumerateObject().Select(x=>x.Name).Order().SequenceEqual(new[]{"algorithm","key_id","payload","signature"})
                || root.GetProperty("algorithm").GetString()!="RS256" || root.GetProperty("key_id").GetString()!=KeyId) throw new Refused("installation_authorization_invalid",403);
            var payload=Decode(root.GetProperty("payload").GetString()!,8192);var signature=Decode(root.GetProperty("signature").GetString()!,512);
            using var rsa=RSA.Create();rsa.ImportFromPem(File.ReadAllText(options.InstallationAuthorityPublicKey));
            if (rsa.KeySize!=3072 || !rsa.VerifyData(payload,signature,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1)) throw new Refused("installation_authorization_invalid",403);
            using var inner=JsonDocument.Parse(payload,new JsonDocumentOptions{MaxDepth=4});var p=inner.RootElement;
            var names=new[]{"schema","issuer","audience","installation_uuid","account_tenant_uuid","local_tenant_uuid","domain_uuid","key_hash","server_host","label","issued_at","expires_at","generation"};
            if (!p.EnumerateObject().Select(x=>x.Name).Order().SequenceEqual(names.Order()) || p.GetProperty("schema").GetInt32()!=1
                || p.GetProperty("issuer").GetString()!=Issuer || p.GetProperty("audience").GetString()!="openwebpbx-installation"
                || p.GetProperty("key_hash").GetString()!=keyHash || p.GetProperty("server_host").GetString()!=request.ServerHost
                || p.GetProperty("local_tenant_uuid").GetString()!=request.TenantUuid.ToString("D") || p.GetProperty("domain_uuid").GetString()!=request.DomainUuid.ToString("D")
                || p.GetProperty("label").GetString()!=request.Label) throw new Refused("installation_authorization_binding",403);
            var issued=DateTimeOffset.Parse(p.GetProperty("issued_at").GetString()!,CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind);
            var until=DateTimeOffset.Parse(p.GetProperty("expires_at").GetString()!,CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind);
            var generation=p.GetProperty("generation").GetInt64();
            var id=Guid.ParseExact(p.GetProperty("installation_uuid").GetString()!,"D");var account=Guid.ParseExact(p.GetProperty("account_tenant_uuid").GetString()!,"D");
            if (id==Guid.Empty || account==Guid.Empty || generation<1 || issued.Offset!=TimeSpan.Zero || until.Offset!=TimeSpan.Zero
                || issued>DateTimeOffset.UtcNow.AddMinutes(5) || until<=DateTimeOffset.UtcNow || until<=issued || until>issued.AddDays(366)) throw new Refused("installation_authorization_expired",403);
            return new(id,account,generation,until);
        } catch (Refused) { throw; }
        catch (IOException) { throw new Refused("installation_authority_unavailable",503); }
        catch (Exception error) when (error is JsonException or CryptographicException or FormatException or InvalidOperationException or ArgumentException or KeyNotFoundException or OverflowException) {
            throw new Refused("installation_authorization_invalid",403);
        }
    }
}
