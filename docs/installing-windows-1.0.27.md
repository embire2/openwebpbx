# Install OpenWeb PBX 1.0.27 on Windows Server

**One complete installer. No previous OpenWeb PBX installation is required.**
The Windows package includes the PBX, native server manager, call engine,
local PostgreSQL database setup, web administration, APIs, system prompts,
background workers and current ordered updater. You do not need an older PBX,
a separate PBX repair, Visual Studio, a .NET SDK or system Python.

Use the complete `openwebpbx-1.0.27-windows-x64.zip` and matching `SHA256SUMS`
from the [Windows release](https://github.com/embire2/openwebpbx/releases/tag/windows-v1.0.27).
Read the [qualification record](release-windows-1.0.27-qualification.md) for the
actual tested scope and remaining deployment checks. The Windows calling
client is a separate product; the included native manager administers the server.

## Prepare Windows

Use **Windows Server 2025 x64 with Desktop Experience**, administrator access,
internet connectivity and a reachable public IP. Windows 10/11 and Server Core
are not supported server targets. Finish any pending Windows restart first.
Allow at least 30 GB free for setup, then additional space for recordings,
encrypted backups and the retained upgrade snapshot. The transaction checks
its own space requirement before changing an existing server.

The installer prepares IIS/PHP, required Windows features and the Microsoft
Visual C++ runtime automatically. Windows may require a restart to complete
its feature/runtime setup; resume the same installer after that restart.
Application runtimes and the isolated backup interpreter are included.
An internet connection is also needed for managed tenant registration, DNS,
trusted HTTPS and signed update checks.

Keep the database and internal control interfaces local. Use the
[network and certificate guide](installing-windows-1.0.22.md#before-you-start)
for the configured listeners. STUN and PBX-delivered audio do not establish
universal connectivity through every firewall; TURN remains a separate capability.

## Verify and extract

Compare the ZIP against its release checksum before extracting it:

```powershell
Get-FileHash .\openwebpbx-1.0.27-windows-x64.zip -Algorithm SHA256
```

Extract the **entire** ZIP to a new short folder, such as `C:\PBXSetup27`.
Keep every component, `installation.json` and `release-manifest.json` together.
Do not extract over an installed PBX or combine files from different releases.

Optional read-only validation uses built-in Windows PowerShell 5.1 and the
included isolated interpreter; it does not install runtimes or change the PBX:

```powershell
powershell.exe -NoProfile -File .\Install-OpenWebPBX.ps1 -Check
```

`-Help` displays setup guidance without requiring administrator access.
The full-package check refuses missing, changed or extra payloads and unsafe
paths. The installer protects an existing PBX instead of overwriting its data.

## Install a new server

1. Open **Start-OpenWebPBX.cmd**, then select **Setup** in the native manager.
2. Keep **Managed OpenWeb PBX setup (recommended)** selected. Enter the local
   PBX administrator email and password, then choose **Install OpenWeb PBX**.
3. Approve the administrator prompt and keep the manager open. Choose
   **Finish registration** when offered.
4. Follow the ordinary [setup wizard](https://openwebpbx.com/wizard). Sign in
   or verify your OpenWeb account and choose an available
   `company.openwebpbx.com` tenant address. The OpenWeb account and local PBX
   administrator are separate sign-ins.
5. Let the normal background tasks prepare DNS, trusted HTTPS and registration.
   Open the tenant address, sign in and complete **Create my PBX**.
6. Add people under **Users**, connect two phones, then configure your provider
   under **Voice & Chat** and test incoming and outgoing calling.

The equivalent fresh-install command, in **Windows PowerShell 5.1 as
Administrator**, is:

```powershell
.\Install-OpenWebPBX.ps1 -BootstrapRegistration -AdminEmail 'admin@example.com'
```

It prompts for the local administrator password. PostgreSQL is installed
locally for this instance; tenants share that database with enforced tenant
boundaries. Configure **Outgoing Mail** before sending user invitations.
Reusable Android QR codes contain the tenant address and remain unchanged
until an authorized user explicitly resets them.

## Included administration and recovery

The package carries the shared Debian 24–27 application features together with
their Windows service integration:

- Call Me Back provider selection for the callback leg, nine speed dials and
  editable narration scripts, with default-script recovery.
- Tenant templates, provider presets, extension and concurrent-call packages,
  resource requests and scoped client workspaces.
- Tenant Admin and PBX backup/restore controls, encrypted archives and a
  Windows recovery worker. Full-instance recovery still requires explicit
  confirmation and a verified backup; it is not a casual import operation.
- API Keys and API Documentation for tenant administrators, PBX administrators
  and linked users. Permissions follow the current tenant, PBX and account
  role on every request. The reference is [available online](https://openwebpbx.com/api-docs).
- Isolated streaming backup uploads with admission checks before PHP consumes
  the archive, plus local worker and storage limits.

Use **Voice & Chat → DID Numbers** to add or edit an incoming destination in
one place. Select a user, ring group, receptionist, external number or configured
Call Me Back service. A new number starts off until explicitly enabled.
Do not copy the hosted OpenWeb tenant's customer routes into another installation.

## Update an existing server

Fresh installation has **no previous-PBX prerequisite**. Updating existing
data is a separate transaction with its own supported source versions and
signature, idle-call, backup, space and recovery checks.

For a supported existing installation, use **Admin → Updates** or the native
server manager. The updater checks every five minutes, downloads and verifies
the complete package before installation, waits for calls to finish, retains
a recovery snapshot, installs it and starts the services again. An available
update does not stop calling while an administrator waits to install it.

The Windows 1.0.27 signed offer accepts installed **1.0.23 or newer**.
Older installations follow the preserved signed intermediate release path;
original legacy workers may need their separately documented
[ordered-updater bootstrap](windows-upgrade-path-repair.md). A **new 1.0.27
installation already includes the current updater** and does not need that repair.
No historical package, signature or trust floor is rewritten.

Automatic update and recovery helpers select Windows PowerShell's MTA mode
before managing IIS. Operator-only command-line recovery must also use `-Mta`:

```powershell
powershell.exe -NoProfile -NonInteractive -Mta -ExecutionPolicy Bypass -File C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1 -Recover
```

For an explicitly chosen completed update snapshot, use the same command with
`-RestoreBackup 'C:\ProgramData\OpenWebPBX\backups\YOUR_COMPLETED_SNAPSHOT'`
in place of `-Recover`. The original snapshot, ownership and recovery checks
still apply. Prefer **Update Now** for normal updates; no manual command is
needed for ordinary installation or updating.


Keep the backup password separately and retain the printed recovery path.
Check version, administrator access, tenant configuration and two phones after
an update. Physical phone, provider, ringing and answered two-way audio checks
remain necessary for your own deployment.

## Recover an installation

Use the dashboard's verified encrypted backups and the
[Windows recovery instructions](windows-backups.md). Tenant archives restore
only their authorized workspace. A full-instance archive contains broader
configuration and private identities and requires the instance-level recovery
workflow. Preserve the source server offline when moving an existing registered
address to a replacement; do not run two writers for the same PBX.

Read [platform release rules](independent-platform-releases.md) and the
[Debian-to-Windows ledger](debian-windows-sync.md) for independent version and
qualification status. Matching server version numbers are not a claim of
complete 3CX parity, carrier acceptance or Store approval.
