# OpenWeb PBX feature coverage

OpenWeb PBX is a free, independently developed PBX built on FusionPBX and FreeSWITCH. Version 1.0.3 adds the standalone Android phone, QR setup and tested Debian/Windows updates to the callbacks, hotel services and native Windows installation introduced in 1.0.2. It does **not** implement every 3CX feature, run 3CX software or accept proprietary 3CX apps. No claim of being the world's first free PBX is made.

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
- A complete backup/restore compatibility guarantee across 3CX versions, broader interrupted-update/reboot recovery, a simple graphical update workflow and signed Windows distribution.

Underlying upstream modules may offer additional capabilities. Their presence alone does not establish that they work through this simplified Admin or match 3CX behavior.

## Comparison references

The comparison scope follows the official [3CX feature list](https://www.3cx.com/ordering/pricing/features/), [queue documentation](https://www.3cx.com/docs/manual/call-center-queues/) and [Hotel Module documentation](https://www.3cx.com/docs/hotel-pbx/), reviewed on 7 October 2026. Product offerings can change. The implementation and verification statements above describe OpenWeb PBX itself.

See [installation](installing-1.0.3.md) and [callbacks and Hotel Services](callbacks-and-hotels.md) for operating instructions.
