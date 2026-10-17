using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;

var connection=Environment.GetEnvironmentVariable("OPENWEB_CMB_TEST_DATABASE")??throw new Exception("Explicit disposable PostgreSQL required.");
await using var root=NpgsqlDataSource.Create(connection);await using var db=await root.OpenConnectionAsync();
var schema="cmb_worker_"+Guid.NewGuid().ToString("N");var directory=Path.Combine(Path.GetTempPath(),schema);int checks=0;
void Check(bool value,string message){if(!value)throw new Exception(message);checks++;}
async Task Run(string sql){await new NpgsqlCommand(sql,db).ExecuteNonQueryAsync();}
var commands=new ConcurrentBag<string>();var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();using var stop=new CancellationTokenSource();string exists="false";
var server=Task.Run(async()=>{while(!stop.IsCancellationRequested){TcpClient client;try{client=await listener.AcceptTcpClientAsync(stop.Token);}catch(OperationCanceledException){break;}using(client){var stream=client.GetStream();await stream.WriteAsync("Content-Type: auth/request\n\n"u8.ToArray());var read=new StreamReader(stream,Encoding.UTF8,leaveOpen:true);await read.ReadLineAsync();await read.ReadLineAsync();await stream.WriteAsync("Content-Type: command/reply\nReply-Text: +OK accepted\n\n"u8.ToArray());var cmd=await read.ReadLineAsync()??"";await read.ReadLineAsync();commands.Add(cmd);string answer=cmd=="api status"?"UP local fixture":cmd.Contains("uuid_exists")?exists:"+OK accepted";await stream.WriteAsync(Encoding.UTF8.GetBytes($"Content-Type: api/response\nContent-Length: {Encoding.UTF8.GetByteCount(answer)}\n\n{answer}"));}}});
try{
 await Run($"create schema {schema};set search_path to {schema}");
 await Run("create table v_domains(domain_uuid uuid primary key,domain_enabled text);create table v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean);create table v_pbx_services(domain_uuid uuid,tenant_uuid uuid)");
 await Run(await File.ReadAllTextAsync("app/pbx_setup/resources/call_me_back.sql"));
 var domain=Guid.NewGuid();var service=Guid.NewGuid();var request=Guid.NewGuid();
 await Run($"insert into v_domains values('{domain}','true');insert into v_pbx_cmb_services(service_uuid,domain_uuid,name,incoming_rule_uuid,route_owner,enabled,prompt_state,prompt_sha256) values('{service}','{domain}','Fictional',gen_random_uuid(),'1000',true,'ready',repeat('a',64));insert into v_pbx_cmb_requests(request_uuid,domain_uuid,service_uuid,inbound_uuid,caller_number,state) values('{request}','{domain}','{service}',gen_random_uuid(),'+27820000001','queued')");
 await using var data=NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder(connection){SearchPath=schema}.ConnectionString);
 var config=new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?>{["Switch:Port"]=((IPEndPoint)listener.LocalEndpoint).Port.ToString(),["Switch:Password"]="fictional-test-password",["CallMeBack:PromptRoot"]=directory,["ElevenLabs:ApiKey"]="fictional-test-key"}).Build();
 var worker=new CallMeBackWorker(data,new SwitchClient(config),NullLogger<CallMeBackWorker>.Instance);
 await Task.WhenAll(worker.Tick(default),worker.Tick(default));
 Check(commands.Count(c=>c.Contains("luarun app/pbx_setup/call_me_back.lua"))==1,"Concurrent dispatch launched duplicate callback");
 await Run($"update v_pbx_cmb_requests set lease_until=now()-interval '1 minute' where request_uuid='{request}'");
 exists="-ERR lookup unavailable";
 try{await worker.Tick(default);throw new Exception("Ambiguous active call treated absent");}catch(IOException){checks++;}
 Check((string)(await new NpgsqlCommand("select state from v_pbx_cmb_requests",db).ExecuteScalarAsync())! == "starting","Unknown existence released request");
 exists="true";await worker.Tick(default);Check(commands.Count(c=>c.Contains("luarun app/pbx_setup/call_me_back.lua"))==1,"Recovery redialled a live callback");
 await Run("update v_pbx_cmb_requests set lease_until=now()-interval '1 minute'");exists="false";await worker.Tick(default);
 Check((string)(await new NpgsqlCommand("select state from v_pbx_cmb_requests",db).ExecuteScalarAsync())! == "failed","Confirmed absent launch was not finished");
 Check(commands.Count(c=>c.Contains("luarun app/pbx_setup/call_me_back.lua"))==1,"Interrupted callback silently redialled");
 await Run($"update v_pbx_cmb_services set enabled=false,prompt_state='pending',prompt_sha256=null where service_uuid='{service}'");
 var transport=new VoiceTransport();var factory=new Clients(transport);var voice=new CallMeBackPromptWorker(data,factory,config,NullLogger<CallMeBackPromptWorker>.Instance);
 var pending=voice.Tick(default);await transport.Seen.Task.WaitAsync(TimeSpan.FromSeconds(10));
 // A slow provider request is still pending; dispatch has a separate host loop.
 await worker.Tick(default);Check(!pending.IsCompleted,"Voice network fixture did not remain isolated");
 await Run($"update v_pbx_cmb_services set name='Changed fictional company',prompt_state='pending',prompt_sha256=null where service_uuid='{service}'");
 transport.Release.TrySetResult();await pending;
 Check((string)(await new NpgsqlCommand("select prompt_state from v_pbx_cmb_services",db).ExecuteScalarAsync())! == "pending","Old company greeting marked new name ready");
 Check(!File.Exists(Path.Combine(directory,service.ToString("D"),"greeting.wav")),"Stale company greeting became active");
 var freshTransport=new VoiceTransport();freshTransport.Release.TrySetResult();
 await new CallMeBackPromptWorker(data,new Clients(freshTransport),config,NullLogger<CallMeBackPromptWorker>.Instance).Tick(default);
 Check((string)(await new NpgsqlCommand("select prompt_state from v_pbx_cmb_services",db).ExecuteScalarAsync())! == "ready","Generated private greeting not sealed ready");
 var wav=await File.ReadAllBytesAsync(Path.Combine(directory,service.ToString("D"),"greeting.wav"));
 Check(wav.AsSpan(0,4).SequenceEqual("RIFF"u8)&&BitConverter.ToInt32(wav,24)==16000&&wav.Length==3244,"PCM was not wrapped into valid 16kHz mono WAV");
 Check(freshTransport.Body.Contains("Changed fictional company")&&!freshTransport.Body.Contains("2782"),"Provider request contained private caller data");
 Check(freshTransport.Uri=="https://api.elevenlabs.io/v1/text-to-speech/7S3KNdLDL7aRgBVRQb1z?output_format=pcm_16000","Wrong Nathaniel voice or insecure provider target");
 await Run("update v_pbx_cmb_services set prompt_state='pending',enabled=false");config["ElevenLabs:ApiKey"]=null;
 await new CallMeBackPromptWorker(data,factory,config,NullLogger<CallMeBackPromptWorker>.Instance).Tick(default);
 Check((string)(await new NpgsqlCommand("select prompt_state from v_pbx_cmb_services",db).ExecuteScalarAsync())! == "pending","Missing owner voice key did not fail closed");
 Console.WriteLine($"PASS: {checks} actual PostgreSQL/.NET callback concurrency, recovery, provider isolation and private greeting controls");
}finally{stop.Cancel();listener.Stop();await server;await Run($"set search_path to public;drop schema {schema} cascade");if(Directory.Exists(directory))Directory.Delete(directory,true);}
sealed class Clients(HttpMessageHandler handler):IHttpClientFactory{public HttpClient CreateClient(string name)=>new(handler,false){Timeout=TimeSpan.FromSeconds(10)};}
sealed class VoiceTransport:HttpMessageHandler{
 public TaskCompletionSource Seen=new(TaskCreationOptions.RunContinuationsAsynchronously),Release=new(TaskCreationOptions.RunContinuationsAsynchronously);public string Body="",Uri="";
 protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct){Body=await request.Content!.ReadAsStringAsync(ct);Uri=request.RequestUri!.ToString();Seen.TrySetResult();await Release.Task.WaitAsync(ct);return new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(new byte[3200])};}
}
