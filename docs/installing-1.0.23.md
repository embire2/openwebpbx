# Install OpenWeb PBX 1.0.23 on Debian 13

Release 1.0.23 adds one guided editor for incoming numbers, clearer external
forwarding and Call Me Back destinations, explicit local/international number
matching and protection against disabled numbers falling through to another
route. PostgreSQL, calling and administration remain on your server.

Use the matching complete archive and published checksums. The
[qualification record](release-1.0.23-qualification.md) distinguishes completed
checks from pending release checks. Android remains 1.0.19.

## New server

Use a clean Debian 13 amd64 server with a reachable public address. Download
`openwebpbx-1.0.23-debian13-amd64.tar.gz` and `SHA256SUMS` from the same
[release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.23). Compare
the downloaded archive's SHA-256 with the published checksum before extracting
it into an empty, private directory. Do not run a fresh installer over an
existing PBX.

As root:

```sh
sha256sum openwebpbx-1.0.23-debian13-amd64.tar.gz
tar -xzf openwebpbx-1.0.23-debian13-amd64.tar.gz
cd openwebpbx-1.0.23-debian13-amd64
./install.sh --bootstrap-registration --address YOUR_PUBLIC_IP --email admin@example.com --stun
```

Choose the local administrator password when prompted. Open the setup link
printed by the installer and follow the [registration wizard](https://openwebpbx.com/wizard)
to verify your OpenWeb account, provide company details and select an available
`company.openwebpbx.com` address. The OpenWeb account and local administrator
are separate sign-ins. Calling starts after ordinary registration, DNS and
trusted HTTPS preparation complete.

`--stun` enables the included UDP 3478 STUN service. It is not a TURN relay.
Allow the [documented web, SIP and audio traffic](installing-1.0.22.md#install-on-your-own-debian-13-server)
to reach this server. Complete **Create my PBX**, add two users and test their
phones before moving a provider connection or live number.

## Existing server

The 1.0.23 signed offer is scoped to **Debian 1.0.22 or newer**. Make a verified
encrypted backup and keep its password separately. Use the ordinary updater;
it waits for calls to finish, saves its recovery snapshot and restarts the
services. Do not interrupt the server during installation.

Older servers need their separately supported transition first. The archived
[1.0.22 instructions](installing-1.0.22.md) describe that release's qualified
minimum; they do not authorize bypassing the latest offer's minimum version.

Accounts, phone authentication IDs/passwords, reusable QR codes, recordings and
company routes must be preserved. A fresh installer is not an upgrade path.
The [release record](release-1.0.23-qualification.md) states the exact tested
scope and remaining deployment-specific checks.

## Set up incoming numbers

Open **Voice & Chat**, select the provider, then choose **Add number** or edit
an existing number through its displayed destination. The same wizard owns the
number, destination and optional closed-hours route. Choose an extension, ring
group, digital receptionist, external number or Call Me Back.

For South African numbers, select **South Africa (+27)** once in the number
format choice so local and international forms select the same saved route.
Other PBXs can retain their current setting or use exact matching. The system
does not guess a country from the server's address. Call Me Back setup keeps
an existing destination until the service is ready; a new unfinished number
stays off. [Routing guide](trunk-options.md).

Configure **Outgoing Mail** before emailing invitations. Test actual incoming
and outgoing calls with your provider and desk phones before a cutover.
Webhotel's image availability is recorded separately; publishing this installer
does not update or qualify a provider image automatically.
