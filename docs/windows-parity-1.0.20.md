# Windows Server parity work — 1.0.20

Status on 22 October 2026: **development and native acceptance in progress**.
The currently published Windows release remains 1.0.7. Do not replace a
production server with an unpublished archive. Debian's hosted Phone Health
patch and the earlier complete Debian candidate have separate verification.

The target is the complete implemented PBX suite on native Windows Server 2025:
IIS/PHP administration, local PostgreSQL, FreeSWITCH calling, the .NET background
service, the WinUI server manager and the independent updater. Installing Linux
under Windows can provide a comparison environment; it does not qualify the
native Windows server.

| Area | Current work | Required acceptance |
|---|---|---|
| Phone Health & Recovery | Native Windows security adapter, continuous event observer, incidents, controlled recovery and global email alerts are implemented in development. | Actual Defender Firewall ownership, negative permissions, event-to-block-to-recovery flow, restart and restore checks. |
| Remote phones | Native .NET STUN Binding worker and protected setup are in development. Existing PBX-anchored audio and restored sign-in identities remain. | Windows IPv4/IPv6 UDP, external Binding, malformed/unsupported packet refusal, existing listener/rule preservation and setup recovery. STUN is not TURN. |
| Conferences | A native-engine parser defect was reproduced with delayed fragmented WebSocket messages, independently of IIS. The corrected engine compiles and passes parser/registration controls. | Before/after frontend and backend transport, decoded browser/phone audio and VP8, host actions and exact cleanup. |
| Backups and restore | Scheduled-job choices are preserved. Restored pending phone-unblock requests are refused before background work resumes; other recovery history is retained. | Complete encrypted backup, same-machine failure recovery, distinct clean-server restore, media/key preservation and explicit activation. |
| Updates | New protected tools and health task are included in installation and recovery inventory. | Current complete-package fresh setup, same-version repair, late-failure recovery and a signed newer-version upgrade with natural restart. |
| Public access | Existing trusted IIS, secure-phone and managed tenant-address implementations remain. | Actual public certificate issuance/renewal and external tenant/Android connections on the test machine. |
| Existing calling suite | Users, departments, trunk/routing controls, groups, queues, callbacks, voicemail121, Nathaniel clock1026, recording, hotel services and mail retain their existing native tests. | Repeat the complete native suite against the combined current-source package, including decoded media and protected-data checks. |

The owner's test machine is Windows Server 2025. Its original 1.0.6 installation
was found with PBX services stopped; its data and configuration are being
preserved before migration. Private access details and customer/test evidence
remain outside the public repository.

No Windows parity release, physical-handset acceptance, carrier acceptance,
Google Play approval or complete 3CX feature parity is claimed by this record.
The roadmap remains **133 IDs / 21 accepted / 72 partial / 40 planned**. See
[Phone Health](phone-health.md), [Windows meeting transport](windows-meet.md),
[installation](installing-1.0.20.md), [updates](windows-upgrade.md),
[backups](backups.md) and [feature coverage](feature-coverage.md).
