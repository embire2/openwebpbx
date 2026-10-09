# OpenWeb PBX homepage

Public destination: **https://openwebpbx.com/**. Deploy only the contents of `public/` to that domain's document root. The site is static HTML, CSS, JavaScript and SVG; it needs no Node build, database, external fonts or third-party scripts. The PBX application and private account data are separate.

Current deployment: **[https://openwebpbx.com/](https://openwebpbx.com/)**, published to the existing cPanel document root on 2026-10-08 and refreshed to 1.0.6 on 2026-10-09. HTTP and `www` requests redirect to the HTTPS apex while preserving the path and query. No DNS or mail routing was changed.

The project-domain `/tenantadmin`, `/tenantadmin/` and `/tenantadmin/index.php` entries redirect to the authenticated PBX portal at https://call.openweb.co.za/tenantadmin/. Query parameters are preserved. Account authentication and tenant data stay on the PBX instance.

The installed Let's Encrypt YR1 wildcard certificate covers the apex and `www`, was issued on 2026-10-08 and expires on 2027-01-06 at 12:05:01 GMT. Verified the existing installed certificate and renewal state: both names have trusted TLS, and cPanel AutoSSL reports the certificate active, no exclusions or problems, and renewal enabled.

The [HTTPS preview](https://call.openweb.co.za/openwebpbx-preview/) remains available with noindex. It serves the reviewed static files from `/var/www/openwebpbx-site/openwebpbx-preview`, outside the PBX application tree. Its scoped NGINX include is `/etc/nginx/snippets/openweb-homepage-preview.conf`; a private copy of the original site configuration is under `/var/backups/openwebpbx/homepage-20261008`.

## Local preview

From the repository root:

```sh
python3 -m http.server 8099 --bind 127.0.0.1 --directory website/public
```

Open `http://127.0.0.1:8099/`. The Apache `.htaccess` is for the public cPanel deployment; the Python preview does not apply those headers or redirects.

The desktop includes shortcuts, a searchable Start menu, a taskbar, minimize/restore/maximize controls, bounded dragging on larger screens, a local clock and a persistent light/dark preference. Feature cards open accessible details dialogs; Escape dismisses dialogs and Start. Ctrl+Space opens Start. The page remains readable and its downloads work without JavaScript.

## Content and downloads

The homepage describes the user's nonprofit, open-source project identity. It makes no registered-charity or tax-deductibility claim. The project retains its original software licenses and credits FusionPBX and FreeSWITCH.

The 1.0.6 website refresh pairs the Android call-audio correction with a persistent server audio-module setting, so configuration regeneration retains the server fix. Its seven release assets include the signed APK, server archives, corresponding Android and engine source, signed update feed and SHA256SUMS. `public/releases.json` is refreshed only after complete public GitHub downloads match the reviewed local SHA-256 values. The existing 1.0.2/1.0.3/1.0.4/1.0.5 assets remain unchanged. Server installers target Debian 13 amd64 and Windows Server 2025 with Desktop Experience; Android requires version 9 or later and an OpenWeb PBX 1.0.6 server with trusted phone connections. Upgrade the server before the Android app. Existing 1.0.3 installations need one manual update; installations with the updater follow their configured policies. Android may require confirmation or a notification tap to reopen. The website retains explicit handset, carrier and incoming-call qualification limits.

Windows 10 and 11 have separate cards labelled **Planned**. The current server installer uses `Install-WindowsFeature`, which is a Windows Server installation path. The WinUI manager's target framework alone does not establish full-server compatibility. Do not turn those cards into server download claims until an appropriate installer and actual operating-system verification exist.

When publishing a new PBX release:

1. Read the public GitHub release and asset metadata. Confirm version, platform, file size, SHA-256, URLs and actual qualification results.
2. Update release pills, download cards, release links, platform notes and feature details in `public/index.html` and `public/assets/site.js`. Record the reviewed assets in `public/releases.json`.
3. Update the roadmap and coverage guides when capabilities or supported platforms change. Do not infer compatibility from a shared Windows ZIP filename.
4. Check the actual public asset links, browser interactions, 320px/390px mobile layouts, desktop layout, keyboard access, dark mode and console output.
5. Back up the domain's existing files outside its web root, deploy only the public-site allowlist, then verify live HTTPS, redirects, headers and matching file hashes. Preserve unrelated files and the domain's mail/DNS configuration. Merge the site's rules into a marked, replaceable block in the live `.htaccess`; retain cPanel-generated PHP and hosting settings rather than overwriting the whole file.

## Hosting access

cPanel credentials belong in `/root/fusionpbx/.env`, mode `600`, which Git ignores. Use `CPANEL_HOST`, `CPANEL_USERNAME`, `CPANEL_API_TOKEN` and `CPANEL_DOMAIN`; never put their values in this directory, browser code, deployment logs or the web root. API authentication requires the username as well as the token. Validate TLS and keep authorization in the request header.

Before deployment, use the authenticated account's domain information to obtain the actual document root and inspect its current contents. The initial deployment replaced an Apache directory index on the existing cPanel host. The MX record uses the apex domain, so replacing that address would also affect mail delivery. Publish to the existing host unless a separate hosting/DNS migration is explicitly planned.

The original cPanel `.htaccess` is backed up privately at `/var/backups/openwebpbx/homepage-20261008/cpanel/original.htaccess`, mode `600`. The deployed file merges the public site's managed rules with the original cPanel-generated PHP blocks. Live verification passed for eight public file hashes, the merged `.htaccess`, canonical redirects, security/cache headers and trusted TLS. Requests for dotfiles and the assets directory return 403; missing files return 404.

The initial actual-domain Chromium checks passed for all six Start shortcut names, search/no-results/Enter navigation, all six original feature dialogs, window controls, persistent light/dark themes and the 390px mobile layout/dialog/FAQ. The 1.0.3 refresh adds a seventh Android feature dialog and an Android download card; local checks cover the new links/dialog and 320px/390px light/dark layouts. The 1.0.3 refresh is now published at the actual domain. All six full GitHub asset downloads matched their SHA-256 values, all eight deployed file hashes matched source, and 18 distinct GitHub link targets returned 200. Actual-domain Chromium checks passed for all seven feature dialogs, Android download/guide links, Start navigation, window controls, theme persistence and 1440px/320px/390px layouts with no horizontal overflow or browser errors/warnings. Existing hosting rules, DNS and mail settings were preserved. All assets loaded and the browser console reported zero warnings/errors. Start search now matches each shortcut's visible name as well as its keywords, including Downloads.

Use the official [cPanel API token guidance](https://docs.cpanel.net/knowledge-base/security/how-to-use-cpanel-api-tokens/), [domain information API](https://api.docs.cpanel.net/specifications/cpanel.openapi/domain-information/domaininfo-single_domain_data) and [file upload API](https://api.docs.cpanel.net/specifications/cpanel.openapi/manage-files/fileman-upload_files).

## Version 1.0.4 publication verification

All seven complete public GitHub downloads matched their local SHA-256 values. The latest signed feed matched the final release envelope. All eight deployed public files matched source; nineteen GitHub targets returned 200. Trusted HTTPS, canonical redirects with query preservation, security headers and private-path denial passed. Actual-domain Chromium passed all eight feature dialogs, Android download/setup links, Start navigation, window controls, theme persistence and 1440/320/390px layouts without overflow or console warnings/errors. Existing cPanel rules, DNS and mail routing were preserved; prior files remain private under `/var/backups/openwebpbx/homepage-1.0.4`.

## Version 1.0.5 publication verification

Published the eight-file static allowlist on 2026-10-09 after all seven complete public GitHub downloads matched the final release hashes and the latest signed feed matched its reviewed envelope. The release tag points to `8c726fe32`. The live catalogue lists Android, Debian 13 and Windows Server 2025 version 1.0.5; Windows 10/11 full-server downloads remain planned.

All eight deployed public files matched source and all nineteen GitHub link targets returned HTTP 200. Trusted HTTPS, canonical redirects with path/query preservation, security headers, dotfile/directory denial and the expected missing-file response passed. Actual-domain Chromium passed all eight feature dialogs, Android APK/setup links, Start search/Downloads navigation, maximize/restore, minimize/taskbar restore, persistent light/dark themes and 1440/320/390px layouts. There was no horizontal overflow and zero browser console errors or warnings. Desktop/light and 320px/dark screenshots were also visually reviewed. The validation browser was closed after testing.

Existing cPanel `.htaccess`, DNS and mail routing were preserved. Previous public files remain private under `/var/backups/openwebpbx/homepage-1.0.5`; deployment and validation evidence is outside source and the web roots.

## Version 1.0.6 publication verification

Published the eight-file static allowlist on 2026-10-09 after all seven complete public GitHub downloads matched the final release hashes and the latest signed feed matched its reviewed envelope. The release tag points to `4f6993e19`. The live catalogue and download links now list Android, Debian 13 and Windows Server 2025 version 1.0.6. The earlier 1.0.5 release is superseded; its assets remain unchanged. Windows 10/11 full-server downloads remain planned, and handset/carrier acceptance limits stay visible.

All eight deployed public files matched source and all nineteen GitHub targets returned HTTP 200. Trusted HTTPS, canonical redirects with path/query preservation, security headers, dotfile/directory denial and the expected missing-file response passed. Actual-domain Chromium passed all eight feature dialogs, Android APK/setup links, Start search/Downloads navigation, maximize/restore, minimize/taskbar restore, persistent light/dark themes and 1440/320/390px layouts. There was no horizontal overflow and zero browser console errors or warnings; the 390px dark dialog was visually reviewed. The validation browser was closed after testing.

Existing cPanel `.htaccess`, DNS and mail routing were preserved. Previous public files remain private under `/var/backups/openwebpbx/homepage-1.0.6`; deployment and verification evidence stays outside source and the web roots.
