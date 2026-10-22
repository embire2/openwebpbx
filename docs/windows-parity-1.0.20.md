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
| Phone Health & Recovery | Native components passed16 Defender and62 SYSTEM checks; durable-intent policy passed96 isolated PostgreSQL controls. Complete source `568b3ab5f` passed installed observer/restart checks, then failed the actual ESL→Defender→SQL worker gate at firewall preflight. Separate repairs pass **26** actual Windows PHP subscription controls and **four** native empty-policy query controls, including old-source negatives. | Rebuild the complete package and pass actual event-to-block-to-recovery, negative permissions, unchanged firewall policy, restart and restore. Loopback/component checks alone do not qualify this flow. |
| Remote phones | Native .NET STUN Binding worker and setup are implemented. The current package passed33 installed Windows checks, including actual service/Defender activation, decoded modern/legacy Binding and recovery.146 separate NTFS/interruption controls use service/firewall doubles. Existing PBX-anchored audio and restored sign-in identities remain. | External test-machine Binding and phone/client acceptance; Windows IPv6 remains separate. STUN is not TURN. |
| Conferences | Corrected native engine passes all16 ordinary/fragmented small/8KiB frontend/backend OPTIONS exchanges. Browser admission reaches the engine, but media remains unqualified. A separate read-only check confirms the stock Windows engine generated an already-expired DTLS certificate through a date-calculation overflow; a guarded pre-start repair is being tested. | Qualify the certificate repair and negotiation, then decoded browser/phone audio and VP8, host actions and exact cleanup. Preserve valid custom certificates and destination-owned identity during restore. |
| Backups and restore | Scheduled-job choices are preserved. Restored pending phone-unblock requests are refused before background work resumes; other recovery history is retained. | Complete encrypted backup, same-machine failure recovery, distinct clean-server restore, media/key preservation and explicit activation. |
| Updates | New protected tools and health task are included in installation and recovery inventory. The legacy transition accepts current signed releases rather than only 1.0.13. **11** native guard controls distinguish actual Windows contention from permission/path failures; the tenant worker defers only on the typed busy result. | Rebuilt complete-package fresh setup, same-version repair, late-failure recovery and a signed newer-version upgrade with natural restart. |
| Public access | Existing trusted IIS, secure-phone and managed tenant-address implementations remain. | Actual public certificate issuance/renewal and external tenant/Android connections on the test machine. |
| Client setup and welcome mail | Shared tenant-address, app-password and profile features are implemented. A new required welcome case passes29 local real PHP/PostgreSQL/SMTP/MIME/independent QR checks and120 caller/projection controls; native Windows execution remains pending. | Pass the installed Windows welcome case, then external Android QR/manual sign-in, password change, multiple profiles and trusted-IIS role/online boundaries. |
| Existing calling suite | The unchanged-package diagnostic replay passes decoded TLS two-way calling, independent G729/PCMU transcoding and three decoded clock1026 announcements. The first fictional provider call then fails; Call Me Back and later groups, queues, voicemail121, recording, hotel and mail cases remain unqualified against this package. | Resolve the provider failure and repeat the complete native suite against the combined current-source package, including decoded media and protected-data checks. |

The owner's test machine is Windows Server 2025. Its original 1.0.6 installation
was found with PBX services stopped. Its files, logical database, permissions
and original TLS key have now been preserved and independently verified before
migration. Private access details and customer/test evidence
remain outside the public repository.

The welcome-mail case uses the actual installed PHP welcome/outbox dispatcher,
an isolated PostgreSQL schema and two concurrent queue processes. Its one
loopback message must contain matching HTML/inline QR content IDs and a
password-free setup attachment whose full JSON matches an independently decoded
QR. The installed PNG renderer must also work with `php -n`, without GD. Used
invitations must not dispatch, and every original public row and global mail
setting must remain exact. Alias custody and HTTPS readiness are explicitly
modelled only for this MIME test; they do not replace the real alias/IIS and
external Android acceptance. SMTP acceptance does not prove inbox receipt.
The decoder is a pinned private QA dependency, not a server runtime dependency.
The private database-credential copy is removed on success and failure; five
additional local controls cover interruption before state creation and unsafe
copy refusal. No customer or external recipient is used.

