// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace OpenWebPbx.Phone.MediaChecks;
internal sealed record EngineSdp(string direction, string kind, string protocol, string[] codecs, string[] crypto_suites);
internal sealed record EngineObservation(bool observed, int log_bytes, string[] rejection_signals, EngineSdp[] sdp, bool sealed_original);
internal sealed record DiagnosticBinding(int schema, string source_commit, string run_id, string stage, int plaintext_bytes, string plaintext_sha256);
internal sealed record SealedDiagnostic(int schema, string algorithm, string public_key_sha256, string aad, string wrapped_key, string nonce, string tag, string ciphertext);
internal static class EngineDiagnostics
{
    internal const int Maximum = 2 * 1024 * 1024;
    internal const string KeyHash = "1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307";
    internal static readonly string[] Stages = ["engine_start", "tls_chain_hostname", "outgoing_audio", "incoming_audio", "hold_music_resume", "dtmf", "blind_transfer", "consult_complete", "consult_cancel", "call_waiting", "local_conference", "software_vp8", "voicemail_local_player"];
    internal static readonly string[] Protocols = ["RTP/AVP", "RTP/AVPF", "RTP/SAVP", "RTP/SAVPF", "UDP/TLS/RTP/SAVP", "UDP/TLS/RTP/SAVPF", "other"];
    internal static readonly string[] Codecs = ["PCMU", "PCMA", "OPUS", "G722", "G729", "VP8", "VP9", "H264", "TELEPHONE-EVENT", "CN", "other"];
    internal static readonly string[] Suites = ["AES_CM_128_HMAC_SHA1_80", "AES_CM_128_HMAC_SHA1_32", "AEAD_AES_128_GCM", "AEAD_AES_256_GCM", "other"];
    private static readonly (string Source, string Message, string Signal)[] Errors = [
        ("switch_core_media.c", "a=crypto in RTP/AVP, refer to rfc3711", "crypto_in_avp_refused"),
        ("switch_core_media.c", "Received invite with SAVP but secure media is administratively disabled", "srtp_administratively_disabled"),
        ("switch_core_media.c", "Crypto not negotiated but required.", "required_crypto_missing"),
        ("switch_core_media.c", "Cannot find a c= line in the sdp at media or session level!", "connection_line_missing"),
        ("switch_core_media.c", "INVALID SUITE SUPPLIED", "invalid_crypto_suite"),
        ("sofia.c", "Codec Error!", "codec_error"),
        ("sofia.c", "Early Media Codec Error!", "early_codec_error"),
        ("sofia.c", "Reinvite Codec Error!", "reinvite_codec_error"),
        ("sofia.c", "Reinvite resulted in codec negotiation failure.", "reinvite_negotiation_failed")];
    // Exact logger framing, fixed source and fixed messages; arbitrary remote text is never exported.
    private static readonly Regex LogLine = new(@"^(?:[a-fA-F0-9-]{36} )?\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ (?:\d{1,3}\.\d{2}%\s+)?\[(DEBUG|WARNING|ERR|ERROR|NOTICE|INFO)\] ([a-z_]+\.c):[0-9]+ (.*)$", RegexOptions.CultureInvariant);
    internal static EngineObservation Project(byte[] raw)
    {
        if (raw.Length is < 1 or > Maximum) throw new InvalidDataException("Bounded private engine trace required.");
        var lines = new UTF8Encoding(false, true).GetString(raw).Split('\n').Select(line => Regex.Replace(line.TrimEnd('\r'), @"^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12} ", "")).ToArray(); var signals = new List<string>(); var offers = new List<EngineSdp>();
        for (int i = 0; i < lines.Length; i++)
        {
            var match = LogLine.Match(lines[i].TrimEnd('\r')); if (!match.Success) continue;
            var source = match.Groups[2].Value; var message = match.Groups[3].Value;
            foreach (var error in Errors) if (source == error.Source && (message == error.Message || error.Signal == "codec_error" && message.StartsWith(error.Message + " ", StringComparison.Ordinal)) && !signals.Contains(error.Signal)) signals.Add(error.Signal);
            string direction; int start;
            if (source == "sofia.c" && match.Groups[1].Value == "DEBUG" && message is "Remote SDP:" or "Duplicate SDP") { direction = "remote"; start = i + 1; }
            else if (source == "sofia_glue.c" && match.Groups[1].Value == "DEBUG" && message.Contains(" sending invite version: ", StringComparison.Ordinal) && i + 1 < lines.Length && lines[i + 1] == "Local SDP:") { direction = "local"; start = i + 2; }
            else continue;
            int end = start; while (end < lines.Length && end - i <= 256 && !LogLine.IsMatch(lines[end].TrimEnd('\r'))) end++;
            if (end - i > 256) throw new InvalidDataException("Bounded SDP section required.");
            string? kind = null; string protocol = "other"; var codecs = new HashSet<string>(StringComparer.Ordinal); var suites = new HashSet<string>(StringComparer.Ordinal);
            void Finish() { if (kind is null) return; if (offers.Count >= 16) throw new InvalidDataException("Bounded SDP count required."); offers.Add(new(direction, kind, protocol, codecs.Order(StringComparer.Ordinal).ToArray(), suites.Order(StringComparer.Ordinal).ToArray())); }
            for (int line = start; line < end; line++)
            {
                var value = lines[line].TrimEnd('\r'); if (value.Length > 4096) throw new InvalidDataException("Bounded SDP line required.");
                if (value.StartsWith("m=", StringComparison.Ordinal))
                {
                    Finish(); codecs.Clear(); suites.Clear(); kind = null; var fields = value[2..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (fields.Length < 4 || fields[0] is not ("audio" or "video")) continue;
                    kind = fields[0]; protocol = Protocols.Contains(fields[2], StringComparer.Ordinal) ? fields[2] : "other";
                    if (kind == "audio") foreach (var payload in fields.Skip(3)) if (payload is "0" or "8" or "9" or "18") codecs.Add(payload switch { "0" => "PCMU", "8" => "PCMA", "9" => "G722", _ => "G729" });
                }
                else if (kind is not null && value.StartsWith("a=rtpmap:", StringComparison.Ordinal))
                {
                    var fields = value[9..].Split(' ', StringSplitOptions.RemoveEmptyEntries); if (fields.Length != 2) continue;
                    var codec = fields[1].Split('/')[0].ToUpperInvariant(); codecs.Add(Codecs.Contains(codec, StringComparer.Ordinal) ? codec : "other");
                }
                else if (kind is not null && value.StartsWith("a=crypto:", StringComparison.Ordinal))
                {
                    var fields = value[9..].Split(' ', StringSplitOptions.RemoveEmptyEntries); if (fields.Length < 3) continue;
                    suites.Add(Suites.Contains(fields[1], StringComparer.Ordinal) ? fields[1] : "other");
                }
            }
            Finish(); i = end - 1;
        }
        return new(true, raw.Length, signals.ToArray(), offers.ToArray(), false);
    }
    internal static byte[] ReadCase(string file, long offset)
    {
        if (!Path.IsPathFullyQualified(file) || offset < 0) throw new InvalidDataException("Exact trace path required.");
        for (var item = new FileInfo(file) as FileSystemInfo; item is not null; item = item is FileInfo leaf ? leaf.Directory : ((DirectoryInfo)item).Parent)
            if (!item.Exists || (item.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Ordinary trace ancestry required.");
        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var length = stream.Length - offset; if (length is < 1 or > Maximum || stream.Length > 16 * Maximum) throw new InvalidDataException("Bounded complete case trace required.");
        stream.Position = offset; var raw = new byte[(int)length]; stream.ReadExactly(raw); if (stream.Length != offset + length) throw new InvalidDataException("Trace changed after engine shutdown."); return raw;
    }
    internal static byte[] Seal(byte[] raw, string source, string run, string stage, string publicPem)
    {
        if (raw.Length is < 1 or > Maximum || !Regex.IsMatch(source, "^[a-f0-9]{40}$") || !Regex.IsMatch(run, "^[1-9][0-9]{0,19}$") || !Stages.Contains(stage, StringComparer.Ordinal)) throw new InvalidDataException("Exact diagnostic binding required.");
        using var rsa = RSA.Create(); rsa.ImportFromPem(publicPem); if (rsa.KeySize != 3072) throw new InvalidDataException("Dedicated RSA3072 public key required.");
        var aad = JsonSerializer.SerializeToUtf8Bytes(new DiagnosticBinding(1, source, run, stage, raw.Length, Convert.ToHexStringLower(SHA256.HashData(raw))));
        var key = RandomNumberGenerator.GetBytes(32); var nonce = RandomNumberGenerator.GetBytes(12); var tag = new byte[16]; var cipher = new byte[raw.Length];
        try { using var aes = new AesGcm(key, 16); aes.Encrypt(nonce, raw, cipher, tag, aad); return JsonSerializer.SerializeToUtf8Bytes(new SealedDiagnostic(1, "RSA3072-OAEP-SHA256+A256GCM", Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(publicPem))), Convert.ToBase64String(aad), Convert.ToBase64String(rsa.Encrypt(key, RSAEncryptionPadding.OaepSHA256)), Convert.ToBase64String(nonce), Convert.ToBase64String(tag), Convert.ToBase64String(cipher))); }
        finally { CryptographicOperations.ZeroMemory(key); }
    }
}
