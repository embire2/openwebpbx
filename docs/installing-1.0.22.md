# Install OpenWeb PBX 1.0.22 on Debian 13

Version 1.0.22 adds registered self-install onboarding and the Webhotel Debian 13
image. Use this guide with the matching signed Debian1.0.22 release package.
Windows Server remains on its separately qualified1.0.21 package; Android remains
1.0.19. See the release qualification report for the accepted scope and limits.

## Webhotel installation

Choose **OpenWebPBX — Debian 13** in **Create Instance**. Enter the company and
administrator details, verify the account email and choose an available
`company.openwebpbx.com` address. Availability is checked centrally; the selected
address is reserved for this deployment before provisioning starts.

The image installs the complete PBX with local PostgreSQL, creates fresh instance
identities, proves control of the allocated public address and obtains a signed
tenant registration and trusted certificate. Calls remain unavailable until that
registration completes. The provider's account credentials never enter the guest.

After setup, the instance page permanently shows the PBX address, administrator
username and initial password to its owner and explicitly authorised credential
viewers. Passwords are encrypted in provider storage. Changing the password inside
the PBX does not update the provider's saved initial password.

## Install on your own Debian 13 server

Use a clean Debian 13 amd64 server and the matching complete release archive.
Verify its published checksum and signature, then follow the commands in the
archive's README. Keep the installation directory private. Do not run a fresh
installer over an existing PBX.

Download `openwebpbx-1.0.22-debian13-amd64.tar.gz` and `SHA256SUMS` from the
same release. Verify the archive before extracting it. As root, in an empty
private directory:

```sh
sha256sum openwebpbx-1.0.22-debian13-amd64.tar.gz
tar -xzf openwebpbx-1.0.22-debian13-amd64.tar.gz
cd openwebpbx-1.0.22-debian13-amd64
./install.sh --bootstrap-registration --address YOUR_PUBLIC_IP --email admin@example.com --stun
```

The installer prompts for the initial local administrator password. It creates
a unique managed server hostname and prints a setup link and code. You do not
need to choose a separate hostname, manage DNS or obtain a certificate yourself.
`--stun` enables the included UDP3478 STUN binding service on the supplied local
public address; it is not a TURN relay. A firewall or router must forward the
documented web, SIP and audio ports to this instance. A dedicated, reachable
public address is required for ownership verification and certificate issuance.

Open the setup address shown by the installer and follow the account, email
verification, company and tenant-address steps at
[the onboarding wizard](https://openwebpbx.com/wizard). The server needs its own
reachable public address and the documented web, SIP, STUN and audio ports. A
registered `*.openwebpbx.com` tenant address is required before calling can start.

## Existing instances, backup and recovery

Use the signed Debian updater for an existing supported installation. Existing
registered phones, providers, routes and company settings must be preserved.
The fresh-install onboarding requirement does not reconfigure an existing
customer deployment.

The 1.0.22 signed feed requires **1.0.21 or newer**. Older installations need a
separately validated migration path; this release does not qualify a direct
1.0.16-to-1.0.22 upgrade. The retained [1.0.21 instructions](installing-debian-1.0.21.md)
describe that historical release, rather than a current intermediate-upgrade
recipe using the latest feed. Do not bypass the minimum-version check or run
the fresh installer over an installed server.
Make a verified encrypted backup first and allow the normal updater to finish;
it waits for active calls, saves a recovery snapshot and restarts services as
part of installation. Keep the server running throughout the transaction.

Encrypted Debian backups include the source instance's protected registration
identity and onboarding session. Restore onto a clean Debian installation of the
same release, following [the backup guide](backups.md). Stop the source before
bringing up its replacement at the same registered public address. Moving a
registered instance to another public address requires a separate authorised
address change; a backup restore does not transfer a provider IP allocation.

See [Webhotel onboarding](webhotel-onboarding.md) for API contracts, cancellation,
ownership and deployment requirements. Physical handset and carrier acceptance
remain deployment-specific; software fixture tests are not handset tests.
