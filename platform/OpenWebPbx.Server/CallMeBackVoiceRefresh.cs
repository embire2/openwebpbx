using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Npgsql;

namespace OpenWebPbx.Server;

// Refreshes only an old generator-owned cache. Its ready/enabled state and old
// audio remain available while the new narrator is prepared off the live path.
internal sealed class CallMeBackVoiceRefresh(IConfiguration settings, ILogger log)
{
    public static async Task RecoverExpired(NpgsqlConnection db,CancellationToken ct)
    {
        await using var expired=new NpgsqlCommand("""
            update v_pbx_cmb_services set prompt_refresh_state='blocked',prompt_refresh_token=null,prompt_refresh_until=null,
             prompt_refresh_after=null,prompt_refresh_message='Keoma preparation was interrupted three times. Existing audio remains available. Review and retry preparation.'
            where prompt_version='1.0.1' and prompt_state='ready' and prompt_refresh_state='preparing'
             and prompt_refresh_token is not null and prompt_refresh_attempts>=3 and prompt_refresh_until<now()
            """,db);
        await expired.ExecuteNonQueryAsync(ct);
    }
    public static async Task MissingKey(NpgsqlConnection db, CancellationToken ct)
    {
        await using var status=new NpgsqlCommand("""
            update v_pbx_cmb_services set prompt_refresh_message='Keoma preparation needs the instance voice service. Existing audio remains available.',
             prompt_refresh_after=now()+interval '1 minute'
            where prompt_version='1.0.1' and prompt_state='ready' and prompt_refresh_state in ('pending','preparing')
             and (prompt_refresh_until is null or prompt_refresh_until<now()) and (prompt_refresh_after is null or prompt_refresh_after<=now())
            """,db);
        await status.ExecuteNonQueryAsync(ct);
    }

