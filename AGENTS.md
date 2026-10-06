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
- Published the tenant workspace to public `embire2/openwebpbx` on `customization` and verified committed files match the live application. Fresh CEO sign-in with the requested credentials passed after cleanup. The live checkout preserves its existing optional applications.

## Outgoing mail progress — 2026-10-06

- Verified the server's local and public outbound IPv4 address is `173.214.174.68`.
- Added a platform SMTP Outgoing Mail page with host, port, connection security, sender defaults, username/password authentication, and IP Authentication. IP mode requires no credentials and clears stored SMTP username/password on save.
- The global relay is read directly by the shared PHP mail transport for every tenant, including queued voicemail, fax, and system mail. Existing configuration remains in effect until a global server is saved. Connection testing sends no email.
- Local SMTP integration checks passed using an isolated PostgreSQL schema and loopback SMTP sink. Wire capture confirmed IP mode sends no AUTH command and password mode authenticates successfully; both messages were captured locally. Validation, permissions, tenant override precedence, secret masking, password retention, and credential clearing passed.
- Live Chromium checks passed for the desktop launcher/embedded page, IP mode, saving/reloading, the connection test against a local fixture, mobile layout, light/dark appearance, and zero console errors/warnings. Live HTTPS checks rejected missing CSRF tokens and denied GET/POST access to a temporary tenant administrator.
- Removed the test relay, account, and session, restored the original empty SMTP settings, and reloaded PHP-FPM to clear cached fixture settings. No email was sent outside the local test sink. Operator documentation is in `docs/outgoing-mail.md`. No real SMTP provider has been configured.

## Guided setup and 3CX migration progress — 2026-10-06

- The user confirmed 3CX V20 as the source version. Native V20 backup restore remains unsupported pending a real backup and build-specific validation; do not claim complete 3CX compatibility or restored calls.
- Added a simpler PBX Setup console with company/users/provider/routing/review steps and focused administration sections. Empty PBXs open it automatically from the existing Windows-inspired desktop.
- Setup and supported configuration import create independent tenant-owned services using encrypted, administrator-owned, one-hour drafts, explicit confirmation, idempotency, and a single transaction. Completed drafts discard credential payloads.
- Added bounded ZIP/XML analysis, secret-free reports, documented SetupConfig support, and structurally verified legacy V14/V16 migration. Unsupported versions, encryption, unsafe archives/XML, schedules, media, and unmapped behavior are blocked or reported rather than silently restored.
- Native SIP users, voicemail, ring groups, prefix/length/strip/prepend outgoing rules, and disabled provider/number records are mapped within the new service. Incoming contexts exclude global dialplans and deny unconfigured ingress. The platform's custom business/carrier routes are excluded from stock defaults.
- Parser checks, native mapper checks, guided workflow checks, and existing tenant integration checks passed in isolated schemas. Live HTTPS checks passed for tenant setup/create/retry, user/provider lists, CSRF, nonowner access denial, native V20 refusal, masking, and explicit SetupConfig configuration import.
- Chromium checks passed for automatic desktop entry, embedded native editors, wizard validation/add/remove/destinations/IP authentication, password masking, no-JavaScript review, light/dark contrast, and 390px layouts. Browser console reported zero messages/errors/warnings. Synthetic V20 analysis showed an unavailable import and no creation action.
- The official V20 SetupConfig sample passed parser and mapper normalization (two users, two disabled trunks, two incoming numbers, with unsupported behavior reported). FreeSWITCH directory lookup resolved a guided user and an imported authentication ID in their separate service realms. Real handset registration, carrier calling, and native V20 restore remain unverified.
- Temporary validation accounts, services, private session files, and CEO review drafts were removed. Enabled periodic expiry cleanup for encrypted draft data; retained the original published Business PBX template and empty provider/mail configuration. Source is deployed and published on `customization`; operator workflow and limits are in `docs/guided-pbx-setup.md`.
