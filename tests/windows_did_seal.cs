// SPDX-License-Identifier: AGPL-3.0-or-later
// Seal body retained from EngineDiagnostics.cs/e6a1cec4; separate fixed DID stage.
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace OpenWebPbx.DidDiagnostics;
internal sealed record DiagnosticBinding(int schema, string source_commit, string run_id, string stage, int plaintext_bytes, string plaintext_sha256);
internal sealed record SealedDiagnostic(int schema, string algorithm, string public_key_sha256, string aad, string wrapped_key, string nonce, string tag, string ciphertext);
public static class NativeFailureSeal
{
    internal const int Maximum = 2 * 1024 * 1024;
    internal static readonly string[] Stages = new[] { "windows_did_initdb_failure" };
    public static byte[] Seal(byte[] raw, string source, string run, string stage, string publicPem)
    {
        if (raw.Length is < 1 or > Maximum || !Regex.IsMatch(source, "^[a-f0-9]{40}$") || !Regex.IsMatch(run, "^[1-9][0-9]{0,19}$") || !Stages.Contains(stage, StringComparer.Ordinal)) throw new InvalidDataException("Exact diagnostic binding required.");
        using var rsa = RSA.Create(); rsa.ImportFromPem(publicPem); if (rsa.KeySize != 3072) throw new InvalidDataException("Dedicated RSA3072 public key required.");
        var aad = JsonSerializer.SerializeToUtf8Bytes(new DiagnosticBinding(1, source, run, stage, raw.Length, Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant()));
        var key = RandomNumberGenerator.GetBytes(32); var nonce = RandomNumberGenerator.GetBytes(12); var tag = new byte[16]; var cipher = new byte[raw.Length];
        try { using var aes = new AesGcm(key, 16); aes.Encrypt(nonce, raw, cipher, tag, aad); return JsonSerializer.SerializeToUtf8Bytes(new SealedDiagnostic(1, "RSA3072-OAEP-SHA256+A256GCM", Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(publicPem))).ToLowerInvariant(), Convert.ToBase64String(aad), Convert.ToBase64String(rsa.Encrypt(key, RSAEncryptionPadding.OaepSHA256)), Convert.ToBase64String(nonce), Convert.ToBase64String(tag), Convert.ToBase64String(cipher))); }
        finally { CryptographicOperations.ZeroMemory(key); }
    }
}
