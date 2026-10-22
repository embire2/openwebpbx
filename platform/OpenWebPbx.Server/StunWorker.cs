// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace OpenWebPbx.Server;

// A small public Binding service, not a TURN relay. It never accepts a reply
// address from a packet, opens another socket on demand, or records endpoints.
internal static class StunBinding
{
    internal const uint Cookie = 0x2112a442;
    internal static byte[]? Reply(ReadOnlySpan<byte> packet, IPEndPoint sender)
    {
        if (packet.Length < 20 || packet.Length > 1200 || packet[0] != 0 || packet[1] != 1
            || sender.Port == 0 || sender.Address.IsIPv6Multicast
            || sender.Address.Equals(IPAddress.Any) || sender.Address.Equals(IPAddress.IPv6Any)) return null;
        var length = BinaryPrimitives.ReadUInt16BigEndian(packet[2..]);
        if ((length & 3) != 0 || length != packet.Length - 20) return null;
        bool modern = BinaryPrimitives.ReadUInt32BigEndian(packet[4..]) == Cookie;
        bool fingerprint = false;
        for (int at = 20; at < packet.Length;)
        {
            if (at + 4 > packet.Length) return null;
            int type = BinaryPrimitives.ReadUInt16BigEndian(packet[at..]);
            int size = BinaryPrimitives.ReadUInt16BigEndian(packet[(at + 2)..]);
            int end = at + 4 + ((size + 3) & ~3);
            if (end > packet.Length) return null;
            // No RESPONSE-ADDRESS, CHANGE-REQUEST, integrity/authentication or
            // unknown mandatory extensions: unsupported requests fail closed.
            if (type == 0x8028)
            {
                if (!modern || size != 4 || end != packet.Length || fingerprint
                    || BinaryPrimitives.ReadUInt32BigEndian(packet[(at + 4)..]) != (Crc32(packet[..at]) ^ 0x5354554e)) return null;
                fingerprint = true;
            }
            else if (!modern && type == 3 && size == 4 && BinaryPrimitives.ReadUInt32BigEndian(packet[(at + 4)..]) == 0) { }
            else if (type < 0x8000 && type != 0x0006) return null;
            at = end;
        }
        var address = sender.Address.IsIPv4MappedToIPv6 ? sender.Address.MapToIPv4() : sender.Address;
        var bytes = address.GetAddressBytes();
        if (bytes.Length != 4 && bytes.Length != 16) return null;
        if (!modern && bytes.Length != 4) return null; // RFC3489 is IPv4 only.
        int valueLength = 4 + bytes.Length;
        // Return MAPPED-ADDRESS too for old desk phones; modern clients use XOR.
        int total = 20 + 4 + valueLength + (modern ? 4 + valueLength : 0) + (fingerprint ? 8 : 0);
        var result = new byte[total];
        result[0] = 1; result[1] = 1;
        BinaryPrimitives.WriteUInt16BigEndian(result.AsSpan(2), (ushort)(total - 20));
        packet.Slice(4, 16).CopyTo(result.AsSpan(4));
        int offset = 20;
        void AddressAttribute(ushort type, bool xor)
        {
            BinaryPrimitives.WriteUInt16BigEndian(result.AsSpan(offset), type);
            BinaryPrimitives.WriteUInt16BigEndian(result.AsSpan(offset + 2), (ushort)valueLength);
            result[offset + 5] = (byte)(bytes.Length == 4 ? 1 : 2);
            BinaryPrimitives.WriteUInt16BigEndian(result.AsSpan(offset + 6), (ushort)(sender.Port ^ (xor ? Cookie >> 16 : 0)));
            for (int i = 0; i < bytes.Length; i++) result[offset + 8 + i] = (byte)(bytes[i] ^ (xor ? result[4 + i] : 0));
            offset += 4 + valueLength;
        }
        AddressAttribute(1, false);
        if (modern) AddressAttribute(0x20, true);
        if (fingerprint)
        {
            BinaryPrimitives.WriteUInt16BigEndian(result.AsSpan(offset), 0x8028);
            BinaryPrimitives.WriteUInt16BigEndian(result.AsSpan(offset + 2), 4);
            BinaryPrimitives.WriteUInt32BigEndian(result.AsSpan(offset + 4), Crc32(result.AsSpan(0, offset)) ^ 0x5354554e);
        }
        return result;
    }
    internal static uint Crc32(ReadOnlySpan<byte> bytes)
    {
        uint crc = uint.MaxValue;
        foreach (byte value in bytes)
        {
            crc ^= value;
            for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0u : 0xedb88320u);
        }
        return ~crc;
    }
}

