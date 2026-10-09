# OpenWeb PBX feature coverage

OpenWeb PBX is a free, independently developed PBX built on FusionPBX and FreeSWITCH. Version 1.0.7 adds Android ear protection, prominent update controls and Google Play submission preparation to the working native calling, managed updates, tenant, callback and hotel foundations. It does **not** implement every 3CX feature, run 3CX software or accept proprietary 3CX apps. No claim of being the world's first free PBX is made.

The Windows edition includes a C#/.NET 10 background calling service and WinUI 3 administration manager, built with Visual Studio 2026. The existing web application uses PHP and the call engine uses FreeSWITCH/Lua. This is not a complete C# rewrite. The manager opens the authenticated web Admin and is not a calling app.

## Released 1.0.2 baseline

This table records the published 1.0.2 packages. The 1.0.3 additions and their
verification state appear below; the existing 1.0.2 archives are unchanged.

| Area | Version 1.0.2 behavior | Verification and limits |
| --- | --- | --- |
| Installation | Native Windows Server and Debian 13 packages, initial administrator and two users | Windows Server 2025 Desktop Experience and Debian 13 amd64; other Windows releases are unverified |
| Administration | Guided setup, familiar page names, Windows-inspired web desktop, native WinUI manager | Authenticated desktop/mobile administration and Windows RDP checks |
| Tenants | Invite-only companies, separate PBX services, shared/owned templates, scoped administrators | Database and live tenant-isolation checks |
| Users and calls | SIP users, voicemail, departments, hours, forwarding, ring groups, queues, receptionists | Internal, ring-group, queue and receptionist calls with two-way audio; supported source backup behavior only |
| Providers | Provider and number configuration, incoming/outgoing rules | Imported providers remain off; real carrier calls require provider setup and testing |
| Queue callbacks | Request, offer after waiting, automatic after waiting; agent first, retries, cancellation, expiry, status and hours checks | Live internal-phone callbacks on both operating systems; live waiting callers have priority; exact virtual queue position and provider failover are not implemented |
| Hotel rooms | Check-in/out, guest record, Clean/Dirty/Inspected/Maintenance status, DND, vacant-room outside-call blocking, mailbox reset and new PIN | Tenant-isolated operations and privacy checks; no automatic handset name/provisioning update |
| Wake-up calls | Administrator scheduling, announcement, press 1 confirmation, bounded retries and result history | Live confirmed calls on Debian and Windows; no guest scheduling IVR or PMS scheduling |
| Recordings and history | Protected playback, native recording indexing and imported history | Restored and new internal/queue/ring-group recordings checked; operator retention still applies |
| Outgoing mail | Shared SMTP relay, password or IP authentication | Local SMTP authentication and no-AUTH wire tests; a real mail provider must be configured |
| Backup import | Observed 3CX V20 Update 9 layout, supported calling objects and private media | Customer backup trial/live restore tested; the Restore Report lists missing media and unmapped behavior; other native builds require validation |

## Carrier and routing verification — 2026-10-08

The 1.0.3 source includes the following work beyond the published 1.0.2
packages. Local tests and the bounded carrier pilot below have distinct
qualification limits; broad 3CX compatibility is unverified. See [carrier cutover](carrier-cutover.md) for the
operator workflow and current blockers.

