// SPDX-License-Identifier: AGPL-3.0-or-later
using OpenWebPbx.Phone.MediaChecks;
using System.Text.Json;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
var root = Path.Combine(Path.GetTempPath(), "phone-media-pure-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root); var checks = 0;
void Check(bool value) { if (!value) throw new InvalidDataException("Pure media control failed."); checks++; }
void Refuse(Action action) { bool refused = false; try { action(); } catch (InvalidDataException) { refused = true; } Check(refused); }
try
{
    var single = Path.Combine(root, "single.wav"); PcmWave.Write(single, [425], 4); var wave = PcmWave.Read(single); Check(wave.Rate == 8000 && wave.Duration == 4); var proof = wave.Find([425]); Check(proof.GoodFraction == 1 && proof.MinimumToneRatio > .99 && proof.Seconds >= 3);
    Refuse(() => wave.Find([733])); Refuse(() => wave.Find([425, 733]));
    var mix = Path.Combine(root, "mixed.wav"); PcmWave.Write(mix, [425, 733], 4); var decoded = PcmWave.Read(mix); Check(decoded.Find([425, 733]).GoodFraction == 1); Refuse(() => decoded.Find([425]));
    var tripleFile = Path.Combine(root, "triple.wav"); PcmWave.Write(tripleFile, [425, 733, 1013], 4); Check(PcmWave.Read(tripleFile).Find([425, 733, 1013]).GoodFraction == 1); Refuse(() => decoded.Find([425, 733, 1013]));
    var shortFile = Path.Combine(root, "short.wav"); PcmWave.Write(shortFile, [425], 1); Refuse(() => PcmWave.Read(shortFile).Find([425]));
    var silence = File.ReadAllBytes(single); Array.Clear(silence, 44, silence.Length - 44); var quiet = Path.Combine(root, "silence.wav"); File.WriteAllBytes(quiet, silence); Refuse(() => PcmWave.Read(quiet).Find([425]));
    var clipped = File.ReadAllBytes(single); for (var at = 44; at < clipped.Length; at += 2) { clipped[at] = 255; clipped[at + 1] = 127; } var clippedFile = Path.Combine(root, "clipped.wav"); File.WriteAllBytes(clippedFile, clipped); Refuse(() => PcmWave.Read(clippedFile).Find([425]));
    var bad = File.ReadAllBytes(single); bad[4] ^= 1; var invalid = Path.Combine(root, "invalid.wav"); File.WriteAllBytes(invalid, bad); Refuse(() => PcmWave.Read(invalid));
    var growing = File.ReadAllBytes(single); Array.Clear(growing, 4, 4); Array.Clear(growing, 40, 4); var open = Path.Combine(root, "open.wav"); File.WriteAllBytes(open, growing); Refuse(() => PcmWave.Read(open)); Check(PcmWave.Read(open, true).Tail([425]).GoodFraction == 1); Check(File.ReadAllBytes(open).SequenceEqual(growing));
    var wrongNow = Path.Combine(root, "past.wav"); PcmWave.Write(wrongNow, [733], 4); var past = File.ReadAllBytes(single); var current = File.ReadAllBytes(wrongNow); var ordered = past.Concat(current.Skip(44)).ToArray(); System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(ordered.AsSpan(4), (uint)(ordered.Length - 8)); System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(ordered.AsSpan(40), (uint)(ordered.Length - 44)); var orderedPath = Path.Combine(root, "ordered.wav"); File.WriteAllBytes(orderedPath, ordered); Refuse(() => PcmWave.Read(orderedPath).Tail([425])); Check(PcmWave.Read(orderedPath).Tail([733]).GoodFraction == 1);
    var typed = JsonSerializer.Deserialize<AudioWindow>(JsonSerializer.Serialize(proof))!; Check(double.IsFinite(typed.MinimumToneRatio) && typed.GoodFraction == 1);
    object Codec(string name, string key, string type = "codec") => new { type, name, ikey = key };
    object[] rows = [Codec("G.711 ulaw", "CORE_PCM_MODULE"), Codec("G.711 alaw", "CORE_PCM_MODULE"), Codec("VP8 Video", "CORE_VPX_MODULE")];
    string Inventory(object[] values, int? count = null) => JsonSerializer.Serialize(new { row_count = count ?? values.Length, rows = values });
    CoreCodecInventory.Require(Inventory(rows)); Check(true);
    for (var index = 0; index < rows.Length; index++) { Refuse(() => CoreCodecInventory.Require(Inventory(rows.Where((_, i) => i != index).ToArray()))); Refuse(() => CoreCodecInventory.Require(Inventory(rows.Concat([rows[index]]).ToArray()))); }
    Refuse(() => CoreCodecInventory.Require(Inventory([rows[0], rows[1], Codec("VP8 Video", "mod_vpx")])));
    Refuse(() => CoreCodecInventory.Require(Inventory([rows[0], rows[1], Codec("VP8 Video", "CORE_VPX_MODULE", "application")])));
    Refuse(() => CoreCodecInventory.Require(Inventory([rows[0], rows[1], Codec("VP9 Video", "CORE_VPX_MODULE")])));
    Refuse(() => CoreCodecInventory.Require(Inventory(rows, 4)));
    Refuse(() => CoreCodecInventory.Require(Inventory(rows.Concat(Enumerable.Range(0, 1022).Select(_ => Codec("other", "other"))).ToArray())));
    var peerError = "{\"schema\":1,\"state\":\"refused_or_failed\",\"error_type\":\"InvalidOperationException\"}";
    Check(FailureObservation.ReadPeerError(peerError, true) == ("InvalidOperationException", true));
    Check(FailureObservation.ReadPeerError("", true) == ("none", true));
    foreach (var invalidPeer in new[] { peerError + peerError, peerError.Replace("InvalidOperationException", "PRIVATE"), peerError.Replace("\"schema\":1", "\"schema\":1,\"schema\":1"), peerError.Replace("\"schema\":1", "\"schema\":true"), peerError.Replace("\"schema\":1", "\"schema\":1,\"private\":\"PRIVATE\""), new string('x', 8193) }) Check(FailureObservation.ReadPeerError(invalidPeer, true) == ("unobserved", false));
    Check(FailureObservation.ReadPeerError(peerError, false) == ("unobserved", false));
    var safe = FailureObservation.Capture(new InvalidOperationException("PRIVATE"), "wrong_ca_create"); Check(safe.operation == "wrong_ca_create" && safe.source_basename == "external_component" && safe.source_line == 0 && !JsonSerializer.Serialize(safe).Contains("PRIVATE", StringComparison.Ordinal));
    var executable = Path.Combine(root, "fixture.exe"); File.WriteAllBytes(executable, [1, 2, 3]); var imageHash = ProcessImage.HashFile(executable);
    Check(ProcessImage.Validate(executable, 1000, 42, executable, 1000, 42, false) == executable); ProcessImage.VerifyFile(executable, imageHash); Check(true);
    Refuse(() => ProcessImage.Validate(executable, 1000, 42, executable, 1000, 43, false)); Refuse(() => ProcessImage.Validate(executable, 1000, 42, executable, 1001, 42, false)); Refuse(() => ProcessImage.Validate(executable, 1000, 42, executable, 1000, 42, true));
    Refuse(() => ProcessImage.Validate(executable, 1000, 42, executable + ".other", 1000, 42, false)); Refuse(() => ProcessImage.Validate("relative.exe", 1000, 42, "relative.exe", 1000, 42, false)); Refuse(() => ProcessImage.Validate(executable, 1000, 42, "relative.exe", 1000, 42, false));
    Refuse(() => ProcessImage.Validate(executable, 0, 42, executable, 0, 42, false)); Refuse(() => ProcessImage.Validate(executable, 1000, 0, executable, 1000, 0, false));
    Refuse(() => ProcessImage.VerifyFile(executable, new string('0', 64))); Refuse(() => ProcessImage.VerifyFile(executable, "PRIVATE")); File.WriteAllBytes(executable, [4, 5, 6]); Refuse(() => ProcessImage.VerifyFile(executable, imageHash));
    var link = Path.Combine(root, "linked.exe"); File.CreateSymbolicLink(link, executable); Refuse(() => ProcessImage.HashFile(link)); File.Delete(link); Refuse(() => ProcessImage.HashFile(root));
    MediaWaitPeer[] Peers() => [new(0, true, new(true, false, false, 0, [], [new(13, 4, 404, true)]))];
    var waitModel = new MediaWaitObservation("incoming_initial", 20, Peers()); Check(WaitObservation.Require(waitModel).peers[0].state!.signals[0].protocol_code == 404);
    Refuse(() => WaitObservation.Require(waitModel with { name = "PRIVATE" })); Refuse(() => WaitObservation.Require(waitModel with { deadline_seconds = 21 })); Refuse(() => WaitObservation.Require(waitModel with { peers = [] }));
    Refuse(() => WaitObservation.Require(waitModel with { peers = [new(1, false, null)] })); Refuse(() => WaitObservation.Require(waitModel with { peers = [new(0, false, waitModel.peers[0].state)] }));
    foreach (var badSignal in new[] { new MediaWaitSignal(22, 4, 404, true), new(13, 26, 404, true), new(13, 4, 700, true), new(13, 4, 404, false) }) Refuse(() => WaitObservation.Require(waitModel with { peers = [new(0, true, waitModel.peers[0].state! with { signals = [badSignal] })] }));
    Refuse(() => WaitObservation.Require(waitModel with { peers = [new(0, true, waitModel.peers[0].state! with { call_count = 1, states = ["PRIVATE"] })] }));
    long elapsed = 0; var predicates = 0; var observations = 0;
    MediaWaitPeer[] Observe() { observations++; return Peers(); }
    void Sleep(int duration) { if (duration != 100) throw new InvalidDataException("Original poll interval differs."); elapsed += duration; }
    WaitObservation.RunCore("incoming_initial", () => { predicates++; return true; }, Observe, 20, () => elapsed, _ => throw new InvalidDataException()); Check(predicates == 1 && observations == 0);
    predicates = 0; try { WaitObservation.RunCore("incoming_initial", () => { predicates++; return false; }, Observe, 20, () => elapsed, Sleep); throw new InvalidDataException(); } catch (TimeoutException timeout) { Check(predicates == 200 && elapsed == 20000 && observations == 1 && timeout.Data["media_wait_observation"] is MediaWaitObservation); }
    var primary = new InvalidDataException("PRIVATE"); try { WaitObservation.RunCore("conference_merged", () => throw primary, () => throw new InvalidOperationException("PRIVATE"), 20, () => 0, _ => throw new InvalidDataException()); } catch (InvalidDataException caught) { Check(ReferenceEquals(caught, primary) && !caught.Data.Contains("media_wait_observation")); }
    // Real parser/crypto/filesystem controls. The SDP input is explicitly fictional.
    var trace = "2026-10-23 18:30:00.123456 [DEBUG] sofia.c:7521 Remote SDP:\n" +
        "v=0\no=PRIVATE 0 0 IN IP4 192.0.2.10\ns=PRIVATE\nc=IN IP4 192.0.2.10\nm=audio 19000 RTP/SAVP 0 8 101\na=rtpmap:101 telephone-event/8000\na=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:PRIVATE_KEY\nm=video 19002 RTP/SAVPF 96\na=rtpmap:96 VP8/90000\na=crypto:1 PRIVATE_SUITE inline:PRIVATE_KEY\n" +
        "2026-10-23 18:30:00.223456 [WARNING] switch_core_media.c:5628 Crypto not negotiated but required.\n";
    var traceBytes = System.Text.Encoding.UTF8.GetBytes(trace); var projected = EngineDiagnostics.Project(traceBytes);
    Check(projected.observed && projected.sdp.Length == 2 && projected.sdp[0].codecs.SequenceEqual(new[] { "PCMA", "PCMU", "TELEPHONE-EVENT" }));
    Check(projected.sdp[0].crypto_suites.SequenceEqual(new[] { "AES_CM_128_HMAC_SHA1_80" }) && projected.sdp[1].crypto_suites.SequenceEqual(new[] { "other" }));
    Check(projected.rejection_signals.SequenceEqual(new[] { "required_crypto_missing" }) && !JsonSerializer.Serialize(projected).Contains("PRIVATE", StringComparison.Ordinal) && !JsonSerializer.Serialize(projected).Contains("192.0.2", StringComparison.Ordinal));
    Check(EngineDiagnostics.Project(System.Text.Encoding.UTF8.GetBytes("Crypto not negotiated but required.\n")).rejection_signals.Length == 0);
    Check(EngineDiagnostics.Project(System.Text.Encoding.UTF8.GetBytes(trace.Replace("[WARNING] switch_core_media.c", "[WARNING] other.c"))).rejection_signals.Length == 0);
    Check(EngineDiagnostics.Project(System.Text.Encoding.UTF8.GetBytes(trace.Replace("Remote SDP:", "PRIVATE Remote SDP:"))).sdp.Length == 0);
    var uuidPrefix = "01234567-89ab-cdef-0123-456789abcdef ";
    var actualFormatModel = string.Join("\n", trace.Split('\n').Select(line => uuidPrefix + line.Replace(" [DEBUG]", " 99.95% [DEBUG]").Replace(" [WARNING]", " 99.95% [WARNING]"))) +
        "\n" + uuidPrefix + "2026-10-23 18:30:01.123456 99.95% [DEBUG] sofia_glue.c:1659 PRIVATE sending invite version: PRIVATE\n" + uuidPrefix + "Local SDP:\n" + uuidPrefix + "v=0\n" + uuidPrefix + "m=audio 19000 RTP/AVP 0 8\n";
    var actualFormat = EngineDiagnostics.Project(System.Text.Encoding.UTF8.GetBytes(actualFormatModel));
    Check(actualFormat.sdp.Length == 3 && actualFormat.sdp[0].direction == "remote" && actualFormat.sdp[0].protocol == "RTP/SAVP" && actualFormat.sdp[0].crypto_suites.SequenceEqual(new[] { "AES_CM_128_HMAC_SHA1_80" }));
    Check(actualFormat.sdp[2].direction == "local" && actualFormat.sdp[2].protocol == "RTP/AVP" && actualFormat.sdp[2].crypto_suites.Length == 0 && actualFormat.sdp[2].codecs.SequenceEqual(new[] { "PCMA", "PCMU" }));
    Check(!JsonSerializer.Serialize(actualFormat).Contains("PRIVATE", StringComparison.Ordinal) && !JsonSerializer.Serialize(actualFormat).Contains(uuidPrefix.Trim(), StringComparison.Ordinal));
    Check(EngineDiagnostics.Project(System.Text.Encoding.UTF8.GetBytes(actualFormatModel.Replace("sofia_glue.c", "other.c"))).sdp.Length == 2);
    Refuse(() => EngineDiagnostics.Project([])); Refuse(() => EngineDiagnostics.Project(new byte[EngineDiagnostics.Maximum + 1]));
    var privateLog = Path.Combine(root, "private.log"); File.WriteAllBytes(privateLog, new byte[] { 9, 9 }.Concat(traceBytes).ToArray()); Check(EngineDiagnostics.ReadCase(privateLog, 2).SequenceEqual(traceBytes));
    Refuse(() => EngineDiagnostics.ReadCase(privateLog, -1)); Refuse(() => EngineDiagnostics.ReadCase(privateLog, new FileInfo(privateLog).Length)); Refuse(() => EngineDiagnostics.ReadCase("relative.log", 0));
    var traceLink = Path.Combine(root, "trace-link"); File.CreateSymbolicLink(traceLink, privateLog); Refuse(() => EngineDiagnostics.ReadCase(traceLink, 0)); File.Delete(traceLink);
    using var diagnosticKey = System.Security.Cryptography.RSA.Create(3072); var publicPem = diagnosticKey.ExportSubjectPublicKeyInfoPem();
    var sealedBytes = EngineDiagnostics.Seal(traceBytes, new string('a', 40), "123456", "outgoing_audio", publicPem); var sealedTrace = JsonSerializer.Deserialize<SealedDiagnostic>(sealedBytes)!;
    var key = diagnosticKey.Decrypt(Convert.FromBase64String(sealedTrace.wrapped_key), System.Security.Cryptography.RSAEncryptionPadding.OaepSHA256);
    var aad = Convert.FromBase64String(sealedTrace.aad); var cipher = Convert.FromBase64String(sealedTrace.ciphertext); var nonce = Convert.FromBase64String(sealedTrace.nonce); var tag = Convert.FromBase64String(sealedTrace.tag); var plain = new byte[cipher.Length];
    using var aes = new System.Security.Cryptography.AesGcm(key, 16); aes.Decrypt(nonce, cipher, tag, plain, aad); Check(plain.SequenceEqual(traceBytes));
    var binding = JsonSerializer.Deserialize<DiagnosticBinding>(aad)!; Check(binding.source_commit == new string('a', 40) && binding.run_id == "123456" && binding.stage == "outgoing_audio" && binding.plaintext_bytes == traceBytes.Length && binding.plaintext_sha256 == Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(traceBytes)));
    Check(!System.Text.Encoding.UTF8.GetString(sealedBytes).Contains("PRIVATE", StringComparison.Ordinal) && sealedTrace.algorithm == "RSA3072-OAEP-SHA256+A256GCM");
    void AuthenticationRefuses(byte[] changedCipher, byte[] changedTag, byte[] changedAad) { bool refused = false; try { aes.Decrypt(nonce, changedCipher, changedTag, new byte[changedCipher.Length], changedAad); } catch (System.Security.Cryptography.AuthenticationTagMismatchException) { refused = true; } Check(refused); }
    var changed = cipher.ToArray(); changed[0] ^= 1; AuthenticationRefuses(changed, tag, aad); var changedTag = tag.ToArray(); changedTag[0] ^= 1; AuthenticationRefuses(cipher, changedTag, aad); var changedAad = aad.ToArray(); changedAad[0] ^= 1; AuthenticationRefuses(cipher, tag, changedAad);
    using var wrongKey = System.Security.Cryptography.RSA.Create(3072); bool wrongKeyRefused = false; try { wrongKey.Decrypt(Convert.FromBase64String(sealedTrace.wrapped_key), System.Security.Cryptography.RSAEncryptionPadding.OaepSHA256); } catch (System.Security.Cryptography.CryptographicException) { wrongKeyRefused = true; } Check(wrongKeyRefused);
    Refuse(() => EngineDiagnostics.Seal(traceBytes, "PRIVATE", "123456", "outgoing_audio", publicPem)); Refuse(() => EngineDiagnostics.Seal(traceBytes, new string('a', 40), "PRIVATE", "outgoing_audio", publicPem)); Refuse(() => EngineDiagnostics.Seal(traceBytes, new string('a', 40), "123456", "PRIVATE", publicPem)); Refuse(() => EngineDiagnostics.Seal(new byte[EngineDiagnostics.Maximum + 1], new string('a', 40), "123456", "outgoing_audio", publicPem));
    System.Security.Cryptography.CryptographicOperations.ZeroMemory(key);
    WaveReadObservation ObserveWave(byte[] bytes, bool growing, string reason)
    {
        var file = Path.Combine(root, "PRIVATE-wave-" + Guid.NewGuid().ToString("N")); File.WriteAllBytes(file, bytes);
        try { PcmWave.Read(file, growing); throw new InvalidOperationException("Expected original parser refusal."); }
        catch (InvalidDataException error)
        {
            var observation = error.Data["media_wave_observation"] as WaveReadObservation ?? throw new InvalidOperationException("Original failure observation missing.");
            Check(observation.reason == reason && !observation.snapshot_atomic && observation.growing == growing && !JsonSerializer.Serialize(observation).Contains("PRIVATE", StringComparison.Ordinal));
            var captured = FailureObservation.Capture(error, "case_execute"); Check(ReferenceEquals(captured.wave, observation) && captured.source_basename == "AudioProof.cs" && captured.source_line > 0);
            return observation;
        }
    }
    var audioBytes = File.ReadAllBytes(single); var emptyHeader = audioBytes.Take(44).ToArray(); Array.Clear(emptyHeader, 4, 4); Array.Clear(emptyHeader, 40, 4);
    var emptyObservation = ObserveWave(emptyHeader, true, "decoded_samples"); Check(emptyObservation.source == "failed_read_buffer" && emptyObservation.buffer_bytes == 44 && emptyObservation.format_seen && emptyObservation.data_seen && emptyObservation.data_bytes == 0 && emptyObservation.format_tag == 1 && emptyObservation.sample_bits == 16);
    var partial = ObserveWave(emptyHeader.Take(40).ToArray(), true, "file_length"); Check(partial.source == "file_length_check" && partial.length_check_bytes == 40 && partial.buffer_bytes == 0 && partial.riff is null);
    var wrongRiff = audioBytes.ToArray(); wrongRiff[0] = 0; var riffObservation = ObserveWave(wrongRiff, true, "riff_wave_shape"); Check(riffObservation.riff == false && riffObservation.wave == true);
    var unsupported = audioBytes.ToArray(); System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(unsupported.AsSpan(20), 3); Check(ObserveWave(unsupported, true, "pcm_format").format_tag == 3);
    var eightBit = audioBytes.ToArray(); System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(eightBit.AsSpan(34), 8); Check(ObserveWave(eightBit, true, "pcm_format").sample_bits == 8);
    var invalidRate = audioBytes.ToArray(); System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(invalidRate.AsSpan(24), 1000); Check(ObserveWave(invalidRate, true, "pcm_layout").sample_rate == 1000);
    var tooLongChunk = audioBytes.ToArray(); System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(tooLongChunk.AsSpan(16), uint.MaxValue); Check(ObserveWave(tooLongChunk, true, "chunk_length").chunk_declared_bytes == uint.MaxValue);
    var unfinalized = ObserveWave(emptyHeader, false, "riff_wave_shape"); Check(unfinalized.riff == true && unfinalized.wave == true && unfinalized.riff_declared_bytes == 0);
    var growth = Path.Combine(root, "growing-observation.wav");
    using (var writer = new FileStream(growth, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.ReadWrite))
    {
        writer.Write(emptyHeader); writer.Flush(true); InvalidDataException? primaryRead = null;
        try { PcmWave.Read(growth, true); } catch (InvalidDataException error) { primaryRead = error; }
        Check(primaryRead?.Data["media_wave_observation"] is WaveReadObservation { reason: "decoded_samples", data_bytes: 0 });
        writer.Write(audioBytes.AsSpan(44)); writer.Flush(true); Check(PcmWave.Read(growth, true).Duration == 4 && PcmWave.Read(growth, true).Tail([425]).GoodFraction == 1);
        Check(primaryRead?.Data["media_wave_observation"] is WaveReadObservation { buffer_bytes: 44, data_bytes: 0 });
    }
    var security = SecurityObservation.Capture(true, true, [SecurityObservation.Call("StreamsRunning", "SRTP", "Invalid")]); Check(security.tls_ca_and_hostname && security.mandatory_srtp && security.calls[0].srtp_suite == "Invalid");
    Check(SecurityObservation.Capture(false, true, []).tls_ca_and_hostname == false); Check(SecurityObservation.Capture(true, false, []).mandatory_srtp == false);
    foreach (var encryption in SecurityObservation.Encryptions) Check(SecurityObservation.Call("StreamsRunning", encryption, "AESCM128HMACSHA180").encryption == encryption);
    foreach (var suite in SecurityObservation.Suites) Check(SecurityObservation.Call("StreamsRunning", "SRTP", suite).srtp_suite == suite);
    var unknownSecurity = SecurityObservation.Capture(true, true, [SecurityObservation.Call("PRIVATE", "PRIVATE", "PRIVATE")]); Check(!JsonSerializer.Serialize(unknownSecurity).Contains("PRIVATE", StringComparison.Ordinal) && unknownSecurity.calls[0] == new MediaSecurityCall("unrecognised", "unrecognised", "unrecognised"));
    Refuse(() => SecurityObservation.Capture(true, true, [security.calls[0], security.calls[0], security.calls[0]]));
    var securityError = new InvalidDataException("PRIVATE"); securityError.Data["media_security_observation"] = security; Check(ReferenceEquals(FailureObservation.Capture(securityError, "case_execute").security, security));
    // Actual fixed-header/file/hash observer controls; native call metadata is an explicit model.
    var recordRoot = Path.Combine(root, "PRIVATE-recorder"); Directory.CreateDirectory(recordRoot); var recordPath = Path.Combine(recordRoot, "output.wav");
    var nativePayload = RecorderObservation.Payload("StreamsRunning", "PCMU", 8000, 1);
    var pendingRecorder = RecorderObservation.Pending(recordRoot, recordPath, true, true, [nativePayload]);
    var notClosed = RecorderObservation.Complete(pendingRecorder, false); Check(!notClosed.owned_peers_closed && notClosed.file_observation == "peers_not_closed" && notClosed.closed_file is null);
    var absentRecorder = RecorderObservation.Complete(pendingRecorder, true); Check(absentRecorder.owned_peers_closed && absentRecorder.file_observation == "read_refused" && absentRecorder.closed_file is null);
    File.WriteAllBytes(recordPath, []); var closedEmpty = RecorderObservation.Complete(pendingRecorder, true);
    Check(closedEmpty.closed_file is { length_bytes: 0, header_bytes: 0, riff: null, sample_rate: null } && closedEmpty.closed_file.sha256 == Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData([])));
    File.WriteAllBytes(recordPath, audioBytes); var closedActual = RecorderObservation.Complete(pendingRecorder, true); var closedHeader = closedActual.closed_file!;
    Check(closedHeader.phase == "after_owned_peer_shutdown" && closedHeader.length_bytes == audioBytes.Length && closedHeader.header_bytes == 44 && closedHeader.riff == true && closedHeader.wave == true && closedHeader.format == true && closedHeader.data == true);
    Check(closedHeader.format_tag == 1 && closedHeader.channels == 1 && closedHeader.sample_rate == 8000 && closedHeader.sample_bits == 16 && closedHeader.alignment == 2 && closedHeader.byte_rate == 16000 && closedHeader.bytes_after_fixed_header == audioBytes.Length - 44 && closedHeader.data_declared_bytes == audioBytes.Length - 44);
    Check(closedHeader.sha256 == Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(audioBytes)) && File.ReadAllBytes(recordPath).SequenceEqual(audioBytes));
    Check(!JsonSerializer.Serialize(closedActual).Contains("PRIVATE", StringComparison.Ordinal));
    var originalRecorderError = new InvalidDataException("PRIVATE"); originalRecorderError.Data["media_recorder_observation"] = closedActual; Check(ReferenceEquals(FailureObservation.Capture(originalRecorderError, "case_execute").recorder, closedActual));
    var sourceHeaderModel = audioBytes.Take(44).ToArray(); System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(sourceHeaderModel.AsSpan(4), 32); System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(sourceHeaderModel.AsSpan(40), 0); File.WriteAllBytes(recordPath, sourceHeaderModel);
    var closedSourceModel = RecorderObservation.ReadClosed(recordRoot, recordPath); Check(closedSourceModel.riff_declared_bytes == 32 && closedSourceModel.data_declared_bytes == 0 && closedSourceModel.bytes_after_fixed_header == 0); Refuse(() => PcmWave.Read(recordPath));
    File.WriteAllBytes(recordPath, unsupported); Check(RecorderObservation.ReadClosed(recordRoot, recordPath).format_tag == 3); Refuse(() => PcmWave.Read(recordPath));
    foreach (var length in new[] { 1, 4, 8, 12, 16, 36, 40, 43 }) { File.WriteAllBytes(recordPath, audioBytes.Take(length).ToArray()); Check(RecorderObservation.ReadClosed(recordRoot, recordPath).header_bytes == length); }
    File.WriteAllBytes(recordPath, Enumerable.Repeat((byte)255, 44).ToArray()); var rawHeader = RecorderObservation.ReadClosed(recordRoot, recordPath); Check(rawHeader.riff == false && rawHeader.wave == false && rawHeader.format == false && rawHeader.data == false && rawHeader.format_tag is null && rawHeader.data_declared_bytes is null);
    File.Delete(recordPath); File.CreateSymbolicLink(recordPath, single); Refuse(() => RecorderObservation.ReadClosed(recordRoot, recordPath)); Check(RecorderObservation.Complete(pendingRecorder, true).file_observation == "read_refused"); File.Delete(recordPath);
    var linkedRecordRoot = Path.Combine(root, "PRIVATE-linked-recording"); Directory.CreateSymbolicLink(linkedRecordRoot, recordRoot); Refuse(() => RecorderObservation.ReadClosed(linkedRecordRoot, Path.Combine(linkedRecordRoot, "output.wav"))); Directory.Delete(linkedRecordRoot);
    using (var largeRecorder = new FileStream(recordPath, FileMode.CreateNew)) largeRecorder.SetLength((long)RecorderObservation.Maximum + 1); Refuse(() => RecorderObservation.ReadClosed(recordRoot, recordPath)); File.Delete(recordPath);
    Refuse(() => RecorderObservation.Pending(recordRoot, single, true, true, [nativePayload])); Refuse(() => RecorderObservation.Pending(recordRoot, Path.Combine(recordRoot, "other.wav"), true, true, [nativePayload])); Refuse(() => RecorderObservation.Pending("relative", "relative/output.wav", false, false, []));
    Refuse(() => RecorderObservation.Pending(recordRoot, recordPath, false, true, [nativePayload])); Refuse(() => RecorderObservation.Pending(recordRoot, recordPath, true, true, [])); Refuse(() => RecorderObservation.Pending(recordRoot, recordPath, true, true, [nativePayload, nativePayload, nativePayload]));
    Refuse(() => RecorderObservation.Pending(recordRoot, recordPath, true, true, [new("PRIVATE", "PRIVATE", 8000, 1)]));
    Check(RecorderObservation.Payload("PRIVATE", "PRIVATE", int.MaxValue, -1) == new RecorderPayload("unrecognised", "unrecognised", 0, 0));
    Check(RecorderObservation.Pending(recordRoot, Path.Combine(recordRoot, "conference.wav"), false, false, []).Recording == "conference_mix");
    // Exact original zero-byte refusal plus actual growing files. Only the clock,
    // sleeps and peer payload are adapters; no synthetic media is accepted here.
    File.WriteAllBytes(recordPath, []); InvalidDataException? emptyPrimary = null;
    try { PcmWave.Read(recordPath, true); } catch (InvalidDataException error) { emptyPrimary = error; }
    Check(emptyPrimary?.Data["media_wave_observation"] is WaveReadObservation { reason: "file_length", length_check_bytes: 0, buffer_bytes: 0 });
    var retainedEmpty = emptyPrimary!.Data["media_wave_observation"]; long intervalClock = 10; var sleeps = new List<int>(); PendingRecorderObservation grown;
    using (var liveWriter = new FileStream(recordPath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite))
    {
        grown = RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder, 0, () => intervalClock,
            duration => { Check(duration is > 0 and <= 100); sleeps.Add(duration); liveWriter.Write(audioBytes.AsSpan(44, duration * 16)); liveWriter.Flush(true); intervalClock += duration; });
        Check(grown.Interval is { state: "observed", phase: "before_owned_peer_shutdown", snapshot_atomic: false, requested_ms: 5000, elapsed_ms: 5000, wait_completed: true });
        Check(grown.Interval!.prefix is { length_before_bytes: 80000, length_after_bytes: 80000, header_bytes: 44, riff: false, format_tag: null });
        Check(sleeps.Count == 50 && sleeps.Sum() == 5000 && intervalClock == 5010 && ReferenceEquals(emptyPrimary.Data["media_wave_observation"], retainedEmpty));
    }
    Check(RecorderObservation.Complete(grown, true).initialization_interval == grown.Interval);
    intervalClock = 11050; sleeps.Clear(); var shortInterval = RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder, 0, () => intervalClock, duration => { sleeps.Add(duration); intervalClock += duration; });
    Check(shortInterval.Interval is { state: "observed", requested_ms: 950, elapsed_ms: 950, start_capture_ms: 11050, end_capture_ms: 12000 } && sleeps.Sum() == 950 && sleeps.All(duration => duration is > 0 and <= 100));
    intervalClock = 12000; var exhausted = RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder, 0, () => intervalClock, _ => throw new InvalidOperationException("No sleeping allowed.")); Check(exhausted.Interval is { state: "no_remaining_budget", requested_ms: 0, elapsed_ms: 0, prefix: null, wait_completed: false });
    intervalClock = 11990; var overslept = RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder, 0, () => intervalClock, duration => { Check(duration == 10); intervalClock += 25; }); Check(overslept.Interval is { state: "capture_budget_expired", end_capture_ms: 12015, requested_ms: 10, prefix: null });
    intervalClock = 0; var requestedTotal = 0; var stagnant = RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder, 0, () => intervalClock, duration => requestedTotal += duration); Check(stagnant.Interval is { state: "observation_refused", wait_completed: false, prefix: null } && requestedTotal == 5000);
    var observedPrimary = emptyPrimary;
    try { try { throw emptyPrimary; } catch (InvalidDataException original) { _ = RecorderObservation.ObserveInitialization(original, pendingRecorder, 0, () => 0, _ => throw new IOException("PRIVATE")); throw; } }
    catch (InvalidDataException original) { Check(ReferenceEquals(original, observedPrimary) && ReferenceEquals(original.Data["media_wave_observation"], retainedEmpty)); }
    var backward = RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder, 10, () => 9, _ => throw new InvalidOperationException()); Check(backward.Interval is { state: "observation_refused", start_capture_ms: null, prefix: null });
    var unknownCall = RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder with { SameCallIdentity = false }, 0, () => 10, _ => throw new InvalidOperationException()); Check(unknownCall.Interval is { state: "call_not_confirmed", requested_ms: 0, prefix: null });
    var nonzeroFailure = new InvalidDataException(); nonzeroFailure.Data["media_wave_observation"] = ((WaveReadObservation)retainedEmpty!) with { length_check_bytes = 1 };
    Check(ReferenceEquals(RecorderObservation.ObserveInitialization(nonzeroFailure, pendingRecorder, 0, () => throw new InvalidOperationException(), _ => throw new InvalidOperationException()), pendingRecorder));
    var wrongShapeFailure = new InvalidDataException(); wrongShapeFailure.Data["media_wave_observation"] = ((WaveReadObservation)retainedEmpty!) with { growing = false };
    Check(ReferenceEquals(RecorderObservation.ObserveInitialization(wrongShapeFailure, pendingRecorder, 0, () => throw new InvalidOperationException(), _ => throw new InvalidOperationException()), pendingRecorder));
    Check(ReferenceEquals(RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder, 300001, () => throw new InvalidOperationException(), _ => throw new InvalidOperationException()), pendingRecorder));
    Check(!JsonSerializer.Serialize(grown.Interval).Contains("PRIVATE", StringComparison.Ordinal));
    File.WriteAllBytes(recordPath, audioBytes); var liveFormat = RecorderObservation.ReadPrefix(recordRoot, recordPath); Check(liveFormat.sample_rate == 8000 && liveFormat.format_tag == 1 && liveFormat.data_declared_bytes == 64000 && File.ReadAllBytes(recordPath).SequenceEqual(audioBytes));
    File.WriteAllBytes(recordPath, []); Check(RecorderObservation.ReadPrefix(recordRoot, recordPath) is { header_bytes: 0, riff: null, data_declared_bytes: null });
    File.Delete(recordPath); File.CreateSymbolicLink(recordPath, single); Refuse(() => RecorderObservation.ReadPrefix(recordRoot, recordPath)); File.Delete(recordPath);
    intervalClock = 0; var missingPrefix = RecorderObservation.ObserveInitialization(emptyPrimary, pendingRecorder, 0, () => intervalClock, duration => intervalClock += duration); Check(missingPrefix.Interval is { state: "observation_refused", wait_completed: true, requested_ms: 5000, prefix: null });
    // Real readiness/wait helpers with explicit snapshot and monotonic-clock adapters.
    MediaSecurityObservation Connection(string state = "StreamsRunning", string suite = "AESCM128HMACSHA180", string encryption = "SRTP", bool tls = true, bool mandatory = true) => SecurityObservation.Capture(tls, mandatory, [SecurityObservation.Call(state, encryption, suite)], "last_connection_wait_argument");
    Check(Connection().source == "last_connection_wait_argument"); Refuse(() => SecurityObservation.Capture(true, true, [], "PRIVATE"));
    var refusal = new InvalidDataException("PRIVATE-original-security-refusal"); var refusalCount = 0;
    void OriginalRefusal(int peer) { Check(peer is 0 or 1); refusalCount++; throw refusal; }
    Check(SecurityReadiness.Ready(Connection(), () => throw new InvalidOperationException()));
    Check(!SecurityReadiness.Ready(Connection(suite: "Invalid"), () => throw new InvalidOperationException()));
    Check(!SecurityReadiness.Ready(Connection(state: "OutgoingProgress"), () => throw new InvalidOperationException()));
    Check(!SecurityReadiness.Ready(SecurityObservation.Capture(true, true, [], "last_connection_wait_argument"), () => throw new InvalidOperationException()));
    foreach (var suite in SecurityObservation.Suites.Where(value => value is not ("AESCM128HMACSHA180" or "Invalid")))
    {
        try { _ = SecurityReadiness.Ready(Connection(suite: suite), () => OriginalRefusal(0)); throw new InvalidOperationException(); }
        catch (InvalidDataException actual) { Check(ReferenceEquals(actual, refusal)); }
    }
    foreach (var encryption in SecurityObservation.Encryptions.Where(value => value != "SRTP"))
    {
        try { _ = SecurityReadiness.Ready(Connection(encryption: encryption, suite: "Invalid"), () => OriginalRefusal(1)); throw new InvalidOperationException(); }
        catch (InvalidDataException actual) { Check(ReferenceEquals(actual, refusal)); }
    }
    foreach (var invalidPolicy in new[] { Connection(tls: false), Connection(mandatory: false), Connection(state: "OutgoingProgress", tls: false) })
    {
        try { _ = SecurityReadiness.Ready(invalidPolicy, () => OriginalRefusal(0)); throw new InvalidOperationException(); }
        catch (InvalidDataException actual) { Check(ReferenceEquals(actual, refusal)); }
    }
    Refuse(() => SecurityReadiness.Ready(Connection(tls: false), () => { }));
    var mixedReadiness = SecurityObservation.Capture(true, true, [SecurityObservation.Call("Paused", "None", "Invalid"), SecurityObservation.Call("StreamsRunning", "SRTP", "AESCM128HMACSHA180")], "last_connection_wait_argument");
    Check(SecurityReadiness.Ready(mixedReadiness, () => throw new InvalidOperationException()));
    Check(!SecurityReadiness.Ready(mixedReadiness with { calls = [Connection().calls[0], Connection(suite: "Invalid").calls[0]] }, () => throw new InvalidOperationException()));
    long connectionClock = 0; var connectionSamples = 0; var waitEntries = 0; var waitObservations = 0;
    void ExistingConnectionWait(Func<bool> predicate) { waitEntries++; WaitObservation.RunCore("streams_initial", predicate, () => { waitObservations++; return Peers(); }, 20, () => connectionClock, duration => { Check(duration == 100); connectionClock += duration; }); }
    SecurityReadiness.WithinExistingWait(() => { connectionSamples++; return [Connection(state: connectionClock < 3500 ? "OutgoingProgress" : "StreamsRunning", suite: connectionClock < 5000 ? "Invalid" : "AESCM128HMACSHA180"), Connection()]; }, OriginalRefusal, ExistingConnectionWait);
    Check(connectionClock == 5000 && connectionSamples == 51 && waitEntries == 1 && waitObservations == 0);
    connectionClock = 0; connectionSamples = waitEntries = waitObservations = 0; MediaSecurityObservation? lastConnectionArgument = null;
    try
    {
        SecurityReadiness.WithinExistingWait(() => { connectionSamples++; lastConnectionArgument = Connection(state: connectionClock < 3500 ? "OutgoingProgress" : "StreamsRunning", suite: "Invalid"); return [lastConnectionArgument, Connection()]; }, OriginalRefusal, ExistingConnectionWait); throw new InvalidOperationException();
    }
    catch (TimeoutException timeout)
    {
        Check(connectionClock == 20000 && connectionSamples == 200 && waitEntries == 1 && waitObservations == 1);
        Check(ReferenceEquals(timeout.Data["media_security_observation"], lastConnectionArgument) && lastConnectionArgument!.calls[0].srtp_suite == "Invalid" && timeout.Data["media_wait_observation"] is MediaWaitObservation);
    }
    connectionClock = 0; waitEntries = waitObservations = 0; var beforeRefusal = refusalCount;
    try { SecurityReadiness.WithinExistingWait(() => [Connection(suite: "Invalid"), Connection(suite: "AESCM128HMACSHA132")], OriginalRefusal, ExistingConnectionWait); throw new InvalidOperationException(); }
    catch (InvalidDataException actual) { Check(ReferenceEquals(actual, refusal) && connectionClock == 0 && waitEntries == 1 && refusalCount == beforeRefusal + 1); }
    connectionClock = 19900; waitEntries = waitObservations = 0;
    try { SecurityReadiness.WithinExistingWait(() => [Connection(suite: "Invalid"), Connection()], OriginalRefusal, ExistingConnectionWait); throw new InvalidOperationException(); }
    catch (TimeoutException timeout) { Check(connectionClock == 20000 && waitEntries == 1 && timeout.Data["media_security_observation"] is MediaSecurityObservation); }
    Refuse(() => SecurityReadiness.WithinExistingWait(() => [Connection()], OriginalRefusal, predicate => predicate()));
    var productionAbsence = false;
    if (args.Length != 0)
    {
        if (args.Length != 2 || args[0] != "--production-windows-assembly") throw new InvalidDataException("Explicit production assembly argument required.");
        using var stream = File.OpenRead(args[1]); using var pe = new PEReader(stream); var metadata = pe.GetMetadataReader();
        var types = metadata.TypeDefinitions.Select(handle => metadata.GetString(metadata.GetTypeDefinition(handle).Name)).ToHashSet(StringComparer.Ordinal);
        var methods = metadata.MethodDefinitions.Select(handle => metadata.GetString(metadata.GetMethodDefinition(handle).Name)).ToHashSet(StringComparer.Ordinal);
        var fields = metadata.FieldDefinitions.Select(handle => metadata.GetString(metadata.GetFieldDefinition(handle).Name)).ToHashSet(StringComparer.Ordinal);
        Check(types.Contains("NativePhone")); foreach (var type in new[] { "NativeMediaFixture", "NativeMediaCallSignal", "NativeFixtureSnapshot", "NativeMediaCallSnapshot", "NativeLocalPlaybackSnapshot" }) Check(!types.Contains(type));
        foreach (var method in new[] { "ConfigureMediaFixture", "FixtureSnapshot", "FixturePlaybackSnapshot", "FixtureStartConferenceRecording", "FixtureStopConferenceRecording" }) Check(!methods.Contains(method));
        foreach (var field in new[] { "mediaFixture", "mediaSignals", "decodedFrames", "receivedDtmf", "rearmFrames" }) Check(!fields.Contains(field)); productionAbsence = true;
    }
    Console.WriteLine(JsonSerializer.Serialize(new { schema = 1, state = "passed_pure_audio_codec_diagnostic_and_process_identity_components", production_fixture_absence_checked = productionAbsence, checks, actual_native_calling = false, hardware_media_tested = false, codec_inventory_input = "explicit_model" }));
}
finally { Directory.Delete(root, true); }
