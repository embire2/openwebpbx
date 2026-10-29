// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Npgsql;
namespace OpenWebPbx.DomainRegistry;

public sealed record InstanceProofRequest(string ServerHost,string Nonce,string KeyHash);
public sealed record BootstrapRequest(Guid InstallationUuid,Guid AccountTenantUuid,string ServerAddress,string Nonce,string KeyHash,Guid LocalTenantUuid,Guid DomainUuid,string Label,string Signature,string PublicKey);
public sealed record BootstrapReply(string ServerHost,string Address,string State);
public sealed record TenantReadyRequest(string Hostname,string ServerHost,string KeyHash,Guid DomainUuid,string Nonce);
public interface IBootstrapProof { Task Verify(IPAddress address,string nonce,string keyHash,CancellationToken stop); }
public sealed class BootstrapProof : IBootstrapProof {
    public async Task Verify(IPAddress address,string nonce,string keyHash,CancellationToken stop) {
        if (!PublicSiteProof.IsPublic(address)) throw new Refused("bootstrap_public_address_required",403);
        using var handler=new SocketsHttpHandler{AllowAutoRedirect=false,UseProxy=false,ConnectTimeout=TimeSpan.FromSeconds(5)};
        handler.ConnectCallback=async(context,token)=>{
            if (context.DnsEndPoint.Port!=80 || !IPAddress.TryParse(context.DnsEndPoint.Host,out var parsed) || !parsed.Equals(address)) throw new Refused("bootstrap_proof_endpoint",403);
            var socket=new Socket(address.AddressFamily,SocketType.Stream,ProtocolType.Tcp);
            try {await socket.ConnectAsync(new IPEndPoint(address,80),token);return new NetworkStream(socket,true);}catch{socket.Dispose();throw;}
        };
        using var client=new HttpClient(handler){Timeout=TimeSpan.FromSeconds(12),MaxResponseContentBufferSize=1024};
        var host=address.AddressFamily==AddressFamily.InterNetworkV6?"["+address+"]":address.ToString();
        using var response=await client.GetAsync("http://"+host+"/.well-known/openwebpbx-instance/"+nonce,stop);
        var actual=await response.Content.ReadAsByteArrayAsync(stop);var expected=Encoding.ASCII.GetBytes("openwebpbx-bootstrap-v1\n"+nonce+"\n"+keyHash+"\n"+address+"\n");
        if(response.StatusCode!=HttpStatusCode.OK || !CryptographicOperations.FixedTimeEquals(actual,expected)) throw new Refused("bootstrap_public_proof_failed",403);
    }
}
public sealed class InstanceBootstrap(NpgsqlDataSource data,IRegistryDns dns,IBootstrapProof proof) {
    public static byte[] Message(BootstrapRequest r)=>Encoding.ASCII.GetBytes($"openwebpbx-bootstrap-v1\n{r.Nonce}\n{r.ServerAddress}\n{r.KeyHash}\n{r.InstallationUuid:D}\n{r.AccountTenantUuid:D}\n{r.LocalTenantUuid:D}\n{r.DomainUuid:D}\n{r.Label}\n");
    public async Task<BootstrapReply> Register(BootstrapRequest request,CancellationToken stop) {
        if (request.InstallationUuid==Guid.Empty || request.AccountTenantUuid==Guid.Empty || request.LocalTenantUuid==Guid.Empty || request.DomainUuid==Guid.Empty
            || request.Nonce is null || !Regex.IsMatch(request.Nonce,"^[0-9a-f]{64}$") || !IPAddress.TryParse(request.ServerAddress,out var address)
            || !PublicSiteProof.IsPublic(address) || request.ServerAddress!=address.ToString() || request.KeyHash!=Protocol.KeyHash(request.PublicKey)
            || Protocol.IsReserved(Protocol.Label(request.Label))) throw new Refused("invalid_bootstrap_request",400);
        try {
            using var key=ECDsa.Create();key.ImportSubjectPublicKeyInfo(Convert.FromBase64String(request.PublicKey),out _);
            if(request.Signature is null || request.Signature.Length>200 || !key.VerifyData(Message(request),Convert.FromBase64String(request.Signature),HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence)) throw new Refused("bootstrap_signature_invalid",403);
        }catch(FormatException){throw new Refused("bootstrap_signature_invalid",403);}
        await proof.Verify(address,request.Nonce,request.KeyHash,stop);
        var host="node-"+request.InstallationUuid.ToString("N")+"."+RegistryOptions.Zone;
        await using(var db=await data.OpenConnectionAsync(stop)) {
            await using var tx=await db.BeginTransactionAsync(stop);
            await using(var gate=new NpgsqlCommand("select pg_advisory_xact_lock(650146123)",db,tx))await gate.ExecuteNonQueryAsync(stop);
            await using var select=new NpgsqlCommand("select instance_uuid,account_tenant_uuid,host(server_address),label,server_host,local_tenant_uuid,domain_uuid,key_hash from registry_bootstrap where instance_uuid=$1 or key_hash=$2 for update",db,tx);
            select.Parameters.AddWithValue(request.InstallationUuid);select.Parameters.AddWithValue(request.KeyHash);
            await using(var rows=await select.ExecuteReaderAsync(stop)) {
                while(await rows.ReadAsync(stop)) {
                    if(rows.GetGuid(0)!=request.InstallationUuid || rows.GetGuid(1)!=request.AccountTenantUuid || rows.GetString(2)!=request.ServerAddress
                        || rows.GetString(3)!=request.Label || rows.GetString(4)!=host || rows.GetGuid(5)!=request.LocalTenantUuid || rows.GetGuid(6)!=request.DomainUuid || rows.GetString(7)!=request.KeyHash)
                        throw new Refused("bootstrap_ownership_conflict",409);
                }
            }
            await using var insert=new NpgsqlCommand("insert into registry_bootstrap(instance_uuid,account_tenant_uuid,key_hash,local_tenant_uuid,domain_uuid,server_address,label,server_host) values($1,$2,$3,$4,$5,$6::inet,$7,$8) on conflict(instance_uuid) do nothing",db,tx);
            foreach(var item in new object[]{request.InstallationUuid,request.AccountTenantUuid,request.KeyHash,request.LocalTenantUuid,request.DomainUuid,request.ServerAddress,request.Label,host})insert.Parameters.AddWithValue(item);
            await insert.ExecuteNonQueryAsync(stop);await tx.CommitAsync(stop);
        }
        await dns.EnsureAddress("node-"+request.InstallationUuid.ToString("N"),address,stop);
        return new(host,address.ToString(),"dns_ready");
    }
    public async Task<bool> Matches(LeaseRequest r,string hash,InstallationBinding binding,CancellationToken stop) {
        if(!Protocol.IsBootstrapHost(r.ServerHost))return true;
        // Additional local tenants have their own signed receipts on the same
        // operator-controlled installation key and canonical bootstrap host.
        await using var command=data.CreateCommand("select exists(select 1 from registry_bootstrap where key_hash=$1 and server_host=$2)");
        foreach(var item in new object[]{hash,r.ServerHost})command.Parameters.AddWithValue(item);
        return await command.ExecuteScalarAsync(stop)is true;
    }
}
