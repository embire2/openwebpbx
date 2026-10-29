// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net;
using System.Text.RegularExpressions;
using Npgsql;
namespace OpenWebPbx.DomainRegistry;

public sealed record LabelAvailabilityRequest(string Label);
public sealed record LabelAvailability(string Label,string Hostname,bool Available,string Scope="global",bool ReservationConfirmed=false);
public sealed record LabelReservationRequest(Guid AccountTenantUuid,Guid RequestUuid,string Label);
public sealed record LabelReservationAction(Guid AccountTenantUuid,Guid ReservationUuid);
public sealed record LabelReservationBind(Guid AccountTenantUuid,Guid ReservationUuid,string Label,string KeyHash,Guid DomainUuid,Guid LocalTenantUuid,Guid BootstrapUuid);
public sealed record LabelReservationReply(Guid ReservationUuid,string Label,string Hostname,string State,DateTimeOffset ExpiresAt);
public sealed record InstanceRevokeRequest(Guid AccountTenantUuid,Guid ReservationUuid,string ServerAddress,string? ExpectedServerHost=null,string? ExpectedKeyHash=null);
public sealed record InstanceRevokeReply(bool CleanupConfirmed,string State,string Scope);

public sealed class TenantReservations(NpgsqlDataSource data,IRegistryDns dns,InstanceOperations operations) {
    public static void Label(string label){Protocol.Label(label);if(Protocol.IsReserved(label)||label.StartsWith("node-",StringComparison.Ordinal))throw new Refused("invalid_tenant_label",400);}
    private static void Id(Guid value){if(value==Guid.Empty)throw new Refused("invalid_reservation",400);}
    private static NpgsqlCommand Command(NpgsqlConnection db,NpgsqlTransaction tx,string sql,params object[] values){var c=new NpgsqlCommand(sql,db,tx);foreach(var value in values)c.Parameters.AddWithValue(value);return c;}
    private static async Task Lock(NpgsqlConnection db,NpgsqlTransaction tx,CancellationToken stop){
        await using var c=Command(db,tx,"select pg_advisory_xact_lock(650146123);update registry_label_reservations set state='expired' where state in ('held','bound') and expires_at<=now()");await c.ExecuteNonQueryAsync(stop);
    }
    private static LabelReservationReply Reply(Guid id,string label,string state,DateTimeOffset expires)=>new(id,label,label+"."+RegistryOptions.Zone,state is "held" or "bound"?"reserved":state,expires);
    private static DateTimeOffset Deadline()=>new(DateTimeOffset.UtcNow.AddHours(1).Ticks/10*10,TimeSpan.Zero); // PostgreSQL microsecond precision.
    public async Task<LabelAvailability> Availability(string label,CancellationToken stop){
        Label(label);var names=await dns.Names(stop);
        await using var db=await data.OpenConnectionAsync(stop);await using var tx=await db.BeginTransactionAsync(stop);await Lock(db,tx,stop);
        await using var c=Command(db,tx,"select exists(select 1 from registry_leases where label=$1) or exists(select 1 from registry_label_reservations where label=$1 and state in ('held','bound'))",label);
        var used=await c.ExecuteScalarAsync(stop)is true;await tx.CommitAsync(stop);return new(label,label+"."+RegistryOptions.Zone,!used&&!names.Contains(label+"."+RegistryOptions.Zone));
    }
    public async Task<LabelReservationReply> Reserve(LabelReservationRequest r,CancellationToken stop){
        Id(r.AccountTenantUuid);Id(r.RequestUuid);Label(r.Label);var names=await dns.Names(stop);
        await using var db=await data.OpenConnectionAsync(stop);await using var tx=await db.BeginTransactionAsync(stop);await Lock(db,tx,stop);
        await using(var existing=Command(db,tx,"select reservation_uuid,label,state,expires_at from registry_label_reservations where account_tenant_uuid=$1 and request_uuid=$2",r.AccountTenantUuid,r.RequestUuid))
        await using(var rows=await existing.ExecuteReaderAsync(stop))if(await rows.ReadAsync(stop)){
            if(rows.GetString(1)!=r.Label)throw new Refused("reservation_request_changed",409);
            var state=rows.GetString(2);if(state is not("held" or "bound" or "consumed"))throw new Refused("reservation_expired",409);
            return Reply(rows.GetGuid(0),r.Label,state,rows.GetFieldValue<DateTimeOffset>(3));
        }
        await using(var used=Command(db,tx,"select exists(select 1 from registry_leases where label=$1) or exists(select 1 from registry_label_reservations where label=$1 and state in ('held','bound'))",r.Label))
            if(await used.ExecuteScalarAsync(stop)is true||names.Contains(r.Label+"."+RegistryOptions.Zone))throw new Refused("subdomain_unavailable",409);
        await using(var quota=Command(db,tx,"select count(*) from registry_label_reservations where account_tenant_uuid=$1 and state in ('held','bound')",r.AccountTenantUuid))
            if((long)(await quota.ExecuteScalarAsync(stop))!>=3)throw new Refused("reservation_limit",409);
        var id=Guid.NewGuid();var until=Deadline();
        await using(var insert=Command(db,tx,"insert into registry_label_reservations(reservation_uuid,account_tenant_uuid,request_uuid,label,state,expires_at)values($1,$2,$3,$4,'held',$5)",id,r.AccountTenantUuid,r.RequestUuid,r.Label,until))await insert.ExecuteNonQueryAsync(stop);
        await tx.CommitAsync(stop);return Reply(id,r.Label,"held",until);
    }
    public async Task<LabelReservationReply> Action(LabelReservationAction r,bool release,CancellationToken stop){
        Id(r.AccountTenantUuid);Id(r.ReservationUuid);await using var db=await data.OpenConnectionAsync(stop);await using var tx=await db.BeginTransactionAsync(stop);await Lock(db,tx,stop);
        string label,state;DateTimeOffset until,created;bool hasBinding;
        await using(var c=Command(db,tx,"select label,state,expires_at,created_at,key_hash from registry_label_reservations where reservation_uuid=$1 and account_tenant_uuid=$2 for update",r.ReservationUuid,r.AccountTenantUuid))
        await using(var rows=await c.ExecuteReaderAsync(stop)){if(!await rows.ReadAsync(stop))throw new Refused("reservation_unavailable",404);label=rows.GetString(0);state=rows.GetString(1);until=rows.GetFieldValue<DateTimeOffset>(2);created=rows.GetFieldValue<DateTimeOffset>(3);hasBinding=!rows.IsDBNull(4);}
        if(release){if(hasBinding||state is "bound" or "consumed" or "revoking")throw new Refused("instance_cleanup_required",409);if(state is "held" or "expired"){await using var c=Command(db,tx,"update registry_label_reservations set state='released' where reservation_uuid=$1",r.ReservationUuid);await c.ExecuteNonQueryAsync(stop);state="released";}}
        else if(state is "held" or "bound"){
            if(created<DateTimeOffset.UtcNow.AddDays(-1))throw new Refused("reservation_expired",409);until=Deadline();
            await using var c=Command(db,tx,"update registry_label_reservations set expires_at=$2 where reservation_uuid=$1",r.ReservationUuid,until);await c.ExecuteNonQueryAsync(stop);
        }else if(state!="consumed")throw new Refused("reservation_expired",409);
        await tx.CommitAsync(stop);return Reply(r.ReservationUuid,label,state,until);
    }
    public async Task<object> Bind(LabelReservationBind r,CancellationToken stop){
        Id(r.AccountTenantUuid);Id(r.ReservationUuid);Id(r.DomainUuid);Id(r.LocalTenantUuid);Id(r.BootstrapUuid);Label(r.Label);
        if(r.KeyHash is null||!Regex.IsMatch(r.KeyHash,"^[0-9a-f]{64}$"))throw new Refused("invalid_reservation_binding",400);
        await using var db=await data.OpenConnectionAsync(stop);await using var tx=await db.BeginTransactionAsync(stop);await Lock(db,tx,stop);
        await using(var c=Command(db,tx,"select state,key_hash,domain_uuid,local_tenant_uuid,bootstrap_uuid from registry_label_reservations where reservation_uuid=$1 and account_tenant_uuid=$2 and label=$3 for update",r.ReservationUuid,r.AccountTenantUuid,r.Label))
        await using(var rows=await c.ExecuteReaderAsync(stop)){
            if(!await rows.ReadAsync(stop)||rows.GetString(0)is not("held" or "bound" or "consumed"))throw new Refused("reservation_unavailable",409);
            if(!rows.IsDBNull(1)&&(rows.GetString(1)!=r.KeyHash||rows.GetGuid(2)!=r.DomainUuid||rows.GetGuid(3)!=r.LocalTenantUuid||rows.GetGuid(4)!=r.BootstrapUuid))throw new Refused("reservation_binding_changed",409);
        }
        await using(var c=Command(db,tx,"update registry_label_reservations set key_hash=$2,domain_uuid=$3,local_tenant_uuid=$4,bootstrap_uuid=$5,state=case when state='consumed' then state else 'bound' end where reservation_uuid=$1",r.ReservationUuid,r.KeyHash,r.DomainUuid,r.LocalTenantUuid,r.BootstrapUuid))await c.ExecuteNonQueryAsync(stop);
        await tx.CommitAsync(stop);return new{bound=true};
    }
    public async Task<InstanceRevokeReply> Revoke(InstanceRevokeRequest r,CancellationToken stop){
        Id(r.AccountTenantUuid);Id(r.ReservationUuid);if(!IPAddress.TryParse(r.ServerAddress,out var address)||!PublicSiteProof.IsPublic(address)||address.ToString()!=r.ServerAddress)throw new Refused("invalid_server_address",400);
        // The initial read only selects the guard. Recheck its immutable binding
        // inside the transaction, after address then instance locks, never while
        // holding the global ownership gate and waiting on an instance writer.
        string? selectedHash=null;Guid? selectedBootstrap=null;
        await using(var selected=data.CreateCommand("select key_hash,bootstrap_uuid from registry_label_reservations where reservation_uuid=$1 and account_tenant_uuid=$2")){
            selected.Parameters.AddWithValue(r.ReservationUuid);selected.Parameters.AddWithValue(r.AccountTenantUuid);
            await using var rows=await selected.ExecuteReaderAsync(stop);if(!await rows.ReadAsync(stop))throw new Refused("reservation_unavailable",404);
            if(!rows.IsDBNull(0)){selectedHash=rows.GetString(0);selectedBootstrap=rows.GetGuid(1);}
        }
        await using var addressGuard=await operations.Address(r.ServerAddress,stop);
        await using var instanceGuard=selectedHash is null?null:await operations.Key(selectedHash,stop);
        string? hash=null,host=null;Guid? bootstrap=null;var aliases=new List<string>();bool ownsBootstrap=false,alreadyCleaned=false;
        await using(var db=await data.OpenConnectionAsync(stop)){
            await using var tx=await db.BeginTransactionAsync(stop);await Lock(db,tx,stop);
            await using(var c=Command(db,tx,"select key_hash,bootstrap_uuid from registry_label_reservations where reservation_uuid=$1 and account_tenant_uuid=$2 for update",r.ReservationUuid,r.AccountTenantUuid))
            await using(var rows=await c.ExecuteReaderAsync(stop)){if(!await rows.ReadAsync(stop))throw new Refused("reservation_unavailable",404);if(!rows.IsDBNull(0)){hash=rows.GetString(0);bootstrap=rows.GetGuid(1);host="node-"+bootstrap.Value.ToString("N")+"."+RegistryOptions.Zone;}}
            if(hash!=selectedHash||bootstrap!=selectedBootstrap)throw new Refused("cleanup_binding_changed",409);
            if((r.ExpectedKeyHash is not null&&r.ExpectedKeyHash!=hash)||(r.ExpectedServerHost is not null&&r.ExpectedServerHost!=host))throw new Refused("cleanup_binding_changed",409);
            if(hash is null){
                await using var c=Command(db,tx,"select exists(select 1 from registry_bootstrap where server_address=$1::inet and state<>'cleaned')",r.ServerAddress);
                if(await c.ExecuteScalarAsync(stop)is true)throw new Refused("server_cleanup_unconfirmed",409);
                await using var done=Command(db,tx,"update registry_label_reservations set state='released' where reservation_uuid=$1",r.ReservationUuid);await done.ExecuteNonQueryAsync(stop);await tx.CommitAsync(stop);return new(true,"released","reservation_only");
            }
            await using(var c=Command(db,tx,"select account_tenant_uuid,key_hash,host(server_address),server_host,state from registry_bootstrap where instance_uuid=$1 for update",bootstrap!.Value))
            await using(var rows=await c.ExecuteReaderAsync(stop))if(await rows.ReadAsync(stop)){
                if(rows.GetGuid(0)!=r.AccountTenantUuid||rows.GetString(1)!=hash||rows.GetString(2)!=r.ServerAddress||rows.GetString(3)!=host)throw new Refused("cleanup_binding_changed",409);ownsBootstrap=rows.GetString(4)!="revoked_unregistered";
                alreadyCleaned=rows.GetString(4)=="cleaned";
            }
            if(alreadyCleaned){await using var done=Command(db,tx,"update registry_label_reservations set state='released' where reservation_uuid=$1",r.ReservationUuid);await done.ExecuteNonQueryAsync(stop);await tx.CommitAsync(stop);return new(true,"revoked","instance");}
            await using(var other=Command(db,tx,"select exists(select 1 from registry_bootstrap where server_address=$1::inet and key_hash<>$2 and state<>'cleaned')",r.ServerAddress,hash))
                if(await other.ExecuteScalarAsync(stop)is true)throw new Refused("server_cleanup_unconfirmed",409);
            if(ownsBootstrap){
                await using(var c=Command(db,tx,"select label from registry_leases where key_hash=$1 and server_host=$2",hash,host!))await using(var rows=await c.ExecuteReaderAsync(stop))while(await rows.ReadAsync(stop))aliases.Add(rows.GetString(0));
                await using(var c=Command(db,tx,"update registry_bootstrap set state='revoked' where instance_uuid=$1",bootstrap!.Value))await c.ExecuteNonQueryAsync(stop);
                await using(var c=Command(db,tx,"update registry_leases set enabled=false,state='disabled',updated_at=now() where key_hash=$1",hash))await c.ExecuteNonQueryAsync(stop);
            }else{
                // A cancelled, not-yet-started bootstrap needs a tombstone too.
                // It does not establish ownership of a pre-existing DNS record.
                await using var c=Command(db,tx,"insert into registry_bootstrap(instance_uuid,account_tenant_uuid,key_hash,local_tenant_uuid,domain_uuid,server_address,label,server_host,state) select bootstrap_uuid,account_tenant_uuid,key_hash,local_tenant_uuid,domain_uuid,$2::inet,label,$3,'revoked_unregistered' from registry_label_reservations where reservation_uuid=$1 on conflict(instance_uuid) do nothing",r.ReservationUuid,r.ServerAddress,host!);
                await c.ExecuteNonQueryAsync(stop);
            }
            await using(var c=Command(db,tx,"update registry_label_reservations set state='revoking' where reservation_uuid=$1",r.ReservationUuid))await c.ExecuteNonQueryAsync(stop);await tx.CommitAsync(stop);
        }
        if(ownsBootstrap){
            foreach(var label in aliases)await dns.RemoveOwned(label+"."+RegistryOptions.Zone,"CNAME",host!,stop);
            await dns.RemoveOwned(host!,address.AddressFamily==System.Net.Sockets.AddressFamily.InterNetwork?"A":"AAAA",r.ServerAddress,stop);
        }
        else if((await dns.Names(stop)).Contains(host!))throw new Refused("server_cleanup_unconfirmed",409);
        await using(var cleaned=data.CreateCommand("update registry_bootstrap set state='cleaned' where instance_uuid=$1 and key_hash=$2 and state in ('revoked','revoked_unregistered')")){cleaned.Parameters.AddWithValue(bootstrap!.Value);cleaned.Parameters.AddWithValue(hash!);if(await cleaned.ExecuteNonQueryAsync(stop)!=1)throw new Refused("cleanup_binding_changed",409);}
        await using(var c=data.CreateCommand("update registry_label_reservations set state='released' where reservation_uuid=$1 and account_tenant_uuid=$2")){c.Parameters.AddWithValue(r.ReservationUuid);c.Parameters.AddWithValue(r.AccountTenantUuid);await c.ExecuteNonQueryAsync(stop);}
        return new(true,"revoked",ownsBootstrap?"instance":"bound_without_dns");
    }
}