| Area | Version 1.0.3 behavior | Verification and remaining limits |
| --- | --- | --- |
| Provider restore | Independent authentication and REGISTER, transport/port, realm/authentication ID, proxies, expiry, concurrency, codecs, From/Contact/RPID and DID source selection | All 18 carrier configurations from the inspected `20.0.9.995` backup mapped; one bridge needs replacement. Focused mapping and full private-backup restore checks passed. Other builds remain unverified. |
| Existing-service repair | Guarded dry run and reconciliation of native provider fields, incoming conditions/bindings and fallback order | Applied to the production restore: 19 gateways and 44 incoming rules repaired, including 19 fallback order changes. Credentials, identities, users, media, IP bindings and disabled state were retained; a subsequent dry run reported zero changes. All customer connections remain off. The guided reconciliation workflow remains incomplete. |
| Simple provider administration | Advanced settings retained through editor save/reload, separate registration control, native status and DNS/TCP/TLS readiness with next actions | Scoped permission, CSRF, masking, identity and editor round-trip checks passed. Readiness does not send REGISTER or qualify calls; UDP signalling and remote SIP/RTP network checks remain separate work. |
| Outgoing routing | Ordered provider fallback, busy-stop behavior, rewriting, caller-ID/header selection and challenge authentication without registration | Actual Debian FreeSWITCH local-provider tests passed 503 fallback, 486 stop, Contact/RPID, fresh 407 authentication without REGISTER, intact PCMU/PCMA offers, negotiated PCMA and two-way RTP. Six actual native codec-parser checks passed. Broader carrier and Windows qualification remain pending. |
| Durable external-number callbacks | Agent-first delivery through ordinary provider policy, provider fallback, digest authentication and durable result tracking | Two synthetic external-number callbacks passed 503 fallback or fresh 407 authentication, PCMA two-way audio with verified packet rates, one-attempt Connected completion, cleared leases and native agent release. This fixture starts already-leased jobs and tests Lua delivery, not C# claim/dispatch. Real carrier callbacks and Windows provider-fallback qualification remain pending. |
| Incoming ownership | Exact/suffix/default precedence, declared-number fallback, enabled native provider/tenant binding and approved source-IP gates | Actual Debian local-provider delivery passed with a To-header DID and Request-URI contact alias; unknown DID, wrong gateway, unapproved source and disabled provider were rejected. Production incoming rules were reconciled. Policy/runtime suites passed 149/44 checks; two registered local phones were used and scoped media/jobs/XML/CDR/native queue/agent/tier cleanup passed. Public-network delivery remains unverified. |

Nine configured SIP endpoints resolved; seven answered a nonregistering SIP
probe and two timed out. DNS and SIP responses confirm connectivity only.
An additional registration-only fixture check verified exact original-Call-ID
cleanup, leaving zero matching native contacts without printing phone accounts.
A separately authorized carrier pilot registered and answered a controlled
16-second outgoing call, exchanging 765 sent and 797 received RTP packets
through G729-to-PCMU transcoding without native audio errors. Caller audibility
confirmation is pending. Rollback restored source-IP bindings, left all 19
customer connections off and left no pilot calls running. Public incoming
delivery, DTMF, transfers, sustained-call stability and real carrier callbacks
remain unverified. The missing source audio/PIN destinations, greeting
selection, additional calling apps and bridge still need the work in
[V20 restore](v20-restore.md) and RESTORE-01/10/PHONE-04 in [the roadmap](../3CX.md).

## Native Android and server updates — 1.0.3

The Android client is a standalone Kotlin application with native screens and its
own Linphone calling engine. It has no WebView. Its five delivery workflows are
QR enrollment, incoming/outgoing calls, call controls, directory/recents and
voicemail. [The Android guide](android.md) records installation, operation and
qualification. Physical handset audio, battery restrictions, Wi-Fi/mobile network
changes and push wake-up remain separate work; the current app keeps an ongoing
foreground connection and must be reopened after force-stop or restart.

Server validation passed 27 isolated database checks for one-use enrollment,
per-device credentials, tenant/mailbox isolation, call reports, expiry and
revocation. Live tenant-owner administration passed QR creation, phone removal,
CSRF refusal and cross-tenant refusal. Actual native phone registration passed
trusted TLS, separate device authentication and mapping to the original extension.
The Android 13 device decoded the actual PBX-generated QR code and passed
Keystore encryption/tamper checks. The decoded result passed through the native
scanner callback, server confirmation and enrollment; physical camera capture
was substituted by instrumentation. Native outgoing/incoming TLS/SRTP calls,
sustained media in both directions, incoming notification-to-answer, mute,
speaker selection, hold/resume, received menu digits, contact dialing, Recents
redial and voicemail playback/read/delete passed. Enrollment rotation and
cancelled voicemail-download regressions passed. The test device has no earpiece
hardware; physical handset audio and camera coverage remain unqualified. The signed,
non-debuggable universal APK passed installation and native workflows. Removing
a phone also ended its active incoming call and denied API/SIP reuse.

