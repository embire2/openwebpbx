# Install OpenWeb PBX 1.0.29 on Windows Server

**Use one complete installer on a clean Windows Server 2025 x64 machine with
Desktop Experience.** The full ZIP includes the PBX, native server manager,
call engine, database setup, web administration, system prompts, background
workers and updater. Setup installs a local PostgreSQL database for the PBX.
No older PBX, separate repair, Visual Studio, .NET SDK or system Python is
required.

## Prepare Windows

Use an administrator account, internet connectivity, a reachable public IP
and at least 30 GB free for setup and working files. Finish any pending
Windows restart. The installer prepares the required Windows features, IIS,
PHP and Microsoft Visual C++ runtime. If Windows requests a restart for
prerequisites, resume with the same installer.

## Verify and install

1. Compare the complete ZIP with the matching release checksum.

   ```powershell
   Get-FileHash .\openwebpbx-1.0.29-windows-x64.zip -Algorithm SHA256
   ```

2. Extract the entire archive to an empty folder in your Windows administrator
   profile, such as `%USERPROFILE%\PBXSetup29`. Use a folder that only Windows
   administrators and the system can modify. Keep `installation.json`,
   `release-manifest.json` and all component folders together. An optional
   package preflight uses Windows PowerShell 5.1.

   ```powershell
   powershell.exe -NoProfile -File .\Install-OpenWebPBX.ps1 -Check
   ```

3. Run **Start-OpenWebPBX.cmd**, open **Setup**, keep **Managed OpenWeb PBX
   setup** selected, and enter a local administrator email and password.
   Choose **Install OpenWeb PBX** and approve elevation.
4. Choose **Finish registration**, then follow the setup wizard to register
   the tenant address. Sign in to the PBX after trusted HTTPS is ready and
   finish **Create my PBX**. [Managed setup wizard](https://openwebpbx.com/wizard)

The ordinary command-line installer supports the same managed setup from an
administrator PowerShell window and prompts for the local password.

```powershell
.\Install-OpenWebPBX.ps1 -BootstrapRegistration -AdminEmail 'admin@example.com'
```

## Configure calling and updates

Add people in **Users**, connect their phones, and add a provider and numbers
in **Voice & Chat**. Use **First Calls** to verify calling and record any
blocker. Restore Report covers the inspected 3CX V20 Update 9 and Update 10
backup builds. Keep imported trunks disabled until their settings are
confirmed. [Calling guide](core-calling.md) · [3CX restore](v20-restore.md)

The fresh installer refuses to overwrite an existing PBX. On a supported
existing instance, **Software Updates** and the native manager use verified
signed releases and wait for an administrator to approve installation.
The updater waits for active calls to end and retains a recovery snapshot.
Keep an encrypted backup and its password separately. [Recovery](windows-backups.md)
