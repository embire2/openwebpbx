// Isolated HTTP/PG/DNS-adapter checks. Never use a customer or central production DB.
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Npgsql;
using OpenWebPbx.DomainRegistry;
int checks=0;
void Check(bool value,string name){if(!value)throw new Exception(name);checks++;}
foreach(var ip in new[]{"0.0.0.0","10.0.0.1","127.0.0.1","169.254.169.254","100.64.0.1","172.16.1.1","192.168.1.1","192.0.2.1","198.18.0.1","198.51.100.1","203.0.113.1","224.0.0.1","::1","::ffff:127.0.0.1","fe80::1","fc00::1","2001:db8::1","2002::1","3fff::1"})Check(!PublicSiteProof.IsPublic(IPAddress.Parse(ip)),"Public-proof SSRF refusal "+ip);
foreach(var ip in new[]{"8.8.8.8","1.1.1.1","192.0.3.1","2606:4700:4700::1111"})Check(PublicSiteProof.IsPublic(IPAddress.Parse(ip)),"Public proof address");
foreach(var host in new[]{"127.0.0.1","LOCALHOST","localhost","x.invalid","user@server.example.com","a.example.com/path","a.example.com:443","a.openwebpbx.com"}){try{Protocol.Host(host);throw new Exception("Unsafe hostname accepted");}catch(Refused){checks++;}}
using var keyA=ECDsa.Create(ECCurve.NamedCurves.nistP256);using var keyB=ECDsa.Create(ECCurve.NamedCurves.nistP256);
string Public(ECDsa key)=>Convert.ToBase64String(key.ExportSubjectPublicKeyInfo());
var connection=Environment.GetEnvironmentVariable("OPENWEB_REGISTRY_TEST_DATABASE");
if(string.IsNullOrEmpty(connection)){Console.WriteLine($"PASS {checks} protocol controls; isolated PostgreSQL required for integration.");return;}
var cs=new NpgsqlConnectionStringBuilder(connection);if(cs.Host!="127.0.0.1"||cs.Port<20000||!cs.Database!.StartsWith("openweb_registry_check_"))throw new Exception("Disposable PostgreSQL required");
await using var source=NpgsqlDataSource.Create(connection);
var fixtures=WebApplication.CreateBuilder();fixtures.Logging.ClearProviders();fixtures.WebHost.UseUrls("http://127.0.0.1:0");await using var fixture=fixtures.Build();
var proofs=new Dictionary<string,byte[]>();var dns=new DnsFixture();
fixture.MapGet("/.well-known/openwebpbx-instance/{nonce}",(string nonce)=>proofs.TryGetValue(nonce,out var body)?Microsoft.AspNetCore.Http.Results.Bytes(body,"text/plain"):Microsoft.AspNetCore.Http.Results.NotFound());
fixture.MapGet("/execute/DNS/{operation}",dns.Handle);
await fixture.StartAsync();var fixtureUrl=fixture.Urls.Single();
var options=new RegistryOptions(connection,fixtureUrl+"/","fictional","not-a-provider-credential"){ListenUrl="http://127.0.0.1:0"};
var proof=new HttpProof(new HttpClient{BaseAddress=new Uri(fixtureUrl)});var adapter=new CpanelDns(options);
await using var broker=RegistryApplication.Create([],options,services=>{services.AddSingleton<ISiteProof>(proof);services.AddSingleton<IRegistryDns>(adapter);services.AddLogging(log=>log.ClearProviders());});
await broker.Services.GetRequiredService<RegistryStore>().Initialize(default);await broker.StartAsync();using var client=new HttpClient{BaseAddress=new Uri(broker.Urls.Single())};
async Task<LeaseRequest> Request(ECDsa key,string host,Guid tenant,Guid domain,string label,long revision=0,bool enabled=true,bool move=false){
 var response=await client.PostAsJsonAsync("/v1/challenges",new ChallengeRequest(Public(key),host));Check(response.IsSuccessStatusCode,"Challenge HTTP success");var challenge=(await response.Content.ReadFromJsonAsync<ChallengeReply>())!;var hash=Protocol.KeyHash(Public(key));proofs[challenge.Challenge]=Protocol.Proof(challenge.Challenge,hash,host);var r=new LeaseRequest(challenge.Challenge,Public(key),host,tenant,domain,label,enabled,revision,move,"");return r with{Signature=Convert.ToBase64String(key.SignData(Protocol.Message(r,hash),HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence))};
}
async Task<(HttpResponseMessage Http,LeaseReply? Reply)> Send(LeaseRequest request,bool match=false){using var message=new HttpRequestMessage(HttpMethod.Post,"/v1/leases"){Content=JsonContent.Create(request)};if(match)message.Headers.TryAddWithoutValidation("If-Match","\""+request.Revision+"\"");var response=await client.SendAsync(message);return(response,response.IsSuccessStatusCode?await response.Content.ReadFromJsonAsync<LeaseReply>():null);}
var tenantA=Guid.NewGuid();var domainA=Guid.NewGuid();var initial=await Request(keyA,"server-a.example.test",tenantA,domainA,"fictional-company");var a=await Send(initial);Check(a.Reply?.State=="dns_ready"&&a.Reply.Revision==1,"Actual signed HTTP lease and DNS write");Check(dns.Changes==1,"Exactly one DNS mutation");Check(dns.UnrelatedExact,"All unrelated DNS records exact");
var replay=await Send(initial);Check(replay.Http.StatusCode==HttpStatusCode.Forbidden&&dns.Changes==1,"Consumed nonce replay cannot mutate");
var lookup=await client.GetAsync("/v1/tenant-addresses/"+a.Reply!.Hostname);
Check(lookup.IsSuccessStatusCode&&lookup.Headers.CacheControl?.NoStore==true,"Tenant origin lookup succeeds without caching");
var address=(await lookup.Content.ReadFromJsonAsync<TenantAddressReply>())!;
Check(address.Schema==1&&address.Hostname==a.Reply.Hostname&&address.ServerOrigin=="https://server-a.example.test"&&address.DomainUuid==domainA&&address.Revision==1,"Lookup binds exact hostname, original canonical origin, domain and revision");
var lookupJson=JsonDocument.Parse(await lookup.Content.ReadAsStringAsync());
Check(lookupJson.RootElement.EnumerateObject().Select(p=>p.Name).Order().SequenceEqual(new[]{"domainUuid","hostname","revision","schema","serverOrigin"}),"Public lookup discloses only the migration binding");
foreach(var invalid in new[]{"unknown-company.openwebpbx.com","admin.openwebpbx.com","www.openwebpbx.com","company.openwebpbx.com.evil.test","nested.company.openwebpbx.com","UPPER.openwebpbx.com","openwebpbx.com"})
 Check((await client.GetAsync("/v1/tenant-addresses/"+invalid)).StatusCode==HttpStatusCode.NotFound,"Unowned/non-tenant address cannot resolve "+invalid);
