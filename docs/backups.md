# Encrypted instance backups and recovery

Backups protect **all tenants on one Debian 13 installation**. Only an enabled instance administrator with the **pbx_backup_instance** permission can change settings, request or download a copy. Tenant administrators cannot access another tenant’s data through this page.

This feature is included in the Debian 1.0.9 release. The previous 1.0.7 package does not include this worker. Windows backup/restore portability is outside this implementation.

## Set up

Open **Backups**, set a password of at least 12 characters, select whether to include media, and save. Keep this password outside the PBX; a downloaded backup cannot be decrypted without it.

Select **Back up automatically every day**, choose a UTC hour and how many completed local copies to keep (2–90). The worker checks each minute and catches up once when the server returns after downtime. **Back up now** queues an immediate request. Existing requests are coalesced, and only one worker runs at a time.

An **.owpbx** file contains:

- A PostgreSQL snapshot of the complete instance database: users, tenant memberships, service rules, encrypted templates, imported configuration, job records, history and system settings.
- The private PBX configuration, original template/encryption key, background-service configuration and FreeSWITCH configuration.
- Supported private mobile-push configuration, when present.
- With **Include media** selected: standard private storage, voicemail, recordings and OpenWeb PBX custom sounds.

Application executables are supplied by the matching release. PostgreSQL server files, roles, active phone registrations, transient FreeSWITCH databases, source checkouts, environment credentials, browser profiles, private test/review fixtures, upload drafts and updater-recovery directories are excluded. The downloader receives only the encrypted file.

Calls continue during backup. PostgreSQL uses a transactionally consistent MVCC snapshot; each included file must remain unchanged while copied, and all archived files are checked after encryption. This is not an atomic freeze of a running PBX: a call still writing a recording or voicemail, a file added after the inventory, or configuration changed concurrently may require another backup at a quiet time. No backup in this implementation claims recovery of an unfinished recording or an exact point-in-time snapshot across PostgreSQL and live media. A missing or changed inventoried file fails the copy instead of publishing an incomplete file.

The tool supports the standard Debian paths and the application’s single public database schema. Custom PostgreSQL schemas/extensions/large objects, symbolic links, linked files, nonstandard media paths and filesystems that cannot safely provide ordinary files require an administrator-managed backup. Limits are 50 GB expanded data and 500,000 archived files.

## Encryption and checking

The archive uses AES-256-GCM with a fresh nonce and salt, deriving its key from the backup password with PBKDF2-HMAC-SHA256 and 600,000 iterations. The format/header and all ciphertext are authenticated. The encrypted payload contains a bounded manifest with every private file’s SHA-256 digest.

Saved passwords and SSH identities are separately encrypted under the instance’s private template key. Settings and status APIs do not return them. Changing the password affects future backups; keep the old password for old copies. **Check backup** uses the currently saved password, so older copies encrypted with another password should be checked with the server tool instead.

Downloaded SHA-256 values detect transport/storage changes; the authenticated archive and inner file checks are the actual restore integrity gate. Decrypted temporary files stay in mode-700 private directories and are removed after verification. Wrong passwords, truncation, tampering, unsafe paths, links, duplicate files and missing inventory members prevent restoration before any target service/data change.

A verified archive is not proof that every SIP provider or external integration will work after migration. Practice a restore on a separate server and test calls.

## Additional SFTP copy

Enable the additional copy and enter the server, port, username, existing absolute destination folder, the server’s **trusted public SSH host key**, and an unencrypted private SSH account key.

Get the host key directly from the server owner. For example, the server owner can supply the contents of **/etc/ssh/ssh_host_ed25519_key.pub**. A key learned from an unauthenticated network scan is not an independent trust check. Use an account restricted to its backup folder.

The worker uses batch-mode OpenSSH, a private temporary identity, strict host-key checking and no inherited SSH configuration. It uploads to a temporary remote name, then renames the completed file. A changed host key, invalid identity, inaccessible folder or connection failure leaves the verified local copy available and marks the remote copy **failed**. No unencrypted database/media is sent.

