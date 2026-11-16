using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenWebPbx.Updater;

// A catalogue has its own monotonic history. Historical step envelopes never
// replace the ordinary release-feed trust watermark.
public sealed record UpgradeCatalogueTrust(long Sequence, string PayloadSha256);
public sealed record VerifiedWindowsUpgradeStep(VerifiedRelease Release, byte[] Envelope, string FeedUrl);
public sealed record VerifiedWindowsUpgradePlan(
    string InstalledVersion, VerifiedRelease Latest, byte[] LatestEnvelope,
    byte[] CatalogueEnvelope, UpgradeCatalogueTrust CatalogueTrust,
    IReadOnlyList<VerifiedWindowsUpgradeStep> Steps)
{
    public TrustState OrdinaryTrustFloor => new(Latest.Sequence, Latest.PayloadSha256);
}

/// <summary>
/// Resolves only publisher-authorised, consecutive Windows release steps.
/// A freshly verified signed catalogue commits to both the ordinary latest
/// release and each exact historical envelope. It is not an instruction to
/// lower the ordinary feed's minimum or its persisted anti-rollback watermark.
/// </summary>
public sealed class WindowsUpgradePlanner(string publicKey)
{
    public const string CatalogueUrl = "https://github.com/embire2/openwebpbx/releases/latest/download/windows-upgrade-path.json";
    private const int MaximumCatalogueBytes = 262144;
    private const int MaximumSteps = 32;
    private readonly ReleaseVerifier releaseVerifier = new(publicKey);
    private static readonly Regex Hash = new("\\A[a-f0-9]{64}\\z", RegexOptions.CultureInvariant);
    private static readonly Regex CanonicalVersion = new("\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\z", RegexOptions.CultureInvariant);

    private sealed record Entry(string PreviousVersion, string Version, string EnvelopeSha256);
    private sealed record Context(VerifiedRelease Latest, UpgradeCatalogueTrust Trust, string MinimumVersion, IReadOnlyList<Entry> Entries);

    public static string PlatformFeedUrl(string version)
    {
        var parsed = ParseVersion(version);
        var tag = parsed <= new Version(1, 0, 21) ? "v" + version : "windows-v" + version;
        return $"https://github.com/embire2/openwebpbx/releases/download/{tag}/windows-update-manifest.json";
    }

    public async Task<VerifiedWindowsUpgradePlan> Resolve(
        string installed, byte[] latestEnvelope, byte[] catalogueEnvelope,
        TrustState? ordinaryTrust, UpgradeCatalogueTrust? catalogueTrust,
        DateTimeOffset now, Func<string, CancellationToken, Task<byte[]>> fetch,
        CancellationToken ct)
    {
        var context = VerifyContext(latestEnvelope, catalogueEnvelope, ordinaryTrust, catalogueTrust, now);
        var remaining = Remaining(context, installed);
        var steps = new List<VerifiedWindowsUpgradeStep>();
        var current = installed;
        foreach (var entry in remaining)
        {
            ct.ThrowIfCancellationRequested();
            var envelope = entry.Version == context.Latest.Version
                ? latestEnvelope : await fetch(PlatformFeedUrl(entry.Version), ct);
            var step = VerifyEntry(context, entry, current, envelope, now);
            steps.Add(step);
            current = step.Release.Version;
        }
        return new(installed, context.Latest, (byte[])latestEnvelope.Clone(),
            (byte[])catalogueEnvelope.Clone(), context.Trust, steps.AsReadOnly());
    }

    /// <summary>
    /// Installer admission for ONE next step. Re-verify this immediately before
    /// extraction/installation, using the actual installation version and the
    /// current ordinary/catalogue trust files. Never accept a caller-selected
    /// later step or treat the public desktop status as authorisation.
    /// </summary>
    public VerifiedWindowsUpgradeStep VerifyNextStep(
        string installed, string target, byte[] stepEnvelope, byte[] latestEnvelope,
        byte[] catalogueEnvelope, TrustState? ordinaryTrust,
        UpgradeCatalogueTrust? catalogueTrust, DateTimeOffset now)
    {
        var context = VerifyContext(latestEnvelope, catalogueEnvelope, ordinaryTrust, catalogueTrust, now);
        var remaining = Remaining(context, installed);
        if (remaining.Count == 0 || target != remaining[0].Version)
            throw new InvalidDataException("Install the next signed Windows release before a later release.");
        return VerifyEntry(context, remaining[0], installed, stepEnvelope, now);
    }

