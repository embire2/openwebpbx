using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;
using OpenWebPbx.Updater;

// Explicit Linux startup regression checks; database, paths and helper children are independently owned.
static class WorkerStartupChecks
{
    private static int checks;
    private static readonly List<string> cases = [];
    private static void Check(bool value, string message)
    { if (!value) throw new Exception(message); checks++; }
    private static async Task Until(Func<Task<bool>> predicate, string message, int seconds = 12)
    {
        var deadline = Stopwatch.StartNew();
        while (deadline.Elapsed < TimeSpan.FromSeconds(seconds))
        { if (await predicate()) return; await Task.Delay(25); }
        throw new TimeoutException(message);
    }
    private static async Task<Exception> Failure(Task operation)
    {
        try { await operation.WaitAsync(TimeSpan.FromSeconds(10)); }
        catch (Exception e) { return e; }
        throw new Exception("An expected actual worker failure did not occur.");
    }
    private static void BusyError(Exception e)
    { Check(e.GetType() == typeof(IOException) && e.Message == "Another update is still completing.", "Public/one-shot busy failure changed."); }

    public static async Task<int> Run(string connection)
    {
        if (!OperatingSystem.IsLinux()) throw new PlatformNotSupportedException("These independent PostgreSQL startup controls are Linux-only.");
        await using (var f = await Fixture.Create(connection, 75))
        {
            f.InstallingJournal();
            await f.Worker.StartAsync(default);
            await f.Busy();
            Check(!f.Worker.ExecuteTask!.IsCompleted, "The service exited on recovery75.");
            await f.NoCommandsOrFeed();
            Check(!File.Exists(f.Paths.FailedInstall), "Busy recovery marked the update as failed.");
            Check(await f.CompetingLock() == 23, "A competing process acquired worker.lock during busy initialization.");
            f.Code(0);
            await Until(async () => await f.CommandStatus(f.Pending) == "completed", "Recovery0 did not permit the real first Tick.");
            Check(f.FeedRequests == 1 && f.Calls >= 2, "Recovery was not retried before first work.");
            Check(await f.CommandStatus(f.Running) == "failed", "Successful initialization did not reconcile the original running request.");
            Check(UpdateJson.Read<UpdateStatus>(f.Paths.Status).State == "available", "Normal signed-feed Tick did not complete after initialization.");
            Check(!File.Exists(f.Paths.FailedInstall), "Successful deferred initialization wrote a false failed-install marker.");
            await f.Stop();
            Check(await f.CompetingLock() == 0, "worker.lock remained owned after service stop.");
            cases.Add("actual helper75 then0; real pending/running rows unchanged until success; signed Tick and lock lifetime");
        }
        await using (var f = await Fixture.Create(connection, 75))
        {
            await f.Worker.StartAsync(default); await f.Busy(); await f.NoCommandsOrFeed();
            var clock = Stopwatch.StartNew(); await f.Stop();
            Check(clock.Elapsed < TimeSpan.FromSeconds(3), "Cancellation waited for the retry delay instead of cancelling it.");
            var calls = f.Calls; await Task.Delay(200);
            Check(f.Calls == calls && f.Worker.ExecuteTask!.IsCompleted, "A helper was launched after cancellation completed.");
            await f.NoCommandsOrFeed();
            Check(await f.CompetingLock() == 0, "Cancellation did not release worker.lock.");
            cases.Add("busy cancellation; no later helper/Tick/claims; cross-process lock released");
        }
        foreach (var code in new[] { 1, 2, 74, 76 })
        {
            await using var f = await Fixture.Create(connection, code); f.InstallingJournal();
            await f.Worker.StartAsync(default);
            var error = await Failure(f.Worker.ExecuteTask!);
            Check(error.GetType() == typeof(IOException) && error.Message == "An interrupted update needs recovery before continuing.", "A non75 recovery error was retried or changed.");
            Check(f.Calls == 1 && f.FeedRequests == 0, "A hard recovery failure performed another helper/Tick.");
            await f.NoCommandsOrFeed();
            Check(UpdateJson.Read<UpdateStatus>(f.Paths.Status).State == "recovery_required", "Hard recovery status changed.");
            var failed = UpdateJson.Read<FailedInstall>(f.Paths.FailedInstall);
            Check(failed.Version == "1.0.14" && failed.AssetSha256 == new string('f', 64), "Hard recovery failed-install marker changed.");
        }
        cases.Add("actual hard recovery1/2/74/76 preserve immediate error/status/marker with no retry/work");
        foreach (var flags in new[] { (false, false), (true, false), (true, true) })
        {
            await using var f = await Fixture.Create(connection, 75);
            f.Worker.OneShot = flags.Item1; f.Worker.CheckOnly = flags.Item2;
            BusyError(await Failure(f.Worker.Initialize(default)));
            Check(f.Calls == 1 && !File.Exists(f.Paths.FailedInstall), "Public Initialize retried75 or recorded a failed installation.");
            await f.NoCommandsOrFeed();
        }
        cases.Add("public Initialize single-attempt75 for service/run-once/check-once flags");
        foreach (var argument in new[] { "--run-once", "--check-once" })
        {
            await using var f = await Fixture.Create(connection, 75);
            Check(await f.CliBusy(argument), "The real one-shot CLI no longer fails immediately on recovery75.");
            Check(f.Calls == 1, "The actual CLI retried its recovery helper.");
            await f.NoCommandsOrFeed();
            Check(await f.CompetingLock() == 0, "The actual one-shot CLI did not release worker.lock.");
        }
        cases.Add("actual updater Program --run-once/--check-once subprocesses preserve immediate75 failure");
        foreach (var flags in new[] { (true, false), (false, true), (true, true) })
        {
            await using var f = await Fixture.Create(connection, 75);
            f.Worker.OneShot = flags.Item1; f.Worker.CheckOnly = flags.Item2;
            await f.Worker.StartAsync(default); BusyError(await Failure(f.Worker.ExecuteTask!));
            Check(f.Calls == 1, "OneShot/CheckOnly service entrypoint retried75."); await f.NoCommandsOrFeed();
        }
        cases.Add("ExecuteAsync OneShot/CheckOnly preserve immediate75 failure");
        foreach (var skip in new[] { false, true })
        {
            await using var f = await Fixture.Create(connection, skip ? 75 : 0);
            f.Worker.OneShot = true; f.Worker.SkipRecovery = skip;
            await f.Worker.StartAsync(default); await f.Worker.ExecuteTask!.WaitAsync(TimeSpan.FromSeconds(8));
            Check(f.Calls == (skip ? 0 : 1), "Normal/SkipRecovery helper count changed.");
            Check(f.FeedRequests == 1 && await f.CommandStatus(f.Pending) == "completed", "Normal/SkipRecovery real Tick did not finish.");
        }
        cases.Add("normal0 and SkipRecovery keep real signed check flow and exact helper counts");
        await using (var f = await Fixture.Create(connection, 75))
        {
            File.Delete(f.Helper); await f.Worker.StartAsync(default);
            Check((await Failure(f.Worker.ExecuteTask!)).GetType() == typeof(FileNotFoundException), "Missing helper was swallowed/retried.");
            Check(f.Calls == 0, "A missing helper was invoked."); await f.NoCommandsOrFeed();
        }
        await using (var f = await Fixture.Create(connection, 75))
        {
            File.WriteAllText(f.Paths.Journal, "{not-json"); await f.Worker.StartAsync(default);
            Check(await Failure(f.Worker.ExecuteTask!) is JsonException, "Malformed journal was swallowed/retried.");
            Check(f.Calls == 0, "Recovery started before malformed journal refusal."); await f.NoCommandsOrFeed();
        }
        cases.Add("missing helper and malformed journal remain hard failures before work");
        Console.WriteLine(JsonSerializer.Serialize(new { state = "passed", platform = "Linux independent PostgreSQL; not native Windows", checks, cases }));
        return checks;
    }

