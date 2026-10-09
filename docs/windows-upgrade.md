# Updating Windows Server

Starting with 1.0.4, **Admin → System → Updates** controls updates for the whole installation. Only an instance administrator can restart the shared server. The Windows manager shows progress and opens that authenticated page. The default is **Let me choose**; **Download automatically** stages a verified release, and **Install automatically** applies it during the chosen daily UTC maintenance window after calls finish. An explicit **Install when calls finish** request may run outside that window but still waits for calls. Manual installation requests expire after 24 hours; request the update again if one expires.

The independent **OpenWeb PBX Updates** Windows service stays running while the PBX restarts. It checks a pinned, signed stable release feed, requires the correct platform and a newer version, bounds and resumes downloads, and verifies the complete archive before any service stops. The already installed helper checks the signature again and rejects unsafe archive paths, changed release files, old metadata and unsupported versions. Offline checks leave the current phone system running. A failed automatic installation is not retried repeatedly: a new release or an explicit administrator **Install when calls finish** request is required.

The Windows x64 package also includes `Upgrade-OpenWebPBX.ps1` for an existing native Windows Server installation. Use the steps below once to upgrade a 1.0.3 installation and install the update service. Use `Install-OpenWebPBX.ps1` only for a new server. Windows 10 and 11 server installations are not yet qualified.

1. Download the complete release from [GitHub](https://github.com/embire2/openwebpbx/releases) and compare its SHA-256 with that release's `SHA256SUMS` file.
2. Extract it into a new folder. Keep every release file together; the updater checks the included file manifest before stopping the server.
3. Choose a time with no active calls. Open PowerShell as administrator in the extracted folder and run:

   ```powershell
   .\Upgrade-OpenWebPBX.ps1 -Check
   .\Upgrade-OpenWebPBX.ps1
   ```

The updater saves private snapshots of the application, configuration, encryption key, call scripts and media while the PBX remains available. It then rechecks for calls and the automatic maintenance window, pauses new calls, stops the owned web application and calling services, copies any media completed during preparation, saves the database, and applies the application and database changes. Allow time and free disk space for copying and verifying the backup; larger recording libraries need a longer maintenance window. It updates the native XML handlers as well as the callback and call-routing scripts. Users, tenants, administrator credentials, mail settings, phone registrations and provider activation settings are not replaced by installation defaults. Phones reconnect when the call service restarts.

An open manager registers a restart task for its signed-in Windows user. The updater closes it only after verification and preparation, then reopens it in that user's interactive session after installation or recovery. It never launches a desktop as SYSTEM. If the user signs out during maintenance, open the manager from its normal shortcut after signing back in.

The local PostgreSQL service continues running during the update. The updater does not move the database or enable a trunk. It checks the background service's version and trusted HTTPS login before declaring success. A failed upgrade restores the previous application, database and updater slot. Automatic recovery preserves media created after the snapshot. Keep the printed private backup path until the new release has passed your own calling checks.

Private logs and the durable recovery journal are under `C:\ProgramData\OpenWebPBX\updates`. During boot, the updater checks this journal before starting the owned FreeSWITCH service, PBX background service and IIS site. These owned components use manual startup; unrelated Windows services and sites keep their existing settings. If recovery cannot finish, maintenance remains in place and an administrator must inspect the private log. To rerun recovery after correcting the cause:

```powershell
& 'C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1' -Recover
```

`Remove-Updater.ps1` in that tools folder removes the updater service and restores the original startup settings for the owned PBX services and IIS site. It preserves update history and backups.

To explicitly return to a completed update backup, stop making changes and run:

```powershell
.\Upgrade-OpenWebPBX.ps1 -RestoreBackup 'C:\ProgramData\OpenWebPBX\backups\BACKUP-FOLDER'
```

Rollback verifies the backup's integrity record, then restores the older database and media snapshot, so changes and recordings made after that snapshot will be lost. Back up anything new before using it. An explicit rollback changes automatic updates to **Let me choose**, preventing immediate reinstallation of the version you removed. Its journal also supports recovery if the rollback is interrupted. Backup folders are restricted to local Administrators and SYSTEM and must never be uploaded to GitHub or a web server. Older backups without a 1.0.4 integrity record require the original release's recovery helper.

After an update, open the WinUI manager, check the displayed version and **Running** status, sign in to **Admin**, and test internal and provider calls. A healthy background service does not establish carrier compatibility. The **Android App** shortcut opens the administrator's phone connection page. A public Android connection requires trusted HTTPS, the configured SIP connection and reachable audio ports; the local setup certificate only covers this Windows computer.

Version 1.0.4 keeps the existing native Windows call-engine package. G.729 transcoding is not qualified on Windows; choose a codec supported by both the phone and the provider and review the provider readiness warnings. No public phone firewall rule or certificate is installed by an upgrade.

To enable the Android app on a public Windows instance, first configure its public hostname and trusted HTTPS binding. Import a matching certificate with an exportable private key into Local Computer → Personal, then run the following from the extracted release:

```powershell
.\Enable-PhoneTLS.ps1 -CertificateThumbprint YOUR_CERTIFICATE_THUMBPRINT -FullChainPath C:\Certificates\fullchain.pem
```

Use the fullchain PEM supplied by your certificate authority to preserve its compatibility path, including cross-signed intermediates. The optional `-FullChainPath` checks that the first certificate matches the selected server certificate and that each following certificate signs the preceding one. Self-signed roots are omitted from the presented chain. Without this option, the helper uses Windows' verified preferred chain, which may require a newer phone trust store.

The helper refuses a local or self-signed setup certificate. It checks for active calls, exports the certificate privately, enables the internal phone listener on TCP 5061 with TLS 1.2 and strict registration identity matching, then verifies an encrypted connection against the public hostname using Windows' normal certificate validator. Only a successful handshake marks Android setup ready. Previous certificate/listener settings are backed up privately and restored if activation fails. Repeat this command after renewing or replacing the certificate. Certificate renewal itself and external firewall rules remain the instance administrator's responsibility. The initial Windows test installation remains local-only until a public hostname and certificate are supplied.
