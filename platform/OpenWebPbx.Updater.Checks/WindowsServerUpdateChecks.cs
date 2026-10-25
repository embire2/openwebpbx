using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;
using OpenWebPbx.Updater;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

static class WindowsServerUpdateChecks
{
    public static async Task<int> Run(string connection)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("These checks require actual Windows PowerShell and Windows file replacement.");
        var count = 0;
        void Check(bool value, string name) { if (!value) throw new Exception(name); count++; }
        var schema = "server_update_" + Guid.NewGuid().ToString("N");
        var directory = Path.Combine(Path.GetTempPath(), schema); Directory.CreateDirectory(directory);
        await using var root = NpgsqlDataSource.Create(connection); await using var db = await root.OpenConnectionAsync();
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(); using var stop = new CancellationTokenSource();
        var active = false;
        var engine = Task.Run(async () => {
            while (!stop.IsCancellationRequested) {
                TcpClient socket;
                try { socket = await listener.AcceptTcpClientAsync(stop.Token); } catch (OperationCanceledException) { break; }
                using (socket) {
                    var stream = socket.GetStream(); await stream.WriteAsync("Content-Type: auth/request\n\n"u8.ToArray());
                    using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen:true);
                    await reader.ReadLineAsync(stop.Token); await reader.ReadLineAsync(stop.Token);
                    await stream.WriteAsync("Content-Type: command/reply\nReply-Text: +OK\n\n"u8.ToArray());
                    await reader.ReadLineAsync(stop.Token); await reader.ReadLineAsync(stop.Token);
                    var reply = active ? "{\"row_count\":1}" : "{\"row_count\":0}";
                    await stream.WriteAsync(Encoding.UTF8.GetBytes($"Content-Type: api/response\nContent-Length: {reply.Length}\n\n{reply}"));
                }
            }
        });
        try {
            await new NpgsqlCommand($"create schema {schema};set search_path to {schema};create table v_users(user_uuid uuid primary key)", db).ExecuteNonQueryAsync();
            var migration = await File.ReadAllTextAsync("app/pbx_updates/resources/install.sql");
            migration = migration[..migration.IndexOf("DO $$\nDECLARE permission", StringComparison.Ordinal)] + "COMMIT;";
            await new NpgsqlCommand(migration, db).ExecuteNonQueryAsync();
            await using var data = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(connection) { SearchPath = schema }.ConnectionString);
            var repository = new UpdateRepository(data);
            var installed = Path.Combine(directory, "installation.json");
            var marker = Path.Combine(directory, "install-count");
            var helper = Path.Combine(directory, "helper.ps1");
            var updates = Path.Combine(directory, "updates");
            void ResetVersion() => File.WriteAllText(installed, "{\"Version\":\"1.0.3\"}");
            ResetVersion();
            static string Quote(string text) => "'" + text.Replace("'", "''") + "'";
            await File.WriteAllTextAsync(helper, "param($Archive,$FeedEnvelope,$TargetVersion,[switch]$Check,[switch]$Recover,[switch]$Automatic)\n$ErrorActionPreference='Stop'\nif($Check -or $Recover){exit 0}\nif($Automatic){throw 'Unrequested automatic install'}\n" +
                "Add-Content -LiteralPath " + Quote(marker) + " -Value installed\n" +
                "[IO.File]::WriteAllText(" + Quote(installed) + ",('{\"Version\":\"'+$TargetVersion+'\"}'))\n" +
                "[IO.File]::WriteAllText(" + Quote(Path.Combine(updates,"install-journal.json")) + ",' {\"state\":\"completed\"}')\n");
            var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?> {
                ["Updater:DataDirectory"]=updates, ["Updater:PublicStatus"]=Path.Combine(directory,"public-status.json"),
                ["Updater:InstalledVersionPath"]=installed, ["Updater:Helper"]=helper,
                ["Switch:Host"]="127.0.0.1", ["Switch:Port"]=((IPEndPoint)listener.LocalEndpoint).Port.ToString(), ["Switch:Password"]="owned-fixture"
            }).Build();
            var paths = new UpdaterPaths(configuration); paths.Prepare();
            using var rsa = RSA.Create(2048); var verifier = new ReleaseVerifier(rsa.ExportSubjectPublicKeyInfoPem());
            var clock = new TestClock(); var bytes = "owned-windows-update-fixture"u8.ToArray();
            var payload = JsonSerializer.SerializeToUtf8Bytes(new { schema=1, product="openwebpbx", channel="stable", sequence=104,
                version="1.0.4", published_at=clock.GetUtcNow().AddMinutes(-1), expires_at=clock.GetUtcNow().AddDays(1),
                assets=new[] {new {platform="windows-x64",name="openwebpbx-1.0.4-windows-x64.zip",url="https://github.com/embire2/openwebpbx/releases/download/v1.0.4/openwebpbx-1.0.4-windows-x64.zip",
                    bytes=bytes.Length,sha256=Convert.ToHexStringLower(SHA256.HashData(bytes)),minimum_version="1.0.3"}} });
            var envelope = JsonSerializer.SerializeToUtf8Bytes(new {key_id="release-2026-a",payload=Convert.ToBase64String(payload),signature=Convert.ToBase64String(rsa.SignData(payload,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1))});
            int feeds=0, downloadsCount=0; bool corrupt=false;
            using var downloads = new DownloadClient(new Handler(request => {
                var feed = request.RequestUri!.AbsoluteUri == UpdaterPaths.WindowsFeedUrl;
                if (feed) feeds++; else downloadsCount++;
                var content = feed ? corrupt ? "invalid"u8.ToArray() : envelope : bytes;
                return new(HttpStatusCode.OK) { Content = new ByteArrayContent(content) };
            }));
            Worker Fresh() => new(repository,paths,verifier,downloads,new PlatformInstaller(paths),new SwitchClient(configuration),NullLogger<Worker>.Instance,clock) {OneShot=true,SkipRecovery=true};
            UpdateStatus Status() => UpdateJson.Read<UpdateStatus>(paths.Status);
            var worker=Fresh(); await worker.Initialize(default); await worker.Tick(default);
            Check(Status() is {State:"ready",UpdateRequired:true,DownloadReady:true,AvailableVersion:"1.0.4"}, "Windows default did not download and prepare a required update");
            Check(feeds==1 && downloadsCount==1 && !File.Exists(marker) && paths.InstalledVersion()=="1.0.3", "Detection stopped or installed the running version");
            clock.Advance(TimeSpan.FromSeconds(299)); await worker.Tick(default);
            Check(feeds==1 && !File.Exists(marker), "Postponement installed the update or polled prematurely");
            clock.Advance(TimeSpan.FromSeconds(1)); await worker.Tick(default);
            Check(feeds==2 && downloadsCount==1 && Status().State=="ready", "Five-minute polling or cached download reuse failed");
            await new NpgsqlCommand("update v_pbx_update_policies set mode='automatic' where scope_key='instance'", db).ExecuteNonQueryAsync();
            clock.Advance(TimeSpan.FromMinutes(5)); await worker.Tick(default);
            Check(feeds==3 && !File.Exists(marker) && paths.InstalledVersion()=="1.0.3", "A previous automatic policy ignored postponement");
            await Task.WhenAll(repository.RequestInstallation(default),repository.RequestInstallation(default));
            Check((long)(await new NpgsqlCommand("select count(*) from v_pbx_update_commands where action='install'",db).ExecuteScalarAsync())! == 1, "Desktop installation request was duplicated");
            active=true; await worker.Tick(default);
            Check(Status().State=="waiting_calls" && !File.Exists(marker), "Installation did not wait for the active call");
            active=false; await worker.Tick(default);
            Check(Status() is {State:"completed",UpdateRequired:false,DownloadReady:false} && paths.InstalledVersion()=="1.0.4" && File.Exists(marker), "Unattended explicit installation did not complete");
            Check(File.ReadAllBytes(paths.Status).SequenceEqual(File.ReadAllBytes(paths.PublicStatus)), "Desktop and database worker status diverged");
            ResetVersion(); File.Delete(marker); corrupt=true;
            worker=Fresh(); await worker.Initialize(default); await worker.Tick(default);
            Check(Status() is {State:"error",UpdateRequired:true,DownloadReady:false} && !File.Exists(marker), "Failed refresh discarded the verified notice or installed untrusted bytes");
            var before=feeds; clock.Advance(TimeSpan.FromSeconds(299)); await worker.Tick(default);
            Check(feeds==before, "Failed feed ignored its five-minute retry bound");
            corrupt=false; clock.Advance(TimeSpan.FromSeconds(1)); await worker.Tick(default);
            Check(feeds==before+1 && Status() is {State:"ready",UpdateRequired:true} && !File.Exists(marker), "Failed refresh did not recover at the next five-minute check");
            await new NpgsqlCommand("insert into v_pbx_update_commands(command_uuid,action) values(gen_random_uuid(),'check')",db).ExecuteNonQueryAsync();
            try { await repository.RequestInstallation(default); throw new Exception("Conflicting command accepted"); }
            catch (InvalidOperationException) { Check((long)(await new NpgsqlCommand("select count(*) from v_pbx_update_commands where status='pending'",db).ExecuteScalarAsync())! == 1, "Local request changed the conflicting queue"); }
        } finally {
            stop.Cancel(); listener.Stop(); await engine;
            await new NpgsqlCommand($"set search_path to public;drop schema if exists {schema} cascade", db).ExecuteNonQueryAsync();
            Directory.Delete(directory,true);
        }
        return count;
    }
    private sealed class TestClock : TimeProvider
    {
        private DateTimeOffset value=DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow()=>value;
        public void Advance(TimeSpan amount)=>value+=amount;
    }
}