internal sealed class StunStatus
{
    public string State { get; internal set; } = "Disabled";
}

internal sealed class StunWorker(IConfiguration configuration, StunStatus status, ILogger<StunWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var sockets = new List<UdpClient>();
        try
        {
            IConfiguration settings = configuration;
            if (OperatingSystem.IsWindows())
            {
                var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "stun.json");
                if (File.Exists(path)) settings = new ConfigurationBuilder().AddJsonFile(path, optional: false, reloadOnChange: false).Build();
            }
            if (!settings.GetValue<bool>("Stun:Enabled")) return;
            status.State = "Starting";
            var values = settings.GetSection("Stun:ListenAddresses").Get<string[]>() ?? [];
            if (values.Length == 0 || values.Length > 16) throw new InvalidOperationException("STUN requires explicit local listening addresses.");
            var local = System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .SelectMany(x => x.GetIPProperties().UnicastAddresses).Select(x => x.Address).ToHashSet();
            var addresses = values.Select(IPAddress.Parse).ToArray();
            if (addresses.Distinct().Count() != addresses.Length || addresses.Any(a => !local.Contains(a) || IPAddress.IsLoopback(a)
                || a.Equals(IPAddress.Any) || a.Equals(IPAddress.IPv6Any) || a.IsIPv6Multicast || a.IsIPv4MappedToIPv6))
                throw new InvalidOperationException("STUN must bind installed, unique, non-loopback unicast addresses.");
            foreach (var address in addresses)
            {
                var socket = new UdpClient(address.AddressFamily);
                sockets.Add(socket);
                socket.Client.ExclusiveAddressUse = true;
                if (address.AddressFamily == AddressFamily.InterNetworkV6) socket.Client.DualMode = false;
                socket.Client.Bind(new IPEndPoint(address, 3478));
            }
            status.State = "Running";
            logger.LogInformation("STUN Binding service listening on {Count} local addresses, UDP3478.", sockets.Count);
            await Task.WhenAll(sockets.Select(socket => Serve(socket, stoppingToken)));
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
        catch (Exception error)
        {
            // A failed optional NAT helper must not stop ordinary PBX calls.
            status.State = "Unavailable";
            logger.LogError("STUN Binding service unavailable ({ErrorType}); PBX calling continues.", error.GetType().Name);
        }
        finally { foreach (var socket in sockets) socket.Dispose(); }
    }
    internal static async Task Serve(UdpClient socket, CancellationToken stop)
    {
        // Bounded per-listener rate/memory. No user-address list or payload log.
        long window = Environment.TickCount64;
        int used = 0;
        while (!stop.IsCancellationRequested)
        {
            UdpReceiveResult request;
            try { request = await socket.ReceiveAsync(stop); }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
            catch (SocketException) when (!stop.IsCancellationRequested) { await Task.Delay(20, stop); continue; }
            long now = Environment.TickCount64;
            if (now - window >= 1000) { window = now; used = 0; }
            if (++used > 200) continue;
            var reply = StunBinding.Reply(request.Buffer, request.RemoteEndPoint);
            if (reply is null) continue;
            try { await socket.SendAsync(reply, request.RemoteEndPoint, stop); }
            catch (SocketException) { /* An unreachable peer must not stop other phones. */ }
        }
    }
}
