# OpenWeb PBX

An open-source, multi-tenant PBX powered by FreeSWITCH, with a Windows 11 inspired administration desktop.

## Version 1.0.2

Native **Windows Server** and **Debian 13** installation packages are available on the [release page](https://github.com/embire2/openwebpbx/releases/tag/v1.0.2). This release adds queue callbacks, Hotel Services, confirmed wake-up calls, a C#/.NET 10 background service and a WinUI 3 manager built with Visual Studio 2026.

Read the [installation guide](docs/installing-1.0.2.md), [callback and hotel guide](docs/callbacks-and-hotels.md), and [feature coverage](docs/feature-coverage.md). OpenWeb PBX does not yet provide complete 3CX feature parity. The Windows manager is an administration app; replacement calling apps and PMS/billing integrations remain outstanding.

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

Follow the [existing-installation update procedure](docs/installing-1.0.2.md#updating-an-existing-installation) to deploy the matching web application, background service and call scripts. Keep `/etc/fusionpbx`, PostgreSQL, and FreeSWITCH configuration in their existing locations. These operational identifiers are retained for compatibility. Use the release installers for a fresh server.

Back up the application and database before replacing files. Apply the branding migration as the PostgreSQL administrator:

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -d fusionpbx -f /var/www/fusionpbx/core/desktop/resources/branding.sql
```

The primary workspace is `/core/desktop/`. The original PBX dashboard remains available as an application at `/core/dashboard/?classic=1`. Application pages can also be opened directly.

If your installation uses the upstream Fail2ban filters, update their log-prefix patterns to accept `(?:FusionPBX|OpenWeb PBX)` and reload Fail2ban. Existing jail names and filesystem paths stay compatible. Reload PHP-FPM and clear the application settings/template cache after deployment, then sign in again.

New source-code assets need no JavaScript build step. The desktop uses local assets and the existing administration endpoints.

## License and provenance

OpenWeb PBX is a derivative of [the original project](https://github.com/fusionpbx/fusionpbx). Original MPL 1.1 license and copyright notices are retained in the source files. The original project documentation remains available at https://docs.fusionpbx.com/. FreeSWITCH is maintained separately at https://github.com/signalwire/freeswitch.
