# OpenWeb PBX administration and V20 restore

The Admin console uses the 3CX page names: Dashboard, Users, Phones, Voice & Chat,
Outbound Rules, Departments, Office Hours, Call Handling, Contacts, Reports,
Recordings, Backup & Restore, and System. User editing has General, Call
Forwarding, Voicemail, Phone Provisioning, and Options tabs.

Backup & Restore accepts unencrypted ZIP files up to 2 GB. Native V20 restore
currently supports the inspected Update 9 build `20.0.9.995`. Unknown builds
remain unavailable until their layout and behavior are checked. Analysis does
not execute source scripts, firmware, or provisioning programs.

The restore creates a separate tenant-owned PBX. It keeps phone account
passwords, user statuses and forwarding profiles, departments and hours,
ring groups, queues and agents, receptionist keys, incoming destinations,
outbound order, department/user restrictions, and trunk failover settings.
The recognized PIN menu is translated to bounded local call handling; its
original C# code is never executed. Files missing in the original backup and
missing PIN destinations appear in the Restore Report.

Recordings, prompts, and voicemail audio remain outside the web root and are
available through authenticated, domain-scoped streaming. Voicemail is also
imported into the native mailboxes, including files absent from the old index.
The twelve saved voicemail greetings are available under Users → Voicemail. The
source does not identify an active greeting, so the user chooses it by name.
Personal call history is available under Reports. Old certificates, licenses,
JWT signing keys, refresh tokens, web account passwords, and 3CX binary services
are never imported. The existing administrator and HTTPS certificate remain.

Trunks and incoming numbers start off. Under Voice & Chat, check the provider
server, authentication and caller ID, supply provider IP addresses, and enable
the trunk. Then enable the chosen DID Numbers. Incoming calls check the source
IP and enabled trunk before entering that PBX. The same number from the same
provider cannot be enabled for two tenants. Saving changed provider addresses
refreshes existing incoming checks; disabling a trunk also turns its numbers off. Connect a handset using Users →
Phone Provisioning and test internal, incoming, outgoing and unanswered calls.

3CX apps, its hosted email delivery, a 3CX bridge, and two automatic queue callback options
are not available in OpenWeb PBX yet. Missing source prompts and PIN destinations
are listed in the Restore Report. Queue position announcements are not offered
as a new setting until their playback is implemented. System → Email configures a shared SMTP
server, including IP Authentication. The console does not claim that OpenWeb
PBX is a running 3CX instance or that carrier calls have passed without a test.

## Installation and checks

Apply `app/pbx_setup/resources/restore.sql` after the existing tenant and guided
setup migrations. Deploy the PHP, CSS and JavaScript files, and copy the Lua
files in `app/pbx_setup/resources/switch/scripts/app/pbx_setup` to the corresponding
FreeSWITCH scripts directory. Give the PBX service account private access to
`/var/lib/openwebpbx/uploads` and `/var/lib/freeswitch/storage/openwebpbx`.
Raise the authenticated upload limits in PHP and NGINX for large backups.
Run `app/pbx_setup/cleanup.php` from cron to expire drafts and disposable uploads.

`php tests/threecx_backup_parser.php`, the existing mapper/setup/tenant integration
checks, and `lua tests/pbx_call_policy.lua` exercise bounded parsing, transactions,
isolation, hours, forwarding, and outgoing call decisions. The optional full
restore check reads an operator-supplied private archive:

```sh
OPENWEB_PRIVATE_BACKUP=/private/path/backup.zip php tests/pbx_v20_restore_integration.php
```

That check uses an isolated database schema and removes restored test files.
Customer data must never be copied into repository fixtures or published.

On this instance, registration with preserved passwords, internal calls, a restored
ring group, a restored queue and a receptionist menu key passed with two-way audio. A new call recording
appeared in Recordings and played through the protected audio endpoint. Outside
calls still require provider connection checks.
User recording options apply to outgoing calls and calls answered through queues
and ring groups; recordings are indexed in the protected Recordings page.