var changesBeforeLookup=dns.Changes;
await using(var pending=source.CreateCommand("update registry_leases set state='pending_dns' where domain_uuid=$1")){pending.Parameters.AddWithValue(domainA);await pending.ExecuteNonQueryAsync();}
Check((await client.GetAsync("/v1/tenant-addresses/"+a.Reply.Hostname)).StatusCode==HttpStatusCode.NotFound,"Pending DNS never authorises token migration");
await using(var ready=source.CreateCommand("update registry_leases set state='dns_ready' where domain_uuid=$1")){ready.Parameters.AddWithValue(domainA);await ready.ExecuteNonQueryAsync();}
Check(dns.Changes==changesBeforeLookup,"Origin lookups do not mutate DNS");
var lostReply=await Send(await Request(keyA,"server-a.example.test",tenantA,domainA,"fictional-company"));Check(lostReply.Reply?.Hostname==a.Reply!.Hostname&&lostReply.Reply.Revision==1&&dns.Changes==1,"Lost creation response retries original revision with fresh signed nonce without DNS mutation");
var wrongTenantRetry=await Send(await Request(keyA,"server-a.example.test",Guid.NewGuid(),domainA,"fictional-company"));Check(wrongTenantRetry.Http.StatusCode==HttpStatusCode.Conflict&&dns.Changes==1,"Initial retry cannot change tenant ownership");
var renewal=await Send(await Request(keyA,"server-a.example.test",tenantA,domainA,"renamed-company",1));Check(renewal.Reply?.Hostname==a.Reply!.Hostname&&dns.Changes==1,"Stable name and idempotent DNS renewal");
var duplicate=await Send(await Request(keyB,"server-a.example.test",Guid.NewGuid(),Guid.NewGuid(),"other-company"));Check(duplicate.Http.StatusCode==HttpStatusCode.Conflict&&dns.Changes==1,"Foreign key cannot take a verified registered hostname");
var domainB=Guid.NewGuid();var collision=await Send(await Request(keyB,"server-b.example.test",Guid.NewGuid(),domainB,"fictional-company"));Check(collision.Reply?.Hostname==Protocol.CollisionLabel("fictional-company",Protocol.KeyHash(Public(keyB)),domainB)+".openwebpbx.com","Stable global collision suffix");Check(dns.UnrelatedExact,"Only owned alias DNS changed");
var reserved=await Send(await Request(keyA,"server-a.example.test",tenantA,Guid.NewGuid(),"admin"));Check(reserved.Reply?.Hostname!="admin.openwebpbx.com"&&reserved.Reply?.State=="dns_ready","Reserved name uses stable suffix");
var disabled=await Send(await Request(keyA,"server-a.example.test",tenantA,domainA,"fictional-company",1,false));Check(disabled.Reply?.State=="disabled"&&disabled.Reply.Hostname==a.Reply!.Hostname,"Disabled lease retains original ownership/name");
Check((await client.GetAsync("/v1/tenant-addresses/"+a.Reply!.Hostname)).StatusCode==HttpStatusCode.NotFound,"Disabled tenant cannot authorise a saved-token recipient");
var restore=await Send(await Request(keyA,"server-a.example.test",tenantA,domainA,"fictional-company",1));Check(restore.Reply?.State=="dns_ready"&&restore.Reply.Hostname==a.Reply!.Hostname,"Recovered same key and hostname retains lease");
var writes=dns.Changes;var unsigned=await Request(keyA,"server-a.example.test",tenantA,domainA,"fictional-company",1);var forged=await Send(unsigned with{TenantUuid=Guid.NewGuid()});Check(forged.Http.StatusCode==HttpStatusCode.Forbidden&&dns.Changes==writes,"Signature binds tenant/operation");
var moveDenied=await Send(await Request(keyA,"server-c.example.test",tenantA,domainA,"fictional-company",1));Check(moveDenied.Http.StatusCode==HttpStatusCode.Conflict&&dns.Changes==writes,"Ordinary renewal cannot move host");
var missingMatch=await Send(await Request(keyA,"server-c.example.test",tenantA,domainA,"fictional-company",1,true,true));Check(missingMatch.Http.StatusCode==HttpStatusCode.Conflict,"Explicit move requires If-Match");
var move=await Send(await Request(keyA,"server-c.example.test",tenantA,domainA,"fictional-company",1,true,true),true);Check(move.Reply?.State=="dns_ready"&&move.Reply.Revision==2&&move.Reply.Hostname==a.Reply!.Hostname,"Explicit signed revision move updates only owned CNAME");
var movedAddress=await client.GetFromJsonAsync<TenantAddressReply>("/v1/tenant-addresses/"+a.Reply!.Hostname);
Check(movedAddress!.ServerOrigin=="https://server-c.example.test"&&movedAddress.Revision==2,"Moved lease never returns the stale canonical credential recipient");
var old=await Send(await Request(keyA,"server-a.example.test",tenantA,domainA,"fictional-company",1));Check(old.Http.StatusCode==HttpStatusCode.Conflict,"Old restored/source instance cannot silently move DNS back");
var stale=await Send(await Request(keyA,"server-c.example.test",tenantA,domainA,"fictional-company",1));Check(stale.Http.StatusCode==HttpStatusCode.Conflict,"Stale revision refused");
var lateInitial=await Send(await Request(keyA,"server-c.example.test",tenantA,domainA,"fictional-company"));Check(lateInitial.Http.StatusCode==HttpStatusCode.Conflict,"Initial revision cannot adopt later moved revision");
var badProof=await Request(keyA,"server-c.example.test",tenantA,domainA,"fictional-company",2);proofs[badProof.Challenge]=Encoding.UTF8.GetBytes("wrong owned proof");writes=dns.Changes;var wrong=await Send(badProof);Check(wrong.Http.StatusCode==HttpStatusCode.Forbidden&&dns.Changes==writes,"Actual HTTP nonce proof mismatch precedes DNS");
var expired=await Request(keyA,"server-c.example.test",tenantA,domainA,"fictional-company",2);await using(var c=source.CreateCommand("update registry_challenges set expires_at=now()-interval '1 second' where nonce=$1")){c.Parameters.AddWithValue(expired.Challenge);await c.ExecuteNonQueryAsync();}Check((await Send(expired)).Http.StatusCode==HttpStatusCode.Forbidden,"Expired nonce refused");
var unknown=await client.PostAsJsonAsync("/v1/challenges",new{publicKey=Public(keyA),serverHost="server-c.example.test",unknown="not-exported-secret"});Check(unknown.StatusCode==HttpStatusCode.BadRequest,"Unknown request key refused");Check(!(await unknown.Content.ReadAsStringAsync()).Contains("not-exported-secret"),"Bad request never projects body values");
var owned=a.Reply!.Hostname;dns.Foreign(owned);writes=dns.Changes;var conflict=await Send(await Request(keyA,"server-c.example.test",tenantA,domainA,"fictional-company",2));Check(conflict.Reply?.State=="dns_conflict"&&dns.Changes==writes,"Foreign record replacement refused");
// Actual root-only read-only provider fixture verifies the deployed UAPI shape.
var original=Environment.GetEnvironmentVariable("OPENWEB_REGISTRY_CPANEL_PARSE_FIXTURE");if(!string.IsNullOrEmpty(original)){
 using var j=JsonDocument.Parse(await File.ReadAllBytesAsync(original));var data=j.RootElement.GetProperty("data");var parsed=CpanelDns.Parse(data);
 string Decode(JsonElement value)=>Encoding.ASCII.GetString(Convert.FromBase64String(value.GetString()!));
 var real=data.EnumerateArray().Where(r=>r.GetProperty("type").GetString()=="record").ToArray();
 Check(parsed.Records.Count==real.Length,"Actual cPanel complete record count");
 foreach(var row in real){var rawName=Decode(row.GetProperty("dname_b64"));var name=(rawName.EndsWith('.')?rawName.TrimEnd('.'):rawName+".openwebpbx.com").ToLowerInvariant();var actual=parsed.Records.Single(r=>r.Line==row.GetProperty("line_index").GetInt32());Check(actual.Name==name,"Actual cPanel absolute/relative owner-name decoding");if(actual.Type=="CNAME")Check(actual.Data.SequenceEqual(row.GetProperty("data_b64").EnumerateArray().Select(Decode)),"Actual cPanel CNAME target bytes preserved");if(actual.Type=="SOA")Check(parsed.Serial==long.Parse(Decode(row.GetProperty("data_b64")[2])),"Actual cPanel SOA serial exact");}
}
Check(dns.UnrelatedExact,"All original non-lease DNS records remain exact");
for(int i=0;i<121;i++){using var r=new HttpRequestMessage(HttpMethod.Get,"/health");r.Headers.Add("X-Forwarded-For","203.0.113.99");using var response=await client.SendAsync(r);if(i==120)Check((int)response.StatusCode==429&&response.Headers.RetryAfter?.Delta==TimeSpan.FromSeconds(60),"Trusted loopback forwarded client is capped with retry");}
using(var other=new HttpRequestMessage(HttpMethod.Get,"/health")){other.Headers.Add("X-Forwarded-For","203.0.113.100");using var response=await client.SendAsync(other);Check(response.IsSuccessStatusCode,"Independent forwarded client has independent limiter");}
await broker.StopAsync();await fixture.StopAsync();Console.WriteLine($"PASS {checks} actual signed HTTP/PostgreSQL/CNAME-custody/proof/revision/privacy controls; fictional endpoints only.");