    public async Task Run(NpgsqlConnection db, Func<string,CancellationToken,Task<byte[]>> synthesize, CancellationToken ct)
    {
        Guid id,token;string name,oldHash;
        await using(var claim=new NpgsqlCommand("""
            with chosen as(select s.service_uuid from v_pbx_cmb_services s join v_domains d using(domain_uuid)
             where s.prompt_version='1.0.1' and s.prompt_state='ready' and s.prompt_audio_file='greeting.wav' and s.prompt_refresh_attempts<3
              and d.domain_enabled='true' and not exists(select 1 from v_pbx_services p join v_pbx_tenants t using(tenant_uuid) where p.domain_uuid=s.domain_uuid and not t.enabled)
              and (s.prompt_refresh_state='pending' or (s.prompt_refresh_state='preparing' and s.prompt_refresh_until<now()))
              and (s.prompt_refresh_after is null or s.prompt_refresh_after<=now())
             order by s.created_at,s.service_uuid for update of s skip locked limit 1)
            update v_pbx_cmb_services s set prompt_refresh_state='preparing',prompt_refresh_token=gen_random_uuid(),
             prompt_refresh_until=now()+interval '3 minutes',prompt_refresh_attempts=prompt_refresh_attempts+1,
             prompt_refresh_message='Preparing Keoma. Existing audio remains available.'
             from chosen where s.service_uuid=chosen.service_uuid returning s.service_uuid,s.name,s.prompt_sha256,s.prompt_refresh_token
            """,db))
        await using(var reader=await claim.ExecuteReaderAsync(ct)) {
            if(!await reader.ReadAsync(ct))return;
            id=reader.GetGuid(0);name=reader.GetString(1);oldHash=reader.IsDBNull(2)?"":reader.GetString(2);token=reader.GetGuid(3);
        }
        string? temporary=null;
        var root=settings["CallMeBack:PromptRoot"]??(OperatingSystem.IsWindows()
            ?Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"OpenWebPBX","storage","openwebpbx","call-me-back")
            :"/var/lib/freeswitch/storage/openwebpbx/call-me-back");
        var live=Path.Combine(root,id.ToString("D"),"greeting.wav");
        try {
            if(!Regex.IsMatch(oldHash,@"\A[a-f0-9]{64}\z")||await Hash(live,ct)!=oldHash)
                throw new CustomGreetingException();
            var newAudio=await synthesize(name,ct);
            var nextHash=Convert.ToHexStringLower(SHA256.HashData(newAudio));
            temporary=Path.Combine(Path.GetDirectoryName(live)!,".keoma-"+token.ToString("N")+".tmp");
            var selected="greeting-keoma-"+nextHash+".wav";
            var candidate=Path.Combine(Path.GetDirectoryName(live)!,selected);
            if(File.Exists(temporary))throw new IOException("An owned preparation path already exists.");
            await using(var stream=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                await stream.WriteAsync(newAudio,ct);await stream.FlushAsync(ct);stream.Flush(true);
            }
            if(!OperatingSystem.IsWindows())File.SetUnixFileMode(temporary,File.GetUnixFileMode(live));
            // Publish an immutable candidate first. A crash or DB refusal can
            // leave an unselected file, never new bytes under the old live hash.
            try { File.Move(temporary,candidate,false);temporary=null; }
            catch(IOException)when(File.Exists(candidate)) { }
            if(await Hash(candidate,ct)!=nextHash)throw new CustomGreetingException();
            await using var transaction=await db.BeginTransactionAsync(ct);
            await using var guard=new NpgsqlCommand("""
                select 1 from v_pbx_cmb_services where service_uuid=$1 and name=$2 and prompt_version='1.0.1'
                 and prompt_state='ready' and prompt_audio_file='greeting.wav' and prompt_sha256=$3 and prompt_refresh_token=$4 and prompt_refresh_state='preparing'
                 and prompt_refresh_until>now() for update
                """,db,transaction);
            guard.Parameters.AddWithValue(id);guard.Parameters.AddWithValue(name);guard.Parameters.AddWithValue(oldHash);guard.Parameters.AddWithValue(token);
            if(await guard.ExecuteScalarAsync(ct) is null)throw new ChangedRequestException();
            if(await Hash(live,ct)!=oldHash)throw new CustomGreetingException();
            if(await Hash(candidate,ct)!=nextHash)throw new CustomGreetingException();
            await using var update=new NpgsqlCommand("""
                update v_pbx_cmb_services set prompt_version='1.0.2',prompt_sha256=$2,prompt_audio_file=$4,prompt_refresh_state='complete',
                 prompt_refresh_token=null,prompt_refresh_until=null,prompt_refresh_after=null,prompt_refresh_message='Keoma greeting ready.'
                where service_uuid=$1 and prompt_refresh_token=$3
                """,db,transaction);
            update.Parameters.AddWithValue(id);update.Parameters.AddWithValue(nextHash);update.Parameters.AddWithValue(token);update.Parameters.AddWithValue(selected);
            if(await update.ExecuteNonQueryAsync(ct)!=1)throw new ChangedRequestException();
            await transaction.CommitAsync(ct);
        } catch(OperationCanceledException)when(ct.IsCancellationRequested){throw;}
        catch(Exception error) {
            var message=error is CustomGreetingException?"Custom or changed audio was preserved. Review the greeting before retrying.":
                error is ChangedRequestException?"The service changed during preparation. Its current audio and settings were preserved.":
                "Keoma preparation could not finish. Existing audio remains available. Retry after checking the instance voice service.";
            try {
                await using var failed=new NpgsqlCommand("""
                    update v_pbx_cmb_services set prompt_refresh_state=case when $3 or prompt_refresh_attempts>=3 then 'blocked' else 'pending' end,
                     prompt_refresh_token=null,prompt_refresh_until=null,prompt_refresh_after=now()+make_interval(secs=>60*greatest(1,prompt_refresh_attempts)),
                     prompt_refresh_message=$4 where service_uuid=$1 and prompt_refresh_token=$2
                    """,db);
                failed.Parameters.AddWithValue(id);failed.Parameters.AddWithValue(token);
                failed.Parameters.AddWithValue(error is CustomGreetingException or ChangedRequestException);failed.Parameters.AddWithValue(message);
                await failed.ExecuteNonQueryAsync(CancellationToken.None);
            } catch(Exception failure)when(failure is NpgsqlException or IOException){ }
            log.LogWarning("Previous system greeting preparation retained its active audio ({ErrorType}).",error.GetType().Name);
        } finally {
            if(temporary is not null)File.Delete(temporary);
            // Keep published hash-named candidates: an uncertain commit must
            // never remove the file selected by a successful transaction.
        }
    }
    private static async Task<string> Hash(string path,CancellationToken ct)
    {
        for(var p=path;p is not null;p=Path.GetDirectoryName(p))if((File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0)throw new IOException("Greeting path is linked.");
        await using var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete);
        if(stream.Length is <44 or >3840044)throw new CustomGreetingException();
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream,ct));
    }
    private sealed class CustomGreetingException:IOException {}
    private sealed class ChangedRequestException:IOException {}
}