    private sealed class Fixture : IAsyncDisposable
    {
        public Worker Worker { get; }
        public UpdaterPaths Paths { get; }
        public Guid Pending { get; } = Guid.NewGuid();
        public Guid Running { get; } = Guid.NewGuid();
        public int FeedRequests;
        public string Helper { get; }
        private readonly string directory;
        private readonly string schema;
        private readonly string rootConnection;
        private readonly NpgsqlDataSource data;
        private readonly DownloadClient downloads;
        private bool stopped;
        public int Calls => File.Exists(Path.Combine(directory, "calls")) ? File.ReadAllLines(Path.Combine(directory, "calls")).Length : 0;
        private Fixture(string connection, string name, string temporary, NpgsqlDataSource source)
        {
            rootConnection = connection; schema = name; directory = temporary; data = source;
            File.WriteAllText(Path.Combine(directory, "VERSION"), "1.0.13\n"); Helper = Path.Combine(directory, "helper.py");
            var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?> {
                ["Updater:DataDirectory"] = Path.Combine(directory,"updates"), ["Updater:PublicStatus"] = Path.Combine(directory,"public","status.json"),
                ["Updater:InstalledVersionPath"] = Path.Combine(directory,"VERSION"), ["Updater:Helper"] = Helper,
                ["Switch:Host"]="127.0.0.1", ["Switch:Port"]="9", ["Switch:Password"]="owned-unused-fixture" }).Build();
            Paths = new UpdaterPaths(configuration); Paths.Prepare();
            var calls = JsonSerializer.Serialize(Path.Combine(directory,"calls")); var code = JsonSerializer.Serialize(Path.Combine(directory,"code"));
            File.WriteAllText(Helper, "import pathlib,sys\n" +
                "if sys.argv[1:] != ['--recover']: sys.exit(99)\n" +
                "with open(" + calls + ",'a') as out: out.write('recover\\n'); out.flush()\n" +
                "sys.exit(int(pathlib.Path(" + code + ").read_text()))\n");
            using var key = RSA.Create(2048);
            var asset = "owned-startup-fixture"u8.ToArray();
            var payload = JsonSerializer.SerializeToUtf8Bytes(new { schema=1, product="openwebpbx", channel="stable", sequence=1000010,
                version="1.0.14", published_at=DateTimeOffset.UtcNow.AddMinutes(-1), expires_at=DateTimeOffset.UtcNow.AddDays(1),
                assets=new[]{new { platform=Paths.Platform, name="openwebpbx-1.0.14-debian13-amd64.tar.gz",
                    url="https://github.com/embire2/openwebpbx/releases/download/v1.0.14/openwebpbx-1.0.14-debian13-amd64.tar.gz",
                    bytes=asset.Length, sha256=Convert.ToHexStringLower(SHA256.HashData(asset)), minimum_version="1.0.13" }} });
            var envelope = JsonSerializer.SerializeToUtf8Bytes(new { key_id="release-2026-a", payload=Convert.ToBase64String(payload), signature=Convert.ToBase64String(key.SignData(payload,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1)) });
            downloads = new DownloadClient(new Handler(_ => { Interlocked.Increment(ref FeedRequests); return new(HttpStatusCode.OK) { Content=new ByteArrayContent(envelope) }; }));
            Worker = new Worker(new UpdateRepository(data),Paths,new ReleaseVerifier(key.ExportSubjectPublicKeyInfoPem()),downloads,new PlatformInstaller(Paths),new SwitchClient(configuration),NullLogger<Worker>.Instance);
        }
        public static async Task<Fixture> Create(string connection, int exitCode)
        {
            var schema = "startup_"+Guid.NewGuid().ToString("N");
            var directory = Path.Combine(Path.GetTempPath(),"openweb-startup-check-"+Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
            if (OperatingSystem.IsLinux()) File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            await using var root = NpgsqlDataSource.Create(connection);
            await using (var connectionHandle = await root.OpenConnectionAsync())
            { await new NpgsqlCommand("create schema "+schema, connectionHandle).ExecuteNonQueryAsync(); }
            var data = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(connection) { SearchPath=schema+",public" }.ConnectionString);
            await using (var db = await data.OpenConnectionAsync())
            {
                await new NpgsqlCommand("create table v_users(user_uuid uuid primary key);create table v_permissions(permission_uuid uuid,permission_name text,application_name text,application_uuid uuid,permission_description text);create table v_groups(group_uuid uuid,group_name text,domain_uuid uuid);create table v_group_permissions(group_permission_uuid uuid,group_uuid uuid,group_name text,permission_name text,permission_assigned text)",db).ExecuteNonQueryAsync();
                await new NpgsqlCommand(await File.ReadAllTextAsync("app/pbx_updates/resources/install.sql"),db).ExecuteNonQueryAsync();
            }
            var fixture = new Fixture(connection,schema,directory,data); fixture.Code(exitCode);
            await using var command = data.CreateCommand("insert into v_pbx_update_commands(command_uuid,action,status,created_at) values($1,'check','pending',now()-interval '1 minute'),($2,'install','running',now())");
            command.Parameters.AddWithValue(fixture.Pending);command.Parameters.AddWithValue(fixture.Running);await command.ExecuteNonQueryAsync();
            return fixture;
        }
        public void Code(int value) => File.WriteAllText(Path.Combine(directory,"code"),value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        public void InstallingJournal() => UpdateJson.Write(Paths.Journal,new WorkerJournal(Running,"install","1.0.14","installing",DateTimeOffset.UtcNow,new string('f',64)));
        public async Task<string> CommandStatus(Guid id)
        {
            await using var command=data.CreateCommand("select status from v_pbx_update_commands where command_uuid=$1");command.Parameters.AddWithValue(id);
            return (string)(await command.ExecuteScalarAsync())!;
        }
        public async Task NoCommandsOrFeed()
        {
            Check(FeedRequests==0,"Tick reached feed verification before initialization succeeded.");
            Check(await CommandStatus(Pending)=="pending" && await CommandStatus(Running)=="running","Initialization reconciled/claimed commands before successful recovery.");
        }
        public async Task Busy() => await Until(() => Task.FromResult(File.Exists(Paths.Status) && UpdateJson.Read<UpdateStatus>(Paths.Status).State=="installing"),"Actual helper75 status was not observed.");
        public async Task<int> CompetingLock()
        {
            var start=new ProcessStartInfo("/usr/bin/python3") { UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true };
            start.ArgumentList.Add("-c");start.ArgumentList.Add("import fcntl,sys\nf=open(sys.argv[1],'r+b')\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(23)\nsys.exit(0)");start.ArgumentList.Add(Path.Combine(Paths.Data,"worker.lock"));
            using var child=Process.Start(start)!;var stdout=child.StandardOutput.ReadToEndAsync();var stderr=child.StandardError.ReadToEndAsync();
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3));Check((await stdout).Length==0 && (await stderr).Length==0,"Competing lock child unexpectedly emitted output.");return child.ExitCode;
        }
        public async Task<bool> CliBusy(string argument)
        {
            var configuration=Path.Combine(directory,"runtime.json");
            File.WriteAllBytes(configuration,JsonSerializer.SerializeToUtf8Bytes(new {
                Updater=new { DataDirectory=Paths.Data,PublicStatus=Paths.PublicStatus,InstalledVersionPath=Paths.InstalledVersionPath,Helper },
                Switch=new { Host="127.0.0.1",Port=9,Password="owned-unused-fixture" },
                ConnectionStrings=new { Pbx=data.ConnectionString } }));
            var start=new ProcessStartInfo("/opt/dotnet/dotnet") { UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true };
            start.ArgumentList.Add(typeof(Worker).Assembly.Location);start.ArgumentList.Add(argument);start.Environment["OPENWEBPBX_CONFIG"]=configuration;
            using var child=Process.Start(start)!;var stdout=child.StandardOutput.ReadToEndAsync();var stderr=child.StandardError.ReadToEndAsync();
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(8));
            return child.ExitCode!=0 && (await stdout).Length==0 && (await stderr).Contains("System.IO.IOException: Another update is still completing.",StringComparison.Ordinal);
        }
        public async Task Stop()
        {
            using var stop=new CancellationTokenSource(TimeSpan.FromSeconds(3));await Worker.StopAsync(stop.Token);stopped=true;
        }
        public async ValueTask DisposeAsync()
        {
            try { if(!stopped && Worker.ExecuteTask is not null) await Stop(); }
            finally
            {
                Worker.Dispose();downloads.Dispose();await data.DisposeAsync();
                await using var root=NpgsqlDataSource.Create(rootConnection);await using var command=root.CreateCommand("drop schema "+schema+" cascade");await command.ExecuteNonQueryAsync();
                Directory.Delete(directory,true);
            }
        }
    }
    private sealed class Handler(Func<HttpRequestMessage,HttpResponseMessage> response) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)=>Task.FromResult(response(request)); }
}
