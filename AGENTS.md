# OpenWeb PBX workspace

## Working conventions

- The application name is OpenWeb PBX and the public repository is `embire2/openwebpbx`.
- Work on the `customization` branch. Keep the original project's license and copyright notices.
- Keep operational `fusionpbx` database, configuration, service, protocol-header, and filesystem identifiers compatible with the installed stack.
- Administration endpoints must retain their existing authentication, permissions, and CSRF checks. The desktop application launcher uses the permission-filtered menu.
- Local checkout: `/root/fusionpbx`. Live application: `/var/www/fusionpbx`. Deploy source changes without copying `.git`, `.env`, browser state, or validation artifacts.
- Optional Windows test credentials are in the local, untracked `.env` file. Never commit, print, or copy credentials into the live web root. Keep that file mode `600`.
- Update this file as work progresses. Record actual verification results and outstanding work without credentials.

## Progress — 2026-10-06

- FusionPBX stable 5.6 and FreeSWITCH 1.11.3 are installed. NGINX, PHP-FPM, PostgreSQL, FreeSWITCH, and Fail2ban are running.
- Renamed the public fork to `embire2/openwebpbx`; local and live Git remotes point to it.
- Rebranded visible application text, translations, phone provisioning defaults, email templates, logos, favicon, and login page. Original license notices and protocol identifiers remain intact.
- Implemented a Windows 11 inspired desktop: searchable Start menu, permission-filtered application library, movable/resizable windows, maximize, minimize, edge snapping, taskbar restore, light/dark themes, wallpaper preferences, fullscreen, clock, calendar, and per-domain PBX status.
- Deployed the desktop and branding migration. Administrator sign-in reaches `/core/desktop/`; 73 applications are available to the administrator. Live connection, extension, registration, and channel counts work.
- PHP syntax checks passed for 26 changed/new PHP files; JavaScript syntax and Git whitespace checks passed.
- Chromium browser checks passed for maximize/restore, minimize/taskbar restore, drag, resize, left-edge snapping, show desktop, multiple windows, application search, empty results, and all 73 launcher entries.
- Created a disabled temporary extension through the existing CSRF-protected form, verified persistence, then deleted the extension and voicemail through the UI. Live counts returned to zero. Unsaved-change confirmation worked.
- Verified dark theme in embedded applications, wallpaper/theme persistence after reload, fullscreen, calendar month navigation, and 390px mobile layouts. Browser console reported zero errors or warnings.
- Final styling checks passed for dark cards and headings. Search and list selection do not trigger false unsaved-change warnings. Unauthenticated desktop/status requests render the sign-in form.
- Published the verified source to public `embire2/openwebpbx` and set `customization` as the repository default branch. The live checkout now tracks `origin/customization`; existing optional app directories are preserved.
- The original IP address remains reachable with its self-signed certificate. The public application now uses trusted HTTPS at `https://call.openweb.co.za/`. SIP endpoint registration and external calling have not been tested because no real trunks or endpoints are configured.
- Optional Windows RDP settings were saved to the local `.env` with mode `600`; Git ignores that file and it is absent from the live web root. No Windows-specific issue required an RDP session.
- Pre-change application and database backups are stored privately under `/var/backups/openwebpbx`.

## Tenant workspace progress — 2026-10-06

- `call.openweb.co.za` resolves to this server. A Let's Encrypt certificate is installed and the HTTPS login is trusted. Certbot renewal timer and NGINX reload hook are enabled; renewal dry run passed.
- Created the requested CEO administrator privately; no credentials are stored in tracked files. Renamed the platform PBX domain to `call.openweb.co.za` and updated its standard dialplan contexts.
- Implemented invite-only tenant onboarding, expiring single-use invitations, isolated PBX service domains, published shared and tenant-owned templates, trunk presets, outbound call rules, extension/voicemail defaults, and domain business settings.
- Template data is encrypted with a key stored outside the web root. Service provisioning uses a transaction, a tenant service limit, and an idempotent request identifier. Template versions are recorded on each service.
- Tenant administrators do not receive global domain selection or cross-domain privileges. Session checks enforce tenant membership and suspension. New tenant workspaces expose only the service portal until a PBX service is opened.
- Enabled global email identities for central-host tenant sign-in. Added menu translations and pinned Tenant Services on the desktop. Unaccepted invitations can be renewed, invalidating the previous link.
- PostgreSQL integration checks passed for encryption, invitation renewal/replay, validation, tenant/domain/trunk/rule isolation, template ownership, service limits, repeated submissions, suspension, and preservation of existing services.
- Live HTTPS checks passed for CEO and tenant sign-in, invitation acceptance, CSRF rejection, two-tenant provisioning, extension access from the desktop, foreign domain/service denial, and suspension/reactivation. FreeSWITCH recognized extension 100 separately in both PBX realms and rejected it in the platform realm. Desktop and mobile portal/editor layouts were reviewed; the final editor reported zero browser errors or warnings.
- Published a Business PBX starter template with two extensions and voicemail. No carrier credentials are configured; SIP registration and external calls still require provider details and endpoints.
- Operator and tenant workflow documentation is in `docs/tenant-services.md`. Removed temporary validation accounts, PBX services, carrier template, cached test directory entries, and test sessions. Only the published Business PBX starter remains. Integration checks are CLI-only.
