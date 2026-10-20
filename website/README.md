# OpenWeb PBX homepage

Public destination: **https://openwebpbx.com/**. Deploy only the contents of `public/` to that domain's document root. The site is static HTML, CSS, JavaScript and SVG; it needs no Node build, database, external fonts or third-party scripts. The PBX application and private account data are separate.

Current deployment: **[https://openwebpbx.com/](https://openwebpbx.com/)**, published to the existing cPanel document root on 2026-10-08 and refreshed to 1.0.15 on 2026-10-16, with Play policy pages updated on 2026-10-17. HTTP and `www` requests redirect to the HTTPS apex while preserving the path and query. No DNS or mail routing was changed.

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

The 1.0.10 source refresh fixes notification-setting storage and presents the five new core packages, native Android calling controls, automatic incoming wake-up, CC0 hold music and the native Windows client plan. New server features target Debian 13 amd64; the download card explicitly retains Windows Server 1.0.7 as a previous release. The Android 1.0.10 app requires a matching 1.0.10 server. There is no Windows 1.0.10 package or Windows softphone claim.

Eight current release assets cover Debian, the direct APK, separate Play AAB/submission packet, corresponding Android/engine source, signed update metadata and checksums. `public/releases.json` is refreshed only after complete public GitHub downloads match reviewed local SHA-256 values. Earlier releases remain unchanged. The old 1.0.7 video is labelled as an earlier basic-workflow demonstration. Physical proximity, locked/idle push, Wi-Fi/mobile handover, broader hardware qualification and Google Play approval remain visible limitations. Store links/badges remain absent until approval.

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

## Google Play preparation pages — 2026-10-09

Published `privacy.html`, `data-removal.html`, `support.html` and `assets/support.css`; the homepage footer and sitemap link them. The six-file deployment allowlist matched served bytes, with prior files backed up privately under `/var/backups/openwebpbx/homepage-play-preparation-107`. Actual-domain Chromium passed all three pages at 1440/390/320px in light/dark mode with no overflow or console errors/warnings. The 320px dark support page was visually reviewed. The browser was closed. The existing cPanel support-email forwarder is configured; inbox delivery has not been tested.

These pages prepare the Android store submission; they do not announce Google Play approval. Keep the public store link absent until the listing is actually published.


## Version 1.0.7 publication verification

Published the fourteen-file static allowlist on 2026-10-09 after all nine complete public GitHub downloads matched the frozen release hashes and the latest signed feed matched its reviewed envelope. The release tag points to `4075316e5f84ed568dc786518abbfae24ae302ee`. All fourteen served file hashes match source. The catalogue includes the separate Play AAB and submission ZIP alongside the direct APK and both server packages. The public demonstration page serves the reviewed 78-second native-app video; no credentials or customer data are included.

All 36 public links passed. Trusted HTTPS, canonical redirects, private-path denial and video range requests passed. Actual-domain Chromium passed all eight feature dialogs, download links, Start search, window controls and theme persistence. The privacy, removal, support and review pages passed at 1440/390/320px in light/dark mode; the video actually played. There was no horizontal overflow and zero browser console errors or warnings. Desktop/mobile screenshots were visually reviewed and the browser was closed after verification.

Existing cPanel `.htaccess`, DNS and mail routing were preserved. Previous public files remain private under `/var/backups/openwebpbx/homepage-1.0.7`; deployment and verification evidence stays outside source and the web roots.

## Version 1.0.9 publication verification

All eight complete public GitHub downloads matched their local SHA-256 values. Fourteen allowlisted website files matched the deployed HTTPS contents, and 38 links passed. Actual-domain Chromium passed all twelve feature dialogs, download links, desktop controls, Start navigation, persistent themes and 1440/390/320px layouts with zero console errors. The labelled earlier 1.0.7 video played successfully (78 seconds), including HTTP range delivery. Historical Windows 1.0.7 downloads, existing hosting rules, DNS and mail were preserved.

## Version 1.0.10 publication verification

Published the fourteen-file static allowlist after all eight complete public downloads matched their reviewed SHA-256 values. Latest signed metadata is byte-identical to sequence 110. HTTP verification passed fourteen file hashes, 38 links, trusted TLS, canonical redirects and private-path denial. Actual-domain Chromium passed twelve feature dialogs, current Debian/Android links, historical Windows 1.0.7 link, Start/taskbar/window controls, persistent light/dark themes and 1440/390/320px layouts with zero errors or warnings. The clearly labelled historical 1.0.7 video still plays (78 seconds, HTTP range 206). DNS, mail and existing hosting rules were preserved. The HTTPS noindex preview was refreshed with the same fourteen allowlisted files. The native Windows calling client remains a plan; Google Play approval and physical handset qualification remain open.


## Google Play policy URLs — 2026-10-17

- Privacy: https://openwebpbx.com/privacy
- Terms and conditions: https://openwebpbx.com/terms
- Account/data deletion: https://openwebpbx.com/delete

These return public HTML directly with trusted HTTPS. `/privacy.html` and `/data-removal.html` remain available to installed app versions; their canonical URLs use the clean paths. Trailing slashes redirect to the canonical path. The deletion page has a prominent email request link and copyable contact details, does not require installing the app or signing in, and distinguishes account/server-data deletion from disconnecting a device. App and publisher names are OpenWebPBX Free Phone and Open ISP cc. The existing contact-email forwarder is configured; inbox delivery has not been tested.

Deployment updated seven static files and added four rules inside the existing managed `.htaccess` block. All other live hosting rules were preserved exactly; DNS and email configuration were unchanged. Private before/after and HTTPS evidence is in `/var/lib/openwebpbx/play-pages-20261017/`. No APK, AAB, release feed or PBX version changed for this website update. The existing native app's policy links still reach the updated pages.

Live browser verification passed all three pages at 1440/390/320px in light/dark mode (18 layouts), with no overflow or page/console errors. App/publisher names, canonical tags, cross-links, the deletion email URI and request anchor passed. The email link was checked without sending a message. The mobile deletion page was visually reviewed, and the browser was closed.

## EU/POPIA website work — 2026-10-17

The public site now has [company details](https://openwebpbx.com/legal), [cookies/local storage](https://openwebpbx.com/cookies), [privacy requests](https://openwebpbx.com/privacy-rights), [PAIA access](https://openwebpbx.com/paia) and [accessibility assistance](https://openwebpbx.com/accessibility), alongside the existing clean privacy/terms/deletion URLs. Owner-supplied company registration and Leon Whitherall's Information Officer contacts appear in the relevant notices.

Shared `assets/privacy.js` / `assets/privacy.css` provide equally styled accept/reject buttons, initially unticked appearance preference, footer withdrawal, 180-day logical expiry, malformed-record refusal and cross-tab updates. Appearance is no longer read or saved without optional consent. The essential privacy choice is the only persistent choice record required; the public site still has no analytics/ad scripts or HTTP cookies. Clearing/expiry cleanup occurs when the script next checks storage. Browser-blocked storage works in memory, and the text/download pages remain available without JavaScript. Any future purpose or tracker needs a fresh assessment and consent category, rather than reusing appearance consent.

Deployment verified **15 exact public files** and **eight clean routes**, their slash/HTTP/www canonical forms, original HTML compatibility, security headers and denied private/missing paths. Only one existing canonical rule was expanded and one narrow routing rule added; every unrelated original cPanel line is exact. DNS, mail and immutable release/download data were unchanged. Previous hosting state and private evidence are under `/var/lib/openwebpbx/eu-popia-20261017/`.

Actual-domain Chromium passed **95 checks**, including **66 page/width/theme layouts** (eleven pages × 1440/390/320px × light/dark), all consent transitions, malformed/future/expired choice refusal, optional-store gating, blocked-storage and no-JavaScript checks. No warnings/errors, third-party resource requests or HTTP cookies were observed. The mobile banner and dialog were visually reviewed. Static verification resolved **229 local page/asset references**, and both JavaScript syntax checks passed.

See the [legal/privacy audit and primary sources](../docs/website-privacy-compliance.md), [operating procedure](../docs/privacy-operations.md) and [PAIA manual draft](../docs/paia-manual-draft.md). This is not a declaration of complete GDPR/POPIA/EAA compliance: organisation-wide records/manual approval, actual retention/contracts/transfers, mailbox delivery, Information Officer registration and a valid EU representative arrangement where required remain unresolved.

## Android1.0.18 delivery —20October2026

The homepage, Android details/support/demonstration and catalogue now distinguish Android1.0.18 from full Debian1.0.16. Users confirm their registered tenant address; desk-phone settings stay unchanged. The hosted minimum is18. Use the r2 Debian16 feed-compatibility archive and SHA256SUMS-r2; the earlier helper/checksums are explicitly superseded, with their bytes retained. APK/AAB/source/feed bytes are unchanged. Five live files match source;52 actual-domain browser checks/24 light-dark responsive layouts passed, including corrected320px address wrapping. Hosting rules, policy pages, DNS and mail settings were retained.
