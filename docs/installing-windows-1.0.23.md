# Install the local Windows Server 1.0.23 candidate

**Local, unpublished candidate.** Windows1.0.23 has passed private installed
upgrade, DID browser, native manager and buffered software-call checks. The
final audio-corrected installer is being repackaged. There is no public
Windows1.0.23 download, signed feed or release tag. Use only the
complete privately supplied package and its recorded SHA-256. The published
Windows 1.0.22 release and its qualification remain separate.

See [local scope and pending checks](windows-local-1.0.23.md). The Windows
calling app is a separate product; the server manager included here does not
establish a phone-client or Microsoft Store release.

## Before installation

Use **Windows Server 2025 x64 with Desktop Experience** and a local administrator
account. Complete any pending Windows restart first. Keep at least 30 GB free
on C:, with additional room for recordings, encrypted backups, extraction and
the retained upgrade snapshot. Windows 10/11 are not supported server targets.

The complete package supplies PostgreSQL, the call engine, IIS/PHP, the local
PBX services, updater, native manager and application runtimes. Do not assemble
an installation from selected web files or copy another server's configuration.
Use the existing [Windows network and certificate instructions](installing-windows-1.0.22.md#before-you-start)
for the actual configured listeners. Keep database and internal control access
local. This candidate does not add TURN or qualify every provider or network.

## Verify the private package

The expected package name is `openwebpbx-1.0.23-windows-x64.zip`. Compare its hash
with the private build handover, not a checksum copied from Windows 1.0.22:

```powershell
Get-FileHash .\openwebpbx-1.0.23-windows-x64.zip -Algorithm SHA256
```

The initial **intermediate** private archive is643,266,840 bytes with19,288
manifested payloads. It predates the tested Windows audio-buffer correction;
use the final corrected handover instead. Initial intermediate SHA-256:

```text
dd9ac9f94bd19bf05032ba387b7fc91e3913260d55cc30aa8de20a1f688b01be
```

There is no public download URL for this candidate.
Extract the entire archive into a new short folder readable by the installing
account, such as `C:\PBXSetup23`. Keep `release-manifest.json` and every package
component together.

## A new Windows server

1. Open **Start-OpenWebPBX.cmd**, then choose **Setup** in the native manager.
2. Keep **Managed OpenWeb PBX setup (recommended)** selected. Enter the local
   administrator email and password, then choose **Install OpenWeb PBX**.
3. Approve the administrator prompt and keep the manager open. Choose
   **Finish registration** when offered.
4. Follow the ordinary [registration wizard](https://openwebpbx.com/wizard):
   sign in or verify an OpenWeb account, then choose an available tenant address.
   The OpenWeb account and the local PBX administrator are separate sign-ins.
5. Leave the server online while its normal background tasks prepare DNS,
   trusted HTTPS and registration. Open the tenant address, sign in to Admin
   and complete **Create my PBX**.

The equivalent fresh-install entry point is built-in **Windows PowerShell 5.1
as Administrator**, in the complete extracted package:

```powershell
.\Install-OpenWebPBX.ps1 -BootstrapRegistration -AdminEmail 'admin@example.com'
```

It prompts for the local administrator password. Fresh installation protects an
existing installation; use an upgrade for an already installed server. An empty
**RestoreServer** replacement is a different workflow, with the original source
preserved offline before restoring its registered address. See [Windows backups](windows-backups.md).

## Upgrade an existing Windows 1.0.22 installation

This candidate uses the existing **manual upgrade from a complete extracted
package**. It does not create or offer a public update. Retain a current verified
encrypted backup, its password separately, and the existing installation's
identity, credentials, recordings and configuration before maintenance.

With no active calls, open built-in **Windows PowerShell 5.1 as Administrator**
in the verified extracted 1.0.23 package. Follow the reviewed local maintenance
plan, starting with:

```powershell
.\Upgrade-OpenWebPBX.ps1 -Check
.\Upgrade-OpenWebPBX.ps1
```

These commands intentionally have no `-Archive` or `-FeedEnvelope` argument.
They use this complete package and its manifest, with the normal installed
service checks, call/restore holds, maintenance lock, private rollback snapshot
and health checks. They do not advance the installed feed-trust floor. Do not
replace the installed release key, edit updater caches or publish a temporary
feed to make this local installation appear as a public release.

Keep the helper's printed private backup path. Confirm version 1.0.23 in the
manager and Admin, preserved tenant/phone/provider settings, trusted web access
and calling after maintenance. This local check targets **22→23**; it does not
extend the public minimum-version policy or qualify an earlier installed version.

## Set incoming destinations in one place

Open **Voice & Chat → DID Numbers**. Both a trunk's **Add DID Number** link and
an existing number's **Edit** link open the same wizard:

1. **Number & provider:** choose the number supplied by your provider and its
   SIP trunk. The provider account/main number identifies the connection; it is
   not a second destination editor.
2. **Destination:** choose a user, external number, call-handling destination or
   an already configured Call Me Back service. All day is the simple route;
   office hours and a closed-hours destination are optional. Existing holiday
   routing is retained and identified on the page.
3. **Review & save:** check the destination and whether incoming calls are on.
   A new number starts off. Saving does not turn on its provider.

If Call Me Back is not configured, **Call Me Back (set up)** saves the number
and opens service setup. It does not activate the service. An existing number
keeps its destination during setup; a new number remains off. Prepare the
greeting/accounts, then choose Call Me Back as the number's destination in this
same wizard. Its settings page is not a second routing switch.

The number list shows the effective current destination, schedule and enabled
state. Provider fallback routes are behind a disclosure. A configured DID that
is switched off must not send its callers to an unrelated fallback destination.
Preserved provider-number aliases use the same DID and destination.

## Choose number formats explicitly

In step1 of the DID wizard, use **Number format**. Choose **South Africa (+27)**
only when that PBX uses the South African numbering plan. **Use current PBX
setting** preserves its existing choice; **Use exactly what I enter** avoids
adding national/international equivalents for another numbering plan. Existing
saved aliases are retained when exact entry is selected. The final Windows
browser check of this control is still pending.

For an explicitly selected South African plan, supported national and +27
formats can identify the same DID. Without that setting, use the exact number
format delivered by the provider. The software does not infer a country from a
hostname, public IP, account name or an arbitrary leading zero. This is not a
global conversion of every number or a migration of another tenant's routes.

Do not apply the hosted OpenWeb PBX's numbers or destinations to a new Windows
PBX. Provider delivery may use the To user or Request-URI user according to its
saved trunk setting; record the actual format before changing that setting.

## After the local upgrade

Check the wizard through an ordinary authenticated browser, then test the
specific provider delivery, ringing and answered two-way audio needed by your
installation. A saved route or registered provider does not establish an
answered carrier call. Verify an encrypted backup containing the new routing
settings, current credentials, private keys and required recordings.

No fresh registration claim is needed for an existing upgraded PBX. Preserve
its registration policy, tenant address, phone credentials and reusable QR
codes. Public release qualification, signed updater delivery, physical phones,
carrier cutovers and Store distribution remain outside this local guide's claim.
