using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using OpenWebPbx.Updater;

if (args.Contains("--windows-server-update-checks", StringComparer.Ordinal))
{
    var windowsConnection = Environment.GetEnvironmentVariable("OPENWEB_TEST_DATABASE") ?? throw new InvalidOperationException("An owned PostgreSQL fixture is required.");
    Console.WriteLine($"PASS: {await WindowsServerUpdateChecks.Run(windowsConnection)} actual Windows five-minute, download, postponement, idle, queue, unattended helper and retry controls");
    return;
}

if (args.Contains("--startup-checks", StringComparer.Ordinal))
{
    var startupConnection = Environment.GetEnvironmentVariable("OPENWEB_TEST_DATABASE") ?? throw new InvalidOperationException("An independently owned PostgreSQL fixture is required.");
    await WorkerStartupChecks.Run(startupConnection);
    return;
}

var checks = 0;
void Check(bool valid, string name) { if (!valid) throw new Exception(name); checks++; }
void Reject(Action action, string name) { try { action(); } catch (Exception e) when (e is InvalidDataException or CryptographicException or FormatException or KeyNotFoundException or JsonException) { checks++; return; } throw new Exception(name); }
async Task RejectAsync(Func<Task> action, string name) { try { await action(); } catch (Exception e) when (e is InvalidDataException or IOException) { checks++; return; } throw new Exception(name); }
using var rsa = RSA.Create(3072);
var verifier = new ReleaseVerifier(rsa.ExportSubjectPublicKeyInfoPem());
var now = DateTimeOffset.UtcNow;
var directory = Path.Combine(Path.GetTempPath(), "openweb-updater-check-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
var payload = new Dictionary<string,object?> { ["schema"] = 1, ["product"] = "openwebpbx", ["channel"] = "stable", ["sequence"] = 104L, ["version"] = "1.0.4", ["published_at"] = now.AddMinutes(-1), ["expires_at"] = now.AddDays(7) };
string prefix = "openwebpbx-1.0.4-windows-x64";
byte[] Archive(Action<ZipArchive>? mutate = null)
{
    using var stream = new MemoryStream();
    using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, true))
    {
        var files = new Dictionary<string,string> { ["VERSION"]="1.0.4\n", ["web/resources/require.php"]="<?php", ["bootstrap.php"]="<?php", ["server/OpenWebPbx.Server.exe"]="fixture", ["desktop/OpenWebPbx.Desktop.exe"]="fixture" };
        var hashes = new Dictionary<string,string>();
        foreach (var (name,text) in files) { var bytes=System.Text.Encoding.UTF8.GetBytes(text); using var output=zip.CreateEntry(prefix+"/"+name).Open();output.Write(bytes);hashes[name]=Convert.ToHexStringLower(SHA256.HashData(bytes)); }
        using (var output=zip.CreateEntry(prefix+"/release-manifest.json").Open()) JsonSerializer.Serialize(output,new {version="1.0.4",files=hashes});
        mutate?.Invoke(zip);
    }
    return stream.ToArray();
}
var archive = Archive();
Dictionary<string,object?> Asset(byte[] bytes) => new() { ["platform"]="windows-x64",["name"]="openwebpbx-1.0.4-windows-x64.zip",["url"]="https://github.com/embire2/openwebpbx/releases/download/v1.0.4/openwebpbx-1.0.4-windows-x64.zip",["bytes"]=bytes.Length,["sha256"]=Convert.ToHexStringLower(SHA256.HashData(bytes)),["minimum_version"]="1.0.3" };
byte[] Envelope(Dictionary<string,object?> fields) { var bytes=JsonSerializer.SerializeToUtf8Bytes(fields); return JsonSerializer.SerializeToUtf8Bytes(new {key_id="release-2026-a",payload=Convert.ToBase64String(bytes),signature=Convert.ToBase64String(rsa.SignData(bytes,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1))}); }
payload["assets"]=new[]{Asset(archive)};
try
{
 foreach (var mode in new[]{"notify","download","automatic"}) {
  var policy=new UpdatePolicy(mode,23,3);
  Check(ServerUpdateBehaviour.EffectivePolicy("windows-x64",policy)==new UpdatePolicy("download",23,3),"Windows may install without an explicit request");
  Check(ServerUpdateBehaviour.EffectivePolicy("debian13-amd64",policy)==policy,"Windows policy changed Debian behaviour");
 }
 Check(ServerUpdateBehaviour.CheckInterval("windows-x64")==TimeSpan.FromMinutes(5),"Windows does not check every five minutes");
 Check(ServerUpdateBehaviour.CheckInterval("debian13-amd64")==TimeSpan.FromHours(6),"Debian interval changed");
 var noticeFields=new Dictionary<string,object?> { ["platform"]="windows-x64",["update_required"]=true,["available_version"]="1.0.21",["installed_version"]="1.0.20",["download_ready"]=false };
 OpenWebPbx_Desktop.ServerUpdateNotice? Notice(){using var document=JsonDocument.Parse(JsonSerializer.SerializeToUtf8Bytes(noticeFields));return OpenWebPbx_Desktop.ServerUpdateNotice.Read(document.RootElement);}
 Check(Notice() is {Version:"1.0.21",Ready:false},"Required prompt did not wait for download");
 noticeFields["download_ready"]=true;
 Check(Notice() is {Ready:true} && Notice()!.Message==ServerUpdateBehaviour.Notice("1.0.21"),"Desktop notice differs from the service notice");
 foreach(var (field,value) in new (string,object?)[]{("platform","debian13-amd64"),("platform",null),("update_required","true"),("update_required",false),("available_version","1.0.20"),("available_version","1.0.19"),("available_version","1.0.021"),("available_version","1.0.21\n"),("available_version","<script>"),("available_version",42),("installed_version",null)}) {
  var previous=noticeFields[field];noticeFields[field]=value;Check(Notice() is null,"Invalid or non-Windows update displayed a mandatory notice");noticeFields[field]=previous;
 }
 var envelope=Envelope(payload);var release=verifier.Verify(envelope,"windows-x64",null,now);
 Check(release.Version=="1.0.4","signed feed accepted");
 var changed=(byte[])envelope.Clone();changed[^12]^=1;Reject(()=>verifier.Verify(changed,"windows-x64",null,now),"tampered envelope accepted");
 using(var other=RSA.Create(2048))Reject(()=>new ReleaseVerifier(other.ExportSubjectPublicKeyInfoPem()).Verify(envelope,"windows-x64",null,now),"foreign signing key accepted");
 Reject(()=>verifier.Verify(envelope,"debian13-amd64",null,now),"wrong architecture accepted");
 Reject(()=>verifier.Verify(envelope,"windows-x64",new TrustState(105,"x"),now),"old sequence accepted");
 Reject(()=>verifier.Verify(envelope,"windows-x64",new TrustState(104,"x"),now),"changed repeated sequence accepted");
 Check(verifier.Verify(envelope,"windows-x64",new TrustState(104,release.PayloadSha256),now).Sequence==104,"identical sequence rejected");
 Reject(()=>verifier.Verify(envelope,"windows-x64",null,now.AddDays(8)),"expired feed accepted");
 Reject(()=>verifier.Verify(envelope,"windows-x64",null,now.AddHours(-1)),"future feed accepted");
 Reject(()=>ReleaseVerifier.RequireUpgrade(release,"1.0.4"),"equal version upgrade accepted");
 Reject(()=>ReleaseVerifier.RequireUpgrade(release,"1.1.0"),"downgrade accepted");
 Reject(()=>ReleaseVerifier.RequireUpgrade(release,"1.0.2"),"unsupported old installation accepted");
 var foreign=Asset(archive);foreign["url"]="https://example.invalid/update.zip";payload["assets"]=new[]{foreign};Reject(()=>verifier.Verify(Envelope(payload),"windows-x64",null,now),"foreign download URL accepted");payload["assets"]=new[]{Asset(archive)};
 Check(!DownloadClient.Allowed(new Uri("http://github.com/embire2/openwebpbx/releases/download/v1.0.4/test")),"cleartext redirect accepted");
 Check(!DownloadClient.Allowed(new Uri("https://github.com/another/repo/releases/download/test")),"foreign repo redirect accepted");
 Check(!DownloadClient.Allowed(new Uri("https://github.com:444/embire2/openwebpbx/releases/download/test")),"alternate port accepted");
 Check(!DownloadClient.Allowed(new Uri("https://evil.example/")),"foreign host accepted");
 Check(UpdaterPaths.FeedUrlForPlatform("windows-x64")==UpdaterPaths.WindowsFeedUrl,"Windows server did not select its fixed feed");
 Check(UpdaterPaths.GenericFeedUrl=="https://github.com/embire2/openwebpbx/releases/latest/download/update-manifest.json","Android's original feed changed");
 Check(UpdaterPaths.FeedUrlForPlatform("debian13-amd64")==UpdaterPaths.DebianFeedUrl && UpdaterPaths.DebianFeedUrl!=UpdaterPaths.GenericFeedUrl,"Debian server did not select its independent feed");
 Check(DownloadClient.Allowed(new Uri(UpdaterPaths.WindowsFeedUrl))&&DownloadClient.Allowed(new Uri(UpdaterPaths.DebianFeedUrl))&&DownloadClient.Allowed(new Uri(UpdaterPaths.GenericFeedUrl)),"fixed platform feed was rejected");
 Check(!DownloadClient.Allowed(new Uri("https://github.com/embire2/openwebpbx/releases/latest/download/foreign-feed.json")),"arbitrary latest feed filename accepted");
 foreach(var invalid in new[]{"https://github.com/another/repo/releases/latest/download/debian-update-manifest.json","https://github.com/embire2/openwebpbx/releases/latest/download/debian-update-manifest.json/extra","http://github.com/embire2/openwebpbx/releases/latest/download/debian-update-manifest.json","https://user@github.com/embire2/openwebpbx/releases/latest/download/debian-update-manifest.json"})
  Check(!DownloadClient.Allowed(new Uri(invalid)),"unsafe Debian feed location accepted");
 var feedRequests=new List<string>();
 using(var downloader=new DownloadClient(new Handler(request=>{feedRequests.Add(request.RequestUri!.AbsoluteUri);return new(HttpStatusCode.OK){Content=new ByteArrayContent(envelope)};})))
 {
  Check((await downloader.Feed("windows-x64",default)).SequenceEqual(envelope)&&feedRequests[^1]==UpdaterPaths.WindowsFeedUrl,"Windows feed request was rerouted");
  Check((await downloader.Feed("debian13-amd64",default)).SequenceEqual(envelope)&&feedRequests[^1]==UpdaterPaths.DebianFeedUrl,"Debian feed request was rerouted");
  try{await downloader.Feed("https://example.invalid/feed",default);throw new Exception("arbitrary feed URL accepted");}catch(PlatformNotSupportedException){Check(feedRequests.Count==2,"unsupported feed reached the network");}
 }
 var unavailableFeedRequests=new List<string>();
 using(var downloader=new DownloadClient(new Handler(request=>{unavailableFeedRequests.Add(request.RequestUri!.AbsoluteUri);return new(HttpStatusCode.NotFound);})))
 {
  try{await downloader.Feed("debian13-amd64",default);throw new Exception("missing Debian feed accepted");}
  catch(HttpRequestException){Check(unavailableFeedRequests.SequenceEqual(new[]{UpdaterPaths.DebianFeedUrl}),"missing Debian feed fell back to another platform");}
 }
 var injected=new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?>{["Updater:FeedUrl"]="https://example.invalid/feed",["Updater:DebianFeedUrl"]=UpdaterPaths.GenericFeedUrl}).Build();
 var fixedPaths=new UpdaterPaths(injected);
 Check(fixedPaths.FeedUrl==UpdaterPaths.FeedUrlForPlatform(fixedPaths.Platform),"configuration overrode the built-in feed");
 var path=Path.Combine(directory,"valid.zip");await File.WriteAllBytesAsync(path,archive);
 Check(Directory.Exists(await PackageExtractor.Extract(path,Path.Combine(directory,"good"),release,default)),"valid archive rejected");
 foreach(var kind in new[]{"traversal","duplicate","symlink","unlisted"})
 {
  var malformed=Archive(zip=>{var name=kind=="traversal"?prefix+"/../escape":kind=="duplicate"?prefix+"/VERSION":prefix+"/unexpected";var entry=zip.CreateEntry(name);if(kind=="symlink")entry.ExternalAttributes=0xA1FF<<16;using var output=entry.Open();output.WriteByte(1);});
  await File.WriteAllBytesAsync(path,malformed);payload["assets"]=new[]{Asset(malformed)};var testRelease=verifier.Verify(Envelope(payload),"windows-x64",null,now);
  await RejectAsync(()=>PackageExtractor.Extract(path,Path.Combine(directory,kind),testRelease,default),kind+" archive accepted");
 }
 await File.WriteAllBytesAsync(path,new byte[]{1});await RejectAsync(()=>ReleaseVerifier.VerifyArchive(path,release.Asset,default),"incomplete archive accepted");
 Check(UpdateJson.InWindow(new("automatic",23,2),new DateTimeOffset(2026,1,1,0,59,0,TimeSpan.Zero)),"wrapping maintenance window rejected");
 Check(!UpdateJson.InWindow(new("automatic",23,2),new DateTimeOffset(2026,1,1,1,0,0,TimeSpan.Zero)),"outside maintenance window accepted");
 Check(UpdaterPaths.IsDebian13(new[]{"ID=debian","VERSION_ID=\"13\""}),"Debian 13 was not recognized");
 Check(!UpdaterPaths.IsDebian13(new[]{"ID=other","VERSION_ID=\"13\""}),"Another version-13 distribution was accepted");
 Check(!UpdaterPaths.IsDebian13(new[]{"ID=debian","VERSION_ID=\"12\""}),"Older Debian was accepted");
 var restoreRoot=Path.Combine(directory,"restore-gates");Directory.CreateDirectory(restoreRoot);
 Check(!RestoreGates.BlocksUpdate(restoreRoot),"A normal instance was blocked by restore gates");
 var restoreDir=Path.Combine(restoreRoot,"backup-restore");Directory.CreateDirectory(restoreDir);
 foreach(var name in new[]{"calls","jobs","updates","backups"})
 {
  var hold=Path.Combine(restoreDir,"hold-"+name);File.WriteAllText(hold,"{}");
  Check(RestoreGates.BlocksUpdate(restoreRoot),"A persistent restore hold did not block updates: "+name);File.Delete(hold);
 }
 var restoreJournal=Path.Combine(restoreDir,"journal.json");
 foreach(var state in new[]{"prepared","restoring","recovery_required","unknown"})
 {
  File.WriteAllText(restoreJournal,JsonSerializer.Serialize(new{schema=1,state}));
  Check(RestoreGates.BlocksUpdate(restoreRoot),"Unsafe restore journal allowed an update: "+state);
 }
 foreach(var state in new[]{"restored","recovered"})
 {
  File.WriteAllText(restoreJournal,JsonSerializer.Serialize(new{schema=1,state}));
  Check(!RestoreGates.BlocksUpdate(restoreRoot),"A completed and activated restore blocked updates: "+state);
 }
 File.WriteAllText(restoreJournal,"{invalid");Check(RestoreGates.BlocksUpdate(restoreRoot),"Malformed restore journal allowed an update");
 File.Delete(restoreJournal);Directory.CreateDirectory(restoreJournal);Check(RestoreGates.BlocksUpdate(restoreRoot),"Directory-shaped restore journal allowed an update");
 var durable=Path.Combine(directory,"state.json");UpdateJson.Write(durable,new TrustState(104,"first"));UpdateJson.Write(durable,new TrustState(105,"second"));
 Check(UpdateJson.Read<TrustState>(durable).Sequence==105&&!Directory.EnumerateFiles(directory,"*.tmp").Any(),"Durable state replacement failed");
 var downloadDir=Path.Combine(directory,"download");Directory.CreateDirectory(downloadDir);var partial=Path.Combine(downloadDir,release.Asset.Sha256+".archive.partial");await File.WriteAllBytesAsync(partial,archive[..100]);
 var rangeSeen=false;
 using(var downloader=new DownloadClient(new Handler(request=>{rangeSeen=request.Headers.Range?.Ranges.Single().From==100;var response=new HttpResponseMessage(HttpStatusCode.PartialContent){Content=new ByteArrayContent(archive[100..])};response.Content.Headers.ContentRange=new ContentRangeHeaderValue(100,archive.Length-1,archive.Length);return response;})))
 {var downloaded=await downloader.Download(release.Asset,downloadDir,_=>Task.CompletedTask,default);Check(rangeSeen&&File.ReadAllBytes(downloaded).SequenceEqual(archive),"resumable range download failed");File.Delete(downloaded);}
 await File.WriteAllBytesAsync(partial,archive[..100]);
 using(var downloader=new DownloadClient(new Handler(_=>new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(archive)})))
 {var downloaded=await downloader.Download(release.Asset,downloadDir,_=>Task.CompletedTask,default);Check(File.ReadAllBytes(downloaded).SequenceEqual(archive),"server ignoring Range was not safely restarted");File.Delete(downloaded);}
 var bad=(byte[])archive.Clone();bad[^1]^=1;
 using(var downloader=new DownloadClient(new Handler(_=>new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(bad)})))
 {await RejectAsync(()=>downloader.Download(release.Asset,downloadDir,_=>Task.CompletedTask,default),"corrupt download accepted");Check(!File.Exists(partial),"corrupt partial retained");}
 var disconnected=new byte[archive.Length/2];
 using(var downloader=new DownloadClient(new Handler(_=>new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(disconnected)})))
 {await RejectAsync(()=>downloader.Download(release.Asset,downloadDir,_=>Task.CompletedTask,default),"short response accepted");}
 Console.WriteLine($"PASS: {checks} signed feed, rollback protection, archive safety, download recovery and maintenance checks");
}
finally{Directory.Delete(directory,true);}
var connection=Environment.GetEnvironmentVariable("OPENWEB_TEST_DATABASE");
if(!string.IsNullOrEmpty(connection))Console.WriteLine($"PASS: {await DatabaseChecks.Run(connection)} isolated database, policy, command, call-idle and recovery checks");
sealed class Handler(Func<HttpRequestMessage,HttpResponseMessage> respond):HttpMessageHandler
{protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)=>Task.FromResult(respond(request));}
