# Install OpenWeb PBX 1.0.21 on Windows Server 2025

This is the complete Windows server package: the local PostgreSQL database,
calling engine, browser administration, background services, backups, updater
and native Windows server manager. Each installation hosts multiple tenants.
OpenWebPBX Free Phone for Windows is a separate client still in development.

Version1.0.21 adds five-minute update checks, desktop/web notices, Greetings recording and reuse, group-managed hours and Add DID. **Complete Windows and Debian server1.0.21 release**. Built-in Keoma prompts are included; optional typed narration uses your configured voice-provider account and its charges.

## Download and verify

Download the Windows ZIP, `SHA256SUMS` and this guide from the same
[1.0.21 release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.21).
In PowerShell, run:

```powershell
Get-FileHash .\openwebpbx-1.0.21-windows-x64.zip -Algorithm SHA256
```

Compare the result with its entry in `SHA256SUMS`, then choose **Extract All**
and open the extracted `openwebpbx-1.0.21-windows-x64` folder.

## Set up the server


Use the matching `openwebpbx-1.0.21-windows-x64.zip` and its published `SHA256SUMS`. Windows Server 2025 x64 with Desktop Experience is the supported server target. The server installer refuses Windows 10/11; the native Windows calling client is a separate project.

Extract the complete archive to a private directory and run **Start-OpenWebPBX.cmd**. It checks Microsoft's required runtime before opening the WinUI manager. Choose **Setup**, enter the server hostname and administrator email/password, and select **Automatic public certificate**. Approve Windows' administrator prompt to install. The hostname must point at the server, with TCP 80/443 and the documented SIP/audio ports reachable. After setup, use the installed desktop shortcut. The equivalent command in built-in **Windows PowerShell 5.1 as Administrator** is:

```powershell
.\Install-OpenWebPBX.ps1 -DomainName 'pbx.example.com' -EnablePublicAccess -HttpsPort 443 -AdminEmail 'admin@example.com'
```

Managed `*.openwebpbx.com` server hostnames use HTTPS 443. Other new installations default to 8443; the public command above explicitly selects 443. Use a nonmanaged test hostname for local 8443 trials. Existing saved hostname/port and deliberate custom choices remain authoritative.

