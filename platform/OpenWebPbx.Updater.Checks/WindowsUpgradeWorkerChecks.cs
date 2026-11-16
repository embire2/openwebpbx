using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;
using OpenWebPbx.Updater;
using System.Net;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

public static class WindowsUpgradeWorkerChecks
{
    public static async Task<int> Run(string connection)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("These checks require Windows PowerShell and ACLs.");
        var count = 0;
        void Check(bool value, string message) { count++; if (!value) throw new Exception(message); }
        var schema = "windows_chain_" + Guid.NewGuid().ToString("N");
        var directory = Path.Combine(Path.GetTempPath(), schema); Directory.CreateDirectory(directory);
        await using var source = NpgsqlDataSource.Create(connection);
        await using var db = await source.OpenConnectionAsync();
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        using var stop = new CancellationTokenSource();
        var busy = false;
        var engine = Task.Run(async () => {
            while (!stop.IsCancellationRequested)
            {
                TcpClient socket;
                try { socket = await listener.AcceptTcpClientAsync(stop.Token); } catch (OperationCanceledException) { break; }
                using (socket)
                {
                    var stream = socket.GetStream(); await stream.WriteAsync("Content-Type: auth/request\n\n"u8.ToArray());
                    using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
                    await reader.ReadLineAsync(stop.Token); await reader.ReadLineAsync(stop.Token);
                    await stream.WriteAsync("Content-Type: command/reply\nReply-Text: +OK\n\n"u8.ToArray());
                    await reader.ReadLineAsync(stop.Token); await reader.ReadLineAsync(stop.Token);
                    var reply = busy ? "{\"row_count\":1}" : "{\"row_count\":0}";
                    await stream.WriteAsync(Encoding.UTF8.GetBytes($"Content-Type: api/response\nContent-Length: {reply.Length}\n\n{reply}"));
                }
            }
        });
        try
        {
            await new NpgsqlCommand($"create schema {schema};set search_path to {schema};create table v_users(user_uuid uuid primary key)", db).ExecuteNonQueryAsync();
            var sql = await File.ReadAllTextAsync("app/pbx_updates/resources/install.sql");
            sql = sql[..sql.IndexOf("DO $$\nDECLARE permission", StringComparison.Ordinal)] + "COMMIT;";
            await new NpgsqlCommand(sql, db).ExecuteNonQueryAsync();
            await using var data = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(connection) { SearchPath = schema }.ConnectionString);
            var repository = new UpdateRepository(data);
            var installed = Path.Combine(directory, "installation.json");
            var helper = Path.Combine(directory, "helper.ps1");
            var marker = Path.Combine(directory, "installed-steps.txt");
            var updates = Path.Combine(directory, "updates"); Directory.CreateDirectory(updates);
            var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
            foreach (var sid in new[] { "S-1-5-18", "S-1-5-32-544" })
                acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            new DirectoryInfo(updates).SetAccessControl(acl);
            void Reset() => File.WriteAllText(installed, "{\"Version\":\"1.0.21\"}");
            Reset();
            static string Q(string value) => "'" + value.Replace("'", "''") + "'";
            await File.WriteAllTextAsync(helper,
                "param($Archive,$FeedEnvelope,$TargetVersion,[switch]$Check,[switch]$Recover,[switch]$Automatic)\n$ErrorActionPreference='Stop'\nif($Recover){exit 0}\n" +
                "if(!$env:OPENWEBPBX_UPGRADE_CATALOGUE -or !$env:OPENWEBPBX_UPGRADE_LATEST){throw 'Missing parent authorisation'}\nif($Check){exit 0}\nif($Automatic){throw 'Unapproved installation'}\n" +
                "Add-Content -LiteralPath " + Q(marker) + " -Value $TargetVersion\n" +
                "[IO.File]::WriteAllText(" + Q(installed) + ",('{\"Version\":\"'+$TargetVersion+'\"}'))\n" +
                "[IO.File]::WriteAllText(" + Q(Path.Combine(updates, "install-journal.json")) + ",' {\"state\":\"completed\"}')\n");
            var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> {
                ["Updater:DataDirectory"] = updates, ["Updater:PublicStatus"] = Path.Combine(directory, "public-status.json"),
                ["Updater:InstalledVersionPath"] = installed, ["Updater:Helper"] = helper,
                ["Switch:Host"] = "127.0.0.1", ["Switch:Port"] = ((IPEndPoint)listener.LocalEndpoint).Port.ToString(), ["Switch:Password"] = "owned-fixture"
            }).Build();
            var paths = new UpdaterPaths(config); paths.Prepare();
            using var key = RSA.Create(2048); var verifier = new ReleaseVerifier(key.ExportSubjectPublicKeyInfoPem());
            var now = DateTimeOffset.UtcNow;
            byte[] Sign(object value) { var bytes = JsonSerializer.SerializeToUtf8Bytes(value); return JsonSerializer.SerializeToUtf8Bytes(new { key_id = "release-2026-a", payload = Convert.ToBase64String(bytes), signature = Convert.ToBase64String(key.SignData(bytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) }); }
            string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
            var assets = new Dictionary<string, byte[]> { ["1.0.22"] = "owned-step22"u8.ToArray(), ["1.0.23"] = "owned-step23"u8.ToArray() };
            byte[] Feed(string version, string minimum, int sequence) => Sign(new { schema = 1, product = "openwebpbx", channel = "stable", sequence, version,
                published_at = now.AddMinutes(-1), expires_at = now.AddDays(1), assets = new[] { new { platform = "windows-x64", name = $"openwebpbx-{version}-windows-x64.zip", url = $"https://github.com/embire2/openwebpbx/releases/download/v{version}/openwebpbx-{version}-windows-x64.zip", bytes = assets[version].Length, sha256 = Hash(assets[version]), minimum_version = minimum } } });
            var first = Feed("1.0.22", "1.0.21", 122); var latestBytes = Feed("1.0.23", "1.0.22", 123);
            var latest = verifier.Verify(latestBytes, "windows-x64", null, now);
            var catalogue = Sign(new { schema = 1, kind = "windows-upgrade-path", product = "openwebpbx", channel = "stable", platform = "windows-x64", sequence = 501,
                published_at = now.AddMinutes(-1), expires_at = now.AddDays(1), minimum_installed_version = "1.0.21", latest_version = latest.Version, latest_sequence = latest.Sequence, latest_payload_sha256 = latest.PayloadSha256,
                steps = new[] { new { previous_version = "1.0.21", version = "1.0.22", envelope_sha256 = Hash(first) }, new { previous_version = "1.0.22", version = "1.0.23", envelope_sha256 = Hash(latestBytes) } } });
            UpdateJson.Write(paths.Trust, new TrustState(latest.Sequence, latest.PayloadSha256));
            var originalFloor = File.ReadAllBytes(paths.Trust);
            var requested = new List<string>();
            var catalogueUnavailable = false;
            using var downloads = new DownloadClient(new Handler(request => {
                var url = request.RequestUri!.AbsoluteUri; requested.Add(url);
                if (url == WindowsUpgradePlanner.CatalogueUrl && catalogueUnavailable) return new(HttpStatusCode.NotFound);
                var bytes = url == UpdaterPaths.WindowsFeedUrl ? latestBytes : url == WindowsUpgradePlanner.CatalogueUrl ? catalogue :
                    url == WindowsUpgradePlanner.PlatformFeedUrl("1.0.22") ? first : url.Contains("openwebpbx-1.0.22-windows-x64.zip", StringComparison.Ordinal) ? assets["1.0.22"] : assets["1.0.23"];
                return new(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };
            }));
            Worker Fresh() => new(repository, paths, verifier, downloads, new PlatformInstaller(paths), new SwitchClient(config), NullLogger<Worker>.Instance) { OneShot = true, SkipRecovery = true };
            UpdateStatus Status() => UpdateJson.Read<UpdateStatus>(paths.Status);
            var worker = Fresh(); await worker.Initialize(default); await worker.Tick(default);
            Check(Status() is { State: "ready", AvailableVersion: "1.0.22", DownloadReady: true }, "21 did not prepare22 first");
            Check(!File.Exists(marker) && !File.Exists(paths.WindowsJourney), "Downloading approved an installation");
            Check(File.ReadAllBytes(paths.Trust).SequenceEqual(originalFloor), "Intermediate preparation lowered ordinary trust");
            Check(requested.Contains(WindowsUpgradePlanner.PlatformFeedUrl("1.0.22")) && !requested.Any(url => url.Contains("/download/v1.0.22/windows-update", StringComparison.Ordinal)), "Worker fetched canonical22's stale feed");
            await Task.WhenAll(repository.RequestInstallation(default), repository.RequestInstallation(default));
            busy = true; await worker.Tick(default);
            Check(Status().State == "waiting_calls" && !File.Exists(marker), "Chain interrupted an active call");
            var journey = UpdateJson.Read<WindowsUpgradeJourney>(paths.WindowsJourney);
            Check(journey is { FromVersion: "1.0.21", TargetVersion: "1.0.23", State: "active" }, "Finite chain approval was not persisted");
            busy = false; await worker.Tick(default);
            Check(paths.InstalledVersion() == "1.0.22" && File.ReadAllLines(marker).SequenceEqual(new[] { "1.0.22" }), "First step skipped or duplicated a release");
            Check((string)(await new NpgsqlCommand("select status from v_pbx_update_commands where action='install'", db).ExecuteScalarAsync())! == "running", "Approval completed before the last step");
            var beforeResume = requested.Count;
            worker = Fresh(); await worker.Initialize(default); await worker.Tick(default);
            Check(paths.InstalledVersion() == "1.0.23" && Status().State == "completed", "Restart did not continue23 automatically");
            Check(File.ReadAllLines(marker).SequenceEqual(new[] { "1.0.22", "1.0.23" }), "Restart skipped/repeated a release");
            Check(requested.Skip(beforeResume).All(url => url.Contains("openwebpbx-1.0.23-windows-x64.zip", StringComparison.Ordinal)), "Restart changed the approved parent catalogue/latest offer");
            Check((long)(await new NpgsqlCommand("select count(*) from v_pbx_update_commands where action='install'", db).ExecuteScalarAsync())! == 1, "Chain created extra installation approvals");
            Check(UpdateJson.Read<WindowsUpgradeJourney>(paths.WindowsJourney).State == "completed", "Completed approval remained active");
            Check(File.ReadAllBytes(paths.Trust).SequenceEqual(originalFloor), "Chain changed the original latest trust floor");
            // A private journey file is insufficient: the original approved DB
            // command must still exist and be pending/running.
            UpdateJson.Write(paths.WindowsJourney, journey);
            Reset(); File.Delete(marker);
            worker = Fresh(); await worker.Initialize(default); await worker.Tick(default);
            Check(!File.Exists(marker) && Status().State == "ready", "A completed DB command replayed an old private approval");
            // Once signed ordering has been observed, a missing remote catalogue
            // cannot turn a chain-aware installation back into a direct update.
            catalogueUnavailable = true;
            File.Delete(paths.WindowsJourney);
            File.WriteAllText(installed, "{\"Version\":\"1.0.22\"}");
            var retainedCatalogue = File.ReadAllBytes(paths.WindowsCatalogue);
            File.Delete(paths.WindowsCatalogue);
            worker = Fresh(); await worker.Initialize(default); await worker.Tick(default);
            Check(Status().State == "error" && !File.Exists(marker), "Missing catalogue bypassed retained catalogue trust");
            UpdateJson.WriteBytes(paths.WindowsCatalogue, retainedCatalogue);
            File.Delete(paths.WindowsCatalogueTrust);
            worker = Fresh(); await worker.Initialize(default); await worker.Tick(default);
            Check(Status().State == "error" && !File.Exists(marker), "Missing catalogue bypassed retained signed catalogue");
        }
        finally
        {
            stop.Cancel(); listener.Stop(); await engine;
            await new NpgsqlCommand($"set search_path to public;drop schema if exists {schema} cascade", db).ExecuteNonQueryAsync();
            Directory.Delete(directory, true);
        }
        return count;
    }
}
