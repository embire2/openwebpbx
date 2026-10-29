// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
namespace OpenWebPbx.DomainRegistry;
public interface ISiteProof {
    Task Verify(string host, string nonce, string keyHash, CancellationToken stop);
    Task VerifyTenantAlias(string hostname,string serverHost,string nonce,string keyHash,CancellationToken stop)=>throw new Refused("tenant_readiness_unavailable",503);
}
public sealed class PublicSiteProof : ISiteProof {
    public static bool IsPublic(IPAddress address) {
        if (address.IsIPv4MappedToIPv6) return IsPublic(address.MapToIPv4());
        var b = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork) {
            return b[0] is not (0 or 10 or 127) && b[0] < 224 && !(b[0] == 169 && b[1] == 254) && !(b[0] == 172 && b[1] is >= 16 and <= 31) && !(b[0] == 192 && (b[1] == 168 || (b[1] == 0 && b[2] is 0 or 2) || (b[1] == 88 && b[2] == 99))) && !(b[0] == 100 && b[1] is >= 64 and <= 127) && !(b[0] == 198 && b[1] is 18 or 19) && !(b[0] == 198 && b[1] == 51 && b[2] == 100) && !(b[0] == 203 && b[1] == 0 && b[2] == 113);
        }
        // Only globally routed IPv6 unicast, excluding documentation, Teredo,
        // 6to4 and IETF protocol-assignment blocks. No local/mapped fallback.
        return b[0] is >= 0x20 and <= 0x3f && !(b[0] == 0x20 && b[1] == 0x01 && (b[2] < 0x02 || (b[2] == 0x0d && b[3] == 0xb8))) && !(b[0] == 0x20 && b[1] == 0x02) && !(b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0);
    }
    public Task Verify(string host,string nonce,string keyHash,CancellationToken stop){Protocol.Host(host);return VerifyCore(host,nonce,Protocol.Proof(nonce,keyHash,host),stop);}
    public Task VerifyTenantAlias(string host,string serverHost,string nonce,string keyHash,CancellationToken stop){
        const string suffix="."+RegistryOptions.Zone;Protocol.Host(serverHost);
        if(!host.EndsWith(suffix,StringComparison.Ordinal)||Protocol.IsReserved(Protocol.Label(host[..^suffix.Length])))throw new Refused("invalid_tenant_hostname",403);
        return VerifyCore(host,nonce,Protocol.Proof(nonce,keyHash,serverHost),stop);
    }
    private async Task VerifyCore(string host,string nonce,byte[] expected,CancellationToken stop) {
        var addresses = await Dns.GetHostAddressesAsync(host, stop);
        if (addresses.Length is < 1 or > 16 || addresses.Any(address => !IsPublic(address))) throw new Refused("hostname_requires_public_addresses", 403);
        using var handler = new SocketsHttpHandler { AllowAutoRedirect = false, UseProxy = false, ConnectTimeout = TimeSpan.FromSeconds(5) };
        handler.ConnectCallback = async (context, token) => {
            if (context.DnsEndPoint.Host != host || context.DnsEndPoint.Port != 443) throw new Refused("invalid_proof_endpoint");
            var socket = new Socket(addresses[0].AddressFamily, SocketType.Stream, ProtocolType.Tcp);
            try { await socket.ConnectAsync(new IPEndPoint(addresses[0], 443), token); return new NetworkStream(socket, ownsSocket: true); } catch { socket.Dispose(); throw; }
        };
        // TLS still validates the original hostname with the system trust store;
        // the already-validated destination IP is pinned through the connection.
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(12), MaxResponseContentBufferSize = 1024 };
        using var response = await client.GetAsync("https://" + host + "/.well-known/openwebpbx-instance/" + nonce, stop);
        var actual = await response.Content.ReadAsByteArrayAsync(stop);
        if (response.StatusCode != HttpStatusCode.OK || actual.Length != expected.Length || !CryptographicOperations.FixedTimeEquals(actual, expected)) throw new Refused("installed_hostname_proof_failed", 403);
    }
}
