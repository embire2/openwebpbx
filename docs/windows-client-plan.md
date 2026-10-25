# Native Windows calling app

This is the implementation plan for roadmap **APP-02**, with **APP-05/06/07** activation, headset and availability dependencies. It is not an available Windows softphone release. The existing Windows manager administers the server and does not make calls. The PBX server is available separately for Debian 13 and Windows Server 2025; client acceptance is independent of either server release.

## Current verification — 25 October 2026

The Windows client remains unpublished. Its focused native tool-selection check passes on Windows, including the real numeric version case and original access-control/cleanup checks. The full development-package repeat40171083241 passes signed installation, native confirmation, automatic update/relaunch, protected account history/preferences and complete certificate/registry/package preservation and cleanup. All66 authority controls pass. Only failure diagnostics changed; no failure occurred in this repeat, so the earlier40168134715 UI/update cause remains unknown. This is development-package acceptance, with production signing, clean-machine distribution and Store certification still open.

Calling remains unqualified. The native test advances through secure setup, then the strict audio reader refuses the recorder output. Source review finds matching defects in the pinned SDK writer. A corrected fixture producer and first-data readiness helper have source review and41 managed checks. The isolated native contract test40241735286 stops after CMake configuration: its parent exits0, but owned Job descendants do not finish and require termination. Native compilation, factory selection, WAV output and managed-parser execution are unreached. The original audio parser, fresh-sample checks and full system-preservation requirement stay unchanged. The original media service-state changes and the newer fixture’s five state-only service differences remain unresolved; no actor or historical surviving process is inferred.

## Setup in three steps

1. The administrator opens **Users → Phone Provisioning → Send Windows setup**. The PBX sends the organisation's standard welcome email through the instance's global outgoing mail server, with the signed Windows app installer link and a small `OpenWeb-phone.openwebpbx` attachment.
2. The user installs the native app once, then opens the attachment. Windows opens OpenWeb PBX automatically. If the app is already installed, the user only opens the attachment.
3. The app shows the organisation/server and intended extension, with one **Connect** button. It exchanges the one-use invitation for private device credentials, then displays **Ready for calls**. No camera, QR code, phone password or server settings are needed.

The email also contains an HTTPS setup link and a **Open setup file** action for mail clients that block attachments. Mail delivery failure stays visible to the administrator. Resending replaces the previous invitation. Revoking the device removes both API and calling access without disconnecting the user's other phones.

## Setup-file contract

- A bounded JSON document (maximum 16 KiB) associated only with `.openwebpbx`; it is configuration data, never an executable or script.
- Version, application identifier, HTTPS server address, invitation identifier, opaque single-use code, intended extension/name, expiry and issuer/signature metadata. No SIP password, durable account token, service-account key or carrier credential.
- A configurable short invitation lifetime, initially 24 hours for emailed setup. QR invitations retain their existing ten-minute lifetime. Expired/used invitations show **Ask your administrator to send a new setup email**.
- The app validates schema, expiry, HTTPS certificate, issuer and signature before offering Connect. Self-hosted instances use their own issuer identity, shown clearly to the user; a signature alone does not establish trust in an unknown organisation.
- Enrollment remains atomic and idempotent. The server authorizes the extension and tenant, checks suspension and device limits, and consumes the invitation once. The client saves returned credentials before marking activation complete, so restart does not lose a consumed code.
- Windows DPAPI/Credential Locker protects local credentials. No credential-bearing URLs, command-line values, screenshots, diagnostic logs or email attachments.
- File activation is delivered to the existing app instance; opening the same email twice does not create a second account or concurrent calling engines. Switching accounts requires an explicit choice.

Microsoft documents native [file-type activation](https://learn.microsoft.com/en-us/windows/apps/develop/launch/handle-file-activation), including validation of untrusted files. Use the Windows App SDK activation APIs for WinUI 3, rather than UWP-only activation overrides.

## Native app and screens

Use **C#/.NET 10, WinUI 3 and Visual Studio 2026**, with a separately named `OpenWebPbx.Client` project. Use native Fluent controls, Windows themes/high contrast, keyboard navigation and Narrator. No website frame. Keep the existing administration manager separate.

The initial targets are Windows 11 and Windows Server 2025 with Desktop Experience. Other Windows editions remain unqualified. Pin the Windows App SDK only after a clean toolchain/build and OS support audit. Client support does not imply that these desktop operating systems can host the PBX server.

- **Keypad:** incoming/outgoing calling, caller details, microphone/speaker/Bluetooth selection, mute, hold, digits, blind/attended transfers, call waiting and three-way calls.
- **Contacts:** company/personal directory, search, availability and click-to-call.
- **Recents:** incoming, outgoing and missed calls, local dates and redial; offline uploads retry without duplicates.
- **Voicemail:** native playback, unread state and confirmed deletion, scoped to the user's own mailbox.
- **Status and queues:** Available/Away/Do Not Disturb, temporary status and assigned queue join/leave, using the shared server status API.
- **Settings:** connection check, audio devices, start on sign-in, updates, privacy, licenses and Disconnect.
- **Tray and notifications:** background ringing, Answer/Decline, missed calls and return to the active call. Lock/unlock and closing the window preserve the connection while the tray app remains running. Exiting the app makes it unavailable unless a separately qualified Windows push channel is implemented.

Use a native SIP/media engine through a narrow C# interface, initially evaluating the corresponding-source Linphone Windows SDK under the project's compatible license. Require trusted SIP TLS and SRTP, communication audio-device handling and tested codec interoperability. Keep the engine independent of XAML lifecycle. All engine access passes through one dispatcher; every call has independent state/history and a bounded recovery path.

## Packaging and updates

Default to a signed MSIX distribution with package identity, `.openwebpbx` file association and single-instance activation. Evaluate a signed bootstrap installer only if the audited server/desktop support matrix requires it. Source, notices and the exact native SDK source accompany each release.

Reuse the signed release feed and tenant update policy. Download and verify the complete package first; defer installation until all calls end. Windows controls installer consent and foreground launch restrictions. Retain a clear **Open OpenWeb PBX** notification if automatic reopening is unavailable. Keep the user's encrypted connection across replacement and support a tested rollback path. Do not advertise an unsigned package as ready for effortless end-user installation.

## Delivery and acceptance gates

| Stage | Complete when |
| --- | --- |
| W1 — Activation | Signed installer/file association; emailed file and HTTPS-link activation; one-use/expiry/resend; restart during enrollment; tenant/device removal and malicious-file refusal pass. SMTP is exercised with a local test sink before an owner-approved real email. |
| W2 — Voice | Actual local/remote internal and provider-approved outside calls have sustained audio both ways, secure registration/media, menu digits and correct independent history. |
| W3 — Call controls | Transfers and their failure recovery, waiting/switching, three-way audio, participant removal, pickup/parking through the core server and headset controls pass with actual endpoints. |
| W4 — Daily use | Directory, voicemail, status/queues, tray, notification answering, lock/unlock, audio-device changes and sleep/network recovery pass on the published OS/device matrix. |
| W5 — Distribution | Signed in-place update retains the account; required/optional policies defer active calls; installer failure recovery, source/license catalogue and fresh-PC setup pass. Publish a Windows **client** download only after these gates. |

Required external inputs are a Windows code-signing identity or verified Store distribution, representative Windows/headset devices and carrier-approved test endpoints. The existing test server and Visual Studio installation help development but do not establish broad client compatibility.

## Verification of this plan

Prepared 2026-10-12 from the existing native Android/device API, released administration manager, roadmap and Microsoft file-activation/WinUI guidance. This is a design document; no Windows client was created, installed or advertised as downloadable by this task.
