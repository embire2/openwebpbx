// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using OpenWebPbx.Server;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;

if (OperatingSystem.IsWindows() && File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "stun.json")))
    throw new InvalidOperationException("Run these component checks on a clean test workspace before enabling installed STUN.");
int checks = 0;
void Check(bool pass, string name) { if (!pass) throw new Exception(name); checks++; }
byte[] Request(bool modern = true, byte[]? attributes = null)
{
    attributes ??= [];
    var p = new byte[20 + attributes.Length]; p[1] = 1;
    BinaryPrimitives.WriteUInt16BigEndian(p.AsSpan(2), (ushort)attributes.Length);
    for (int i = 4; i < 20; i++) p[i] = (byte)(i * 7);
    if (modern) BinaryPrimitives.WriteUInt32BigEndian(p.AsSpan(4), StunBinding.Cookie);
    attributes.CopyTo(p, 20); return p;
}
var v4 = new IPEndPoint(IPAddress.Parse("203.0.113.17"), 54321);
var request = Request();
var response = StunBinding.Reply(request, v4)!;
Check(response.Length == 44 && response[0] == 1 && response[1] == 1 && response[3] == 24, "IPv4 response header");
Check(request.AsSpan(4,16).SequenceEqual(response.AsSpan(4,16)), "Exact transaction correlation");
Check(response.AsSpan(20,12).SequenceEqual(Convert.FromHexString("000100080001D431CB007111")), "Independent mapped IPv4 wire value");
Check(response.AsSpan(32,12).SequenceEqual(Convert.FromHexString("002000080001F523EA12D553")), "Independent XOR IPv4 wire value");
var v6 = new IPEndPoint(IPAddress.Parse("2001:db8:1234:5678:90ab:cdef:1020:3040"), 34789);
response = StunBinding.Reply(request, v6)!;
Check(response.Length == 68 && response[25] == 2 && response[49] == 2, "IPv6 family/header");
var decoded = response.AsSpan(52,16).ToArray();
for (int i=0;i<16;i++) decoded[i]^=request[4+i];
Check(new IPAddress(decoded).Equals(v6.Address), "All 128 XOR IPv6 bits");
Check((BinaryPrimitives.ReadUInt16BigEndian(response.AsSpan(50)) ^ 0x2112) == v6.Port, "XOR IPv6 port");
var old = Request(false); response = StunBinding.Reply(old,v4)!;
Check(response.Length==32 && old.AsSpan(4,16).SequenceEqual(response.AsSpan(4,16)), "Legacy RFC3489 IPv4 transaction");
Check(StunBinding.Reply(old,v6) is null, "Legacy IPv6 refused");
Check(StunBinding.Reply(Request(false,Convert.FromHexString("0003000400000000")),v4) is not null, "Legacy no-change binding");
Check(StunBinding.Reply(Request(false,Convert.FromHexString("0003000400000002")),v4) is null, "No change-address socket/reflection");
foreach(var hex in new[]{"0002000800011234CB007111","0008000000000000","0003000400000000","0024000400000001","00010004DEADBEEF"})
    Check(StunBinding.Reply(Request(true,Convert.FromHexString(hex)),v4) is null,"Unsupported mandatory/address/auth attribute");
