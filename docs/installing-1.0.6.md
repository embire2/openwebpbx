# Install OpenWeb PBX 1.0.6

Choose the **Windows x64** or **Debian 13 amd64** archive on the [1.0.6 release page](https://github.com/embire2/openwebpbx/releases/tag/v1.0.6). Verify its SHA-256 against the release's `SHA256SUMS` file, then extract the entire archive. The application source remains available on the `customization` branch.

For a new server, use the fresh installation steps below. For an installed server, use the separate update command. The fresh installers refuse to overwrite an existing PBX. They create an administrator, a company workspace and Main PBX, with users **100 Reception** and **101 Office**, random phone passwords and voicemail PINs. No provider is enabled by installation.

Both installers automatically install PostgreSQL **on the PBX computer** and create one application database for the installation. Every tenant and PBX service uses that database; tenant administrators never enter database settings or create separate databases. Tenant and service permissions keep their records separate inside the shared database. The internal database and account retain the name `fusionpbx` for compatibility with the installed PBX stack.

Database credentials are generated during setup and kept in private configuration. A remote database service is not required for either edition. Back up the instance's database, encryption keys and media together.

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

The installer installs PostgreSQL and the other distribution packages, creates one local application database shared by all tenants, configures NGINX/PHP, and starts FreeSWITCH and the .NET background service. Private configuration is under `/etc/fusionpbx` and `/etc/openwebpbx`; private PBX media is under `/var/lib/freeswitch`. Application source is under `/var/www/fusionpbx`.

## First calls

Open **Admin → Users**, choose a user, and open **Phone Provisioning** to view that user's phone credentials. Register two SIP phones against your server using the displayed PBX domain, then call between the users. Open **Voice & Chat** to add your provider and incoming numbers, and **Outbound Rules** to allow outside calls. Check a real incoming and outgoing call before putting a service into production.

See [callbacks and hotels](callbacks-and-hotels.md) for the new features. The [feature coverage](feature-coverage.md) document distinguishes working features from remaining 3CX differences. OpenWeb PBX is independent software; proprietary 3CX clients and hosted services do not become compatible through a backup import.

## Updating an existing installation

Version 1.0.6 includes the independent signed-release updater for Debian 13 and Windows Server. Open **Admin → System → Updates** to choose notification, download or scheduled automatic installation. The default is notification. All instance tenants use this one server policy and database.

An existing 1.0.4 instance can use **Admin → System → Updates** to install 1.0.6. An existing 1.0.3 instance needs a one-time manual upgrade to install the new worker and trusted verification key. Read [application updates](updates.md) before starting: it includes the complete signed-archive commands, private backup behavior, active-call checks, interrupted-update recovery and supported database layouts. The fresh installer continues to refuse an existing PBX. Windows-specific commands are in [Windows updates and recovery](windows-upgrade.md).

## Android phone app

Download the signed **Android APK** from the same release page. It supports Android 9 or later on ARM and x86-64 devices. This is a native calling app, separate from the Windows administration manager. It connects to your own OpenWeb PBX 1.0.6 server.

1. Install the APK from the release download, allowing your browser to install this app when Android asks.
2. In Admin, open **Users → Phone Provisioning** for the extension, select **Connect Android App · QR Code**, then choose **Show QR code**.
3. Open the Android app and scan that QR code. The setup code is single-use and expires; generate a new code if it has expired.
4. Allow microphone and notification access for calls. Keep the app's connection notification enabled while receiving calls.
5. Test an internal incoming and outgoing call before enabling outside calling for the user.

The app provides extension setup, incoming/outgoing calling, call controls, a company directory and recent calls, and voicemail. The PBX must have trusted HTTPS and a trusted TLS phone connection. A local test certificate is insufficient for a public Android deployment. Administrators should follow the [mobile guide](android.md) for certificate, network and device setup, supported call controls and current limits.

For an existing Debian installation, configure the phone connection after updating, during an idle call window:

```sh
python3 configure-sip-tls.py --domain pbx.example.com \
  --fullchain /etc/letsencrypt/live/pbx.example.com/fullchain.pem \
  --private-key /etc/letsencrypt/live/pbx.example.com/privkey.pem
```

The helper verifies the trusted certificate chain, hostname, validity and private-key match, installs private certificate copies for the enabled internal IPv4/IPv6 phone profiles, and checks the actual TLS listeners and served certificate chain before enabling mobile setup. It preserves the supplied cross-signed certificate path for phones whose trust stores do not contain newer root certificates. It preserves strict phone-registration identity matching. Permit TCP 5061 and the configured audio ports through the server/provider firewall. New Debian installations supplied with a trusted certificate run this helper automatically; local-certificate test installs do not advertise mobile readiness.

A daily private helper retries phone-certificate renewal. It first uses FreeSWITCH's certificate reload event and verifies the presented certificate; if that engine requires a profile restart, it waits for an idle call state and retries on the next daily run when calls are busy. Certificate expiry monitoring remains part of instance operations. Read the `openwebpbx-sip-tls` journal messages when a renewal needs attention.

The initial Android release uses a persistent foreground connection. It cannot wake an app that Android has force-stopped, and push delivery across device power-saving modes remains unqualified. Test the handset and networks your users actually use before replacing their existing phone app. Android source and its AGPL-3.0-or-later license/component notices are in `mobile/android/`; the server retains its existing licenses.

The installation archives contain no customer backups, credentials, existing tenants or recordings. Keep backups private; the encryption key is required to read encrypted templates and draft imports after restoring a database backup.
