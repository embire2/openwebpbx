# Debian 1.0.25 — backups and reseller operations

This version adds recovery and resource packages to the PBX and Tenant Admin
workspaces. Public installer versions remain independently qualified; a source
change or hosted deployment does not update an older downloaded installer.

## Administration

- **Backup & Restore:** instance administrators can back up the complete PBX,
  including its database, private configuration, voicemail and recordings.
  Tenant administrators use a separately scoped backup of their tenant's PBX
  services. Download encrypted archives and keep their passwords separately.
- Restore requires a successful backup check, review of the selected workspace,
  and explicit replacement confirmation. Tenant restore cannot replace global
  administrator accounts, app/QR revocations, API keys, resource purchases or
  another tenant's data.
- **PBX Templates:** prepare extensions, default provider connections and outgoing
  rules. Each service receives its own configuration. Provider passwords remain
  encrypted and are not returned in normal API responses. Provider presets
  become tenant-owned connections, including in authorised encrypted backups.
  Use separate provider accounts for customers, or IP authentication on the
  hosting instance.
- **Packages & Resources:** define extension and simultaneous-call allowances,
  assign packages and set prices for extra hosted capacity. Existing PBXs keep
  their service levels until an administrator assigns a package.
- Resource orders have repeat-safe references and an approval record. Approval
  grants the purchased capacity. Payment collection is external; this release
  does not claim to charge a card or collect an invoice automatically.
- Self-hosted installations default to free resource management. Only the
  installation operator can switch hosted billing policy.
- **API Keys:** create named, scoped credentials, choose expiry, see recent use,
  rotate or revoke access. Copy a new secret when it is first displayed; the
  database retains only its hash.

## API

API v1 remains the public registration and onboarding protocol. API v2 adds
administration through explicitly permitted operations, with tenant and PBX
scope checked on every request. Ordinary reads redact private credentials;
credential access requires its own permission.

Use the API Keys page and the API operation catalogue for exact routes and
required scopes. Never put a key in a URL or a phone provisioning QR code.

## Restore boundaries

A whole-instance archive is a recovery artifact for that installation and
matching application version. Tenant archives restore into the same tenant on
the same installation. Moving a tenant to another installation requires a
separately controlled migration; a tenant download does not contain the server's
global encryption key.

Tenant recovery preserves current account ownership, app/QR access and
revocations, callback usage, call history, API access and package allowances. It does not replay pending outbound jobs. The application blocks
tenant calls during the scoped replacement and retains a recovery copy.

## Platform status

The implementation targets Debian 13. Windows remains on its independently
published version; its required ports are tracked in
[the Debian-to-Windows ledger](debian-windows-sync.md).

## Verification and deployment

Hosted App, native Core and updater run1.0.25. The matching native Linux build
uses86 frozen inputs; calling code is unchanged from hosted1.0.24. All 565 outputs
are verified; six version-bearing files differ from the previous native build.
The calling engine stayed running during the native metadata swap.

Verification includes:

- 47 isolated PostgreSQL reseller/package controls,21 native SIP capacity controls,
  214 routing controls and63 callback regression controls.
- 108 PostgreSQL API/admission controls,19 DOM controls and237 OpenAPI schema,
  example and route checks. The API documents140 paths and 75 named PBX actions.
- 54 PostgreSQL/encryption/tenant recovery controls,35 protection authorization
  controls,48 existing backup authorization controls,19 full-backup regressions
  and one actual populated-target restore/interruption-recovery case.
- 39 actual administrator browser/API controls, including both workspaces,
  desktop/mobile layouts, real key creation/rotation/revocation, cross-PBX
  denial and denial of writes using a read key.
- The installed root worker naturally completes create → verify → confirmed
  tenant restore in102.489 seconds on a disposable tenant. Configuration and
  WAV recover; current app credentials, revoked access and used callback minutes
  stay current. Cleanup leaves39 existing customer projections exact.

Binary uploads have a body-free server admission check and their own PHP worker
pool. Ordinary web sign-in and XML requests retain normal form parsing. A
per-request PHP setting initially interfered with new logins; the isolated pool
corrects it. Actual normal POST parsing and all seven International Lighting/
Global desk phones are verified afterwards. Earlier failed QA/deployment
observations remain retained; no new human carrier/audio test is claimed.

The test tenant automatically received a managed address and expanded the shared
certificate. Its local records, vhost, central lease and exact DNS record are
removed; the shared certificate and its original history are retained. All other
22 leases, 20 instances and DNS records are preserved. This is not a claim that
certificate bytes remained unchanged throughout that test.

New hosted services can use **Hosted Starter 1.0.25**: two initial extensions,
a 10-extension/five-simultaneous-call package and provider-free setup. Operators
can add provider presets to private templates. Extra-resource prices start at
zero until the operator configures them; no arbitrary prices or card charges
are introduced. Existing services remain unassigned until deliberately resized.

### Storage on the current hosted instance

The former server's roughly 10 GiB free space correctly prevented a full media
backup while preserving the 10 GiB safety reserve. The new primary stores PBX
data and backups on its 500 GB volume. On 9 November the actual full backup
completes and its authenticated 3.1 GB download matches its checksum. Independent
replacement-test results, media counts, maintenance changes and limitations are
recorded in the [full-media recovery qualification](backup-recovery-2026-11-09.md).
Keep an off-server copy and its password separately; the archive on this data
volume alone cannot protect against loss of that volume.

### Distribution and remaining boundaries

Source and hosted deployment run 1.0.25. No complete or signed 1.0.25 installer has
been qualified or published. Public complete Debian and Windows packages remain
1.0.23; Android remains1.0.19. Windows ports stay in the change ledger. These
checks do not establish complete 3CX parity, aggregate reseller fleet quotas,
automatic payment collection or new physical/carrier/Store acceptance.

The final installer controls include PHP pool validation and rollback, custom
configuration refusal, encrypted-upload directory permissions, proxy byte
preservation and disabled task choices. Ten binary-CSRF controls use the actual
form-token implementation. Actual authenticated browser upload returns202; a
known invalid encrypted fixture is rejected by the root worker without a
restore, its password is cleared and its sole test job/file is removed after
private evidence retention. Four final raw HTTPS probes receive401before
sending any body bytes, in under one second.
