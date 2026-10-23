// SPDX-License-Identifier: AGPL-3.0-or-later
// Failure-only observation. This never supplies audio samples to acceptance.
using System.Buffers.Binary;
using System.Security.Cryptography;
namespace OpenWebPbx.Phone.MediaChecks;
internal sealed record RecorderPayload(string state, string codec, int clock_rate, int channels);
internal sealed record RecorderClosedFile(string phase, long length_bytes, string sha256, int header_bytes,
    bool? riff, bool? wave, bool? format, bool? data, long? riff_declared_bytes, long? format_declared_bytes,
    int? format_tag, int? channels, long? sample_rate, long? byte_rate, int? alignment, int? sample_bits,
    long? data_declared_bytes, long? bytes_after_fixed_header);
internal sealed record RecorderPrefix(long length_before_bytes, long length_after_bytes, int header_bytes,
    bool? riff, bool? wave, bool? format, bool? data, long? riff_declared_bytes, long? format_declared_bytes,
    int? format_tag, int? channels, long? sample_rate, long? byte_rate, int? alignment, int? sample_bits,
    long? data_declared_bytes);
internal sealed record RecorderInterval(string phase, bool snapshot_atomic, string state, long failure_capture_ms,
    long? start_capture_ms, long? end_capture_ms, long? elapsed_ms, int requested_ms, bool wait_completed, RecorderPrefix? prefix);
internal sealed record MediaRecorderObservation(string scope, string recording, string payload_phase,
    bool payload_observed, bool same_call_identity, int call_count, RecorderPayload[] calls,
    bool owned_peers_closed, string file_observation, RecorderClosedFile? closed_file, RecorderInterval? initialization_interval);
internal sealed record PendingRecorderObservation(string Root, string Path, string Recording,
    bool PayloadObserved, bool SameCallIdentity, RecorderPayload[] Calls, RecorderInterval? Interval = null);
