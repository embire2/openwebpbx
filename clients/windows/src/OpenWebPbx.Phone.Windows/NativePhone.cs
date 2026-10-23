// SPDX-License-Identifier: AGPL-3.0-or-later
using Linphone;
using System.Security.Cryptography.X509Certificates;
using OpenWebPbx.Phone.Core;
using LCore = Linphone.Core;
namespace OpenWebPbx.Phone.Windows;

public sealed record LiveCall(Guid Id, Guid ProfileId, string Name, string Number, CallState State, bool Incoming, int Duration, bool Video, bool Muted, bool Camera);
public sealed record PhoneDevice(string Id, string Name);

/// <summary>Owned by the WinUI dispatcher. Iterate and every native operation run on that same thread.</summary>
public sealed class NativePhone : IDisposable
{
    private readonly LCore core;
    private readonly NativeSessionFiles nativeFiles;
#if PHONE_MEDIA_FIXTURE
    private readonly NativeMediaFixture? mediaFixture;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<Call, int> decodedFrames = new();
    private readonly System.Collections.Concurrent.ConcurrentQueue<Call> rearmFrames = new();
    private readonly List<string> receivedDtmf = [];
#endif
    private readonly int thread = Environment.CurrentManagedThreadId;
    private readonly Dictionary<Guid, (PhoneProfile Profile, Account Account, AuthInfo Auth)> accounts = [];
    private readonly Dictionary<Call, Guid> identities = [];
    private readonly Dictionary<Guid, string> registrations = [];
    private Call? selected, consultation;
    private Conference? conference;
    private bool disposed, videoVisible;
    private Player? voicemailPlayer;
    private string? voicemailPath;
    private int playbackEnded;
    private readonly List<string> pendingAudioCleanup = [];
    private readonly List<Player> pendingPlayers = [];
    public event Action? Changed;
    public event Action<Guid, string, bool, DateTimeOffset, int, bool>? CallFinished;
    private readonly Dictionary<Call, (Guid Profile, DateTimeOffset Started, bool Answered)> history = [];
    public string Message { get; private set; } = "Ready to connect an account";
    public bool Busy => core.CallsNb != 0;
    public bool Conferencing => conference is not null;
    public Guid? SelectedProfile { get; private set; }
    public IReadOnlyList<LiveCall> Calls => core.Calls.Select(View).ToArray();
    public LiveCall? Current => selected is null ? null : View(selected);
    public IReadOnlyDictionary<Guid, string> Registrations => registrations;
    public NativePhone() : this((Action<string>?)null) { }
#if PHONE_MEDIA_FIXTURE
    internal NativePhone(NativeMediaFixture fixture) : this(null, fixture) { }
#endif
    internal NativePhone(Action<string>? progress
#if PHONE_MEDIA_FIXTURE
        , NativeMediaFixture? fixture = null
#endif
    )
    {
#if PHONE_MEDIA_FIXTURE
        fixture?.Validate(); mediaFixture = fixture; nativeFiles = new(fixture?.Root);
#else
        nativeFiles = new();
#endif
        try
        {
        progress?.Invoke("runtime_resources"); NativeResources.Verify();
        progress?.Invoke("logging"); LoggingService.Instance.LogLevelMask = 0;
        progress?.Invoke("factory"); Factory.Instance.ConfigDir = nativeFiles.Path; Factory.Instance.DataDir = nativeFiles.Path; Factory.Instance.CacheDir = nativeFiles.Path;
        Factory.Instance.MspluginsDir = Path.Combine(AppContext.BaseDirectory, "native", "plugins");
        Factory.Instance.TopResourcesDir = Path.Combine(AppContext.BaseDirectory, "native", "share");
        // No path is supplied to Config: native account/auth/history state stays in memory.
        progress?.Invoke("configuration"); var config = Factory.Instance.CreateConfigFromString("[sip]\nsave_auth_info=0\nstore_auth_info=0\n[storage]\nbackend=\nuri=\n[lime]\nenabled=0\n[logging]\ndisable_stdout=1\n");
#if PHONE_MEDIA_FIXTURE
        if (mediaFixture is not null) { config.SetString("sip", "bind_address", "127.0.0.1"); config.SetInt("sip", "use_ipv6", 0); config.SetString("rtp", "bind_address", "127.0.0.1"); }
#endif
        Factory.Instance.EnableLogCollection(LogCollectionState.Disabled);
        progress?.Invoke("create_core"); core = Factory.Instance.CreateCoreWithConfig(config, IntPtr.Zero);
        progress?.Invoke("database"); core.DatabaseEnabled = false; core.MaxCallLogs = 0; core.LimeX3DhEnabled = false; core.DisableChat(Reason.NotAcceptable);
        core.Config.SetInt("sip", "save_auth_info", 0); core.Config.SetInt("sip", "store_auth_info", 0);
        core.Config.SetInt("sip", "use_rfc2833", 1); core.Config.SetInt("sip", "use_info", 0);
        core.Config.SetInt("rtp", "symmetric", 1);
        core.AutoIterateEnabled = false; core.MaxCalls = 2;
        progress?.Invoke("encryption"); core.MediaEncryption = MediaEncryption.SRTP; core.MediaEncryptionMandatory = true;
        core.SrtpCryptoSuites = "AES_CM_128_HMAC_SHA1_80";
        progress?.Invoke("trusted_roots"); using (var roots = new X509Store(StoreName.Root, StoreLocation.LocalMachine))
        {
            roots.Open(OpenFlags.ReadOnly);
            core.RootCaData = string.Join("\n", roots.Certificates.Cast<X509Certificate2>().Select(c => c.ExportCertificatePem()));
        }
        core.VerifyServerCertificates(true); core.VerifyServerCn(true);
        progress?.Invoke("devices"); foreach (var codec in core.VideoPayloadTypes) codec.Enable(codec.MimeType.Equals("VP8", StringComparison.OrdinalIgnoreCase));
        core.PreferredVideoDefinitionByName = "vga"; core.PreferredFramerate = 15f;
        core.EchoCancellationEnabled = true; core.VideoCaptureEnabled = false; core.VideoDisplayEnabled = true;
        var video = Factory.Instance.CreateVideoActivationPolicy(); video.AutomaticallyAccept = false; video.AutomaticallyInitiate = false; core.VideoActivationPolicy = video;
        var transport = Factory.Instance.CreateTransports(); transport.UdpPort = 0; transport.TcpPort = 0; transport.TlsPort = -1; core.Transports = transport;
        progress?.Invoke("listeners"); core.Listener.OnAccountRegistrationStateChanged = (_, account, state, _) =>
        {
            var match = accounts.Values.FirstOrDefault(x => x.Account == account);
            if (match.Profile is not null) registrations[match.Profile.Id] = state switch { RegistrationState.Ok => "Ready for calls", RegistrationState.Progress => "Connecting…", RegistrationState.Failed => "Could not connect. Check your connection or sign in again.", _ => "Offline" };
            Changed?.Invoke();
        };
        core.Listener.OnCallStateChanged = (sender, call, state, message) => { try { CallChanged(sender, call, state, message); } catch { Message = "The call could not be updated. Choose your call to continue."; } };
        core.Listener.OnTransferStateChanged = (_, _, state) => { if (state == CallState.Error) Message = "Transfer failed. Choose your original call to continue."; Changed?.Invoke(); };
#if PHONE_MEDIA_FIXTURE
        if (mediaFixture is not null) ConfigureMediaFixture(mediaFixture);
        core.Listener.OnDtmfReceived = (_, _, value) => { var key = ((char)value).ToString(); if ("0123456789*#".Contains(key, StringComparison.Ordinal) && receivedDtmf.Count < 128) receivedDtmf.Add(key); };
#endif
        core.SetUserAgent("OpenWebPBX Free Phone", "1.0.0");
        progress?.Invoke("start"); core.Start();
        progress?.Invoke("verify_policy"); if (!core.IsVerifyServerCn || !core.IsVerifyServerCertificates || !core.IsMediaEncryptionMandatory || core.Config.GetInt("sip", "save_auth_info", 1) != 0) throw new InvalidOperationException("Secure native calling policy was not applied.");
        }
        catch { try { core?.Stop(); } catch { } try { nativeFiles.Dispose(); } catch { } throw; }
    }
    public void Iterate()
    {
        CheckThread(); core.Iterate();
        if (Interlocked.Exchange(ref playbackEnded, 0) != 0) InterruptVoicemail();
        foreach (var player in pendingPlayers.ToArray()) try { player.Close(); pendingPlayers.Remove(player); } catch { }
        foreach (var file in pendingAudioCleanup.ToArray()) try { File.Delete(file); pendingAudioCleanup.Remove(file); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
#if PHONE_MEDIA_FIXTURE
        while (rearmFrames.TryDequeue(out var call)) if (core.Calls.Contains(call) && call.CurrentParams.VideoEnabled) call.RequestNotifyNextVideoFrameDecoded();
#endif
    }
    public void Synchronize(IReadOnlyList<PhoneProfile> profiles, Guid? chosen)
    {
        CheckThread(); ConnectionRules.RequireIdle(core.CallsNb);
        foreach (var id in accounts.Keys.Where(x => profiles.All(p => p.Id != x || p.NeedsLogin)).ToArray()) Remove(id);
        foreach (var profile in profiles.Where(x => !x.NeedsLogin && !accounts.ContainsKey(x.Id)))
        {
            var sip = profile.Sip;
#if PHONE_MEDIA_FIXTURE
            if (mediaFixture is not null && (sip.Server is not ("localhost" or "127.0.0.1") || sip.Port <= 1024 || !sip.Realm.EndsWith(".invalid", StringComparison.Ordinal))) throw new InvalidOperationException("Media fixture SIP escaped loopback.");
#endif
            var auth = Factory.Instance.CreateAuthInfo(sip.Username, sip.AuthUsername, sip.Password, null!, sip.Realm, sip.Realm);
            core.AddAuthInfo(auth);
            try
            {
                var parameters = core.CreateAccountParams(); parameters.IdentityAddress = Factory.Instance.CreateAddress($"sip:{sip.Username}@{sip.Realm}");
                var server = Factory.Instance.CreateAddress($"sip:{sip.Server}:{sip.Port};transport=tls");
                parameters.ServerAddress = server; parameters.RoutesAddresses = [server]; parameters.OutboundProxyEnabled = true;
                parameters.Transport = TransportType.Tls; parameters.Idkey = profile.Id.ToString(); parameters.RegisterEnabled = true;
                parameters.Expires = 300; parameters.UnregisterAtStopEnabled = true;
                var account = core.CreateAccount(parameters); accounts.Add(profile.Id, (profile, account, auth)); core.AddAccount(account); registrations[profile.Id] = "Connecting…";
            }
            catch { core.RemoveAuthInfo(auth); throw; }
        }
        SelectedProfile = chosen;
        if (chosen is Guid selectedId && accounts.TryGetValue(selectedId, out var current)) core.DefaultAccount = current.Account;
        Changed?.Invoke();
    }
    private void Remove(Guid id)
    {
        var row = accounts[id]; row.Account.ClearCallLogs(); core.RemoveAccountWithData(row.Account); core.RemoveAuthInfo(row.Auth); accounts.Remove(id); registrations.Remove(id); core.ClearCallLogs();
    }
    public void Reconnect() { CheckThread(); ConnectionRules.RequireIdle(core.CallsNb); core.NetworkReachable = true; core.RefreshRegisters(); Message = "Reconnecting…"; }
    public void NetworkChanged(bool available) { CheckThread(); core.NetworkReachable = available; if (available) core.RefreshRegisters(); Message = available ? "Reconnecting…" : "No network connection"; Changed?.Invoke(); }
    public void Dial(string number, bool video = false) => DialOnProfile(number, video, SelectedProfile);
    private void DialOnProfile(string number, bool video, Guid? profileId)
    {
        CheckThread(); CallingRules.Stable(pending is not null); if (video) RequireVideo(true); if (core.CallsNb >= 2) throw new PhoneInputException("Finish one call before starting another.");
        if (profileId is not Guid id || !accounts.TryGetValue(id, out var account) || account.Account.State != RegistrationState.Ok) throw new PhoneInputException("Wait for this account to connect.");
        var address = Factory.Instance.CreateAddress($"sip:{ConnectionRules.Number(number)}@{account.Profile.Sip.Realm}");
        var active = selected; if (active is not null && active.State == CallState.StreamsRunning) { active.Pause(); pending = () => Start(); return; }
        Start();
        void Start()
        {
            var parameters = core.CreateCallParams(null!); parameters.Account = account.Account; parameters.MediaEncryption = MediaEncryption.SRTP;
            parameters.VideoEnabled = video; parameters.CameraEnabled = video; core.VideoCaptureEnabled = video;
            selected = core.InviteAddressWithParams(address, parameters) ?? throw new PhoneInputException("The call could not start."); Changed?.Invoke();
        }
    }
    private Action? pending;
    public void Select(Guid id)
    {
        CheckThread(); CallingRules.Stable(pending is not null); var target = Find(id);
        if (selected is not null && selected != target && selected.State == CallState.StreamsRunning) { selected.Pause(); pending = SelectAfterPause; } else SelectAfterPause();
        void SelectAfterPause() { selected = target; if (target.State == CallState.Paused) target.Resume(); Changed?.Invoke(); }
    }
    public void Answer(Guid id, bool video)
    {
        CheckThread(); CallingRules.Stable(pending is not null); if (video) RequireVideo(); var target = Find(id);
        if (selected is not null && selected != target && selected.State == CallState.StreamsRunning) { selected.Pause(); pending = Accept; } else Accept();
        void Accept() { selected = target; var parameters = core.CreateCallParams(target); parameters.VideoEnabled = video && target.RemoteParams.VideoEnabled; parameters.CameraEnabled = parameters.VideoEnabled; core.VideoCaptureEnabled = parameters.VideoEnabled; target.AcceptWithParams(parameters); Changed?.Invoke(); }
    }
    public void Hangup(Guid id) { CheckThread(); var target = Find(id); if (target.State == CallState.IncomingReceived) target.Decline(Reason.Declined); else target.Terminate(); }
    public void HoldResume()
    {
        CheckThread(); CallingRules.Stable(pending is not null); var target = Required(); if (conference is not null) { foreach (var call in core.Calls.ToArray()) { if (call.State == CallState.StreamsRunning) call.Pause(); else if (call.State == CallState.Paused) call.Resume(); } return; }
        if (target.State == CallState.Paused) target.Resume(); else if (target.State == CallState.StreamsRunning) target.Pause(); else throw new PhoneInputException("Wait for the call to connect.");
    }
    public void Mute() { CheckThread(); var call = Required(); if (conference is not null) conference.MicrophoneMuted = !conference.MicrophoneMuted; else call.MicrophoneMuted = !call.MicrophoneMuted; Changed?.Invoke(); }
    public void Dtmf(char key) { CheckThread(); if (!"0123456789*#".Contains(key)) return; Required().SendDtmf((sbyte)key); }
    public void BlindTransfer(string number) { CheckThread(); CallingRules.Stable(pending is not null); var call = Required(); call.TransferTo(Factory.Instance.CreateAddress($"sip:{ConnectionRules.Number(number)}@{Profile(call).Sip.Realm}")); }
    public void Consult(string number) { CheckThread(); if (consultation is not null || core.CallsNb != 1) throw new PhoneInputException("Choose a single call to transfer."); consultation = Required(); try { DialOnProfile(number, false, Profile(consultation).Id); } catch { consultation = null; throw; } }
    public void CompleteTransfer() { CheckThread(); var destination = Required(); if (consultation is null || destination == consultation || destination.State != CallState.StreamsRunning) throw new PhoneInputException("Wait for the second person to answer."); consultation.TransferToAnother(destination); }
    public void CancelConsultation() { CheckThread(); pending = null; var original = consultation; consultation = null; if (original is null) return; foreach (var call in core.Calls.Where(x => x != original).ToArray()) call.Terminate(); selected = original; if (original.State == CallState.Paused) original.Resume(); }
    public void Merge()
    {
        CheckThread(); CallingRules.Stable(pending is not null); var calls = core.Calls.ToArray(); if (calls.Length != 2 || calls.Any(x => x.State is not (CallState.StreamsRunning or CallState.Paused)) || Profile(calls[0]).Id != Profile(calls[1]).Id || consultation is not null) throw new PhoneInputException("Both people on the same account must answer before merging.");
        StopCamera(); var parameters = core.CreateConferenceParams(null!); parameters.AudioEnabled = true; parameters.VideoEnabled = false; parameters.LocalParticipantEnabled = true; parameters.OneParticipantConferenceEnabled = true;
        core.Config.SetString("misc", "conference_type", "local"); var group = core.CreateConferenceWithParams(parameters);
        var added = new List<Call>();
        try { foreach (var call in calls) { group.AddParticipant(call); added.Add(call); } if (group.Enter() != 0) throw new PhoneInputException("Could not join the conference. Choose a call to continue."); conference = group; }
        catch { foreach (var call in added) { var participant = group.FindParticipant(call.RemoteAddress); if (participant is not null) group.RemoveParticipant(participant); } throw; }
        Changed?.Invoke();
    }
    public void MuteParticipant(Guid id) { CheckThread(); var call = Find(id); call.SpeakerMuted = !call.SpeakerMuted; Changed?.Invoke(); }
    public void SetVideo(bool enabled)
    {
        CheckThread(); CallingRules.Stable(pending is not null); if (enabled) RequireVideo(); var call = Required(); var parameters = core.CreateCallParams(call); parameters.VideoEnabled = enabled; parameters.CameraEnabled = enabled; core.VideoCaptureEnabled = enabled; call.CameraEnabled = enabled; call.Update(parameters); Changed?.Invoke();
    }
    public void StopCamera() { CheckThread(); core.VideoCaptureEnabled = false; core.VideoPreviewEnabled = false; foreach (var call in core.Calls) call.CameraEnabled = false; Changed?.Invoke(); }
    public void AcceptVideoOffer(bool video) { CheckThread(); if (video) RequireVideo(); var call = Required(); var parameters = core.CreateCallParams(call); parameters.VideoEnabled = video; parameters.CameraEnabled = video; core.VideoCaptureEnabled = video; call.AcceptUpdate(parameters); }
    public void BeginQrScan(IntPtr preview, Action<string> found)
    {
        CheckThread(); ConnectionRules.RequireIdle(core.CallsNb);
        if (Cameras.Count == 0) throw new PhoneInputException("No available webcam was found. Open your welcome email setup file instead.");
        if (!Factory.Instance.IsQrcodeAvailable) throw new PhoneInputException("QR scanning is unavailable. Open your welcome email setup file instead.");
        core.Listener.OnQrcodeFound = (_, result) => { if (result.Length <= 16384) found(result); };
        core.NativePreviewWindowId = preview; core.QrcodeVideoPreviewEnabled = true; core.VideoCaptureEnabled = true; core.VideoPreviewEnabled = true;
    }
    public void EndQrScan() { CheckThread(); core.Listener.OnQrcodeFound = null!; core.QrcodeVideoPreviewEnabled = false; StopCamera(); core.NativePreviewWindowId = IntPtr.Zero; }
    public void PlayVoicemail(byte[] audio)
    {
        CheckThread(); ConnectionRules.RequireIdle(core.CallsNb); StopVoicemail();
        if (audio.Length is < 44 or > 32 * 1024 * 1024 || !audio.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !audio.AsSpan(8, 4).SequenceEqual("WAVE"u8)) throw new PhoneInputException("This voicemail audio format is unavailable. Dial 121 to listen through your phone.");
        var path = Path.Combine(nativeFiles.Path, "voicemail-" + Guid.NewGuid().ToString("N") + ".wav");
        try
        {
            using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough)) { output.Write(audio); output.Flush(true); }
            voicemailPath = path; voicemailPlayer = core.CreateLocalPlayer(core.OutputAudioDevice?.Id ?? core.DefaultOutputAudioDevice?.Id!, null!, IntPtr.Zero) ?? throw new PhoneInputException("Connect a speaker or headset to play voicemail.");
            voicemailPlayer.Listener.OnEofReached = _ => Interlocked.Exchange(ref playbackEnded, 1);
            voicemailPlayer.Open(path); voicemailPlayer.Start();
        }
        catch { StopVoicemail(); if (File.Exists(path)) { try { File.Delete(path); } catch (IOException) { pendingAudioCleanup.Add(path); } } throw new PhoneInputException("Voicemail could not play. Check your speaker or headset, or dial 121 to listen through your phone."); }
    }
    public void StopVoicemail()
    {
        CheckThread(); var player = voicemailPlayer; voicemailPlayer = null; Interlocked.Exchange(ref playbackEnded, 0);
        try { player?.Close(); }
        catch { if (player is not null) { try { player.Pause(); } catch { } pendingPlayers.Add(player); } Message = "Voicemail playback cleanup is pending. Calling remains available."; }
        finally
        {
            var path = voicemailPath; voicemailPath = null;
            if (path is not null) try { File.Delete(path); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { pendingAudioCleanup.Add(path); }
        }
    }
    private void InterruptVoicemail()
    {
        try { StopVoicemail(); } catch { Message = "Voicemail playback could not be cleared completely. Your incoming call remains available."; }
    }
    public void AttachVideo(IntPtr remote, IntPtr preview) { CheckThread(); videoVisible = remote != IntPtr.Zero; core.NativeVideoWindowId = remote; core.NativePreviewWindowId = preview; }
    private void RequireVideo(bool dialing = false) => CallingRules.Video(videoVisible, Cameras.Count > 0, core.CallsNb, conference is not null, dialing);
    public IReadOnlyList<PhoneDevice> Microphones => core.ExtendedAudioDevices.Where(x => x.HasCapability(AudioDeviceCapabilities.CapabilityRecord)).Select(x => new PhoneDevice(x.Id, x.DeviceName)).ToArray();
    public IReadOnlyList<PhoneDevice> Speakers => core.ExtendedAudioDevices.Where(x => x.HasCapability(AudioDeviceCapabilities.CapabilityPlay)).Select(x => new PhoneDevice(x.Id, x.DeviceName)).ToArray();
    public IReadOnlyList<string> Cameras => core.VideoDevicesList.Where(x => !x.Contains("StaticImage", StringComparison.OrdinalIgnoreCase)
#if PHONE_MEDIA_FIXTURE
        || mediaFixture?.StaticImage is not null
#endif
    ).ToArray();
    public void SetMicrophone(string id) { CheckThread(); var device = core.ExtendedAudioDevices.FirstOrDefault(x => x.Id == id && x.HasCapability(AudioDeviceCapabilities.CapabilityRecord)) ?? throw new PhoneInputException("Choose an available microphone."); core.InputAudioDevice = device; core.DefaultInputAudioDevice = device; }
    public void SetSpeaker(string id) { CheckThread(); var device = core.ExtendedAudioDevices.FirstOrDefault(x => x.Id == id && x.HasCapability(AudioDeviceCapabilities.CapabilityPlay)) ?? throw new PhoneInputException("Choose an available speaker."); core.OutputAudioDevice = device; core.DefaultOutputAudioDevice = device; }
    public void SetCamera(string camera) { CheckThread(); if (!Cameras.Contains(camera)) throw new PhoneInputException("Choose an available camera."); core.VideoDevice = camera; }
    public void SetRingtone(string path) { CheckThread(); if (path != "" && (!File.Exists(path) || !path.EndsWith(".wav", StringComparison.OrdinalIgnoreCase) || new FileInfo(path).Length > 32 * 1024 * 1024)) throw new PhoneInputException("Choose a WAV ringtone smaller than 32 MB."); core.Ring = path; }
    private LiveCall View(Call call)
    {
        if (!identities.TryGetValue(call, out var id)) identities[call] = id = Guid.NewGuid();
        return new(id, Profile(call).Id, call.RemoteAddress.DisplayName ?? call.RemoteAddress.Username, call.RemoteAddress.Username, call.State, call.Dir == CallDir.Incoming, call.Duration, call.CurrentParams?.VideoEnabled == true || call.RemoteParams?.VideoEnabled == true, call.MicrophoneMuted, call.CameraEnabled);
    }
    private PhoneProfile Profile(Call call) => accounts.Values.FirstOrDefault(x => x.Account == call.Params?.Account || x.Profile.Sip.Username == call.ToAddress?.Username).Profile ?? accounts.Values.Single(x => x.Profile.Sip.Username == call.CallLog.LocalAddress.Username).Profile;
    private Call Find(Guid id) => identities.FirstOrDefault(x => x.Value == id && core.Calls.Contains(x.Key)).Key ?? throw new PhoneInputException("That call has ended.");
    private Call Required() => selected ?? throw new PhoneInputException("Choose an active call first.");
    private void CallChanged(LCore _, Call call, CallState state, string ignored)
    {
        if (state is CallState.IncomingReceived or CallState.OutgoingInit) InterruptVoicemail();
        if (state == CallState.IncomingReceived && core.CallsNb > 2) { call.Decline(Reason.Busy); return; }
#if PHONE_MEDIA_FIXTURE
        if (mediaFixture is not null && !decodedFrames.ContainsKey(call))
        {
            decodedFrames[call] = 0; call.Listener.OnNextVideoFrameDecoded = observed => { decodedFrames.AddOrUpdate(observed, 1, (_, count) => count + 1); rearmFrames.Enqueue(observed); };
        }
        if (mediaFixture is not null && state == CallState.StreamsRunning && call.CurrentParams.VideoEnabled) call.RequestNotifyNextVideoFrameDecoded();
#endif
        if (!history.ContainsKey(call)) history[call] = (Profile(call).Id, DateTimeOffset.UtcNow, false);
        if (state == CallState.StreamsRunning) { var old = history[call]; history[call] = (old.Profile, old.Started, true); }
        if (selected is null) selected = call;
        if (state == CallState.UpdatedByRemote && call.RemoteParams.VideoEnabled != call.CurrentParams.VideoEnabled) { call.DeferUpdate(); Message = "The other person requested video. Choose Accept video or Audio only."; }
        if (state == CallState.Paused && pending is not null) { var next = pending; pending = null; next(); }
        if (state is CallState.End or CallState.Error)
        {
            if (history.Remove(call, out var entry)) CallFinished?.Invoke(entry.Profile, call.RemoteAddress.Username, call.Dir == CallDir.Incoming, entry.Started, call.Duration, entry.Answered);
            if (call == selected) selected = core.Calls.FirstOrDefault(x => x != call && x.State is not (CallState.End or CallState.Error or CallState.Released));
            if (call == consultation) consultation = null; if (core.CallsNb <= 1) conference = null;
            Message = state == CallState.Error ? "The call could not connect. Check the number or try again." : "Call ended";
        }
        if (state == CallState.Released) { identities.Remove(call); history.Remove(call); }
        Changed?.Invoke();
    }
#if PHONE_MEDIA_FIXTURE
    internal void ConfigureMediaFixture(NativeMediaFixture fixture)
    {
        CheckThread(); fixture.Validate();
        if (mediaFixture is null || fixture.Root != mediaFixture.Root || accounts.Count != 0 || core.CallsNb != 0) throw new InvalidOperationException("Only a fresh isolated native media core may be configured.");
        core.RootCaData = fixture.CaPem; core.UseFiles = true; core.PlayFile = fixture.InputWav; core.RecordFile = fixture.OutputWav; core.Ipv6Enabled = false;
#pragma warning disable CS0612 // Fixture-only forced advertisement; actual loopback bind keys are set before core creation.
        core.NatAddress = "127.0.0.1";
#pragma warning restore CS0612
        var policy = core.CreateNatPolicy(); policy.StunEnabled = false; policy.IceEnabled = false; policy.TurnEnabled = false; core.NatPolicy = policy;
        var transport = Factory.Instance.CreateTransports(); transport.UdpPort = 0; transport.TcpPort = 0; transport.TlsPort = -2; core.Transports = transport;
        if (fixture.StaticImage is not null) { core.StaticPicture = fixture.StaticImage; core.StaticPictureFps = 15; core.VideoDevice = core.VideoDevicesList.First(x => x.Contains("StaticImage", StringComparison.OrdinalIgnoreCase)); }
        if (!core.IsVerifyServerCertificates || !core.IsVerifyServerCn || !core.IsMediaEncryptionMandatory) throw new InvalidOperationException("Media fixture weakened production transport policy.");
    }
    internal void FixtureStartConferenceRecording(string ownedPath)
    {
        CheckThread(); if (mediaFixture is null || conference is null) throw new InvalidOperationException("Only an active isolated conference may be recorded.");
        mediaFixture.NewOutput(ownedPath); if (conference.StartRecording(ownedPath) != 0) throw new InvalidOperationException("The native conference recorder refused.");
    }
    internal void FixtureStopConferenceRecording()
    {
        CheckThread(); if (mediaFixture is null || conference is null || conference.StopRecording() != 0) throw new InvalidOperationException("The native conference recorder did not stop.");
    }
    internal NativeLocalPlaybackSnapshot FixturePlaybackSnapshot()
    {
        CheckThread(); if (mediaFixture is null) throw new InvalidOperationException("No media fixture is active.");
        return new(voicemailPlayer?.State.ToString() ?? "Closed", voicemailPlayer?.Duration ?? 0, voicemailPlayer?.CurrentPosition ?? 0, voicemailPath is not null && File.Exists(voicemailPath));
    }
    internal NativeFixtureSnapshot FixtureSnapshot(bool clearDtmf = false)
    {
        CheckThread(); if (mediaFixture is null) throw new InvalidOperationException("No media fixture is active.");
        var calls = core.Calls.Select(call => { var view = View(call); var parameters = call.CurrentParams; var definition = parameters?.ReceivedVideoDefinition; return new NativeMediaCallSnapshot(view.Id, call.State.ToString(), parameters?.MediaEncryption.ToString() ?? "None", call.AudioStats?.SrtpSuite.ToString() ?? "Invalid", parameters?.UsedVideoPayloadType?.MimeType ?? "", decodedFrames.GetValueOrDefault(call), (int)(definition?.Width ?? 0), (int)(definition?.Height ?? 0), parameters?.ReceivedFramerate ?? 0); }).ToArray();
        var dtmf = receivedDtmf.ToArray(); if (clearDtmf) receivedDtmf.Clear();
        return new(core.IsVerifyServerCertificates && core.IsVerifyServerCn, core.IsMediaEncryptionMandatory, calls, dtmf);
    }
#endif
    // Pinned5.5.23 chat.c returns chat_deny_code!=None from the misleadingly named getter.
    // The native fixture must prove enable=false/disable=true before this adapter can survive an SDK change.
    private bool ChatDenied => core.ChatEnabled;
    internal NativeAuthStorageProof? AuthStorageProof { get; private set; }
    internal bool VerifyVolatileAuth(string secret)
    {
        CheckThread(); ConnectionRules.RequireIdle(core.CallsNb);
        if (accounts.Count != 0) throw new InvalidOperationException("Only the empty native fixture may inspect auth persistence.");
        var auth = Factory.Instance.CreateAuthInfo("owm-fixture", "owm-fixture", secret, null!, "invented.invalid", "invented.invalid");
        try
        {
            core.AddAuthInfo(auth); var config = core.Config.Dump();
            var count = core.AuthInfoList.Count(); var databaseDisabled = !core.DatabaseEnabled; var limeDisabled = !core.LimeX3DhEnabled; var chatDisabled = ChatDenied;
            core.EnableChat(); var allowedFlag = core.ChatEnabled; core.DisableChat(Reason.NotAcceptable); var deniedFlag = core.ChatEnabled;
            var denyTransitions = chatDisabled && !allowedFlag && deniedFlag;
            var saveDisabled = core.Config.GetInt("sip", "save_auth_info", 1) == 0; var storeDisabled = core.Config.GetInt("sip", "store_auth_info", 1) == 0;
            var configSecret = config.Contains(secret, StringComparison.Ordinal); var configUser = config.Contains("owm-fixture", StringComparison.Ordinal);
            core.Stop();
            var files = Directory.EnumerateFiles(nativeFiles.Path, "*", SearchOption.AllDirectories).ToArray(); var unexpectedDb = 0; var unexpectedConfig = 0; var fileSecret = false; var complete = files.Length <= 256;
            foreach (var file in files)
            {
                var name = Path.GetFileName(file); if (name.EndsWith(".db", StringComparison.OrdinalIgnoreCase) || name.Contains(".sqlite", StringComparison.OrdinalIgnoreCase)) unexpectedDb++;
                if (new[] { ".ini", ".rc" }.Contains(Path.GetExtension(file), StringComparer.OrdinalIgnoreCase) || name.Contains("linphonerc", StringComparison.OrdinalIgnoreCase)) unexpectedConfig++;
                if (new FileInfo(file).Length > 2 * 1024 * 1024 || (File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) { complete = false; continue; }
                fileSecret |= System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(file)).Contains(secret, StringComparison.Ordinal);
            }
            AuthStorageProof = new(count, databaseDisabled, limeDisabled, chatDisabled, saveDisabled, storeDisabled, denyTransitions, configSecret, configUser, true, files.Length, unexpectedDb, unexpectedConfig, fileSecret, complete);
            return AuthStorageProof.Passed;
        }
        finally { core.RemoveAuthInfo(auth); core.ClearCallLogs(); }
    }
    private void CheckThread() { ObjectDisposedException.ThrowIf(disposed, this); if (Environment.CurrentManagedThreadId != thread) throw new InvalidOperationException("Native phone operations require its dispatcher."); }
    public void Dispose()
    {
        if (disposed) return; CheckThread(); if (Busy) throw new PhoneInputException("Finish your calls before closing the phone."); StopVoicemail(); StopCamera(); foreach (var id in accounts.Keys.ToArray()) Remove(id); core.ClearCallLogs(); core.ClearAllAuthInfo(); core.Stop(); nativeFiles.Dispose(); disposed = true;
    }
}
