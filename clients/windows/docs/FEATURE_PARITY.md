# Android18 source inventory → Windows1.0.0

Source baseline08d80370133fc5de9367940fbe529ad87ee43978; Android app version1.0.18/code118, Liblinphone5.5.23. The first table describes the intended Windows scope; measured component results and remaining acceptance appear separately below. Source presence is not a successful native test.

| Feature | Android source | Windows scope |
|---|---|---|
| Tenant address, manual extension/app-password login, one-use QR/JSON setup | PhoneStore, ProfileRules, MainActivity | Strict tenant HTTPS only; webcam QR plus file/URI activation; no plaintext SIP password in setup files |
| Ten saved profiles, concurrent registrations, select/add/edit/remove/revoke | PhoneStore, PhoneService | Per-user DPAPI store; idle-only account changes; preserve active calls |
| Own app-password change, other-device revocation | MainActivity, pbx_mobile_password | Existing API semantics; never replace restored desk-phone credentials |
| Dialpad, incoming answer/reject, call waiting/switching, hangup, microphone mute, DTMF | PhoneService, IncomingCallActivity | Actual native SIP/media and notifications; no framed web UI |
| Hold/resume with PBX music; blind/consult transfer, cancel/complete consultation, local conference, participant audio controls | PhoneService | Actual native SDK operations and controlled media tests |
| Camera/video answer/upgrade/decline, audio-only mode, camera choice, privacy on locked/hidden app | CallVideo, VideoCallActivity | Native capture/rendering, explicit camera controls and Windows privacy/lifecycle adaptation |
| Directory/search/name-extension sorting, history and queued call-log sync | MainActivity, PhoneService | Existing bearer API, profile-scoped data and retry queue |
| Voicemail list/read/delete/private audio playback | MainActivity, PhoneApi | Existing API; private bounded temporary playback and cleanup |
| Presence/status duration and queue login/receiving state | MainActivity | Existing availability/set_status/queue_status API |
| Audio route/devices, ringtone, theme/startup page, safe preferences, connection diagnostics | PhonePreferences, MainActivity | Windows-native device/ringtone/theme/startup settings, tray/system notifications, accessibility |
| Optional/mandatory update visibility and active-call-safe installation | direct UpdateManager, play UpdateManager | Store-managed updates for Store; independent signed WindowsPhone feed for direct distribution |
| Terms/privacy/delete/licences | MainActivity | Public external links, licence/source bundle and Store submission disclosures |
| Incoming availability while phone backgrounded | PhoneService, PushConnection | Resident/tray native registration and Windows notifications; no dependency on Android Firebase/UnifiedPush |

Android proximity/cheek protection is hardware-specific; Windows substitutes explicit device/privacy controls. Android source does not demonstrate a native Windows feature, physical hardware or Store acceptance.

## Evidence as of2026-10-23

`Implemented` below means source exists and has been reviewed/type-checked; it does not mean the complete feature has passed Windows execution. The current actual baseline is source64effe1c63f854ff0ba873c2e7f8733ff97f878d/run39984012407:172 core controls with explicit HTTP/store doubles,25 actual Windows DPAPI/native-Core/privacy controls,23 real logged-out UI Automation controls and compilation of both direct and Store channel code. The Store branch has not contacted a real published Store listing. Bounded original artifact12514966699/SHAf2575c802801cca4f67232b96670497ec9e510ae19051d93a0548c4eafe6a74d is retained privately.

| Area | Implemented source | Actual native qualification | Still required |
|---|---|---|---|
| Native WinUI shell, accounts/settings/keypad, icon and initial work-area fit | Yes | Responsive WindowsServer2025 hosted desktop;23 UIA checks and screenshots | Windows11 and physical-device/accessibility review, signed-package launch |
| Tenant restrictions, bounded one-use file/URI, QR/manual code and login | Yes | Domain/parser/body-deadline controls; actual account controls are visible | Owned-tenant login/enrollment, generated welcome attachment and OS file/URI activation, webcam QR |
| Ten profiles, select/rename/re-sign-in/remove and own password | Yes | Actual DPAPI/ACL/tamper storage; profile identity/late-call controls use an explicit store double | Concurrent real registrations, revocation/re-sign-in/password API and preservation across real package updates |
| Native credential privacy and TLS/SRTP configuration | Yes | Real Core starts with strict policy, inverted chat API semantics checked, no native auth/config/DB residue in the tested shutdown; production fixture types absent. Later isolated media runs prove wrong-CA and wrong-hostname refusal plus trusted TLS registration for three invented peers | Successful negotiated SRTP calling and all media states |
| Dial/incoming/waiting/mute/DTMF/hold/transfer/conference/video | Yes | No completed controlled calling result yet | Twelve-case native lab with real TLS/SRTP/decoded software audio/VP8, then physical mic/speaker/camera checks |
| Directory, presence, queues, history sync | Yes | Bounded HTTP and queue/store logic controls; no live client API acceptance | Owned PBX end-to-end API and independent profile scopes |
| Voicemail list/read/delete and native local WAV playback | Yes; uses Liblinphone, not Media Foundation | No native playback acceptance yet | SDK player advancement/interruption/private-file cleanup plus real speaker test |
| Tray/startup/devices/ringtone/notifications/privacy | Yes | Initial native window and settings controls; no physical device or notification delivery claim | Real background incoming/lock/resume/device/ringtone/permission-denial tests |
| Direct update verification, Store-managed path, idle protection | Yes | Real DPAPI anti-replay/tamper; RSA/hash/download/ZIP controls; both channels compile | Active-call deferral with real media; signed development MSIX install/confirmation/update/relaunch/rollback/cleanup |
| MSIX/Store submission and separate Server direct route | Source/manifest/docs prepared | Actual development MakeAppx/signing reaches installation; PackageManager then refuses certificate trust. Owned certificate/key removal verified, full machine-vector preservation still fails | Reviewed disposable trust/preservation qualification, dependency inventory/redistribution, packaged launch/update tests, final owner Partner Center identity, source bundle and Store review |
| Public legal/source notices | Windows privacy section and external links published; submission documents prepared | Existing legal URLs returned HTTPS200; reviewed Windows tester privacy section published2026-10-23 | Update final binary/source/licence inventory and owner submission disclosures; no legal or Store approval implied |

The media-lab binary uses compile-only file/CA/static-image seams and must report that it differs from the production managed assembly. Software decoding does not prove physical hardware or GUI video rendering. Development-package tests use a nonce identity and disposable public test key; they cannot qualify the production update channel or Store acceptance. Fully exited Windows push wake remains a disclosed external-registration dependency; resident tray/startup calling is the implemented route.

Later media runs39998975773/source79c36ea17 and40002543418/source9194e35d3 each complete exactly one of12 cases: TLS trust/hostname refusals followed by trusted registration. They do not complete an audio/video call. The latter outgoing-audio case observes caller SIP488/NotAcceptable before the target signals an incoming call. Owned native cleanup/engine shutdown pass, but complete system-state preservation fails at service states. These partial results neither replace the source64 build/startup baseline above nor qualify calling, packages or physical hardware.

Development-package40003127796/source4d4577499 fails actual installation with0x800B0109. Its original closed receipt proves zero remaining owned private/public certificates and no owned CNG key, with unchanged pre-existing package inventory. It also reports an added CA-store entry and changed registry content, so exact cleanup/preservation remains false. No signed installation, successful update/relaunch or production trust result is claimed.
