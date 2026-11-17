# Install OpenWeb PBX 1.0.27 on Debian 13

**This is a complete standalone server installer. Start with a clean Debian 13
amd64 machine; no previous OpenWeb PBX version is required.** The download
contains the PBX application, calling engine, administration/API, updater,
background services and system voice prompts. Setup installs PostgreSQL on the
same machine and prepares the complete server.

You need root access, a reachable public IP address and internet access for
Debian packages and tenant registration. The [qualification record](release-1.0.27-qualification.md)
identifies the exact published files and the checks performed on them.

## Install a new server

1. Download `openwebpbx-1.0.27-debian13-amd64.tar.gz` and `SHA256SUMS` from the
   same [Debian 1.0.27 release](https://github.com/embire2/openwebpbx/releases/tag/debian-v1.0.27).
   Compare the archive's SHA-256 with the matching line in `SHA256SUMS`.
2. Extract the complete archive into an empty private directory. As root:

   ```sh
   sha256sum openwebpbx-1.0.27-debian13-amd64.tar.gz
   tar -xzf openwebpbx-1.0.27-debian13-amd64.tar.gz
   cd openwebpbx-1.0.27-debian13-amd64
   ./install.sh --bootstrap-registration --address YOUR_PUBLIC_IP --email admin@example.com --stun
   ```

3. Choose the local administrator password when prompted. Follow the printed
   setup link to the [registration wizard](https://openwebpbx.com/wizard), sign
   in to or verify your OpenWeb account, enter the company details and choose
   an available `company.openwebpbx.com` address. Setup prepares managed DNS and
   trusted HTTPS. Calling starts when registration is ready.
4. Open your tenant address, sign in with the local administrator account and
   complete **Create my PBX**. Add people, connect two phones and test calling.
   Add your provider and incoming numbers in **Voice & Chat** before moving
   live numbers.

The OpenWeb account used for registration and your local PBX administrator are
separate sign-ins. Your PBX and PostgreSQL database stay on your own server.
The complete download supplies the current application and services together;
installing an older PBX or applying a separate PBX patch is not a setup step.

For a read-only package and machine check before installation, run
`./install.sh --check`. On a minimal OS without Python3, the normal installer
prepares it automatically; `--check` reports it missing without installing it.
Use `./install.sh --help` for the supported options.
The package's manifest-sealed `installation.json` identifies it as a full
release with `previous_installation_required: false`.

`--stun` provides UDP 3478 STUN. It does not provide TURN. Allow the documented
web, SIP and audio traffic to reach the server and test your phones and
provider on their actual networks before a cutover.

## An existing PBX

Use the normal **Updates** page to update an existing server while preserving
its users, passwords, reusable QR codes, recordings and call routes. Keep a
verified encrypted backup and its password separately. The updater downloads
the complete signed release, checks compatibility, waits for calls and keeps
its recovery snapshot. A fresh installer refuses to overwrite an existing PBX.

Existing-server compatibility is recorded separately in the
[qualification record](release-1.0.27-qualification.md). Those checks protect
existing data; they are not prerequisites for installing a new server. Do not
change installed-version files, lower signed admission rules or clear updater
trust to skip a refused transition.

## Configure your PBX

- **Voice & Chat:** add providers and numbers. The incoming-number wizard gives
  each number one destination, including Ring Group, Digital Receptionist,
  Extension or a prepared Call Me Back service. [Incoming numbers](trunk-options.md).
- **Users:** add people and connect their phones. Reusable Android QR codes
  contain the tenant address. [Phone setup](../readme.md#connect-android-with-a-qr-code).
- **Outgoing Mail:** configure the installation's outgoing relay before sending
  welcome messages. Tenants use this shared mail configuration.
- **Backup & Restore:** choose an encryption password, keep it separately and
  configure retention. Tenant Admin also provides tenant backup and recovery.
  Off-site storage requires your destination. [Backups](backups.md).
- **Templates** and **Packages & Resources:** publish provider presets and
  extension/call allowances. Capacity requests use quotes and explicit
  approval; payment collection remains external. [Reseller guide](reseller-1.0.25.md).
- **API Keys** and **API Documentation:** create keys with the current account's
  tenant, PBX, department or personal authority. Your installation uses
  `https://YOUR_TENANT_ADDRESS/api/v2`. [API reference](https://openwebpbx.com/api-docs).

The public `openwebpbx.com/api/v2` gateway manages the hosted instance; it does
not select an arbitrary self-hosted machine. Select the actual configured PBX
when creating an integration key. An empty login workspace returns
`409 pbx_not_configured`; it must not be initialized or granted broader access
to hide the wrong selection.

Windows Server and Android retain their independent versions and qualification.
Hosting-provider images also have separate deployment records; this guide
covers the complete Debian archive.
