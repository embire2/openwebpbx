// SPDX-License-Identifier: AGPL-3.0-or-later
using OpenWebPbx.Phone.MediaChecks;
using System.Text.Json;
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
    Console.WriteLine(JsonSerializer.Serialize(new { schema = 1, state = "passed_pure_audio_codec_and_diagnostic_components", checks, actual_native_calling = false, hardware_media_tested = false, codec_inventory_input = "explicit_model" }));
}
finally { Directory.Delete(root, true); }
