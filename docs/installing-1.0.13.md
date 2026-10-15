# Windows Server 1.0.13

**Candidate under qualification; no 1.0.13 download is published yet.** Debian and Android remain on the published 1.0.12 release. Do not substitute a Windows package for a Debian update or require an Android version that has not been released. Current results are recorded in [feature coverage](feature-coverage.md#windows-server-return--1013).

The ordered work and pass criteria for publication are in the [Windows 1.0.13 release plan](../3CX.md#windows-1013-release-plan).

This server uses Windows Server 2025 x64 Desktop Experience, local PostgreSQL, IIS/PHP, FreeSWITCH, the .NET 10 background service and independent updater, and the WinUI 3 administration manager. The manager opens the existing Admin workflows; the separate [Windows calling client](windows-client-plan.md) remains planned. Windows 10/11 server installation is not qualified.

## New installation

Choose an empty Windows server with a stable public IPv4 address and a hostname that points to it. Allow outside access to TCP 80 for certificate validation, TCP 443 for the administration/app connection, the selected phone ports, and UDP 16384–32768 for audio. The public setup helper creates only OpenWeb PBX's own Windows Firewall rules; upstream/cloud firewalls still need the corresponding ports.

Extract the complete matching Windows release and open its manager as an administrator. In **Setup**, enter the server hostname, administrator email and password, and select **Automatic public certificate**. The public address can be left blank when the hostname has one unambiguous public IPv4 address. Setup installs the database on this same server for every tenant. Provider connections start disabled.

For an empty replacement server, select **Prepare this server for restoring a backup**. It creates the instance administrator without demo phones or a company service. Normal setup creates the initial company and Main PBX.

The equivalent command uses **Windows PowerShell 5.1 (`powershell.exe`) as administrator**. The manager and scheduled tasks use that built-in shell for native IIS management. Run:

```powershell
.\Install-OpenWebPBX.ps1 -DomainName 'pbx.example.com' -EnablePublicAccess -AdminEmail 'admin@example.com'
```

Add `-RestoreServer` for a replacement. The password is requested privately. `-LocalCertificate` is reserved for local tests; it does not qualify remote phones. An existing trusted, exportable certificate in Local Computer → Personal can instead be selected with `-CertificateThumbprint`.

The first installation downloads hash-verified prerequisites and a pinned compiler, builds the audio converter locally, and tests its native callbacks and memory ownership before enabling it. Combined converter DLLs are not distributed in the release. Keep the installer running until completion. A restart requested by Windows must finish before continuing setup.

## After setup

Sign in to **Admin**. Use **SIP Trunks**, **First Calls**, **Users**, **Phones**, **Call Handling**, **Office Hours**, **Switchboard**, **Queues**, **Hotel Services**, **SMTP Outgoing Mail** and **Backups**. All tenants use the instance's global outgoing SMTP settings. **My IP address is whitelisted** sends without a username/password. Voicemail and other queued mail use the scheduled Windows outgoing-mail worker.

Public setup requests a Let's Encrypt certificate, applies the HTTPS binding and native phone TLS listener, and schedules renewal. If active calls prevent phone-certificate replacement, the pending retry waits for them to finish. A successful local handshake verifies the actual certificate and hostname; public issuance and remote handset audio require their separate checks.

Android users keep the released standalone app and connect through their extension's QR code. Restored desk phones retain supported original credentials and use the selected tenant phone domain. Test internal and incoming/outgoing calls, hold music, voicemail and email before moving a live provider.

## Updating an older Windows installation

Windows 1.0.3–1.0.7 need one transition because their installed helper does not inventory the new native modules. Use these steps if the older manager reports that the release does not support this server architecture. Download the complete 1.0.13 archive and signed **windows-update-manifest.json** from the same release. From the extracted release, run:

```powershell
.\Upgrade-LegacyWindows.ps1 -Archive 'C:\Downloads\openwebpbx-1.0.13-windows-x64.zip' -FeedEnvelope 'C:\Downloads\windows-update-manifest.json' -TargetVersion '1.0.13'
```

The existing verifier authenticates the complete package before the new transaction helper runs. The new helper snapshots native modules, local converter, database, configuration, notification identity, support runtimes and owned task state. Future Windows releases use **Admin → System → Updates** and the separate signed Windows feed. The generic feed stays on Debian/Android 1.0.12. See [Windows upgrades and recovery](windows-upgrade.md).

## Backups and recovery

Use **Backups** to select an encryption password, media inclusion, daily UTC schedule, retention and optional SFTP destination with a pinned host key. Keep the password separately. Backups cover every tenant in this installation.

Restore only onto an empty, matching-version Windows replacement. This candidate refuses cross-platform Debian/Windows restores. Restored calls, background jobs, updates and backups remain held until explicit activation. Target database credentials and public certificate account stay local; the source encryption key is recovered so restored templates remain usable. Configure the replacement phone certificate while calls are held, then pass the native TLS check before activating calls. An interrupted restore leaves all maintenance holds in place.

Native fresh installation, upgrade/recovery, email, complete calling and clean-server restore are release gates. Passing source checks or opening the manager alone does not establish them. Physical handsets, live carriers, outside certificate issuance and the wider [3CX roadmap](../3CX.md) remain separate acceptance work.
