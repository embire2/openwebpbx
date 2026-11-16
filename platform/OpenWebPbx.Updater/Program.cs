using Npgsql;
using OpenWebPbx.Server;
using OpenWebPbx.Updater;
using System.Text.Json;
using System.Security.Principal;

var requestInstallation = args.Contains("--request-install", StringComparer.Ordinal);
if (requestInstallation && (args.Length != 1 || !OperatingSystem.IsWindows() ||
    !new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)))
{
    Console.Error.WriteLine("Windows administrator access is required to request a server update."); return 1;
}

var builder = Host.CreateApplicationBuilder(Array.Empty<string>());
var configurationPath = (requestInstallation ? null : Environment.GetEnvironmentVariable("OPENWEBPBX_CONFIG")) ?? (OperatingSystem.IsWindows()
    ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "runtime.json")
    : "/etc/openwebpbx/runtime.json");
builder.Configuration.AddJsonFile(configurationPath, optional: false, reloadOnChange: false);
if (!requestInstallation && (Environment.GetEnvironmentVariable("OPENWEBPBX_UPGRADE_CATALOGUE") is not null || Environment.GetEnvironmentVariable("OPENWEBPBX_UPGRADE_LATEST") is not null))
    builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?> {
        ["Updater:WindowsUpgradePathContext:CataloguePath"] = Environment.GetEnvironmentVariable("OPENWEBPBX_UPGRADE_CATALOGUE"),
        ["Updater:WindowsUpgradePathContext:LatestFeedPath"] = Environment.GetEnvironmentVariable("OPENWEBPBX_UPGRADE_LATEST")
    });
