# Application updates

Open **Admin → System → Updates** to check the installed version, review an available release and choose how this instance updates. This setting covers every tenant on the instance; tenants do not install their own server database or application.

- **Let me choose** checks for releases and leaves installation to the instance administrator.
- **Download automatically** also downloads and verifies a complete package in advance.
- **Install automatically** installs the verified package during the chosen daily maintenance window, measured in UTC, once calls have finished. An explicit **Install when calls finish** request can run outside that window and still waits for idle.

Manual installation requests expire after 24 hours if they cannot complete; request installation again when ready. If an automatic installation fails, that exact release file is not retried automatically on every check or worker restart. An instance administrator must explicitly retry it, or a different verified release file must become available.

A separate updater service remains running while the PBX application restarts. Phones reconnect when the update finishes. An interrupted download does not stop calling. The updater checks a pinned RSA signature, expiry, version, platform, complete download size and SHA-256 before an archive can be installed. It also validates every package file and refuses older or conflicting release metadata. No database setting can supply a custom download URL or shell command.

Automatic updates begin with version **1.0.4**. Existing 1.0.3 instances need the one-time manual upgrade below to install the independent updater and its trusted signing key. Updates remain set to notify until an instance administrator changes the policy.

## Debian 13

Only Debian 13 on 64-bit Intel/AMD is supported. Ubuntu is not included. The installer creates PostgreSQL on the PBX computer; all tenants share the instance database.

The service is `openwebpbx-updater`. Its private downloads, logs, signed metadata and recovery state are under `/var/lib/openwebpbx/updates`, accessible only to root. The current trusted installation helper is `/opt/openwebpbx/tools/upgrade.py`. Application upgrades preserve private configuration, encryption keys, recordings and voicemail. Keep the normal media backup: update backups contain application files, database and private configuration, rather than another copy of all media.

For the first upgrade from 1.0.3, download the Debian archive, `update-manifest.json` and `SHA256SUMS` from the same reviewed release. Check the published checksums, extract the archive into a root-owned directory under `/root` and run:

```sh
./upgrade.sh --archive /root/openwebpbx-1.0.6-debian13-amd64.tar.gz \
  --feed-envelope /root/update-manifest.json --target-version 1.0.6 --check
./upgrade.sh --archive /root/openwebpbx-1.0.6-debian13-amd64.tar.gz \
  --feed-envelope /root/update-manifest.json --target-version 1.0.6
```

The check validates the signature, package, idle state and recovery prerequisites without stopping services. The installation command downloads nothing: both files must already be complete. Later releases use the currently installed trusted helper, including when launched from an extracted archive. Root-owned inputs and their parent directories must not be writable by other accounts.

Before shutdown, the helper checks database ownership, creates a private application/configuration/database backup, and records a durable journal. It pauses new calls, rechecks that no call or channel is active, stops the application services, and refreshes the database snapshot while they are quiescent. It applies migrations, verifies the running version and database, then activates the new independent updater slot. Automatic installation rechecks the window before shutdown.

A failed migration or health check restores the prior application and its complete database snapshot, including object ownership and grants. Migration-created tables/functions/schemas are removed. Recovery acts only inside the originally configured PBX database and verifies its database identity. The supported automatic recovery layout is a database owned by the application account, the standard public schema, application-owned objects, and the built-in PL/pgSQL extension. An existing legacy application account that already has PostgreSQL superuser privileges may also recover the standard schema and its original owners; the updater never grants these privileges. Custom schemas, extensions, large objects, or objects owned by another account without that existing privilege need an administrator-managed migration and are refused before shutdown.

The independent `openwebpbx-update-recovery` service runs before PBX services on boot. If power is lost during a migration, it completes rollback from the private journal before allowing the PBX to start. If the snapshot is missing/corrupt or recovery fails, the maintenance latch keeps application services stopped; it does not start a partially updated system. Keep the private backup and review its `upgrade.log` without sharing credentials or customer data. After correcting the external problem, run:

```sh
python3 /opt/openwebpbx/recovery/upgrade.py --recover
```

Do not delete the journal or maintenance latch to bypass recovery. Keep users off the PBX until the updater reports completion. Services briefly reopen during the final health check, before the update is committed; a crash in that interval can restore the saved database and lose changes made during that interval. Review any new calls, messages and settings before resuming normal use. The tested interruption occurred during migration, while application services were stopped; this is not a guarantee of lossless recovery from every possible hardware or storage failure.

A completed update is not automatically reverted after users have resumed work; a deliberate later restore needs an administrator to reconcile new calls, settings and media first.

## Windows Server

The Windows edition uses the same signed release feed and independent C# updater. See [Windows updates and recovery](windows-upgrade.md) for service names, backup/recovery commands and the administration manager's restart behavior. Windows Server 2025 is the qualified server platform; Windows 10/11 full-server qualification remains outstanding.

## Android phones

In **Tenant Admin → Updates**, tenant administrators choose a phone-update policy for their users: **Let users choose**, **Download automatically**, or **Require the update**. For direct APK installations, notification, background download and required-update choices use the same signed release feed, then verify the APK's application ID, version and signing certificate. Android system permission/installation confirmation still applies. An active call defers installation. The app reopens after replacement where Android permits it; otherwise a notification provides the reopen action. See [the Android guide](android.md) for actual tested devices and limits.

The 1.0.7 phone UI adds a prominent update card with live download progress and notification navigation. The Google Play edition opens Google Play for installation and contains no APK self-installer. Store updates become required only after signed metadata confirms a fully published production Play version; publishing on GitHub alone cannot trigger that requirement. Google Play controls its own download, installation and reopening. See [Play publication](google-play.md).

This protects OpenWeb PBX application updates. Distribution packages, PostgreSQL, the call engine and public TLS certificate operations remain separate administrator tasks; updating the application does not silently replace these installed components.

## Debian verification for 1.0.4

An isolated Debian 13 installation completed a signed 1.0.3-to-1.0.4 upgrade, retained its phone passwords, and passed an answered internal call with two-way audio afterward. The independent updater remained running across a PBX service restart. Verification covered an answered SIP call with two-way audio deferring installation without restarting services, a closed UTC maintenance window, automatic rollback after a failing migration and a failed health check, and abrupt termination of the entire test machine during migration followed by boot recovery. Database checks verified restoration of rows, comments, ownership and grants in the same database, removal of migration-created tables/functions/schemas, and both fresh-instance ownership and the existing legacy privileged-account layout. Signature tests cover tampering, expiry, future timestamps, replay/conflicts, wrong URLs, downgrade/minimum-version rules and unsafe archives. Production fault injection was not used.

A separate fresh-configuration smoke used Debian 13 with distribution prerequisites already installed. It created a new local database, administrator and default users; administrator HTTPS sign-in, an answered two-way internal call, version 1.0.4 health and automatic updater/recovery service setup passed. The installer refused an existing PBX database before changing application configuration.
