// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
namespace OpenWebPbx.Phone.Core;
public sealed record WindowsPhonePolicy(string Mode, string TenantMode, bool RequiredByInstance, Version? Minimum, Version? Latest, bool Published)
{
    public bool Requires(Version installed) => Minimum is not null && installed < Minimum || Mode == "required" && Latest is not null && installed < Latest;
    public static WindowsPhonePolicy Parse(JsonObject value)
    {
        try
        {
            if (value["schema"]!.GetValue<int>() != 1 || value["component"]!.GetValue<string>() != "windows-free-phone" || value["channel"]!.GetValue<string>() != "stable" ||
                value["feed_url"]!.GetValue<string>() != "https://github.com/embire2/openwebpbx/releases/download/windows-phone-stable/windows-phone-update-manifest.json") throw Invalid();
            var published = value["release_available"]!.GetValue<bool>(); var mode = value["mode"]!.GetValue<string>(); var tenant = value["tenant_mode"]!.GetValue<string>();
            if (mode is not ("notify" or "download" or "required") || tenant is not ("notify" or "download" or "required")) throw Invalid();
            var min = value["minimum_version"]!.GetValue<string>(); var latest = value["latest_version"]!.GetValue<string>();
            if (!published && (min != "" || latest != "")) throw Invalid();
            var minimum = min == "" ? null : ClientRelease.Version(min); var available = latest == "" ? null : ClientRelease.Version(latest);
            if (published && available is null || minimum is not null && (available is null || minimum > available)) throw Invalid();
            return new(mode, tenant, value["required_by_instance"]!.GetValue<bool>(), minimum, available, published);
        }
        catch (Exception e) when (e is InvalidOperationException or NullReferenceException or FormatException) { throw Invalid(); }
    }
    private static PhoneInputException Invalid() => new("Your Windows phone update policy could not be verified. Existing calls can continue.");
}
public sealed record ClientRelease(string ReleaseVersion, long Sequence, Uri Package, long Bytes, string Sha256, string Identity, string Publisher)
{
    public string PayloadSha256 { get; init; } = "";
    public static Version Version(string value)
    {
        var split = value.Split('.'); if (split.Length != 3 || split.Any(x => x.Length is 0 or > 5 || x.Length > 1 && x[0] == '0' || x.Any(c => c is < '0' or > '9') || !int.TryParse(x, out var n) || n > 65535)) throw new PhoneInputException("The Windows phone release version is invalid.");
        return new(int.Parse(split[0], CultureInfo.InvariantCulture), int.Parse(split[1], CultureInfo.InvariantCulture), int.Parse(split[2], CultureInfo.InvariantCulture));
    }
    public static ClientRelease Verify(ReadOnlySpan<byte> envelope, RSA publicKey, long minimumSequence, string expectedIdentity, string expectedPublisher, string? acceptedPayloadSha256 = null, DateTimeOffset? now = null)
    {
        try
        {
            if (envelope.Length is 0 or > 262144 || publicKey.KeySize < 3072) throw Invalid();
            using var root = JsonDocument.Parse(envelope.ToArray(), new() { MaxDepth = 8 }); Exact(root.RootElement, ["algorithm", "key_id", "payload", "signature"]);
            if (root.RootElement.GetProperty("algorithm").GetString() != "rsa-sha256" || root.RootElement.GetProperty("key_id").GetString() != "windows-phone-release-1") throw Invalid();
            var payload = Convert.FromBase64String(root.RootElement.GetProperty("payload").GetString()!); var signature = Convert.FromBase64String(root.RootElement.GetProperty("signature").GetString()!);
            if (payload.Length > 65536 || !publicKey.VerifyData(payload, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) throw Invalid();
            using var data = JsonDocument.Parse(payload, new() { MaxDepth = 8 }); var item = data.RootElement;
            Exact(item, ["schema", "purpose", "component", "platform", "channel", "version", "sequence", "published_at", "expires_at", "package"]);
            if (item.GetProperty("purpose").GetString() != "windows-phone-release" || item.GetProperty("schema").GetInt32() != 1 || item.GetProperty("component").GetString() != "windows-free-phone" || item.GetProperty("platform").GetString() != "windows-x64" || item.GetProperty("channel").GetString() != "stable") throw Invalid();
            var version = item.GetProperty("version").GetString()!; _ = Version(version); var sequence = item.GetProperty("sequence").GetInt64(); if (sequence < minimumSequence || sequence < 1) throw Invalid();
            var clock = now ?? DateTimeOffset.UtcNow;
            var published = Timestamp(item.GetProperty("published_at").GetString()!); var expires = Timestamp(item.GetProperty("expires_at").GetString()!);
            if (published > clock.AddMinutes(5) || expires <= clock || expires <= published || expires - published > TimeSpan.FromDays(366)) throw Invalid();
            var payloadHash = Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant();
            if (sequence == minimumSequence && acceptedPayloadSha256 is not null && payloadHash != acceptedPayloadSha256) throw Invalid();
            var package = item.GetProperty("package"); Exact(package, ["url", "bytes", "sha256", "identity", "publisher"]);
            var target = $"https://github.com/embire2/openwebpbx/releases/download/windows-phone-v{version}/OpenWebPBX-Free-Phone-{version}-win-x64.msixbundle";
            if (package.GetProperty("url").GetString() != target) throw Invalid();
            var bytes = package.GetProperty("bytes").GetInt64(); var sha = package.GetProperty("sha256").GetString()!; var identity = package.GetProperty("identity").GetString()!; var publisher = package.GetProperty("publisher").GetString()!;
            if (identity != expectedIdentity || publisher != expectedPublisher || bytes is < 1000 or > 1073741824 || sha.Length != 64 || sha.Any(c => !char.IsAsciiHexDigitLower(c) && !char.IsAsciiDigit(c)) || identity.Length is < 3 or > 50 || identity.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '-')) || publisher.Length is < 4 or > 500 || !publisher.StartsWith("CN=", StringComparison.Ordinal) || publisher.Any(char.IsControl)) throw Invalid();
            return new ClientRelease(version, sequence, new(target), bytes, sha, identity, publisher) { PayloadSha256 = payloadHash };
        }
        catch (Exception e) when (e is JsonException or FormatException or InvalidOperationException or ArgumentException or KeyNotFoundException) { throw Invalid(); }
    }
    private static DateTimeOffset Timestamp(string value)
    {
        if (value.Length != 20 || !DateTimeOffset.TryParseExact(value, "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var result)) throw Invalid();
        return result;
    }
    private static void Exact(JsonElement value, string[] names) { var fields = value.EnumerateObject().Select(x => x.Name).ToArray(); if (fields.Length != names.Length || fields.Distinct().Count() != fields.Length || fields.Except(names).Any()) throw Invalid(); }
    private static PhoneInputException Invalid() => new("The Windows phone release could not be verified. The current app has been kept.");
}
