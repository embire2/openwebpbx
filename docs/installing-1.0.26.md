# Install OpenWeb PBX 1.0.26 on Debian 13

This guide accompanies the complete Debian 1.0.26 bundle. Its
[qualification and publication record](release-1.0.26-qualification.md) states
which fresh-install, signed-upgrade and recovery checks have actually passed.
Use the package and signed offer published together for your platform.


Version 1.0.26 includes encrypted PBX and tenant backup/recovery, reseller
workspaces, templates with provider presets, extension and simultaneous-call
allowances, and administration/personal API 2.1. Core and updater versions match
the server. PostgreSQL, calling, administration and offline Keoma prompts stay
on your own machine. Windows Server and Android retain their independent
versions. [Feature scope](api-1.0.26.md) · [Windows catch-up](debian-windows-sync.md).

## New server

Use a clean **Debian 13 amd64** server with a reachable public address. Download
`openwebpbx-1.0.26-debian13-amd64.tar.gz` and `SHA256SUMS` from the same
[Debian release](https://github.com/embire2/openwebpbx/releases/tag/debian-v1.0.26).
The matching canonical download is under `v1.0.26`; source and platform tag refer
to the same frozen Debian build. Compare the archive's SHA-256 with the published
checksum before extracting it into an empty, private directory. A fresh
installer must not be run over an existing PBX.

As root:

```sh
sha256sum openwebpbx-1.0.26-debian13-amd64.tar.gz
tar -xzf openwebpbx-1.0.26-debian13-amd64.tar.gz
cd openwebpbx-1.0.26-debian13-amd64
./install.sh --bootstrap-registration --address YOUR_PUBLIC_IP --email admin@example.com --stun
```

Choose the local administrator password when prompted. Follow the printed setup
link to the [registration wizard](https://openwebpbx.com/wizard), verify your
OpenWeb account, enter the company details and select an available
`company.openwebpbx.com` address. The OpenWeb account and local PBX administrator
are separate sign-ins. Calling starts after registration, managed DNS and
trusted HTTPS preparation complete.

`--stun` provides UDP 3478 STUN, not TURN. Allow the documented web, SIP and audio
traffic to reach the instance. In **Create my PBX**, prepare the service, add two
users and connect their phones before moving a live provider or number.

## Existing server

The signed 1.0.26 offer requires **installed Debian 1.0.22 or newer**. Use the
published platform offer and its qualification record. Earlier servers need
their supported intermediate release first; never lower a minimum or clear
saved updater trust to skip a transition.


Keep a verified encrypted backup and its password separately. Use the normal
server updater, which verifies the complete signed download, waits for active
calls, saves its recovery snapshot and restarts the services. Do not interrupt
installation. A failed transaction uses its ordinary recovery journal and backup;
do not delete those files to force another update.

Extension numbers, separate phone authentication IDs and password bytes,
reusable QR identities, custom recordings, routes and service allowances must
remain intact. Use the release's qualification record for the exact accepted
scope. Real phones, providers and network conditions still need your own call
checks before a production cutover.

## First administration steps

Open **Voice & Chat** to add the provider and its incoming numbers. The DID
wizard gives each number one incoming destination, including Call Me Back, and
can keep a separate closed-hours route. Existing provider and onward call rules
remain authoritative. [Incoming numbers](trunk-options.md) ·
[Callback scripts and speed dials](call-me-back-1.0.24.md).

In **Backup & Restore**, choose an encryption password, keep it separately and
schedule instance backups with your retention choice. Tenant Admin also provides
tenant backup and recovery. Configure **Outgoing Mail** before sending welcome
messages. Off-site storage requires your own destination.

Tenant Admin provides **Templates** and **Packages & Resources** for provider
presets and extension/call allowances. Existing PBXs keep their service levels
until a package is assigned. Resource requests use quotes and explicit approval;
payment collection remains external. [Reseller guide](reseller-1.0.25.md).

## API access

After setup, Tenant Admin and PBX Administration link to **API Keys** and
**API Documentation**; My PBX also exposes the permitted personal controls.
The installation API uses `https://YOUR_HOST/api/v2`. The public
`openwebpbx.com/api/v2` gateway manages the hosted instance; it does not select
an arbitrary self-hosted machine.

Issue keys for the account's actual configured tenant/PBX service. An empty
platform workspace returns `409 pbx_not_configured`; do not initialize it or
broaden a key to work around the error. Personal access requires an enabled
Staff Access assignment linked to the extension. Department keys retain current
role and ownership boundaries on every request. [API reference](https://openwebpbx.com/api-docs).

Webhotel image publication is separate from this installer release. A newly
published archive does not update or qualify hosting-provider images automatically.
