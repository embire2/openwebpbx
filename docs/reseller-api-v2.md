# PBX and reseller API v2 — Debian 1.0.25

Manage the installed PBX at `https://<installation-host>/api/v2`. The hosted installation uses `https://call.openweb.co.za/api/v2`. Tenant registration, email verification, managed subdomains and self-install authority continue to use the existing `/api/v1` API. Existing v1 tokens do not grant v2 administration access.

Create a key in **API Keys**, available from the PBX and Tenant Admin. Choose the tenant, optional individual PBX, permissions and expiry. The full value appears once. Store it in your integration's secret store; send `Authorization: Bearer <key>`. API-created delegated keys inherit their parent’s expiry ceiling and revocation chain. Revoking or rotating a parent also withdraws its descendants. Rotation replaces the secret immediately and preserves its expiry; revocation takes effect on the next request. Keys do not change phone passwords or QR codes.

Every request checks the current account, current role, tenant suspension, PBX ownership, expiry, revocation and key permissions. A tenant-wide key covers its own services. A service key covers only that PBX. A key restricted by an instance administrator stays restricted. A reseller portfolio key additionally needs `reseller:manage`, an owned parent tenant and a currently assigned child tenant; removing that assignment withdraws access. An ordinary PBX administrator can create a service key for their own PBX, without gaining tenant or instance administration.

Use HTTPS and server-to-server requests. Browser Origin requests, Basic authentication, URL/query tokens, arbitrary SQL and arbitrary switch commands are refused. Each key permits 120 requests per minute, with `429` and `Retry-After: 60` on excess requests. JSON bodies are limited to 128 KiB. The API returns a request identifier and safe errors; it does not return server traces or database credentials.

## Start with a read request

```sh
curl --fail-with-body \
  -H "Authorization: Bearer $OPENWEBPBX_API_KEY" \
  https://call.openweb.co.za/api/v2/services
```

Tenant suspension/enabling and pending invitation renewal use `/tenants/{id}/enabled` and `/tenants/{id}/invitation`, with current instance or assigned-reseller authority.

All ordinary replies have `data` and `request_id`. Collection responses are intentionally scoped; they do not enumerate other customers. `GET /` returns the supported operation catalogue and this key's scope. Save the `domain_uuid` of your PBX from `/services` for the examples below. Service-only keys already have their domain UUID in `GET /` and use `/pbx/{domain_uuid}/...` directly.

```sh
curl --fail-with-body \
  -H "Authorization: Bearer $OPENWEBPBX_API_KEY" \
  "https://call.openweb.co.za/api/v2/pbx/$DOMAIN_UUID/actions/next-extension"
```

## Features and endpoint families

Download [the complete OpenAPI document](../website/public/api-openapi-v2.json). The document is generated from the implemented operation catalogue by `php tests/export_reseller_openapi.php`; it contains each named operation and required scope.

