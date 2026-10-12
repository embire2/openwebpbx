# OpenWeb PBX

An open-source, multi-tenant PBX powered by FreeSWITCH, with a Windows 11 inspired administration desktop.

## Version 1.0.10

OpenWeb PBX is a nonprofit, open-source project building a free PBX with the everyday simplicity people value in 3CX. Our roadmap first covers those familiar calling workflows, then new features. Complete 3CX parity remains a goal; the [roadmap](3CX.md) records the remaining work and evidence.

Version 1.0.10 packages the **Debian 13 amd64 server** and **standalone native Android app**, with signed update metadata, checksums and corresponding source. Use the [1.0.10 release page](https://github.com/embire2/openwebpbx/releases/tag/v1.0.10) for matching assets and [feature coverage](docs/feature-coverage.md) for publication and qualification evidence. New server development currently targets Debian 13. The [previous Windows Server 1.0.7 package](https://github.com/embire2/openwebpbx/releases/tag/v1.0.7) remains available; it includes an administration manager. A separate [native Windows calling client](docs/windows-client-plan.md), with emailed one-use setup files, is planned.

This patch repairs saving **Incoming Call Wake-up** settings on Debian and includes the tracked SDK source inputs omitted by the earlier archive filter. Setup migrates the private notification store automatically while preserving its identity and recovery files. Fresh installation, installed upgrade, rollback and complete tracked-source validation passed; [feature coverage](docs/feature-coverage.md#notification-store-permission-patch--1010-candidate) records the separate production and phone acceptance results. Physical locked/idle handset wake-up remains unqualified.

- **SIP Trunks & First Calls:** a guided provider form, initial disabled connections, an ordered backup provider, readiness messages and controlled call-check records.
- **Office Hours & Call Routing:** multiple periods, overnight hours, breaks, holidays, temporary opening changes and a routing preview.
- **Receptionist Switchboard:** live calls and availability, with hold, transfer, pickup, parking and retrieval through connected phones.
- **Queues, Callbacks & Wallboard:** priority groups, position announcements, overflow, callback ordering, live totals and scoped reports.
- **Automatic Backups & Restore:** encrypted scheduled instance backups, retention, optional pinned-key SFTP copy and guarded recovery onto a separate clean Debian installation, including selected media.
- **Android:** transfers, consultation recovery, second-call handling, three-way calling, network recovery and availability/queue controls. Optional native incoming wake-up uses source-available UnifiedPush libraries and server-generated keys; your own Firebase project is not required.
- **Hold music:** a bundled CC0 lo-fi track, with original audio, license provenance and telephone-ready variants. Existing custom music is preserved.

Read the [installation guide](docs/installing-1.0.10.md), [core calling guide](docs/core-calling.md), [Android guide](docs/android.md), [backup guide](docs/backups.md), [updates](docs/updates.md) and [feature coverage](docs/feature-coverage.md). Qualify your own provider and handsets before a production cutover. Physical locked/idle incoming wake-up, Wi-Fi/mobile handover, broader hardware coverage and Google Play approval remain open. Android can require installation confirmation and a tap to reopen.

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

Follow the [existing-installation update procedure](docs/installing-1.0.10.md#existing-debian-server) to deploy the matching web application, background service and call scripts. Keep `/etc/fusionpbx`, PostgreSQL, and FreeSWITCH configuration in their existing locations. These operational identifiers are retained for compatibility. Use the release installers for a fresh server.

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
