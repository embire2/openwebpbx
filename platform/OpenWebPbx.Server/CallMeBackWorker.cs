using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using Npgsql;

namespace OpenWebPbx.Server;

/// <summary>Durable, tenant-owned callback dispatch. It never handles SA identity numbers.</summary>
public sealed class CallMeBackWorker(NpgsqlDataSource data, SwitchClient engine, ILogger<CallMeBackWorker> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        do
        {
            try { await Tick(stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogWarning("Call Me Back will retry ({ErrorType}).", ex.GetType().Name); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    public async Task Tick(CancellationToken ct)
    {
        await using var db = await data.OpenConnectionAsync(ct);
        if (!(await engine.Execute("status", ct)).Contains("UP", StringComparison.Ordinal)) return;

        var stale = new List<(Guid Request, Guid? Call, Guid? Bridge, DateTime Created, bool Answered)>();
        await using (var command = new NpgsqlCommand("""
            select request_uuid,call_uuid,bridge_uuid,created_at,connected_at is not null from v_pbx_cmb_requests
            where state in ('announcing','starting','authenticating','dialling','connected')
              and coalesce(lease_until,created_at+interval '2 minutes')<now() limit 50
            """, db))
        await using (var reader = await command.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct)) stale.Add((reader.GetGuid(0), reader.IsDBNull(1) ? null : reader.GetGuid(1), reader.IsDBNull(2) ? null : reader.GetGuid(2), reader.GetDateTime(3), reader.GetBoolean(4)));
        foreach (var row in stale)
        {
            bool active = false;
            foreach (var id in new[] { row.Call, row.Bridge }.OfType<Guid>().Distinct())
            {
                var observed = (await engine.Execute($"uuid_exists {id:D}", ct)).Trim();
                if (observed == "false") continue;
                if (observed != "true") throw new IOException("Call existence could not be verified.");
                active = true; // Even an accepted kill is verified absent in a later tick.
                if (row.Created < DateTime.UtcNow.AddMinutes(-13))
                {
                    var killed = await engine.Execute($"uuid_kill {id:D} ALLOTTED_TIMEOUT", ct);
                    if (!killed.StartsWith("+OK", StringComparison.Ordinal)) throw new IOException("Expired call could not be stopped.");
                }
            }
            await using var command = new NpgsqlCommand(active
                ? "update v_pbx_cmb_requests set lease_until=now()+interval '1 minute' where request_uuid=$1 and state not in ('completed','failed','cancelled')"
                : row.Bridge is null && !row.Answered
                    ? "select openweb_cmb_finish($1,0,'interrupted_before_destination')"
                    : "select openweb_cmb_finish($1,null,'interrupted_review_usage')", db);
            command.Parameters.AddWithValue(row.Request); await command.ExecuteNonQueryAsync(ct);
        }
        await using (var expire = new NpgsqlCommand("select openweb_cmb_finish(request_uuid,0,'request_expired') from v_pbx_cmb_requests where state='queued' and created_at<now()-interval '2 minutes'", db))
            await expire.ExecuteNonQueryAsync(ct);
        await using (var clean = new NpgsqlCommand("""
            delete from v_pbx_cmb_requests r using v_pbx_cmb_services s where r.domain_uuid=s.domain_uuid and r.service_uuid=s.service_uuid
              and r.state in ('completed','failed','cancelled') and r.updated_at<now()-s.retention_days*interval '1 day';
            delete from v_pbx_cmb_bindings b using v_pbx_cmb_services s where b.domain_uuid=s.domain_uuid and b.service_uuid=s.service_uuid
              and b.revoked_at<now()-s.retention_days*interval '1 day';
            delete from v_pbx_cmb_audit where created_at<now()-interval '365 days'
            """, db)) await clean.ExecuteNonQueryAsync(ct);
        var requests = new List<Guid>();
        await using (var claim = new NpgsqlCommand("""
            with chosen as (
              select r.request_uuid from v_pbx_cmb_requests r join v_pbx_cmb_services s using(domain_uuid,service_uuid)
              join v_domains d using(domain_uuid)
              where r.state='queued' and r.created_at>now()-interval '2 minutes' and s.enabled and s.prompt_state='ready' and d.domain_enabled='true'
                and not exists(select 1 from v_pbx_services p join v_pbx_tenants t using(tenant_uuid) where p.domain_uuid=r.domain_uuid and not t.enabled)
              order by r.created_at for update of r skip locked limit 4
            ) update v_pbx_cmb_requests r set state='starting',call_uuid=gen_random_uuid(),lease_until=now()+interval '2 minutes',updated_at=now()
              from chosen where r.request_uuid=chosen.request_uuid returning r.request_uuid
            """, db))
        await using (var reader = await claim.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct)) requests.Add(reader.GetGuid(0));
        foreach (var id in requests)
        {
            // The exact original call UUID is retained on launch ambiguity. Recovery checks it;
            // callbacks are never silently redialled after an uncertain launch or a restart.
            var result = await engine.Execute($"luarun app/pbx_setup/call_me_back.lua {id:D}", ct);
            if (!result.StartsWith("+OK", StringComparison.Ordinal))
            {
                await using var command = new NpgsqlCommand("select openweb_cmb_finish($1,0,'launch_refused')", db);
                command.Parameters.AddWithValue(id); await command.ExecuteNonQueryAsync(ct);
            }
        }
    }

}
