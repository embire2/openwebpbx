# Android18 source inventory → Windows1.0.0

Source baseline08d80370133fc5de9367940fbe529ad87ee43978; Android app version1.0.18/code118, Liblinphone5.5.23. Every row below is implementation/acceptance pending for Windows. Source presence is not a successful native test.

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
