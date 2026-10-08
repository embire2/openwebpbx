# Updating Windows Server

The Windows x64 package includes `Upgrade-OpenWebPBX.ps1` for an existing native Windows Server installation. Use `Install-OpenWebPBX.ps1` only for a new server. Windows 10 and 11 server installations are not yet qualified.

1. Download the complete release from [GitHub](https://github.com/embire2/openwebpbx/releases) and compare its SHA-256 with that release's `SHA256SUMS` file.
2. Extract it into a new folder. Keep every release file together; the updater checks the included file manifest before stopping the server.
3. Choose a time with no active calls. Open PowerShell as administrator in the extracted folder and run:

   ```powershell
   .\Upgrade-OpenWebPBX.ps1 -Check
   .\Upgrade-OpenWebPBX.ps1
   ```

The updater stops the web application and calling services, saves a private database dump and snapshots of the application, configuration, encryption key, call scripts and media, then applies the new application and database changes. Allow time for the media copy; larger recording libraries need a longer maintenance window. It updates the native XML handlers as well as the callback and call-routing scripts. Users, tenants, administrator credentials, mail settings, phone registrations and provider activation settings are not replaced by installation defaults. Phones reconnect when the call service restarts.

The local PostgreSQL service continues running during the update. The updater does not move the database or enable a trunk. It checks the background service's version and readiness before declaring success. A failed upgrade attempts to restore the previous application and database. Keep the printed private backup path until the new release has passed your own calling checks.

To explicitly return to a completed update backup, stop making changes and run:

```powershell
.\Upgrade-OpenWebPBX.ps1 -RestoreBackup 'C:\ProgramData\OpenWebPBX\backups\BACKUP-FOLDER'
```

Rollback restores the older database and media snapshot, so changes and recordings made after that snapshot will be lost. Back up anything new before using it. Backup folders are restricted to local Administrators and SYSTEM and must never be uploaded to GitHub or a web server.

After an update, open the WinUI manager, check the displayed version and **Running** status, sign in to **Admin**, and test internal and provider calls. A healthy background service does not establish carrier compatibility. The **Android App** shortcut opens the administrator's phone connection page. A public Android connection requires trusted HTTPS, the configured SIP connection and reachable audio ports; the local setup certificate only covers this Windows computer.

Version 1.0.3 keeps the existing native Windows call-engine package. G.729 transcoding is not qualified on Windows; choose a codec supported by both the phone and the provider and review the provider readiness warnings. No public phone firewall rule or certificate is installed by an upgrade.

To enable the Android app on a public Windows instance, first configure its public hostname and trusted HTTPS binding. Import a matching certificate with an exportable private key into Local Computer → Personal, then run the following from the extracted release:

```powershell
.\Enable-PhoneTLS.ps1 -CertificateThumbprint YOUR_CERTIFICATE_THUMBPRINT -FullChainPath C:\Certificates\fullchain.pem
```

Use the fullchain PEM supplied by your certificate authority to preserve its compatibility path, including cross-signed intermediates. The optional `-FullChainPath` checks that the first certificate matches the selected server certificate and that each following certificate signs the preceding one. Self-signed roots are omitted from the presented chain. Without this option, the helper uses Windows' verified preferred chain, which may require a newer phone trust store.

The helper refuses a local or self-signed setup certificate. It checks for active calls, exports the certificate privately, enables the internal phone listener on TCP 5061 with TLS 1.2 and strict registration identity matching, then verifies an encrypted connection against the public hostname using Windows' normal certificate validator. Only a successful handshake marks Android setup ready. Previous certificate/listener settings are backed up privately and restored if activation fails. Repeat this command after renewing or replacing the certificate. Certificate renewal itself and external firewall rules remain the instance administrator's responsibility. The initial Windows test installation remains local-only until a public hostname and certificate are supplied.
