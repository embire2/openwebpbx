// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net;
using System.Text;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using OpenWebPbx.Phone.Core;
var checks = 0;
void Check(bool value) { if (!value) throw new InvalidOperationException($"Control {checks + 1} failed."); checks++; }
void Refuse(Action action) { try { action(); } catch (PhoneInputException) { checks++; return; } throw new InvalidOperationException("Invalid connection accepted."); }
foreach (var value in new[] { "openweb", "OPENWEB", "openweb.openwebpbx.com", "https://openweb.openwebpbx.com", "https://openweb.openwebpbx.com:443/" })
    Check(ConnectionRules.Tenant(value).AbsoluteUri == "https://openweb.openwebpbx.com/");
foreach (var value in new[] { "", "http://openweb.openwebpbx.com", "https://evil.example", "https://openwebpbx.com", "https://nested.openweb.openwebpbx.com", "https://openweb.openwebpbx.com:8443", "https://user:secret@openweb.openwebpbx.com", "https://@openweb.openwebpbx.com", "https://openweb.openwebpbx.com?x", "https://openweb.openwebpbx.com#x", "https://openweb.openwebpbx.com/path", "https://xn--abc.openwebpbx.com", "https://é.openwebpbx.com", "https://openweb.openwebpbx.com\\evil", "https://%6fpenweb.openwebpbx.com" }) Refuse(() => ConnectionRules.Tenant(value));
var setup = Encoding.UTF8.GetBytes("""{"type":"openwebpbx","version":1,"server":"https://openweb.openwebpbx.com","code":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","extension":"1000"}""");
var invitation = SetupInvitation.Parse(setup); Check(invitation.Extension == "1000"); Check(invitation.Code.Length == 64);
foreach (var key in new[] { "password", "sip", "token", "unknown" }) Refuse(() => SetupInvitation.Parse(Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(setup).Replace("\"version\":1", $"\"version\":1,\"{key}\":\"private\""))));
foreach (var replacement in new[] { "\"version\":1,\"version\":1", "\"version\":2", "\"version\":\"1\"" }) Refuse(() => SetupInvitation.Parse(Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(setup).Replace("\"version\":1", replacement))));
Refuse(() => SetupInvitation.Parse(new byte[16385]));
Check(SetupInvitation.FromUri(new Uri("openwebpbx://setup?server=https%3A%2F%2Fopenweb.openwebpbx.com&code=aaaaaaaaaaaaaaaa&extension=1000")).Extension == "1000");
foreach (var query in new[] { "server=x&code=aaaaaaaaaaaaaaaa&password=secret", "server=x&server=y&code=aaaaaaaaaaaaaaaa", "server=x", "code=aaaaaaaaaaaaaaaa" }) Refuse(() => SetupInvitation.FromUri(new Uri("openwebpbx://setup?" + query)));
Check(ConnectionRules.Number("+27 (87) 350-8601") == "+27873508601"); Check(ConnectionRules.Number("*70#") == "*70#");
foreach (var value in new[] { "sip:user@example.invalid", "123;transport=udp", "123\r\nHeader: value", new string('1', 33) }) Refuse(() => ConnectionRules.Number(value));
ConnectionRules.AppPassword(new string('a', 12)); Check(true); ConnectionRules.AppPassword(string.Concat(Enumerable.Repeat("😀", 12))); Check(true);
foreach (var value in new[] { "short", new string('a', 129), new string('a', 12) + '\ud800' }) Refuse(() => ConnectionRules.AppPassword(value));
Refuse(() => ConnectionRules.RequireIdle(1)); Refuse(() => ConnectionRules.RequireIdle(0, true)); ConnectionRules.RequireIdle(0); Check(true);
var requests = new List<HttpRequestMessage>();
using (var api = new PhoneApi(invitation.Server, new string('a', 64), new Handler(request => { requests.Add(request); return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"ok\":true}") }; })))
{
    Check((await api.JsonAsync("bootstrap"))["ok"]!.GetValue<bool>());
    Check(requests.Single().RequestUri!.Host == "openweb.openwebpbx.com");
    Check(requests.Single().Headers.Authorization!.Scheme == "Bearer");
    Check(requests.Single().Headers.UserAgent.ToString() == "OpenWebPBX-WindowsPhone/1.0.0");
}
using (var api = new PhoneApi(invitation.Server, handler: new Handler(_ => new HttpResponseMessage(HttpStatusCode.Redirect) { Headers = { Location = new Uri("https://other.example") } })))
{
    try { await api.JsonAsync("bootstrap"); throw new Exception("Redirect accepted."); } catch (PhoneApiException error) { Check(error.Status == HttpStatusCode.Redirect); }
}
using (var api = new PhoneApi(invitation.Server, handler: new Handler(_ => new HttpResponseMessage(HttpStatusCode.Forbidden) { Content = new StringContent("PRIVATE_DATABASE_ERROR_TOKEN") })))
{
    try { await api.JsonAsync("bootstrap"); throw new Exception("Forbidden accepted."); } catch (PhoneApiException error) { Check(!error.Message.Contains("PRIVATE")); }
}
var store = new MemoryStore(); var calls = 0;
var manager = new ProfileManager(store, () => calls, () => false);
PhoneProfile Invented(int number) => new(Guid.NewGuid(), invitation.Server, new string('a', 64), Guid.NewGuid(),
    new SipAccount("call.example.invalid", "invented.example.invalid", "owm-test", "owm-test", "PRIVATE_SIP_PASSWORD", 5061),
    new AccountIdentity(Guid.Parse("11111111-1111-1111-1111-111111111111"), Guid.NewGuid(), number.ToString(), "Invented", "Test"), []);
