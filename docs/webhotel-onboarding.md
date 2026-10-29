# Webhotel.cloud and Debian image onboarding

## Current rollout status — 29 October 2026

The provider integration now runs in Webhotel: Create Instance collects company
details, verifies the owner's email, checks the requested tenant address live and
reserves it before provisioning. The authenticated instance view permanently
shows the initial local PBX address and credentials to its owner or an explicitly
permitted credential viewer. They are encrypted in provider storage; provider
root and registration-account secrets are separate.

The complete Debian **1.0.22** package is published, and its read-only template
media is rebuilt. The [qualification record](release-1.0.22-qualification.md)
distinguishes package acceptance from each hosting node. Eight healthy nodes are
eligible; a location becomes available only after its installation, registration,
calling, backup and reboot checks. Other nodes remain held for storage health,
memory or customer-IP availability.
All224 usable addresses in the sixteen existing OVH blocks have vMACs; no extra
IP purchase or customer-address reassignment is part of this rollout.

Public Windows Server1.0.21 and Android1.0.19 retain their original packages and
update-feed bytes. Earlier protocol-only and source-only records below retain
their original scope; they do not describe later package or fleet acceptance.

## Pairing protocol

OpenWeb PBX supplies a first-boot pairing API, a browser wizard at
`https://openwebpbx.com/wizard`, and a portable image consumer with installed
Debian/Windows bridge adapters. The PBX and its data
stay on the installed server. This flow does **not** create another PBX service
on OpenWeb's hosted installation.

The machine-readable companion contract is
[`website/public/wizard-openapi.json`](../website/public/wizard-openapi.json),
served as `/wizard-openapi.json`. Its version identifies this API contract and
does not change a published server release.

The central API and public wizard are deployed. A controlled public test passed
ten end-to-end checks: owner confirmation (the verification mail was intercepted
privately for the test), IPv4 device pairing, owner claim, signed public HTTP
bootstrap, real custodian A record, canonical Let's Encrypt HTTPS, fresh HTTPS
challenge and RSA3072 authorization, signed tenant CNAME lease, expanded tenant
certificate and exact tenant HTTPS completion/browser readiness. Cleanup removed
only the test account, two owned DNS records, proofs, temporary virtual host and
test certificate; the disabled ownership tombstone remains reserved. Evidence:
`/var/lib/openwebpbx/selfinstall-onboarding-inrzsxty/public-pairing/`.
This proves the central public protocol. It does not establish inbox delivery,
a clean native Windows/Debian installer run or a published Webhotel provider
image. Published server1.0.21 archives remain unchanged.

## User experience

1. Install the qualified OpenWeb PBX Debian image and open its console or setup
   details. Follow the displayed setup link, or enter its code at `/wizard`.
2. Create an OpenWeb account and confirm the emailed code, or sign in to an
   existing account. An invited owner must also confirm the current email.
3. Choose a business name such as `example.openwebpbx.com`, confirm that the
   displayed server is theirs, and accept the terms.
4. Keep the server running. The image proves its ownership, receives its
   canonical server address, obtains HTTPS, installs its signed authorization
   and requests its tenant address through the normal custodian worker.
5. The browser offers **Open my PBX** only after the actual tenant HTTPS
   connection has passed a fresh ownership check. Sign in with the administrator
   account chosen during the local PBX installation.

Neither the owner password nor owner API bearer is sent to the image. The user
does not enter a DNS provider key, custom hostname or certificate. Existing SIP
phones and hosted customer configuration are outside this first-boot flow.

## Provider integration

