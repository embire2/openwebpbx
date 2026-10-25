// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
namespace OpenWebPbx.Phone.MediaChecks;
internal sealed record LabInput(int Schema, string Root, string EngineRoot, string SourceCommit, string SdkSha256, string EngineSha256, string ImageA, string ImageB, string RunId);
internal sealed record AudioObservation(AudioWindow Window, double FreshSeconds, double ObservedSeconds);
internal sealed class LabPeer : IDisposable
{
    private readonly Process process; private readonly Task<(string Type, bool Observed)> errors; private int sequence; private readonly DateTime start; private bool disposed;
    private string progress = "none"; private readonly string executableHash;
    internal static bool CleanupRefused { get; private set; }
    public PeerState State { get; private set; } = null!;
    public string Root { get; }
    public string Output => Path.Combine(Root, "output.wav");
    public int ProcessId => process.Id;
    public LabPeer(PeerInput input, string journal)
    {
        Root = input.Root; var path = Path.Combine(Root, "peer.json"); Protocol.Write(path, input);
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException();
        if (!exe.EndsWith("OpenWebPbx.Phone.MediaChecks.exe", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Run the published native fixture.");
        executableHash = ProcessImage.HashFile(exe);
        var info = new ProcessStartInfo(exe) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = AppContext.BaseDirectory, CreateNoWindow = true };
        info.ArgumentList.Add("--peer"); info.ArgumentList.Add(path); process = Process.Start(info) ?? throw new InvalidOperationException(); start = process.StartTime.ToUniversalTime(); errors = Protocol.PeerError(process.StandardError);
        var end = DateTime.UtcNow.AddSeconds(60);
        try
        {
        Protocol.Own(process, "peer", journal, exe, start, executableHash);
        while (DateTime.UtcNow < end)
        {
            var reply = Receive(end - DateTime.UtcNow); if (reply.Sequence != 0 || !reply.Ok) throw new InvalidDataException("Native startup control failed.");
            progress = FailureObservation.Progress.Contains(reply.Stage, StringComparer.Ordinal) ? reply.Stage : "unrecognised";
            if (reply.Stage == "ready") { State = reply.State ?? throw new InvalidDataException(); return; }
            if (!reply.Stage.StartsWith("native_", StringComparison.Ordinal) || reply.Stage.Length > 80) throw new InvalidDataException("Native startup progress differs.");
        }
        throw new TimeoutException("Native peer startup deadline.");
        }
        catch (Exception error) { ObserveFailure(error); try { StopOwned(); } catch { CleanupRefused = true; } FinishFailureObservation(error); process.Dispose(); disposed = true; throw; }
    }
    private void ObserveFailure(Exception error)
    {
        try { var exited = process.HasExited; error.Data["media_peer_observation"] = new PeerFailureObservation(progress, exited, exited ? process.ExitCode : null, "unobserved", false); } catch { }
    }
    private void FinishFailureObservation(Exception error)
    {
        try { if (error.Data["media_peer_observation"] is PeerFailureObservation observed && process.HasExited) { var captured = errors.WaitAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult(); error.Data["media_peer_observation"] = observed with { error_type = captured.Type, stderr_observed = captured.Observed }; } } catch { }
    }
    private PeerReply Receive(TimeSpan timeout)
    {
        var line = process.StandardOutput.ReadLineAsync().WaitAsync(timeout).GetAwaiter().GetResult();
        if (line is null || line.Length > 32768) throw new InvalidDataException("Native peer ended or exceeded output bound.");
        return JsonSerializer.Deserialize<PeerReply>(line, Protocol.Json) ?? throw new InvalidDataException();
    }
    public PeerState Command(string action = "snapshot", string number = "", Guid? call = null, bool video = false)
    {
        process.StandardInput.WriteLine(JsonSerializer.Serialize(new PeerCommand(++sequence, action, number, call, video), Protocol.Json)); process.StandardInput.Flush();
        try { var reply = Receive(TimeSpan.FromSeconds(12));
        if (reply.Sequence != sequence || !reply.Ok || reply.State is null) throw new InvalidDataException("Actual NativePhone operation refused: " + action);
        State = reply.State; return State; }
        catch (Exception error) { ObserveFailure(error); FinishFailureObservation(error); throw; }
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        try
        {
            if (!process.HasExited) { foreach (var call in Command().Calls) Command("hangup", call: call.Id); var end = DateTime.UtcNow.AddSeconds(8); while (Command().Busy && DateTime.UtcNow < end) Thread.Sleep(50); Command("shutdown"); process.StandardInput.Close(); if (!process.WaitForExit(12000)) throw new TimeoutException("Owned peer shutdown timed out."); }
            errors.GetAwaiter().GetResult(); if (process.ExitCode != 0) throw new InvalidDataException("Owned native peer did not exit cleanly.");
        }
        catch (Exception error) { ObserveFailure(error); FinishFailureObservation(error); throw; }
        finally
        {
            StopOwned();
            process.Dispose();
        }
    }
    private void StopOwned()
    {
        if (!process.HasExited) { ProcessImage.Require(process, Environment.ProcessPath ?? throw new InvalidOperationException(), start, executableHash); process.Kill(true); if (!process.WaitForExit(10000)) throw new TimeoutException("Owned peer termination failed."); }
    }
}
internal static class LabCoordinator
{
    internal static void PrivateDirectory(string path)
    {
        if (Directory.Exists(path) || File.Exists(path)) throw new InvalidDataException("Only a fresh owned directory is allowed.");
        Directory.CreateDirectory(path); var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { WindowsIdentity.GetCurrent().User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) }) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(acl);
    }
    private static void Wait(string name, Func<bool> predicate, LabPeer[] observed, int seconds = 20)
    {
        WaitObservation.Run(name, predicate, () => observed.Select((peer, index) =>
        {
            try { var state = peer.Command(); return new MediaWaitPeer(index, true, new(state.Ready, state.RegistrationFailed, state.Busy, state.Calls.Length, state.Calls.Select(call => call.State).ToArray(), state.Native.Signals.Select(signal => new MediaWaitSignal(signal.State, signal.Reason, signal.ProtocolCode, signal.Observed)).ToArray())); }
            catch { return new MediaWaitPeer(index, false, null); }
        }).ToArray(), seconds);
    }
    private static void Secure(PeerState state)
    {
        if (!state.Native.TlsCaAndHostname || !state.Native.MandatorySrtp || state.Native.Calls.Any(call => call.State == "StreamsRunning" && (call.Encryption != "SRTP" || call.SrtpSuite != "AESCM128HMACSHA180"))) {
            var error = new InvalidDataException("Actual TLS/SRTP state differs.");
            try { error.Data["media_security_observation"] = SecurityObservation.Capture(state.Native.TlsCaAndHostname, state.Native.MandatorySrtp, state.Native.Calls.Select(call => SecurityObservation.Call(call.State, call.Encryption, call.SrtpSuite)).ToArray()); } catch { }
            throw error;
        }
    }
    private static void Connected(LabPeer a, LabPeer b, bool video = false, string phase = "initial")
    {
        Wait("incoming_" + phase, () => b.Command().Calls.Any(call => call.Incoming && call.State == "IncomingReceived"), [a, b]); b.Command("answer", call: b.State.Calls.Single(call => call.Incoming && call.State == "IncomingReceived").Id, video: video);
        MediaSecurityObservation Snapshot(LabPeer peer)
        {
            var state = peer.Command().Native;
            return SecurityObservation.Capture(state.TlsCaAndHostname, state.MandatorySrtp, state.Calls.Select(call => SecurityObservation.Call(call.State, call.Encryption, call.SrtpSuite)).ToArray(), "last_connection_wait_argument");
        }
        SecurityReadiness.WithinExistingWait(() => [Snapshot(a), Snapshot(b)], index => Secure(index == 0 ? a.State : b.State),
            predicate => Wait("streams_" + phase, predicate, [a, b]));
        Secure(a.State); Secure(b.State);
    }
    private static AudioObservation Capture(LabPeer peer, double[] frequencies, string? recording = null)
    {
        // The observation is made while this phase is stable. Require at least 3.3
        // seconds of NEW decoded samples, then a completely good current 3 s tail.
        // Resets restart the observation; an old final WAV never qualifies it.
        var timer = Stopwatch.StartNew(); double? baseline = null; var previous = 0d;
        var observedCallIds = peer.State.Native.Calls.Select(call => call.Id).Order().ToArray();
        while (timer.Elapsed.TotalSeconds < 12)
        {
            try
            {
                var wave = PcmWave.Read(recording ?? peer.Output, true);
                if (baseline is null || wave.Duration < previous) baseline = wave.Duration;
                previous = wave.Duration;
                if (wave.Duration - baseline.Value >= 3.3 && timer.Elapsed.TotalSeconds >= 3.3) return new(wave.Tail(frequencies), wave.Duration - baseline.Value, timer.Elapsed.TotalSeconds);
            }
            catch (InvalidDataException error) when (error.Data["media_wave_observation"] is WaveReadObservation)
            {
                var failedElapsed = timer.ElapsedMilliseconds;
                // Observe only after the original exact read has failed. No retry,
                // changed acceptance or new call/recorder operation follows here.
                try
                {
                    var observed = false; var same = false; RecorderPayload[] payloads = [];
                    try { var current = peer.Command("recorder_payload").Native.Calls; observed = true; same = observedCallIds.Length > 0 && observedCallIds.SequenceEqual(current.Select(call => call.Id).Order()); payloads = current.Select(call => RecorderObservation.Payload(call.State, call.AudioCodec, call.AudioClockRate, call.AudioChannels)).ToArray(); } catch { }
                    var pending = RecorderObservation.Pending(peer.Root, recording ?? peer.Output, observed, same, payloads);
                    error.Data["media_recorder_pending"] = RecorderObservation.ObserveInitialization(error, pending, failedElapsed, () => timer.ElapsedMilliseconds, Thread.Sleep);
                }
                catch { }
                throw;
            }
            catch (IOException) { }
            Thread.Sleep(100);
        }
        throw new InvalidDataException("Fresh sustained decoded audio missing in the current call phase.");
    }
    private static void Pair(Dictionary<string, object> facts, string phase, LabPeer a, double[] aTones, LabPeer b, double[] bTones)
    {
        facts[phase + "_left"] = Capture(a, aTones); facts[phase + "_right"] = Capture(b, bTones); Secure(a.Command()); Secure(b.Command());
    }
    private static bool StopPeers(List<LabPeer> peers)
    {
        var clean = true; foreach (var peer in peers) { try { peer.Dispose(); } catch { clean = false; } } peers.Clear(); return clean;
    }
    internal static int Run(string inputPath, string reportPath)
    {
        Protocol.Guard(); var own = Protocol.InputScope(inputPath, "phone-client-media-", "lab.json"); var input = Protocol.Read<LabInput>(inputPath, 16384);
        if (!string.Equals(Path.GetFullPath(reportPath), Path.Combine(own, "media.json"), StringComparison.OrdinalIgnoreCase) || !string.Equals(Path.GetFullPath(input.EngineRoot), Path.Combine(own, "msi", "core"), StringComparison.OrdinalIgnoreCase) || !string.Equals(Path.GetFullPath(input.ImageA), Path.Combine(own, "frame1.jpg"), StringComparison.OrdinalIgnoreCase) || !string.Equals(Path.GetFullPath(input.ImageB), Path.Combine(own, "frame2.jpg"), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Exact owned media paths are required.");
        if (input.Schema != 1 || input.SdkSha256 != "9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297" || input.EngineSha256 != "3d4091bd972c1ea82ff9b6899c091dbeebf66416d6d76475add523ebe10a7542" || !System.Text.RegularExpressions.Regex.IsMatch(input.SourceCommit, "^[a-f0-9]{40}$")) throw new InvalidDataException("Pinned media inputs differ.");
        var temp = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP")!); var root = Path.GetFullPath(input.Root);
        if (!string.Equals(root, own, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Owned media lab root differs.");
        if (input.RunId != Environment.GetEnvironmentVariable("GITHUB_RUN_ID") || !System.Text.RegularExpressions.Regex.IsMatch(input.RunId, "^[1-9][0-9]{0,19}$")) throw new InvalidDataException("Exact hosted run binding required.");
        EngineObservation? engineObservation = null;
        var cases = new List<object>(); var stage = "engine_start"; var operation = "engine_construct"; Exception? failure = null; bool cleanup = true; bool engineStarted = false, engineStopped = false;
        var peers = new List<LabPeer>(); var peerRoots = new List<string>(); LabServer? server = null;
        try
        {
            var journal = Path.Combine(root, "owned-processes.jsonl"); using (var file = new FileStream(journal, FileMode.CreateNew)) file.Flush(true);
            server = new LabServer(root, input.EngineRoot, journal); operation = "engine_start"; server.Start(); engineStarted = true;
            foreach (var name in new[] { "tls_chain_hostname", "outgoing_audio", "incoming_audio", "hold_music_resume", "dtmf", "blind_transfer", "consult_complete", "consult_cancel", "call_waiting", "local_conference", "software_vp8", "voicemail_local_player" })
            {
                stage = name; operation = "case_prepare"; server.BeginCase(); var paths = new List<string>(); var facts = new Dictionary<string, object>(); Exception? caseFailure = null;
                string NewRoot(int index)
                {
                    var own = Path.Combine(temp, "phone-media-" + Guid.NewGuid().ToString("N")); PrivateDirectory(own); peerRoots.Add(own);
                    using (var rootIndex = new FileStream(Path.Combine(root, "owned-roots.txt"), FileMode.Append, FileAccess.Write, FileShare.Read)) { var bytes = System.Text.Encoding.ASCII.GetBytes(Path.GetFileName(own) + "\n"); rootIndex.Write(bytes); rootIndex.Flush(true); }
                    PcmWave.Write(Path.Combine(own, "input.wav"), [new[] { 425d, 733d, 1013d }[index]]); PcmWave.Write(Path.Combine(own, "voicemail.wav"), [1553], 4);
                    File.Copy(index == 0 ? input.ImageA : input.ImageB, Path.Combine(own, "frame.jpg")); return own;
                }
                for (var index = 0; index < 3; index++) paths.Add(NewRoot(index));
                LabPeer Create(int index, string? ca = null, string host = "127.0.0.1", bool distinct = false)
                {
                    var own = distinct ? NewRoot(index) : paths[index];
                    return new(new(1, own, ca ?? server.CaPem, Path.Combine(own, "input.wav"), Path.Combine(own, "output.wav"), Path.Combine(own, "frame.jpg"), server.Realm, "810" + (index + 1), server.Password, server.TlsPort, host), journal);
                }
                try
                {
                    // Exact same account/server is subsequently required to succeed;
                    // explicit native registration failure is required for each negative.
                    if (name == "tls_chain_hostname")
                    {
                        operation = "wrong_ca_create"; using (var wrongCa = Create(0, server.WrongCaPem, distinct: true)) { operation = "wrong_ca_wait"; Wait("wrong_ca_refused", () => wrongCa.Command().RegistrationFailed, [wrongCa], 20); operation = "wrong_ca_assert"; if (wrongCa.State.Ready) throw new InvalidDataException("Untrusted TLS CA accepted."); operation = "wrong_ca_dispose"; }
                        operation = "wrong_name_create"; using (var wrongName = Create(0, host: "localhost", distinct: true)) { operation = "wrong_name_wait"; Wait("wrong_name_refused", () => wrongName.Command().RegistrationFailed, [wrongName], 20); operation = "wrong_name_assert"; if (wrongName.State.Ready) throw new InvalidDataException("Wrong TLS name accepted."); operation = "wrong_name_dispose"; }
                        facts["wrong_ca_refused"] = true; facts["wrong_name_refused"] = true;
                    }
                    operation = "peer_0_create"; peers.Add(Create(0)); operation = "peer_1_create"; peers.Add(Create(1)); operation = "peer_2_create"; peers.Add(Create(2)); var a = peers[0]; var b = peers[1]; var c = peers[2];
                    operation = "registration_wait"; Wait("registrations_ready", () => peers.All(peer => peer.Command().Ready), peers.ToArray(), 20); operation = "security_assert"; foreach (var peer in peers) Secure(peer.State); facts["actual_tls_registration"] = true; operation = "case_execute";
                    if (name == "tls_chain_hostname") { }
                    else if (name == "voicemail_local_player")
                    {
                        a.Command("play"); Wait("voicemail_playing", () => a.Command().Playback.State == "Playing" && a.State.Playback.Position >= 200 && a.State.Playback.Duration >= 3500 && a.State.Playback.OwnedFilePresent, [a], 8); facts["native_player_advanced"] = true;
                        b.Command("dial", "8101"); Wait("voicemail_incoming", () => a.Command().Calls.Any(call => call.Incoming), [a, b]); Wait("voicemail_removed", () => !a.Command().Playback.OwnedFilePresent && a.State.Playback.State == "Closed", [a, b], 8); facts["incoming_call_removed_private_playback"] = true; Connected(b, a, phase: "voicemail"); Pair(facts, "answered", a, [733], b, [425]);
                    }
                    else
                    {
                        var caller = name == "incoming_audio" ? b : a; var target = name == "incoming_audio" ? a : b; caller.Command("dial", name == "incoming_audio" ? "8101" : "8102", video: name == "software_vp8"); Connected(caller, target, name == "software_vp8");
                        Pair(facts, "initial", a, [733], b, [425]);
                        switch (name)
                        {
                            case "outgoing_audio":
                                a.Command("update_active_refusal"); facts["active_call_deferred_update"] = true; Pair(facts, "after_update_refusal", a, [733], b, [425]);
                                foreach (var call in a.Command().Calls) a.Command("hangup", call: call.Id); Wait("update_idle", () => !a.Command().Busy && !b.Command().Busy, [a, b]); a.Command("update_idle_accept"); facts["idle_allows_update"] = true; break;
                            case "hold_music_resume":
                                a.Command("hold"); Wait("held", () => a.Command().Native.Calls.Any(call => call.State == "Paused"), [a, b]); facts["held_caller_music"] = Capture(b, [1553]);
                                a.Command("hold"); Wait("resumed", () => a.Command().Native.Calls.Any(call => call.State == "StreamsRunning"), [a, b]); Pair(facts, "resumed", a, [733], b, [425]); break;
                            case "dtmf":
                                b.Command("clear_dtmf"); foreach (var digit in "578#") { a.Command("dtmf", digit.ToString()); Thread.Sleep(180); } Wait("dtmf_received", () => string.Concat(b.Command().Native.Dtmf) == "578#", [a, b], 8); facts["received_exact_digits"] = true; break;
                            case "blind_transfer":
                                a.Command("blind", "8103"); Connected(b, c, phase: "blind"); Wait("blind_original_ended", () => !a.Command().Busy, [a, b, c]); Pair(facts, "transferred", b, [1013], c, [733]); break;
                            case "consult_complete": case "consult_cancel":
                                a.Command("consult", "8103"); Connected(a, c, phase: "consultation"); Pair(facts, "consultation", a, [1013], c, [425]); a.Command(name == "consult_complete" ? "complete" : "cancel");
                                if (name == "consult_complete") { Wait("consult_completed", () => !a.Command().Busy && b.Command().Busy && c.Command().Busy, [a, b, c]); Pair(facts, "completed", b, [1013], c, [733]); }
                                else { Wait("consult_cancelled", () => a.Command().Native.Calls.Any(call => call.State == "StreamsRunning") && !c.Command().Busy, [a, b, c]); Pair(facts, "cancelled", a, [733], b, [425]); } break;
                            case "call_waiting":
                                var original = a.Command().Calls.Single().Id; c.Command("dial", "8101"); Connected(c, a, phase: "waiting"); Pair(facts, "waiting_answered", a, [1013], c, [425]);
                                a.Command("select", call: original); Wait("waiting_original_resumed", () => a.Command().Current == original && a.State.Native.Calls.Any(call => call.Id == original && call.State == "StreamsRunning"), [a, b, c]); Pair(facts, "original_resumed", a, [733], b, [425]); break;
                            case "local_conference":
                                a.Command("dial", "8103"); Connected(a, c, phase: "consultation"); a.Command("merge"); Wait("conference_merged", () => a.Command().Conferencing && a.State.Calls.Length == 2, [a, b, c]); a.Command("conference_record");
                                facts["host_sdk_recorded_mix"] = Capture(a, [425, 733, 1013], Path.Combine(a.Root, "conference.wav")); facts["left_received_mix"] = Capture(b, [425, 1013]); facts["right_received_mix"] = Capture(c, [425, 733]); a.Command("conference_stop"); facts["sdk_conference_recording"] = PcmWave.Read(Path.Combine(a.Root, "conference.wav")).Duration >= 9; if (!(bool)facts["sdk_conference_recording"]) throw new InvalidDataException("Actual SDK conference recording missing."); break;
                            case "software_vp8":
                                var beforeA = a.Command().Native.Calls.Single().DecodedVideoFrames; var beforeB = b.Command().Native.Calls.Single().DecodedVideoFrames; Thread.Sleep(3000); var afterA = a.Command().Native.Calls.Single(); var afterB = b.Command().Native.Calls.Single();
                                if (afterA.DecodedVideoFrames - beforeA < 20 || afterB.DecodedVideoFrames - beforeB < 20 || afterA.VideoCodec != "VP8" || afterB.VideoCodec != "VP8" || afterA.Width < 64 || afterB.Width < 64 || afterA.Height < 64 || afterB.Height < 64 || !float.IsFinite(afterA.ReceivedFps) || !float.IsFinite(afterB.ReceivedFps) || afterA.ReceivedFps < 5 || afterB.ReceivedFps < 5) throw new InvalidDataException("Continuous independently decoded VP8 frames missing.");
                                facts["left_decoded_frames"] = afterA.DecodedVideoFrames - beforeA; facts["right_decoded_frames"] = afterB.DecodedVideoFrames - beforeB; facts["window_seconds"] = 3;
                                facts["left_width"] = afterA.Width; facts["left_height"] = afterA.Height; facts["right_width"] = afterB.Width; facts["right_height"] = afterB.Height; facts["left_received_fps"] = afterA.ReceivedFps; facts["right_received_fps"] = afterB.ReceivedFps; break;
                        }
                        foreach (var peer in peers) Secure(peer.Command());
                    }
                    operation = "peers_cleanup"; if (!StopPeers(peers)) { cleanup = false; throw new InvalidDataException("Owned peer cleanup failed."); } operation = "engine_idle"; server.RequireIdle();
                    cases.Add(new { name, state = "passed", actual_nativephone = true, file_media_adapter = true, growing_wav_snapshot_adapter = true, facts });
                }
                catch (Exception error) { caseFailure = error; throw; }
                finally
                {
                    // Preserve the existing once-only owned shutdown before any final
                    // recorder observation. An observer can never replace the failure.
                    var peersClosed = StopPeers(peers); if (!peersClosed) cleanup = false;
                    try { if (caseFailure?.Data["media_recorder_pending"] is PendingRecorderObservation pending) caseFailure.Data["media_recorder_observation"] = RecorderObservation.Complete(pending, peersClosed); } catch { }
                }
            }
            operation = "engine_idle"; server.RequireIdle(); operation = "engine_shutdown"; server.Dispose(); engineStopped = true; server = null;
        }
        catch (Exception error) { failure = error; }
        finally
        {
            if (!StopPeers(peers)) cleanup = false;
            if (server is not null) { try { server.Dispose(); engineStopped = true; } catch { cleanup = false; } }
            if (failure is not null && server is not null && engineStopped) engineObservation = server.ObserveFailure(input.SourceCommit, input.RunId, stage);
            foreach (var path in peerRoots) { try { Protocol.NoLinks(path); Directory.Delete(path, true); } catch { cleanup = false; } }
            if (LabPeer.CleanupRefused) cleanup = false;
            var receipt = JsonSerializer.SerializeToNode(new { schema = 1, producer = "OpenWebPbx.Phone.MediaChecks", state = failure is null && cleanup && cases.Count == 12 ? "passed_software_media" : "failed", stage, error_type = failure?.GetType().Name ?? "none", cases, exact_owned_cleanup = cleanup, input.SourceCommit, input.SdkSha256, input.EngineSha256, test_managed_assembly = true, production_binary_tested = false, hardware_media_tested = false, gui_render_tested = false, carrier_calls_placed = false, store_accepted = false, installer_transaction_executed = false, production_update_channel_tested = false })!.AsObject();
            if (engineObservation is not null) receipt["engine_observation"] = JsonSerializer.SerializeToNode(engineObservation);
            if (failure is not null) { receipt["failure_observation"] = JsonSerializer.SerializeToNode(FailureObservation.Capture(failure, operation)); receipt["engine_lifecycle"] = JsonSerializer.SerializeToNode(new { start_completed = engineStarted, shutdown_completed = engineStopped }); }
            Protocol.Write(reportPath, receipt);
        }
        return failure is null && cleanup && cases.Count == 12 ? 0 : 1;
    }
}
