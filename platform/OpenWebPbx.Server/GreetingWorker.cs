using System.Net.Http.Json;
using System.Text;
using Npgsql;

namespace OpenWebPbx.Server;

/// <summary>Tenant greeting preparation is separate from live calling and never exposes provider credentials to the web UI.</summary>
public sealed class GreetingWorker(NpgsqlDataSource data, IHttpClientFactory clients, IConfiguration settings,
    SwitchClient engine, ILogger<GreetingWorker> log) : BackgroundService
{
    public const string Voice = "i8SlcaZfyeP1st7wHsjM";
    public static string Introduction(string company, string category) =>
        $"You are about to create {Category(category)} for {company} - leave your message after the tone then press hash.";
    public static string Category(string category) => category switch {
        "voicemail" => "a voicemail greeting", "receptionist" => "a Digital Receptionist greeting", "queue_intro" => "a queue welcome greeting",
        "queue_wait" => "a queue waiting announcement", "hold_music" => "music on hold", "announcement" => "an announcement",
        _ => throw new InvalidDataException("Unknown greeting category.")
    };
    private string Root => settings["Greetings:MediaRoot"] ?? (OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "storage", "openwebpbx")
        : "/var/lib/freeswitch/storage/openwebpbx");
    private CancellationTokenSource ProviderDeadline(CancellationToken ct)
    {
        var configured=settings["Greetings:ProviderTimeoutSeconds"];
        if (configured is not null && (!int.TryParse(configured,out var value) || value is <1 or >90))
            throw new InvalidDataException("The greeting provider deadline must be between one and ninety seconds.");
        var timeout=CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(configured is null?90:int.Parse(configured)));
        return timeout;
    }
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        do {
            try { await Tick(stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogWarning("Greeting preparation needs attention ({ErrorType}).", ex.GetType().Name); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
    public async Task Tick(CancellationToken ct)
    {
        // Reuse the native shared-read lease and durable maintenance hold. It
        // must cover heartbeat, preparation and dispatch, before any DB access.
        using var maintenance=OperatingSystem.IsWindows()
            ? WindowsCallRecordLease.TryAcquire(settings["Greetings:StateRoot"] ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"OpenWebPBX"))
            : null;
        if (OperatingSystem.IsWindows() && maintenance is null) return;
        await using var db = await data.OpenConnectionAsync(ct);
        await using (var installed = new NpgsqlCommand("select to_regclass('v_pbx_greetings') is not null and to_regclass('v_pbx_greeting_uses') is not null and to_regclass('v_pbx_greeting_status') is not null",db))
            if (await installed.ExecuteScalarAsync(ct) is not true) return;
        await using (var status = new NpgsqlCommand("insert into v_pbx_greeting_status(singleton,provider_configured,checked_at) values(1,$1,now()) on conflict(singleton) do update set provider_configured=excluded.provider_configured,checked_at=now()",db)) {
            status.Parameters.AddWithValue(!string.IsNullOrWhiteSpace(settings["ElevenLabs:ApiKey"]));await status.ExecuteNonQueryAsync(ct);
        }
        await using (var expired = new NpgsqlCommand("update v_pbx_greetings set state='failed',last_result='Preparation interrupted. Choose Retry.',lease_until=null,updated_at=now() where state='preparing' and lease_until<now()",db)) await expired.ExecuteNonQueryAsync(ct);
        if (!string.IsNullOrWhiteSpace(settings["ElevenLabs:ApiKey"])) await Prepare(db,ct);
        await Dispatch(db,ct);
    }
    private async Task Prepare(NpgsqlConnection db, CancellationToken ct)
    {
        Guid id, domain; string source, company, category, script, name;
        await using (var claim = new NpgsqlCommand("""
            with chosen as(select g.greeting_uuid from v_pbx_greetings g join v_domains d using(domain_uuid)
             join v_users u on u.user_uuid=g.created_by where g.state='pending' and g.attempts<3 and d.domain_enabled='true' and u.user_enabled='true'
             and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=g.domain_uuid and not t.enabled)
             order by g.created_at for update of g skip locked limit 1)
            update v_pbx_greetings g set state='preparing',attempts=attempts+1,lease_until=now()+interval '10 minutes',updated_at=now()
             from chosen where g.greeting_uuid=chosen.greeting_uuid returning g.greeting_uuid,g.domain_uuid,g.source,g.company_name,g.category,g.script,g.name
            """,db))
        await using (var reader=await claim.ExecuteReaderAsync(ct)) {
            if (!await reader.ReadAsync(ct)) return;
            id=reader.GetGuid(0);domain=reader.GetGuid(1);source=reader.GetString(2);company=reader.GetString(3);category=reader.GetString(4);script=reader.GetString(5);name=reader.GetString(6);
        }
        var directory=Path.Combine(Root,domain.ToString("D"),"greetings",id.ToString("D"));
        try {
            Directory.CreateDirectory(directory);
            for (var item=new DirectoryInfo(directory); item is not null && item.FullName.StartsWith(Path.GetFullPath(Root),StringComparison.OrdinalIgnoreCase); item=item.Parent)
                if ((item.Attributes & FileAttributes.ReparsePoint)!=0) throw new IOException("Greeting storage contains a link.");
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(directory,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute|UnixFileMode.GroupRead|UnixFileMode.GroupExecute);
            using (var voice=new HttpRequestMessage(HttpMethod.Get,$"https://api.elevenlabs.io/v1/voices/{Voice}")) {
                using var deadline=ProviderDeadline(ct);
                voice.Headers.Add("xi-api-key",settings["ElevenLabs:ApiKey"]);
                using var reply=await clients.CreateClient("voice").SendAsync(voice,deadline.Token);
                if (!reply.IsSuccessStatusCode) throw new IOException("Keoma voice is unavailable on this instance's provider account.");
                var metadata=await reply.Content.ReadFromJsonAsync<System.Text.Json.JsonElement>(deadline.Token);
                if (!metadata.TryGetProperty("name",out var voiceName)||voiceName.GetString()!="Keoma") throw new IOException("The configured Keoma voice needs review.");
            }
            if (source=="text") {
                var path=Path.Combine(directory,"audio.wav");await Generate(script,path,ct);
                await using var transaction=await db.BeginTransactionAsync(ct);
                await using var guard=new NpgsqlCommand("select name from v_pbx_greetings where greeting_uuid=$1 and domain_uuid=$2 and state='preparing' for update",db,transaction);
                guard.Parameters.AddWithValue(id);guard.Parameters.AddWithValue(domain);
                var currentName=await guard.ExecuteScalarAsync(ct) as string;
                if (currentName is null) { File.Delete(path);return; }
                await using var media=new NpgsqlCommand("insert into v_pbx_media(media_uuid,domain_uuid,category,source_path,file_path,title,created_at) values($1,$2,'prompts',$3,$4,$5,now())",db,transaction);
                media.Parameters.AddWithValue(id);media.Parameters.AddWithValue(domain);media.Parameters.AddWithValue("greetings/"+id.ToString("D"));media.Parameters.AddWithValue(path.Replace('\\','/'));media.Parameters.AddWithValue(currentName);await media.ExecuteNonQueryAsync(ct);
                await using var recording=new NpgsqlCommand("insert into v_recordings(recording_uuid,domain_uuid,recording_filename,recording_name) values($1,$2,$3,$4)",db,transaction);
                recording.Parameters.AddWithValue(Guid.NewGuid());recording.Parameters.AddWithValue(domain);recording.Parameters.AddWithValue(path.Replace('\\','/'));recording.Parameters.AddWithValue(currentName);await recording.ExecuteNonQueryAsync(ct);
                await using var ready=new NpgsqlCommand("update v_pbx_greetings set state='ready',media_uuid=$1,lease_until=null,last_result='Recorded by Keoma',updated_at=now() where greeting_uuid=$1 and domain_uuid=$2",db,transaction);
                ready.Parameters.AddWithValue(id);ready.Parameters.AddWithValue(domain);await ready.ExecuteNonQueryAsync(ct);await transaction.CommitAsync(ct);
            } else {
                await Generate(Introduction(company,category),Path.Combine(directory,"instruction.wav"),ct);
                await Generate("Here is your greeting.",Path.Combine(directory,"replay.wav"),ct);
                await Generate("Your greeting has been saved. Goodbye.",Path.Combine(directory,"saved.wav"),ct);
                await using var ready=new NpgsqlCommand("update v_pbx_greetings set state='ready_to_call',lease_until=null,last_result='Ready to call the recording phone',updated_at=now() where greeting_uuid=$1 and domain_uuid=$2 and state='preparing'",db);
                ready.Parameters.AddWithValue(id);ready.Parameters.AddWithValue(domain);await ready.ExecuteNonQueryAsync(ct);
            }
        } catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception ex) {
            await using var failed=new NpgsqlCommand("update v_pbx_greetings set state='failed',last_result='Keoma could not prepare this greeting. Check the instance voice service and choose Retry.',lease_until=null,updated_at=now() where greeting_uuid=$1 and domain_uuid=$2 and state='preparing'",db);
            failed.Parameters.AddWithValue(id);failed.Parameters.AddWithValue(domain);await failed.ExecuteNonQueryAsync(ct);
            log.LogWarning("Greeting voice preparation failed ({ErrorType}).",ex.GetType().Name);
        }
    }
    private async Task Generate(string text,string path,CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(text)||text.Length>3000) throw new InvalidDataException("Greeting text is invalid.");
        using var deadline=ProviderDeadline(ct);
        var token=deadline.Token;
        // A bounded provider request can take 90 seconds. Renew readiness between
        // phone instructions so a healthy worker is not reported offline mid-job.
        await using (var heartbeat=data.CreateCommand("update v_pbx_greeting_status set checked_at=now() where singleton=1")) await heartbeat.ExecuteNonQueryAsync(token);
        using var request=new HttpRequestMessage(HttpMethod.Post,$"https://api.elevenlabs.io/v1/text-to-speech/{Voice}?output_format=pcm_16000");
        request.Headers.Add("xi-api-key",settings["ElevenLabs:ApiKey"]);
        request.Content=JsonContent.Create(new{text,model_id="eleven_multilingual_v2",voice_settings=new{stability=0.7,similarity_boost=0.85}});
        using var response=await clients.CreateClient("voice").SendAsync(request,HttpCompletionOption.ResponseHeadersRead,token);
        if(!response.IsSuccessStatusCode)throw new IOException("The voice provider could not prepare the greeting.");
        await using var source=await response.Content.ReadAsStreamAsync(token);
        using var pcm=new MemoryStream();var buffer=new byte[16384];int length;
        while((length=await source.ReadAsync(buffer,token))>0){if(pcm.Length+length>16000*2*180)throw new IOException("The greeting exceeds three minutes.");pcm.Write(buffer,0,length);}
        if(pcm.Length<3200||pcm.Length%2!=0)throw new IOException("The voice response is incomplete.");
        var wave=CallMeBackPromptWorker.Wave(pcm.ToArray());var temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try {
            await File.WriteAllBytesAsync(temporary,wave,token);
            if(!OperatingSystem.IsWindows())File.SetUnixFileMode(temporary,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.GroupRead);
            token.ThrowIfCancellationRequested();
            File.Move(temporary,path,true);
        } finally {File.Delete(temporary);}
    }
    private async Task Dispatch(NpgsqlConnection db,CancellationToken ct)
    {
        // A call is never automatically redialled. An administrator must retry a failed recording.
        await using(var stale=new NpgsqlCommand("select greeting_uuid,call_uuid from v_pbx_greetings where state='calling' and lease_until<now() limit 10",db)) {
            var rows=new List<(Guid,Guid?)>();await using(var reader=await stale.ExecuteReaderAsync(ct))while(await reader.ReadAsync(ct))rows.Add((reader.GetGuid(0),reader.IsDBNull(1)?null:reader.GetGuid(1)));
            foreach(var (id,call) in rows){
                var alive=call is not null&&(await engine.Execute("uuid_exists "+call.Value.ToString("D"),ct)).Trim()=="true";
                await using var update=new NpgsqlCommand(alive?"update v_pbx_greetings set lease_until=now()+interval '2 minutes' where greeting_uuid=$1 and state='calling'":"update v_pbx_greetings set state='failed',lease_until=null,last_result='Recording call ended before the greeting was saved. Choose Retry.',updated_at=now() where greeting_uuid=$1 and state='calling'",db);
                update.Parameters.AddWithValue(id);await update.ExecuteNonQueryAsync(ct);
            }
        }
        await using var claim=new NpgsqlCommand("""
          with chosen as(select g.greeting_uuid from v_pbx_greetings g join v_domains d using(domain_uuid)
           join v_users u on u.user_uuid=g.created_by where g.state='ready_to_call' and d.domain_enabled='true' and u.user_enabled='true'
           and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=g.domain_uuid and not t.enabled)
           order by g.created_at for update of g skip locked limit 1)
          update v_pbx_greetings g set state='calling',call_uuid=gen_random_uuid(),lease_until=now()+interval '10 minutes',updated_at=now()
           from chosen where g.greeting_uuid=chosen.greeting_uuid returning g.greeting_uuid
          """,db);
        var claimed=await claim.ExecuteScalarAsync(ct);
        if(claimed is Guid greeting) {
            var answer=await engine.Execute("luarun app/pbx_greetings/call.lua "+greeting.ToString("D"),ct);
            if(!answer.StartsWith("+OK",StringComparison.Ordinal))throw new IOException("The recording call could not be dispatched.");
        }
    }
}
