# Install OpenWeb PBX 1.0.22 on Windows Server 2025

These instructions apply to the Windows Server 1.0.22 package. Check the
[download table](../readme.md) and [qualification status](windows-parity-1.0.22.md)
for availability and the recorded test scope. The Windows calling client is a
separate application.

## Before you start

Use Windows Server 2025 x64 with Desktop Experience and an administrator account.
Complete any pending Windows restart first. Allow at least 30 GB free on C:,
plus room for recordings and retained backups. Visual Studio is not required;
the package supplies its application runtimes. Windows 10 and 11 are not
supported server targets.

The server needs a reachable public IPv4 address. Make TCP 80/443 available for
registration, certificates and web access. The standard calling ports are
TCP/UDP 5060, TCP 5061 for secure phones, TCP/UDP 5080 for providers,
UDP 16384–32768 for audio and UDP 3478 for STUN. Follow the actual configured
listeners and [network guide](../packaging/windows/ACME.md). Configure any
upstream router or firewall; the installer cannot configure that equipment.
STUN is not a TURN relay. PostgreSQL and internal control services stay local.

## Download and install

Use the complete Windows ZIP and its checksum from the same Windows release.
In PowerShell, check the downloaded file:

```powershell
Get-FileHash .\openwebpbx-1.0.22-windows-x64.zip -Algorithm SHA256
```

Compare the result with the published Windows checksum. Extract the complete
archive to a private, short path such as `C:\PBXSetup`, then open
**Start-OpenWebPBX.cmd**. The launcher checks the required Microsoft runtime.

1. Choose **Setup** in the native server manager.
2. Leave **Managed OpenWeb PBX setup (recommended)** selected.
3. Enter the local PBX administrator email and password.
4. Choose **Install OpenWeb PBX** and approve Windows' administrator prompt.
5. Keep the manager open until it offers **Finish registration** or opens the
   setup page in your browser.

The installer creates a server address automatically and installs PostgreSQL,
the call engine, IIS/PHP, administration, background services, backups, updater,
Keoma system prompts and the native manager. You do not need to install or
manage a separate tenant database.

The equivalent command, in built-in **Windows PowerShell 5.1 as Administrator**,
is:

```powershell
.\Install-OpenWebPBX.ps1 -BootstrapRegistration -AdminEmail 'admin@example.com'
```

It prompts for the local administrator password. Use the signed upgrade path
for an existing installation; fresh setup will not overwrite it.

## Finish the same registration wizard used by Debian

The manager opens [openwebpbx.com/wizard](https://openwebpbx.com/wizard) with its
setup code. Follow the page to sign in or create an OpenWeb account, confirm
your email, and choose an available `company.openwebpbx.com` address. If an
email thread contains multiple verification messages, use the newest code.
Codes expire after 30 minutes. The OpenWeb account and the local PBX
administrator are separate sign-ins.

The server prepares its managed DNS, trusted HTTPS certificate and registration
authorization. Keep it online while this completes. Calling becomes available
after registration succeeds. The manager retries a pending setup link and can
refresh an expired code; no manual DNS record or certificate upload is needed
for managed setup.

Open the tenant address and choose **Open Admin**, or use its `/admin` address.
Sign in with the local administrator details chosen during installation.
Complete **Create my PBX**, add people in **Users**, then use **Voice & Chat**
and **First Calls** to configure and test your provider. An available extension
is suggested automatically when adding a user.

Configure **Outgoing Mail** once for the installation. Test welcome-email
delivery before inviting users. Android users can scan their QR code or enter
the registered tenant address, extension and app password. Desk-phone setup
uses its configured SIP address. See [tenant phone accounts](tenant-phone-accounts.md).

## Updates, backups and replacement servers

The Windows updater checks every five minutes and downloads a verified package
before offering installation. Notices appear in the manager and web interface.
Calls continue if you defer. **Update now** waits for idle calls, installs the
update, restarts services and reopens the manager. Version 1.0.22's signed
upgrade path requires Windows 1.0.21; earlier releases need their supported
intermediate upgrade. See [Windows upgrades](windows-upgrade.md).

Create an encrypted backup and retain its password separately. Windows backups
include the local database, configured media and the private registration
identity needed by a replacement. Restore only onto a clean Windows installation
of the matching release, following [Windows backups](windows-backups.md).
The original source must be stopped before its replacement uses the same
registered address. A restore does not transfer a provider's IP allocation;
moving to another public address requires an authorized address change.
Debian instance archives are not accepted by the Windows restorer. The 3CX V20
configuration importer is a separate migration path.

Before moving live numbers, verify trusted HTTPS, registrations, ringing,
two-way audio, hold, voicemail, incoming/outgoing provider calls and your call
routes. Check backup contents and repeat calling after a planned Windows
restart. Physical phones, providers, cameras and restrictive networks need
their own deployment checks; see [feature coverage](feature-coverage.md).
