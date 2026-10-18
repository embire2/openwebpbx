// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
namespace OpenWebPbx.DomainRegistry;
public interface IRegistryDns {
    Task<IReadOnlySet<string>> Names(CancellationToken stop);
    Task Ensure(string label, string target, string? previous, CancellationToken stop);
}
public sealed record ZoneRecord(string Name, string Type, string[] Data, int Line);
public sealed class CpanelDns : IRegistryDns, IDisposable {
    private readonly HttpClient client;
    private readonly RegistryOptions options;
    public CpanelDns(RegistryOptions options) : this(options, new SocketsHttpHandler { AllowAutoRedirect = false, UseProxy = false }) { }
    public CpanelDns(RegistryOptions options, HttpMessageHandler handler) {
        this.options = options; client = new HttpClient(handler) { BaseAddress = new Uri(options.CpanelEndpoint), Timeout = TimeSpan.FromSeconds(15), MaxResponseContentBufferSize = 2 * 1024 * 1024 };
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("cpanel", options.CpanelUsername + ":" + options.CpanelToken);
    }
    public void Dispose() => client.Dispose();
    private async Task<JsonElement> Api(string method, IEnumerable<KeyValuePair<string,string>> parameters, CancellationToken stop) {
        var query = string.Join("&", parameters.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value)));
        using var response = await client.GetAsync("execute/DNS/" + method + "?" + query, stop); response.EnsureSuccessStatusCode();
        using var json = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(stop)); var root = json.RootElement;
        // HTTPS /execute returns the result directly. The documented CLI
        // envelope has module/func/result; accept it only when all bindings match.
        var result = root;
        if (root.TryGetProperty("result", out var wrapped)) {
            if (root.GetProperty("module").GetString() != "DNS" || root.GetProperty("func").GetString() != method) throw new IOException("dns_provider_binding");
            result = wrapped;
        }
        if (result.GetProperty("status").GetInt32() != 1) throw new IOException("dns_provider_unavailable");
        return result.GetProperty("data").Clone();
    }
    private static string Decode(string encoded) {
        var bytes = Convert.FromBase64String(encoded);
        if (bytes.Any(b => b is < 32 or > 126)) throw new IOException("dns_provider_encoding");
        return Encoding.ASCII.GetString(bytes);
    }
    public static (long Serial, List<ZoneRecord> Records) Parse(JsonElement data) {
        long? serial = null; var rows = new List<ZoneRecord>();
        foreach (var item in data.EnumerateArray()) {
            if (item.GetProperty("type").GetString() != "record") continue;
            var name = Decode(item.GetProperty("dname_b64").GetString()!); name = (name.EndsWith('.') ? name.TrimEnd('.') : name + "." + RegistryOptions.Zone).ToLowerInvariant();
            var type = item.GetProperty("record_type").GetString()!; var values = item.GetProperty("data_b64").EnumerateArray().Select(v => Decode(v.GetString()!)).ToArray();
            if (type == "SOA" && name == RegistryOptions.Zone && values.Length >= 3 && long.TryParse(values[2], out var value)) serial = value;
            rows.Add(new(name, type, values, item.GetProperty("line_index").GetInt32()));
        }
        return (serial ?? throw new IOException("dns_soa_missing"), rows);
    }
    private Task<JsonElement> Read(CancellationToken stop) => Api("parse_zone", [new("zone", RegistryOptions.Zone)], stop);
    public async Task<IReadOnlySet<string>> Names(CancellationToken stop) => Parse(await Read(stop)).Records.Select(row => row.Name).ToHashSet(StringComparer.Ordinal);
    public async Task Ensure(string label, string target, string? previous, CancellationToken stop) {
        Protocol.Label(label); Protocol.Host(target);
        if (Protocol.IsReserved(label)) throw new Refused("dns_conflict", 409);
        var name = label + "." + RegistryOptions.Zone; var zone = Parse(await Read(stop)); var same = zone.Records.Where(row => row.Name == name).ToArray();
        if (same.Length > 0 && (same.Length != 1 || same[0].Type != "CNAME" || same[0].Data.Length != 1)) throw new Refused("dns_conflict", 409);
        if (same.Length == 1 && same[0].Data[0].TrimEnd('.').Equals(target, StringComparison.OrdinalIgnoreCase)) return;
        if (same.Length == 1 && (previous is null || !same[0].Data[0].TrimEnd('.').Equals(previous, StringComparison.OrdinalIgnoreCase))) throw new Refused("dns_conflict", 409);
        var record = new Dictionary<string,object> { ["dname"] = name + ".", ["record_type"] = "CNAME", ["ttl"] = 300, ["data"] = new[] { target + "." } };
        if (same.Length == 1) record["line_index"] = same[0].Line;
        await Api("mass_edit_zone", [new("zone", RegistryOptions.Zone), new("serial", zone.Serial.ToString(System.Globalization.CultureInfo.InvariantCulture)), new(same.Length == 0 ? "add" : "edit", JsonSerializer.Serialize(record))], stop);
        var verify = Parse(await Read(stop)).Records.Where(row => row.Name == name).ToArray();
        if (verify.Length != 1 || verify[0].Type != "CNAME" || verify[0].Data.Length != 1 || !verify[0].Data[0].TrimEnd('.').Equals(target, StringComparison.OrdinalIgnoreCase)) throw new IOException("dns_readback_pending");
    }
}
