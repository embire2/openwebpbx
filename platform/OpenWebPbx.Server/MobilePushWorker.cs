using Npgsql;
using System.Text.Json.Nodes;

namespace OpenWebPbx.Server;

public sealed class MobilePushWorker(NpgsqlDataSource data, SwitchClient engine, AndroidPushSender sender, ILogger<MobilePushWorker> log) : BackgroundService
{
    private sealed record Item(Guid Request, Guid Call, Guid Device, Guid Domain, Guid Extension, string Token, Guid Lease, DateTimeOffset Expires);
    private long nextCleanup;
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(500));
        do
        {
            try { await Tick(ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogWarning("Incoming wake-up delivery will retry ({ErrorType}).", ex.GetType().Name); await Task.Delay(2000, ct); }
        } while (await timer.WaitForNextTickAsync(ct));
    }
    public async Task Tick(CancellationToken ct)
    {
        var now = DateTime.UtcNow.Ticks; var last = Volatile.Read(ref nextCleanup);
        if (now >= last && Interlocked.CompareExchange(ref nextCleanup, now + TimeSpan.FromMinutes(1).Ticks, last) == last)
        {
            await using var cleanup = data.CreateCommand("delete from v_pbx_mobile_push_calls where expires_at<now()-interval '1 day'");
            await cleanup.ExecuteNonQueryAsync(ct);
        }
        var config = sender.Settings();
        if (config is null)
        {
            // A disabled/missing channel never affects SIP calling. In-flight opaque
            // requests also become unavailable to the authenticated phone API.
            await using var stop = data.CreateCommand("update v_pbx_mobile_push_calls set state='ended',attempts=0 where state in ('pending','sent')");
            await stop.ExecuteNonQueryAsync(ct); return;
        }
        // End requests for revoked/expired phones and disabled/suspended PBXs.
        await using (var retire = data.CreateCommand("""
            update v_pbx_mobile_push_calls p set state='ended',attempts=0,next_attempt_at=now()
            where p.state in ('pending','sent') and not exists(
            select 1 from v_pbx_mobile_devices m join v_domains d on d.domain_uuid=m.domain_uuid
            join v_extensions e on e.extension_uuid=m.extension_uuid and e.domain_uuid=m.domain_uuid
            join v_pbx_mobile_push_config c on c.singleton and c.enabled and c.project_id=$1
            where m.device_uuid=p.device_uuid and m.domain_uuid=p.domain_uuid and m.extension_uuid=p.extension_uuid
            and m.revoked_at is null and m.expires_at>now() and m.push_project=$1 and m.push_token is not null
            and d.domain_enabled='true' and e.enabled='true' and not exists
            (select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=m.domain_uuid and not t.enabled))
            """))
        { retire.Parameters.AddWithValue(config["project_id"]!.GetValue<string>()); await retire.ExecuteNonQueryAsync(ct); }
        // Claim only eight rows at once. All claimed rows start work immediately;
        // a slow earlier batch cannot let a later queued item's lease expire.
        for (var batch = 0; batch < 4; batch++)
        {
            var rows = await Claim(config["project_id"]!.GetValue<string>(), ct);
            if (rows.Count == 0) break;
            await Task.WhenAll(rows.Select(row => Process(row, config, ct)));
        }
    }
    private async Task<List<Item>> Claim(string project, CancellationToken ct)
    {
        var rows = new List<Item>();
        await using var claim = data.CreateCommand("""
            with ready as (
                select p.request_uuid,m.push_token from v_pbx_mobile_push_calls p
                join v_pbx_mobile_devices m using(device_uuid) join v_domains d on d.domain_uuid=p.domain_uuid
                join v_extensions e on e.extension_uuid=p.extension_uuid and e.domain_uuid=p.domain_uuid
                join v_pbx_mobile_push_config c on c.singleton and c.enabled and c.project_id=$1
                where p.next_attempt_at<=now() and (p.lease_until is null or p.lease_until<=now())
                and (p.state in ('pending','sent') or (p.state in ('ended','dismissed') and p.notification_attempted_at is not null and p.cancellation_sent_at is null and p.attempts<3))
                and m.domain_uuid=p.domain_uuid and m.extension_uuid=p.extension_uuid and m.revoked_at is null
                and m.expires_at>now() and m.push_project=$1 and m.push_token is not null
                and d.domain_enabled='true' and e.enabled='true' and not exists
                (select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=p.domain_uuid and not t.enabled)
                order by case when p.state='pending' and p.attempts<3 then 0 when p.state in ('ended','dismissed') then 1 else 2 end,p.next_attempt_at,p.created_at
                limit 8 for update of p skip locked
            ) update v_pbx_mobile_push_calls p set lease_uuid=gen_random_uuid(),lease_until=now()+interval '45 seconds'
            from ready r where p.request_uuid=r.request_uuid
            returning p.request_uuid,p.call_uuid,p.device_uuid,p.domain_uuid,p.extension_uuid,r.push_token,p.lease_uuid,p.expires_at
            """);
        claim.Parameters.AddWithValue(project);
        await using var reader = await claim.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) rows.Add(new(reader.GetGuid(0), reader.GetGuid(1), reader.GetGuid(2), reader.GetGuid(3), reader.GetGuid(4), reader.GetString(5), reader.GetGuid(6), new DateTimeOffset(reader.GetDateTime(7))));
        return rows;
    }
    private async Task<bool> Active(Item row, CancellationToken ct)
    {
        if (row.Expires <= DateTimeOffset.UtcNow || (await engine.Execute($"uuid_exists {row.Call}", ct)).Trim() != "true") return false;
        var vars = await Task.WhenAll(engine.Execute($"uuid_getvar {row.Call} domain_uuid", ct), engine.Execute($"uuid_getvar {row.Call} openweb_mobile_wake_targets", ct), engine.Execute($"uuid_getvar {row.Call} bridge_uuid", ct));
        if (!Guid.TryParse(vars[0].Trim(), out var domain) || domain != row.Domain || vars[1].Length > 40000 || !vars[1].Trim().Split(',').Any(value => Guid.TryParse(value, out var target) && target == row.Extension)) return false;
        return !Guid.TryParse(vars[2].Trim(), out var peer) || !long.TryParse((await engine.Execute($"uuid_getvar {peer} answer_epoch", ct)).Trim(), out var answer) || answer <= 0;
    }
    private async Task Process(Item row, JsonNode config, CancellationToken ct)
    {
        try
        {
            string? state; bool attempted; int attempts;
            await using (var read = data.CreateCommand("select state,notification_attempted_at is not null,attempts from v_pbx_mobile_push_calls where request_uuid=$1 and lease_uuid=$2"))
            {
                read.Parameters.AddWithValue(row.Request); read.Parameters.AddWithValue(row.Lease);
                await using var reader = await read.ExecuteReaderAsync(ct); if (!await reader.ReadAsync(ct)) return;
                state = reader.GetString(0); attempted = reader.GetBoolean(1); attempts = reader.GetInt32(2);
            }
            if (state is "pending" or "sent" && !await Active(row, ct))
            {
                await using var end = data.CreateCommand("update v_pbx_mobile_push_calls set state='ended',attempts=0 where request_uuid=$1 and lease_uuid=$2 and state in ('pending','sent')");
                end.Parameters.AddWithValue(row.Request); end.Parameters.AddWithValue(row.Lease); await end.ExecuteNonQueryAsync(ct); state = "ended"; attempts = 0;
            }
            if (state is "ended" or "dismissed")
            {
                if (!attempted || attempts >= 3) { await Release(row, TimeSpan.FromDays(1), ct); return; }
                if (!await Ready(row, config, ct)) { await Release(row, TimeSpan.FromDays(1), ct); return; }
                if (!await Attempt(row, false, ct)) { await Release(row, TimeSpan.Zero, ct); return; }
                var delivery = await sender.Send(config, row.Token, row.Request, row.Device.ToString(), "ended", DateTimeOffset.UtcNow.AddSeconds(30), ct);
                if (delivery == PushDelivery.Unregistered) await Forget(row, config, ct);
                await using var finish = data.CreateCommand("update v_pbx_mobile_push_calls set cancellation_sent_at=case when $3 then now() else cancellation_sent_at end,lease_uuid=null,lease_until=null,next_attempt_at=now()+interval '1 day' where request_uuid=$1 and lease_uuid=$2");
                finish.Parameters.AddWithValue(row.Request); finish.Parameters.AddWithValue(row.Lease); finish.Parameters.AddWithValue(delivery == PushDelivery.Sent); await finish.ExecuteNonQueryAsync(ct); return;
            }
            if (state == "sent" || attempts >= 3) { await Release(row, TimeSpan.FromSeconds(1), ct); return; }
            if (!await Ready(row, config, ct)) { await End(row, ct); return; }
            if (!await Attempt(row, true, ct)) { await Release(row, TimeSpan.Zero, ct); return; }
            var result = await sender.Send(config, row.Token, row.Request, row.Device.ToString(), "incoming", row.Expires, ct);
            if (result == PushDelivery.Unregistered) await Forget(row, config, ct);
            await using var sent = data.CreateCommand("""
                update v_pbx_mobile_push_calls set state=case when state='pending' then $3 else state end,
                attempts=case when state='pending' then 0 else attempts end,lease_uuid=null,lease_until=null,next_attempt_at=now()
                where request_uuid=$1 and lease_uuid=$2
                """);
            sent.Parameters.AddWithValue(row.Request); sent.Parameters.AddWithValue(row.Lease); sent.Parameters.AddWithValue(result == PushDelivery.Sent ? "sent" : "ended"); await sent.ExecuteNonQueryAsync(ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception ex)
        {
            await Release(row, ex is PushDeliveryException retry ? retry.RetryAfter : TimeSpan.FromSeconds(2), ct);
            log.LogWarning("Incoming notification will retry ({ErrorType}).", ex.GetType().Name);
        }
    }
    private async Task<bool> Ready(Item row, JsonNode config, CancellationToken ct)
    {
        await using var check = data.CreateCommand("""
            select 1 from v_pbx_mobile_devices m join v_domains d using(domain_uuid)
            join v_extensions e on e.extension_uuid=m.extension_uuid and e.domain_uuid=m.domain_uuid
            join v_pbx_mobile_push_config c on c.singleton and c.enabled and c.project_id=$5
            where m.device_uuid=$1 and m.domain_uuid=$2 and m.extension_uuid=$3 and m.push_token=$4 and m.push_project=$5
            and m.revoked_at is null and m.expires_at>now() and d.domain_enabled='true' and e.enabled='true'
            and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=m.domain_uuid and not t.enabled)
            """);
        check.Parameters.AddWithValue(row.Device); check.Parameters.AddWithValue(row.Domain); check.Parameters.AddWithValue(row.Extension); check.Parameters.AddWithValue(row.Token); check.Parameters.AddWithValue(config["project_id"]!.GetValue<string>());
        return await check.ExecuteScalarAsync(ct) is not null;
    }
    private async Task<bool> Attempt(Item row, bool incoming, CancellationToken ct)
    {
        await using var attempt = data.CreateCommand("update v_pbx_mobile_push_calls set attempts=attempts+1,notification_attempted_at=case when $3 then coalesce(notification_attempted_at,now()) else notification_attempted_at end where request_uuid=$1 and lease_uuid=$2 and attempts<3 and "+(incoming?"state='pending'":"state in ('ended','dismissed')")+" returning request_uuid");
        attempt.Parameters.AddWithValue(row.Request); attempt.Parameters.AddWithValue(row.Lease); attempt.Parameters.AddWithValue(incoming); return await attempt.ExecuteScalarAsync(ct) is not null;
    }
    private async Task Release(Item row, TimeSpan delay, CancellationToken ct)
    {
        await using var release = data.CreateCommand("update v_pbx_mobile_push_calls set lease_uuid=null,lease_until=null,next_attempt_at=now()+$3 where request_uuid=$1 and lease_uuid=$2");
        release.Parameters.AddWithValue(row.Request); release.Parameters.AddWithValue(row.Lease); release.Parameters.AddWithValue(delay); await release.ExecuteNonQueryAsync(ct);
    }
    private async Task End(Item row, CancellationToken ct)
    {
        await using var end = data.CreateCommand("update v_pbx_mobile_push_calls set state='ended',attempts=0,lease_uuid=null,lease_until=null,next_attempt_at=now() where request_uuid=$1 and lease_uuid=$2 and state in ('pending','sent')");
        end.Parameters.AddWithValue(row.Request); end.Parameters.AddWithValue(row.Lease); await end.ExecuteNonQueryAsync(ct);
    }
    private async Task Forget(Item row, JsonNode config, CancellationToken ct)
    {
        await using var forget = data.CreateCommand("update v_pbx_mobile_devices set push_token=null where device_uuid=$1 and domain_uuid=$2 and extension_uuid=$3 and push_token=$4 and push_project=$5");
        forget.Parameters.AddWithValue(row.Device); forget.Parameters.AddWithValue(row.Domain); forget.Parameters.AddWithValue(row.Extension); forget.Parameters.AddWithValue(row.Token); forget.Parameters.AddWithValue(config["project_id"]!.GetValue<string>()); await forget.ExecuteNonQueryAsync(ct);
    }
}
