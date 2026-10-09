using Npgsql;
using OpenWebPbx.Server;
using OpenWebPbx.Updater;
using System.Text.Json;

var builder = Host.CreateApplicationBuilder(Array.Empty<string>());
var configurationPath = Environment.GetEnvironmentVariable("OPENWEBPBX_CONFIG") ?? (OperatingSystem.IsWindows()
    ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "runtime.json")
    : "/etc/openwebpbx/runtime.json");
builder.Configuration.AddJsonFile(configurationPath, optional: false, reloadOnChange: false);
var paths = new UpdaterPaths(builder.Configuration);
var verifier = new ReleaseVerifier(UpdaterPaths.PinnedKey());
if (args.Contains("--verify-package", StringComparer.Ordinal))
{
    string Argument(string name) { var index = Array.IndexOf(args, name); if (index < 0 || index + 1 >= args.Length) throw new ArgumentException("Required verification argument missing."); return args[index + 1]; }
    try
    {
        paths.Prepare();
        var previous = File.Exists(paths.Trust) ? UpdateJson.Read<TrustState>(paths.Trust) : null;
        var release = verifier.Verify(UpdateJson.ReadBytes(Argument("--feed-envelope"), 262144), paths.Platform, previous, DateTimeOffset.UtcNow);
        if (release.Version != Argument("--target-version")) throw new InvalidDataException("The requested release does not match signed metadata.");
        ReleaseVerifier.RequireUpgrade(release, paths.InstalledVersion());
        var package = await PackageExtractor.Extract(Argument("--archive"), Argument("--extract-to"), release, CancellationToken.None);
        UpdateJson.Write(paths.Trust, new TrustState(release.Sequence, release.PayloadSha256));
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
if (once)
{
    paths.Prepare(); using var single = new FileStream(Path.Combine(paths.Data, "worker.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    var worker = host.Services.GetRequiredService<Worker>(); worker.OneShot = true; worker.CheckOnly = args.Contains("--check-once", StringComparer.Ordinal);
    await worker.Initialize(CancellationToken.None); await worker.Tick(CancellationToken.None); return 0;
}
await host.RunAsync(); return 0;
