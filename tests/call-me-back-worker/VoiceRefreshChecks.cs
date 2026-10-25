using System.Net;
using System.Security.Cryptography;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;

// Every row, path and provider response belongs to this disposable fixture.
internal static class VoiceRefreshChecks
{
 public static async Task Run(NpgsqlDataSource data,NpgsqlConnection db,IConfiguration config,string root,Guid id,Action<bool,string> check)
 {
  var folder=Path.Combine(root,id.ToString("D"));Directory.CreateDirectory(folder);
  var live=Path.Combine(folder,"greeting.wav");var old=Wave(1400);var next=Wave(2200);
  var oldHash=Convert.ToHexStringLower(SHA256.HashData(old));
  async Task Sql(string sql){await new NpgsqlCommand(sql,db).ExecuteNonQueryAsync();}
  async Task<string> Field(string field)=>(string)(await new NpgsqlCommand($"select {field} from v_pbx_cmb_services where service_uuid='{id}'",db).ExecuteScalarAsync())!;
  async Task Reset(){
   await File.WriteAllBytesAsync(live,old);
   await Sql($"update v_pbx_cmb_services set name='Fictional refresh',enabled=true,prompt_state='ready',prompt_version='1.0.1',prompt_sha256='{oldHash}',prompt_audio_file='greeting.wav',prompt_refresh_state='pending',prompt_refresh_attempts=0,prompt_refresh_token=null,prompt_refresh_until=null,prompt_refresh_after=null,prompt_refresh_message='' where service_uuid='{id}'");
   config["ElevenLabs:ApiKey"]="fictional-test-key";config["CallMeBack:ProviderTimeoutSeconds"]=null;
  }
  CallMeBackPromptWorker Worker(RefreshTransport transport)=>new(data,new Clients(transport),config,NullLogger<CallMeBackPromptWorker>.Instance);
  async Task Old(string context){check((await File.ReadAllBytesAsync(live)).SequenceEqual(old),context+": old audio changed");check(await Field("prompt_version||':'||prompt_state||':'||enabled::text||':'||prompt_sha256||':'||prompt_audio_file")=="1.0.1:ready:true:"+oldHash+":greeting.wav",context+": old active state changed");}
  await Reset();await Sql(await File.ReadAllTextAsync("app/pbx_setup/resources/call_me_back.sql"));await Old("Idempotent migration");
  var transport=new RefreshTransport(next);var pending=Worker(transport).Tick(default);await transport.Seen.Task.WaitAsync(TimeSpan.FromSeconds(10));
  await Old("Pending provider");await Worker(transport).Tick(default);check(transport.Count==1,"Concurrent refresh duplicated provider work");
  // The row is not locked during synthesis: a separate DB connection can edit it.
  await Sql($"set statement_timeout='2s';update v_pbx_cmb_services set enabled=false where service_uuid='{id}';set statement_timeout=0");
  transport.Release.TrySetResult();await pending;
  var selected=await Field("prompt_audio_file");var newHash=Convert.ToHexStringLower(SHA256.HashData(next));
  check(selected=="greeting-keoma-"+newHash+".wav","Keoma selection was not hash-bound");
  check((await File.ReadAllBytesAsync(Path.Combine(folder,selected))).SequenceEqual(next),"Selected Keoma bytes differ");
  check((await File.ReadAllBytesAsync(live)).SequenceEqual(old),"Successful refresh replaced previous fixed audio");
  check(await Field("prompt_version||':'||prompt_state||':'||enabled::text||':'||prompt_refresh_state")=="1.0.2:ready:false:complete","Publish changed administrator enabled choice");
  await Worker(transport).Tick(default);check(transport.Count==1,"Completed refresh regenerated audio");

  await Reset();var failed=new RefreshTransport(next,HttpStatusCode.ServiceUnavailable);failed.Release.TrySetResult();
  await Worker(failed).Tick(default);await Old("Provider failure");check(await Field("prompt_refresh_state||':'||prompt_refresh_attempts::text")=="pending:1","Provider failure did not retain bounded retry");
  await Worker(failed).Tick(default);check(failed.Count==1,"Provider failure ignored backoff");
  for(var i=0;i<2;i++){await Sql("update v_pbx_cmb_services set prompt_refresh_after=now()-interval '1 second'");await Worker(failed).Tick(default);}
  check(failed.Count==3&&await Field("prompt_refresh_state")=="blocked","Provider retry allowance was not finite");await Old("Retry exhaustion");
  await Sql("update v_pbx_cmb_services set prompt_refresh_after=now()-interval '1 second'");await Worker(failed).Tick(default);check(failed.Count==3,"Blocked refresh kept requesting audio");

  await Reset();var custom=Wave(900);await File.WriteAllBytesAsync(live,custom);var refused=new RefreshTransport(next);refused.Release.TrySetResult();
  await Worker(refused).Tick(default);check(refused.Count==0,"Custom audio was sent for regeneration");check((await File.ReadAllBytesAsync(live)).SequenceEqual(custom),"Custom audio was overwritten");check(await Field("prompt_refresh_state||':'||enabled::text||':'||prompt_state")=="blocked:true:ready","Custom refusal disabled service");
  await Reset();transport=new RefreshTransport(next);pending=Worker(transport).Tick(default);await transport.Seen.Task.WaitAsync(TimeSpan.FromSeconds(10));await File.WriteAllBytesAsync(live,custom);transport.Release.TrySetResult();await pending;
  check((await File.ReadAllBytesAsync(live)).SequenceEqual(custom),"Concurrent custom edit was overwritten");check(await Field("prompt_version||':'||enabled::text||':'||prompt_state||':'||prompt_refresh_state")=="1.0.1:true:ready:blocked","Concurrent custom edit published stale greeting");

  await Reset();transport=new RefreshTransport(next);pending=Worker(transport).Tick(default);await transport.Seen.Task.WaitAsync(TimeSpan.FromSeconds(10));await Sql("update v_pbx_cmb_services set name='Changed while preparing'");transport.Release.TrySetResult();await pending;
  await Old("Concurrent name edit");check(await Field("name")=="Changed while preparing"&&await Field("prompt_refresh_state")=="blocked","Concurrent name choice was lost");
  await Reset();transport=new RefreshTransport(next);pending=Worker(transport).Tick(default);await transport.Seen.Task.WaitAsync(TimeSpan.FromSeconds(10));await Sql("update v_pbx_cmb_services set prompt_refresh_token=gen_random_uuid(),prompt_refresh_until=now()+interval '1 minute'");transport.Release.TrySetResult();await pending;
  await Old("Changed claim");check(await Field("prompt_refresh_state")=="preparing","Stale worker cleared a newer claim");

  // A deferred trigger refuses COMMIT after the candidate and UPDATE exist.
  // There is no cross-resource rollback: the old selection/bytes stay intact.
  await Reset();await Sql("create function reject_keoma_commit() returns trigger language plpgsql as $$ begin if new.prompt_version='1.0.2' then raise exception 'controlled publication refusal'; end if;return new;end $$;create constraint trigger reject_keoma_commit after update on v_pbx_cmb_services deferrable initially deferred for each row execute function reject_keoma_commit()");
  transport=new RefreshTransport(next);transport.Release.TrySetResult();await Worker(transport).Tick(default);await Old("Commit refusal");check(await Field("prompt_refresh_state")=="pending","Commit refusal lost retry state");
  check(File.Exists(Path.Combine(folder,selected)),"Commit refusal removed an immutable possibly-selected candidate");
  await Sql("drop trigger reject_keoma_commit on v_pbx_cmb_services;drop function reject_keoma_commit()");

  await Reset();config["ElevenLabs:ApiKey"]=null;transport=new RefreshTransport(next);transport.Release.TrySetResult();await Worker(transport).Tick(default);await Old("Missing key");
  check(transport.Count==0&& (await Field("prompt_refresh_message")).Contains("instance voice service"),"Missing key borrowed credentials or hid operator status");var rowVersion=await Field("xmin::text");await Worker(transport).Tick(default);check(await Field("xmin::text")==rowVersion,"Idle key failure rewrote row every tick");
  await Reset();config["CallMeBack:ProviderTimeoutSeconds"]="1";transport=new RefreshTransport(next){BlockBody=true};transport.Release.TrySetResult();await Worker(transport).Tick(default);await Old("Body deadline");check(await Field("prompt_refresh_state")=="pending","Body deadline left unbounded active work");

  await Reset();transport=new RefreshTransport(next);using(var cancel=new CancellationTokenSource()){
   pending=Worker(transport).Tick(cancel.Token);await transport.Seen.Task.WaitAsync(TimeSpan.FromSeconds(10));cancel.Cancel();try{await pending;throw new Exception("Global cancellation ignored");}catch(OperationCanceledException){check(true,"Cancellation observed");}}
  await Old("Global cancellation");
  await Sql("update v_pbx_cmb_services set prompt_refresh_until=now()-interval '1 second'");transport=new RefreshTransport(next);transport.Release.TrySetResult();await Worker(transport).Tick(default);check(await Field("prompt_version")=="1.0.2","Expired interrupted claim was not recovered");

  await Reset();
  for(var interrupted=0;interrupted<3;interrupted++){
   transport=new RefreshTransport(next);using var cancel=new CancellationTokenSource();pending=Worker(transport).Tick(cancel.Token);await transport.Seen.Task.WaitAsync(TimeSpan.FromSeconds(10));cancel.Cancel();try{await pending;throw new Exception("Interrupted refresh ignored cancellation");}catch(OperationCanceledException){}
   await Sql("update v_pbx_cmb_services set prompt_refresh_until=now()-interval '1 second'");
  }
  config["ElevenLabs:ApiKey"]=null;transport=new RefreshTransport(next);transport.Release.TrySetResult();await Worker(transport).Tick(default);
  await Old("Three interrupted claims");check(transport.Count==0&&await Field("prompt_refresh_state||':'||prompt_refresh_attempts::text")=="blocked:3"&&(await Field("prompt_refresh_message")).Contains("interrupted three times"),"Exhausted interrupted refresh stayed falsely preparing");

  await Reset();await Sql("update v_domains set domain_enabled='false'");transport=new RefreshTransport(next);transport.Release.TrySetResult();await Worker(transport).Tick(default);check(transport.Count==0,"Disabled domain generated audio");await Old("Disabled domain");await Sql("update v_domains set domain_enabled='true'");
  if(OperatingSystem.IsWindows()){
   var state=config["CallMeBack:StateRoot"]!;var before=await Field("xmin::text");transport=new RefreshTransport(next);transport.Release.TrySetResult();
   using(var maintenance=new FileStream(Path.Combine(state,"upgrade.lock"),FileMode.Open,FileAccess.ReadWrite,FileShare.None))await Worker(transport).Tick(default);
   check(transport.Count==0&&await Field("xmin::text")==before,"Windows upgrade sharing lock allowed DB/provider mutation");
   await File.WriteAllTextAsync(Path.Combine(state,"call-records.hold"),"owned maintenance fixture");try{await Worker(transport).Tick(default);}finally{File.Delete(Path.Combine(state,"call-records.hold"));}
   check(transport.Count==0&&await Field("xmin::text")==before,"Windows durable maintenance hold allowed DB/provider mutation");await Old("Windows maintenance");
  }
  await Sql("update v_pbx_cmb_services set enabled=false,prompt_state='ready',prompt_version='1.0.2',prompt_audio_file='greeting.wav'");
  check(!Directory.EnumerateFiles(folder,"*.tmp").Any(),"Temporary synthesis files leaked");
 }
 private static byte[] Wave(short amplitude){var audio=new byte[3244];using var memory=new MemoryStream(audio);using var writer=new BinaryWriter(memory);writer.Write("RIFF"u8);writer.Write(3236);writer.Write("WAVEfmt "u8);writer.Write(16);writer.Write((short)1);writer.Write((short)1);writer.Write(16000);writer.Write(32000);writer.Write((short)2);writer.Write((short)16);writer.Write("data"u8);writer.Write(3200);for(var i=0;i<1600;i++)writer.Write((short)(i%2==0?amplitude:-amplitude));return audio;}
 private sealed class RefreshTransport(byte[] wave,HttpStatusCode status=HttpStatusCode.OK):HttpMessageHandler{
  public readonly TaskCompletionSource Seen=new(TaskCreationOptions.RunContinuationsAsynchronously),Release=new(TaskCreationOptions.RunContinuationsAsynchronously);public int Count;public bool BlockBody;
  protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct){Interlocked.Increment(ref Count);Seen.TrySetResult();await Release.Task.WaitAsync(ct);return new(status){Content=BlockBody?new StreamContent(new WaitingBody()):new ByteArrayContent(wave[44..])};}
 }
 private sealed class WaitingBody:Stream{
  public override bool CanRead=>true;public override bool CanWrite=>false;public override bool CanSeek=>false;public override long Length=>throw new NotSupportedException();public override long Position{get=>throw new NotSupportedException();set=>throw new NotSupportedException();}
  public override async ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken ct=default){await Task.Delay(Timeout.Infinite,ct);return 0;}
  public override int Read(byte[] b,int o,int c)=>throw new NotSupportedException();public override void Flush()=>throw new NotSupportedException();public override long Seek(long o,SeekOrigin s)=>throw new NotSupportedException();public override void SetLength(long v)=>throw new NotSupportedException();public override void Write(byte[] b,int o,int c)=>throw new NotSupportedException();
 }
}
