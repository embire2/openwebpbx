using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

// CLI-only isolated PostgreSQL schema and loopback engine. Credentials are supplied
// privately in the environment and are never written to output or tracked files.
var connection = Environment.GetEnvironmentVariable("OPENWEB_TEST_DATABASE");
if (string.IsNullOrWhiteSpace(connection)) { Console.Error.WriteLine("OPENWEB_TEST_DATABASE is required for the isolated status worker checks."); return 2; }
int checks = 0;
void Check(bool condition, string message) { if (!condition) throw new Exception(message); checks++; }
await using var root = NpgsqlDataSource.Create(connection);
await using var db = await root.OpenConnectionAsync();
var schema = "mobile_status_worker_" + Guid.NewGuid().ToString("N");
var server = new TcpListener(IPAddress.Loopback, 0); server.Start();
using var stop = new CancellationTokenSource();
var commands = new ConcurrentQueue<string>(); var replies = new ConcurrentQueue<string>();
var fakeEngine = Task.Run(async () => {
    try {
        while (!stop.IsCancellationRequested) {
            using var socket = await server.AcceptTcpClientAsync(stop.Token);
            var stream = socket.GetStream();
            await stream.WriteAsync("Content-Type: auth/request\n\n"u8.ToArray());
            var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
            await reader.ReadLineAsync(); await reader.ReadLineAsync();
            await stream.WriteAsync("Content-Type: command/reply\nReply-Text: +OK accepted\n\n"u8.ToArray());
            var command = await reader.ReadLineAsync() ?? ""; await reader.ReadLineAsync(); commands.Enqueue(command);
            var response = replies.TryDequeue(out var queued) ? queued : "+OK Phone status refreshed.\n";
            await stream.WriteAsync(Encoding.UTF8.GetBytes($"Content-Type: api/response\nContent-Length: {Encoding.UTF8.GetByteCount(response)}\n\n{response}"));
        }
    } catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
});
try {
    await new NpgsqlCommand($"create schema {schema}; set search_path to {schema},public", db).ExecuteNonQueryAsync();
    foreach (var table in new[] { "v_domains", "v_extensions", "v_pbx_restore", "v_pbx_mobile_presence" })
        await new NpgsqlCommand($"create table {table}(like public.{table} including all)", db).ExecuteNonQueryAsync();
    var domains = new[] { Guid.NewGuid(), Guid.NewGuid() }; var extensions = new[] { Guid.NewGuid(), Guid.NewGuid() };
    for (var i = 0; i < 2; i++) {
        await using var insert = new NpgsqlCommand("with domain as (insert into v_domains(domain_uuid,domain_name,domain_enabled) values($1,$2,'true') returning domain_uuid) insert into v_extensions(domain_uuid,extension_uuid,extension,enabled) select domain_uuid,$3,'ow-1000',true from domain", db);
        insert.Parameters.AddWithValue(domains[i]); insert.Parameters.AddWithValue($"worker-{i}.invalid"); insert.Parameters.AddWithValue(extensions[i]); await insert.ExecuteNonQueryAsync();
    }
    var cs = new NpgsqlConnectionStringBuilder(connection) { SearchPath = schema + ",public", ApplicationName = schema + "_expiry" };
    await using var data = NpgsqlDataSource.Create(cs.ConnectionString);
    var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Switch:Port"] = ((IPEndPoint)server.LocalEndpoint).Port.ToString(), ["Switch:Password"] = "test-only" }).Build();
    var worker = new MobileStateWorker(data, new SwitchClient(configuration), NullLogger<MobileStateWorker>.Instance);
    async Task Seed(int i, long epoch, string selection = "Away", bool marker = true, Guid? configExtension = null) {
        var user = new JsonObject { ["extension_uuid"] = (configExtension ?? extensions[i]).ToString(), ["profile"] = selection,
            ["profiles"] = new JsonObject { ["Available"] = new JsonObject(), ["Away"] = new JsonObject(), ["Do Not Disturb"] = new JsonObject() } };
        if (marker) user["mobile_temporary"] = new JsonObject { ["previous"] = "Available", ["target"] = "Away", ["expires"] = epoch };
        var config = new JsonObject { ["users"] = new JsonObject { ["1000"] = user } };
        await using var insert = new NpgsqlCommand("with restored as (insert into v_pbx_restore(domain_uuid,source_version,config) values($1,'check',$3::jsonb) on conflict(domain_uuid) do update set config=excluded.config returning domain_uuid) insert into v_pbx_mobile_presence(domain_uuid,extension_uuid,number,previous_profile,target_profile,expires_at) select domain_uuid,$2,'1000','Available','Away',to_timestamp($4) from restored on conflict(domain_uuid,extension_uuid) do update set previous_profile=excluded.previous_profile,target_profile=excluded.target_profile,expires_at=excluded.expires_at", db);
        insert.Parameters.AddWithValue(domains[i]); insert.Parameters.AddWithValue(extensions[i]); insert.Parameters.AddWithValue(config.ToJsonString()); insert.Parameters.AddWithValue(epoch); await insert.ExecuteNonQueryAsync();
    }
    async Task<JsonNode> User(int i) { await using var read = new NpgsqlCommand("select config::text from v_pbx_restore where domain_uuid=$1", db); read.Parameters.AddWithValue(domains[i]); return JsonNode.Parse((string)(await read.ExecuteScalarAsync())!)!["users"]!["1000"]!; }
    async Task<long> Count(int i) { await using var read = new NpgsqlCommand("select count(*) from v_pbx_mobile_presence where domain_uuid=$1", db); read.Parameters.AddWithValue(domains[i]); return (long)(await read.ExecuteScalarAsync())!; }
    var past = DateTimeOffset.UtcNow.AddSeconds(-30).ToUnixTimeSeconds(); var future = DateTimeOffset.UtcNow.AddMinutes(15).ToUnixTimeSeconds();
    await Seed(0, past); await Seed(1, future); var foreign = (await User(1)).ToJsonString();
    await Task.WhenAll(worker.Tick(default), worker.Tick(default));
    var user = await User(0);
    Check(user["profile"]!.GetValue<string>() == "Available" && user["mobile_temporary"] is null, "Expired status restores previous selection and removes marker");
    Check(await Count(0) == 0, "Successful native synchronization removes expiry");
    Check((await User(1)).ToJsonString() == foreign && await Count(1) == 1, "Foreign tenant and future expiry remain unchanged");
    Check(commands.All(c => c == $"api lua app/pbx_setup/mobile_state.lua {domains[0]} 1000"), "Native synchronization is restricted to the expired user's tenant");
    await Seed(0, past, "Do Not Disturb"); await worker.Tick(default); user = await User(0);
    Check(user["profile"]!.GetValue<string>() == "Do Not Disturb" && user["mobile_temporary"] is null, "Admin override survives expiry");
    await Seed(0, past, marker: false); await worker.Tick(default);
    Check((await User(0))["profile"]!.GetValue<string>() == "Away", "Removed Admin marker prevents old expiry restoration");
    await Seed(0, past, configExtension: Guid.NewGuid()); await worker.Tick(default); user = await User(0);
    Check(user["profile"]!.GetValue<string>() == "Away" && user["mobile_temporary"] is not null, "Replaced extension UUID cannot inherit an old expiry");
    await Seed(0, past); replies.Enqueue("-ERR assigned agent temporarily unavailable\n"); await worker.Tick(default);
    Check((await User(0))["profile"]!.GetValue<string>() == "Available" && await Count(0) == 1, "Failed native synchronization preserves durable retry after restoring Admin state");
    await worker.Tick(default); Check(await Count(0) == 0, "Next tick recovers native synchronization and clears expiry");
    // Hold the same lock the phone API uses. Renew while the worker waits so its
    // initially selected expired row cannot undo the newer temporary selection.
    await Seed(0, past);
    await using (var api = await data.OpenConnectionAsync()) await using (var transaction = await api.BeginTransactionAsync()) {
        await using var rowLock = new NpgsqlCommand("select config from v_pbx_restore where domain_uuid=$1 for update", api, transaction); rowLock.Parameters.AddWithValue(domains[0]); await rowLock.ExecuteScalarAsync();
        var tick = worker.Tick(default); var lockDeadline = DateTime.UtcNow.AddSeconds(3); var waiting = false;
        do {
            await using var wait = new NpgsqlCommand("select 1 from pg_stat_activity where application_name=$1 and wait_event_type='Lock'", db); wait.Parameters.AddWithValue(schema + "_expiry"); waiting = await wait.ExecuteScalarAsync() is not null;
            if (!waiting) await Task.Delay(10);
        } while (!waiting && DateTime.UtcNow < lockDeadline);
        Check(waiting && !tick.IsCompleted, "Expiry worker waits on the actual PostgreSQL API edit row lock");
        await using var renew = new NpgsqlCommand("with restored as (update v_pbx_restore set config=jsonb_set(config,'{users,1000,mobile_temporary,expires}',to_jsonb($2::bigint)) where domain_uuid=$1 returning domain_uuid) update v_pbx_mobile_presence set expires_at=to_timestamp($2) where domain_uuid in(select domain_uuid from restored)", api, transaction);
        renew.Parameters.AddWithValue(domains[0]); renew.Parameters.AddWithValue(future); await renew.ExecuteNonQueryAsync(); await transaction.CommitAsync(); await tick;
    }
    Check((await User(0))["profile"]!.GetValue<string>() == "Away" && await Count(0) == 1, "Concurrent renewal survives stale worker list");
    var fixturePath = Environment.GetEnvironmentVariable("OPENWEB_NATIVE_STATE_FIXTURE");
    if (!string.IsNullOrWhiteSpace(fixturePath)) {
        // Optional native qualification must use a separately provisioned disposable
        // tenant. Its presence table is isolated, so the running global worker cannot
        // consume these rows, and this worker cannot discover customer expiry rows.
        var prefix = "/var/lib/openwebpbx/availability-runtime-108/";
        if (!Path.GetFullPath(fixturePath).StartsWith(prefix, StringComparison.Ordinal)) throw new Exception("Private availability fixture required");
        var fixture = JsonNode.Parse(await File.ReadAllTextAsync(fixturePath))!;
        var nativeDomain = Guid.Parse(fixture["domain"]!.GetValue<string>()); var nativeExtension = Guid.Parse(fixture["users"]!["1000"]!["extension_uuid"]!.GetValue<string>());
        var nativeRealm = fixture["realm"]!.GetValue<string>();
        if (!System.Text.RegularExpressions.Regex.IsMatch(nativeRealm, "^availability-check-[a-f0-9]{12}\\.invalid$")) throw new Exception("Disposable availability realm required");
        await using var nativeConnection = await root.OpenConnectionAsync();
        await using (var owned = new NpgsqlCommand("select 1 from v_domains d join v_extensions e using(domain_uuid) where d.domain_uuid=$1 and d.domain_name=$2 and e.extension_uuid=$3", nativeConnection)) {
            owned.Parameters.AddWithValue(nativeDomain); owned.Parameters.AddWithValue(nativeRealm); owned.Parameters.AddWithValue(nativeExtension);
            if (await owned.ExecuteScalarAsync() is null) throw new Exception("Fixture ownership mismatch");
        }
        var nativeSchema = "mobile_state_native_" + Guid.NewGuid().ToString("N");
        await new NpgsqlCommand($"create schema {nativeSchema}; create table {nativeSchema}.v_pbx_mobile_presence(like public.v_pbx_mobile_presence including all)", nativeConnection).ExecuteNonQueryAsync();
        try {
            var nativeString = new NpgsqlConnectionStringBuilder(connection) { SearchPath = nativeSchema + ",public" };
            await using var nativeData = NpgsqlDataSource.Create(nativeString.ConnectionString);
            var privateConfig = new ConfigurationBuilder().AddJsonFile("/etc/openwebpbx/runtime.json", optional: false).Build();
            var nativeEngine = new SwitchClient(privateConfig);
            var nativeWorker = new MobileStateWorker(nativeData, nativeEngine, NullLogger<MobileStateWorker>.Instance);
            var agent0 = Guid.Parse(fixture["agents"]!["8000"]!.GetValue<string>()); var agent1 = Guid.Parse(fixture["agents"]!["8001"]!.GetValue<string>()); var colleague = Guid.Parse(fixture["agents"]!["8002"]!.GetValue<string>());
            async Task SetExpiredDnd() {
                await using var set = new NpgsqlCommand($"with restored as (update public.v_pbx_restore set config=jsonb_set(jsonb_set(config,'{{users,1000,profile}}','\"Do Not Disturb\"'::jsonb),'{{users,1000,mobile_temporary}}',jsonb_build_object('previous','Available','target','Do Not Disturb','expires',$3::bigint)) where domain_uuid=$1 returning domain_uuid) insert into {nativeSchema}.v_pbx_mobile_presence(domain_uuid,extension_uuid,number,previous_profile,target_profile,expires_at) select domain_uuid,$2,'1000','Available','Do Not Disturb',to_timestamp($3) from restored on conflict(domain_uuid,extension_uuid) do update set expires_at=excluded.expires_at", nativeConnection);
                set.Parameters.AddWithValue(nativeDomain); set.Parameters.AddWithValue(nativeExtension); set.Parameters.AddWithValue(past); await set.ExecuteNonQueryAsync();
            }
            async Task<long> NativeCount() => (long)(await new NpgsqlCommand($"select count(*) from {nativeSchema}.v_pbx_mobile_presence", nativeConnection).ExecuteScalarAsync())!;
            await using (var futureExpiry = new NpgsqlCommand("select 1 from public.v_pbx_mobile_presence where domain_uuid=$1 and extension_uuid=$2 and expires_at>now()+interval '1 minute'", nativeConnection)) {
                futureExpiry.Parameters.AddWithValue(nativeDomain); futureExpiry.Parameters.AddWithValue(nativeExtension); Check(await futureExpiry.ExecuteScalarAsync() is not null, "Native fixture keeps its global expiry safely in the future");
            }
            await SetExpiredDnd();
            await nativeEngine.Execute($"lua app/pbx_setup/mobile_state.lua {nativeDomain} 1000", default);
            Check((await nativeEngine.Execute($"callcenter_config agent get status {agent0}", default)).Trim() == "Available", "Native Lua expiry takes effect before the status worker reconciles Admin state");
            await nativeWorker.Tick(default);
            Check(await NativeCount() == 0, "Native successful expiry clears isolated durable row");
            await using (var selection = new NpgsqlCommand("select config->'users'->'1000'->>'profile' from public.v_pbx_restore where domain_uuid=$1", nativeConnection)) {
                selection.Parameters.AddWithValue(nativeDomain); Check((string)(await selection.ExecuteScalarAsync())! == "Available", "Native expiry restores Admin profile");
            }
            Check((await nativeEngine.Execute($"callcenter_config agent get status {agent0}", default)).Trim() == "Available" && (await nativeEngine.Execute($"callcenter_config agent get status {agent1}", default)).Trim() == "Available", "Native expiry resumes both assigned queue agents");
            Check((await nativeEngine.Execute($"callcenter_config agent get status {colleague}", default)).Trim() == "Available", "Native expiry preserves colleague agent");
            await SetExpiredDnd(); await nativeEngine.Execute($"callcenter_config agent del {agent0}", default); await nativeWorker.Tick(default);
            Check(await NativeCount() == 1, "Missing native agent leaves durable expiry retry");
            await nativeEngine.Execute($"callcenter_config agent reload {agent0}", default); await nativeWorker.Tick(default);
            Check(await NativeCount() == 0 && (await nativeEngine.Execute($"callcenter_config agent get status {agent0}", default)).Trim() == "Available", "Reloaded native agent recovers expiry without changing customer rows");
        } finally { await new NpgsqlCommand($"drop schema {nativeSchema} cascade", nativeConnection).ExecuteNonQueryAsync(); }
    }
    Console.WriteLine($"PASS: {checks} real PostgreSQL status expiry, tenant isolation, concurrent edits and engine recovery checks" + (string.IsNullOrWhiteSpace(fixturePath) ? "" : ", including actual FreeSWITCH expiry and retry"));
    return 0;
} finally {
    stop.Cancel(); server.Stop(); await fakeEngine;
    await new NpgsqlCommand($"set search_path to public; drop schema {schema} cascade", db).ExecuteNonQueryAsync();
}
