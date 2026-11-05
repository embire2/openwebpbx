# Install OpenWeb PBX 1.0.23 on Windows Server

Use the complete Windows Server package and its matching checksums from the
[Windows 1.0.23 release](https://github.com/embire2/openwebpbx/releases/tag/windows-v1.0.23).
This server release includes the unified incoming-number wizard, clearer
external forwarding, Call Me Back setup and corrected recovery of permissions
for call records already consumed by the normal importer.

The Windows calling client is a separate product. The included native server
manager is used for setup and updates. Read the [qualification record](release-windows-1.0.23-qualification.md)
for tested scope and deployment-specific checks.

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
local. Qualify your own provider and network before a cutover. TURN is a separate capability.

## Verify the package

Download `openwebpbx-1.0.23-windows-x64.zip` and `SHA256SUMS` from the same
release. Compare the checksum before extracting:

```powershell
Get-FileHash .\openwebpbx-1.0.23-windows-x64.zip -Algorithm SHA256
```

The archive is **643,269,105 bytes** with SHA-256:

```text
badc4326b48d1e7953990eb382f598602bb23bd068ca27c42abf22c25ce10907
```

Its **19,288** manifested payloads bind the corrected Windows source
`e1aaad63f99ac3b11714d9d0cd3f2a085778688f`.

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

The signed update requires **installed Windows 1.0.22 or newer**. Make a verified
encrypted backup and keep its password separately. Open **Admin → Updates** or
the native server manager, download the update and choose **Install** when
ready. The server checks for updates every five minutes. Its banner and desktop
notice offer installation after the complete download is verified; calling
continues while an update is available.

Installation waits for calls to finish, keeps a recovery snapshot, updates the
server and starts its services again. Keep the server online through this
process. Check the displayed version, tenant settings and two phones afterward.

For a manual upgrade from the complete verified package, run built-in
**Windows PowerShell 5.1 as Administrator** in its extracted folder:

```powershell
.\Upgrade-OpenWebPBX.ps1 -Check
.\Upgrade-OpenWebPBX.ps1
```

Keep the printed recovery path. Earlier server versions need their separately
supported intermediate upgrade before using the 1.0.23 offer.

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
saved aliases are retained when exact entry is selected. The Windows browser checks cover this choice and preserve the original PBX setting.

For an explicitly selected South African plan, supported national and +27
formats can identify the same DID. Without that setting, use the exact number
format delivered by the provider. The software does not infer a country from a
hostname, public IP, account name or an arbitrary leading zero. This is not a
global conversion of every number or a migration of another tenant's routes.

Do not apply the hosted OpenWeb PBX's numbers or destinations to a new Windows
PBX. Provider delivery may use the To user or Request-URI user according to its
saved trunk setting; record the actual format before changing that setting.

## After upgrading

Check the wizard through an ordinary authenticated browser, then test the
specific provider delivery, ringing and answered two-way audio needed by your
installation. A saved route or registered provider does not establish an
answered carrier call. Verify an encrypted backup containing the new routing
settings, current credentials, private keys and required recordings.

No fresh registration claim is needed for an existing upgraded PBX. Preserve
its registration policy, tenant address, phone credentials and reusable QR
codes. See the matching qualification record for the tested software scope. Physical
phones, carrier cutovers and Store distribution have separate requirements.