| Area | Endpoints and behaviour |
|---|---|
| Users, trunks, companies, office hours, queues, ring groups, receptionists, outgoing rules, DIDs and scripts | `/pbx/{domain_uuid}/{resource}` and `/{id}`. GET reads; POST creates supported resources or edits the specified item. DELETE is supported for users, queues, ring groups, receptionists and outgoing rules, with `confirm_delete: true`. Trunks and DIDs can be switched off without deleting their identities. Scripts and office hours edit existing imported/configured objects. |
| Single DID routing editor | POST `actions/did-editor` with `id` (or `new`) and optional `trunk`; use its `revision` and destination choices in the next POST to `/dids/{id}` or `/dids`. This preserves stale-edit protection and the one-route-per-number policy. `actions/trunk-incoming` shows effective destinations; `actions/trunk-options` returns the advanced connection options and `options_revision` value for `actions/trunk-options-save`; `actions/add-trunk-number` uses the existing number wizard. |
| Calls and routing | `actions/live`, `call-control`, `agent`, `call-plan`, `route-preview`, `first-calls`, `test-call`, `record-call-check`, `provider-check` and `queue-rules`. Read previews do not originate calls. Call-control and test-call require `calls:control`. |
| Recordings and voicemail | `actions/media?category=recordings&page=0`, `category=voicemails` or `category=prompts`; GET `/audio/{media_uuid}` streams an authorised file. List replies do not expose server file paths. |
| Greetings | `greetings`, `greeting-create`, `greeting-rename`, `greeting-action`, `greeting-assign`, `greeting-unassign`, `greeting-uses`; GET `/greeting-audio/{greeting_uuid}` streams the recording. Phone and Keoma text recording use the same validation and jobs as the dashboard. |
| Call Me Back | `call-me-back` and `call-me-back-action`, including callback-only trunk selection, accounts, authentication bindings, scripts/reset and nine speed-dial slots. |
| Hotel, queues and callbacks | `jobs`, `job-action`, `hotel`, `hotel-action`, `queue-report`. Jobs can be retried or cancelled only in states allowed by the existing calling service. |
| Conferences | `meetings`, `meeting-create`, `meeting-invite`, `meeting-email`, `meeting-cancel`, `meeting-host`, `meeting-status`, `meeting-control`. Invitation and host operations return deliberate connection secrets; host requires `credentials:read`. |
| Staff and phone recovery | `staff`, `staff-grant`, `staff-renew`, `staff-revoke`, `hours-override`, `phone-health`, `phone-alerts`, `phone-recover`. Department and tenant ownership remain enforced. |
| Desk-phone migration | `phone-migration`, `migration-inspect`, `migration-prepare`, `migration-record`, `migration-limitation`, `migration-export`. Configuration export needs `credentials:read`; tests recorded by administrators are not treated as automatic physical-phone proof. |
| App provisioning | `phone-devices`, `phone-qr`, `phone-qr-reset`, `phone-device-revoke`, `phone-password`, `welcome-email`. QR reading is stable; only the explicit reset endpoint replaces enrollment, and requires both `credentials:read` and `pbx:write` plus `confirmed: true`. Credential operations need `credentials:read`. Welcome email is queued, not asserted delivered. |
| SIP addresses | `sip-domains`, `sip-domain-save`, `sip-domain-disable`. |
| Plans and resources | `/plans`, `/plans/assign`, `/plans/assign-tenant`, `/plans/ceiling`, `/orders/{id}/approve` or `/cancel`; PBX actions `resource-usage`, `resource-orders`, `resource-order`. Prices use integer cents and a three-letter currency. Hosted resource orders are quotations/manual billing approvals, not automatic payment collection. Self-hosted installations do not incur a hosted resource charge. |
| Templates and tenants | `/templates`, `/templates/{id}`, `/services`, `/tenants`. Resellers manage explicitly assigned customers; only an instance administrator can delegate reseller rights through `/resellers`. The existing public v1 starter templates remain provider-free. Private v2 templates accept encrypted trunk defaults. Passwords are write-only in template reads. |
| Guided setup and 3CX import | `/setup/options`, `/setup/review`, `/setup/draft`, `/setup/create`, `/setup/import-review`, `/setup/import-preview`, `/setup/import-create`. Setup drafts and destination tenants retain their normal owner checks. |
| Tenant backups | GET/POST `/tenants/{tenant_uuid}/backups`; POST `/{backup_uuid}/verify` or `/restore`; GET `/{backup_uuid}/download`. Restore requires a successful verification, exact tenant confirmation and `confirm_replace: true`. |
| Full-instance backups | `/instance/backups`, `/instance/backups/{id}/verify`, `/restore`, `/download`, `/instance/backup-settings`, `/instance/protection`. Instance-wide keys require both `system:manage` and the relevant backup scope. |
| Updates and mail | Instance-only `/instance/updates`, `/instance/update-policy`, `/instance/android-minimum`, `/instance/mail`, `/instance/mail-check`, `/instance/reseller-policy`. Tenant update policy uses `/tenants/{id}/update-policy`. Existing platform-specific updater behaviour is retained. |
| Key management | `/keys`, DELETE `/keys/{id}`, POST `/keys/{id}/rotate`. Requires `keys:manage`. An API key can delegate only its own permissions, tenant and PBX boundary, with no later expiry than its parent. Only the calling key itself and its delegated descendants can be listed, rotated or revoked through the API. Ancestors, siblings and independent dashboard-created keys are hidden, even if their tenant and permissions match. |

Named actions use `/pbx/{domain_uuid}/actions/{name}`. Their HTTP verb and permissions appear in the OpenAPI document and `GET /` catalogue. POST bodies use the dashboard's validated business fields, including explicit `id`, `number`, `trunk`, `action` and confirmation fields where relevant. These are forms/commands rather than unrestricted JSON merge patches: send the complete settings you intend to save. Public configuration reads are safe projections, not a private backup or an unredacted round-trip document.