foreach(var type in new byte[]{3,0x11,0x81}) {var p=Request();p[1]=type;Check(StunBinding.Reply(p,v4) is null,"TURN/indications/responses ignored");}
foreach(int size in new[]{0,1,19,21,23,1201,65000}) Check(StunBinding.Reply(new byte[size],v4) is null,"Malformed size ignored");
var bad=Request();bad[3]=4;Check(StunBinding.Reply(bad,v4) is null,"Truncated declared length");
Check(StunBinding.Reply(Request(true,Convert.FromHexString("8022000541424344")),v4) is null,"Truncated attribute");
var padded=Request(true,Convert.FromHexString("8022000141000000"));Check(StunBinding.Reply(padded,v4) is not null,"Padded optional attribute accepted");
// Independent standard CRC check, followed by valid and tampered fingerprints.
Check(StunBinding.Crc32("123456789"u8)==0xcbf43926,"IEEE CRC32 known answer");
var fp=Request(true,Convert.FromHexString("8028000400000000"));
BinaryPrimitives.WriteUInt32BigEndian(fp.AsSpan(24),StunBinding.Crc32(fp.AsSpan(0,20))^0x5354554e);
response=StunBinding.Reply(fp,v4)!;
Check(response.Length==52 && BinaryPrimitives.ReadUInt32BigEndian(response.AsSpan(48))==(StunBinding.Crc32(response.AsSpan(0,44))^0x5354554e),"Validated request and response fingerprints");
fp[27]^=1;Check(StunBinding.Reply(fp,v4) is null,"Bad fingerprint refused");
var random=new Random(712);
for(int i=0;i<20000;i++){var bytes=new byte[random.Next(0,1300)];random.NextBytes(bytes);Check(StunBinding.Reply(bytes,v4) is null,"Random non-request datagram");}
// Real independent UDP client checks source/transaction and a malformed packet
// followed by a legitimate request. Cancellation must stop an idle listener.
foreach(var address in new[]{IPAddress.Loopback,IPAddress.IPv6Loopback})
{
    using var server=new UdpClient(new IPEndPoint(address,0));using var stop=new CancellationTokenSource();
    var serving=StunWorker.Serve(server,stop.Token);
    using var client=new UdpClient(new IPEndPoint(address,0));
    var endpoint=(IPEndPoint)server.Client.LocalEndPoint!;
    await client.SendAsync(new byte[]{1,2,3},endpoint);
    await client.SendAsync(request,endpoint);
    using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(2));
    var got=await client.ReceiveAsync(deadline.Token);
    Check(got.RemoteEndPoint.Equals(endpoint),"Response from the contacted listener");
    Check(got.Buffer.AsSpan(4,16).SequenceEqual(request.AsSpan(4,16)),"Real UDP transaction");
    var local=(IPEndPoint)client.Client.LocalEndPoint!;
    Check(BinaryPrimitives.ReadUInt16BigEndian(got.Buffer.AsSpan(26))==local.Port,"Observed source port");
    Check(new IPAddress(got.Buffer.AsSpan(28,address.AddressFamily==AddressFamily.InterNetwork?4:16)).Equals(address),"Observed source address");
    stop.Cancel();await serving.WaitAsync(TimeSpan.FromSeconds(2));checks++;
}
// Optional STUN failures must remain isolated from ordinary background calling.
// These cases refuse before binding any actual port3478 listener on this host.
foreach(var values in new Dictionary<string,string?>[]{
    new(){["Stun:Enabled"]="true"},
    new(){["Stun:Enabled"]="true",["Stun:ListenAddresses:0"]="0.0.0.0"},
    new(){["Stun:Enabled"]="true",["Stun:ListenAddresses:0"]="127.0.0.1"},
    new(){["Stun:Enabled"]="true",["Stun:ListenAddresses:0"]="203.0.113.250"},
    new(){["Stun:Enabled"]="true",["Stun:ListenAddresses:0"]="not-an-address"},
    new(){["Stun:Enabled"]="invalid"}})
{
    var status=new StunStatus();
    using var worker=new StunWorker(new ConfigurationBuilder().AddInMemoryCollection(values).Build(),status,NullLogger<StunWorker>.Instance);
    await worker.StartAsync(default);
    await (worker.ExecuteTask ?? Task.CompletedTask).WaitAsync(TimeSpan.FromSeconds(2));
    Check(status.State=="Unavailable","Auxiliary configuration failure does not fault or terminate host");
}
var disabled=new StunStatus();
using(var worker=new StunWorker(new ConfigurationBuilder().Build(),disabled,NullLogger<StunWorker>.Instance))
{
    await worker.StartAsync(default);await (worker.ExecuteTask??Task.CompletedTask);
    Check(disabled.State=="Disabled","Existing configurations keep STUN disabled");
}
Console.WriteLine($"PASS: {checks} STUN protocol, malformed-input and real IPv4/IPv6 UDP checks.");
