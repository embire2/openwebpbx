# Tenant API v1

Public reference: **https://openwebpbx.com/api-docs**. Download the matching
[OpenAPI 3.1 document](tenant-api.openapi.json) or its
[public copy](https://openwebpbx.com/api-openapi.json).

This hosted API is a separately deployed update. The original published
1.0.21 archives remain unchanged. A self-hosted instance needs a build
containing the tenant API and its operator must enable it before use.

The hosted API registers an organisation, verifies its administrator's email,
and creates isolated PBX services on OpenWeb's shared server. Each service has
its own domain, extensions, call routes and managed `*.openwebpbx.com` address.
“Tenant server” means a PBX service in this shared installation; the API does
not create a separate virtual machine or operating-system installation.

## Address and request format

The hosted base address is:

```text
https://call.openweb.co.za/api/v1
```

Requests and responses use JSON. Send `Content-Type: application/json` for a
JSON request body and `Accept: application/json`. Use HTTPS with normal
certificate verification. Do not use `curl -k` or send secrets through URLs.

The portable front-controller form is also available:

```text
https://call.openweb.co.za/api/v1/index.php?route=/templates
```

Keep the same HTTP method and JSON body when using that form. The public
website contains documentation; API requests go to the PBX base address.

All examples use fictional details. Substitute your own email, password,
identifiers and subdomain. Never put production passwords or tokens in a
public issue, source repository or browser storage.

## 1. Register and verify email

```sh
curl --request POST 'https://call.openweb.co.za/api/v1/registrations' \
  --header 'Content-Type: application/json' \
  --data '{
    "tenant_name": "Example Company",
    "slug": "example-company",
    "email": "owner@example.com",
    "password": "replace-with-a-long-unique-password-42",
    "accept_terms": true
  }'
```

The password must be between **12 and 72 UTF-8 bytes**, including a letter
and a number. Your client must show the
[terms](https://openwebpbx.com/terms) and
[privacy policy](https://openwebpbx.com/privacy) before accepting registration.
`accept_terms` must be the JSON boolean `true`.

A valid registration receives **202 Accepted** with
`status: "verification_required"`. This is deliberately generic; it does not
disclose whether an email already has an account. It also does not prove that
the verification email reached the recipient's inbox.

The global outgoing-mail service sends a **30-minute verification code**.
Submit that code and your original registration password in a POST body.
Opening an email or following a link alone
does not activate a tenant.

```sh
curl --request POST 'https://call.openweb.co.za/api/v1/registrations/verify' \
  --header 'Content-Type: application/json' \
  --data '{"token":"VERIFICATION_CODE_FROM_YOUR_EMAIL","password":"YOUR_ORIGINAL_REGISTRATION_PASSWORD"}'
```

Successful verification returns **201 Created** with `tenant`,
`access_token`, `token_type: "Bearer"`, `expires_at` and token metadata.
Store the access token securely; later list/detail responses do not return
its secret. The code is single-use and expires after 30 minutes. Submitting a
new registration request for a still-pending email replaces its old code;
use the newest message and the password submitted with that request.

## 2. Authenticate

An existing verified tenant owner can obtain another token:

```sh
curl --request POST 'https://call.openweb.co.za/api/v1/auth/token' \
  --header 'Content-Type: application/json' \
  --data '{"email":"owner@example.com","password":"YOUR_ACCOUNT_PASSWORD"}'
```

Use the returned token as an HTTP header on protected operations:

```sh
curl 'https://call.openweb.co.za/api/v1/me' \
  --header "Authorization: Bearer $OPENWEB_TOKEN"
```

Browser login cookies do not authenticate this API. Tokens are restricted to
the tenant owner and are checked against the current owner/account/tenant
status. Disabled or suspended accounts cannot continue provisioning. Token
secrets are stored as hashes by the server. Keep a separate token per
integration and revoke it when that integration is removed.

Change the owner's account password with `POST /me/password`:

```sh
curl --request POST 'https://call.openweb.co.za/api/v1/me/password' \
  --header "Authorization: Bearer $OPENWEB_TOKEN" \
  --header 'Content-Type: application/json' \
  --data '{"current_password":"YOUR_CURRENT_ACCOUNT_PASSWORD","new_password":"replace-with-a-new-unique-password-73"}'
```

The new password must meet the 12–72-byte letter-and-number requirement.
Success returns HTTP **200** with a replacement access token and metadata.
**All previous owner API keys are revoked**, including the key making this
request. Store the replacement before making another call and update your
integrations. A wrong current password returns **401 current_password_invalid**.
This changes the administrator's account password, not SIP, extension or
phone-app passwords.

## 3. Select a template and create a PBX

```sh
curl 'https://call.openweb.co.za/api/v1/templates' \
  --header "Authorization: Bearer $OPENWEB_TOKEN"
```

The response's `templates` array lists the current published starter
templates visible to your tenant, including their IDs, revision, timezone
and extension range/limits. It never returns provider passwords or template
encryption data. Only shared published starter templates explicitly approved
by the instance administrator are available. They must have no trunks,
outbound rules or additional settings. Configure your own provider
after creating the PBX; existing private administrator templates are unaffected.
If the list is empty, ask the instance administrator to publish an approved
starter template using the checkbox described below.

Create a service using one of the returned template IDs and a new UUID in
`Idempotency-Key`:

```sh
curl --request POST 'https://call.openweb.co.za/api/v1/services' \
  --header "Authorization: Bearer $OPENWEB_TOKEN" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: 9b484c7d-4e6f-48b2-b9fd-c55260d8b563' \
  --data '{
    "template_uuid": "TEMPLATE_UUID_FROM_THE_LIST",
    "service_name": "Main Office",
    "slug": "main-office",
    "subdomain": "example-company"
  }'
```

`subdomain` is a single label, without `https://`, a dot, a port or a path.
When omitted, the tenant slug is used. Reserved names and names owned by a
different customer cannot be taken over. The API creates the PBX and records
its requested address atomically before the background worker sees it.

The **201 Created** response contains the service and its subdomain status.
Service fields include `service_uuid`, `tenant_uuid`, `domain_uuid`,
`service_name`, `template_uuid`, `template_name`, `template_version`,
`sip_domain`, `software_version` and `created_at`.

Provisioning uses the current installed application files and the selected
template's current revision. Later template edits do not rewrite an existing
service. A service does not download an uninstalled future server release.

## 4. Wait for the tenant address

DNS and HTTPS preparation are asynchronous. Poll the service's subdomain
resource until its response indicates that the address is ready:

```sh
curl 'https://call.openweb.co.za/api/v1/services/SERVICE_UUID/subdomain' \
  --header "Authorization: Bearer $OPENWEB_TOKEN"
```

The installed worker uses the signed central domain-ownership protocol; API
clients never receive cPanel credentials, instance signing keys or wildcard
certificate keys. An availability check is advisory, not a reservation.
Use the assigned hostname and returned connection addresses rather than
constructing an address from an unchecked label. Do not treat a pending DNS
record as proof of a ready HTTPS portal.

The API can also register the address for an existing owned service with
`POST /services/{service_uuid}/subdomain` and a new UUID `Idempotency-Key`.
Pending or leased addresses cannot be silently renamed. Domain registration
does not replace the SIP domain or existing desk-phone authentication.

Once ready, use the tenant's HTTPS portal and `/admin` administration address.
Configure a provider, assign real telephone numbers and test calling before
moving live traffic. The API does not allocate a carrier DID or activate a
provider's paid connection automatically. Android account QR codes and app
passwords remain managed through the tenant's normal Users workflow; API
access tokens are not phone passwords.

## Endpoint reference

Health, registration, verification and sign-in are public. For every other
operation, send `Authorization: Bearer TOKEN`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Read safe public API/version and registration-enabled metadata; no token needed. |
| POST | `/registrations` | Request a verified tenant account. |
| POST | `/registrations/verify` | Redeem the email code and receive tenant/token details. |
| POST | `/auth/token` | Sign in as an existing verified tenant owner. |
| GET | `/me` | Read the authenticated tenant and current token metadata. |
| POST | `/me/password` | Change the account password and replace all old owner API keys. |
| GET | `/templates` | List safe published templates available to this tenant. |
| GET | `/services` | List this tenant's PBX services. |
| POST | `/services` | Create a PBX from a current template; requires `Idempotency-Key`. |
| GET | `/services/{service_uuid}` | Read one owned PBX. |
| GET | `/subdomains/availability?label=example-company` | Check an address label without reserving it. |
| GET | `/services/{service_uuid}/subdomain` | Read address preparation/readiness. |
| POST | `/services/{service_uuid}/subdomain` | Request an owned service's address; requires `Idempotency-Key`. |
| GET | `/tokens` | List token metadata without token secrets. |
| POST | `/tokens` | Create a named integration token. |
| DELETE | `/tokens/{token_uuid}` | Revoke a token immediately; success is HTTP 204. |
| POST | `/tokens/{token_uuid}/rotate` | Replace a token and invalidate its old secret. |

Tokens can be created with `{"name":"Billing integration","expires_in_days":30}`.
The expiry is at most **90 days**; at most **10 active tokens** are allowed per
tenant. Rotation optionally accepts `expires_in_days`. Save the newly returned
secret before replacing it in your integration. A lost verification/sign-in
response can be recovered by signing in again; never keep retrying a consumed
verification code.

## Idempotency, limits and retries

Use one unique UUID `Idempotency-Key` for each intended create-service or
register-subdomain operation. Retain it when retrying that same request after
a timeout. An identical retry returns its original saved result with
`Idempotent-Replayed: true`; changed details with a reused key receive
**409 idempotency_conflict**. Poll the subdomain resource for current readiness,
because the original saved response can still show its initial pending state.
Use a new key for a genuinely new operation. Do not send a new key
automatically on every retry: that can create another intended service when
your quota permits it.

New public tenants start with a **one-service quota**. The instance operator
controls admission and can adjust service limits. Public signups have a
default instance cap of **25**; this is not an unlimited hosted-service offer.

| Operation | Default limit |
|---|---|
| Register | 5 per source IP/hour; 3 per email/hour; 100 globally/day. |
| Verify | 30 per source IP/10 minutes. |
| Sign in | 20 per source IP/10 minutes; 8 per email/10 minutes. |
| Change account password | 5 attempts per owner/10 minutes. |
| Authenticated API | 120 per tenant per minute, shared by its tokens. |

Rate limits are enforced by the server. On **429**, honor `Retry-After` rather
than retrying immediately. On transport timeouts or a temporary **503**, use
bounded exponential backoff; preserve the original idempotency key for a
write. Validation/authentication/ownership conflicts need a correction, not
an endless retry loop. DNS/certificate/provider limits can delay a requested
name; retain the existing working connection while its status is pending.

## Errors and security boundaries

Errors return JSON with this structure:

```json
{
  "error": {"code": "invalid_request", "message": "Check the supplied details."},
  "request_id": "REQUEST_REFERENCE"
}
```

Use the response's HTTP status and `error.code` for control flow. Include
`request_id` in a support report, without passwords, bearer tokens or the
verification code.

| Status | Meaning |
|---|---|
| 400 | Invalid JSON, unknown/invalid fields or missing required details. |
| 401 | Missing, expired, revoked or invalid authentication. |
| 403 | HTTPS, account/tenant permission or request-origin restriction. |
| 404 | Unknown route or unavailable object; another tenant's objects are not exposed. |
| 405 | Incorrect HTTP method; inspect `Allow`. |
| 409 | Conflict, including a domain, quota or idempotency restriction. |
| 413 | Request body exceeds the supported size. |
| 415 | A JSON body requires `application/json`. |
| 429 | Rate limit exceeded; inspect `Retry-After`. |
| 503 | A required service is temporarily unavailable. |

The API is for server-side integrations, not browser-cookie or cross-origin
website authentication. JSON bodies are limited to 32 KiB and unknown input
fields are refused. Clients cannot
choose an arbitrary tenant ID, assign platform roles, supply DNS server
addresses, read trunk passwords, alter another customer's service or run
operating-system commands. There is no API operation here for deleting a
tenant's installation or customer recordings. For account/data removal,
follow the [deletion procedure](https://openwebpbx.com/delete).

Public self-service tenant owners use the modern Desktop and Tenant Services
portals. Direct legacy administration pages are unavailable to these accounts.
Existing invited tenants keep their current permissions.

## Operator notes

Under **Tenant Services → Templates**, publish a shared provider-free starter
and select **Allow new tenants to use this starter template through the API**.
Saving this choice requires an empty trunks list, outbound rules list and
additional settings list. Ordinary tenant-owned/private templates and existing
services are not changed. No direct SQL is needed to make this choice.

Use the instance's configured global outgoing-mail server for verification.
SMTP acceptance is not a guarantee of inbox delivery. Registration cannot
be treated as a successful activation while email verification is pending.
The domain broker, DNS and trusted HTTPS worker must be ready before a tenant
connection hostname is advertised as ready.

Keep application/database backups and audit records under the instance's
normal privacy and retention policy. Store API token hashes, not raw tokens.
Do not log request bodies containing registration passwords or verification
codes. This API has its own versioned contract and does not change the
published Android 1.0.19 package, signed server assets or update feeds.
