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

Trunks and incoming numbers start off. Under Voice & Chat, review the provider
server, transport/port, authentication, registration and caller ID, and supply
provider-approved incoming IP addresses. Authentication is independent of
REGISTER: the inspected backup has ten registering carriers, three credential
connections without registration and five IP-authenticated carriers, plus one
bridge. The source configuration preserves realm/authentication ID, From/Contact
and caller-ID header settings, proxies, registration expiry, concurrency, codec
order and the selected incoming DID header.

Arrange the provider's change from the existing PBX, then qualify one reviewed
connection and its selected DID Numbers. Incoming checks use the enabled
provider, approved source IPs, any native provider binding and the configured
To-header or Request-URI number. Exact DIDs precede suffix rules and provider
defaults; defaults are limited to that provider's declared numbers. The same
number from the same provider cannot be enabled for two tenants. Saving changed
provider addresses refreshes incoming checks; disabling a trunk turns its
numbers off. Follow the [carrier cutover guide](carrier-cutover.md) before
switching an active service. Connect a handset through Users → Phone Provisioning
and test internal, incoming, outgoing and unanswered calls.

Version 1.0.2 implements the observed queue callback preferences; the twelve restored
queues were migrated and the obsolete callback-unavailable report entries were removed.
Request, timed-offer and automatic callbacks passed internal-phone tests on Debian;
automatic delivery also passed on native Windows. Exact callback position and
outside-carrier qualification remain open; see [callbacks](callbacks-and-hotels.md).

3CX apps, its hosted email delivery and the imported 3CX bridge still need OpenWeb
replacements or configuration. Missing source prompts and PIN destinations are listed
in the Restore Report. Queue position announcements are not offered as a new setting
until their playback is implemented. System → Email configures a shared SMTP server,
including IP Authentication. Track the remaining work in the [3CX roadmap](../3CX.md).
The console does not claim that OpenWeb PBX is a running 3CX instance or that carrier
calls have passed without a test.

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

The 2026-10-08 development checks also cover provider fields and incoming
ownership in `tests/pbx_v20_trunks_integration.php`, existing-service repair in
`tests/pbx_trunk_refresh.php`, editor round trips and readiness diagnostics.
Maintainer reconciliation uses a caller-owned transaction and defaults to a
secret-free dry run. It verifies the source build, provider inventory and native
tenant/UUID bindings, refuses unexpected identity or behavior changes, and
retains enablement, approved addresses, users and media. It can correct an
existing verified restore without importing a second PBX. This maintenance
helper is not yet a completed guided reconciliation workflow.
The production repair updated 19 native gateways, 44 incoming rule conditions
and provider bindings, and 19 fallback orders while preserving credentials,
native identities and disabled state. Customer connections remain off.
A subsequent production dry run reported zero changes to gateway fields,
policy, incoming XML, details, bindings and order.

On this instance, registration with preserved passwords, internal calls, a restored
ring group, a restored queue and a receptionist menu key passed with two-way audio. A new call recording
appeared in Recordings and played through the protected audio endpoint.
The controlled carrier pilot below does not qualify every restored connection.
User recording options apply to outgoing calls and calls answered through queues
and ring groups; recordings are indexed in the protected Recordings page.

On 2026-10-08, actual Debian-engine local-provider checks passed outgoing 503
fallback, stopping on 486 busy, rewriting, caller ID, dynamic Contact/RPID,
407 credential authentication without REGISTER, intact PCMU/PCMA offers, PCMA
and two-way RTP audio. Two durable callbacks to synthetic external numbers
passed agent-first delivery, provider fallback or fresh digest authentication,
and one-attempt Connected completion with cleared leases and agent release.
Ordinary and callback RTP transmit/receive rate checks also passed.
The fixture starts already-leased jobs and verifies Lua delivery, rather than
the C# worker's claim/dispatch path. It used two actual registered local phones.
Incoming delivery passed with the DID in the To header and a contact alias in
the Request URI; unknown numbers, wrong gateway bindings, unapproved sources and disabled
providers were rejected. Scoped media/XML/CDR/job cleanup and native
queue/agent/tier removal passed. The policy and mocked runtime suites passed
149 and 41 checks respectively; six actual native codec-parser checks also
passed. Nine configured SIP endpoints resolved, seven answered a nonregistering
SIP probe and two timed out; these probes do not qualify calls.
An additional registration-only cleanup check passed for both original contact
Call-IDs without exposing native account listings.

A separately authorized registration-based carrier pilot registered and
answered a controlled outgoing call. The 16-second call exchanged 765 sent and
797 received RTP packets through G729-to-PCMU transcoding, without native audio
errors. Caller audibility confirmation is pending. Rollback restored the
original source-IP bindings and left all 19 customer connections off with no
pilot calls remaining. Incoming public routes, DTMF, transfers, sustained-call
stability, real carrier callbacks, replacement apps and Windows qualification
remain pending. The published 1.0.2 archives are unchanged.
