// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text.Json;
using OpenWebPbx.Phone.Core;
using OpenWebPbx.Phone.Windows;
namespace OpenWebPbx.Phone.MediaChecks;
internal static partial class PeerRunner
{
    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial nint CreateWindowEx(uint extended, string name, string title, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool DestroyWindow(nint window);
    [StructLayout(LayoutKind.Sequential)] private struct Message { public nint Window; public uint Id; public nuint W; public nint L; public uint Time; public int X, Y; public uint Private; }
    [LibraryImport("user32.dll", EntryPoint = "PeekMessageW")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool PeekMessage(out Message message, nint window, uint first, uint last, uint remove);
    [LibraryImport("user32.dll", EntryPoint = "TranslateMessage")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool TranslateMessage(in Message message);
    [LibraryImport("user32.dll", EntryPoint = "DispatchMessageW")] private static partial nint DispatchMessage(in Message message);
    internal static int Run(string inputFile)
    {
        Protocol.Guard(); var own = Protocol.InputScope(inputFile, "phone-media-", "peer.json"); var input = Protocol.Read<PeerInput>(inputFile, 262144);
        if (!string.Equals(Path.GetFullPath(input.Root), own, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Peer input root differs.");
        if (input.Schema != 1 || input.Username is not ("8101" or "8102" or "8103") || input.Host is not ("127.0.0.1" or "localhost") || input.Port is < 1024 or > 65535 || !System.Text.RegularExpressions.Regex.IsMatch(input.Realm, "^media-[a-f0-9]{16}\\.invalid$") || !System.Text.RegularExpressions.Regex.IsMatch(input.Password, "^[a-f0-9]{64}$")) throw new InvalidDataException("Only invented loopback accounts are allowed.");
        var commands = new ConcurrentQueue<string>(); bool stdinEnded = false;
        _ = Task.Run(() => { try { string? line; while ((line = Console.ReadLine()) is not null) { if (line.Length > 4096 || commands.Count >= 64) break; commands.Enqueue(line); } } finally { Volatile.Write(ref stdinEnded, true); } });
        NativePhone? phone = null; nint window = 0; var started = DateTime.UtcNow; var stopping = false; var lastSequence = 0; Exception? primary = null;
        void Reply(PeerReply value) { var json = JsonSerializer.Serialize(value, Protocol.Json); if (json.Length > 32768) throw new InvalidDataException("Peer snapshot exceeds its bound."); Console.WriteLine(json); Console.Out.Flush(); }
        PeerState Snapshot(bool clear = false, bool recorder = false) => new(phone!.Registrations.Values.SingleOrDefault() == "Ready for calls", phone.Registrations.Values.SingleOrDefault() == "Could not connect. Check your connection or sign in again.", phone.Busy, phone.Conferencing, phone.Current?.Id, phone.Calls.Select(call => new CallView(call.Id, call.Number, call.State.ToString(), call.Incoming)).ToArray(), phone.FixtureSnapshot(clear, recorder), phone.FixturePlaybackSnapshot());
        try
        {
            var fixture = new NativeMediaFixture(input.Root, input.CaPem, input.InputWav, input.OutputWav, input.StaticImage);
            phone = new NativePhone(stage => Reply(new(0, "native_" + stage, true, "", null)), fixture);
            // An owned hidden window supplies a valid native sink; rendering is never claimed.
            window = CreateWindowEx(0, "STATIC", "OpenWebPBX owned software media fixture", 0, 0, 0, 640, 480, 0, 0, 0, 0);
            if (window == 0) throw new InvalidOperationException("An owned video sink was unavailable."); phone.AttachVideo(window, 0);
            var id = Guid.NewGuid(); var profile = new PhoneProfile(id, new Uri("https://media-fixture.openwebpbx.com"), new string('e', 64), Guid.NewGuid(), new(input.Host, input.Realm, input.Username, input.Username, input.Password, input.Port), new(Guid.NewGuid(), Guid.NewGuid(), input.Username, "Invented media lab", "Software peer"), []);
            phone.Synchronize([profile], id); Reply(new(0, "ready", true, "", Snapshot()));
            while (!stopping && DateTime.UtcNow - started < TimeSpan.FromSeconds(150))
            {
                phone.Iterate(); while (PeekMessage(out var message, 0, 0, 0, 1)) { TranslateMessage(message); DispatchMessage(message); }
                if (commands.TryDequeue(out var line))
                {
                    PeerCommand? command = null;
                    try
                    {
                        command = JsonSerializer.Deserialize<PeerCommand>(line, Protocol.Json) ?? throw new InvalidDataException();
                        if (command.Sequence != lastSequence + 1 || command.Sequence > 2048 || command.Number.Length > 32) throw new InvalidDataException("Peer command sequence differs."); lastSequence = command.Sequence;
                        if (command.Action is "dial" or "blind" or "consult" && command.Number is not ("8101" or "8102" or "8103")) throw new InvalidDataException("Non-lab number refused.");
                        switch (command.Action)
                        {
                            case "snapshot": break;
                            case "recorder_payload": Reply(new(command.Sequence, command.Action, true, "", Snapshot(false, true))); continue;
                            case "clear_dtmf": Reply(new(command.Sequence, command.Action, true, "", Snapshot(true))); continue;
                            case "dial": phone.Dial(command.Number, command.Video); break;
                            case "answer": phone.Answer(command.Call ?? throw new InvalidDataException(), command.Video); break;
                            case "hangup": phone.Hangup(command.Call ?? throw new InvalidDataException()); break;
                            case "hold": phone.HoldResume(); break;
                            case "dtmf": if (command.Number.Length != 1 || !"0123456789*#".Contains(command.Number, StringComparison.Ordinal)) throw new InvalidDataException(); phone.Dtmf(command.Number[0]); break;
                            case "blind": phone.BlindTransfer(command.Number); break;
                            case "consult": phone.Consult(command.Number); break;
                            case "complete": phone.CompleteTransfer(); break;
                            case "cancel": phone.CancelConsultation(); break;
                            case "select": phone.Select(command.Call ?? throw new InvalidDataException()); break;
                            case "merge": phone.Merge(); break;
                            case "conference_record": phone.FixtureStartConferenceRecording(Path.Combine(input.Root, "conference.wav")); break;
                            case "conference_stop": phone.FixtureStopConferenceRecording(); break;
                            case "play": phone.PlayVoicemail(File.ReadAllBytes(Path.Combine(input.Root, "voicemail.wav"))); break;
                            case "stop_play": phone.StopVoicemail(); break;
                            case "update_active_refusal":
                                if (phone.Calls.Count == 0) throw new InvalidOperationException("The real call must still be active.");
                                var refused = false; try { UpdateRequirement.RequireInstallationIdle(phone.Calls.Count); } catch (PhoneInputException) { refused = true; }
                                if (!refused) throw new InvalidOperationException("An active call did not defer installation."); break;
                            case "update_idle_accept":
                                if (phone.Calls.Count != 0) throw new InvalidOperationException("The real calls must be drained."); UpdateRequirement.RequireInstallationIdle(phone.Calls.Count); break;
                            case "shutdown": stopping = true; break;
                            default: throw new InvalidDataException("Unknown peer command.");
                        }
                        Reply(new(command.Sequence, command.Action, true, "", Snapshot()));
                    }
                    catch (Exception error) { Reply(new(command?.Sequence ?? lastSequence, "command_failed", false, error.GetType().Name, Snapshot())); }
                }
                else if (Volatile.Read(ref stdinEnded)) stopping = true;
                Thread.Sleep(20);
            }
            if (!stopping) throw new TimeoutException("Peer deadline expired."); return 0;
        }
        catch (Exception error) { primary = error; throw; }
        finally
        {
            var cleanupFailed = false;
            if (phone is not null)
            {
                try { foreach (var call in phone.Calls.ToArray()) try { phone.Hangup(call.Id); } catch { cleanupFailed = true; } } catch { cleanupFailed = true; }
                try { var limit = DateTime.UtcNow.AddSeconds(8); while (phone.Busy && DateTime.UtcNow < limit) { phone.Iterate(); Thread.Sleep(20); } if (phone.Busy) cleanupFailed = true; } catch { cleanupFailed = true; }
                try { phone.AttachVideo(0, 0); } catch { cleanupFailed = true; }
                try { phone.Dispose(); } catch { cleanupFailed = true; }
            }
            if (window != 0) { try { if (!DestroyWindow(window)) cleanupFailed = true; } catch { cleanupFailed = true; } }
            if (cleanupFailed) { if (primary is not null) primary.Data["owned_cleanup_failed"] = true; else throw new InvalidOperationException("Owned native peer cleanup failed."); }
        }
    }
}