sealed class HttpProof(HttpClient client):ISiteProof{
 public async Task Verify(string host,string nonce,string hash,CancellationToken stop){var actual=await client.GetByteArrayAsync("/.well-known/openwebpbx-instance/"+nonce,stop);if(!actual.SequenceEqual(Protocol.Proof(nonce,hash,host)))throw new Refused("installed_hostname_proof_failed",403);}
}
sealed class DnsFixture{
 readonly Dictionary<string,(string Type,string Value)> rows=new(){["mail.openwebpbx.com"]=("A","203.0.113.10"),["www.openwebpbx.com"]=("CNAME","example.test.")};long serial=1;public int Changes{get;private set;}
 public bool UnrelatedExact=>rows["mail.openwebpbx.com"]==("A","203.0.113.10")&&rows["www.openwebpbx.com"]==("CNAME","example.test.");
 public void Foreign(string name)=>rows[name]=("A","203.0.113.20");
 public Microsoft.AspNetCore.Http.IResult Handle(string operation,Microsoft.AspNetCore.Http.HttpRequest request){
  if(request.Headers.Authorization!="cpanel fictional:not-a-provider-credential"||request.Query["zone"]!="openwebpbx.com")throw new Exception("Provider binding");
  string B(string value)=>Convert.ToBase64String(Encoding.ASCII.GetBytes(value));
  if(operation=="parse_zone")return Microsoft.AspNetCore.Http.Results.Json(new{status=1,data=new[]{new{type="record",record_type="SOA",dname_b64=B("openwebpbx.com."),data_b64=new[]{B("ns.example.test."),B("hostmaster.example.test."),B(serial.ToString()),B("3600"),B("600"),B("86400"),B("300")},line_index=0}}.Cast<object>().Concat(rows.Select((pair,index)=>(object)new{type="record",record_type=pair.Value.Type,dname_b64=B(pair.Key+"."),data_b64=new[]{B(pair.Value.Value)},line_index=index+1})).ToArray(),errors=(object?)null});
  if(operation!="mass_edit_zone")throw new Exception("Unexpected provider function");
  if(!long.TryParse(request.Query["serial"],out var expected)||expected!=serial)return Microsoft.AspNetCore.Http.Results.Json(new{status=0,data=new{},errors=new[]{"fictional serial conflict"}});
  var edit=request.Query.ContainsKey("edit");using var j=JsonDocument.Parse(request.Query[edit?"edit":"add"].ToString());var root=j.RootElement;var name=root.GetProperty("dname").GetString()!.TrimEnd('.');if(!name.EndsWith(".openwebpbx.com")||name is "mail.openwebpbx.com" or "www.openwebpbx.com"||root.GetProperty("record_type").GetString()!="CNAME"||root.GetProperty("ttl").GetInt32()!=300)throw new Exception("Foreign DNS mutation");
  if(edit){var current=rows.ElementAt(root.GetProperty("line_index").GetInt32()-1);if(current.Key!=name)throw new Exception("Wrong DNS line");}else if(rows.ContainsKey(name))throw new Exception("Existing record overwritten");
  rows[name]=("CNAME",root.GetProperty("data")[0].GetString()!);serial++;Changes++;return Microsoft.AspNetCore.Http.Results.Json(new{status=1,data=new{new_serial=serial},errors=(object?)null});
 }
}