Both server editions include in-place update tools with manifest verification,
private backups and automatic recovery. Installed 1.0.2→1.0.3 upgrades passed on
Debian 13 and Windows Server 2025, including preserved-password registration,
answered internal calls with two-way RTP and recovery after controlled migration
failures. Debian also rejected an update during an active call. Windows native
WinUI launch, version/status display, Admin and Android navigation passed through
RDP. Interrupted-power/reboot recovery and Windows 10/11 server installations
remain unqualified. The Windows manager continues to be an administration tool.

Trusted phone TLS with hostname/full-chain checks passed on the deployed Debian
IPv4 and IPv6 listeners. Public Windows phone TLS needs its own hostname and
trusted certificate; the Windows test installation correctly refuses mobile
pairing while it has only its local setup certificate.

## Automatic updates and phone usability — 1.0.4

Version 1.0.4 adds **Tenant Admin → Updates** and **Admin → System → Updates**.
Instance administrators choose manual updates, automatic downloads, or automatic
installation within a daily UTC window. Tenant owners separately choose voluntary,
automatic-download, or required Android updates for their phones. The server
worker runs independently so application shutdown does not stop the update.
Downloads finish and pass signature, size, hash and package validation before
installation. Existing 1.0.3 installations need a one-time updater bootstrap.

Thirty-five PostgreSQL integration checks and twenty live HTTPS checks passed for
policy persistence, tenant ownership, permissions, CSRF, commands and filtered
status. Desktop, embedded dark theme and 390px layouts passed. Browser testing
confirmed reconnection after a simulated outage without discarding unsaved policy
choices. See [updates](updates.md) for policies, the one-time bootstrap and recovery.

Debian 13 passed a signed 1.0.3→1.0.4 upgrade, active SIP-call and maintenance-window
deferral, migration-failure and failed-health rollback, and recovery after the
whole isolated machine was terminated during migration. Recovery ran before PBX
services started. Database identity, data, owners and grants were retained,
including the legacy database ownership layout. Preserved-password registration,
an internal call and two-way RTP passed after upgrading. Fresh configuration also
passed on an isolated Debian 13 image with distribution prerequisites already
installed, including local PostgreSQL, HTTPS Admin and internal two-way audio.
Twenty-eight focused Python checks passed.

Windows Server 2025 passed a signed 1.0.3→1.0.4 upgrade, active-call deferral,
tampered-feed refusal and a deliberately failed migration. Recovery retained the
database identity, ownership, permissions, users and phone passwords while the
independent updater kept running. The manager reopened in the original interactive
user session. Thirty-four shared updater checks and seventeen database/worker
checks passed. The updater service also recovered an interrupted rollback at startup, refused
a corrupted snapshot before changing the PBX, restored the manager in its original
session and retained the failed-release quarantine.

These tests establish the specific failure paths above. Other interruption stages,
physical power loss, and data-loss bounds during the brief final health check
after services reopen still need qualification.

The Android phone now has native vector call controls, a clearer keypad that fits
360px screens, its own extension label, self-call confirmation and useful failure
messages with retry/reconnect actions. Ten JVM checks, release lint and nine native
Android 13 acceptance methods passed. Native calls sustained two-way media and
passed mute, hold/resume, menu digits and hang-up. Update tests covered all three
policies, signature/APK tampering, cached-feed replay, complete download, active-call
deferral, required-update and urgent-call handling, installation permission,
cancellation/storage failure, actual package replacement and notification-to-reopen
with retained account registration. Android may require installation confirmation
and prevent automatic foreground reopening. These checks do not replace physical
handset, camera, mobile-network or battery-restriction qualification.

On 2026-10-09 the owner enabled a production provider. Registration is up; one
extension’s national route was corrected to select it instead of the disabled
provider chosen by the imported rule. The observed internal attempt dialled its
own extension and followed its restored forwarding behavior. Customer forwarding
settings were preserved. Real outgoing audio and calling another active phone
still need acceptance; historical statements that all connections were off refer
to the completed 2026-10-08 pilot, not the current owner-controlled configuration.

## Answered-call and phone audio fixes — 1.0.5 / 1.0.6