    private VerifiedWindowsUpgradeStep VerifyEntry(Context context, Entry entry, string installed, byte[] envelope, DateTimeOffset now)
    {
        if (envelope.Length > MaximumCatalogueBytes ||
            Convert.ToHexStringLower(SHA256.HashData(envelope)) != entry.EnvelopeSha256)
            throw new InvalidDataException("The Windows step does not match its signed upgrade catalogue.");

        // The lower sequence here is explicitly authorised by the independently
        // verified catalogue and its ordinary-latest binding. No ordinary trust
        // file is read with a null replacement or reset by this class.
        var release = releaseVerifier.Verify(envelope, "windows-x64", null, now);
        ParseVersion(release.Version);
        ParseVersion(release.Asset.MinimumVersion);
        if (release.Version != entry.Version || entry.PreviousVersion != installed)
            throw new InvalidDataException("The Windows step does not follow the installed version.");
        if (release.Version == context.Latest.Version &&
            (release.Sequence != context.Latest.Sequence || release.PayloadSha256 != context.Latest.PayloadSha256))
            throw new InvalidDataException("The last Windows step differs from the verified latest release.");
        ReleaseVerifier.RequireUpgrade(release, installed);
        return new(release, (byte[])envelope.Clone(), PlatformFeedUrl(release.Version));
    }