Initial provider research used the official [Webhotel documentation](https://www.webhotel.cloud/docs)
and [Webhotel OpenAPI document](https://webhotel.cloud/openapi.json), retrieved
2026-10-29. The documented service-template endpoints describe saved blueprints;
`POST /api/compute/order` includes provider-image, region, chosen user/password
and SSH-key fields. That document does not expose a guaranteed `userData` or
cloud-init hook for a Debian image. Do not assume a metadata hostname already
has trusted HTTPS or that an undocumented guest-metadata service exists.

The implemented integration uses a clean Debian13 template, read-only complete
installer media and an owned first-boot worker, with the opt-in marker below.
Webhotel binds the deployment to its service, generation and allocated IP, then
reads the non-secret setup link from the owned guest through its guest agent.
Company details, email verification and reservations are handled outside the
guest. Provider access was supplied later in the rollout; template/media uploads
and package qualification are now tracked separately in the release report.

## Image preparation

Use a newly installed, supported Debian 13 instance with its own database,
local tenant/domain UUIDs, root-owned P256 identity and a canonical host in the
form `node-<new-v4-uuid-without-hyphens>.openwebpbx.com`. The installed helper
returns that same bootstrap UUID. Never distribute a live customer's database,
private instance key, saved session, signed activation, administrator password,
SSH host keys or ACME private material as a template. Image generalization must
create new local identities at first boot using the installer-owned procedure.

Install these source-controlled leaves through the normal package mapping:

| Source | Installed destination |
|---|---|
| `packaging/debian/webhotel-onboarding.py` | `/opt/openwebpbx/tools/webhotel-onboarding.py` |
| `packaging/debian/openwebpbx-image-onboarding.service` | `/etc/systemd/system/openwebpbx-image-onboarding.service` |
| `packaging/debian/openwebpbx-image-onboarding.timer` | `/etc/systemd/system/openwebpbx-image-onboarding.timer` |

The installed root-only `/opt/openwebpbx/tools/onboarding.py` must implement:

| Operation | Input | Result / responsibility |
|---|---|---|
| `--image-init` | None | Return `local_tenant_uuid`, `domain_uuid`, `bootstrap_uuid`, `key_path`, base64 SPKI `public_key`, `proof_root`, `image_version`; refuse another customer's identity or a non-image setup. Remain safe to query after this image stores its own authorization. |
| `--image-bind` | `{"server_host":"node-…openwebpbx.com"}` on stdin | Accept only the already-installed canonical hostname; obtain/activate its trusted certificate idempotently. Do not rename existing tenant domains or phone credentials. |
| `--image-store` | `{"activation":{…}}` on stdin | Independently validate the pinned RSA signature, issuer/audience, expiry, generation and local bindings, then atomically persist/queue normal onboarding. Repeated identical input is idempotent. |
| `--image-status` | None | Return `ready`, the actual assigned `hostname`, and optional `url`; readiness requires the trusted, enabled tenant lease. |
| `--image-display` | `user_code`, `verification_uri_complete`, `pairing_uuid`, `expires_at` | Publish only these non-secret setup details to the installer-controlled manager snapshot. Idempotent; never accept a device credential. |
| `--image-sign` | `{"message":"…"}` | Windows: validate the installed private key ACL and return its base64 DER P256 signature. Never accept an arbitrary key path. |
| `--image-proof` | `{"nonce":"…","body":"…"}` | Windows: atomically publish the bounded proof in the fixed IIS-served proof root, using installer-defined ACLs. Never accept an arbitrary destination. |

The root-owned key is `/etc/fusionpbx/tenant-domains-instance-key.pem`.
The existing proof root is
`/var/lib/openwebpbx/tenant-domains/proofs/.well-known/openwebpbx-instance`.
Its existing root:www-data directories must permit Nginx traversal; proof leaves
are atomically written root:www-data `0640`. The canonical HTTP80 and HTTPS443
virtual hosts and generated tenant HTTPS hosts must serve this exact well-known
path before dot-file denial. Keep the existing rate/TLS/body protections.

For a deliberately generalized image, enable only this owned feature:

```sh
install -d -m 0755 /etc/openwebpbx
install -m 0600 /dev/null /etc/openwebpbx/image-onboarding-enabled
systemctl daemon-reload
systemctl enable --now openwebpbx-image-onboarding.timer
journalctl -u openwebpbx-image-onboarding.service --no-pager -n 20
```

The service retries one bounded cycle 30 seconds after each completed cycle and
honours API retry delays. Its root-only session and setup-link file live under
the helper's validated `private_root/image-onboarding/` (legacy Debian default
`/var/lib/openwebpbx/image-onboarding/`); a file lock prevents overlapping cycles.
Only the short-lived user code is printed to the console. No owner credentials
are accepted or stored by this worker. Proofs use the actual P256 private key;
HTTPS uses the platform trust store, with redirects and environment proxies
disabled. The worker renews an active device authorization before expiry using
a fresh signed proof. It never stops current calls or modifies phone settings.

The same source uses an elevated Windows guard and `msvcrt` lock adapter on
Windows. Its session files inherit the installed helper's validated
SYSTEM/Administrators-only private directory; reparse points and hardlinks are
refused. Windows signing/proof publication goes through the bridge above rather
than an OpenSSL executable. The native Windows scheduled task invokes the
installed helper, which delegates a single consumer cycle. Root entry points
are `main(argv=None)` or `run_once(provider='debian', metadata=None)`; `metadata`, when
supplied, must be the actual freshly validated `--image-init` result. Do not let
an unprivileged web request provide it. The scheduler must use `run_once`, which
owns the lock and retry schedule; `Agent.cycle` is the internal test step.
The fixed authority transport uses IPv4 consistently with installer IP proofs,
while retaining normal TLS hostname/CA validation and SNI. This does not change
SIP, the operating-system resolver or other applications. Native Windows ACL, task, first-boot and
ACME acceptance still require actual Windows qualification; portable bridge
tests alone do not establish that pass.

## Dedicated API routes

### Verified checkout before the VM exists (API1.1)

Webhotel collects company details and verifies the owner's OpenWeb account before
charging or creating a VM. It uses these additional JSON operations:

| Method / route | Caller | Purpose |
|---|---|---|
| `POST /subdomains/availability` | Any | Coarse **global** name/DNS check with `{label}`; this is not a reservation. |
| `POST /reservations` | Verified owner bearer | Reserve `{label,request_uuid}` before checkout; return the exact reservation and cleanup control. |
| `POST /reservations/renew` | Original owner bearer | Renew `{reservation_uuid}` during provisioning. |
| `POST /reservations/release` | Original owner bearer | Cancel a never-bound reservation. |
| `POST /servers/revoke` | Scoped secret control | Confirm exact server/DNS cleanup before a provider releases its IP. |

`POST /reservations` returns `reservation_uuid`, `label`, `hostname`, `state`,
UTC `expires_at` and secret `control_token` (`owpc_` plus64hex digits). Identical
account/request/label retries recover the same control. Store it encrypted in
the provider backend. It is never a guest credential or a browser-facing field.
There are at most three pending reservations per verified account; initial
expiry is60minutes and queued renewals are bounded by24hours. Checkout and its
financial idempotency remain the provider's responsibility.

Once the fresh image publishes its setup code, the provider checks the actual
observed server address and adds `reservation_uuid` to the ordinary `/claim`
request. This binds the reserved label to that exact account, P256 key, local
tenant/domain and bootstrap UUID. The later signed lease consumes the reservation
atomically. Another installation cannot take the held name; a foreign DNS record
causes a conflict instead of silently changing a reserved customer's name.

Cleanup accepts `{reservation_uuid,control_token,expected_server_address}` with
optional `expected_server_host` and `expected_key_hash`. It does not require an
unexpired owner bearer. Its positive response is exactly
`{cleanup_confirmed:true,state:"revoked",scope:"instance"}` for a registered
server; `reservation_only` and `bound_without_dns` are possible only when the
custodian confirms no other active bootstrap ownership at that address.
Revocation disables calling authority before removing the exact owned CNAME
and canonical A/AAAA records, verifies deletion, and retains ownership tombstones.
Foreign records or uncertain network results retain the checkpoint and return
an error. The provider must keep VM/IP resources reserved until confirmation.
It must never substitute direct cPanel deletion or interpret a timeout as success.

The guest receives only local initial administrator credentials/company details
through protected first-boot input. The owner bearer and cleanup control remain
on Webhotel. The provider may persistently show the **local PBX** GUI URL, user
and initial password in its authenticated owner/explicitly authorised credential
view, as requested by the project owner; these values stay encrypted at rest,
out of logs/email and out of other owners' caches.

Base: `https://call.openweb.co.za/api/v1/wizard`.
All POST bodies are JSON objects, at most 16 KiB. TLS and canonical host are
required. Browser cookie sessions grant no authority. Only exact browser Origin
`https://openwebpbx.com` receives CORS permission, without credentialed cookies;
images omit Origin. The original hosted `/api/v1` Origin refusal is unchanged.

| Method / route | Caller | Purpose |
|---|---|---|
| `GET /health` | Any | Availability and supported providers |
| `POST /account/register` | Browser | Queue email-verified registration; no hosted service creation |
| `POST /account/verify` | Browser | Verify emailed code and original password; return owner bearer |
| `POST /account/login` | Browser | Sign in to an active owner account |
| `POST /account/email/request` | Owner bearer | Request confirmation of an existing owner's current email |
| `POST /account/email/verify` | Owner bearer | Confirm that email using its code and current password |
| `POST /devices` | Image | Start with provider/version/public P256/local IDs; optional installed `bootstrap_uuid` |
| `POST /devices/lookup` | Browser | Read limited server details using `user_code` |
| `POST /claim` | Owner bearer | Bind code to this verified owner and immutable chosen label |
| `POST /devices/poll` | Device credential | Read only this image's progress, proof material and signed grant |
| `POST /devices/bootstrap` | Device credential + P256 signature | Prove public HTTP80 ownership and obtain canonical DNS |
| `POST /devices/challenge` | Device credential | Request a fresh canonical trusted-HTTPS proof |
| `POST /devices/authorize` | Device credential + P256 signature | Obtain RSA-signed installation authorization |
| `POST /devices/complete` | Device credential + P256 signature | Prove the actual tenant HTTPS address is ready |
| `GET /sessions/{pairing_uuid}` | Original owner bearer | Browser-safe progress and final connection URL |

`POST /devices` accepts `provider` (`webhotel` or `debian`), `image_version`,
`public_key` (base64 SPKI DER, P256), `local_tenant_uuid`, `domain_uuid`, and
optional v4 `bootstrap_uuid`. The observed public TCP peer address is used;
body fields or forwarded headers cannot select another target address. It
returns `pairing_uuid`, private `device_code`, display `user_code`,
`verification_uri`, `verification_uri_complete`, `expires_at` and
`poll_interval:5`. The completed link uses a URL fragment, not a server query.

`POST /claim` requires `user_code`, `label`, `confirm_server:true` and
`accept_terms:true`. A repeated same-owner/same-label claim is idempotent;
another owner or label is refused. It receives no private device secret.

Image operations use `device_code` in the JSON body. `authorize` additionally
takes the exact returned `challenge_uuid` and `signature`; `complete` takes the
actual assigned `hostname` and `signature`. Neither browser status nor public
lookup returns a device secret, owner bearer, challenge or activation envelope.
Errors are redacted `{error:{code,message},request_id}` with `no-store`.

User codes contain 40 random bits and expire after 30 minutes. Root device
credentials contain 256 random bits and are hashed at rest. Anonymous starts,
lookups, owner claims, device operations and existing account operations have
independent limits. A completed unexpired grant permits renewal with the device
credential and a fresh private-key proof. If an unfinished same-image setup
expires, a fresh code rotates the old secrets while retaining any claimed owner,
chosen label and immutable DNS binding. Cross-key/local-ID/address reuse is
refused. A suspended owner cannot continue using a device session.

## Exact proof bytes

Every value below is its canonical ASCII form. UUIDs are lowercase dashed UUIDs.
The signature is ECDSA P256 SHA256 over UTF-8 bytes, returned as base64 DER.
Every listed message ends with a final newline. Do not sign JSON serialization.

Bootstrap signature:

```text
openwebpbx-bootstrap-v1
{nonce}
{serverAddress}
{keyHash}
{bootstrapUuid}
{accountTenantUuid}
{localTenantUuid}
{domainUuid}
{label}
```

The public HTTP80 proof at
`/.well-known/openwebpbx-instance/{nonce}` is:

```text
openwebpbx-bootstrap-v1
{nonce}
{keyHash}
{serverAddress}
```

Only the fixed internal custodian endpoint receives these values. It verifies
the P256 signature and nonce proof before creating
`node-{bootstrapUuidWithoutHyphens}.openwebpbx.com`. The proof destination is
pinned to the validated public IP, with no redirects or private-network targets.
The local image then obtains trusted HTTPS on this already-installed canonical
hostname; no administrator-chosen certificate is needed first.

The normal authority challenge supplies its own nonce and exact HTTPS proof
body. The P256 signature for that challenge is:

```text
openwebpbx-installation-v1
{nonce}
{canonicalServerHost}
{keyHash}
{accountTenantUuid}
{localTenantUuid}
{domainUuid}
{label}
```

Completion signature:

```text
openwebpbx-complete-v1
{completeNonce}
{keyHash}
{canonicalServerHost}
{actualTenantHostname}
{domainUuid}
```

For completion, publish the normal HTTPS proof body using that same fresh
completion nonce. The custodian must verify actual tenant TLS, proof bytes and
the exact enabled hostname/server/key/domain ownership tuple before `ready:true`.
An allocated DNS name or valid RSA authorization alone is insufficient.

## Deployment and verification

Apply `app/tenant_api/resources/wizard.sql` **after** the tenant API installation
and `onboarding.sql` migrations. Deploy `api/wizard/index.php` and
`resources/classes/pbx_wizard_api.php`. Route the more specific
`/api/v1/wizard/` prefix to that controller before the original API front
controller. Preserve the existing original API Origin guard.

On the public static website, publish `wizard.html`, `assets/wizard.css`,
`assets/wizard.js` and `wizard-openapi.json`, and map `/wizard` and `/wizard/`
to `wizard.html`. Permit only `https://call.openweb.co.za` in this page's
`connect-src`; retain `connect-src 'none'` on existing static/legal pages.
No remote third-party script, analytics or iframe is required. Tokens and
passwords remain in memory; optional appearance persistence uses the existing
privacy-choice controls.

Run the isolated source checks:

```sh
php tests/webhotel_wizard_api.php
python3 -I -B tests/webhotel_wizard_http.py
python3 -I -B tests/webhotel_image_onboarding.py
python3 -I -B tests/webhotel_transport.py
```

The PostgreSQL test exercises actual P256 signatures and RSA receipts while
explicitly isolating network proof/DNS. The independent HTTP test runs the exact
dispatcher against a disposable PostgreSQL cluster. The image-consumer check
uses actual POSIX protected files and OpenSSL signatures plus portable Windows
sign/proof/private-path bridge contracts, with helper/HTTP boundaries explicitly
mocked. Browser QA covers registration/confirmation/claim/progress,
mobile and desktop layouts, storage choices and unsafe ready-address refusal
with isolated API responses. These isolated source checks do not themselves establish provider publication, inbox delivery, public DNS/ACME, physical calling or a native Windows image pass. The separate controlled public protocol acceptance above records its actual DNS/ACME scope.

The hosted authority explicitly enables provider reservation/cleanup routes with
`openweb.provider_onboarding_enabled = true`. Other installations default to a
503 preparation response for those provider routes. This switch does not disable
the existing owner wizard, installation registration or hosted tenant API.
