# Tenant administration API

The hosted tenant API is available at
`https://call.openweb.co.za/api/v2`, with its own searchable reference at
[call.openweb.co.za/api-docs](https://call.openweb.co.za/api-docs).
The page also downloads an OpenAPI document using the installation's configured
API address. Documentation does not require an API key or expose customer data.

## Create a tenant administrator key

1. Sign in and choose **API Keys** from Tenant Admin, PBX Admin or the desktop.
2. Choose the tenant to manage and select **Full tenant administration**.
3. Leave **PBX service** as **All services in the selected tenant**. Give the key
   a name and expiry, then create it. Save its secret immediately: it appears
   only in that creation response.
4. Send `Authorization: Bearer YOUR_API_KEY` to the API. Read `GET /services`
   and use the selected service's `domain_uuid` in `/pbx/{domain_uuid}/...`.

That key covers the selected tenant's existing and future CloudPBXs. Choosing
one PBX instead restricts it to that service and prevents tenant-wide service
creation or template administration. The platform login workspace is not a
configured PBX: its configuration endpoints return `409 pbx_not_configured`.
Select the configured service; do not initialise or overwrite the workspace.

The preset selects these nine permissions:

| Scope | Access |
| --- | --- |
| `pbx:read` | Users, trunks, routing, reports and operational status |
| `pbx:write` | PBX users, providers, numbers, routing and supported settings |
| `calls:control` | Authorised call and queue controls |
| `credentials:read` | Explicit private phone setup and QR reads |
| `backups:read` | Permitted backup listings and downloads |
| `backups:write` | Create, verify and explicitly restore permitted backups |
| `templates:read` | Tenant services, available templates and approved packages |
| `templates:write` | Tenant templates and new services within approved allowances |
| `keys:manage` | Same-boundary key delegation, replacement and revocation |

It excludes `system:manage`, `reseller:manage` and personal/staff scopes. Global
SMTP, instance backups, server settings and unrelated tenants are outside this
profile. A tenant key does not become an instance key because its owner is an
instance administrator. PBX-only administrators cannot use the preset to create
a tenant-wide key.

Every request retains the existing live account, role, tenant, PBX and ownership
checks. Hostnames are addresses, not permission grants. Revoked roles, disabled
users and suspended tenants are refused on the next request. Delegated keys
inherit their parent's exact boundary, may contain only a subset of its scopes
and cannot outlive it; parent rotation or revocation withdraws descendants.
Existing API keys, phone passwords and reusable QR identities are unchanged.

## Reference and scope

The local reference contains **123 paths / 153 operations**, derived from the
implemented administration API's contract. It covers tenant services/templates,
PBX configuration, users, providers, DID routing, queues, greetings, Call Me Back,
phone health, conferences, tenant backups and scoped key management. The complete
public reference retains its separate instance, reseller and personal/staff
operations. Local documentation excludes those operations; it does not remove
them from the separately authorised API.

Regenerate the bundled local contract after an administration-contract change:

```sh
python3 tests/export_tenant_openapi.py
python3 tests/tenant_api_reference.py
```

The page makes no authenticated API requests and stores no credentials. Search
works locally. It supports keyboard navigation, narrow screens and an OpenAPI
download for client generation. Use server-to-server HTTPS requests; the
administration API continues to reject browser `Origin` headers. Its normal
rate, payload, job-confirmation and resource limits remain in force.

## Verification on 18 November 2026

- **26** actual PostgreSQL controls in an isolated schema cover multiple current
  services, a service added after key creation, foreign tenants, moved/disabled
  services, full-tenant versus PBX-only administrators, delegation, suspension,
  revocation and role withdrawal. No customer rows or calls are changed.
- **117** existing PostgreSQL API controls, **29** selector/preset DOM controls,
  **334** local-reference controls and **308** original OpenAPI controls pass.
- Actual hosted HTTPS serves the local page, assets and OpenAPI. A real browser
  checks desktop/mobile layout and search. Normal administrator login and UI key
  creation produce a nine-scope tenant-wide key; its own service/configuration
  reads succeed and instance/foreign-PBX reads refuse. A subsequent GET no
  longer displays its secret. Normal UI revocation makes the key return403.

The temporary test key remains revoked for audit. Its secret, browser state,
raw responses and operation evidence remain private. The first browser launch
found no Chrome distribution; the existing Chromium runtime is used instead.
A test-only row-name assumption and a selector-fixture expectation are retained
as distinct failed observations, corrected without changing product authority.

This is a hosted PHP/UI/reference update. It does not change native Core26,
immutable public Debian27, Windows packages, Android19 or signed feeds, and it is
not evidence of physical-phone, carrier, Store or complete3CX feature parity.