var first = Invented(1000); await manager.AddAsync(first); Check(store.Values.Count == 1); Check(store.Selected == first.Id);
Check(!first.ToString().Contains("PRIVATE") && !first.Sip.ToString().Contains("PRIVATE") && !invitation.ToString().Contains(invitation.Code));
try { await manager.AddAsync(first with { Id = Guid.NewGuid(), DeviceId = Guid.NewGuid() }); throw new Exception("Duplicate accepted."); } catch (PhoneInputException) { Check(store.Values.Count == 1); }
var additions = Enumerable.Range(1001, 10).Select(async number => { try { await manager.AddAsync(Invented(number)); return true; } catch (PhoneInputException) { return false; } });
var added = await Task.WhenAll(additions); Check(added.Count(x => x) == 9); Check(store.Values.Count == 10);
await manager.RenameAsync(first.Id, "My first tenant"); Check(store.Values.First().Name == "My first tenant"); Check(store.Values.First().Sip == first.Sip);
calls = 1;
try { await manager.RemoveAsync(first.Id); throw new Exception("Active profile removed."); } catch (PhoneInputException) { Check(store.Values.Count == 10); }
calls = 0; await manager.RemoveAsync(first.Id); Check(store.Values.Count == 9 && store.Selected == store.Values.First().Id);
store.OnRead = () => calls = 1;
try { await manager.SelectAsync(store.Values.Last().Id); throw new Exception("Concurrent incoming call ignored."); } catch (PhoneInputException) { Check(store.Selected == store.Values.First().Id); }
var registryProof = """{"schema":1,"hostname":"openweb.openwebpbx.com","revision":1,"domainUuid":"11111111-1111-1111-1111-111111111111","serverOrigin":"https://call.example.invalid"}""";
using (var registry = new TenantRegistry(new Handler(request => { Check(request.RequestUri!.Host == "domains.openwebpbx.com"); Check(request.Headers.Authorization is null); return new(HttpStatusCode.OK) { Content = new StringContent(registryProof) }; })))
    Check((await registry.LookupAsync(invitation.Server)).DomainId == Guid.Parse("11111111-1111-1111-1111-111111111111"));
foreach (var invalid in new[] { registryProof.Replace("openweb.openwebpbx.com", "another.openwebpbx.com"), registryProof.Replace("\"revision\":1", "\"revision\":0"), registryProof.Replace("11111111-1111-1111-1111-111111111111", Guid.Empty.ToString()), registryProof.Replace("https://call.example.invalid", "http://call.example.invalid"), new string('x', 4097) })
{
    using var registry = new TenantRegistry(new Handler(_ => new(HttpStatusCode.OK) { Content = new StringContent(invalid) }));
    try { await registry.LookupAsync(invitation.Server); throw new Exception("Invalid custody proof accepted."); } catch (PhoneInputException) { Check(true); }
}
using (var registry = new TenantRegistry(new Handler(_ => new(HttpStatusCode.Redirect) { Headers = { Location = new Uri("https://evil.invalid") } })))
    try { await registry.LookupAsync(invitation.Server); throw new Exception("Custody redirect accepted."); } catch (PhoneInputException) { Check(true); }