Setup installs the local PostgreSQL database, IIS/PHP, call engine, background service, updater, backup tooling, offline Keoma prompts, secure meeting proxy and the server manager. No separate database server is needed. The call engine starts during setup; provider trunks must be configured and explicitly enabled before provider calls can run. For a clean replacement receiving an encrypted **Windows** instance backup, add `-RestoreServer` and retain the original public hostname and HTTPS port. Debian instance backups are not accepted by the Windows restorer; the 3CX configuration importer is a separate migration path. See [Windows meeting transport](https://github.com/embire2/openwebpbx/blob/customization/docs/windows-meet.md) for the scoped proxy prerequisites and recovery behavior. Preserve existing installations and use the manager/updater's documented upgrade path; never run a fresh installer over an existing PBX. Check [Windows upgrade guidance](https://github.com/embire2/openwebpbx/blob/customization/docs/windows-upgrade.md), the platform's actual release notes and the feature-coverage limits before replacing a production system.

Before setup, finish any pending Windows restart and use an administrator account. The launcher checks the required Microsoft Visual C++ x64 runtime and verifies Microsoft's signature before installing it; follow a requested restart before continuing. Use built-in Windows PowerShell 5.1 for setup, because its IIS modules are required. The release supplies its application runtimes; installing Visual Studio is not a server prerequisite.

We recommend at least **30 GB free on C:** before setup or an upgrade, plus storage for your recordings and retained backups. Let Windows updates finish and complete their requested restarts first. Microsoft's [Windows Server update guide](https://learn.microsoft.com/en-us/troubleshoot/windows-server/deployment/troubleshoot-windows-server-update-guidance) covers update and pending-restart checks.

For public access, point one public IPv4 DNS record at the server or its forwarding router. The standard network plan uses TCP 80/443 for certificate validation/web access, TCP/UDP 5060 for phones, TCP/UDP 5080 for providers, TCP 5061 for phone TLS, UDP 16384–32768 for call audio and UDP 3478 for STUN. SIP rules follow the actual configured listeners. The installer does not configure an upstream router; STUN is not a TURN relay. See the [Windows network and certificate guide](https://github.com/embire2/openwebpbx/blob/customization/packaging/windows/ACME.md) for the exact checks and renewal behavior. PostgreSQL, the call-engine control socket and the local service API stay local.

After setup, verify all of the following before moving live numbers:

- Open the installed manager and check its version and Running status; sign in through the intended trusted HTTPS hostname without a certificate warning.
- Connect two phones and prove ringing, two-way audio, hold/resume and voicemail. Then test the configured provider's incoming/outgoing calls and routes.
- Verify Phone Health shows the expected registrations, send a controlled welcome email, and test the tenant address/Android connection and any browser meetings you use.
- Create and verify an encrypted backup. For a replacement, follow the [Windows backup and restore guide](https://github.com/embire2/openwebpbx/blob/customization/docs/windows-backups.md), including separate activation of calls and jobs.
- In a planned maintenance window, restart Windows and repeat service, HTTPS and calling checks on your deployment before cutover.


## Add people and make your first calls

Sign in through **Open Admin** in the installed manager. Add people in **Users**;
a free extension is suggested automatically. Use **Voice & Chat** to add the
phone provider and choose who answers incoming calls. **First Calls** records
internal, incoming and outgoing test results before moving live numbers.

Outgoing email is configured once for the installation. **Outgoing Mail**
supports a normal SMTP account or an IP-whitelisted relay without a username
and password. A relay must accept this server's public address and From address.
Send a controlled welcome email and verify receipt before inviting the team.

For Android, complete tenant-address registration, then connect **OpenWebPBX
Free Phone 1.0.19** with a QR code, welcome configuration or tenant address,
extension and app password. The Android app requires a registered
`*.openwebpbx.com` tenant address. Desk-phone addresses have their own setup.
See [tenant phone accounts](https://github.com/embire2/openwebpbx/blob/customization/docs/tenant-phone-accounts.md).

## Move from 3CX or restore a Windows backup

The 3CX V20 configuration importer preserves supported extension numbers,
separate authentication IDs and password bytes. Review **Restore Report**, then
test the actual phones and phone provider before the agreed handover. Proprietary
3CX apps need replacement. Existing custom greetings and recordings are retained.

Encrypted Windows instance backups are a separate restore path. Prepare a clean
replacement with **Restore Server**, retain its intended public hostname and
follow the [Windows restore guide](https://github.com/embire2/openwebpbx/blob/customization/docs/windows-backups.md).
Calling and jobs have separate activation controls. The target retains its own database credentials and HTTPS certificate. While restored calling is held, prepare its current trusted/exportable phone certificate as described in the restore guide; activate calls only after success. Use the target certificate while calling remains held:

```powershell
& 'C:\OpenWebPBX\tools\Enable-PhoneTLS.ps1' -CertificateThumbprint 'TARGET_CERTIFICATE_THUMBPRINT' -PrepareRestored
```

A Debian instance backup is not a Windows restore input.

## Updates and support

The server checks the signed Windows feed every five minutes and prepares a verified download. A desktop modal and red web banner make a required update visible. **Later** keeps calls, registrations and administration running. Choose **Update now** when ready: installation waits for idle calls, runs unattended, restarts services and reopens the manager. Keep backup passwords, provider credentials and private keys private.

Use the installed update controls for existing installations. The independent
Windows feed requires an installed version of at least 1.0.20; earlier Windows installations require a separately
qualified legacy transition. Never run fresh setup over an installed PBX.

The complete Debian 13 server also has a 1.0.21 package with its own source snapshot. Android remains 1.0.19; Windows Free Phone remains unreleased. Windows 10/11
server installation is unsupported. Physical phones, carriers, cameras and
network conditions need their own deployment checks. Review the release's actual
qualification scope and [feature roadmap](https://github.com/embire2/openwebpbx/blob/customization/3CX.md).

For source builds, use the Windows [`v1.0.21`](https://github.com/embire2/openwebpbx/tree/v1.0.21) snapshot and matching source archive; Debian builds use `debian-v1.0.21`. [Recorded checks and limits](https://github.com/embire2/openwebpbx/blob/customization/docs/windows-parity-1.0.21.md).
