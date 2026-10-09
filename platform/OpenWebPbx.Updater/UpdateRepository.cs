using Npgsql;
using NpgsqlTypes;
using System.Text.Json;

namespace OpenWebPbx.Updater;

public sealed class UpdateRepository(NpgsqlDataSource data)
{
    public async Task<UpdatePolicy> Policy(CancellationToken ct)
    {
        await using var command = data.CreateCommand("select mode,maintenance_hour,maintenance_duration from v_pbx_update_policies where scope_key='instance'");
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return new("notify", 2, 2);
        return new(reader.GetString(0), reader.GetInt32(1), reader.GetInt32(2));
    }
    public async Task<UpdateCommand?> Claim(CancellationToken ct)
    {
        await using (var expired = data.CreateCommand("update v_pbx_update_commands set status='failed',finished_at=now(),message='This installation request expired. Request the update again when ready' where status='pending' and action='install' and created_at<now()-interval '24 hours'")) await expired.ExecuteNonQueryAsync(ct);
        await using var command = data.CreateCommand("with next as (select command_uuid from v_pbx_update_commands where status='pending' order by created_at for update skip locked limit 1) update v_pbx_update_commands set status='running',started_at=now(),message='Checking for updates' where command_uuid=(select command_uuid from next) returning command_uuid,action,created_at");
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? new(reader.GetGuid(0), reader.GetString(1), reader.GetFieldValue<DateTimeOffset>(2)) : null;
    }
    public async Task<List<UpdateCommand>> Running(CancellationToken ct)
    {
        var rows = new List<UpdateCommand>();
        await using var command = data.CreateCommand("select command_uuid,action,created_at from v_pbx_update_commands where status='running' order by created_at");
        await using var reader = await command.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) rows.Add(new(reader.GetGuid(0), reader.GetString(1), reader.GetFieldValue<DateTimeOffset>(2)));
        return rows;
    }
    public async Task Finish(UpdateCommand command, bool success, string message, CancellationToken ct)
    {
        await using var sql = data.CreateCommand("update v_pbx_update_commands set status=$2,message=$3,finished_at=now() where command_uuid=$1 and status='running'");
        sql.Parameters.AddWithValue(command.Id); sql.Parameters.AddWithValue(success ? "completed" : "failed"); sql.Parameters.AddWithValue(message);
        await sql.ExecuteNonQueryAsync(ct);
    }
    public async Task Retry(UpdateCommand command, string message, CancellationToken ct)
    {
        await using var sql = data.CreateCommand("update v_pbx_update_commands set status='pending',started_at=null,message=$2 where command_uuid=$1 and status='running'");
        sql.Parameters.AddWithValue(command.Id); sql.Parameters.AddWithValue(message); await sql.ExecuteNonQueryAsync(ct);
    }
    public async Task Status(UpdateStatus status, CancellationToken ct)
    {
        await using var sql = data.CreateCommand("insert into v_pbx_update_status(singleton,status_json,updated_at) values(1,$1,now()) on conflict(singleton) do update set status_json=excluded.status_json,updated_at=now()");
        sql.Parameters.AddWithValue(NpgsqlDbType.Jsonb, JsonSerializer.Serialize(status, UpdateJson.Options)); await sql.ExecuteNonQueryAsync(ct);
    }
    public async Task Heartbeat(CancellationToken ct)
    {
        await using var command = data.CreateCommand("update v_pbx_update_status set updated_at=now() where singleton=1"); await command.ExecuteNonQueryAsync(ct);
    }
}