foreach (var registryMode in new[] { false, true })
{
    var stalled = new StalledBody(); var handler = new Handler(_ => new(HttpStatusCode.OK) { Content = new StreamContent(stalled) });
    var started = System.Diagnostics.Stopwatch.StartNew();
    try
    {
        if (registryMode) { using var registry = new TenantRegistry(handler, TimeSpan.FromMilliseconds(80)); await registry.LookupAsync(invitation.Server); }
        else { using var api = new PhoneApi(invitation.Server, handler: handler, requestDeadline: TimeSpan.FromMilliseconds(80)); await api.JsonAsync("bootstrap"); }
        throw new Exception("A stalled response escaped the body deadline.");
    }
    catch (OperationCanceledException) { Check(started.Elapsed < TimeSpan.FromSeconds(2)); Check(stalled.Closed); }
}
Check(new PersonalPreferences().Validated().Theme == "System");
foreach (var bad in new[] { new PersonalPreferences { Theme = "Unsafe" }, new PersonalPreferences { StartupPage = "Provider" }, new PersonalPreferences { ContactOrder = "Unknown" }, new PersonalPreferences { Microphone = "bad\nname" }, new PersonalPreferences { Ringtone = new string('x', 2049) } }) Refuse(() => bad.Validated());
using (var key = RSA.Create(3072))
{
    var payload = new JsonObject { ["schema"] = 1, ["purpose"] = "windows-phone-release", ["published_at"] = DateTimeOffset.UtcNow.AddMinutes(-1).ToString("yyyy-MM-ddTHH:mm:ssZ"), ["expires_at"] = DateTimeOffset.UtcNow.AddDays(180).ToString("yyyy-MM-ddTHH:mm:ssZ"), ["component"] = "windows-free-phone", ["platform"] = "windows-x64", ["channel"] = "stable", ["version"] = "1.0.1", ["sequence"] = 2, ["package"] = new JsonObject { ["url"] = "https://github.com/embire2/openwebpbx/releases/download/windows-phone-v1.0.1/OpenWebPBX-Free-Phone-1.0.1-win-x64.msixbundle", ["bytes"] = 4096, ["sha256"] = new string('a', 64), ["identity"] = "OpenWebPBX.FreePhone", ["publisher"] = "CN=Open ISP cc" } };
    byte[] Signed(JsonObject item) { var data = Encoding.UTF8.GetBytes(item.ToJsonString()); return Encoding.UTF8.GetBytes(new JsonObject { ["algorithm"] = "rsa-sha256", ["key_id"] = "windows-phone-release-1", ["payload"] = Convert.ToBase64String(data), ["signature"] = Convert.ToBase64String(key.SignData(data, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)) }.ToJsonString()); }
    var envelope = Signed(payload); Check(ClientRelease.Verify(envelope, key, 1, "OpenWebPBX.FreePhone", "CN=Open ISP cc").Sequence == 2); Refuse(() => ClientRelease.Verify(envelope, key, 3, "OpenWebPBX.FreePhone", "CN=Open ISP cc"));
    foreach (var name in new[] { "purpose", "component", "platform", "channel", "version" }) { var changed = (JsonObject)payload.DeepClone(); changed[name] = "wrong"; Refuse(() => ClientRelease.Verify(Signed(changed), key, 1, "OpenWebPBX.FreePhone", "CN=Open ISP cc")); }
    foreach (var name in new[] { "url", "identity", "sha256", "publisher" }) { var changed = (JsonObject)payload.DeepClone(); changed["package"]![name] = "wrong"; Refuse(() => ClientRelease.Verify(Signed(changed), key, 1, "OpenWebPBX.FreePhone", "CN=Open ISP cc")); }
    foreach (var timestamp in new[] { ("published_at", DateTimeOffset.UtcNow.AddMinutes(6).ToString("yyyy-MM-ddTHH:mm:ssZ")), ("expires_at", DateTimeOffset.UtcNow.AddSeconds(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")), ("expires_at", DateTimeOffset.UtcNow.AddDays(367).ToString("yyyy-MM-ddTHH:mm:ssZ")), ("expires_at", "2027-10-23T00:00:00+00:00") }) { var changed = (JsonObject)payload.DeepClone(); changed[timestamp.Item1] = timestamp.Item2; Refuse(() => ClientRelease.Verify(Signed(changed), key, 1, "OpenWebPBX.FreePhone", "CN=Open ISP cc")); }
    Refuse(() => ClientRelease.Verify(envelope, key, 2, "OpenWebPBX.FreePhone", "CN=Open ISP cc", new string('f',64)));
    using var stranger = RSA.Create(3072); Refuse(() => ClientRelease.Verify(envelope, stranger, 1, "OpenWebPBX.FreePhone", "CN=Open ISP cc"));
    var policy = new JsonObject { ["schema"] = 1, ["component"] = "windows-free-phone", ["channel"] = "stable", ["mode"] = "required", ["tenant_mode"] = "required", ["required_by_instance"] = false, ["minimum_version"] = "", ["latest_version"] = "", ["feed_url"] = "https://github.com/embire2/openwebpbx/releases/download/windows-phone-stable/windows-phone-update-manifest.json", ["release_available"] = false };
    Check(!WindowsPhonePolicy.Parse(policy).Requires(new Version(1,0,0))); policy["latest_version"] = "1.0.1"; Refuse(() => WindowsPhonePolicy.Parse(policy)); policy["release_available"] = true; Check(WindowsPhonePolicy.Parse(policy).Requires(new Version(1,0,0))); Check(!WindowsPhonePolicy.Parse(policy).Requires(new Version(1,0,1)));
    policy["minimum_version"] = "1.0.2"; Refuse(() => WindowsPhonePolicy.Parse(policy));
}
using (var input = new MemoryStream(setup)) Check((await SetupInvitation.ReadAsync(input)).Extension == "1000");
var openedFile = Path.Combine(Path.GetTempPath(), "phone-invitation-" + Guid.NewGuid().ToString("N") + ".openwebpbx");
try
{
    await File.WriteAllBytesAsync(openedFile, setup); await using (var input = File.OpenRead(openedFile)) Check((await SetupInvitation.ReadAsync(input)).Code == invitation.Code);
    await File.WriteAllBytesAsync(openedFile, new byte[ConnectionRules.MaximumSetupBytes + 1]);
    try { await using var input = File.OpenRead(openedFile); await SetupInvitation.ReadAsync(input); throw new Exception("Oversized opened file accepted."); } catch (PhoneInputException) { Check(true); }
    await File.WriteAllBytesAsync(openedFile, setup);
    await using var underlying = new FileStream(openedFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096, FileOptions.Asynchronous);
    using var growing = new GrowingFile(underlying, () => File.AppendAllText(openedFile, new string(' ', 20000)));
    try { await SetupInvitation.ReadAsync(growing); throw new Exception("Growing opened file accepted."); } catch (PhoneInputException) { Check(growing.BytesRead == ConnectionRules.MaximumSetupBytes + 1); }
}
finally { File.Delete(openedFile); }
using (var stalled = new StalledBody()) using (var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(80)))
    try { await SetupInvitation.ReadAsync(stalled, cancel.Token); throw new Exception("Stalled invitation read accepted."); } catch (OperationCanceledException) { Check(true); }
CallingRules.Stable(false); Check(true); Refuse(() => CallingRules.Stable(true));
CallingRules.Video(true, true, 1, false); Check(true); CallingRules.Video(true, true, 0, false, true); Check(true);
Refuse(() => CallingRules.Video(false, true, 1, false)); Refuse(() => CallingRules.Video(true, false, 1, false)); Refuse(() => CallingRules.Video(true, true, 2, false)); Refuse(() => CallingRules.Video(true, true, 1, true)); Refuse(() => CallingRules.Video(true, true, 1, false, true));
var runtimeRoot = Path.Combine(Path.GetTempPath(), "phone-resources-" + Guid.NewGuid().ToString("N"));
try
{
    Directory.CreateDirectory(Path.Combine(runtimeRoot, "belr", "grammars")); var resourcePath = Path.Combine(runtimeRoot, "belr", "grammars", "invented.belr"); await File.WriteAllTextAsync(resourcePath, "invented fixture");
    var resourceBytes = await File.ReadAllBytesAsync(resourcePath); var resource = new RuntimeResource("belr/grammars/invented.belr", resourceBytes.Length, Convert.ToHexString(SHA256.HashData(resourceBytes)).ToLowerInvariant());
    RuntimeResources.Verify(runtimeRoot, [resource]); Check(true); Refuse(() => RuntimeResources.Verify(runtimeRoot, [resource, resource]));
    Refuse(() => RuntimeResources.Verify(runtimeRoot, [resource with { Path = "../invented.belr" }])); Refuse(() => RuntimeResources.Verify(runtimeRoot, [resource with { Bytes = resource.Bytes + 1 }])); Refuse(() => RuntimeResources.Verify(runtimeRoot, [resource with { Sha256 = new string('a', 64) }]));
    File.Delete(resourcePath); Refuse(() => RuntimeResources.Verify(runtimeRoot, [resource])); Directory.CreateDirectory(resourcePath); Refuse(() => RuntimeResources.Verify(runtimeRoot, [resource])); Directory.Delete(resourcePath);
    if (!OperatingSystem.IsWindows()) { File.CreateSymbolicLink(resourcePath, "/etc/hosts"); Refuse(() => RuntimeResources.Verify(runtimeRoot, [resource])); File.Delete(resourcePath); }
}
finally { Directory.Delete(runtimeRoot, true); }
store.OnRead = null; calls = 1; var metadataProfile = store.Values.First();
await manager.UpdateAccountAsync(metadataProfile.Id, metadataProfile.Account with { AppPasswordSet = true, CanInitializeAppPassword = false }); Check(store.Values.First().Sip == metadataProfile.Sip); Check(store.Values.First().Token == metadataProfile.Token);
try { await manager.UpdateAccountAsync(metadataProfile.Id, metadataProfile.Account with { DomainId = Guid.NewGuid() }); throw new Exception("Foreign account metadata accepted."); } catch (PhoneInputException) { Check(true); }
using (var productionPublic = ClientUpdateTrust.Open()) { Check(productionPublic.KeySize == 3072); Check(Convert.ToHexString(SHA256.HashData(productionPublic.ExportSubjectPublicKeyInfo())).ToLowerInvariant() == ClientUpdateTrust.PublicSpkiSha256); }
Console.WriteLine($"PASS {checks} client domain/API controls; HTTP handlers are explicit doubles; no Windows/native-call qualification");
sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(respond(request));
}

sealed class MemoryStore : IProfileStore
{
    public IReadOnlyList<PhoneProfile> Values { get; private set; } = [];
    public Guid? Selected { get; private set; }
    public Action? OnRead { get; set; }
    public Task<IReadOnlyList<PhoneProfile>> ReadAsync(CancellationToken cancellation = default) { OnRead?.Invoke(); return Task.FromResult(Values); }
    public Task<Guid?> SelectedAsync(CancellationToken cancellation = default) => Task.FromResult(Selected);
    public Task SaveAsync(IReadOnlyList<PhoneProfile> profiles, Guid? selected, CancellationToken cancellation = default) { Values = profiles.ToArray(); Selected = selected; return Task.CompletedTask; }
}

sealed class StalledBody : Stream
{
    public bool Closed { get; private set; }
    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) { await Task.Delay(Timeout.Infinite, cancellationToken); return 0; }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { Closed = true; base.Dispose(disposing); }
    public override void Flush() => throw new NotSupportedException(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}

sealed class GrowingFile(Stream source, Action grow) : Stream
{
    public int BytesRead { get; private set; } private bool grown;
    public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) { var count = await source.ReadAsync(buffer, cancellationToken); BytesRead += count; if (!grown) { grown = true; grow(); } return count; }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException(); public override void Flush() => throw new NotSupportedException(); public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long value) => throw new NotSupportedException(); public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
