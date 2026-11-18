using System.Data.Common;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;
using OpenWebPbx.Updater;

// Real worker startup and PostgreSQL state, in an independently owned schema.
// Recovery itself is tested separately; this fixture starts after its result.
static class WindowsRecoveredRequestChecks
{
    public static async Task<int> Run(string connection)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("These checks require Windows updater paths.");
        var checks = 0;
        void Check(bool value, string message) { if (!value) throw new Exception(message); checks++; }
        foreach (var scenario in new[] { "ready", "installing", "waiting_calls", "new-approval", "other-version", "not-install", "invalid-time", "missing-time", "ambiguous-time" })
        {
            var schema = "recovered_request_" + Guid.NewGuid().ToString("N");
            var directory = Path.Combine(Path.GetTempPath(), schema);
            Directory.CreateDirectory(directory);
            await using var root = NpgsqlDataSource.Create(connection);
            await using (var create = root.CreateCommand("create schema " + schema)) await create.ExecuteNonQueryAsync();
            try
            {
                await using var data = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(connection) { SearchPath = schema + ",public" }.ConnectionString);
                await using (var create = data.CreateCommand("create table v_pbx_update_commands(command_uuid uuid primary key,action text,status text,created_at timestamptz,started_at timestamptz,finished_at timestamptz,message text)")) await create.ExecuteNonQueryAsync();
                var id = Guid.NewGuid(); var historical = Guid.NewGuid(); var pending = Guid.NewGuid();
                var now = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                var recoveredAt = now.AddMinutes(-2);
                var requestedAt = scenario == "new-approval" ? now.AddMinutes(-1) : now.AddMinutes(-4);
                var action = scenario == "not-install" ? "check" : "install";
                await using (var insert = data.CreateCommand("insert into v_pbx_update_commands values($1,$2,'running',$3,$3,null,'Owned interrupted request'),($4,'install','completed',$5,$5,$5,'Original completed history'),($6,'check','pending',$5,null,null,'Unclaimed check')"))
                {
                    insert.Parameters.AddWithValue(id); insert.Parameters.AddWithValue(action); insert.Parameters.AddWithValue(requestedAt);
                    insert.Parameters.AddWithValue(historical); insert.Parameters.AddWithValue(now.AddDays(-1)); insert.Parameters.AddWithValue(pending);
                    await insert.ExecuteNonQueryAsync();
                }
                async Task<string> OriginalRows()
                {
                    await using var query = data.CreateCommand("select coalesce(jsonb_agg(to_jsonb(c) order by command_uuid)::text,'[]') from v_pbx_update_commands c where command_uuid<>$1");
                    query.Parameters.AddWithValue(id); return (string)(await query.ExecuteScalarAsync())!;
                }
                var originalRows = await OriginalRows();
                var installed = Path.Combine(directory, "installation.json");
                File.WriteAllText(installed, "{\"Version\":\"1.0.23\"}");
                var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> {
                    ["Updater:DataDirectory"] = Path.Combine(directory, "updates"), ["Updater:PublicStatus"] = Path.Combine(directory, "status.json"),
                    ["Updater:InstalledVersionPath"] = installed, ["Updater:Helper"] = Path.Combine(directory, "unused.ps1"),
                    ["Switch:Host"] = "127.0.0.1", ["Switch:Port"] = "9", ["Switch:Password"] = "owned-unused-fixture"
                }).Build();
                var paths = new UpdaterPaths(configuration); paths.Prepare();
                var sha = new string('a', 64);
                var journal = new WorkerJournal(id, action, "1.0.27", scenario is "installing" or "waiting_calls" ? scenario : "ready", requestedAt, sha);
                UpdateJson.Write(paths.Journal, journal);
                var recovery = new Dictionary<string, object?> { ["state"] = "rolled_back", ["version"] = scenario == "other-version" ? "1.0.26" : "1.0.27", ["updated_at"] = recoveredAt };
                if (scenario == "invalid-time") recovery["updated_at"] = "not-a-time";
                if (scenario == "missing-time") recovery.Remove("updated_at");
                if (scenario == "ambiguous-time") recovery["updated_at"] = recoveredAt.ToString("yyyy-MM-ddTHH:mm:ss");
                UpdateJson.Write(paths.InstallJournal, recovery);
                UpdateJson.Write(paths.WindowsJourney, new WindowsUpgradeJourney(id, "1.0.23", "1.0.27", new string('b', 64), new UpgradeCatalogueTrust(100, new string('c', 64)), requestedAt, requestedAt.AddHours(1)));
                using var key = RSA.Create(2048);
                var requests = 0;
                using var downloads = new DownloadClient(new NoNetwork(() => requests++));
                using var worker = new Worker(new UpdateRepository(data), paths, new ReleaseVerifier(key.ExportSubjectPublicKeyInfoPem()), downloads, new PlatformInstaller(paths), new SwitchClient(configuration), NullLogger<Worker>.Instance) { SkipRecovery = true };
                if (scenario is "invalid-time" or "missing-time" or "ambiguous-time")
                {
                    try { await worker.Initialize(default); throw new Exception("An ambiguous rollback was retried."); }
                    catch (InvalidDataException) { checks++; }
                }
                else await worker.Initialize(default);
                await using var result = data.CreateCommand("select status from v_pbx_update_commands where command_uuid=$1");
                result.Parameters.AddWithValue(id);
                var status = (string)(await result.ExecuteScalarAsync())!;
                var failed = scenario is "ready" or "installing" or "waiting_calls";
                Check(status == (failed ? "failed" : scenario is "invalid-time" or "missing-time" or "ambiguous-time" ? "running" : "pending"), "Wrong recovered-request result: " + scenario);
                if (failed)
                {
                    Check(UpdateJson.Read<FailedInstall>(paths.FailedInstall) == new FailedInstall("1.0.27", sha), "The failed release identity was lost.");
                    Check(UpdateJson.Read<WorkerJournal>(paths.Journal).State == "failed", "The stale ready journal was not completed.");
                    Check(UpdateJson.Read<WindowsUpgradeJourney>(paths.WindowsJourney).State == "failed", "The old approval could still continue.");
                    // A second normal initialization cannot turn the failed row pending.
                    await worker.Initialize(default);
                    Check((string)(await result.ExecuteScalarAsync())! == "failed", "A later startup replayed the failed request.");
                }
                else Check(!File.Exists(paths.FailedInstall), "A later approval or unrelated request inherited the old failure.");
                Check(await OriginalRows() == originalRows, "Unrelated update history or pending requests changed.");
                Check(requests == 0, "Reconciliation downloaded or installed software.");
                Check(paths.InstalledVersion() == "1.0.23", "Reconciliation changed the installed PBX.");
            }
            finally
            {
                await using var drop = root.CreateCommand("drop schema " + schema + " cascade"); await drop.ExecuteNonQueryAsync();
                Directory.Delete(directory, true);
            }
        }
        return checks;
    }
    private sealed class NoNetwork(Action called) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        { called(); throw new Exception("No network request is allowed during recovered-request reconciliation."); }
    }
}
