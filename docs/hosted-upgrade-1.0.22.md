# Hosted Debian upgrade to 1.0.22

On 4 November 2026, `call.openweb.co.za` upgraded from 1.0.21 to 1.0.22 through its installed signed-upgrade helper. The normal transaction completed successfully in 286.703 seconds. Core reports 1.0.22 Running; the actual updater executable runs from its 1.0.22 slot and reports up_to_date. The installation journal and normal post-commit finalization are complete.

The deployed public Debian archive is `openwebpbx-1.0.22-debian13-amd64.tar.gz`, 487,451,837 bytes, SHA256 `f55bf2f4e63f45fe478027f44d328d3742814d93bb53cb8c86a73a136c00765d`. Its signed release envelope was verified by the installed updater. Public downloads, tags and platform feeds were not changed by this deployment.

Before installation, the native encrypted configuration/database backup verified 328 files. A separate OpenPGP backup of voicemail, recordings, prompts, application files, nginx configuration and certificates verified by authenticated decryption and GNUtar comparison against all archived file contents and stored metadata. That archive is 3,303,564,270 bytes, SHA256 `36f7a8f0fc170ac6a95df18fecd65e5fc70a58aa48b9b5142cb1a3f5a1770beb`. The normal installer also retained its own transactional recovery backup.

Five inactive test root filesystems were separately archived and fully compared before removing expanded copies. Approximately 18 GiB remains free. The ten-GiB operational reserve and actual PostgreSQL-cluster health checks described in the [recovery record](hosted-recovery-2026-11-04.md) continue to apply.

The public package predates the hosted stable-QR correction. Eight reviewed November 2 QR files were therefore preserved and reapplied over the published package before reopening external PHP access. This includes the current onboarding guard in the mobile class. Existing hosted installations retain their supported legacy onboarding policy; fresh self-installs still require registration. No credentials, QR codes, onboarding policies or domain registrations were reset.

Verification covers:

- Twenty-nine customer configuration tables, including 27 extension/mailbox records, 20 gateways, 340 dialplans and 2,521 call-routing details, ring groups, queues, tenants and update policies. Original columns and values match, excluding operational insert/update/heartbeat/use timestamps; newly added schema columns are outside that original-column comparison.
- All six complete web-user rows and four private-key hashes match. Stable QR ciphertext and the nine existing mobile-device credentials are retained.
- All eight previous registrations remain, including International Lighting 1049–1051 and Global 1055–1058. Listener state/transports and provider states match. The original raw comparison is retained: only the internal profile's parenthesized numeric activity count changed from 1 to 0 while RUNNING and TLS remained unchanged.
- Core, the new updater, FreeSWITCH, PostgreSQL 18/main, PHP-FPM, nginx and STUN are active. Actual database SELECT 1 and a public UDP STUN binding request pass.
- Canonical and OpenWeb tenant HTTPS pages return 200. The original nginx parameters are restored and the temporary external maintenance flag is removed. Browser checks show the ordinary username/password login forms with zero console errors or warnings.

The first post-install check correctly reported that the still-running updater process used its old 1.0.21 slot. Its receipt remains retained. An ordinary updater-service restart loaded 1.0.22 and completed normal finalization; the subsequent verification passes. This restart did not stop the call engine.

No new physical-handset, Android audio or carrier-call test was performed during this deployment. Existing registration and configuration checks do not substitute for an answered audio test.

Private receipts and encrypted backups are under `/var/lib/openwebpbx/hosted-upgrade122-772760e268e447f895b767f1cafbd4e9`. Passphrases, credential snapshots and QR material must remain private.