## Packages and resource orders

POST `/plans` with `plan_name`, `extension_limit`, `concurrent_calls`, `extension_price_cents`, `call_price_cents`, `currency` and `enabled`. Only a currently authorised reseller manager can change or assign packages. POST `/plans/assign` with `domain_uuid` and `plan_uuid`, or `/plans/assign-tenant` with `tenant_uuid` and `plan_uuid`. Existing installations receive no new limit until a package is assigned.

POST a PBX `resource-order` with positive `extra_extensions` and/or `extra_calls`, plus a unique `idempotency_key`. A repeat request with the same key returns the same order. The server quotes its own saved prices; clients cannot supply the price or approve their own hosted upgrade. After the reseller has completed their billing process, an authorised approval grants the extra capacity once. A payment gateway or automatic collection is not configured by this release.

## Backup import and restore

Backups contain private customer data. Use a separately stored password of 12–256 UTF-8 bytes. Tenant archives restore into their original installation and tenant scope; they do not copy global administrators, API keys, other tenants or billing entitlements. Full-instance archives cover the entire server and must be treated as highly privileged recovery material.

Import an encrypted archive using POST `/tenants/{tenant_uuid}/backups/import` or `/instance/backups/import`, `Content-Type: application/octet-stream`, the exact `Content-Length` (up to 2 GiB) and `X-Backup-Password` containing the base64-encoded UTF-8 backup password. The key and permission are checked before reading the stream; the service checks the free-space reserve while storing it. Do not put the password in the URL. The upload becomes a queued verification/import job; only a validated archive becomes downloadable/restorable.

Create, verify, poll status, then request restore with `password`, `confirm_replace: true` and `confirm_tenant` equal to the exact tenant name, or `confirm_server` equal to the installation hostname for instance recovery. Verification is valid for 30 minutes and for that same archive and scope. Restore is queued and status reports success or failure; an HTTP 200 means the request was accepted, not that a destructive restore has completed. Perform instance recovery during a maintenance window and follow the returned activation/recovery instructions.

WAV and desk-phone configuration uploads use multipart `file` at their named upload operations. API multipart uploads, including 3CX import review, are bounded to 32 MiB; WAV additionally has the existing 25 MiB limit. Larger 3CX backup imports use the dashboard's dedicated import workflow. Native phone and app login/SIP protocols remain separate from this administration API.

## Errors and retries

`400` means invalid input, `401` a missing key, `403` refused scope/account access, `404` unavailable resource, `409` conflicting state or capacity, `429` rate limiting and `503` temporary service failure. Error bodies include `request_id`. Do not blindly retry commands that dial, send invitations or change settings after a lost response. Resource orders and provisioning have explicit idempotency keys; queued backup/update commands coalesce as documented by their service.

Windows parity must be qualified separately. This document describes the Debian 1.0.25 implementation and does not advance the public Windows release.

## A reseller's first customer: exact request sequence

The following UUIDs, company details, prices and credentials are examples only. They do not configure the hosted installation. Replace them with returned identifiers and your own commercial rates. Request bodies and typed responses are included in the OpenAPI download.

1. The instance administrator uses their instance key to POST `/resellers` with `{"user_uuid":"11111111-1111-4111-8111-111111111111","enabled":true}` for an existing active tenant owner. The administrator assigns that reseller's wholesale package using `/plans/assign-tenant`. The reseller creates a tenant-wide key with `reseller:manage`, `templates:read`, `templates:write`, `pbx:read`, `pbx:write` and the backup permissions they need. A reseller cannot raise their own wholesale ceiling.
2. The reseller POSTs `/plans` to create a customer package within that allowance:

```json
{
  "plan_name": "Business 20",
  "extension_limit": 20,
  "concurrent_calls": 5,
  "extension_price_cents": 2500,
  "call_price_cents": 5000,
  "currency": "ZAR",
  "enabled": true
}
```

The response's `data.plan_uuid` identifies the package. These example rates mean an extra extension costs ZAR 25.00 per month and an extra simultaneous call costs ZAR 50.00 per month. They are not OpenWebPBX prices.

3. POST `/tenants` with `tenant_name`, `slug`, `email` and optional `service_limit`:

```json
{
  "tenant_name": "Example Lighting",
  "slug": "example-lighting",
  "email": "admin@example.com",
  "service_limit": 3
}
```

