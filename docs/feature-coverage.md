# OpenWeb PBX 1.0.2 feature coverage

OpenWeb PBX is a free, independently developed PBX built on FusionPBX and FreeSWITCH. Version 1.0.2 adds automatic callbacks, hotel room management, wake-up calls and native Windows installation. It does **not** implement every 3CX feature, run 3CX software or accept proprietary 3CX apps. No claim of being the world's first free PBX is made.

The Windows edition includes a C#/.NET 10 background calling service and WinUI 3 administration manager, built with Visual Studio 2026. The existing web application uses PHP and the call engine uses FreeSWITCH/Lua. This is not a complete C# rewrite. The manager opens the authenticated web Admin and is not a calling app.

## Available and tested

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

## Work still required

These are explicit gaps, not features enabled by installing 1.0.2:

- Replacement Windows, browser, iOS and Android calling apps, mobile push, headset integration and app provisioning.
- Hotel PMS/Fidelio/Mitel interfaces, guest folios, call charging, minibar entry, handset housekeeping codes and guest wake-up scheduling.
- A complete operator switchboard, wallboards, supervisor monitoring/coaching and equivalent queue analytics.
- Integrated business messaging, website chat, SMS and social messaging channels.
- Directory/calendar synchronization, enterprise sign-in and supported CRM connectors.
- Video meetings, AI transcription/summaries, voice agents and related service integrations.
- A compatible bridge/SBC deployment workflow, automated public-certificate setup on fresh installers, and tested high availability/disaster recovery.
- Full carrier qualification, emergency-call handling validation, NAT/TLS/SRTP interoperability, hardware provisioning qualification and scale/load testing.
- A complete backup/restore compatibility guarantee across 3CX versions, one-click in-place upgrades and signed Windows distribution.

Underlying upstream modules may offer additional capabilities. Their presence alone does not establish that they work through this simplified Admin or match 3CX behavior.

## Comparison references

The comparison scope follows the official [3CX feature list](https://www.3cx.com/ordering/pricing/features/), [queue documentation](https://www.3cx.com/docs/manual/call-center-queues/) and [Hotel Module documentation](https://www.3cx.com/docs/hotel-pbx/), reviewed on 7 October 2026. Product offerings can change. The implementation and verification statements above describe OpenWeb PBX itself.

See [installation](installing-1.0.2.md) and [callbacks and Hotel Services](callbacks-and-hotels.md) for operating instructions.