internal static class RecorderObservation
{
    internal const int Maximum = 128 * 1024 * 1024;
    internal static readonly string[] Codecs = ["PCMU", "PCMA", "opus", "G722", "G729", "speex", "L16", "none", "unrecognised"];
    internal static RecorderPayload Payload(string state, string codec, int rate, int channels) => new(
        WaitObservation.States.Contains(state, StringComparer.Ordinal) ? state : "unrecognised",
        Codecs.Contains(codec, StringComparer.Ordinal) ? codec : "unrecognised",
        rate is >= 0 and <= 192000 ? rate : 0, channels is >= 0 and <= 8 ? channels : 0);
    internal static PendingRecorderObservation Pending(string root, string path, bool observed, bool same, RecorderPayload[] calls)
    {
        if (!Path.IsPathFullyQualified(root) || !Path.IsPathFullyQualified(path) || calls.Length > 2 || (!observed && (same || calls.Length != 0)) || (same && calls.Length == 0) || calls.Any(call => call != Payload(call.state, call.codec, call.clock_rate, call.channels))) throw new InvalidDataException("Recorder observation scope differs.");
        var fullRoot = Path.GetFullPath(root); var full = Path.GetFullPath(path);
        var name = Path.GetFileName(full);
        if (Path.GetDirectoryName(full) != fullRoot || name is not ("output.wav" or "conference.wav")) throw new InvalidDataException("Exact owned recorder output required.");
        return new(fullRoot, full, name == "output.wav" ? "receive_output" : "conference_mix", observed, same, calls);
    }
    internal static MediaRecorderObservation Complete(PendingRecorderObservation pending, bool closed)
    {
        RecorderClosedFile? file = null; var result = closed ? "read_refused" : "peers_not_closed";
        if (closed) try { file = ReadClosed(pending.Root, pending.Path); result = "observed"; } catch { }
        return new("failed_capture_same_owned_recorder", pending.Recording, "after_failed_read_before_cleanup",
            pending.PayloadObserved, pending.SameCallIdentity, pending.Calls.Length, pending.Calls, closed, result, file, pending.Interval);
    }
    internal static PendingRecorderObservation ObserveInitialization(Exception primary, PendingRecorderObservation pending,
        long failedElapsed, Func<long> elapsed, Action<int> sleep)
    {
        // Only the exact already-retained zero-byte failure enables diagnostic waiting.
        // No parser retry, audio acceptance or native call operation occurs here.
        var empty = new WaveReadObservation("file_length", "file_length_check", true, false, 0, 0,
            null, null, null, "none", -1, null, null, null, null, null, null, null, null, false, false, 0);
        if (primary is not InvalidDataException || primary.Data["media_wave_observation"] is not WaveReadObservation failure || failure != empty || failedElapsed is < 0 or > 300000) return pending;
        long? start = null, end = null; int requested = 0; bool completed = false; RecorderPrefix? prefix = null; var state = "observation_refused";
        try
        {
            long Clock(long previous) { var value = elapsed(); if (value < previous || value > 300000) throw new InvalidDataException("Diagnostic clock differs."); return value; }
            start = Clock(failedElapsed); end = start;
            if (!pending.PayloadObserved || !pending.SameCallIdentity) state = "call_not_confirmed";
            else if (start >= 12000) state = "no_remaining_budget";
            else
            {
                requested = (int)Math.Min(5000, 12000 - start.Value); var deadline = start.Value + requested; var requestedSleep = 0; var current = start.Value;
                while (current < deadline)
                {
                    var duration = (int)Math.Min(100, Math.Min(deadline - current, requested - requestedSleep));
                    if (duration <= 0) throw new InvalidDataException("Diagnostic clock did not advance.");
                    sleep(duration); requestedSleep += duration; current = Clock(current); end = current;
                }
                completed = true;
                // Scheduler overshoot is retained honestly and never buys extra budget.
                if (current > 12000) state = "capture_budget_expired";
                else { var captured = ReadPrefix(pending.Root, pending.Path); end = Clock(current); prefix = captured; state = "observed"; }
            }
        }
        catch { }
        return pending with { Interval = new("before_owned_peer_shutdown", false, state, failedElapsed,
            start, end, start is not null && end is not null ? end.Value - start.Value : null, requested, completed, prefix) };
    }
    internal static RecorderPrefix ReadPrefix(string root, string path)
    {
        _ = Pending(root, path, false, false, []);
        for (var directory = new DirectoryInfo(root); directory is not null; directory = directory.Parent)
            if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Recorder ancestry differs.");
        if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw new InvalidDataException("Recorder output differs.");
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var before = input.Length; if (before is < 0 or > Maximum) throw new InvalidDataException("Recorder observation exceeds bound.");
        var header = new byte[(int)Math.Min(44, before)]; input.ReadExactly(header);
        var after = input.Length; if (after is < 0 or > Maximum) throw new InvalidDataException("Recorder observation exceeds bound.");
        bool? Marker(int offset, ReadOnlySpan<byte> expected) => header.Length >= offset + 4 ? header.AsSpan(offset, 4).SequenceEqual(expected) : null;
        var riff = Marker(0, "RIFF"u8); var wave = Marker(8, "WAVE"u8); var format = Marker(12, "fmt "u8); var data = Marker(36, "data"u8);
        var completeFormat = riff == true && wave == true && format == true && header.Length >= 36;
        return new(before, after, header.Length, riff, wave, format, data,
            riff == true && header.Length >= 8 ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(16)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(20)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(22)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(24)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(28)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(32)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(34)) : null,
            riff == true && wave == true && data == true && header.Length == 44 ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(40)) : null);
    }
    internal static RecorderClosedFile ReadClosed(string root, string path)
    {
        _ = Pending(root, path, false, false, []);
        for (var directory = new DirectoryInfo(root); directory is not null; directory = directory.Parent)
            if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Recorder ancestry differs.");
        if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw new InvalidDataException("Recorder output differs.");
        // Exclusive against writers: never reinterpret this as a live snapshot.
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var length = input.Length; if (length is < 0 or > Maximum) throw new InvalidDataException("Recorder observation exceeds bound.");
        var header = new byte[(int)Math.Min(44, length)]; input.ReadExactly(header); input.Position = 0;
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256); var buffer = new byte[8192]; long remaining = length;
        while (remaining > 0) { var read = input.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining)); if (read == 0) throw new EndOfStreamException(); hash.AppendData(buffer, 0, read); remaining -= read; }
        if (input.ReadByte() != -1 || input.Length != length) throw new InvalidDataException("Closed recorder changed during observation.");
        bool? Marker(int offset, ReadOnlySpan<byte> expected) => header.Length >= offset + 4 ? header.AsSpan(offset, 4).SequenceEqual(expected) : null;
        var riff = Marker(0, "RIFF"u8); var wave = Marker(8, "WAVE"u8); var format = Marker(12, "fmt "u8); var data = Marker(36, "data"u8);
        var completeFormat = riff == true && wave == true && format == true && header.Length >= 36;
        return new("after_owned_peer_shutdown", length, Convert.ToHexStringLower(hash.GetHashAndReset()), header.Length,
            riff, wave, format, data, riff == true && header.Length >= 8 ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(16)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(20)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(22)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(24)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(28)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(32)) : null,
            completeFormat ? BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(34)) : null,
            riff == true && wave == true && data == true && header.Length == 44 ? BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(40)) : null,
            riff == true && wave == true && data == true && header.Length == 44 ? length - 44 : null);
    }
}
