# Windows Server backups and replacement restore

**Server 1.0.21 — Complete Windows and Debian server1.0.21 release.** Use the matching platform release and [current release scope](release-1.0.21-qualification.md). Target certificates and separate restored calling/jobs holds below remain required. The following1.0.20 test record is historical and does not substitute for current-package restore acceptance.

**Historical 1.0.20 qualification:** Its exact package passes normal40111566679 (17 essential gates), independent replacement restore40123098262 (source9/target20), and signed newer upgrade40125359325 (9 gates plus111 native scheduling/file-sharing controls). Its [historical release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.20) and [historical qualification record](windows-parity-1.0.20.md#windows-release-gates) remain available. For a current replacement, use the [1.0.21 release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.21) and its [installation guide](installing-windows-1.0.21.md), matching the version of your backup. The separate restored-conference check40165744505 also passes (source9/target21), including new browser meetings with decoded audio/video and preserved original data/holds. Original 1.0.6 migration/recovery, actual OS reboot, physical phones/carriers/cameras, external NAT and continuity of existing meeting invitations remain unqualified.

Windows instance backups restore onto **Windows Server 2025 x64 with Desktop Experience**. Install the same OpenWeb PBX version, public HTTPS hostname/port and application/ProgramData layout. The target uses its own local PostgreSQL credentials and HTTPS certificate. Debian instance backups are not accepted; importing a 3CX V20 backup is a separate configuration-import workflow.

## Create and retain a backup

In **System → Backups**, choose a backup password, schedule and retention, and include voicemail and recordings when you need them on the replacement. Keep the password separately from the server. Wait for the backup to show ready, verify it, then download the encrypted `.owpbx` file and save its displayed SHA256. An optional SFTP copy has its own delivery status; a successful local backup does not prove that the remote copy arrived.

The Windows scheduled worker runs as SYSTEM. Its private backup files live under `C:\ProgramData\OpenWebPBX\automatic-backups`; do not move them into the website or expose that folder to tenants. A settings-only backup cannot recreate omitted recordings or voicemail.

## Prepare an empty replacement

1. Keep the existing PBX running and retain a separate copy of the encrypted backup. Prepare an empty Windows machine; do not run the fresh installer over an existing customer installation.
2. Install the matching, qualified Windows release with **`-RestoreServer`**. Use the original hostname and HTTPS port with a valid target certificate. For example, from the extracted package in Administrator Windows PowerShell 5.1:

   ```powershell
   .\Install-OpenWebPBX.ps1 -DomainName 'pbx.example.com' -HttpsPort 443 -CertificateThumbprint 'TARGET_CERTIFICATE_THUMBPRINT' -AdminEmail 'admin@example.com' -RestoreServer
   ```

   This example uses standard HTTPS port443. Use the source's actual hostname/port and the target certificate's thumbprint. Published Windows 1.0.20 accepts `https://host` and `https://host:443` as equivalent root HTTPS addresses while still refusing a different hostname, port or path. Use the matching published package for this behavior. The certificate must be current, trusted for that hostname, in Local Computer → Personal, and have an exportable private key for phone/meeting setup. See [public certificates and network setup](../packaging/windows/ACME.md) and [meeting transport](windows-meet.md). Do not switch public DNS or register carrier trunks merely to test a replacement.
3. Copy the encrypted file to an existing folder accessible only to Administrators and SYSTEM. Compare its SHA256 with the original download before continuing:

   ```powershell
   Get-FileHash -Algorithm SHA256 'C:\PrivateRestore\replacement.owpbx'
   ```

The restorer refuses additional target tenants, users beyond the factory administrator, extensions, services or customer media. It also refuses a mismatched application version, hostname, HTTPS address, layout or an older PostgreSQL major version.

## Verify and restore

Run these commands in an Administrator PowerShell window. Each command prompts privately for the backup password; do not put it on the command line or in a script.

```powershell
& 'C:\OpenWebPBX\backup-runtime\python.exe' 'C:\OpenWebPBX\tools\backups.py' verify 'C:\PrivateRestore\replacement.owpbx'
```

After verification succeeds, check the replacement without performing the restore:

```powershell
& 'C:\OpenWebPBX\backup-runtime\python.exe' 'C:\OpenWebPBX\tools\backups.py' restore 'C:\PrivateRestore\replacement.owpbx' --dry-run
```

Then confirm the built-in target database name and restore:

```powershell
& 'C:\OpenWebPBX\backup-runtime\python.exe' 'C:\OpenWebPBX\tools\backups.py' restore 'C:\PrivateRestore\replacement.owpbx' --confirm-database fusionpbx
```

Stop if a command fails. The tool authenticates the complete archive and file inventory, saves the empty target's recovery material, and journals the restore. It preserves the target's database connection and active certificate settings. Stored source certificate metadata does not replace a valid target certificate.

After a successful restore, administration returns while **calling, call jobs, updates and backup scheduling remain held**. Restored provider registrations and pending callbacks must be reviewed before activation. Pending Phone Health unblock requests are refused on restore; an administrator must make a new recovery decision. Do not delete hold files or start services manually to bypass this review.

## Activate and test

1. Sign in and review tenants, users, extension/authentication IDs, routes, groups, office hours, provider settings, voicemail, custom greetings and recordings. Confirm that encrypted provider settings can still be used. Review the target's certificate, public address and phone connection readiness.
2. Keep carrier registrations disabled while testing in parallel. Review any pending callbacks and hotel wake-up jobs before enabling the job service. While calling is still held and FreeSWITCH is stopped, prepare the target's phone certificate in Administrator Windows PowerShell 5.1:

   ```powershell
   & 'C:\OpenWebPBX\tools\Enable-PhoneTLS.ps1' -CertificateThumbprint 'TARGET_CERTIFICATE_THUMBPRINT' -PrepareRestored
   ```

   Use the target's current trusted, exportable certificate. This prepares the certificate without starting calling; the ordinary command without `-PrepareRestored` is not the restore preparation path. Stop if preparation fails. Calling activation also checks the real TLS listener before completing.
3. Activate calling when ready for controlled tests, using the exact original hostname:

   ```powershell
   & 'C:\OpenWebPBX\backup-runtime\python.exe' 'C:\OpenWebPBX\tools\backups.py' activate --confirm-server pbx.example.com --calls
   ```

4. Register two test phones with their preserved credentials. Check ringing and audio in both directions, hold/resume, transfer, ring groups, voicemail on 121, recordings and the routing you use. Test a browser meeting with audio and video. A successful restore command does not establish phone or carrier compatibility.
5. At the agreed handover, activate the intended provider and test incoming/outgoing calls, caller ID and menu digits. Enable reviewed call jobs separately with `activate --confirm-server pbx.example.com --jobs` using the same Python/helper paths above.
6. When the replacement is accepted, enable updates and backup scheduling with `activate --confirm-server pbx.example.com --updates --backups`. Review and save the replacement's backup/SFTP schedule, then create and verify a new backup.
7. In the planned maintenance window, restart Windows and repeat sign-in, service readiness and controlled calling checks. Verify the restored server after a planned operating-system restart; the recorded owner-upgrade reboot has a separate scope.

Keep the source PBX and recovery copy until the replacement passes the handover checks. Activating calls does not release the other service holds.

## Interrupted restore

If the restore reports that recovery is required, retain its private journal and factory recovery files. The `recover` command restores the **empty target's pre-restore state**, not the source PBX:

```powershell
& 'C:\OpenWebPBX\backup-runtime\python.exe' 'C:\OpenWebPBX\tools\backups.py' recover
```

Do not run recovery against a completed restore or delete the journal to retry. A failed recovery needs investigation while the original PBX remains available. Never publish private backup, journal or configuration files with a support request.
