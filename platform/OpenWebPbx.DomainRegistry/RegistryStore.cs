// SPDX-License-Identifier: AGPL-3.0-or-later
using Npgsql;
using System.Security.Cryptography;
namespace OpenWebPbx.DomainRegistry;
public sealed record ReservedLease(string Label, string? DnsHost, long Revision);
public sealed class RegistryStore(NpgsqlDataSource data, RegistryOptions options) {
    public async Task Initialize(CancellationToken stop) {
        await using var command = data.CreateCommand("""
        create table if not exists registry_instances(key_hash text primary key,public_key text not null,server_host text not null unique,verified_at timestamptz not null);
        create table if not exists registry_challenges(nonce text primary key,key_hash text not null,server_host text not null,expires_at timestamptz not null,used boolean not null default false);
        create table if not exists registry_leases(key_hash text not null references registry_instances(key_hash),domain_uuid uuid not null,tenant_uuid uuid not null,label text not null unique,server_host text not null,dns_host text,enabled boolean not null,state text not null,revision bigint not null default 1,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),primary key(key_hash,domain_uuid));
        """);
        await command.ExecuteNonQueryAsync(stop);
    }
    public async Task<ChallengeReply> Challenge(string hash, string host, CancellationToken stop) {
        var nonce = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32)); var until = DateTimeOffset.UtcNow.AddMinutes(5);
        await using (var cleanup = data.CreateCommand("delete from registry_challenges where expires_at<now()")) await cleanup.ExecuteNonQueryAsync(stop);
        await using var command = data.CreateCommand("insert into registry_challenges(nonce,key_hash,server_host,expires_at) values($1,$2,$3,$4)");
        command.Parameters.AddWithValue(nonce); command.Parameters.AddWithValue(hash); command.Parameters.AddWithValue(host); command.Parameters.AddWithValue(until);
        await command.ExecuteNonQueryAsync(stop); return new(nonce, until);
    }
    public async Task CheckChallenge(string nonce, string hash, string host, CancellationToken stop) {
        await using var command = data.CreateCommand("select exists(select 1 from registry_challenges where nonce=$1 and key_hash=$2 and server_host=$3 and expires_at>now() and not used)");
        command.Parameters.AddWithValue(nonce); command.Parameters.AddWithValue(hash); command.Parameters.AddWithValue(host);
        if (!(bool)(await command.ExecuteScalarAsync(stop))!) throw new Refused("challenge_expired_or_used", 403);
    }
    public async Task<ReservedLease> Reserve(LeaseRequest request, string hash, IReadOnlySet<string> dnsNames, CancellationToken stop) {
        await using var db = await data.OpenConnectionAsync(stop); await using var tx = await db.BeginTransactionAsync(stop);
        async Task<object?> Scalar(string sql, params object[] values) { await using var c = new NpgsqlCommand(sql, db, tx); foreach (var v in values) c.Parameters.AddWithValue(v); return await c.ExecuteScalarAsync(stop); }
        // One central ownership transaction serializes name selection, key/host
        // registration and moves. DNS itself additionally uses the provider SOA CAS.
        await Scalar("select pg_advisory_xact_lock(650146123)");
        if (await Scalar("update registry_challenges set used=true where nonce=$1 and key_hash=$2 and server_host=$3 and expires_at>now() and not used returning nonce", request.Challenge, hash, request.ServerHost) is null) throw new Refused("challenge_expired_or_used", 403);
        var other = await Scalar("select key_hash from registry_instances where server_host=$1", request.ServerHost);
        if (other is string owner && owner != hash) throw new Refused("hostname_owned_by_another_instance", 409);
        var existingInstance = await Scalar("select server_host from registry_instances where key_hash=$1", hash);
        await using var select = new NpgsqlCommand("select tenant_uuid,label,dns_host,revision,server_host from registry_leases where key_hash=$1 and domain_uuid=$2 for update", db, tx);
        select.Parameters.AddWithValue(hash); select.Parameters.AddWithValue(request.DomainUuid);
        string label; string? dnsHost; long revision; string? oldHost = null;
        await using (var reader = await select.ExecuteReaderAsync(stop)) {
            if (await reader.ReadAsync(stop)) {
                if (reader.GetGuid(0) != request.TenantUuid) throw new Refused("tenant_ownership_changed", 409);
                label = reader.GetString(1); dnsHost = reader.IsDBNull(2) ? null : reader.GetString(2); revision = reader.GetInt64(3); oldHost = reader.GetString(4);
                if (oldHost != request.ServerHost) {
                    if (!request.Move || request.Revision != revision) throw new Refused("explicit_host_move_revision_required", 409);
                    revision++;
                } else if (request.Revision != revision && !(revision == 1 && request.Revision == 0 && !request.Move)) {
                    // A successful creation reply can be lost. Only the original
                    // revision may be recovered with a fresh nonce by its exact
                    // key/domain/tenant and unchanged verified host. Never adopt
                    // a later revision or authorize an implicit host move.
                    throw new Refused("lease_revision_conflict", 409);
                }
            } else {
                if (request.Move || request.Revision != 0) throw new Refused("unknown_lease_revision", 409);
                label = request.Label; dnsHost = null; revision = 1;
            }
        }
        if (existingInstance is string previousHost && previousHost != request.ServerHost) {
            // Move is per-lease. An ordinary renewal cannot move any lease,
            // and old instances with the same key cannot silently move it back.
            if (!request.Move || oldHost is null) throw new Refused("explicit_host_move_revision_required", 409);
        }
        if (oldHost is null) {
            if ((long)(await Scalar("select count(*) from registry_leases where key_hash=$1", hash))! >= options.MaximumLeasesPerInstance) throw new Refused("instance_alias_limit", 409);
            var taken = await Scalar("select exists(select 1 from registry_leases where label=$1)", label);
            if (Protocol.IsReserved(label) || dnsNames.Contains(label + "." + RegistryOptions.Zone) || (bool)taken!) label = Protocol.CollisionLabel(label, hash, request.DomainUuid);
            if (Protocol.IsReserved(label) || dnsNames.Contains(label + "." + RegistryOptions.Zone) || (bool)(await Scalar("select exists(select 1 from registry_leases where label=$1)", label))!) throw new Refused("alias_collision_needs_review", 409);
        }
        await Scalar("insert into registry_instances values($1,$2,$3,now()) on conflict(key_hash) do update set server_host=excluded.server_host,verified_at=now() returning key_hash", hash, request.PublicKey, request.ServerHost);
        await Scalar("insert into registry_leases(key_hash,domain_uuid,tenant_uuid,label,server_host,enabled,state,revision) values($1,$2,$3,$4,$5,$6,$7,$8) on conflict(key_hash,domain_uuid) do update set server_host=excluded.server_host,enabled=excluded.enabled,state=excluded.state,revision=excluded.revision,updated_at=now() returning label", hash, request.DomainUuid, request.TenantUuid, label, request.ServerHost, request.Enabled, request.Enabled ? "pending_dns" : "disabled", revision);
        await tx.CommitAsync(stop); return new(label, dnsHost, revision);
    }
    public async Task Ready(string hash, Guid domain, string host, long revision, CancellationToken stop) {
        await using var command = data.CreateCommand("update registry_leases set dns_host=$3,state='dns_ready',updated_at=now() where key_hash=$1 and domain_uuid=$2 and server_host=$3 and revision=$4 and enabled");
        command.Parameters.AddWithValue(hash); command.Parameters.AddWithValue(domain); command.Parameters.AddWithValue(host); command.Parameters.AddWithValue(revision);
        if (await command.ExecuteNonQueryAsync(stop) != 1) throw new Refused("lease_revision_conflict", 409);
    }
}
