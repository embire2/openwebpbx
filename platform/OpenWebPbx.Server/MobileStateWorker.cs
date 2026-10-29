using Npgsql;
using System.Text.Json.Nodes;

namespace OpenWebPbx.Server;

// Expiry remains effective in Lua even while this reconciler is unavailable.
// Keep an expiry row until native synchronization succeeds so an engine outage
// cannot leave an agent permanently paused after the stored profile was restored.
public sealed class MobileStateWorker(NpgsqlDataSource data, SwitchClient engine, ILogger<MobileStateWorker> log, OnboardingGate? onboarding = null) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        do
        {
            try { await Tick(ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogWarning("Phone status refresh will retry ({ErrorType}).", ex.GetType().Name); }
        } while (await timer.WaitForNextTickAsync(ct));
    }
    public async Task Tick(CancellationToken ct)
    {
        var rows = new List<(Guid Domain, Guid Extension, string Number)>();
        await using (var list = data.CreateCommand("select domain_uuid,extension_uuid,number from v_pbx_mobile_presence where expires_at<=now() order by expires_at limit 32"))
        await using (var reader = await list.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct)) rows.Add((reader.GetGuid(0), reader.GetGuid(1), reader.GetString(2)));
        foreach (var row in rows)
        {
            if (!System.Text.RegularExpressions.Regex.IsMatch(row.Number, "^[0-9]{2,10}$")) continue;
            if(onboarding is not null && !await onboarding.Allows(row.Domain,data,ct))continue;
            long epoch;
            await using (var connection = await data.OpenConnectionAsync(ct))
            await using (var tx = await connection.BeginTransactionAsync(ct))
            {
                // Match the API lock order; perform no network operations under a DB lock.
                await using var config = new NpgsqlCommand("select config::text from v_pbx_restore where domain_uuid=$1 for update", connection, tx);
                config.Parameters.AddWithValue(row.Domain);
                var raw = await config.ExecuteScalarAsync(ct) as string;
                await using var expiry = new NpgsqlCommand("select previous_profile,target_profile,extract(epoch from expires_at)::bigint from v_pbx_mobile_presence where domain_uuid=$1 and extension_uuid=$2 and expires_at<=now() for update", connection, tx);
                expiry.Parameters.AddWithValue(row.Domain); expiry.Parameters.AddWithValue(row.Extension);
                string? previous = null, target = null; epoch = 0;
                await using (var reader = await expiry.ExecuteReaderAsync(ct))
                    if (await reader.ReadAsync(ct)) { previous = reader.GetString(0); target = reader.GetString(1); epoch = reader.GetInt64(2); }
                if (previous is null) { await tx.CommitAsync(ct); continue; }
                var root = raw is null ? null : JsonNode.Parse(raw);
                var user = root?["users"]?[row.Number];
                // UUID and marker checks prevent an old expiry from changing a replacement
                // extension, a renewed temporary status or an administrator's selection.
                if (user?["extension_uuid"]?.GetValue<string>() == row.Extension.ToString()
                    && user["mobile_temporary"] is JsonNode temp && temp["expires"]?.GetValue<long>() == epoch
                    && temp["target"]?.GetValue<string>() == target && temp["previous"]?.GetValue<string>() == previous)
                {
                    if (user["profile"]?.GetValue<string>() == target && user["profiles"]?[previous] is not null) user["profile"] = previous;
                    user.AsObject().Remove("mobile_temporary");
                    await using var save = new NpgsqlCommand("update v_pbx_restore set config=$1::jsonb where domain_uuid=$2", connection, tx);
                    save.Parameters.AddWithValue(root!.ToJsonString()); save.Parameters.AddWithValue(row.Domain);
                    await save.ExecuteNonQueryAsync(ct);
                }
                await tx.CommitAsync(ct);
            }
            // Lua rereads the latest committed state. Concurrent requests may safely
            // repeat this idempotent operation without reverting a more recent status.
            try
            {
                var result = await engine.Execute($"lua app/pbx_setup/mobile_state.lua {row.Domain} {row.Number}", ct);
                if (!result.TrimStart().StartsWith("+OK", StringComparison.Ordinal)) continue;
                await using var remove = data.CreateCommand("delete from v_pbx_mobile_presence where domain_uuid=$1 and extension_uuid=$2 and expires_at<=now() and extract(epoch from expires_at)::bigint=$3");
                remove.Parameters.AddWithValue(row.Domain); remove.Parameters.AddWithValue(row.Extension); remove.Parameters.AddWithValue(epoch);
                await remove.ExecuteNonQueryAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex) { log.LogWarning("Phone agent refresh will retry ({ErrorType}).", ex.GetType().Name); }
        }
    }
}