Actual customer calls exposed two gaps that the earlier registered-phone tests
had not covered. After a server restart, passthrough G.729 shadowed an installed
converter, so the provider answered but the PBX failed to decode audio and ended
both legs. An unanswered internal extension also ended immediately because the
restored handler sent an unsupported voicemail action. These are fixed; neither
registration status nor a successful internal bridge had established these paths.

The first 1.0.5 migration repaired the native XML, but the actual production upgrade
exposed a later step that regenerates that file from database module settings.
Version 1.0.6 also disables the conflicting database autoload setting when the
installed converter and its enabled setting are present. It preserves unrelated
modules and passthrough-only installations, runs inside the existing private
backup/recovery process, and does not install a codec. The readiness page detects
the conflict in either order. The release adds actual module-regeneration coverage
to the existing normalization and readiness checks: 17 XML, 16 PostgreSQL/module-
regeneration and 31 readiness checks passed. The regression first reproduces the
1.0.5 failure and then verifies repeated regeneration with the database repair.

The update page also reconnects with a fresh GET request after a version change.
Reloading its previous POST had replayed an already-used CSRF token and produced
an expired-form error even though the update itself completed. Authentication,
permissions and CSRF validation remain required.

A real call through the owner-enabled provider answered and sustained 25.1 seconds
with 1,034 sent and 1,249 received RTP packets, no early disconnect and no native
errors on either leg. The test caller ended it normally. Customer phone settings,
provider activation, routes and credentials were unchanged. The later user-confirmed Android 1.0.6 call establishes speech in both directions
on that handset; complete incoming/provider acceptance remains outstanding.

Voicemail now dispatches native greeting/recording with `save`, retaining `check`
for mailbox login. Fifty-three runtime and 149 policy checks passed. An actual
isolated SIP call saved 10.64 seconds of audio; playback delivered 531 RTP packets
with the expected 500 Hz tone. No email was queued. The fixture, message, contacts
and database rows were removed after verification.

The signed 1.0.4 Android build reproduced missing communication-audio mode. Version
1.0.5 supplies the calling SDK's required AndroidX media integration and lets the
SDK own ringing and audio focus. Ten JVM checks and release lint passed. Native
Android 13 tests passed a 42-second outgoing workflow with sustained two-way SRTP,
Home/background/return, competing-focus hold, resume and audio-mode release. An
incoming test passed ringing, answer, twelve seconds of two-way media and return
to normal audio mode. This remains software-device evidence; broader physical
handset, earpiece, Bluetooth and mobile-network qualification remains open.

## Android ear protection and Play preparation — 1.0.7

The app uses Android’s proximity screen lock during earpiece call setup and active
calls, preventing screen touches while held close. Speaker, wired/Bluetooth audio,
local hold and call end release that lock. Unsupported devices retain normal
power-button behavior. Eleven proximity-policy/adapter checks pass; an actual
handset near/far and audio-route test remains required.

A persistent update card, prominent required-update dialog, clear actions and
live download/verification progress make direct updates visible. Calls defer
installation and an urgent-call bypass remains available. Google Play has a
separate build that opens the store listing; it excludes the direct APK installer
and install permissions. It only reports a required store update after signed
metadata confirms a fully published production release. Initial 1.0.7 metadata
contains no such claim because Google has not approved the app.

Both variants target Android 16/API36. The signed APK and AAB passed release lint,
25 direct and 29 Play JVM checks. Google bundletool validated the AAB, its existing
signing identity and manifest; all 26 64-bit native libraries have 16 KiB-compatible
ELF alignment; both final APKs also passed 16 KiB ZIP alignment. Exact signed
1.0.6→1.0.7 package replacement preserved the account and reconnected. Final
direct and Play builds passed sustained SRTP/background/audio-focus/hold/resume
calls. Native 320/360dp screens retain all call controls and update visibility.
Android 16/16 KiB runtime testing remains open; binary alignment alone
does not establish runtime behavior.

An isolated permanent review portal provides reusable login, fresh QR/code
connection, internal echo and incoming-call tests, voicemail and fictional
contacts. It has no providers or outside routes. Forty-four mobile database,
13 repeat-provisioning, seven native background-command reply, nine bootstrap
migration, nine echo policy and 15 live
HTTPS checks passed; desktop/320px/390px browser checks have no overflow or
console errors. Final native review passed outgoing echo, portal incoming Answer
with SRTP, a newly recorded/playable/deletable 18.52-second synthetic voicemail,
external-number refusal and Disconnect. Credentials remain private. Privacy, support and data-removal
pages are live at openwebpbx.com. Store text, artwork, permission/data declarations
and the [owner’s publication guide](google-play.md) are prepared. Account
verification, any required closed test, Play-track tests and Google approval
remain incomplete; APP-16 stays open.