var paths = new UpdaterPaths(builder.Configuration);
var verifier = new ReleaseVerifier(UpdaterPaths.PinnedKey());
if (args.Contains("--verify-windows-upgrade-path", StringComparer.Ordinal))
{
    try
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("This command verifies a Windows installation.");
        string Required(string name) { var index = Array.IndexOf(args, name); if (index < 0 || index + 1 >= args.Length || args.Count(value => value == name) != 1) throw new ArgumentException("A required Windows upgrade argument is missing."); return args[index + 1]; }
        var latestBytes = WindowsUpgradePathContext.ReadProtected(Required("--latest-feed-envelope"));
        var catalogueBytes = WindowsUpgradePathContext.ReadProtected(Required("--upgrade-catalogue"));
        var previous = File.Exists(paths.Trust) ? UpdateJson.Read<TrustState>(paths.Trust) : null;
        var previousCatalogue = File.Exists(paths.WindowsCatalogueTrust) ? UpdateJson.Read<UpgradeCatalogueTrust>(paths.WindowsCatalogueTrust) : null;
        using var downloader = new DownloadClient();
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(3));
        async Task<byte[]> Fetch(string url, CancellationToken ct)
        {
            var tag = new Uri(url).Segments[^2].TrimEnd('/');
            var version = tag.StartsWith("windows-v", StringComparison.Ordinal) ? tag["windows-v".Length..] : tag[1..];
            var index = Array.IndexOf(args, "--historical-feeds");
            return index >= 0 ? WindowsUpgradePathContext.ReadProtected(Path.Combine(Required("--historical-feeds"), version + ".json"))
                : await downloader.HistoricalWindowsFeed(version, ct);
        }
        var plan = await new WindowsUpgradePlanner(UpdaterPaths.PinnedKey()).Resolve(paths.InstalledVersion(), latestBytes, catalogueBytes,
            previous, previousCatalogue, DateTimeOffset.UtcNow, Fetch, deadline.Token);
        Console.WriteLine(JsonSerializer.Serialize(new {
            schema = 1, installed_version = plan.InstalledVersion, latest_version = plan.Latest.Version,
            ordinary_trust_floor = new { sequence = plan.OrdinaryTrustFloor.Sequence, payload_sha256 = plan.OrdinaryTrustFloor.PayloadSha256 },
            catalogue_trust = new { sequence = plan.CatalogueTrust.Sequence, payload_sha256 = plan.CatalogueTrust.PayloadSha256 },
            catalogue_envelope = Convert.ToBase64String(plan.CatalogueEnvelope), latest_feed_envelope = Convert.ToBase64String(plan.LatestEnvelope),
            steps = plan.Steps.Select(step => new { version = step.Release.Version, minimum_version = step.Release.Asset.MinimumVersion,
                sequence = step.Release.Sequence, payload_sha256 = step.Release.PayloadSha256, feed_url = step.FeedUrl,
                envelope = Convert.ToBase64String(step.Envelope), asset = new { platform = step.Release.Asset.Platform,
                    name = step.Release.Asset.Name, url = step.Release.Asset.Url, bytes = step.Release.Asset.Bytes, sha256 = step.Release.Asset.Sha256 } })
        }));
        return 0;
    }
    catch (Exception error) when (error is IOException or InvalidDataException or ArgumentException or JsonException or FormatException or System.Security.Cryptography.CryptographicException or InvalidOperationException or KeyNotFoundException or HttpRequestException or OperationCanceledException or PlatformNotSupportedException)
    { Console.Error.WriteLine("The signed Windows upgrade path could not be verified. The installed application and trust history were not changed."); return 1; }
}
if (args.Contains("--verify-package", StringComparer.Ordinal))
{
    string Argument(string name) { var index = Array.IndexOf(args, name); if (index < 0 || index + 1 >= args.Length) throw new ArgumentException("Required verification argument missing."); return args[index + 1]; }
    try
    {
        paths.Prepare();
        var previous = File.Exists(paths.Trust) ? UpdateJson.Read<TrustState>(paths.Trust) : null;
        var stepBytes = UpdateJson.ReadBytes(Argument("--feed-envelope"), 262144);
        VerifiedRelease release;
        VerifiedWindowsUpgradeStep? authorisedStep = null;
        UpgradeCatalogueTrust? authorisedCatalogue = null;
        TrustState? ordinaryFloor = null;
        if (paths.WindowsUpgradePathContext is { } context)
        {
            var parent = context.Read();
            var catalogueTrust = File.Exists(paths.WindowsCatalogueTrust) ? UpdateJson.Read<UpgradeCatalogueTrust>(paths.WindowsCatalogueTrust) : null;
            var planner = new WindowsUpgradePlanner(UpdaterPaths.PinnedKey());
            authorisedStep = planner.VerifyNextStep(paths.InstalledVersion(), Argument("--target-version"), stepBytes,
                parent.Latest, parent.Catalogue, previous, catalogueTrust, DateTimeOffset.UtcNow);
            release = authorisedStep.Release;
            var latest = verifier.Verify(parent.Latest, "windows-x64", previous, DateTimeOffset.UtcNow);
            ordinaryFloor = new(latest.Sequence, latest.PayloadSha256);
            using var outer = JsonDocument.Parse(parent.Catalogue);
            var payload = Convert.FromBase64String(outer.RootElement.GetProperty("payload").GetString()!);
            using var catalogue = JsonDocument.Parse(payload);
            authorisedCatalogue = new(catalogue.RootElement.GetProperty("sequence").GetInt64(), Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(payload)));
        }
        else release = verifier.Verify(stepBytes, paths.Platform, previous, DateTimeOffset.UtcNow);
        if (release.Version != Argument("--target-version")) throw new InvalidDataException("The requested release does not match signed metadata.");
        ReleaseVerifier.RequireUpgrade(release, paths.InstalledVersion());
        var package = await PackageExtractor.Extract(Argument("--archive"), Argument("--extract-to"), release, CancellationToken.None);
        var nextTrust = ordinaryFloor ?? new TrustState(release.Sequence, release.PayloadSha256);
        if (ordinaryFloor is null || previous != nextTrust) UpdateJson.Write(paths.Trust, nextTrust);
        if (authorisedCatalogue is not null && (!File.Exists(paths.WindowsCatalogueTrust) ||
            UpdateJson.Read<UpgradeCatalogueTrust>(paths.WindowsCatalogueTrust) != authorisedCatalogue))
            UpdateJson.Write(paths.WindowsCatalogueTrust, authorisedCatalogue);
        Console.WriteLine(JsonSerializer.Serialize(new { package_path = package, version = release.Version, sha256 = release.Asset.Sha256 }));
        return 0;
    }
    catch (Exception e) when (e is IOException or InvalidDataException or ArgumentException or JsonException or FormatException or System.Security.Cryptography.CryptographicException or InvalidOperationException or KeyNotFoundException)
    { Console.Error.WriteLine("The signed update package could not be verified. The installed application was not changed."); return 1; }
}
builder.Services.AddWindowsService(options => options.ServiceName = "OpenWebPBXUpdater");
builder.Services.AddSystemd();
builder.Services.Configure<HostOptions>(options => options.ShutdownTimeout = TimeSpan.FromMinutes(2));
builder.Services.AddSingleton(paths); builder.Services.AddSingleton(verifier);
builder.Services.AddSingleton(NpgsqlDataSource.Create(builder.Configuration.GetConnectionString("Pbx") ?? throw new InvalidOperationException("The private instance database connection is required.")));
builder.Services.AddSingleton<UpdateRepository>(); builder.Services.AddSingleton<DownloadClient>(); builder.Services.AddSingleton<PlatformInstaller>(); builder.Services.AddSingleton<SwitchClient>();
var once = args.Contains("--run-once", StringComparer.Ordinal) || args.Contains("--check-once", StringComparer.Ordinal);
builder.Services.AddSingleton<Worker>();
if (!once) builder.Services.AddHostedService(services => services.GetRequiredService<Worker>());
using var host = builder.Build();
if (requestInstallation)
{
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
    try { await host.Services.GetRequiredService<UpdateRepository>().RequestInstallation(deadline.Token); return 0; }
    catch (Exception e) when (e is NpgsqlException or OperationCanceledException or InvalidOperationException)
    { Console.Error.WriteLine("The update request could not be queued. Check the signed-in Updates page."); return 1; }
}
if (once)
{
    paths.Prepare(); using var single = new FileStream(Path.Combine(paths.Data, "worker.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    var worker = host.Services.GetRequiredService<Worker>(); worker.OneShot = true; worker.CheckOnly = args.Contains("--check-once", StringComparer.Ordinal);
    await worker.Initialize(CancellationToken.None); await worker.Tick(CancellationToken.None); return 0;
}
await host.RunAsync(); return 0;
