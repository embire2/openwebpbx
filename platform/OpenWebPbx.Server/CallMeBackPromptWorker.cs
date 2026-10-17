using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using Npgsql;

namespace OpenWebPbx.Server;

/// <summary>Independent bounded voice queue; a slow provider never delays callback dispatch.</summary>
public sealed class CallMeBackPromptWorker(NpgsqlDataSource data, IHttpClientFactory clients,
    IConfiguration settings, ILogger<CallMeBackPromptWorker> log) : BackgroundService
{
    internal const string Voice = "7S3KNdLDL7aRgBVRQb1z";
    internal static string Greeting(string tenant) => $"Hello, this is {tenant} calling you back. You may now authenticate by entering your South African ID Number and press hash.";
    internal string PromptRoot => settings["CallMeBack:PromptRoot"] ?? (OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "storage", "openwebpbx", "call-me-back")
        : "/var/lib/freeswitch/storage/openwebpbx/call-me-back");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        do
        {
            try { await Tick(stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogWarning("Callback voice generation will retry ({ErrorType}).", ex.GetType().Name); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
    public async Task Tick(CancellationToken ct)
    {
        // An independent installation supplies its own licensed provider key privately.
        // No key leaves prompts pending and disabled; it never borrows our deployment key.
        if (string.IsNullOrWhiteSpace(settings["ElevenLabs:ApiKey"])) return;
        await using var db = await data.OpenConnectionAsync(ct);
        await using (var reset = new NpgsqlCommand("update v_pbx_cmb_services set prompt_state='pending' where prompt_state='generating' and updated_at<now()-interval '10 minutes'", db))
            await reset.ExecuteNonQueryAsync(ct);
        await GenerateOne(db, ct);
    }

    private async Task GenerateOne(NpgsqlConnection db, CancellationToken ct)
    {
        Guid id; string name;
        await using (var claim = new NpgsqlCommand("""
            with chosen as(select service_uuid from v_pbx_cmb_services where prompt_state='pending'
              order by created_at for update skip locked limit 1)
            update v_pbx_cmb_services s set prompt_state='generating',updated_at=now() from chosen
              where s.service_uuid=chosen.service_uuid returning s.service_uuid,s.name
            """, db))
        await using (var reader = await claim.ExecuteReaderAsync(ct))
        {
            if (!await reader.ReadAsync(ct)) return;
            id = reader.GetGuid(0); name = reader.GetString(1);
        }
        string? temporary = null;
        try
        {
            // Only the tenant's public service name is sent to the voice provider.
            // Identity numbers, phone numbers and all call audio remain on this instance.
            using var request = new HttpRequestMessage(HttpMethod.Post, $"https://api.elevenlabs.io/v1/text-to-speech/{Voice}?output_format=pcm_16000");
            request.Headers.Add("xi-api-key", settings["ElevenLabs:ApiKey"]);
            request.Content = JsonContent.Create(new { text = Greeting(name), model_id = "eleven_multilingual_v2", voice_settings = new { stability = 0.7, similarity_boost = 0.85 } });
            using var response = await clients.CreateClient("voice").SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (!response.IsSuccessStatusCode) throw new IOException("Voice generation unavailable.");
            await using var source = await response.Content.ReadAsStreamAsync(ct);
            using var pcm = new MemoryStream(); var buffer = new byte[16384]; int n;
            while ((n = await source.ReadAsync(buffer, ct)) > 0)
            {
                if (pcm.Length + n > 16000 * 2 * 120) throw new IOException("Voice response exceeds limit.");
                pcm.Write(buffer, 0, n);
            }
            if (pcm.Length < 3200 || pcm.Length % 2 != 0) throw new IOException("Voice response is incomplete.");
            var directory = Path.Combine(PromptRoot, id.ToString("D")); Directory.CreateDirectory(directory);
            temporary = Path.Combine(directory, ".greeting-" + Guid.NewGuid().ToString("N") + ".tmp");
            var wav = Wave(pcm.ToArray());
            await File.WriteAllBytesAsync(temporary, wav, ct);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead);
            // The name/version guard refuses an administrator edit that happened while generating.
            await using var transaction = await db.BeginTransactionAsync(ct);
            await using var guard = new NpgsqlCommand("select 1 from v_pbx_cmb_services where service_uuid=$1 and name=$2 and prompt_state='generating' and prompt_version='1.0.1' for update", db, transaction);
            guard.Parameters.AddWithValue(id); guard.Parameters.AddWithValue(name);
            if (await guard.ExecuteScalarAsync(ct) is null) return;
            File.Move(temporary, Path.Combine(directory, "greeting.wav"), true); temporary = null;
            await using var ready = new NpgsqlCommand("update v_pbx_cmb_services set prompt_state='ready',prompt_sha256=$2,updated_at=now() where service_uuid=$1", db, transaction);
            ready.Parameters.AddWithValue(id); ready.Parameters.AddWithValue(Convert.ToHexStringLower(SHA256.HashData(wav)));
            await ready.ExecuteNonQueryAsync(ct); await transaction.CommitAsync(ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception ex)
        {
            await using var failed = new NpgsqlCommand("update v_pbx_cmb_services set prompt_state='failed',enabled=false,updated_at=now() where service_uuid=$1 and name=$2 and prompt_state='generating'", db);
            failed.Parameters.AddWithValue(id); failed.Parameters.AddWithValue(name); await failed.ExecuteNonQueryAsync(ct);
            log.LogWarning("Tenant callback greeting could not be generated ({ErrorType}).", ex.GetType().Name);
        }
        finally { if (temporary is not null) File.Delete(temporary); }
    }

    internal static byte[] Wave(byte[] pcm)
    {
        using var output = new MemoryStream(); using var writer = new BinaryWriter(output, Encoding.ASCII, true);
        writer.Write("RIFF"u8); writer.Write(36 + pcm.Length); writer.Write("WAVEfmt "u8); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(16000); writer.Write(32000); writer.Write((short)2); writer.Write((short)16);
        writer.Write("data"u8); writer.Write(pcm.Length); writer.Write(pcm); return output.ToArray();
    }
}
