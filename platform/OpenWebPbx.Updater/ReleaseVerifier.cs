using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenWebPbx.Updater;

public sealed partial class ReleaseVerifier(string publicKey)
{
    public const long MaximumArchiveBytes = 4L * 1024 * 1024 * 1024;
    [GeneratedRegex("^[a-f0-9]{64}$", RegexOptions.CultureInvariant)] private static partial Regex HashPattern();
    public VerifiedRelease Verify(byte[] envelope, string platform, TrustState? previous, DateTimeOffset now)
    {
        if (envelope.Length > 262144) throw new InvalidDataException("Release metadata exceeds its limit.");
        using var outer = JsonDocument.Parse(envelope, new JsonDocumentOptions { MaxDepth = 16 });
        Unique(outer.RootElement);
        if (outer.RootElement.EnumerateObject().Count() != 3 || outer.RootElement.GetProperty("key_id").GetString() != "release-2026-a") throw new InvalidDataException("The release signing key is not trusted.");
        var bytes = Convert.FromBase64String(outer.RootElement.GetProperty("payload").GetString()!);
        var signature = Convert.FromBase64String(outer.RootElement.GetProperty("signature").GetString()!);
        using var rsa = RSA.Create(); rsa.ImportFromPem(publicKey);
        if (!rsa.VerifyData(bytes, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) throw new InvalidDataException("The release signature is invalid.");
        using var payload = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 16 });
        var root = payload.RootElement; Unique(root);
        if (root.GetProperty("schema").GetInt32() != 1 || root.GetProperty("product").GetString() != "openwebpbx" || root.GetProperty("channel").GetString() != "stable") throw new InvalidDataException("The release format is not supported.");
        var sequence = root.GetProperty("sequence").GetInt64();
        var digest = Convert.ToHexStringLower(SHA256.HashData(bytes));
        if (sequence < 1 || (previous is not null && (sequence < previous.Sequence || sequence == previous.Sequence && digest != previous.PayloadSha256))) throw new InvalidDataException("The release feed is older than previously verified metadata.");
        var published = root.GetProperty("published_at").GetDateTimeOffset();
        var expires = root.GetProperty("expires_at").GetDateTimeOffset();
        if (published > now.AddMinutes(5) || expires <= now || expires <= published) throw new InvalidDataException("The release metadata is expired or has an invalid date.");
        var version = root.GetProperty("version").GetString()!; UpdateJson.Version(version);
        var assets = root.GetProperty("assets").EnumerateArray().ToArray();
        if (assets.Length is < 1 or > 8 || assets.Select(a => a.GetProperty("platform").GetString()).Distinct().Count() != assets.Length) throw new InvalidDataException("The release platform list is invalid.");
        var matching = assets.Where(a => a.GetProperty("platform").GetString() == platform).ToArray();
        if (matching.Length != 1) throw new InvalidDataException("This release does not support this server architecture.");
        var item = matching[0];
        var name = $"openwebpbx-{version}-{platform}" + (platform == "windows-x64" ? ".zip" : ".tar.gz");
        var url = $"https://github.com/embire2/openwebpbx/releases/download/v{version}/{name}";
        var length = item.GetProperty("bytes").GetInt64(); var hash = item.GetProperty("sha256").GetString()!;
        var minimum = item.GetProperty("minimum_version").GetString()!; UpdateJson.Version(minimum);
        if (item.GetProperty("name").GetString() != name || item.GetProperty("url").GetString() != url || length is < 1 or > MaximumArchiveBytes || !HashPattern().IsMatch(hash)) throw new InvalidDataException("The release download details are invalid.");
        return new(version, sequence, digest, published, expires, new(platform, name, url, length, hash, minimum));
    }
    public static void RequireUpgrade(VerifiedRelease release, string installed)
    {
        if (UpdateJson.Version(release.Version) <= UpdateJson.Version(installed)) throw new InvalidDataException("A newer signed release is required.");
        if (UpdateJson.Version(installed) < UpdateJson.Version(release.Asset.MinimumVersion)) throw new InvalidDataException("This release requires an intermediate manual upgrade.");
    }
    private static void Unique(JsonElement item)
    {
        if (item.ValueKind == JsonValueKind.Object)
        {
            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in item.EnumerateObject()) { if (!keys.Add(property.Name)) throw new InvalidDataException("Duplicate release metadata fields are not allowed."); Unique(property.Value); }
        }
        else if (item.ValueKind == JsonValueKind.Array) foreach (var child in item.EnumerateArray()) Unique(child);
    }
    public static async Task VerifyArchive(string path, ReleaseAsset asset, CancellationToken ct)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length != asset.Bytes) throw new InvalidDataException("The update download is incomplete.");
        if (Convert.ToHexStringLower(await SHA256.HashDataAsync(file, ct)) != asset.Sha256) throw new InvalidDataException("The update checksum is invalid.");
    }
}