The response is `{"data":{"invitation_url":"/app/tenant_services/accept.php?invite=..."},"request_id":"..."}`. Deliver that private invitation to the customer using your normal secure onboarding process. It is not a public registration token. The customer accepts it and chooses their portal password. GET `/tenants` to obtain the customer `tenant_uuid`; provisioning requires an accepted, enabled tenant. Email verification and managed-domain authority follow the existing onboarding/API v1 process.

4. POST `/plans/assign-tenant` with that `tenant_uuid` and the returned `plan_uuid`. This sets the approved default for future services. Existing PBX services are assigned separately with `/plans/assign` and their `domain_uuid`.
5. POST `/templates` to create a private published template. This is a small working example; provider credentials remain blank until supplied for the customer's service:

```json
{
  "template_name": "Business 20 with voice provider",
  "published": true,
  "resource_plan_uuid": "33333333-3333-4333-8333-333333333333",
  "config": {
    "timezone": "Africa/Johannesburg",
    "extension_start": 1000,
    "extension_count": 3,
    "extension_limit": 20,
    "concurrent_calls": 5,
    "trunks": [
      {
        "name": "Primary provider",
        "proxy": "sip.provider.example",
        "username": "",
        "password": "",
        "transport": "udp",
        "register": true,
        "enabled": false
      }
    ],
    "rules": [
      {"name":"Outside calls","pattern":"^([0-9]{7,15})$","trunk":0,"prefix":""}
    ]
  }
}
```

Save `data.template_uuid`. Template trunk passwords are encrypted; reads do not reveal them. The approved package is authoritative if it differs from editable template defaults. Omit `api_enabled` for reseller templates: that flag belongs to the provider-free public v1 starter catalogue.

6. POST `/services` with the accepted customer's ID, template and a stable request UUID:

```json
{
  "tenant_uuid": "22222222-2222-4222-8222-222222222222",
  "template_uuid": "44444444-4444-4444-8444-444444444444",
  "service_name": "Main office",
  "slug": "main-office",
  "request_uuid": "88888888-8888-4888-8888-888888888888",
  "credentials": [
    {"username":"provider-account-example","password":"example-only-replace-with-provider-password"}
  ]
}
```

The response contains `data.service_uuid`. Repeat the same request UUID after a lost response to retrieve the existing result. GET `/services` for its domain UUID and address. Complete the managed address registration/readiness flow before connecting clients. A template explicitly marked `enabled: false` keeps its provider off even when credentials are supplied; review it and connect it through the provider setup workflow. Providers needing credentials also stay off when credentials are missing.

7. Route DIDs using POST `/pbx/{domain_uuid}/actions/did-editor` with `{"id":"new","trunk":"<trunk-id>"}`. The reply contains the current `revision`, provider choices and destinations. Send that revision, number and selected destination to POST `/pbx/{domain_uuid}/dids`. This uses the same single routing editor as the dashboard, including Ring Group, Digital Receptionist, Extension and Call Me Back destinations. Office hours can be edited through `/office-hours/{department-id}`; `{"hours_action":"delete"}` removes the configured hours through the normal validated operation.
8. When the customer needs more capacity, POST `/pbx/{domain_uuid}/actions/resource-order`:

```json
{"extra_extensions":5,"extra_calls":2,"idempotency_key":"billing-order-20261106-0001"}
```

The reply includes `order_uuid`, `status: "pending"`, `monthly_amount_cents` and `currency`. The server calculates the quotation from the assigned package. With the example rates, this order is 22500 cents (ZAR 225.00) per month. Complete your billing process, then POST `{}` to `/orders/{order_uuid}/approve`. Repeating an already successful approval does not add capacity twice. GET `actions/resource-usage` to confirm the resulting allowance. A customer key cannot approve its own wholesale increase, supply its own price or bypass the operator's ceiling.

For tenant recovery, POST `/tenants/{tenant_uuid}/backups` with `{"password":"example-only-backup-passphrase"}`. Poll the same GET collection for completion, retain the encrypted download separately, verify with the same password, then use the typed restore request only after reviewing its scope. Full-instance backup uses POST `{}` to `/instance/backups` after the instance administrator has saved `passphrase`, `include_media`, `schedule_hour` and `retention` at `/instance/backup-settings`. Full-instance recovery revokes machine API keys to prevent old keys being resurrected; re-create integrations after recovery.
