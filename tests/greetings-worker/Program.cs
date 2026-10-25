using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;

var connection=Environment.GetEnvironmentVariable("OPENWEB_TEST_DATABASE")??throw new InvalidOperationException("Use an owned PostgreSQL fixture connection.");
var schema="greeting_worker_"+Guid.NewGuid().ToString("N");var folder=Path.Combine(Path.GetTempPath(),schema);Directory.CreateDirectory(folder);
int checks=0;void Check(bool valid,string text){if(!valid)throw new Exception(text);checks++;}
await using var root=NpgsqlDataSource.Create(connection);await using var db=await root.OpenConnectionAsync();
var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();using var stop=new CancellationTokenSource();var commands=new List<string>();
var engine=Task.Run(async()=>{
 while(!stop.IsCancellationRequested){
  TcpClient socket;try{socket=await listener.AcceptTcpClientAsync(stop.Token);}catch(OperationCanceledException){break;}
  using(socket){var stream=socket.GetStream();using var reader=new StreamReader(stream,Encoding.UTF8,leaveOpen:true);await stream.WriteAsync("Content-Type: auth/request\n\n"u8.ToArray());await reader.ReadLineAsync(stop.Token);await reader.ReadLineAsync(stop.Token);await stream.WriteAsync("Content-Type: command/reply\nReply-Text: +OK\n\n"u8.ToArray());var line=await reader.ReadLineAsync(stop.Token);await reader.ReadLineAsync(stop.Token);commands.Add(line??"");var reply="+OK owned isolated dispatch";await stream.WriteAsync(Encoding.UTF8.GetBytes($"Content-Type: api/response\nContent-Length: {reply.Length}\n\n{reply}"));}
 }
});
try{
 await new NpgsqlCommand($"create schema {schema};set search_path to {schema};create table v_domains(domain_uuid uuid primary key,domain_enabled boolean);create table v_users(user_uuid uuid primary key,user_enabled boolean);create table v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean);create table v_pbx_services(domain_uuid uuid,tenant_uuid uuid);create table v_pbx_media(media_uuid uuid primary key,domain_uuid uuid,category text,source_path text,file_path text,title text,created_at timestamptz);create table v_recordings(recording_uuid uuid primary key,domain_uuid uuid,recording_filename text,recording_name text)",db).ExecuteNonQueryAsync();
 await new NpgsqlCommand(await File.ReadAllTextAsync("app/pbx_greetings/resources/install.sql"),db).ExecuteNonQueryAsync();
 var domain=Guid.NewGuid();var actor=Guid.NewGuid();
 await using(var seed=new NpgsqlCommand("insert into v_domains values($1,true)",db)){seed.Parameters.AddWithValue(domain);await seed.ExecuteNonQueryAsync();}
 await using(var seed=new NpgsqlCommand("insert into v_users values($1,true)",db)){seed.Parameters.AddWithValue(actor);await seed.ExecuteNonQueryAsync();}
 await using var data=NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(connection){SearchPath=schema}.ConnectionString);
 var config=new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?>{
  ["Greetings:MediaRoot"]=folder,["Switch:Host"]="127.0.0.1",["Switch:Port"]=((IPEndPoint)listener.LocalEndpoint).Port.ToString(),["Switch:Password"]="owned-fixture"
 }).Build();
 var requests=new List<(string,string)>();bool wrongVoice=false,providerFailed=false;Func<Task>? duringSynthesis=null;
 using var client=new HttpClient(new Handler(async request=>{
  var uri=request.RequestUri!.AbsoluteUri;
  Check(request.Headers.GetValues("xi-api-key").Single()=="private-test-provider-key","Provider key was not supplied privately");
  if(request.Method==HttpMethod.Get){Check(uri=="https://api.elevenlabs.io/v1/voices/"+GreetingWorker.Voice,"Wrong narrator metadata requested");return new(HttpStatusCode.OK){Content=new StringContent(JsonSerializer.Serialize(new{name=wrongVoice?"Another voice":"Keoma"}),Encoding.UTF8,"application/json")};}
  Check(uri=="https://api.elevenlabs.io/v1/text-to-speech/"+GreetingWorker.Voice+"?output_format=pcm_16000","Speech did not use Keoma exclusively");
  using var body=JsonDocument.Parse(await request.Content!.ReadAsStringAsync());requests.Add((uri,body.RootElement.GetProperty("text").GetString()!));
  if(duringSynthesis is not null){var action=duringSynthesis;duringSynthesis=null;await action();}
  var pcm=new byte[6400];for(var i=0;i<pcm.Length;i+=2){pcm[i]=64;pcm[i+1]=10;}
  return providerFailed?new(HttpStatusCode.TooManyRequests):new(HttpStatusCode.OK){Content=new ByteArrayContent(pcm)};
 }));
 var worker=new GreetingWorker(data,new Factory(client),config,new SwitchClient(config),NullLogger<GreetingWorker>.Instance);
 async Task<Guid> Add(string source,string category="voicemail"){
  var id=Guid.NewGuid();await using var command=new NpgsqlCommand("insert into v_pbx_greetings(greeting_uuid,domain_uuid,created_by,name,category,source,company_name,script,target_number,caller_extension) values($1,$2,$3,'Fixture greeting',$4,$5,'Fixture Company','A test greeting for callers.','1000','1000')",db);command.Parameters.AddWithValue(id);command.Parameters.AddWithValue(domain);command.Parameters.AddWithValue(actor);command.Parameters.AddWithValue(category);command.Parameters.AddWithValue(source);await command.ExecuteNonQueryAsync();return id;
 }
 async Task<string> State(Guid id){await using var command=new NpgsqlCommand("select state from v_pbx_greetings where greeting_uuid=$1",db);command.Parameters.AddWithValue(id);return (string)(await command.ExecuteScalarAsync())!;}
 var spoken=await Add("text");await worker.Tick(default);Check(await State(spoken)=="pending"&&requests.Count==0&&commands.Count==0,"Missing provider key generated audio or dispatched a call");
 config["ElevenLabs:ApiKey"]="private-test-provider-key";await worker.Tick(default);
 Check(await State(spoken)=="ready"&&requests.Count==1&&commands.Count==0,"Text greeting did not become ready without a call");
 var audio=Path.Combine(folder,domain.ToString("D"),"greetings",spoken.ToString("D"),"audio.wav");var bytes=await File.ReadAllBytesAsync(audio);
 Check(Encoding.ASCII.GetString(bytes,0,4)=="RIFF"&&BitConverter.ToInt32(bytes,4)==bytes.Length-8&&BitConverter.ToInt32(bytes,24)==16000,"Keoma PCM was not saved as a complete 16k mono WAV");
 Check((long)(await new NpgsqlCommand("select count(*) from v_pbx_media",db).ExecuteScalarAsync())! ==1,"Text greeting media was not indexed exactly once");
 var phone=await Add("phone","receptionist");await worker.Tick(default);
 Check(await State(phone)=="calling"&&commands.Count==1&&commands[0].Contains("luarun app/pbx_greetings/call.lua "+phone.ToString("D")),"Phone recording was not dispatched to its owned Lua request");
 Check(requests.Count==4&&requests[1].Item2=="You are about to create a Digital Receptionist greeting for Fixture Company - leave your message after the tone then press hash."&&requests[2].Item2=="Here is your greeting."&&requests[3].Item2=="Your greeting has been saved. Goodbye.","Phone instructions and replay/save narrator were not all Keoma");
 await worker.Tick(default);Check(commands.Count==1,"A calling request was dialled twice");
 wrongVoice=true;var wrong=await Add("text");await worker.Tick(default);Check(await State(wrong)=="failed"&&requests.Count==4,"Wrong voice silently fell back or produced greeting audio");wrongVoice=false;
 providerFailed=true;var refused=await Add("text");await worker.Tick(default);Check(await State(refused)=="failed"&&commands.Count==1,"Provider refusal placed an unprepared recording call");providerFailed=false;
 var cancelled=await Add("text");duringSynthesis=async()=>{await using var cancel=new NpgsqlCommand("update v_pbx_greetings set state='cancelled' where greeting_uuid=$1",db);cancel.Parameters.AddWithValue(cancelled);await cancel.ExecuteNonQueryAsync();};await worker.Tick(default);
 Check(await State(cancelled)=="cancelled"&&!File.Exists(Path.Combine(folder,domain.ToString("D"),"greetings",cancelled.ToString("D"),"audio.wav")),"Cancellation published a stale text greeting");
 await using(var off=new NpgsqlCommand("update v_domains set domain_enabled=false where domain_uuid=$1",db)){off.Parameters.AddWithValue(domain);await off.ExecuteNonQueryAsync();}
 var disabled=await Add("text");var before=requests.Count;await worker.Tick(default);Check(await State(disabled)=="pending"&&requests.Count==before,"Disabled PBX generated audio");
 foreach(var category in new[]{"voicemail","receptionist","queue_intro","queue_wait","hold_music","announcement"})Check(GreetingWorker.Introduction("Fixture",category).Contains("for Fixture - leave your message after the tone then press hash."),"Category prompt is incomplete");
 Console.WriteLine($"PASS: {checks} actual greeting worker PostgreSQL, Keoma HTTP, readiness, WAV, cancellation, dispatch, category and duplicate-call controls");
}finally{
 stop.Cancel();listener.Stop();await engine;
 await new NpgsqlCommand($"set search_path to public;drop schema if exists {schema} cascade",db).ExecuteNonQueryAsync();Directory.Delete(folder,true);
}
sealed class Handler(Func<HttpRequestMessage,Task<HttpResponseMessage>> callback):HttpMessageHandler{protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)=>callback(request);}
sealed class Factory(HttpClient client):IHttpClientFactory{public HttpClient CreateClient(string name)=>client;}
