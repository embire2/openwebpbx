# Architecture and integration constraints

- C#/.NET10 WinUI3 desktop UI. Official template is scaffolded, built and launched on GitHub-hosted Windows before adapting its shell. Packaged MSIX is the Store model; a deliberate self-contained direct flavor supports WindowsServer2025DesktopExperience.
- Native Liblinphone5.5.23 matches Android's signalling/media stack. The official Windows64 SDK exposes a C# binding and native DLLs. Media runs natively; no Electron/CEF/WebView calling frame. The SDK's exact binary/source licence and corresponding-source inventory must be sealed before distribution.
- Pure domain/API/profile/update rules are separate from native SDK and WinUI, allowing meaningful platform-independent tests. The Windows adapter owns per-user DPAPI, process lifecycle, device enumeration, activation, notifications and native video surfaces.
- Existing bearer API remains tenant-scoped. Fresh login/enrolment creates a device-specific SIP account; it must never reuse or alter the restored extension's desk-phone password. Existing app-password change semantics revoke other devices without ending active calls.
- Backend blocker found in actual source: `pbx_mobile::enroll/login` currently reject non-Android platforms and insert literalAndroid. Any Windows support is implemented/tested only on this branch and separately reviewed by root before integration. Android18 behaviour and existing device/SIP tuples must remain exact.
- Store identity/publisher requires the owner's PartnerCenter reservation. Store builds cannot use a private self-updater. Direct builds require their own signed client feed and trust state, never the serverWindows or Android feed/minimum.

Primary guidance checked2026-10-23:

- [Microsoft WinUI setup/templates](https://learn.microsoft.com/windows/apps/get-started/start-here)
- [Windows distribution choices](https://learn.microsoft.com/windows/apps/package-and-deploy/choose-distribution-path)
- [Windows App SDK system requirements](https://learn.microsoft.com/windows/apps/windows-app-sdk/system-requirements)
- [Liblinphone Windows/C# SDK integration](https://wiki.linphone.org/xwiki/wiki/public/view/Lib/Getting%20started/Windows%20UWP/)
- [Official Windows SDK releases](https://download.linphone.org/releases/windows/sdk/)
- [Official C# API reference](https://download.linphone.org/releases/docs/liblinphone/5.5/cs/)
- [Liblinphone licensing](https://www.linphone.org/en/liblinphone-voip-sdk/)
