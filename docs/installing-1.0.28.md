# Debian 13 installation guide for the local 1.0.28 candidate

This candidate is kept locally for development and qualification. The public Debian release and update feed still offer 1.0.27. Use a disposable Debian 13 amd64 instance for this candidate.

## Install on a new server

1. Verify the archive against the matching local SHA-256 checksum and extract it into an empty private directory. The full installer contains the application, local PostgreSQL setup, calling engine, updater and system prompts.
2. Run `./install.sh --check` as root to verify the files and host prerequisites.
3. Follow the normal Debian installation and managed registration procedure. A fresh installation does not require an earlier OpenWeb PBX. [Debian installation and registration](installing-1.0.27.md)

## Migrate from 3CX V20

In **Backup & Restore**, analyze the unencrypted 3CX ZIP, review the import preview, and check the **Restore Report** after restoring to a separate PBX. The candidate targets the exact inspected Update 9 build `20.0.9.995` and Update 10 build `20.0.10.1801`. Review the report's unsupported objects and missing files, and confirm extensions, phone setup, routes and media before a cutover. Imported providers start disabled. [Import behavior and cutover](v20-restore.md)

A large ZIP needs adequate temporary upload space in addition to PBX storage. The Debian qualification used a private disk-backed PHP upload directory for the real Update 10 archive. [Qualification record](release-1.0.28-local-qualification.md)

## Update an existing server

In **Admin → System → Updates**, an instance administrator can check the installed version and compatible signed offer. **Update Now** queues the verified offer, downloads its package if needed, then waits for an idle period. To opt in to automatic installation, select that mode and save a daily UTC window. The page shows that window in your browser's time zone. Existing download-only and manual controls remain available.

Existing-data updates use the installed signed updater, its recovery checks, and a matching verified offer. Keep the privacy and backups of existing installations intact. The local candidate cannot be installed by the public feed until its own qualification and publication. [Update and recovery procedure](updates.md)
