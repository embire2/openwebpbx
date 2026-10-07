using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;
using System.Net;
using System.Net.Sockets;
using System.Text;

int checks = 0;
void Check(bool condition, string message) { if (!condition) throw new Exception(message); checks++; }
var frame = await SwitchClient.ReadFrame(new MemoryStream(Encoding.UTF8.GetBytes("Content-Type: api/response\nContent-Length: 7\n\nUP test")), default);
Check(frame["Body"] == "UP test", "Length-delimited body");
try { await SwitchClient.ReadFrame(new MemoryStream("Content-Length: 9999999\n\n"u8.ToArray()), default); throw new Exception("Oversized frame accepted"); } catch (IOException) { checks++; }
try { await SwitchClient.ReadFrame(new MemoryStream("Content-Length: 5\n\nX"u8.ToArray()), default); throw new Exception("Truncated frame accepted"); } catch (EndOfStreamException) { checks++; }
var connection = Environment.GetEnvironmentVariable("OPENWEB_TEST_DATABASE");
if (string.IsNullOrEmpty(connection)) { Console.WriteLine($"PASS: {checks} protocol checks. Database checks require OPENWEB_TEST_DATABASE."); return; }
await using var root = NpgsqlDataSource.Create(connection);
await using var db = await root.OpenConnectionAsync();
var schema = "openweb_worker_check_" + Guid.NewGuid().ToString("N");
var server = new TcpListener(IPAddress.Loopback, 0); server.Start();
using var stop = new CancellationTokenSource();
var commands = new System.Collections.Concurrent.ConcurrentBag<string>();
var fakeEngine = Task.Run(async () => {
    while (!stop.IsCancellationRequested) {
        TcpClient socket;
        try { socket = await server.AcceptTcpClientAsync(stop.Token); } catch (OperationCanceledException) { break; }
        using (socket) {
            var stream = socket.GetStream();
            await stream.WriteAsync("Content-Type: auth/request\n\n"u8.ToArray());
            var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
            await reader.ReadLineAsync(); await reader.ReadLineAsync();
            await stream.WriteAsync("Content-Type: command/reply\nReply-Text: +OK accepted\n\n"u8.ToArray());
            var command = await reader.ReadLineAsync() ?? ""; await reader.ReadLineAsync(); commands.Add(command);
            var response = command.Contains("uuid_exists") ? "false" : command == "api status" ? "UP test" : "+OK started";
            await stream.WriteAsync(Encoding.UTF8.GetBytes($"Content-Type: api/response\nContent-Length: {Encoding.UTF8.GetByteCount(response)}\n\n{response}"));
        }
    }
});
try {
    await new NpgsqlCommand($"create schema {schema}; set search_path to {schema},public", db).ExecuteNonQueryAsync();
    foreach (var table in new[] { "v_domains", "v_pbx_tenants", "v_pbx_services" }) await new NpgsqlCommand($"create table {table}(like public.{table} including all)", db).ExecuteNonQueryAsync();
    var sqlPath = Path.Combine(Directory.GetCurrentDirectory(), "app/pbx_setup/resources/jobs.sql");
    await new NpgsqlCommand(await File.ReadAllTextAsync(sqlPath), db).ExecuteNonQueryAsync();
    var domain = Guid.NewGuid();
    await using (var insert = new NpgsqlCommand("insert into v_domains(domain_uuid,domain_name,domain_enabled) values($1,'check.invalid','true')", db)) { insert.Parameters.AddWithValue(domain); await insert.ExecuteNonQueryAsync(); }
    var job = Guid.NewGuid();
    await using (var insert = new NpgsqlCommand("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,target_number,request_key) values($1,$2,'callback','100','test')", db)) { insert.Parameters.AddWithValue(job); insert.Parameters.AddWithValue(domain); await insert.ExecuteNonQueryAsync(); }
    var cs = new NpgsqlConnectionStringBuilder(connection) { SearchPath = schema + ",public" };
    await using var data = NpgsqlDataSource.Create(cs.ConnectionString);
    var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?> { ["Switch:Port"] = ((IPEndPoint)server.LocalEndpoint).Port.ToString(), ["Switch:Password"] = "test-only" }).Build();
    var worker = new JobWorker(data, new SwitchClient(configuration), new ServiceStatus(), NullLogger<JobWorker>.Instance);
    await Task.WhenAll(worker.Tick(default), worker.Tick(default));
    Check(commands.Count(x => x.Contains("luarun")) == 1, "Concurrent workers started the same request twice");
    Check((string)(await new NpgsqlCommand("select state from v_pbx_jobs", db).ExecuteScalarAsync())! == "starting", "Job was not leased");
    await new NpgsqlCommand("update v_pbx_jobs set lease_until=now()-interval '1 minute'", db).ExecuteNonQueryAsync();
    await worker.Tick(default);
    Check((string)(await new NpgsqlCommand("select state from v_pbx_jobs", db).ExecuteScalarAsync())! == "waiting", "Interrupted launch was not recovered");
    Check(commands.Any(x => x.Contains("uuid_exists")), "Recovery did not check for an active call");
    await new NpgsqlCommand("update v_pbx_jobs set expires_at=now()-interval '1 second'", db).ExecuteNonQueryAsync();
    await worker.Tick(default);
    Check((string)(await new NpgsqlCommand("select state from v_pbx_jobs", db).ExecuteScalarAsync())! == "failed", "Expired callback was not stopped");
    Console.WriteLine($"PASS: {checks} protocol, concurrent delivery, restart and expiry checks");
}
finally { stop.Cancel(); server.Stop(); await fakeEngine; await new NpgsqlCommand($"set search_path to public; drop schema {schema} cascade", db).ExecuteNonQueryAsync(); }