    private Context VerifyContext(byte[] latestEnvelope, byte[] envelope, TrustState? ordinaryTrust,
        UpgradeCatalogueTrust? previous, DateTimeOffset now)
    {
        if (ordinaryTrust is not null && (ordinaryTrust.Sequence < 1 || !Hash.IsMatch(ordinaryTrust.PayloadSha256)) ||
            previous is not null && (previous.Sequence < 1 || !Hash.IsMatch(previous.PayloadSha256)))
            throw new InvalidDataException("The saved Windows upgrade trust state is invalid; preserve it for administrator recovery.");
        // Ordinary anti-rollback is enforced first, before consulting/fetching
        // any intermediate. The complete latest signed release remains pinned.
        var latest = releaseVerifier.Verify(latestEnvelope, "windows-x64", ordinaryTrust, now);
        ParseVersion(latest.Version);
        ParseVersion(latest.Asset.MinimumVersion);
        if (envelope.Length is < 1 or > MaximumCatalogueBytes)
            throw new InvalidDataException("The Windows upgrade catalogue exceeds its limit.");
        using var outer = JsonDocument.Parse(envelope, new JsonDocumentOptions { MaxDepth = 16 });
        Unique(outer.RootElement);
        Exact(outer.RootElement, "key_id", "payload", "signature");
        if (outer.RootElement.GetProperty("key_id").GetString() != "release-2026-a")
            throw new InvalidDataException("The Windows upgrade signing key is not trusted.");
        var bytes = Convert.FromBase64String(outer.RootElement.GetProperty("payload").GetString()!);
        var signature = Convert.FromBase64String(outer.RootElement.GetProperty("signature").GetString()!);
        using var rsa = RSA.Create();
        rsa.ImportFromPem(publicKey);
        if (!rsa.VerifyData(bytes, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
            throw new InvalidDataException("The Windows upgrade catalogue signature is invalid.");
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 16 });
        var root = document.RootElement;
        Unique(root);
        Exact(root, "schema", "kind", "product", "channel", "platform", "sequence", "published_at", "expires_at",
            "minimum_installed_version", "latest_version", "latest_payload_sha256", "latest_sequence", "steps");
        if (root.GetProperty("schema").GetInt32() != 1 ||
            root.GetProperty("kind").GetString() != "windows-upgrade-path" ||
            root.GetProperty("product").GetString() != "openwebpbx" ||
            root.GetProperty("channel").GetString() != "stable" ||
            root.GetProperty("platform").GetString() != "windows-x64")
            throw new InvalidDataException("The Windows upgrade catalogue format is not supported.");
        var sequence = root.GetProperty("sequence").GetInt64();
        var digest = Convert.ToHexStringLower(SHA256.HashData(bytes));
        if (sequence < 1 || previous is not null &&
            (sequence < previous.Sequence || sequence == previous.Sequence && digest != previous.PayloadSha256))
            throw new InvalidDataException("An older or conflicting Windows upgrade catalogue was refused.");
        var published = root.GetProperty("published_at").GetDateTimeOffset();
        var expires = root.GetProperty("expires_at").GetDateTimeOffset();
        if (published > now.AddMinutes(5) || expires <= now || expires <= published)
            throw new InvalidDataException("The Windows upgrade catalogue is expired or has an invalid date.");
        if (root.GetProperty("latest_version").GetString() != latest.Version ||
            root.GetProperty("latest_sequence").GetInt64() != latest.Sequence ||
            root.GetProperty("latest_payload_sha256").GetString() != latest.PayloadSha256)
            throw new InvalidDataException("The Windows upgrade catalogue does not authorise the verified latest release.");

        var minimum = root.GetProperty("minimum_installed_version").GetString()!;
        ParseVersion(minimum);
        var values = root.GetProperty("steps");
        if (values.ValueKind != JsonValueKind.Array || values.GetArrayLength() is < 1 or > MaximumSteps)
            throw new InvalidDataException("The Windows upgrade path has an invalid number of steps.");
        var entries = new List<Entry>();
        var previousVersion = minimum;
        foreach (var value in values.EnumerateArray())
        {
            Exact(value, "previous_version", "version", "envelope_sha256");
            var from = value.GetProperty("previous_version").GetString()!;
            var version = value.GetProperty("version").GetString()!;
            var hash = value.GetProperty("envelope_sha256").GetString()!;
            if (from != previousVersion || ParseVersion(version) <= ParseVersion(from) || !Hash.IsMatch(hash))
                throw new InvalidDataException("The Windows upgrade path skips or repeats a release.");
            entries.Add(new(from, version, hash));
            previousVersion = version;
        }
        if (previousVersion != latest.Version ||
            entries[^1].EnvelopeSha256 != Convert.ToHexStringLower(SHA256.HashData(latestEnvelope)))
            throw new InvalidDataException("The Windows upgrade path does not end at the verified latest envelope.");
        return new(latest, new(sequence, digest), minimum, entries.AsReadOnly());
    }

    private static IReadOnlyList<Entry> Remaining(Context context, string installed)
    {
        var current = ParseVersion(installed);
        if (current >= ParseVersion(context.Latest.Version)) return Array.Empty<Entry>();
        if (current < ParseVersion(context.MinimumVersion))
            throw new InvalidDataException("This Windows version needs its separately supported legacy transition before automatic upgrades.");
        if (installed != context.MinimumVersion && !context.Entries.Any(entry => entry.Version == installed))
            throw new InvalidDataException("The installed Windows version is not covered by this signed upgrade path.");
        return context.Entries.Where(entry => ParseVersion(entry.Version) > current).ToArray();
    }

    private static Version ParseVersion(string version)
    {
        if (!CanonicalVersion.IsMatch(version)) throw new InvalidDataException("A Windows upgrade version is not canonical.");
        return UpdateJson.Version(version);
    }

    private static void Exact(JsonElement value, params string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Count() != names.Length ||
            value.EnumerateObject().Any(property => !names.Contains(property.Name, StringComparer.Ordinal)))
            throw new InvalidDataException("The Windows upgrade catalogue contains unsupported fields.");
    }

    private static void Unique(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in value.EnumerateObject())
            {
                if (!names.Add(property.Name)) throw new InvalidDataException("Duplicate Windows upgrade fields are not allowed.");
                Unique(property.Value);
            }
        }
        else if (value.ValueKind == JsonValueKind.Array)
            foreach (var child in value.EnumerateArray()) Unique(child);
    }
}
