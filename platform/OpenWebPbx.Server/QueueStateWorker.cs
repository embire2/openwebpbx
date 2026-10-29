using Npgsql;
using System.Text.Json;

namespace OpenWebPbx.Server;

// Reconcile effective hours and supervisor preferences without unloading a queue
// or resetting a native agent's current bridge, wrap-up or ready time.
public sealed class QueueStateWorker(NpgsqlDataSource data, SwitchClient engine, ILogger<QueueStateWorker> log, OnboardingGate? onboarding = null) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(15));
        do
        {
            try { await Tick(ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogWarning("Queue preferences will retry ({ErrorType}).", ex.GetType().Name); }
        } while (await timer.WaitForNextTickAsync(ct));
    }

    public async Task Tick(CancellationToken ct)
    {
        var targets = new List<(Guid Domain, string Number)>();
        await using (var list = data.CreateCommand("select r.domain_uuid,r.config::text from v_pbx_restore r join v_domains d using(domain_uuid) where d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=r.domain_uuid and not t.enabled) order by r.domain_uuid"))
        await using (var reader = await list.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                using var json = JsonDocument.Parse(reader.GetString(1));
                if (!json.RootElement.TryGetProperty("queues", out var queues) || queues.ValueKind != JsonValueKind.Array) continue;
                var numbers = new HashSet<string>(StringComparer.Ordinal);
                foreach (var queue in queues.EnumerateArray())
                {
                    if (!queue.TryGetProperty("members", out var members) || members.ValueKind != JsonValueKind.Array) continue;
                    foreach (var member in members.EnumerateArray())
                    {
                        if (!member.TryGetProperty("number", out var value)) continue;
                        var number = value.ValueKind == JsonValueKind.String ? value.GetString() : value.GetRawText();
                        if (number is null || number.Length is < 2 or > 10 || number.Any(c => c is < '0' or > '9')) continue;
                        numbers.Add(number);
                    }
                }
                foreach (var number in numbers) targets.Add((reader.GetGuid(0), number));
            }
        }
        foreach (var (domain, number) in targets)
        {
            ct.ThrowIfCancellationRequested();
            if(onboarding is not null && !await onboarding.Allows(domain,data,ct))continue;
            await engine.Execute($"lua app/pbx_setup/mobile_state.lua {domain} {number}", ct);
        }
        await using var reconcile = data.CreateCommand("""
            update v_pbx_queue_tickets t
            set state=case when c.cc_agent_bridged='true' then 'finished' else 'abandoned' end,
                ended_at=to_timestamp(c.end_epoch::double precision),
                wait_seconds=greatest(0,coalesce(c.waitsec,c.answer_epoch-c.start_epoch,c.duration,0))
            from v_xml_cdr c
            where t.call_uuid=c.xml_cdr_uuid and t.domain_uuid=c.domain_uuid
              and t.state in ('waiting','answered','abandoned') and c.end_epoch>0
              and c.cc_queue=t.queue_number||'@'||c.domain_name
            """);
        await reconcile.ExecuteNonQueryAsync(ct);
    }
}
