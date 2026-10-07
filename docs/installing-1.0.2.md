# Install OpenWeb PBX 1.0.2

Choose the **Windows x64** or **Debian 13 amd64** archive on the [1.0.2 release page](https://github.com/embire2/openwebpbx/releases/tag/v1.0.2). Verify its SHA-256 against the release's `SHA256SUMS` file, then extract the entire archive. The application source remains available on the `customization` branch.

Use a fresh PBX installation. The installers refuse to overwrite an existing PBX. They create an administrator, a company workspace and Main PBX, with users **100 Reception** and **101 Office**, random phone passwords and voicemail PINs. No provider is enabled by installation.

## Windows Server

The native edition uses IIS, PostgreSQL, PHP and FreeSWITCH as Windows services, with a C#/.NET 10 background calling service and WinUI 3 manager. It runs directly on Windows; a Linux virtual machine is not required. Validation used Windows Server 2025 Standard with Desktop Experience, .NET 10 and Visual Studio 2026. Visual Studio is a development tool; it is not part of the installer. Binaries are unsigned.

1. Extract the Windows archive into a folder you control.
2. Open **Start-OpenWebPBX.cmd**. The launcher checks for the Microsoft Visual C++ runtime and, if needed, downloads and verifies Microsoft's signed installer. Choose **Setup**, and enter the server name, administrator email and password.
3. For setup on that computer, choose the local certificate. For access from other computers, use a trusted certificate installed in Local Computer → Personal and select it from the list.
4. Select **Install OpenWeb PBX** and approve Windows administrator access. Setup downloads and verifies the required components.
5. Open **Admin** and sign in. The default address is `https://localhost:8443` for local setup.

A local test certificate is trusted only on the installation computer. It does not replace a public certificate for a real PBX hostname. Install a trusted certificate for that hostname before connecting remote users.

For scripted installation, open elevated PowerShell in the extracted folder:

```powershell
.\Install-OpenWebPBX.ps1 -DomainName pbx.example.com -PublicAddress YOUR_SERVER_IP -HttpsPort 443 -CertificateThumbprint YOUR_CERTIFICATE_THUMBPRINT -AdminEmail admin@example.com
```

The password is prompted securely. `-LocalCertificate` can be used instead of a certificate thumbprint for local testing. An interrupted first installation can be resumed with the same script. A completed installation is protected from being overwritten.

Application files live under `C:\OpenWebPBX`; private database, mail, media and runtime data live under `%ProgramData%\OpenWebPBX`. The PBX configuration and encryption key live under `%ProgramData%\fusionpbx`. Services are **FreeSWITCH**, **OpenWebPBX-Database** and **OpenWebPBX**, plus IIS. PostgreSQL uses loopback port 5433; the background service uses loopback port 8087.

Windows Firewall remains under the administrator's control. Permit HTTPS to the chosen port, SIP only for the required phones/providers, and the call engine's configured audio ports. Database and management sockets must remain local. The supplied Windows test machine uses a local setup certificate and is not configured as the public `call.openweb.co.za` host.

## Debian 13

Use Debian 13 on 64-bit Intel/AMD. Run the installer as root from the extracted folder:

```sh
./install.sh --domain pbx.example.com --address YOUR_SERVER_IP --email admin@example.com \
  --certificate /path/to/fullchain.pem --certificate-key /path/to/privkey.pem
```

Enter the administrator password when prompted. Use `--local-certificate` instead of the two certificate options for a local test installation. For a public installation, point the hostname at the server, obtain a trusted certificate, and supply the certificate paths. Your existing `call.openweb.co.za` installation already has a Let's Encrypt certificate and renewal enabled.

The installer installs distribution packages, creates an independent PBX database, configures NGINX/PHP, and starts FreeSWITCH and the .NET background service. Private configuration is under `/etc/fusionpbx` and `/etc/openwebpbx`; private PBX media is under `/var/lib/freeswitch`. Application source is under `/var/www/fusionpbx`.

## First calls

Open **Admin → Users**, choose a user, and open **Phone Settings** to view that user's phone credentials. Register two SIP phones against your server using the displayed PBX domain, then call between the users. Open **Voice & Chat** to add your provider and incoming numbers, and **Outbound Rules** to allow outside calls. Check a real incoming and outgoing call before putting a service into production.

See [callbacks and hotels](callbacks-and-hotels.md) for the new features. The [feature coverage](feature-coverage.md) document distinguishes working features from remaining 3CX differences. OpenWeb PBX is independent software; proprietary 3CX clients and hosted services do not become compatible through a backup import.

## Updating an existing installation

Back up the PostgreSQL database, private encryption keys, configuration and media before updating. Stop the `openwebpbx`/`OpenWebPBX` background service, deploy reviewed application source and the matching service binaries, apply `app/pbx_setup/resources/jobs.sql` to the PBX database, and deploy the matching `app/pbx_setup/resources/switch/scripts` and prompt files. Preserve local configuration, keys and media. Restart the background service and reload the call engine's XML configuration. Do not run a fresh-install script over an existing PBX.

The installation archives do not contain customer backup data, credentials, existing tenants or recordings. Keep backups private; the encryption key is required to read encrypted templates and draft imports after restoring a database backup.