Windows 1.0.7 native compilation, three protocol and 34 updater checks passed on
Windows Server 2025 with Visual Studio 2026 and .NET 10.0.401. The WinUI manager
opened a responsive window showing 1.0.7. All 1,109 exported output hashes and 49
source inputs matched. Installed Windows upgrade/database/audio evidence remains
1.0.6; a new 1.0.7 installed-upgrade result is not claimed.

## Work still required

The maintained [3CX roadmap](../3CX.md) contains the detailed checklist, priorities,
acceptance conditions and external dependencies. The released baseline and
development evidence above are separate; CALL-01 and CALL-02 remain open.

These are explicit gaps:

- Replacement Windows, browser and iOS calling apps; Android mobile push, broader handset/network qualification, headset integration and activation for future clients.
- Hotel PMS/Fidelio/Mitel interfaces, guest folios, call charging, minibar entry, handset housekeeping codes and guest wake-up scheduling.
- A complete operator switchboard, wallboards, supervisor monitoring/coaching and equivalent queue analytics.
- Integrated business messaging, website chat, SMS and social messaging channels.
- Directory/calendar synchronization, enterprise sign-in and supported CRM connectors.
- Video meetings, AI transcription/summaries, voice agents and related service integrations.
- A compatible bridge/SBC deployment workflow, automated public-certificate setup on fresh installers, and tested high availability/disaster recovery.
- Full carrier qualification, emergency-call handling validation, NAT/TLS/SRTP interoperability, hardware provisioning qualification and scale/load testing.
- A complete backup/restore compatibility guarantee across 3CX versions, broader interrupted-update/reboot recovery and Authenticode-signed Windows distribution.

Underlying upstream modules may offer additional capabilities. Their presence alone does not establish that they work through this simplified Admin or match 3CX behavior.

## Comparison references

The comparison scope follows the official [3CX feature list](https://www.3cx.com/ordering/pricing/features/), [queue documentation](https://www.3cx.com/docs/manual/call-center-queues/) and [Hotel Module documentation](https://www.3cx.com/docs/hotel-pbx/), reviewed on 7 October 2026. Product offerings can change. The implementation and verification statements above describe OpenWeb PBX itself.

See [installation](installing-1.0.3.md) and [callbacks and Hotel Services](callbacks-and-hotels.md) for operating instructions.

Version 1.0.6 rebuilds the unchanged Android audio implementation and native Windows
service/manager with the new release version. The detailed 1.0.5 Android audio tests
above remain evidence for that implementation; a version-only rebuild does not add
physical handset, headset or network qualification.

The production Debian 1.0.5 → 1.0.6 upgrade completed through the installed updater
and final public signed feed. After native configuration regeneration and restart,
the conflicting database and XML entries both remained disabled, the converter was
active, the enabled provider was registered and extension 1000 reconnected. All
6,240 packaged web files matched the live installation, and the customer
configuration hash was unchanged. The Updates page reconnected with GET and no
expired-form error. A new authorized provider call then sustained 25.1 seconds
with 1,191 sent and 1,248 received RTP packets and no early disconnect.

The user then confirmed a real outside call from extension 1000 using Android
1.0.6 stays connected with sound in both directions. This qualifies that handset
and tested outgoing path; it does not establish every incoming route, handset,
network change or provider scenario. Both controlled-call legs also had no native
ERR/CRIT entries, and their exact test records were removed while preserving all
unrelated customer call records.

Windows also completed its installed signed 1.0.5 → 1.0.6 update. Database identity,
configuration and phone passwords were preserved; authenticated Admin/Updates and
CSRF checks passed. Two native phones registered and an internal call sustained
two-way RTP. The WinUI manager reopened in its original user session showing
1.0.6 Running and up to date. All temporary test data and scoped build access were
removed, with the original instance baseline restored.
