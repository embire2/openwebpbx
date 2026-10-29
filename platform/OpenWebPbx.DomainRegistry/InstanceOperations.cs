// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net;
using System.Text.RegularExpressions;
using Npgsql;
namespace OpenWebPbx.DomainRegistry;

/// <summary>Hold ownership decisions and DNS writes through final readback.</summary>
public sealed class InstanceOperations(RegistryOptions options,NpgsqlDataSource data) {
    private sealed class Lease(NpgsqlConnection connection):IAsyncDisposable {
        public ValueTask DisposeAsync()=>connection.DisposeAsync();
    }
    private async Task<IAsyncDisposable> Enter(string value,CancellationToken stop){
        // A physical, unpooled session always drops its advisory lock on close,
        // including cancellation or a failure during provider readback.
        var settings=new NpgsqlConnectionStringBuilder(options.ConnectionString){Pooling=false,Timeout=5,CommandTimeout=35};
        var connection=new NpgsqlConnection(settings.ConnectionString);
        try{await connection.OpenAsync(stop);await using var c=new NpgsqlCommand("select pg_advisory_lock(hashtextextended($1,0))",connection);c.Parameters.AddWithValue("openwebpbx-dns:"+value);await c.ExecuteNonQueryAsync(stop);return new Lease(connection);}
        catch{await connection.DisposeAsync();throw;}
    }
    public Task<IAsyncDisposable> Key(string hash,CancellationToken stop){if(!Regex.IsMatch(hash,"^[0-9a-f]{64}$"))throw new Refused("invalid_instance_key",400);return Enter("key:"+hash,stop);}
    public Task<IAsyncDisposable> Address(string address,CancellationToken stop){if(!IPAddress.TryParse(address,out var ip)||!PublicSiteProof.IsPublic(ip)||ip.ToString()!=address)throw new Refused("invalid_server_address",400);return Enter("address:"+address,stop);}
    public async Task<string?> AddressFor(string hash,string host,CancellationToken stop){await using var c=data.CreateCommand("select host(server_address) from registry_bootstrap where key_hash=$1 and server_host=$2");c.Parameters.AddWithValue(hash);c.Parameters.AddWithValue(host);return await c.ExecuteScalarAsync(stop)as string;}
}