Local retention applies only after another verified copy completes; failed requests do not delete prior good backups. At least two successful local copies are retained. Remote files are never deleted automatically—set retention on the remote server. Remote retries currently require creating a new backup; resumable upload and remote-storage browsing are not implemented.

## Install the worker

Fresh/upgrade Debian release integration must include:

1. The **python3-cryptography** package and OpenSSH/PostgreSQL command-line tools.
2. The backup application/migration and the reviewed backup Python helper, service and timer.
3. Root-owned private storage and the read-only download directory.
4. The enabled backup timer.

The provided **packaging/debian/install-backups.sh** installs these reviewed helpers into an already installed matching application. It does not install packages or overwrite database connection settings. Run it only as part of the complete reviewed release integration.

Operational files:

- **/opt/openwebpbx/tools/backups.py**
- **/var/backups/openwebpbx/automatic/** — root-only completed encrypted files and temporary work.
- **/var/lib/openwebpbx/backup-downloads/** — root-owned, web-account read-only encrypted downloads.
- **/var/lib/openwebpbx/backup-restore/** — private factory rollback material and restore journal.
- **openwebpbx-backups.timer / openwebpbx-backups.service** — minute request/schedule polling.

Do not put these directories under the web root or grant tenants filesystem access.

## Restore a replacement Debian server

Do this on a **separate fresh installation**, not the running customer PBX.

1. Install the same OpenWeb PBX release as the backup, with the original public server name and a valid certificate. Use the built-in local PostgreSQL instance. Do not move DNS or activate the replacement’s carrier trunks yet.
2. Copy the encrypted backup to a root-only folder on the replacement. Compare its encrypted SHA-256 with the saved download value.
3. Verify the entire copy. The tool prompts privately for the original password:

       sudo python3 /opt/openwebpbx/tools/backups.py verify /root/replacement.owpbx

4. Run the target preflight without changing services, files or data:

       sudo python3 /opt/openwebpbx/tools/backups.py restore /root/replacement.owpbx --dry-run

5. Confirm the replacement’s built-in database name (normally fusionpbx) and restore:

       sudo python3 /opt/openwebpbx/tools/backups.py restore /root/replacement.owpbx --confirm-database fusionpbx

The tool refuses an installation with extra users/domains, extensions, tenants, services, imported PBXs or customer recordings/voicemail. It requires the same application version/public hostname and a PostgreSQL version at least as new as the source. It verifies every encrypted file before stopping services.

A private factory database/file snapshot and durable journal are created first. The source database is restored in a single transaction; source private keys are restored so encrypted settings remain readable. The target’s own PostgreSQL account, database name and password remain in its configuration and background-service connection, keeping the database local to the replacement. Phone/XML caches are cleared.

After success, web administration returns. **FreeSWITCH, the call-job service and updater stay stopped.** Persistent systemd conditions also hold these services and the backup timer across reboot. Source trunk rules and pending call jobs are preserved, so starting them early could move carrier registrations or deliver calls from the replacement. Backup/SFTP scheduling is disabled for review. Files absent from a settings-only backup cannot recreate omitted recordings/voicemail.

### Activation checklist

- Confirm restored users, tenant ownership, services, templates, queues, callback/hotel jobs, office hours and encrypted provider settings through web administration.
- Check your HTTPS and SIP certificate paths, source hostname, IP-dependent firewall/provider rules and intended media files. Reissue/renew certificates on the replacement as needed; NGINX/Let’s Encrypt account configuration is not imported.
- Plan the carrier handover. Before starting FreeSWITCH on a parallel test machine, disable carrier registrations/routes through administration so it cannot steal live incoming calls.
- Start FreeSWITCH for controlled internal tests:

      sudo python3 /opt/openwebpbx/tools/backups.py activate --confirm-server your.original.server.name --calls

- Register two test phones, make internal calls with audio both ways, check hold/transfer, voicemail/recordings and any queue/receptionist routes you use.
- Review pending callbacks/wake-up jobs before starting the background call service. Start it only when these jobs are intended to run:

      sudo python3 /opt/openwebpbx/tools/backups.py activate --confirm-server your.original.server.name --jobs

- Perform the agreed provider handover and test incoming/outgoing numbers, caller ID and menu digits. Switch DNS/address only after those checks pass. Activate updater/backup timers when the instance is accepted, using the same command with **--updates --backups**. Then explicitly choose the replacement's backup/SFTP settings in administration.
- Keep the old PBX/recovery copy available until the replacement is proven.

Replace **your.original.server.name** with the exact hostname used by the source and replacement installations. Activating phone calls does not activate job delivery, updates or backups. A plain service restart cannot bypass an outstanding restore hold.

The completed restore journal remains for operator review. Do not run recovery against a completed restore or delete its factory recovery material until accepting the replacement.

The database retains source backup history, but encrypted backup-repository files are not recursively included in another backup. These entries are shown as **Previous server** and cannot be downloaded from the replacement; keep their separately downloaded or remote copies. Requests queued on the source are ended so they cannot unexpectedly run on the replacement.

### Interrupted restore

If the tool detects a failure while restoring, it attempts to restore the original factory database and exact prior files, then restart the services that were running. A hard process/server interruption leaves the journal and factory copy intact. On that same replacement server:

    sudo python3 /opt/openwebpbx/tools/backups.py recover

Recovery refuses a different target database/user or a completed restore. If recovery itself fails, leave the private material intact, keep call services stopped, and repair disk/database access before retrying. Do not reuse a journal for a different machine.

## Verification recorded during development

- **php tests/pbx_backups_integration.php**: 42 actual PostgreSQL checks passed for permissions, encrypted settings, invalid inputs, coalesced requests, indexed downloads, symlink/traversal refusal and heartbeat status.
- **python3 tests/pbx_backups.py**: 13 scenarios passed using independent disposable PostgreSQL databases, private fixture trees, real AES-GCM archive verification and loopback OpenSSH SFTP. They cover wrong passwords/tampering, unsafe paths/links/size, target identity, factory guards, retention, daily scheduling, worker interruption, full restore/rollback, pinned remote keys and a failed remote connection preserving the local copy. Actual systemd condition evaluation confirms persistent restore holds; fixture service starts are isolated from production.
- Two new loopback-only systemd-nspawn Debian 13 machines, based on a historical 1.0.4 fresh-install test image, passed native end-to-end backup/recovery on 2026-10-12. Only the new clone’s old validation objects were reset; factory preflight passed before independent source fixtures were created. The real installed systemd worker completed and verified an encrypted full-instance copy. The independent target had a different local PostgreSQL password and template key before restore; the target database password was retained, the original key restored and the source’s encrypted tenant template decrypted. Tenant/service/template/deferred-job/user/private-audio data and media SHA-256 passed after restore.
- Both pre-backup and restored native installations accepted the same two SIP credentials and answered an internal call with sustained two-way RTP and matching audio payloads. Source trunk count was zero and both machines had private loopback-only networks; no carrier call, external email or customer-data export occurred. Web sign-in and the Admin pages passed before and after restore. Calling was explicitly activated on the replacement; job/updater holds remained.
- Actual NGINX/PHP-FPM HTTPS checks passed for the instance-admin Backups page, masking, missing-CSRF 403, valid-CSRF request, encrypted download/hash and traversal 404. An authenticated tenant administrator was denied GET, POST and download with 403; unauthenticated requests exposed no protected backup content. Restored backup history showed **Previous server** without stale download links. The actual web check caught and corrected a framework settings-variable collision before handoff.
- Playwright reviewed the actual backup template with independent fixture data at 320, 390, 768 and 1440 pixels in light/dark modes: no horizontal overflow or clipped input fields, working checksum details, and zero console errors/warnings. This layout fixture is separate from the authenticated HTTPS checks.
- The complete 1.0.9 fresh installation under umask 077, the original installed 1.0.7 updater path and two forced-failure rollback cases passed. Both qualified images match all 7,093 deployed runtime files, including installed backup helpers and timer enablement. Rollback removes newly introduced files and restores pre-existing helper contents, permissions and ownership; database/credential identity and native audio survive. The recovery-copy test above remains the separate source/target restore evidence. Windows backup/restore and real remote-provider infrastructure remain unqualified; SFTP wire tests use a real isolated loopback OpenSSH server.
