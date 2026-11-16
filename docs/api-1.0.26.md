# Administration and personal API — Debian 1.0.26

Hosted Debian **1.0.26** runs at https://call.openweb.co.za with matching native
Core and updater. The public reference is https://openwebpbx.com/api-docs;
the [OpenAPI specification](https://openwebpbx.com/api-openapi-v2.json) contains
**197 paths and 250 HTTP operations**, including 75 named PBX actions.

Use either `https://openwebpbx.com/api/v2` or
`https://call.openweb.co.za/api/v2`. Self-hosted installations use their own
installation address. Registration, verified email and managed tenant addresses
continue to use API v1; registration tokens are separate from administration keys.

## What is available

### Configured PBX versus workspace

A platform login domain or tenant workspace is not the configured calling
service. Issuing a domain-scoped key for that empty workspace can authenticate,
but configuration reads return **409 pbx_not_configured**. Select the tenant's
actual configured PBX service when issuing a key; do not initialize the platform
domain or broaden permissions to bypass the boundary. This error was previously
misreported as503 and was corrected on12November2026. Unauthorized domains remain403.

For integrations, next-extension returns `data.extension`. Creating a user returns
`data.id` as its extension number/alias; use that alias for `/users/{id}`, not the
extension UUID. Match the required department by display name, then send its stable
`number` in `department` and `departments`. Array indexes/names are not identifiers.
Re-read the department and check `members[].number` when verifying assignment.

Stable QR setup uses `POST /pbx/{domain_uuid}/actions/phone-qr` with
`{"number":"1000"}`. Its `data.payload` is the exact private JSON string to encode
in the QR image; `data.enrollment_uuid` identifies the enrollment and
`data.expires_at` is normally null. Never log/publish the payload or reset another
QR to retrieve it. Set `send_welcome:false` on user creation when your integration
sends its own private welcome.

The12November repair passed117 PostgreSQL administration controls and308 OpenAPI
checks without provisioning customer accounts or restarting native calling.
Both hosts passed103 live HTTP assertions. A separately authorized temporary
OpenWeb SIP-account/QR test passed and was removed, preserving all nine protected
table fingerprints and nine registrations. The website's future paid-Ultra
provisioning is enabled. No test calls, emails, WhatsApps or live payments were made.

Tenant and instance operations cover templates, PBX creation, reseller assignments,
resource packages and approvals, backups and restore, update policies, global mail
and API keys. PBX operations cover extensions, trunks, DIDs and routes, departments,
office hours, ring groups, queues, receptionists, call control, greetings, recordings,
voicemail, Call Me Back, speed dials, hotel services, conferences, app enrollment,
phone migration and health. Existing validated business services remain authoritative.

New `/me` operations let linked end users manage their own availability, queue
membership, calls, voicemail, app profiles, app password, QR setup, contacts,
callback speed dials and conferences. `/staff` operations apply the same live
department roles as My PBX to users, providers, groups, queues, routing schedules,
reports, media and staff delegation. Company and personal contacts now have
explicit validated CRUD; imported contact identifiers remain stable after deletion.

**API Keys** and **API Documentation** are linked from Tenant Admin, PBX
Administration and My PBX. Keys show their secret once and support expiry,
rotation and revocation. Use a separate key for each integration.

## Permission boundaries

- Instance administration requires an instance-wide key and `system:manage`.
  Full backup operations also require the appropriate backup scope.
- Tenant/reseller keys cover their own workspace and explicitly assigned customers.
  PBX keys remain bound to their selected PBX, including keys issued by an instance owner.
- Personal scopes are `me:read`, `me:write`, `me:calls` and `me:credentials`.
  Department scopes are `staff:read`, `staff:write` and `staff:calls`. These cannot
  be mixed with administrator scopes. Optional `keys:manage` delegates only a
  subset within the same boundary and expiry ceiling.
- Personal identity comes from the key owner's current enabled staff assignment
  and extension. Supplied account/domain/extension UUIDs cannot impersonate someone
  else. Department keys remain filtered even when their issuer has broader authority.
- Every request rechecks account, role, extension, tenant availability, key ancestry,
  revocation, expiry and boundary. Withdrawing a role withdraws existing keys.
- QR reading stays stable. Reset requires its explicit endpoint, credentials and
  write scopes, and confirmation. App password changes preserve desk-phone SIP passwords.

Use HTTPS and bearer headers. Browser Origin calls and query tokens are refused.
The API has rate limits, safe errors, secret/path filtering and explicit destructive
confirmations. No arbitrary SQL or switch commands are exposed. A queued command
is not a completed call, delivered email, installed update or completed restore.

## Verification and deployment

The final software checks pass: 169 PostgreSQL personal/department API controls,
112 administration API controls, 142 staff-role controls, 65 Core controls,
48 mobile-state controls, 19 key-form DOM controls, 305 OpenAPI contracts and
12 installer integration tests. Fixtures shadow all customer tables in their own
schema; no real phone is called by these checks.

Actual trusted HTTPS checks exercise both API addresses: administrative reads,
PBX narrowing, personal writes, foreign identity/scope/Origin refusals and rejection
of unauthenticated claimed 100 MiB backup uploads before receiving a body.
Normal browser checks cover both administration panels, the personal key form,
CSRF key creation, denied PBX administration and the searchable reference at mobile
and desktop widths. Four further HTTPS checks prove that previously working
personal keys stop working after a normal staff-role withdrawal.

An unmanaged disposable PBX and account are removed after testing. Legacy fixture
rows needed a separate scoped cleanup because their tables do not all cascade
from domain deletion; the first cleanup mismatch remains recorded. All nine
protected customer configuration table digests then match the pre-test reference.
Test audit history is retained. No DNS registration, customer call or email is
created by the fixture.

Before deployment, an encrypted database/configuration checkpoint is created and
verified; it excludes media and was not restored. The first manual native overlay
inherited private compiler file modes and failed Core readiness. It rolled back
to healthy 1.0.25. Normalizing only the new published runtime and checking access
as the service account produces a distinct successful retry in 4.038 seconds.
The regular bundle builder already normalizes these modes. The failed attempt
and rollback remain evidence, rather than being relabelled successful.

Hosted App/Core/updater are 1.0.26. All eight existing desk-phone registrations
remain present; FreeSWITCH is not restarted. This does not establish a new human
audio, carrier or physical-phone qualification. Switchtel's earlier provider-path
exception remains separate.

The complete Debian 1.0.26 bundle is assembled separately from the hosted overlay.
The local archive is **487,819,513 bytes**, SHA-256
`a94907d7efd85f2871fd5140ad01d8e90ca422783fc155eec67683a09644cf2d`.
Ordinary updater manifest validation accepts all **12,251 files**; the new API,
backup progress script, Debian worker integration, native versions and runtime
read permissions are checked. The offline pack verifies all 4,915 spoken files.
Application source is frozen at commit `5eb801d4d`; later catalogue/documentation
commits do not change that code. A first inventory verifier mistakenly expected
`install-reseller.sh`; the bundle correctly contains `install-reseller.py`. The
corrected verifier passes without changing the archive; both results are retained.
Public qualified downloads and signed feeds remain Debian 1.0.23, Windows 1.0.23
and Android 1.0.19 until the new installer completes its own qualification.
Windows catch-up is explicit in the [platform ledger](debian-windows-sync.md).
This API release does not claim complete 3CX feature parity or automatic payments.

Root-private evidence pointer: `/var/lib/openwebpbx/active-api126-path.txt`.
Private archives, keys, credentials, browser logs and raw evidence must not be published.
