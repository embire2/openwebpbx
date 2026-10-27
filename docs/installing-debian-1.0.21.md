# Install OpenWeb PBX 1.0.21 on Debian 13

**Complete Windows and Debian server1.0.21 release**. Use **Debian 13 amd64** for this complete server package. Setup installs the local
PostgreSQL database, calling engine, web administration, background workers,
backups and updater. Each installation supports multiple tenants; tenants do
not configure separate databases. Android remains **1.0.19** and the Windows
server has its own package and source archive.

Download `openwebpbx-1.0.21-debian13-amd64.tar.gz`, this guide and `SHA256SUMS`
from the same [release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.21).
Verify the archive's SHA256 against `SHA256SUMS` before extracting the complete
archive into an empty private directory:

```sh
sha256sum openwebpbx-1.0.21-debian13-amd64.tar.gz
tar -xzf openwebpbx-1.0.21-debian13-amd64.tar.gz
cd openwebpbx-1.0.21-debian13-amd64
```

## Set up a new server

Use a clean Debian 13 computer. Apply Debian's security updates, including the
current PHP-FPM and CLI packages. Point your PBX hostname at the server and
prepare a trusted certificate and private key for that hostname. Run as root:

```sh
./install.sh --domain pbx.example.com --address YOUR_SERVER_IP --email admin@example.com \
  --certificate /path/to/fullchain.pem --certificate-key /path/to/privkey.pem
```

Enter the administrator password when prompted. For an isolated local trial,
replace the certificate arguments with `--local-certificate`. A local test
certificate does not make remote Android enrollment ready. Fresh setup refuses
an existing PBX configuration or database; use the updater for an installed PBX.

Keep PostgreSQL and the engine-control interface local. Allow the documented
web, phone and audio ports through the server firewall and any upstream router.
Public tenant-address registration needs trusted HTTPS, DNS and certificate
readiness; setup does not configure the upstream router or act as a TURN relay.

Sign in at the server's HTTPS address. Fresh setup creates Main PBX with
**100 Reception** and **101 Office**. Add people under **Users**, connect two
phones and prove ringing and two-way audio before adding a provider. No provider
is enabled automatically. Add the provider under **Voice & Chat**, open its
**Incoming Calls** page, add a DID and choose its destination. The number can
also continue directly into Call Me Back setup. Test incoming and outgoing
routes before moving live numbers.

Set outgoing mail once for the installation. Verify receipt of a controlled
welcome email before inviting users. On a ready server, connect Android 1.0.19
by its single-use QR code, setup file, or registered tenant address, extension
and app password. Updating the app over its existing installation preserves
saved accounts. Desk-phone settings are separate.

## Greetings and company hours

Use **Greetings** to call an extension or outside number, record, press **#**,
replay and save. Name and reuse recordings for voicemail, receptionists and
queues; existing custom recordings are retained. Text narration needs a
configured ElevenLabs account with Keoma access. Provider usage and charges
apply; OpenWebPBX adds no generation fee. Built-in speech uses Keoma, including
own voicemail on **121** and the GMT+2 talking clock on **1026**.

Administrators can create, edit or remove company office hours from its group.
Each extension can optionally choose separate In Office and Out of Office
destinations. Review holidays, breaks and temporary overrides before changing
an existing route.

## Upgrade an existing server

An original **1.0.16** updater first needs the signed revision2 feed-compatibility
bootstrap. It separates server updates from the Android feed. Download
`openwebpbx-1.0.18-debian16-feed-compat-r2.tar.gz` and `SHA256SUMS-r2` from the
[1.0.18 release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.18).
The archive is 102,260 bytes, SHA256
`12e8a0fff65444badbdf965d15022b88302c73a103b90d4051b5456804a651e8`.
Verify the downloaded archive against the checksum above and `SHA256SUMS-r2`, then extract it into a private directory and enter its own folder:

```sh
sha256sum openwebpbx-1.0.18-debian16-feed-compat-r2.tar.gz
tar -xzf openwebpbx-1.0.18-debian16-feed-compat-r2.tar.gz
cd openwebpbx-1.0.18-debian16-feed-compat-r2
```

Run its preflight and then apply as root:

```sh
python3 split-android-feed.py
python3 split-android-feed.py --apply
```

Preflight checks the signature and exact supported files. Applying saves a
recovery copy and restarts only the independent updater. Calling services and
phone settings stay in place. Stop if either command refuses. Servers older
than 1.0.16 need their documented intermediate upgrade first. The public21 feed
minimum does not make an unpatched original 16 updater directly compatible.

After the compatibility bootstrap, open **Admin → System → Updates** and choose
the update. The updater verifies the complete signed download, waits for active
calls and retains a private recovery snapshot before migration. Follow your
configured maintenance policy; unattended installation can restart services.
Keep backup passwords, provider credentials, private keys and database settings
private. Never run the fresh installer over an existing PBX.

## Backup and replacement

Create and verify an encrypted instance backup before changing an installed
server. To prepare a clean Debian replacement, add `--restore-server` to the
fresh install command and use the original public hostname. Install the same
release as the backup. The target keeps its own local database credentials and
certificate. Review the restore result and activate calling, jobs and other
held services through their separate controls.

Debian and Windows instance-backup formats are platform-specific. The supported
3CX V20 configuration importer is a separate migration path. Review its Restore
Report and test real phones and providers before handover.

## Before moving live numbers

Verify trusted HTTPS, the intended phone registrations, internal and provider
calls, hold/resume, voicemail and mail delivery. Check Phone Health, tenant/Android
setup and any browser meetings you use. Restore a verified encrypted backup to
a separate target before relying on it. Plan an operating-system restart and
repeat service, web and calling checks in your deployment window.

The release's software qualification does not establish every physical phone,
camera, carrier, NAT arrangement, OS reboot or existing meeting invitation.
See the [release scope](https://github.com/embire2/openwebpbx/blob/customization/docs/release-1.0.21-qualification.md),
[backup guide](https://github.com/embire2/openwebpbx/blob/customization/docs/backups.md)
and [feature coverage](https://github.com/embire2/openwebpbx/blob/customization/docs/feature-coverage.md).

For source builds, use the Debian [`debian-v1.0.21`](https://github.com/embire2/openwebpbx/tree/debian-v1.0.21) snapshot, the [Debian application source](https://github.com/embire2/openwebpbx/releases/download/v1.0.21/openwebpbx-1.0.21-debian-source.tar.gz) and [Debian engine source](https://github.com/embire2/openwebpbx/releases/download/v1.0.21/openwebpbx-1.0.21-debian13-engine-source.tar.gz). The separate `v1.0.21` snapshot belongs to the Windows package.
