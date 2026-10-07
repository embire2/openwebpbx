using Npgsql;

namespace OpenWebPbx.Server;

public sealed class ServiceStatus
{
    public DateTimeOffset? LastSuccess { get; set; }
    public string State { get; set; } = "Starting";
}

public sealed class JobWorker(NpgsqlDataSource data, SwitchClient callEngine, ServiceStatus status, ILogger<JobWorker> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        do
        {
            try
            {
                await Tick(stoppingToken);
                status.LastSuccess = DateTimeOffset.UtcNow; status.State = "Running";
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                status.State = "Connection unavailable";
                // Never log connection strings, database parameters, phone numbers or provider passwords.
                log.LogWarning("Background calling service unavailable ({ErrorType}). It will retry.", ex.GetType().Name);
            }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    public async Task Tick(CancellationToken ct)
    {
        // Check the engine before claiming work. A failed launch remains leased and is recovered below.
        if (!(await callEngine.Execute("status", ct)).Contains("UP", StringComparison.Ordinal)) throw new IOException("Call engine unavailable.");
        await using var db = await data.OpenConnectionAsync(ct);
        // Recovery checks the exact call UUID before allowing another attempt, including after a restart.
        await using (var expired = new NpgsqlCommand("select job_uuid,call_uuid from v_pbx_jobs where state in ('starting','calling') and lease_until<now() limit 100", db))
        {
            var recover = new List<(Guid, Guid?)>();
            await using (var reader = await expired.ExecuteReaderAsync(ct))
                while (await reader.ReadAsync(ct)) recover.Add((reader.GetGuid(0), reader.IsDBNull(1) ? null : reader.GetGuid(1)));
            foreach (var (id, call) in recover)
            {
                bool alive = call is not null && (await callEngine.Execute($"uuid_exists {call:D}", ct)).Trim() == "true";
                await using var update = new NpgsqlCommand(alive
                    ? "update v_pbx_jobs set lease_until=now()+interval '5 minutes' where job_uuid=$1 and state in ('starting','calling')"
                    : "update v_pbx_jobs set state=case when attempts>=max_attempts or expires_at<now() then 'failed' else 'waiting' end, due_at=now()+interval '1 minute',lease_until=null,agent_number=null,last_result='Interrupted; rescheduled',updated_at=now() where job_uuid=$1 and state in ('starting','calling') and lease_until<now()", db);
                update.Parameters.AddWithValue(id); await update.ExecuteNonQueryAsync(ct);
            }
        }
        await using (var expire = new NpgsqlCommand("update v_pbx_jobs set state='failed',last_result='Request expired',updated_at=now() where state='waiting' and expires_at<now()", db)) await expire.ExecuteNonQueryAsync(ct);
        // Atomically lease a bounded batch. Concurrent workers cannot claim the same request.
        await using var claim = new NpgsqlCommand("""
            with chosen as (
              select j.job_uuid from v_pbx_jobs j join v_domains d using(domain_uuid)
              where j.state='waiting' and j.due_at<=now() and j.expires_at>now() and d.domain_enabled='true'
              and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=j.domain_uuid and not t.enabled)
              order by j.created_at for update of j skip locked limit 8
            ) update v_pbx_jobs j set state='starting',lease_until=now()+interval '2 minutes',call_uuid=gen_random_uuid(),updated_at=now()
              from chosen where j.job_uuid=chosen.job_uuid returning j.job_uuid
            """, db);
        var jobs = new List<Guid>();
        await using (var reader = await claim.ExecuteReaderAsync(ct)) while (await reader.ReadAsync(ct)) jobs.Add(reader.GetGuid(0));
        foreach (var id in jobs)
        {
            var result = await callEngine.Execute($"luarun app/pbx_setup/jobs.lua {id:D}", ct);
            if (!result.StartsWith("+OK", StringComparison.Ordinal)) throw new IOException("Call engine did not accept the job.");
        }
    }
}