The test machine unexpectedly rebooted while its original file archive was
being copied, before any preview installation. A read-only comparison after the
reboot confirms all138 original public-table multisets,18 roles and506 relation
owner/permission records remain exact. The interrupted archive prefix and its
failure are retained. The missing tail was copied, one complete archive
reconstructed and all 85,383 files verified against the original ledger, then
independently repeated. The original database was cleanly aligned with its
registered Windows service, preserving all tables, roles, permissions and
configuration; other PBX services and IIS remain stopped.
The crash reports are preserved privately. This interruption is not a controlled
reboot or recovery-test pass.

The earlier complete run39835943565 at source568b3ab5f passed
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

A later unchanged-package replay retained a fresh Scheduler run whose info
still reported `267009` (running) after a separate state read returned Ready.
The qualification polling now waits for a fresh terminal result under a bounded
timer; it continues to reject genuine nonzero exits. **Eight actual Windows
Scheduler controls** reproduce the old inter-read race, pass the corrected
waiter, retain a real exit17 failure, reject stale/running results and verify
the exact SYSTEM children and owned task are removed. Fourteen portable waiter
controls also pass. This corrects QA polling and does not change the tenant
worker or qualify the old package. The first short-lived fixture exited before
ownership inspection; that refusal is retained, and the passing fixture uses a
private release-file handshake between real Scheduler snapshots.

The corrected tenant worker passes19 source/OS-lock controls and five actual
Windows SYSTEM/Scheduler cases against the final typed guard: hold/busy
deferrals return success, an actual ACL denial remains a failure and releasing
the lock permits normal work. No registry, certificate or SQL action is taken
while deferring. An intermediate fixture polling timeout is retained; its
instrumented repeat passed, with exact final source/runtime hashes and no
remaining owned task/process. Complete package tenant acceptance remains open.

The unchanged `568b3ab5f` diagnostic replay retains closed PHP
phase/class/basename/line/SQLSTATE and Scheduler result observations. It identifies
a firewall preflight refusal before subscription and proves exact failed-worker
recovery; the historical report omits the two individual firewall state values.
The replay also passes75 native tenant checks with a successful deferred task.
Continuing
to independent diagnostics requires exact timed public table/catalogue/namespace,
firewall, engine, identity and task preservation, an empty response spool,
stopped owned children and a resumed SYSTEM observer. The failed gate and
release/owner-update ineligibility remain recorded.

A further diagnostic replay39850187983 uses the same untouched package and
test-only provider observations: SIP response codes, bounded invite counts,
PCMU/PCMA offer flags and gateway-state enums. Raw SIP, credentials and customer
identities are excluded from public facts. Its source projections pass seven
Python checks and459 actual PowerShell controls; these are diagnostic controls,
not successful provider calls. It confirms caller503 while both gateways report
NOREG/UP and neither fictional provider receives an INVITE. Direct native parser
checks on Windows and Debian refute the codec-list separator hypothesis; the
local failure still needs diagnosis. This replay intentionally cannot qualify a
release, upgrade or backup.

The combined sourcee031bb10b build39851801900 exported its archive but failed
fresh installation: the new DTLS pre-start helper required a certificate folder
that the stock Windows engine has not created yet. Isolated tests had used an
existing folder. The first-install path and exact parent-directory recovery are
being corrected; no new fresh-install or conference pass is claimed. Subsequent
recovery fixes also require a rebuilt package: held newly created DTLS objects
must refuse recovery, and the helper must prove restored bytes/permissions or
absence before marking its journal recovered.

The explicit custom-event subscription, exact empty-firewall-query handling and typed maintenance-contention repairs
change product bytes. They require a newly built final Windows archive and
complete acceptance; neither the old `568b3ab5f` ZIP nor a diagnostic replay becomes a
release through these source changes. Read the [Phone Health evidence](phone-health.md#windows-server-follow-up)
for the scope of the separate **26 / 16 / 62 / 96**, read-only empty-query **four** and native guard **11** controls.

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
