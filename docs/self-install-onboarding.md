# Self-installed PBX registration

The public setup page is **https://openwebpbx.com/wizard**. The central service
authorizes an installation running on its owner's server; it does not create a
second PBX on OpenWeb's hosted installation. The normal hosted-service API is
still available separately.

This document describes the current source integration. Published server
1.0.21 archives remain unchanged. Complete current installer qualification and
the Webhotel image rebuild/upload are still required before distributing a new
server package or advertising a newly updated provider image.

## Setup experience

1. Install the current qualified package/image and choose the initial local
   administrator email and password. The updated installer source chooses a
   managed server identity automatically when expert hostname options are absent.
2. Open the setup link printed by the installer or shown in the Windows manager.
   Alternatively, open `/wizard` and enter the short-lived setup code.
3. Create an OpenWeb account, confirm the emailed code and choose the business
   address, for example `example.openwebpbx.com`. Existing account owners sign in
   and confirm their current email if necessary.
4. Leave the server running. It proves ownership, obtains its canonical DNS and
   trusted certificate, installs the signed authorization, and prepares the
   tenant address and its certificate automatically.
5. **Open my PBX** appears only after a fresh HTTPS ownership/readiness check.
   Sign in using the local administrator account chosen during installation.
   The tenant portal is at its assigned address and administration is `/admin`.

The owner password and owner bearer from the public wizard never enter the
image. DNS provider credentials remain on the central custodian. The local
administrator password and the OpenWeb registration account are separate.

For additional local PBX services, Tenant Services offers **Register or review
this PBX address**. Its owner can use the local HTTPS setup page at
`/app/pbx_onboarding/` to register or sign in, verify email and request the next
tenant address. Account tokens used by that local flow are encrypted at rest.

## Registration and calling rules

Fresh installations require both a valid, pinned RSA3072 authorization and an
enabled tenant address with a current, actually installed HTTPS certificate.
The authorization binds the account, installation key, local tenant, PBX
domain, canonical hostname, chosen label, generation and expiry.

The native background workers, SIP directory, provider configuration, call
routes and mobile enrollment check registration before new calling work. The
Lua gate also matches the database receipt against the root-verified SHA256
snapshot. A database-ready flag alone cannot enable calling. Repair, backups,
updates and registration stay available. Active calls are not terminated.

The durable fresh-install requirement lives outside instance-backup roots:

| Platform | Marker |
|---|---|
| Debian | `/etc/openwebpbx-installation/onboarding-required` |
| Windows | `%ProgramData%/OpenWebPBX-Installation/onboarding-required` |

Restoring an older database/configuration does not remove that requirement.
Existing installations retain their original compatibility policy; this source
change does not disable their registered phones. Valid cached authorizations
remain usable during transient registration-network failures. Renewal runs
before expiry and preserves a still-valid working registration while retrying.
As with other open-source software, a root operator can modify their own source;
these are supported-runtime enforcement rules, not a claim of tamper-proof DRM.

## Installer and scheduler integration

The shared root/SYSTEM bridge is `packaging/debian/onboarding.py` with privileged
PHP IPC in `onboarding.php`. The Debian and Windows package maps include the
same portable consumer and pinned public authority key. The private authority
signing key is never packaged.

| Platform | Scheduled registration |
|---|---|
| Debian | `openwebpbx-onboarding.timer`, one minute after a completed check |
| Windows | `OpenWebPBX-Onboarding`, at startup and every minute |

The worker and image consumer have separate maintenance and session locks.
Certificate setup takes the ordinary maintenance lock independently. Restore
holds and existing disabled scheduler choices are preserved. Only a bounded,
unexpired setup URL/code is exposed through the Windows manager health response.

The canonical hostname is `node-<installation UUID without hyphens>.openwebpbx.com`.
It stays stable through activation: existing SIP realms, credentials and phone
settings are not renamed. Debian configures sufficient Nginx hostname-hash
capacity before adding tenant virtual hosts. Windows prepares a separate,
restricted static HTTP ownership-proof site; it exposes no administration files.
Public HTTP80 and HTTPS443 must reach the server for proof and ACME issuance.

The public protocol is documented in [the tenant API guide](tenant-api.md) and
[the Webhotel integration guide](webhotel-onboarding.md). The companion contract
is [wizard-openapi.json](https://openwebpbx.com/wizard-openapi.json).

## Accepted checks and remaining release work

Accepted component checks include 228 actual registry PostgreSQL/HTTP controls,
79 native/background-worker controls, 132 privileged-worker controls, 78 local
wizard database/crypto and 16 HTTP controls, 76 image API and 37 dispatcher HTTP
controls, 59 portable-consumer controls, seven actual IPv4/TLS controls, 61 tenant
alias boundaries, 23 Lua activation controls and ten native Nginx/configuration
controls. The original tenant API's 103 database and 153 HTTP controls remain
accepted. Browser checks cover the public and local wizard at mobile/desktop
sizes, privacy/storage behavior and actual public CORS/CSP.

A disposable public protocol run completes real HTTP ownership proof,
custodial A/CNAME changes, canonical and tenant Let's Encrypt issuance, signed
authorization and fresh tenant HTTPS readiness. Its verification message was
intercepted privately for the test; this does not claim new inbox delivery.
The owned test account, DNS, proofs, virtual host and certificate were removed;
the disabled custodian ownership reservation remains. Customer-table projections
and all seven expected working desk-phone registrations were preserved.

Still required for a new distributable: complete Debian/Windows installer and
upgrade/restore qualification with this integration; actual native Windows
IIS/ACL/task/manager acceptance; provider image generalization, rebuild and
publication; and a real newly deployed Webhotel image check. A generalized image
must create fresh database/installation/key identities at first boot and must
never contain customer data, administrator passwords, saved pairing credentials
or an existing activation. No provider image upload is claimed without the
provider's actual image access and identifiers.
