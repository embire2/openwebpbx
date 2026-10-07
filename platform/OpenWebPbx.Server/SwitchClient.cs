using System.Net.Sockets;
using System.Text;

namespace OpenWebPbx.Server;

// One connection per command: bounded frames, no shared reader, no interleaved replies.
public sealed class SwitchClient(IConfiguration configuration)
{
    public async Task<string> Execute(string command, CancellationToken cancellationToken)
    {
        if (command.Contains('\n') || command.Contains('\r')) throw new ArgumentException("Invalid command.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(8));
        var ct = deadline.Token;
        using var client = new TcpClient();
        await client.ConnectAsync(configuration["Switch:Host"] ?? "127.0.0.1", configuration.GetValue("Switch:Port", 8021), ct);
        using var stream = client.GetStream();
        var greeting = await ReadFrame(stream, ct);
        if (greeting.GetValueOrDefault("Content-Type") != "auth/request") throw new IOException("Call engine authentication unavailable.");
        var password = configuration["Switch:Password"] ?? throw new InvalidOperationException("Call engine password is required.");
        if (password.IndexOfAny(['\r', '\n']) >= 0) throw new InvalidOperationException("Invalid call engine password.");
        await stream.WriteAsync(Encoding.UTF8.GetBytes($"auth {password}\n\n"), ct);
        var auth = await ReadFrame(stream, ct);
        if (!auth.GetValueOrDefault("Reply-Text", "").StartsWith("+OK", StringComparison.Ordinal)) throw new IOException("Call engine authentication failed.");
        await stream.WriteAsync(Encoding.UTF8.GetBytes($"api {command}\n\n"), ct);
        var reply = await ReadFrame(stream, ct);
        return reply.GetValueOrDefault("Body", reply.GetValueOrDefault("Reply-Text", ""));
    }

    internal static async Task<Dictionary<string, string>> ReadFrame(Stream stream, CancellationToken ct)
    {
        var header = new List<byte>(); var one = new byte[1];
        while (header.Count < 16384)
        {
            if (await stream.ReadAsync(one, ct) == 0) throw new EndOfStreamException();
            header.Add(one[0]);
            if (header.Count >= 2 && header[^1] == 10 && header[^2] == 10) break;
        }
        if (header.Count >= 16384) throw new IOException("Call engine header exceeds limit.");
        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in Encoding.UTF8.GetString(header.ToArray()).Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var p = line.IndexOf(':'); if (p > 0) fields[line[..p]] = line[(p + 1)..].Trim();
        }
        if (fields.TryGetValue("Content-Length", out var length))
        {
            if (!int.TryParse(length, out var n) || n < 0 || n > 1024 * 1024) throw new IOException("Invalid call engine frame length.");
            var body = new byte[n]; await stream.ReadExactlyAsync(body, ct); fields["Body"] = Encoding.UTF8.GetString(body);
        }
        return fields;
    }
}
