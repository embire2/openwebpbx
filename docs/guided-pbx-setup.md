# Guided PBX setup and 3CX migration

Open **PBX Setup** from the desktop, or visit `https://call.openweb.co.za/app/pbx_setup/`.
An empty PBX opens this control panel automatically. It groups administration into Overview,
Users & phones, Voice & numbers, Call handling, and Settings. Existing native editors remain
available for detailed phone provisioning, queues, digital receptionists, and schedules.

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
Use the native Users & extensions editor to obtain connection details and provision phones.

Providers and incoming numbers start disabled. Their incoming context is `ingress@<PBX realm>`,
which excludes shared global dialplans and rejects unconfigured incoming calls. Bind and
verify provider ingress for that service before enabling its gateway and incoming routes.
Confirm caller ID, incoming/outgoing calls, voicemail, and provider-approved emergency routing.
Use `call.openweb.co.za` as the SIP server/outbound proxy and the service's SIP domain as its realm.

## 3CX V20 status

**Native V20 backup restore is not yet supported.** A backup from the intended installation
and its exact V20 update/build are required to implement and validate its adapter. Unsupported
versions and encrypted containers produce a report and cannot create a PBX, even through
a direct form submission. This is not a drop-in 3CX installation or a promise of full backup
fidelity, 3CX client compatibility, or restoration of licensing, recordings, voicemail audio,
provisioning, call history, department rules, and every routing feature.

3CX introduced [Backup & Restore V2 in V20 Update 7](https://www.3cx.com/blog/releases/admin-system-management/).
The [documented SetupConfig XML](https://www.3cx.com/docs/configure-pbx-automatically/) is a
configuration input/export format, distinct from a native backup. Its supported settings can
be migrated now; that does not establish V20 backup compatibility.

The analyzer recognizes structurally verified legacy V14/V16 XML/ZIP configuration layouts
and documented SetupConfig XML. It maps supported SIP users, authentication credentials,
voicemail settings, basic SIP trunks, ring groups, incoming destinations, and outgoing
prefix/length/strip/prepend rules. Unsupported settings are reported before creation;
trunks, schedules, failover, provider header rules, media, and other omissions must be reviewed.
Phones and applications must be reprovisioned. Legacy tests use synthetic fixtures; no actual
customer V20 backup has been restored or validated.

## Review and import

1. Select **Import 3CX backup** and upload an unencrypted ZIP or configuration XML.
2. Review supported counts, warnings, and unsupported items. Unsupported native V20
   backups cannot proceed. Compatible configuration migration requires an explicit
   acknowledgement of the listed limitations.
3. Choose the company, PBX name, and timezone, and create an independent service.
4. Configure omitted behavior and verify every call flow before moving live numbers.

The web upload limit is 50 MB; XML is limited to 8 MB. Archives are never extracted or executed.
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
existing PHP-FPM and NGINX limits; both must permit a 50 MB form upload.

Delete expired uncompleted drafts periodically, for example from a restricted root cron file:

```cron
*/10 * * * * postgres psql -d fusionpbx -v ON_ERROR_STOP=1 -qc "DELETE FROM v_pbx_setup_drafts WHERE expires_at < now() AND completed_domain_uuid IS NULL"
```

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
Real SIP registration, carrier calling, emergency routing, and a native V20 restore remain
unverified until the actual providers, phones, and backup are available.
