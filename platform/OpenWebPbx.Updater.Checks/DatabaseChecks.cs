using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using OpenWebPbx.Server;
using OpenWebPbx.Updater;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

static class DatabaseChecks
{
 public static async Task<int> Run(string connection)
 {
  var count=0;
  void Check(bool value,string message){if(!value)throw new Exception(message);count++;}
  var schema="openweb_update_check_"+Guid.NewGuid().ToString("N");
  var temporary=Path.Combine(Path.GetTempPath(),schema);Directory.CreateDirectory(temporary);
  await using var root=NpgsqlDataSource.Create(connection);await using var db=await root.OpenConnectionAsync();
  var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();using var stop=new CancellationTokenSource();var active=false;
  var engine=Task.Run(async()=>{
   while(!stop.IsCancellationRequested){TcpClient socket;try{socket=await listener.AcceptTcpClientAsync(stop.Token);}catch(OperationCanceledException){break;}
    using(socket){var stream=socket.GetStream();await stream.WriteAsync("Content-Type: auth/request\n\n"u8.ToArray());var reader=new StreamReader(stream,Encoding.UTF8,leaveOpen:true);await reader.ReadLineAsync();await reader.ReadLineAsync();await stream.WriteAsync("Content-Type: command/reply\nReply-Text: +OK\n\n"u8.ToArray());await reader.ReadLineAsync();await reader.ReadLineAsync();var text=active?"{\"row_count\":1}":"{\"row_count\":0}";await stream.WriteAsync(Encoding.UTF8.GetBytes($"Content-Type: api/response\nContent-Length: {Encoding.UTF8.GetByteCount(text)}\n\n{text}"));}
   }
  });
  try{
   await new NpgsqlCommand($"create schema {schema};set search_path to {schema},public;create table v_users(user_uuid uuid primary key)",db).ExecuteNonQueryAsync();
   var sql=await File.ReadAllTextAsync("app/pbx_updates/resources/install.sql");sql=sql[..sql.IndexOf("DO $$",StringComparison.Ordinal)]+"COMMIT;";await new NpgsqlCommand(sql,db).ExecuteNonQueryAsync();
   var builder=new NpgsqlConnectionStringBuilder(connection){SearchPath=schema+",public"};await using var data=NpgsqlDataSource.Create(builder.ConnectionString);var repository=new UpdateRepository(data);
   var race=Guid.NewGuid();await new NpgsqlCommand($"insert into v_pbx_update_commands(command_uuid,action) values('{race}','check')",db).ExecuteNonQueryAsync();
   var claims=await Task.WhenAll(repository.Claim(default),repository.Claim(default));Check(claims.Count(x=>x is not null)==1,"A command was claimed twice");await repository.Finish(claims.Single(x=>x is not null)!,true,"Checked",default);
   Check(await repository.Claim(default) is null,"A completed command replayed");
   var stale=Guid.NewGuid();await new NpgsqlCommand($"insert into v_pbx_update_commands(command_uuid,action,created_at) values('{stale}','install',now()-interval '25 hours')",db).ExecuteNonQueryAsync();
   Check(await repository.Claim(default) is null && (string)(await new NpgsqlCommand($"select status from v_pbx_update_commands where command_uuid='{stale}'",db).ExecuteScalarAsync())! =="failed","Expired install authorization was claimed");
   var versionFile=Path.Combine(temporary,"VERSION");await File.WriteAllTextAsync(versionFile,"1.0.3");
   var helper=Path.Combine(temporary,"helper.py");var installedMarker=Path.Combine(temporary,"installed-count");var updates=Path.Combine(temporary,"updates");Directory.CreateDirectory(updates);
   await File.WriteAllTextAsync(helper,"import sys,json,pathlib\n"+"if '--recover' in sys.argv or '--check' in sys.argv: sys.exit(0)\n"+"pathlib.Path("+JsonSerializer.Serialize(versionFile)+").write_text('1.0.4')\n"+"pathlib.Path("+JsonSerializer.Serialize(installedMarker)+").write_text('installed')\n"+"pathlib.Path("+JsonSerializer.Serialize(Path.Combine(updates,"install-journal.json"))+").write_text(json.dumps({'state':'completed'}))\n");
   var configuration=new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?>{["Updater:DataDirectory"]=updates,["Updater:PublicStatus"]=Path.Combine(temporary,"status.json"),["Updater:InstalledVersionPath"]=versionFile,["Updater:Helper"]=helper,["Switch:Host"]="127.0.0.1",["Switch:Port"]=((IPEndPoint)listener.LocalEndpoint).Port.ToString(),["Switch:Password"]="private-test"}).Build();
   var paths=new UpdaterPaths(configuration);paths.Prepare();
   using var rsa=RSA.Create(2048);var verifier=new ReleaseVerifier(rsa.ExportSubjectPublicKeyInfoPem());var bytes="private-worker-fixture"u8.ToArray();
   var payload=JsonSerializer.SerializeToUtf8Bytes(new{schema=1,product="openwebpbx",channel="stable",sequence=104,version="1.0.4",published_at=DateTimeOffset.UtcNow.AddMinutes(-1),expires_at=DateTimeOffset.UtcNow.AddDays(1),assets=new[]{new{platform="debian13-amd64",name="openwebpbx-1.0.4-debian13-amd64.tar.gz",url="https://github.com/embire2/openwebpbx/releases/download/v1.0.4/openwebpbx-1.0.4-debian13-amd64.tar.gz",bytes=bytes.Length,sha256=Convert.ToHexStringLower(SHA256.HashData(bytes)),minimum_version="1.0.3"}}});
   var envelope=JsonSerializer.SerializeToUtf8Bytes(new{key_id="release-2026-a",payload=Convert.ToBase64String(payload),signature=Convert.ToBase64String(rsa.SignData(payload,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1))});
   var downloadCount=0;
   using var downloads=new DownloadClient(new Handler(request=>{var feed=request.RequestUri!.AbsolutePath.EndsWith("update-manifest.json");if(!feed)downloadCount++;return new(HttpStatusCode.OK){Content=new ByteArrayContent(feed?envelope:bytes)};}));
   var worker=new Worker(repository,paths,verifier,downloads,new PlatformInstaller(paths),new SwitchClient(configuration),NullLogger<Worker>.Instance){OneShot=true,SkipRecovery=true};
   await worker.Initialize(default);await worker.Tick(default);
   Check(UpdateJson.Read<UpdateStatus>(paths.Status).State=="available"&&downloadCount==0&&!File.Exists(installedMarker),"Notify policy changed the application");
   var request=Guid.NewGuid();await new NpgsqlCommand($"insert into v_pbx_update_commands(command_uuid,action) values('{request}','download')",db).ExecuteNonQueryAsync();await worker.Tick(default);
   Check(UpdateJson.Read<UpdateStatus>(paths.Status).State=="ready"&&downloadCount==1&&!File.Exists(installedMarker),"Download command installed application");
   request=Guid.NewGuid();await new NpgsqlCommand($"insert into v_pbx_update_commands(command_uuid,action) values('{request}','install')",db).ExecuteNonQueryAsync();active=true;await worker.Tick(default);
   Check(UpdateJson.Read<UpdateStatus>(paths.Status).State=="waiting_calls"&&!File.Exists(installedMarker),"Active calls did not defer installation");
   active=false;await worker.Tick(default);
   Check(UpdateJson.Read<UpdateStatus>(paths.Status).State=="completed"&&File.Exists(installedMarker),"Idle installation did not complete");
   Check((string)(await new NpgsqlCommand($"select status from v_pbx_update_commands where command_uuid='{request}'",db).ExecuteScalarAsync())! =="completed","Completed install command was not durable");
   await worker.Tick(default);Check(downloadCount==1,"Completed update downloaded twice");
   var interrupted=Guid.NewGuid();await new NpgsqlCommand($"insert into v_pbx_update_commands(command_uuid,action,status) values('{interrupted}','install','running')",db).ExecuteNonQueryAsync();
   UpdateJson.Write(paths.Journal,new WorkerJournal(interrupted,"install","1.0.4","installing",DateTimeOffset.UtcNow));
   await worker.Initialize(default);Check((string)(await new NpgsqlCommand($"select status from v_pbx_update_commands where command_uuid='{interrupted}'",db).ExecuteScalarAsync())! =="completed","Completed journal was not reconciled");
   var unfinished=Guid.NewGuid();await new NpgsqlCommand($"insert into v_pbx_update_commands(command_uuid,action,status) values('{unfinished}','download','running')",db).ExecuteNonQueryAsync();
   await worker.Initialize(default);Check((string)(await new NpgsqlCommand($"select status from v_pbx_update_commands where command_uuid='{unfinished}'",db).ExecuteScalarAsync())! =="pending","Interrupted download did not resume safely");
   await repository.Heartbeat(default);Check((bool)(await new NpgsqlCommand("select updated_at>now()-interval '5 seconds' from v_pbx_update_status",db).ExecuteScalarAsync())!,"Heartbeat is stale");
   await new NpgsqlCommand("delete from v_pbx_update_commands;insert into v_pbx_update_policies(scope_key,mode,maintenance_hour,maintenance_duration) values('instance','automatic',extract(hour from now() at time zone 'UTC')::int,2) on conflict(scope_key) do update set mode='automatic',maintenance_hour=excluded.maintenance_hour,maintenance_duration=2",db).ExecuteNonQueryAsync();
   await File.WriteAllTextAsync(versionFile,"1.0.3");File.Delete(installedMarker);
   await File.WriteAllTextAsync(helper,"import sys,json,pathlib\nif '--recover' in sys.argv or '--check' in sys.argv: sys.exit(0)\n"+"p=pathlib.Path("+JsonSerializer.Serialize(installedMarker)+");p.write_text(p.read_text()+'x' if p.exists() else 'x')\n"+"pathlib.Path("+JsonSerializer.Serialize(Path.Combine(updates,"install-journal.json"))+").write_text(json.dumps({'state':'rolled_back'}))\nsys.exit(1)\n");
   Worker Fresh()=>new(repository,paths,verifier,downloads,new PlatformInstaller(paths),new SwitchClient(configuration),NullLogger<Worker>.Instance){OneShot=true,SkipRecovery=true};
   var failed=Fresh();await failed.Initialize(default);await failed.Tick(default);
   Check(File.ReadAllText(installedMarker)=="x" && File.Exists(paths.FailedInstall),"Failed installation was not durably recorded");
   failed=Fresh();await failed.Initialize(default);await failed.Tick(default);
   Check(File.ReadAllText(installedMarker)=="x" && UpdateJson.Read<UpdateStatus>(paths.Status).State=="error","A restarted worker repeated a failed automatic install");
   File.Delete(paths.FailedInstall);UpdateJson.Write(paths.Journal,new WorkerJournal(null,null,"1.0.4","installing",DateTimeOffset.UtcNow,Convert.ToHexStringLower(SHA256.HashData(bytes))));
   failed=Fresh();await failed.Initialize(default);await failed.Tick(default);
   Check(File.Exists(paths.FailedInstall)&&File.ReadAllText(installedMarker)=="x","Boot recovery replayed an interrupted automatic installation without a command");
   await new NpgsqlCommand($"insert into v_pbx_update_commands(command_uuid,action) values('{Guid.NewGuid()}','install')",db).ExecuteNonQueryAsync();await failed.Tick(default);
   Check(File.ReadAllText(installedMarker)=="xx","Explicit administrator retry was not allowed");
   using var badEnvelope=JsonDocument.Parse(envelope);
   var tampered=JsonSerializer.SerializeToUtf8Bytes(new{key_id="release-2026-a",payload=badEnvelope.RootElement.GetProperty("payload").GetString(),signature=Convert.ToBase64String(new byte[256])});
   using var badDownload=new DownloadClient(new Handler(_=>new(HttpStatusCode.OK){Content=new ByteArrayContent(tampered)}));
   var rejected=new Worker(repository,paths,verifier,badDownload,new PlatformInstaller(paths),new SwitchClient(configuration),NullLogger<Worker>.Instance){OneShot=true,SkipRecovery=true};
   await rejected.Initialize(default);await rejected.Tick(default);
   Check(UpdateJson.Read<UpdateStatus>(paths.Status).State=="error"&&File.ReadAllText(installedMarker)=="xx","Invalid signed feed escaped worker error handling or changed the PBX");
  }finally{stop.Cancel();listener.Stop();await engine;await new NpgsqlCommand($"set search_path to public;drop schema {schema} cascade",db).ExecuteNonQueryAsync();Directory.Delete(temporary,true);}
  return count;
 }
}
