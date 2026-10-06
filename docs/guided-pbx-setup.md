# Guided PBX setup and 3CX migration

Open **Admin** from the desktop, or visit `https://call.openweb.co.za/app/pbx_setup/`.
An empty PBX opens the setup steps automatically. Restored services use the familiar
Dashboard, Users, Phones, Voice & Chat, Outbound Rules, Departments, Office Hours,
Call Handling, Contacts, Reports, Recordings, Backup & Restore, and System pages.

## Create a PBX

1. Select **New PBX** and enter the company name, PBX name, and timezone.
2. Add people with their extension number, name, and optional voicemail email address.
3. Add a voice provider, or leave its SIP server blank to configure it later. IP authentication
   requires no username or password; password authentication requires both.
4. Optionally route the main incoming number to a user. Enter a dialing prefix to add an
   outgoing rule, including any digits to remove or prepend. A blank prefix creates no rule.
5. Review the counts and warnings, confirm, and create the PBX.

The platform administrator can select an existing company workspace. Choosing **My company**
creates a workspace owned by that existing administrator when necessary. Tenant owners use
their own workspace. Every setup creates a new isolated service; it does not replace an
existing PBX. SIP passwords and voicemail PINs are generated separately for each person.
Use Users → Phone Provisioning for restored services, or the native Users editor to obtain connection details and provision phones.

Providers and incoming numbers start disabled. Their incoming context is `ingress@<PBX realm>`,
which excludes shared global dialplans and rejects unconfigured incoming calls. Bind and
verify provider ingress for that service before enabling its gateway and incoming routes.
Confirm caller ID, incoming/outgoing calls, voicemail, and provider-approved emergency routing.
Use `call.openweb.co.za` as the SIP server/outbound proxy and the service's SIP domain as its realm.

## 3CX V20 status

The supplied native V20 Update 9 backup (`20.0.9.995`) has been restored and checked.
See [V20 restore](v20-restore.md) for restored objects, media, administration, and
remaining differences. Unknown native builds remain unavailable until their layout
is checked. This is OpenWeb PBX; proprietary 3CX apps and services are not imported.

3CX introduced [Backup & Restore V2 in V20 Update 7](https://www.3cx.com/blog/releases/admin-system-management/).
The [documented SetupConfig XML](https://www.3cx.com/docs/configure-pbx-automatically/) is a
configuration input/export format, distinct from a native backup. Its supported settings can
be migrated now; that does not establish V20 backup compatibility.

The analyzer recognizes structurally verified legacy V14/V16 XML/ZIP configuration layouts
and documented SetupConfig XML. It maps supported SIP users, authentication credentials,
voicemail settings, basic SIP trunks, ring groups, incoming destinations, and outgoing
prefix/length/strip/prepend rules. Unsupported settings are reported before creation;
trunks, schedules, failover, provider header rules, media, and other omissions must be reviewed.
Phones and applications must be reprovisioned. Legacy tests use synthetic fixtures. The optional native V20 check uses a privately
supplied customer archive, kept outside repository fixtures.

## Review and import

1. Select **Import 3CX backup** and upload an unencrypted ZIP or configuration XML.
2. Review supported counts, warnings, and unsupported items. Unknown native V20 builds
   cannot proceed. Compatible configuration migration requires an explicit
   acknowledgement of the listed limitations.
3. Choose the company, PBX name, and timezone, and create an independent service.
4. Configure omitted behavior and verify every call flow before moving live numbers.

The web upload limit is 2 GB; XML is limited to 8 MB. Media is streamed into private
storage after validation; source programs and scripts are never executed.
Traversal paths, symlinks, encrypted ZIP entries, ambiguous configuration files, external XML
entities, oversized expansion, and excessive XML complexity are rejected. Preview pages omit
credential values. Drafts are encrypted in PostgreSQL with the key outside the web root,
bound to the creating administrator, and expire after an hour. Completion removes draft
credentials and retains a secret-free report. Repeated confirmation returns the same service.
Provisioning is one transaction; failed creation leaves existing PBXs unchanged.

## Deployment and verification

Install PHP's ZIP extension, apply `app/tenant_services/resources/install.sql` first, then
`app/pbx_setup/resources/install.sql`. Preserve `/etc/fusionpbx/openweb-template.key` with
the same restricted permissions as the tenant template feature. Upload handling uses the
existing PHP-FPM and NGINX limits; both must permit a 2 GB form upload. Apply `app/pbx_setup/resources/restore.sql` and
follow the Lua deployment steps in [V20 restore](v20-restore.md).

Run `app/pbx_setup/cleanup.php` every ten minutes as the web service account. It removes
expired drafts and disposable upload copies. It leaves the original operator backup intact.

Run the CLI-only parser checks and isolated PostgreSQL integration checks:

```sh
php tests/threecx_backup_parser.php
php tests/pbx_setup_provisioner_integration.php
php tests/pbx_setup_integration.php
php tests/tenant_services_integration.php
```

The mapper rejects foreign references, unsupported behavior, duplicate identities, and
nonempty target PBXs. Stock dialplans copied for new services are limited to the bundled
application/name/context pairs, excluding the platform's custom carrier and business routes.
Native V20 restore, preserved-password phone registration, and an answered internal
call passed on this instance. Carrier calling and provider-approved emergency routing
remain unverified; trunks and incoming numbers remain off.
