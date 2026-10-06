# OpenWeb PBX

An open-source, multi-tenant PBX powered by FreeSWITCH, with a Windows 11 inspired administration desktop.

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

Install the standard Debian stack using the upstream installer, then deploy this fork over the application checkout. Keep `/etc/fusionpbx`, PostgreSQL, and FreeSWITCH configuration in their existing locations. These operational identifiers are retained for compatibility.

Back up the application and database before replacing files. Apply the branding migration as the PostgreSQL administrator:

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -d fusionpbx -f /var/www/fusionpbx/core/desktop/resources/branding.sql
```

The primary workspace is `/core/desktop/`. The original PBX dashboard remains available as an application at `/core/dashboard/?classic=1`. Application pages can also be opened directly.

If your installation uses the upstream Fail2ban filters, update their log-prefix patterns to accept `(?:FusionPBX|OpenWeb PBX)` and reload Fail2ban. Existing jail names and filesystem paths stay compatible. Reload PHP-FPM and clear the application settings/template cache after deployment, then sign in again.

New source-code assets need no JavaScript build step. The desktop uses local assets and the existing administration endpoints.

## License and provenance

OpenWeb PBX is a derivative of [the original project](https://github.com/fusionpbx/fusionpbx). Original MPL 1.1 license and copyright notices are retained in the source files. The original project documentation remains available at https://docs.fusionpbx.com/. FreeSWITCH is maintained separately at https://github.com/signalwire/freeswitch.
