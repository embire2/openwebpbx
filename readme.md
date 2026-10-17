# OpenWeb PBX

**1.0.15:** department staff roles and private invitations, guided desk-phone moves with original credentials, and first-call/provider failover results. [Downloads](https://github.com/embire2/openwebpbx/releases/tag/v1.0.15) · [Install](docs/installing-1.0.15.md) · [Staff access](docs/department-staff.md) · [Phone handover](docs/desk-phone-handover.md) · [First calls](docs/core-calling.md). Fresh installation, signed upgrade/recovery, authorization and decoded software-phone calling passed. Physical Yealink W60B/Fanvil V62W tests await handset access; live-carrier cutover remains required. [Evidence and limits](docs/feature-coverage.md#department-staff-phone-handover-and-provider-evidence--1015).

Google Play information: [Privacy](https://openwebpbx.com/privacy) · [Terms](https://openwebpbx.com/terms) · [Delete account and data](https://openwebpbx.com/delete).

An open-source, multi-tenant PBX powered by FreeSWITCH, with a Windows 11 inspired administration desktop.

## Version 1.0.14 — simpler users and department routing

New users receive a free, editable extension automatically. Departments can include users and call-handling objects, with office-hour routing, editable outbound restrictions and Android directory visibility. The Android app is now **OpenWebPBX Free Phone**, version **1.0.14 / code 114**, retaining its existing application and signing identity. See the [user/group guide](docs/users-and-departments.md) and [installation guide](docs/installing-1.0.14.md). Use the [1.0.14 downloads](https://github.com/embire2/openwebpbx/releases/tag/v1.0.14). Fresh installation, signed upgrade/recovery, native calls, administration layouts and Android replacement passed. [Release and deployment status](docs/feature-coverage.md#users-and-departments--1014) records the exact checks and remaining limits.

## Windows Server 1.0.13 development

Version **1.0.13** is being prepared for Windows Server 2025 x64 with its own server package and signed update feed. It brings the current core web/calling workflows to Windows and adds restored-phone registration, local audio conversion, global queued mail, notification permissions, portable hold music, encrypted scheduled backups/restore and automatic public certificate management. The .NET 10/Visual Studio 2026 WinUI manager has built and opened responsively on Windows Server 2025. No 1.0.13 download is published yet.

The current Windows candidate passed fresh installation, native internal calling and audio, encrypted backups, same-version reapply, forced recovery, both manager-reopening paths and independent verification of its complete package. A Windows test also proved the corrected updater waits through a busy lock and recovers automatically without a manual restart. An encrypted backup also restored successfully onto a separate clean Windows server, preserving phone credentials, settings and media, with working internal audio and voicemail. The signed newer-version test also passed: genuine HTTPS downloads, exact recovery from an intentional failure, a successful newer build and automatic updater/manager recovery, with original data preserved. Migration from the supplied server's original 1.0.6 installation remains on hold while unexplained changes to copied test files await host investigation. A fresh read-only check confirmed the original five services remain running with firewalls enabled. Follow the [1.0.13 release plan](3CX.md#windows-1013-release-plan) for the current result of each step.

Debian and Android now release **1.0.14** independently of the frozen Windows candidate. See the [Windows candidate guide](docs/installing-1.0.13.md) and [qualification record](docs/feature-coverage.md#windows-server-return--1013). The Windows administration manager and planned Windows calling client have separate roles.

The [hosted admin instance](https://call.openweb.co.za/) and current source now find provider addresses from the server name automatically. Incoming IP addresses are an optional Advanced override. This 2026-10-15 hosted patch preserves existing trunks; the immutable 1.0.12 downloads retain their original bytes. See [provider setup](docs/core-calling.md).

## Version 1.0.12

This version focuses on moving existing direct SIP phones after a supported 3CX V20 restore: preserve original extension numbers, separate Authentication IDs and password bytes; choose the new phone domain once; retain existing Android accounts and shared routes. It adds owned public phone addresses, source group/queue ringing order, caller-local queue timeouts, stable live agent state, Ring My Mobile and **Connect Provider and Numbers** for an atomic handover. [Desk-phone instructions](docs/desk-phone-handover.md) cover Yealink W60B and Fanvil V62W.

The supported source inventory, original-phone registration, ring groups, queues, menus and decoded audio checks passed. Fresh installation, the installed updater, forced recovery and admin browser checks also passed. Final Android, public-asset, production, physical-phone and carrier results are tracked in [feature coverage](docs/feature-coverage.md#restore-and-desk-phone-handover--1012). New server assets target **Debian 13 only**; the standalone Android app remains native. The [matching installation guide](docs/installing-1.0.12.md) includes the recoverable native registrar upgrade. Use the [1.0.12 downloads](https://github.com/embire2/openwebpbx/releases/tag/v1.0.12) and matching server/app versions. Physical phones and customer carriers still require their controlled first-call checks.

Published on 2026-10-13 at immutable tag `061f83c81`. All eight complete downloads and signed update metadata passed; the original installed updater completed its HTTPS upgrade and all 7,113 production mappings/preservation checks passed. The shared OpenWeb phone address is **openweb.sip.openwebpbx.com** with trusted SIP TLS; the admin address is **https://call.openweb.co.za/**. Android minimum **1.0.12** is required across current/future tenants, preserving their later-release preferences. [Publication and production evidence](docs/feature-coverage.md#publication-and-production).

## Historical version 1.0.11

OpenWeb PBX is a nonprofit, open-source project building a free PBX with the everyday simplicity people value in 3CX. Our roadmap first covers those familiar calling workflows, then new features. Complete 3CX parity remains a goal; the [roadmap](3CX.md) records the remaining work and evidence. [Core system status](docs/core-system-status.md) provides the built-feature inventory and all 133 goals, with 21 accepted and 112 still open.

Version 1.0.11 packages the **Debian 13 amd64 server** and **standalone native Android app**, with signed update metadata, checksums and corresponding source. Use the [1.0.11 release page](https://github.com/embire2/openwebpbx/releases/tag/v1.0.11) for matching assets and [feature coverage](docs/feature-coverage.md) for publication and qualification evidence. New server development currently targets Debian 13. The [previous Windows Server 1.0.7 package](https://github.com/embire2/openwebpbx/releases/tag/v1.0.7) remains available; it includes an administration manager. A separate [native Windows calling client](docs/windows-client-plan.md), with emailed one-use setup files, is planned.

Published on 2026-10-13 from immutable tag `15e1edcd1`: all eight complete public downloads and the signed sequence-111 feed passed verification. Production completed its server upgrade with customer/reviewer preservation and all 7,096 live mappings checked; nineteen normal HTTPS checks activated minimum direct-Android 1.0.11 (Android code 111) across tenants. Genuine public Android 1.0.10→1.0.11 replacement and final native-fixture cleanup passed in [feature coverage](docs/feature-coverage.md#visible-call-controls-personal-settings-and-instance-phone-floor--1011).

This release makes **Call Hold / Resume Call** visible on every active-call page, adds personal **Settings**, and lets an instance administrator require a minimum direct-Android release across current and future tenants. Tenant preferences remain saved for later releases. Fresh Debian, installed upgrade/rollback and six final signed direct-app and four AAB-derived native Settings/hold/conference/recovery/audio-focus cases passed. The notification-store and complete-SDK-source corrections introduced in 1.0.10 are retained; [feature coverage](docs/feature-coverage.md#visible-call-controls-personal-settings-and-instance-phone-floor--1011) records separate publication, production and phone checks. Physical locked/idle handset wake-up remains unqualified.

- **SIP Trunks & First Calls:** a guided provider form, initial disabled connections, an ordered backup provider, readiness messages and controlled call-check records.
- **Office Hours & Call Routing:** multiple periods, overnight hours, breaks, holidays, temporary opening changes and a routing preview.
- **Receptionist Switchboard:** live calls and availability, with hold, transfer, pickup, parking and retrieval through connected phones.
- **Queues, Callbacks & Wallboard:** priority groups, position announcements, overflow, callback ordering, live totals and scoped reports.
- **Automatic Backups & Restore:** encrypted scheduled instance backups, retention, optional pinned-key SFTP copy and guarded recovery onto a separate clean Debian installation, including selected media.
- **Android:** visible Call Hold/Resume Call, safe theme/ringtone/startup/contact-sort Settings, transfers, consultation recovery, second-call handling, three-way calling, network recovery and availability/queue controls. Optional native incoming wake-up uses source-available UnifiedPush libraries and server-generated keys; your own Firebase project is not required.
- **Phone updates:** signed direct-app downloads and an instance minimum across tenants, with tenant preferences, active-call deferral, urgent-call access and Android confirmation preserved. Google Play updates depend on a separately approved published store release.
- **Hold music:** a bundled CC0 lo-fi track, with original audio, license provenance and telephone-ready variants. Existing custom music is preserved.

Read the [installation guide](docs/installing-1.0.12.md), [core calling guide](docs/core-calling.md), [Android guide](docs/android.md), [backup guide](docs/backups.md), [updates](docs/updates.md) and [feature coverage](docs/feature-coverage.md). Qualify your own provider and handsets before a production cutover. Physical locked/idle incoming wake-up, Wi-Fi/mobile handover, broader hardware coverage and Google Play approval remain open. Android can require installation confirmation and a tap to reopen.

The [homepage](https://openwebpbx.com/) explains the project and lists releases. Its static source and deployment instructions are in [website/README.md](website/README.md). Server and client software retain their component licenses; no OpenWeb software license fee is charged. Hosting, carriers and optional external services have their own costs.

## Desktop workspace

- Centered taskbar, searchable Start menu, and permission-aware application library.
- Independent administration windows with drag, resize, minimize, maximize, edge snapping, and taskbar restore.
- Existing PBX forms, permissions, CSRF protection, and authentication remain in use.
- Live PBX connection, extension, registration, and channel status for the current domain.
- Light and dark themes, wallpaper selection, full screen, clock, and calendar.
- Responsive layouts and keyboard navigation. Use Ctrl+Space to search apps and Ctrl+Alt+D to show the desktop.
- Unsaved form changes are checked before a desktop window is closed.

## Repository

Source: https://github.com/embire2/openwebpbx

The `customization` branch contains OpenWeb PBX. The `upstream` remote tracks the original project; this fork started from its stable `5.6` branch.

## Existing installations

Follow the [existing-installation update procedure](docs/installing-1.0.12.md#existing-debian-server) to deploy the matching web application, background service and call scripts. Keep `/etc/fusionpbx`, PostgreSQL, and FreeSWITCH configuration in their existing locations. These operational identifiers are retained for compatibility. Use the release installers for a fresh server.

Back up the application and database before replacing files. Apply the branding migration as the PostgreSQL administrator:

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -d fusionpbx -f /var/www/fusionpbx/core/desktop/resources/branding.sql
```

The primary workspace is `/core/desktop/`. The original PBX dashboard remains available as an application at `/core/dashboard/?classic=1`. Application pages can also be opened directly.

If your installation uses the upstream Fail2ban filters, update their log-prefix patterns to accept `(?:FusionPBX|OpenWeb PBX)` and reload Fail2ban. Existing jail names and filesystem paths stay compatible. Reload PHP-FPM and clear the application settings/template cache after deployment, then sign in again.

New source-code assets need no JavaScript build step. The desktop uses local assets and the existing administration endpoints.

## License and provenance

OpenWeb PBX is a derivative of [the original project](https://github.com/fusionpbx/fusionpbx). Original MPL 1.1 license and copyright notices are retained in the source files. The original project documentation remains available at https://docs.fusionpbx.com/. FreeSWITCH is maintained separately at https://github.com/signalwire/freeswitch.

The native Android client in `mobile/android/` is licensed AGPL-3.0-or-later and includes separately credited open-source components. Its corresponding source and notices accompany the Android release. The existing server licenses are unchanged.

The bundled hold track is Seth_Makes_Sounds’ **Lofi Beat Loop Schmoop**, released under CC0. Original audio, hashes, conversion details and credits are in [the music guide](docs/music-on-hold.md).
