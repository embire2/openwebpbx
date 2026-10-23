// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Diagnostics;
namespace OpenWebPbx.Phone.MediaChecks;

internal sealed record MediaWaitSignal(int state, int reason, int protocol_code, bool observed);
internal sealed record MediaWaitState(bool ready, bool registration_failed, bool busy, int call_count, string[] states, MediaWaitSignal[] signals);
internal sealed record MediaWaitPeer(int position, bool observed, MediaWaitState? state);
internal sealed record MediaWaitObservation(string name, int deadline_seconds, MediaWaitPeer[] peers);
internal static class WaitObservation
{
    internal static readonly string[] Names = ["wrong_ca_refused", "wrong_name_refused", "registrations_ready", "incoming_initial", "streams_initial", "incoming_voicemail", "streams_voicemail", "incoming_blind", "streams_blind", "incoming_consultation", "streams_consultation", "incoming_waiting", "streams_waiting", "voicemail_playing", "voicemail_incoming", "voicemail_removed", "update_idle", "held", "resumed", "dtmf_received", "blind_original_ended", "consult_completed", "consult_cancelled", "waiting_original_resumed", "conference_merged"];
    internal static readonly string[] States = ["Idle", "IncomingReceived", "PushIncomingReceived", "OutgoingInit", "OutgoingProgress", "OutgoingRinging", "OutgoingEarlyMedia", "Connected", "StreamsRunning", "Pausing", "Paused", "Resuming", "Referred", "Error", "End", "PausedByRemote", "UpdatedByRemote", "IncomingEarlyMedia", "Updating", "Released", "EarlyUpdatedByRemote", "EarlyUpdating"];
    internal static MediaWaitObservation Require(MediaWaitObservation value)
    {
        if (!Names.Contains(value.name, StringComparer.Ordinal) || value.deadline_seconds is not (8 or 20) || value.peers.Length is < 1 or > 3) throw new InvalidDataException("Closed wait observation required.");
        for (var index = 0; index < value.peers.Length; index++)
        {
            var peer = value.peers[index]; if (peer.position != index || peer.observed != (peer.state is not null)) throw new InvalidDataException("Observed peer scope differs.");
            if (peer.state is not { } state) continue;
            if (state.call_count is < 0 or > 2 || state.states.Length != state.call_count || state.states.Any(s => !States.Contains(s, StringComparer.Ordinal)) || state.signals.Length > 32) throw new InvalidDataException("Bounded native call state required.");
            foreach (var signal in state.signals)
                if (signal.observed ? signal.state is < 0 or > 21 || signal.reason is < 0 or > 25 || signal.protocol_code is < -1 or > 699 : signal.state != -1 || signal.reason != -1 || signal.protocol_code != -1) throw new InvalidDataException("Closed native call signal required.");
        }
        return value;
    }
    internal static void Run(string name, Func<bool> predicate, Func<MediaWaitPeer[]> observe, int seconds)
    {
        var clock = Stopwatch.StartNew(); RunCore(name, predicate, observe, seconds, () => clock.ElapsedMilliseconds, Thread.Sleep);
    }
    internal static void RunCore(string name, Func<bool> predicate, Func<MediaWaitPeer[]> observe, int seconds, Func<long> elapsed, Action<int> sleep)
    {
        if (!Names.Contains(name, StringComparer.Ordinal) || seconds is not (8 or 20)) throw new InvalidDataException("Exact native wait identity and deadline required.");
        try
        {
            while (elapsed() < seconds * 1000L) { if (predicate()) return; sleep(100); }
            throw new TimeoutException("The actual native call transition did not complete.");
        }
        catch (Exception error)
        {
            try { error.Data["media_wait_observation"] = Require(new(name, seconds, observe())); } catch { }
            throw;
        }
    }
}
