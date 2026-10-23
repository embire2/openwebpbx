// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net;
using System.Text;
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
