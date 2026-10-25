// SPDX-License-Identifier: AGPL-3.0-or-later
// Analyses decoded file output. It does not infer sound-device or RTP acceptance.
using System.Buffers.Binary;
using System.Text;
namespace OpenWebPbx.Phone.MediaChecks;

internal sealed record AudioWindow(double StartSeconds, double Seconds, double MinimumToneRatio, double MinimumRms, double GoodFraction);
internal sealed record WaveReadObservation(string reason, string source, bool growing, bool snapshot_atomic,
    long length_check_bytes, int buffer_bytes, bool? riff, bool? wave, long? riff_declared_bytes,
    string chunk, int chunk_offset, long? chunk_declared_bytes, long? chunk_effective_bytes,
    int? format_tag, int? channels, long? sample_rate, int? sample_bits, int? alignment, long? byte_rate,
    bool format_seen, bool data_seen, int data_bytes);
internal sealed class PcmWave
{
    public int Rate { get; }
    public double[] Samples { get; }
    public double Duration => (double)Samples.Length / Rate;
    private PcmWave(int rate, double[] samples) { Rate = rate; Samples = samples; }
    public static PcmWave Read(string path, bool growing = false)
    {
        byte[]? bytes = null; long lengthCheck = -1; var reason = "file_length"; var chunk = "none"; var chunkOffset = -1;
        long? declared = null, effective = null; int? formatTag = null, observedChannels = null, sampleBits = null, observedAlignment = null;
        long? sampleRate = null, byteRate = null; bool format = false; int dataAt = -1, dataLength = 0;
        try
        {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, growing ? FileShare.ReadWrite : FileShare.Read);
        if ((lengthCheck = input.Length) is < 44 or > 128 * 1024 * 1024) throw new InvalidDataException("Bounded decoded WAV required.");
        bytes = new byte[checked((int)input.Length)]; input.ReadExactly(bytes);
        reason = "riff_wave_shape";
        if (!bytes.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !bytes.AsSpan(8, 4).SequenceEqual("WAVE"u8) || (!growing && BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(4)) + 8L != bytes.Length)) throw new InvalidDataException("Exact RIFF/WAVE shape required.");
        int rate = 0, channels = 0, alignment = 0;
        for (var at = 12; at < bytes.Length;)
        {
            reason = "chunk_header"; chunkOffset = at; chunk = "none"; declared = effective = null;
            if (at + 8 > bytes.Length) throw new InvalidDataException("Incomplete WAV chunk.");
            var length = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(at + 4)); var start = at + 8;
            declared = length; chunk = bytes.AsSpan(at, 4).SequenceEqual("fmt "u8) ? "fmt" : bytes.AsSpan(at, 4).SequenceEqual("data"u8) ? "data" : "other";
            // Explicit file-media observation adapter: an open native WAV commonly
            // leaves RIFF/data lengths unfinished. Snapshot only the bytes already
            // read, never manufacture samples or change the writer's file.
            if (growing && bytes.AsSpan(at, 4).SequenceEqual("data"u8))
            {
                reason = "terminal_data_shape";
                if (!format || dataAt != -1) throw new InvalidDataException("Unique terminal PCM data required.");
                length = checked((uint)(bytes.Length - start));
            }
            effective = length; reason = "chunk_length";
            if (length > bytes.Length - start) throw new InvalidDataException("WAV chunk exceeds file.");
            if (bytes.AsSpan(at, 4).SequenceEqual("fmt "u8))
            {
                reason = "pcm_format";
                if (length >= 16 && start + 16 <= bytes.Length) { formatTag = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(start)); observedChannels = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(start + 2)); sampleRate = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(start + 4)); byteRate = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(start + 8)); observedAlignment = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(start + 12)); sampleBits = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(start + 14)); }
                if (format || length < 16 || length > 256 || BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(start)) != 1 || BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(start + 14)) != 16) throw new InvalidDataException("Unique PCM16 format required.");
                channels = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(start + 2)); rate = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(start + 4))); alignment = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(start + 12));
                reason = "pcm_layout";
                if (channels is < 1 or > 2 || rate is < 8000 or > 48000 || alignment != channels * 2 || BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(start + 8)) != rate * alignment) throw new InvalidDataException("PCM rate/channels differ.");
                format = true;
            }
            if (bytes.AsSpan(at, 4).SequenceEqual("data"u8)) { reason = "duplicate_data"; if (dataAt != -1) throw new InvalidDataException("Duplicate audio data."); dataAt = start; dataLength = checked((int)length); }
            reason = "chunk_padding"; at = checked(start + (int)length + (int)(length & 1)); if (at > bytes.Length) throw new InvalidDataException("Missing WAV padding.");
        }
        reason = "decoded_samples";
        if (!format || dataAt < 0 || dataLength % alignment != 0 || dataLength == 0) throw new InvalidDataException("Complete decoded samples required.");
        var samples = new double[dataLength / alignment];
        for (var n = 0; n < samples.Length; n++) { double value = 0; for (var channel = 0; channel < channels; channel++) value += BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(dataAt + n * alignment + channel * 2)); samples[n] = value / channels; }
        return new(rate, samples);
        }
        catch (InvalidDataException error)
        {
            // This is the exact buffer used by the failed read. No observer reopens
            // the growing file; a concurrent writer means it is not an atomic snapshot.
            try { error.Data["media_wave_observation"] = new WaveReadObservation(reason, bytes is null ? "file_length_check" : "failed_read_buffer", growing, false,
                lengthCheck, bytes?.Length ?? 0, bytes is { Length: >= 4 } ? bytes.AsSpan(0, 4).SequenceEqual("RIFF"u8) : null,
                bytes is { Length: >= 12 } ? bytes.AsSpan(8, 4).SequenceEqual("WAVE"u8) : null,
                bytes is { Length: >= 8 } ? BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(4)) : null,
                chunk, chunkOffset, declared, effective, formatTag, observedChannels, sampleRate, sampleBits, observedAlignment, byteRate, format, dataAt >= 0, dataLength); } catch { }
            throw;
        }
    }
    public static void Write(string path, IReadOnlyList<double> frequencies, double seconds = 120, int rate = 8000, double amplitude = .25)
    {
        if (frequencies.Count is < 1 or > 3 || frequencies.Any(f => !double.IsFinite(f) || f < 200 || f > 3000) || !double.IsFinite(seconds) || seconds is <= 0 or > 150 || rate != 8000 || amplitude is <= 0 or > .9) throw new ArgumentOutOfRangeException(nameof(frequencies));
        var count = checked((int)(seconds * rate)); using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None); using var writer = new BinaryWriter(file, Encoding.ASCII, true);
        writer.Write("RIFF"u8); writer.Write(36 + count * 2); writer.Write("WAVEfmt "u8); writer.Write(16); writer.Write((short)1); writer.Write((short)1); writer.Write(rate); writer.Write(rate * 2); writer.Write((short)2); writer.Write((short)16); writer.Write("data"u8); writer.Write(count * 2);
        for (var n = 0; n < count; n++) writer.Write((short)Math.Round(32767 * amplitude * frequencies.Sum(f => Math.Sin(2 * Math.PI * f * n / rate)) / frequencies.Count));
        writer.Flush(); file.Flush(true);
    }
    private (double Ratio, double Rms, bool Good) Frame(int start, int length, IReadOnlyList<double> tones)
    {
        double sum = 0, energy = 0; var clipped = 0; for (var n = 0; n < length; n++) sum += Samples[start + n]; var mean = sum / length;
        for (var n = 0; n < length; n++) { var value = Samples[start + n] - mean; energy += value * value; if (Math.Abs(Samples[start + n]) >= 32700) clipped++; }
        var rms = Math.Sqrt(energy / length); var ratios = new List<double>();
        foreach (var tone in tones)
        {
            double sine = 0, cosine = 0; for (var n = 0; n < length; n++) { var value = Samples[start + n] - mean; var angle = 2 * Math.PI * tone * n / Rate; sine += value * Math.Sin(angle); cosine += value * Math.Cos(angle); }
            ratios.Add(energy == 0 ? 0 : Math.Min(1, 2 * (sine * sine + cosine * cosine) / (length * energy)));
        }
        var combined = ratios.Sum(); var good = double.IsFinite(combined) && rms >= 500 && clipped <= length / 1000 && combined >= .65 && (tones.Count == 1 || ratios.All(value => value >= .12));
        return (combined, rms, good);
    }
    public AudioWindow Find(IReadOnlyList<double> tones, double seconds = 3, double after = 0)
    {
        if (tones.Count is < 1 or > 3 || tones.Any(value => !double.IsFinite(value) || value < 200 || value > 3000) || !double.IsFinite(after) || !double.IsFinite(seconds) || after < 0 || seconds < 2 || seconds > 10) throw new ArgumentOutOfRangeException(nameof(tones));
        var frame = Rate / 10; var frames = checked((int)Math.Ceiling(seconds * 10)); var startFrame = checked((int)Math.Ceiling(after * 10)); var total = Samples.Length / frame;
        for (var start = startFrame; start + frames <= total; start++)
        {
            var measured = Enumerable.Range(start, frames).Select(n => Frame(n * frame, frame, tones)).ToArray(); var good = measured.Count(value => value.Good);
            if (good != frames) continue;
            return new((double)start / 10, (double)frames / 10, measured.Min(value => value.Ratio), measured.Min(value => value.Rms), (double)good / frames);
        }
        throw new InvalidDataException("Sustained independently decoded audio did not meet its window.");
    }
    public AudioWindow Tail(IReadOnlyList<double> tones, double seconds = 3)
    {
        if (Duration < seconds + .2) throw new InvalidDataException("A continuous current decoded window is unavailable.");
        // Exclude the final 100 ms that may be concurrently appended. All preceding
        // 100 ms blocks in the requested window must satisfy the actual decoder.
        var after = Math.Floor((Duration - seconds - .1) * 10) / 10;
        return Find(tones, seconds, after);
    }
}
