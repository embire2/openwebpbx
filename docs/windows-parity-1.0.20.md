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
| Phone Health & Recovery | Native components passed16 Defender and62 SYSTEM checks; durable-intent policy passed96 isolated PostgreSQL controls. The latest complete run passed installed observer/restart checks, then failed the new actual ESL→Defender→SQL worker test. Its underlying error is being diagnosed. | Complete event-to-block-to-recovery flow, negative permissions, unchanged firewall policy, restart and restore checks. |
| Remote phones | Native .NET STUN Binding worker and setup are implemented. The current package passed33 installed Windows checks, including actual service/Defender activation, decoded modern/legacy Binding and recovery.146 separate NTFS/interruption controls use service/firewall doubles. Existing PBX-anchored audio and restored sign-in identities remain. | External test-machine Binding and phone/client acceptance; Windows IPv6 remains separate. STUN is not TURN. |
| Conferences | Corrected native engine passes all16 ordinary/fragmented small/8KiB frontend/backend OPTIONS exchanges. Browser admission reaches the engine, but SIP488 still prevents media negotiation. | Resolve negotiation, then decoded browser/phone audio and VP8, host actions and exact cleanup. |
| Backups and restore | Scheduled-job choices are preserved. Restored pending phone-unblock requests are refused before background work resumes; other recovery history is retained. | Complete encrypted backup, same-machine failure recovery, distinct clean-server restore, media/key preservation and explicit activation. |
| Updates | New protected tools and health task are included in installation and recovery inventory. The legacy transition accepts current signed releases rather than only1.0.13. | Current complete-package fresh setup, same-version repair, late-failure recovery and a signed newer-version upgrade with natural restart. |
| Public access | Existing trusted IIS, secure-phone and managed tenant-address implementations remain. | Actual public certificate issuance/renewal and external tenant/Android connections on the test machine. |
| Existing calling suite | Users, departments, groups, queues, voicemail121, recording, hotel services and mail have native fixtures. Mandatory clock1026, Call Me Back and simulated provider-failover cases are implemented in the current test suite; earlier failures have prevented their execution. | Repeat the complete native suite against the combined current-source package, including decoded media and protected-data checks. |

The owner's test machine is Windows Server 2025. Its original 1.0.6 installation
was found with PBX services stopped; its data and configuration are being
preserved before migration. Private access details and customer/test evidence
remain outside the public repository.

The current complete run is39835943565 at source568b3ab5f. Its installer passed
an independent check of every payload hash, immutable source mappings, original
native binaries, engine source, voice files and configured-secret exclusion.
These archive checks do not qualify the failed runtime tests. A privately signed
test preview is prepared for faster diagnosis on the authorised machine after
its original file archive is verified; it has not been installed or published.

The earlier native run also found a tenant scheduled-worker failure and a
backup-recovery failure while rebinding the meeting proxy. An isolated Windows
control reproduces tenant lock contention; the cause of the earlier run's
specific task result remains unproven. All failures remain part of the work
record rather than being marked complete.

Publishing Windows must retain the exact currently published Android18 and
Debian16 signed feeds. Their public bytes and signatures have been independently
verified; no new Windows release or public feed has been published during this
work. The [build guide](../packaging/BUILDING.md) describes the three-feed check.

No Windows parity release, physical-handset acceptance, carrier acceptance,
Google Play approval or complete 3CX feature parity is claimed by this record.
The roadmap remains **133 IDs / 21 accepted / 72 partial / 40 planned**. See
[Phone Health](phone-health.md), [Windows meeting transport](windows-meet.md),
[installation](installing-1.0.20.md), [updates](windows-upgrade.md),
[backups](backups.md) and [feature coverage](feature-coverage.md).
