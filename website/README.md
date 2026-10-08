# OpenWeb PBX homepage

Public destination: **https://openwebpbx.com/**. Deploy only the contents of `public/` to that domain's document root. The site is static HTML, CSS, JavaScript and SVG; it needs no Node build, database, external fonts or third-party scripts. The PBX application and private account data are separate.

Current deployment: **[https://openwebpbx.com/](https://openwebpbx.com/)**, published to the existing cPanel document root on 2026-10-08. HTTP and `www` requests redirect to the HTTPS apex while preserving the path and query. No DNS or mail routing was changed.

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

At the initial review on 2026-10-08, GitHub's published release API lists **1.0.2**. Direct downloads are the Debian 13 amd64 archive and Windows x64 archive, plus checksums and the corresponding engine source. Fresh server installations were qualified on Debian 13 and Windows Server 2025 with Desktop Experience.

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

Actual-domain Chromium checks passed for all six Start shortcut names, search/no-results/Enter navigation, all six feature dialogs, window controls, persistent light/dark themes and the 390px mobile layout/dialog/FAQ. All assets loaded and the browser console reported zero warnings/errors. Start search now matches each shortcut's visible name as well as its keywords, including Downloads.

Use the official [cPanel API token guidance](https://docs.cpanel.net/knowledge-base/security/how-to-use-cpanel-api-tokens/), [domain information API](https://api.docs.cpanel.net/specifications/cpanel.openapi/domain-information/domaininfo-single_domain_data) and [file upload API](https://api.docs.cpanel.net/specifications/cpanel.openapi/manage-files/fileman-upload_files).
