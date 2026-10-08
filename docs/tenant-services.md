# Tenant services

OpenWeb PBX uses invite-only tenant accounts. Sign in at [Tenant Admin](https://call.openweb.co.za/tenantadmin/), or open **Tenant Services** from the desktop. The project entry at https://openwebpbx.com/tenantadmin redirects to this authenticated portal.

## Administrator workflow

1. Under **Tenants & invitations**, enter a tenant name, short name, administrator email, and service limit. Copy the invitation and share it with that administrator. Invitations expire after seven days and can be accepted once. **Renew invitation** invalidates the previous link and creates a fresh link for an unaccepted invitation.
2. Under **PBX templates**, create and publish a reusable setup. The platform administrator manages shared templates; tenant administrators manage templates for their own tenant. The installed **Business PBX** starter creates extensions 100 and 101 with voicemail, an extension limit of 100, and the Africa/Johannesburg timezone. Configure provider details before using it for external calling.
3. A tenant accepts its invitation, sets a password, and signs in using its full email address at the central hostname. Until a service is created, its desktop exposes the tenant workspace and profile.
4. Under **PBX services**, choose a published template, enter a service name and short name, and supply any service-specific trunk credentials. Provisioning creates an independent PBX domain and opens its desktop. Return to **Tenant Services** to switch services or create another one.

Templates support timezone, initial extension range/count, extension limit, outbound caller ID, SIP trunk presets (proxy, username, password, transport, registration, enabled state), outbound number rules, and allowed domain business settings. Number rules use an anchored regular expression with a captured dialled number, a selected trunk, and an optional numeric prefix. For example, `^(0[0-9]{9})$` bridges the first captured number through that service's copied gateway.

Additional settings use existing PBX category, subcategory, and type names. Business categories include voicemail, email/SMTP, recording, devices/provisioning, SIP, and call applications. Authentication, roles, executable paths, URLs, and global configuration are excluded. Configure extension limits in the dedicated defaults field.

The instance administrator configures one global server under **SMTP Outgoing Mail** for all outgoing email. Tenants do not configure a relay or a separate database. Until the global mail server is ready, queued mail waits without consuming delivery retries. See [outgoing mail configuration](outgoing-mail.md).

Each service gets its own extensions, unique SIP passwords, voicemail boxes/PINs, copied standard application dialplans, trunks, call rules, and domain settings. Template versions are recorded on services. Editing or unpublishing a template affects future provisioning; existing services retain their current setup. Provisioning is transactional and repeated submissions with the same request identifier return the same service. Registration trunks without both a username and password stay disabled.

Use `call.openweb.co.za` as the SIP server/outbound proxy and the generated service domain as the SIP realm, for example `office.acme.call.openweb.co.za`. These realm names identify PBX domains; this feature does not provision wildcard DNS or certificates for separate web hostnames. Provider credentials, telephone numbers, NAT settings, endpoints, and provider-specific inbound routing still need real deployment configuration.

Tenant administrators have ordinary PBX administration permissions without global domain selection, cross-domain access, or higher-role delegation. Service users remain restricted to the PBX domain containing their account. **Suspend tenant** blocks tenant web access, including existing sessions, and further provisioning. It does not disconnect active calls or disable already provisioned SIP accounts; use the PBX controls for telephony shutdown.

## Installation and operations

Debian and Windows installations automatically install PostgreSQL on the PBX server. All tenants and PBX services use the same instance database, with tenant and domain ownership checks separating their data. Creating a tenant or service does not create a database or request database credentials. The operational database name remains `fusionpbx` for compatibility.

This feature targets the installed PostgreSQL-backed FusionPBX 5.6 stack with PHP Sodium. Preserve the upstream license and operational identifiers.

Back up the database before applying the migration. From the application checkout as an operator able to read the source:

```sh
runuser -u postgres -- psql -d fusionpbx -v ON_ERROR_STOP=1 < app/tenant_services/resources/install.sql
```

The migration creates the three workspace tables, permissions, tenant role, menu entries/translations, and unique domain/account indices. It enables global email/username authentication for the central login host. Existing duplicates must be resolved before those indices can be created. Run this migration explicitly; the application's generic schema updater does not create these custom tables. Re-running the migration is supported. Reload PHP-FPM afterward to invalidate any old settings cache.

Create `/etc/fusionpbx/openweb-template.key` once with 32 cryptographically random bytes, readable by the PHP worker and inaccessible through the web root. On this deployment its owner/group is `root:www-data` and mode is `640`. Back up this key privately alongside the database; restore the same key to decrypt existing templates. Never regenerate it on an existing installation. Template payloads are encrypted using Sodium secretbox; editor forms leave stored passwords blank and preserve matching saved credentials when left unchanged. Provisioned gateway credentials are stored in the native PBX gateway table for FreeSWITCH consumption.

Operational backups are under `/var/backups/openwebpbx`. The public hostname's NGINX configuration is `/etc/nginx/sites-available/openweb-call.conf`. Let's Encrypt renewal runs through `certbot.timer`, with the NGINX reload hook under `/etc/letsencrypt/renewal-hooks/deploy/`. Local credentials and browser state remain outside the public source and live web root.

## Verification

```sh
php tests/tenant_services_integration.php
```

The integration check creates and removes a temporary PostgreSQL schema. It tests invitation renewal/replay, credential encryption, validation, two isolated tenants and services, copied trunks/rules, service limits, repeated requests, private template visibility, shared template ownership, suspension, and preservation of existing services. It triggers a FreeSWITCH XML reload/rescan but does not create customer records.

Live HTTPS checks additionally covered CEO/tenant sign-in, invitation acceptance, CSRF rejection, two-tenant provisioning, desktop extension access, foreign domain/service rejection, suspension/reactivation, dynamic template rows, and mobile layouts. FreeSWITCH recognized extensions in each service realm without exposing them in the platform realm. External calling and endpoint registration require real carrier credentials and endpoints and have not been tested.
