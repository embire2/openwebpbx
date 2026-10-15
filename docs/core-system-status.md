# OpenWeb PBX core system status

The hosted instance received a provider-setup patch on 2026-10-15: **Voice & Chat** now finds incoming addresses from the provider server name, with an optional override under Advanced and automatic discovery when Port is blank. Fifteen normal HTTPS checks and six desktop/mobile layouts passed; the temporary PBX was removed and all existing customer/provider settings were preserved. This patch is in current source and the hosted instance; immutable 1.0.12 downloads are unchanged. Wider SETUP-01/02 and CALL-01 acceptance remains open.

Status date: **2026-10-15**. Latest verified public Debian/Android baseline: **[1.0.12](https://github.com/embire2/openwebpbx/releases/tag/v1.0.12)** at immutable tag `061f83c81`. Eight complete public downloads/signed sequence-112 feed, original installed-worker HTTPS upgrade/all 7,113 mappings/customer preservation, trusted owned phone domain, seventeen global minimum-release checks and full homepage qualification passed. Five focused exact direct-APK and one exact AAB-derived native cases passed; physical phones/carriers and the recorded broader limits remain open.


OpenWeb PBX has a working multi-tenant voice server, a native Android calling app and controlled installation/update/recovery workflows. Complete 3CX feature equivalence remains unfinished. This report separates working product capabilities from the wider acceptance goals in [the maintained roadmap](../3CX.md). [Feature coverage](feature-coverage.md) contains the detailed dated verification record.

## Windows Server return

The [Windows 1.0.13 release plan](../3CX.md#windows-1013-release-plan) lists the remaining ordered checkpoints, parallel qualification work, dependencies and pass criteria. The supplied server remains on 1.0.6 until the controlled upgrade is qualified.

Windows 1.0.13 targets the complete core suite on Windows Server 2025 with the .NET 10/Visual Studio 2026 service, updater and WinUI administration manager. Isolated runs have passed fresh/all 14,095 mappings, complete native calling/audio and the complete encrypted backup workflow, including interrupted recovery, SFTP, restored settings/media/keys, database preservation and trusted phone TLS. Earlier runs passed reapply, forced rollback, held startup and both manager reopen paths. The latest full run failed a numeric process-ID assertion; its cause is unobserved. Qualification now pins the actual original process and retains every reopened-window requirement. Focused native Windows manager/worker identity and lifetime controls passed. The combined repeat, separate-server restore, signed newer updating, outside certificates, actual owner upgrade, Android-to-Windows calling, OS boot and publication remain open. See [candidate guide](installing-1.0.13.md) and [coverage](feature-coverage.md#windows-server-return--1013). The Debian/Android 1.0.12 baseline, hosted provider patch and all 133 task classifications retain their existing status.

## Current restore-to-phone work

Version 1.0.12 implements preserved source identities, owned public phone addresses, source group/queue orders, caller-local queue deadlines, stable live queue state, Ring My Mobile and an atomic provider/number handover action. Exact backup inventory and original-phone registration/internal audio checks have passed. Fresh/installed-upgrade/forced-rollback and twelve browser layouts passed with 7,113 exact mappings. Five final direct and one exact AAB-derived Play cases passed the new network correction; publication and production deployment passed; physical/carrier qualification remains in progress; [the coverage record](feature-coverage.md#restore-and-desk-phone-handover--1012) records actual evidence and limits. The 72 partial/qualification and 40 planned counts are unchanged; implemented subsets do not close their wider acceptance conditions.

## Exact roadmap counts

| Report category | Entries | Definition |
| --- | ---: | --- |
| Built / accepted | 21 | Checked roadmap entries whose stated baseline acceptance was verified. |
| Partial / qualification | 72 | Open entries labelled Partial, Verify or Needs input, plus the seven open Android acceptance entries without a label. Working subsets may already be available. |
| Planned / unintegrated | 40 | Open entries labelled Build or a mixed Build/Verify label. The requested complete OpenWeb equivalent has not been established; upstream code or related building blocks may exist. |
| **Total** | **133** | **21 checked and 112 open; no checkmarks changed for this report.** |

The open labels comprise **47 Partial, 16 Verify, two Needs input, seven unlabelled Android acceptance entries, 34 Build and six mixed Build/Verify entries**. These counts classify acceptance goals, not equally sized features, and are not a completion percentage. A working hold button or backup helper does not close a broader device, migration or platform matrix.

| Area | Total | Accepted | Partial / qualification | Planned / unintegrated |
| --- | ---: | ---: | ---: | ---: |
| Delivered foundations (BASE) | 11 | 11 | 0 | 0 |
| Setup and administration (SETUP) | 7 | 0 | 7 | 0 |
| Calling and providers (CALL) | 10 | 0 | 9 | 1 |
| Queues and operator tools (QUEUE) | 8 | 0 | 8 | 0 |
| Calling apps (APP) | 21 | 7 | 10 | 4 |
| Desk phones and remote offices (PHONE) | 6 | 0 | 4 | 2 |
| Migration and backups (RESTORE) | 10 | 0 | 9 | 1 |
| Hotel Services (HOTEL) | 10 | 0 | 4 | 6 |
| Tenants and templates (TENANT) | 6 | 0 | 6 | 0 |
| Reports and media (REPORT) | 6 | 0 | 4 | 2 |
| Business integrations (INTEGRATION) | 6 | 0 | 0 | 6 |
| Messaging (MESSAGE) | 7 | 0 | 0 | 7 |
| Meetings (MEETING) | 3 | 0 | 0 | 3 |
| AI services (AI) | 4 | 0 | 0 | 4 |
| Platforms and operation (PLATFORM) | 10 | 1 | 6 | 3 |
| Feature mapping (SCOPE) | 1 | 0 | 1 | 0 |
| Release acceptance (RELEASE) | 5 | 0 | 4 | 1 |
| Website (WEB) | 2 | 2 | 0 | 0 |

## Working product capabilities

These are implemented and tested subsets. Their linked wider roadmap goals can remain open.

| Product area | Built behavior | Roadmap IDs and practical limits |
| --- | --- | --- |
| Administration desktop | Searchable permission-filtered launcher, movable/resizable windows, maximize/minimize/snap/taskbar, theme/wallpaper, clock/calendar, embedded Admin and scoped live counts | BASE-01, SETUP-02; broad independent usability/accessibility acceptance remains open. |
| Tenants and PBX services | Invite-only onboarding, expiring single-use invitations, separate PBX realms, membership/owner checks, encrypted shared/owned templates, transactional/idempotent provisioning and service limits | BASE-03, TENANT-01–06; complete staff roles, suspension of existing SIP accounts and resource quotas remain open. |
| Guided setup | Company/users/provider/routing setup, atomic disabled provider/main-number/hours/outgoing-rule creation, optional existing backup provider, First Calls readiness and ordinary-route preview | BASE-04, SETUP-01; independent new-administrator and real public first-call acceptance remains open. |
| Users and call handling | Users, departments, forwarding/status profiles, ring groups, receptionist menus/PIN flows, contacts, greetings and protected prompt upload/playback | BASE-04–06, CALL-04–06, RESTORE-09; supported imported objects and known source limits only. |
| SIP providers | Separate authentication/REGISTER, transport/port/realm/auth-ID/proxy/expiry, concurrency/codecs, identity headers, DID source settings, masked editing and DNS/TCP/TLS/native readiness | CALL-01/02, RESTORE-02/04; registration/connectivity alone does not qualify calls. |
| Incoming/outgoing routing | Prefix/length/strip/prepend, provider ordering/fallback, busy-stop, caller-ID/header handling, configured DID/tenant/source-IP gates, caller blocking and explicit emergency routes | CALL-01/02/06/07; local-provider media/failure tests passed, broad real-carrier and emergency checks remain open. |
| Hours | Multiple/overnight periods, breaks, holidays, timezones, temporary Open/Closed and date/time destination preview | CALL-04; actual forced-open/closed ingress passed; full DST/restored/new-PBX boundary matrix remains open. |
| Switchboard and parking | Tenant-owned live calls/people/presence with permission-checked hold/resume, transfer, park/pickup and end through connected phones | CALL-03, QUEUE-07; actual native media passed; browser audio and complete simultaneous-receptionist acceptance are not delivered. |
| Queues and agents | Strategy/priority groups, capacity/overflow, tracked position/wait estimate, periodic messages, native agent state and Ready/Break/Sign Out/assigned membership controls | QUEUE-03–06, APP-21; top-down/native/status cases passed; broader strategies/localization/supervision matrix remains open. |
| Durable callbacks | Request/timed-offer/automatic modes, agent-first delivery, retries/expiry/cancellation/offline waiting, ordinary outgoing routing and Original Position/Live First choices | BASE-07, QUEUE-01/02; local-provider failover/digest/media passed; mixed restart/starvation and carrier callbacks remain open. |
| Wallboard and queue reports | Scoped waiting/agent totals, service-target in-page alert, completed visits and callback results over 24 hours, seven days and 31 days | QUEUE-08, REPORT-01; answered/callback reconciliation passed; full missed/transferred/timezone/cost totals and external alerts remain open. |
| Voicemail | Native greeting/record/check dispatch, indexed mailbox audio, protected web/mobile playback/read/delete, PIN/greeting selection and privacy checks | APP-12, CALL-05; complete shared-mailbox, phone-menu/notification/retention acceptance remains open. |
| Recording/history | User/queue/outgoing recording flags, automatic native recording indexing, protected playback and supported imported personal history | REPORT-03/04; consent/pause/resume and full retention/archive lifecycle remain open. |
| Native Android calling | Native Kotlin/Linphone UI, one-use QR/code/device credentials, Keystore, TLS/SRTP, incoming/outgoing, mute/speaker/hold/resume/DTMF, directory/Recents and voicemail; 1.0.11 adds visible hold and personal theme/ringtone/startup/sorting/reset Settings | APP-07–12; final 1.0.11 direct-APK Settings/persistence/hold tests passed; hardware/camera/network/battery matrix and other native platforms remain open. |
| Android advanced controls | Consultation/cancel/failure recovery, blind/attended transfers, second-call handling, three-way switch/merge/removal, reconnect, temporary status and per-queue controls | APP-17–21, CALL-03; actual native media/state cases passed, full carrier/history/device matrices remain open. |
| Optional Android wake-up | Automatic stable VAPID keys, source-available UnifiedPush/native distributor, encrypted incoming/ended events, subscription rotation and optional Cloudflare ciphertext relay | APP-17; configuration/crypto/worker tests passed. Real locked/idle Google delivery and deployed relay qualification remain open. No user Firebase project is required. |
| Hotel basics | Room check-in/out, guest record/status/DND, vacant-room outside-call restrictions, mailbox/PIN/greeting reset and audit | BASE-08, HOTEL-01/02/09; no completed PMS, charging, minibar or handset-housekeeping equivalent. |
| Scheduled wake-up calls | Durable administrator jobs, announcement, DTMF 1 confirmation, bounded retry/expiry/result history | BASE-09, HOTEL-03/10; guest self-scheduling and PMS scheduling remain planned. This is separate from Android push wake-up. |
| Outgoing email | Shared global relay, IP or password authentication, masked secrets, sender/Reply-to enforcement and protected native queue waiting/retry | BASE-10, SETUP-05; local wire tests passed; configured Google relay rejects sender and real inbox delivery is unqualified. |
| V20 migration | Bounded ZIP/XML analysis, encrypted administrator-owned drafts, explicit confirmation/idempotency, supported calling objects/media and actionable Restore Report | BASE-05, RESTORE-01–05/09/10; verified native baseline is only 20.0.9.995; encrypted/other builds and missing source items remain open. |
| Encrypted backups | Scheduled/manual configuration/keys/database/optional media, password protection, verification/retention, protected downloads, pinned-key SFTP and clean separate-Debian restore with activation holds | RESTORE-06–08; actual independent Debian restore passed on a historical factory stack; notifications, broader storage and Windows portability remain open. |
| Managed server updates | Independent C# signed-feed worker, complete hash/signature validation, idle/window guards, private recovery inventory and rollback | PLATFORM-10, PLATFORM-03; historical Windows/Debian upgrades and Debian 1.0.10 fresh/upgrade/two-rollback checks passed; broader power-loss/endurance remains open. |
| Managed Android updates | Prominent voluntary/automatic/required policies, signed direct APK verification/install, active-call deferral, urgent-call bypass and separate Play store handoff | APP-13/15; actual public 1.0.7→1.0.10 passed with supported manual Open. The production instance minimum 1.0.11 passed nineteen HTTPS/API checks; genuine public 1.0.10→1.0.11 replacement passed with supported manual reopening, and broader clients/Play approval remain open. |
| Hold music | Bundled CC0 lo-fi source/provenance, normalized telephone audio and four native sample rates; custom selections preserved | CALL-03; actual held-phone RTP matched 9.98 seconds at 0.895 energy-envelope correlation. |
| Distribution and review | Debian/Android packages, historical Windows manager, corresponding source/checksums/signed feed, isolated internal-only review portal and public privacy/support/removal pages | BASE-11, APP-16, PLATFORM-05, WEB-01/02; no approved Google Play listing, Windows 1.0.9/1.0.10/1.0.11 package, Windows calling app or complete C# rewrite. |

## Evidence and platform limits

| Evidence | Actual result | Boundary |
| --- | --- | --- |
| Core calling 1.0.9 | 48 PostgreSQL, 149 policy, 75 runtime, 19 actual native and 21 HTTPS checks; seven core screens in light/dark at 320/390/1440px | Local native/media/scoping proof, not broad carrier or independent-user acceptance. |
| Availability | 48 isolated PHP and 19 worker checks, actual native expiry/retry and Android status/queue agreement | Full concurrent/device/office-hour matrix remains open. |
| Wake-up 1.0.10 | 34 PHP, 65 C# and 27 Worker checks; 14 fresh, 16 upgraded and 18 hosted real HTTPS save/reload/permission checks | Stable configuration/crypto is not physical locked/idle delivery. Production generated a new identity; the clone preserved an existing one. |
| Backups | 42 PHP and 13 original Python scenarios plus independent source/target native restoration; the 1.0.10 repeat passed fourteen scenarios with the unchanged SFTP scenario skipped | Original actual loopback SFTP remains historical; real remote infrastructure/Windows restore not qualified. |
| Debian 1.0.10 | Full fresh/installed-1.0.9 upgrade, two exact signed failure rollbacks and all 7,096 hash/mode/service/timer mappings | Production reused an atomically seeded verified cache package; full C# HTTPS download passed separately on the isolated clone. |
| Android 1.0.10 | 25 direct/29 Play JVM checks plus lint/signature/alignment checks; five exact direct and three exact AAB-derived Play native cases with relevant independent peer RTP | Earlier twelve direct/three Play 1.0.9 cases remain exact-artifact history; physical route/proximity/network/push and Play approval remain open. |
| Public update 1.0.10 | Genuine pinned public 1.0.7 feed/APK download/install confirmation, exact installed hash, retained account/extension and TLS return | Completion used manual Open; automatic notification reopening was not qualified in that run. |
| Public distribution 1.0.10 | Eight full SHA-matching downloads, signed sequence-110 envelope, 38,406 tracked SDK entries, 88 Android entries, 42 source JARs, fourteen website files and actual browser checks | The original 1.0.9 source filter omitted 465 tracked inputs; notes now link corrected same-SDK 1.0.10 source without changing old tag/assets. |
| Debian/Android 1.0.12 | Supported-source inventory 23, native source cases 65, normal HTTPS 37, outbound preservation 9, canonical registration 756/owned addresses 693/answered alias audio 11; core native cases 48, policy/runtime 198/137; fresh/installed upgrade each 7,113 mappings, forced recovery and twelve browser layouts | Five exact direct/one derived-Play native network/control cases passed; long Settings UI repeat and remote disconnected-call cleanup remain unqualified. Publication/production passed; physical W60B/V62W and customer network/carrier remain open; see current coverage. |
| Debian/Android 1.0.11 | 65 PostgreSQL checks; fresh/installed-upgrade each 23 HTTPS/API checks, 7,096 mappings and internal RTP; signed rollback/fourteen notification checks; 29 direct/33 Play JVM and six direct/four derived-Play native cases; all eight public hashes/feed/source, production 7,096 mappings and nineteen minimum-policy checks | Production reused its exact verified public cache package; full C# HTTPS download passed on the clone. Genuine public phone replacement and scoped native cleanup passed with supported manual reopening; hardware/carrier/Play approval remain open. |
| Windows | Server 2025 Desktop Experience native installation/calling/upgrade evidence through 1.0.6; 1.0.7 build/manager/export/protocol/updater evidence | No 1.0.9/1.0.10 Windows package, Windows 10/11 server qualification or Windows softphone. |

The source still uses PHP administration and FreeSWITCH/Lua call handling alongside the C# background service/updater and historical WinUI manager. A complete C# application rewrite is unfinished. Binary 16-KiB alignment is not Android 16 runtime qualification. The existing provider's successful outside path and owner-confirmed 1.0.6 speech do not establish every incoming/provider/device path.

## Version 1.0.11 publication and qualification

The 1.0.11 implementation adds a full-width **Call Hold / Resume Call** action to every active-call tab and pauses both SIP legs while a three-way call is held. Hold/resume already exists under APP-10; this update improves visibility and conference behavior. A reproduced resume failure was corrected by entering the rebuilt conference synchronously after adding both paused legs. The final exact signed APK (`9f23be7940bc…`) passed visible hold/reset while held in 76.051 seconds, strict three-way hold/music/resume/remote departure in 72.814 seconds and manual hold/switch/back/end-second automatic original recovery in 23.960 seconds. Strict proof includes joined local audio, both legs StreamsRunning with send/receive directions, advancing RTP counters, positive fresh bandwidth and independent peer media. Outgoing/background/audio focus (45.412 seconds) and incoming SDK ringing/media focus (18.363) also passed, for six final direct cases. These results supersede earlier candidate-byte timings.

Independent remote captures qualified direct hold music for 53.80 seconds on a single call, 19.92 on both conference legs and 10.08 on the remaining leg. Every overlapping ten-second/trailing window passed the unchanged 0.75 threshold (minima 0.8368/0.8424/0.8336), together with continuous RTP, capture hashes, loop-offset identity and music ending on Resume. The full fixed-offset single-capture correlation failed at 0.593 and remains recorded as a long-loop matcher limitation. Play captures independently passed every window for 20.12/20.10 and 10.18 seconds. This evidence does not qualify physical handset audibility.

The new **Settings** page provides System/Light/Dark appearance, an Android ringtone picker, keypad haptics, four startup pages and Name/Extension contact sorting. It also exposes read-only account/version details; existing status, queue, audio, connection and update controls; Android microphone/alert/battery shortcuts; privacy/licenses; and reset of personal preferences without removing account or trust data. Ringtone choices exclude Silent, invalid and network sounds, and the calling SDK retains sole audio focus. The final direct-APK test passed in 104.003 seconds: canonical Andromeda selection and unreadable-sound fallback on the same Core each retained incoming two-way RTP; all four startup pages survived cold relaunch, and theme/sorting/haptics/reset preserved account and update trust. The broader APP-07/APP-04 goals remain open.

The instance minimum-release floor maps to APP-15/PLATFORM-10. Sixty-five disposable PostgreSQL checks cover existing/future tenants and unassigned phones, preserved tenant preferences, an inactive five-field API and active-floor fields. Fresh Debian under umask 077 and the actual installed-1.0.10 independent-worker signed HTTPS upgrade each passed 23 normal HTTPS/CSRF/API-floor-scope checks, all 7,096 file/hash/mode/service/timer mappings and sustained two-way internal RTP. A signed forced migration failure restored the previous 1.0.10 state, including removal of the new floor column/value. Fresh default notification saving also passed fourteen HTTPS checks. The floor starts inactive; isolated fixture/floor cleanup passed. Production normal CEO HTTPS/CSRF activated minimum 1.0.11 and passed nineteen checks for existing Notify tenants, unassigned phones and future tenants, while preserving preferences and refusing unauthorized changes. Four clone-only reset/default cases were omitted to keep the live floor active; owned fixtures were removed. Genuine public phone replacement passed exact bytes/account retention, supported manual reopening, TLS and a 43.304-second native SRTP/media call.

Actual fresh installation exposed inherited mode-700 private publish roots causing systemd 200/CHDIR for the `www-data` service. The packager and installer now supply mode-755 service-program roots; a focused real-packager regression and the fresh repeat passed while private build roots stayed mode 700. A root-only upgraded updater slot's retained legacy mode 700 remains safe. Private state permissions and historical published artifacts are unchanged.

Published immutable `15e1edcd1` at 14:38:05 UTC, the eight complete public assets and signed sequence-111 feed passed. Production's original installed-1.0.10 updater completed verification/preflight/install/natural restart at 14:42 UTC using an atomically seeded exact public/hash-verified cache package; it did not itself complete the full C# HTTP download, which the isolated clone proved separately. Protected customer/reviewer/database preservation passed 23 users, nineteen gateways, 137 routes and all 801 detail rows. PORTA is registered/up, codecs are correct and calls are zero; all 7,096 live hash/mode/owner/inventory mappings, seven services, timer and private recovery checks passed.

The final source inventories contain 38,406 SDK/95 Android/42 JARs and 113 engine-source tracked/7,793 unchanged vendor entries. The Play packet has 24 files/23 internal checksums/eight fictional-account images. The public homepage passed fourteen files, 38 links, eight assets, twelve dialogs, four support pages, TLS/private paths/historical video HTTP 206 and light/dark 1440/390/320px browser checks with zero errors. Runtime/tag/asset bytes remain frozen; this later documentation records their actual evidence.

Genuine public Android 1.0.10→1.0.11 replacement passed an untouched old app/userdata, pinned-feed/HTTPS download without seeded/partial cache, exact installed APK/account-token hash retention and receiver completion before verification. The eligible Android 13 software device installed unattended; the first runner termination was expected package replacement, not an app Java crash. Reconnection used the supported manual launcher; automatic UI/notification reopening is not qualified. A 43.304-second post-update internal native SRTP/background/audio-focus/hold/resume call passed with independent peer media. This does not qualify unattended installation on every physical device.

Owned native/domain/account/CDR/restore/media/contact/tenant/owner cleanup returned zero. Seventy-five preserved REGISTER IDs in one bounded batch, two peer contacts and one exact-realm Android contact were removed; peer units, the owned Android environment and four labelled firewall exceptions stopped. Two owned ADB authorizations were removed. The exact original `adb_keys` prefix and original metadata remain, together with a foreign authorization matched to the unchanged existing host key; the whole file is not byte-identical. Original ADB5037/host key, unrelated binary-store entries and production services were preserved.

Final 15:04 UTC production HMAC/readiness passed customer 23 users/19 gateways/137 routes/all 801 details, 23 mailbox records/12 queues/15 agents and tiers, DB roles/grants/credentials/scoped settings and permanent reviewer. Service/version 1.0.11 is Running with zero calls, PORTA registered/up and codecs ready. Ordinary extension 1000 is registered; its mobile contact is offline and physical-phone/carrier qualification remains open.

The official [3CX Android manual](https://www.3cx.com/user-manual/installation-android/), reviewed on 13 October 2026 and updated on 30 September 2026, describes account/theme/personalization and advanced audio/ringtone/battery settings as well as status and broader conferencing/messaging workflows. OpenWeb's settings scope is recorded from its own implementation and tests; these references do not establish equivalent video/chat/voice-assistant or hardware behavior.

Required direct updates retain Android install-confirmation/manual-open and active-call/urgent-call limits. The final AAB (`ad47ad9b7df4…`) passed signed verification/universal conversion and four exact derived-Play cases: manual switch (23.104 seconds), Settings (132.242), conference/departure (72.208) and outgoing focus (43.338). Both builds passed 29 direct/33 Play JVM checks and zero-error lint; eight refreshed fictional-account screenshots include visually reviewed light/dark Settings and held-call screens. Final source/submission-packet checks passed: 38,406 exact SDK entries including 456 build inputs/eleven safe symlinks, 95 Android inputs, 42 source JARs and a 24-file/23-checksum/eight-screen Play packet without private inputs or the historical video. The Play client cannot claim a required published store update before Google approval. Missing browser/iOS/Windows calling clients cannot be described as upgraded. Production tenant/default API scope passed nineteen checks with minimum 1.0.11 retained; genuine public phone replacement passed exact bytes/account/TLS retention and the supported manual launcher.

## Built / accepted roadmap entries — 21

These 21 checkmarks retain the stated baseline boundaries. Later wider tasks remain open.

| ID | Accepted goal | Actual basis and limit |
| --- | --- | --- |
| BASE-01 | Branding and desktop administration | Permission-filtered desktop and Admin; desktop/mobile light/dark browser checks. |
| BASE-02 | Production HTTPS and administrator | Trusted production HTTPS and renewal dry run; automatic fresh-server certificates remain SETUP-03. |
| BASE-03 | Tenants and templates | Invite-only tenants, scoped services and encrypted templates; PostgreSQL/live isolation checks. |
| BASE-04 | Guided setup and administration | Guided setup and supported object editors; parser, mapper, HTTPS and browser checks. |
| BASE-05 | Observed V20 backup import | Observed V20 Update 9/build 20.0.9.995 configuration/private-media import; other builds remain open. |
| BASE-06 | Internal calling | Internal, ring-group, queue and receptionist calls with two-way RTP; broader carriers remain CALL-01. |
| BASE-07 | Automatic callbacks | Agent-first callback delivery/retry/expiry/offline waiting passed on Windows and Debian. |
| BASE-08 | Hotel basics | Guest check-in/out, room status/DND/vacant restrictions and mailbox reset; no PMS/billing parity. |
| BASE-09 | Administrator wake-up scheduling | Administrator wake-up delivery with DTMF confirmation and bounded retries on both platforms. |
| BASE-10 | Shared outgoing mail settings | Shared SMTP/IP/password modes; local wire tests. Real Google sender/inbox delivery remains SETUP-05. |
| BASE-11 | Native installation and release | Published native Windows/Debian installation baseline; newer server packages target Debian only. |
| APP-08 | Native QR setup | One-use QR/code enrollment, device credentials, TLS/Keystore checks; physical camera matrix remains open. |
| APP-09 | Native incoming and outgoing voice | Actual native TLS/SRTP incoming/outgoing calls; one owner-confirmed outside path on 1.0.6. |
| APP-10 | Everyday native call controls | Native mute/speaker/hold/resume/DTMF with real media. Visible front-page hold work is tracked below. |
| APP-11 | Company directory and recent calls | Scoped company directory and Recents; native contact dialing/redial passed. |
| APP-12 | Native voicemail | Protected native voicemail playback/read/delete and cancellation/rotation privacy checks. |
| APP-13 | Managed Android updates | Signed direct update and account retention; Play uses store handoff with no approved listing claim. |
| APP-15 | Prominent and required Android updates | Prominent required-update controls/call deferral; OS confirmation/manual reopen limits remain explicit. |
| PLATFORM-10 | Automatic server updates | Independent signed updater, verified downloads, idle/window guards, recovery on Windows/Debian. |
| WEB-01 | Homepage and current release catalogue | Public release catalogue/desktop controls; 1.0.11 fourteen-file/eight-asset/link/browser verification. |
| WEB-02 | Publish on openwebpbx.com | Trusted openwebpbx.com publication and canonical/security checks; existing DNS/mail preserved. |

## Partial / qualification roadmap entries — 72

The third column is the remaining acceptance target. Existing working components are described above and in the linked guides; an open goal is not an assertion that nothing has been built.

| ID | Goal | Remaining acceptance target |
| --- | --- | --- |
| SETUP-01 | Finish the first-call wizard | A new administrator can complete it without editing files, SQL or call-engine settings. |
| SETUP-02 | Keep everyday screens simple | Ordinary tasks never require the legacy technical editors. |
| SETUP-03 | Automatic public HTTPS | A clean public Windows and Debian installation obtains and renews a trusted certificate through setup. |
| SETUP-04 | Network and firewall check | Deliberate faults are detected on local and remote-phone test networks and rerunning the check confirms the repair. |
| SETUP-05 | Complete outgoing mail setup | Both supported authentication modes are qualified with suitable relays and delivery to test inboxes is confirmed. |
| SETUP-06 | User onboarding and account recovery | An invited user can activate, recover and protect an account without an administrator exposing a password. |
| SETUP-07 | Bulk changes and accessible help | Failed rows are explained and desktop/mobile workflows remain usable with assistive input. |
| CALL-01 | Real provider qualification | A published provider/model matrix records passing results; enable restored trunks only as their configuration is validated. |
| CALL-02 | Route and provider failure handling | An unavailable first route reaches the correct backup route for ordinary calls and callbacks without duplicate calls or cross-tenant routing. |
| CALL-03 | Everyday call controls | Real endpoints produce the expected audio and call history for each flow on both platforms. |
| CALL-04 | Hours and forwarding consistency | New and restored PBXs route the same test calls to the expected destinations at every boundary. |
| CALL-05 | Complete voicemail workflows | Users can record/select greetings and manage messages from phones and apps, and shared messages reach only intended recipients. |
| CALL-06 | Caller rules and number blocking | Imported and newly created rules pass positive and negative call checks. |
| CALL-07 | Emergency calling | Provider-approved test procedures verify routing under restrictions and provider failure; do not use live emergency numbers for routine tests. |
| CALL-08 | Phone-network compatibility | A published compatibility matrix includes real devices and both server platforms. |
| CALL-09 | Fax and analogue equipment | Supported equipment sends/receives actual test faxes, fax email delivery works, and documented analogue calling flows pass. |
| QUEUE-01 | Callback place in the queue | Mixed waiting/callback scenarios follow the selected equivalent policy across restarts without starvation or duplicate delivery. |
| QUEUE-02 | Finish outside callbacks | Real carrier callbacks connect with two-way audio, bounded retries and an accurate result; depends on CALL-01/02. |
| QUEUE-03 | Queue announcements | Callers hear correct, localized announcements as the queue changes, including imported settings. |
| QUEUE-04 | Routing choices | Deterministic multi-agent scenarios demonstrate the chosen order and limits. |
| QUEUE-05 | Agent controls | Agent state remains consistent across concurrent calls, devices, status changes and reconnects. |
| QUEUE-06 | Supervisor calling tools | Real audio tests prove who can hear whom and unauthorized users are refused. |
| QUEUE-07 | Receptionist switchboard | A receptionist can manage simultaneous calls without opening engine-specific screens. |
| QUEUE-08 | Wallboard and service alerts | Displays and notifications reconcile with actual calls and the reports in REPORT-01. |
| APP-04 | Android app | Signed builds handle background restrictions, battery-saving modes and network changes on a published device matrix. |
| APP-05 | Simple app activation | A user provisions a replacement app without typing technical phone credentials and a revoked device loses access. |
| APP-07 | People, presence and personal settings | Changes propagate to apps/phones while respecting company and department visibility. |
| APP-14 | Ear protection during calls | Real handset near/far proximity and supported audio-route checks. |
| APP-16 | Google Play publication | Verified account, required tests, Google review and approved public listing. |
| APP-17 | Incoming-call wake-up | Real locked/idle Answer/Decline/cancellation and battery restrictions. |
| APP-18 | Connection recovery | Supported device matrix including physical Wi-Fi/mobile handover. |
| APP-19 | Call transfers | Internal/external transfers with audio and independent complete history. |
| APP-20 | Call waiting and three-way calling | Complete final-build media, teardown and independent-history case matrix. |
| APP-21 | Availability and queues | Full isolation/concurrency/expiry and Android/Admin routing/agent-state agreement. |
| PHONE-01 | Supported phone catalogue | Each listed model has a tested firmware version, provisioning steps and supported-feature record. |
| PHONE-02 | Easy phone setup | A reset supported phone joins the intended tenant and cannot download another phone's credentials. |
| PHONE-05 | Phone buttons and shared desks | Button state and a user's identity follow the intended phone without leaving the previous user's data behind. |
| PHONE-06 | Paging and intercom | Real phones obey permissions, target groups and audio direction. |
| RESTORE-01 | Resolve the supplied backup's remaining items | Each Restore Report entry has a verified resolution or a clearly accepted source-data limitation; do not silently delete warnings. |
| RESTORE-02 | V20 version/feature matrix | Every declared supported build has repeatable import and post-import call results, with unmapped fields reported. |
| RESTORE-04 | Guided migration reconciliation | A new administrator can resolve each supported migration step without editing database records. |
| RESTORE-05 | Import failure and rollback checks | Failures leave existing services intact, retries cannot duplicate a service and private temporary files expire correctly on both platforms. |
| RESTORE-06 | OpenWeb backups | It restores an independent working PBX, including encrypted settings. |
| RESTORE-07 | Remote storage | Uploads, integrity checks, rotation, download and restore work after a connection failure. |
| RESTORE-08 | Windows/Debian portability | File paths, ownership, scheduled jobs, media and call behavior survive the move. |
| RESTORE-09 | Custom call flows | Supported flows are recreated and tested, while unknown source programs receive an actionable migration report. |
| RESTORE-10 | Replacement accounts and services | An administrator sees exactly what needs reconnecting and can finish it; source licenses, tokens and executable services are not reusable equivalents. |
| HOTEL-01 | Guest identity on phones | Reprovisioning updates the actual room phone and the next guest sees no previous identity. |
| HOTEL-02 | Finish guest-data clearing | Checkout enforces the selected policy in indexes, private media and archives; 1.0.2 clears mailbox indexes but retains private audio under operator retention. |
| HOTEL-09 | Front-desk permissions and workflow | Staff can perform their tasks without broader PBX privileges and all guest-affecting actions are traceable. |
| HOTEL-10 | Full hotel acceptance test | Phone, PMS, billing and privacy results agree; depends on the preceding hotel tasks and CALL-07. |
| TENANT-01 | Complete template contents | A tenant creates a service with the expected complete setup and fresh per-service secrets. |
| TENANT-02 | Friendly template editing | An administrator can publish a usable template and its existing services remain unaffected by later edits. |
| TENANT-03 | Granular staff roles | Each role can perform its documented actions and is denied every cross-role/cross-tenant action outside that scope. |
| TENANT-04 | Suspension and service limits | Operators can see and verify the effect; current tenant suspension alone does not disable existing SIP accounts. |
| TENANT-05 | Tenant domains and resource usage | One tenant cannot consume another's allocation or obtain its data. |
| TENANT-06 | Isolation across new features | Two tenants using identical extension numbers remain isolated through every supported interface. |
| REPORT-01 | Complete calling and queue reports | Totals reconcile to known completed, missed and transferred test calls in each timezone. |
| REPORT-03 | Recording controls | Internal, outside, queued and transferred calls record exactly the permitted portions. |
| REPORT-04 | Media lifecycle | Playback permissions and retention remain correct after moves, restores and guest checkout. |
| REPORT-06 | System health and alerts | Injected failures produce useful tenant-appropriate alerts without exposing secrets. |
| PLATFORM-01 | Complete the C# application work | All promised C# application workflows run on both OSes; document any retained native FreeSWITCH engine separately. |
| PLATFORM-02 | Finish the WinUI administration experience | Normal install, connect, update and recovery workflows are tested in Visual Studio 2026 builds on supported Windows Server releases. |
| PLATFORM-03 | In-place upgrades and rollback | Upgrading from 1.0.2 preserves tenants, credentials, media and calling, and an interrupted update can recover without rerunning a fresh installer. |
| PLATFORM-05 | Reproducible builds and release automation | Automated tests, dependency inventories, license checks, hashes and private-data exclusions run before publication. |
| PLATFORM-07 | Capacity and endurance | Resource limits, recovery after overload and recommended hardware are published from measurements. |
| PLATFORM-08 | Supported deployment matrix | Every advertised combination has evidence. |
| SCOPE-01 | Maintain a complete feature-to-test map | No baseline feature is unclassified and every claimed equivalent has repeatable evidence. |
| RELEASE-01 | End-to-end regression suite | Both platform release candidates pass and test records are removed without changing customer data. |
| RELEASE-02 | Access and abuse controls | Permission and isolation checks cover successful and denied operations, including recordings and APIs. |
| RELEASE-03 | Prove setup simplicity | Both OS workflows need no developer intervention; record task times and fix observed stumbling points. |
| RELEASE-04 | Free and maintainable distribution | The declared OpenWeb feature set has no OpenWeb license paywall and a new contributor can build and maintain it. |

## Planned / unintegrated roadmap entries — 40

These requested full equivalents still need implementation/integration and qualification. Native three-way calls do not establish a video-meeting service; backup recovery does not establish automatic high availability; an administration manager does not establish a Windows calling app.

| ID | Goal | Required outcome |
| --- | --- | --- |
| CALL-10 | Assistant screening | The selected assistant can handle the intended calls while other users cannot impersonate that role. |
| APP-01 | Browser calling | A normal user can handle calls in supported browsers on local and remote networks. |
| APP-02 | Windows calling app | Installed builds handle calls across lock/unlock, restart and reconnection; the current administration manager does not satisfy this. |
| APP-03 | iPhone app | Signed builds ring on locked/suspended devices and recover after Wi-Fi/mobile-network changes using our own app identity. |
| APP-06 | Headsets and click-to-call | Answer/end/mute state and selected calling device remain synchronized during real calls. |
| PHONE-03 | Remote-phone connector | Several remote phones work behind one network connection without manual per-phone port forwarding. |
| PHONE-04 | Office bridges | Calls, failover and tenant restrictions pass between two independent PBXs. |
| RESTORE-03 | Encrypted backup import | Supported encrypted samples restore successfully, wrong passwords fail clearly and temporary decrypted material is removed. |
| HOTEL-03 | Guest wake-up menu | Room identity, timezone, invalid entry and confirmation are tested with actual calls. |
| HOTEL-04 | Housekeeping by phone | Staff can update the correct room and rejected codes cannot affect another tenant. |
| HOTEL-05 | Minibar entry | Duplicate submissions and connection failures cannot double-charge a stay. |
| HOTEL-06 | Call charging and guest account | Sample stays reconcile to their actual calls, including retries and checkout boundaries. |
| HOTEL-07 | Fidelio/FIAS connection | A real or vendor-approved test system passes reconnect and message-replay checks. |
| HOTEL-08 | Mitel-compatible connection | Hotel operations pass; do not label phone-charge posting available through a protocol that lacks it. |
| REPORT-02 | Scheduled reports | Recipients receive only their permitted data and failures/retries are visible. |
| REPORT-05 | Data connections | Reconnects and repeated delivery neither lose nor double-count events. |
| INTEGRATION-01 | Microsoft 365 | Initial sync, changes, revoked consent and separate customer directories pass. |
| INTEGRATION-02 | Google Workspace | Sync ownership, conflicts, account changes and revoked access behave predictably without affecting another tenant. |
| INTEGRATION-03 | Microsoft Teams calling | Supported accounts can make, receive and transfer calls through the PBX with documented external requirements. |
| INTEGRATION-04 | CRM connectors | Each named connector/version must pass customer lookup, screen opening, activity logging and supported record creation with a test account; a generic API alone does not qualify the catalogue. |
| INTEGRATION-05 | Public management and call APIs | Sample integrations work with scoped credentials, replay handling, rate limits and permission checks. |
| INTEGRATION-06 | Integration setup and troubleshooting | An administrator can repair a disconnected integration without accessing server files. |
| MESSAGE-01 | Team messaging | Delivery, reconnects, membership changes and tenant isolation pass. |
| MESSAGE-02 | Website chat | Website visitors and agents can finish a conversation without losing its history. |
| MESSAGE-03 | SMS and MMS | Inbound/outbound messages and webhook retries pass with a real provider account. |
| MESSAGE-04 | WhatsApp | The real channel passes inbound/outbound, reassignment and expiry/failure scenarios. |
| MESSAGE-05 | Facebook messaging | Access revocation, duplicate events and message delivery pass with a test page. |
| MESSAGE-06 | Public contact links | Visitors can reach the intended destination and abuse controls protect the PBX. |
| MESSAGE-07 | Unified inbox and chat reporting | Conversations and reports reconcile without exposing another company's messages. |
| MEETING-01 | Audio/video meetings | Supported clients join reliably from different networks and host permissions are enforced. |
| MEETING-02 | Meeting collaboration | Each function works for hosts/guests and access ends when sharing or the meeting ends. |
| MEETING-03 | Self-hosted capacity | Measured audio/video capacity meets the documented comparison target on published hardware. |
| AI-01 | Transcription | Queued work survives failures, permissions protect transcripts and accuracy is measured on representative languages/audio. |
| AI-02 | Summaries and analysis | Evaluation examples demonstrate useful results and authorized users can inspect the original evidence. |
| AI-03 | Voice assistants | Realistic callers can finish supported tasks and failed/uncertain requests reach the configured human destination. |
| AI-04 | AI administration | Disabling an AI service or exhausting its budget leaves ordinary calling usable and removes access as configured. |
| PLATFORM-04 | Signed Windows distribution | Clean machines verify publisher identity and upgrades do not damage unrelated applications or private data. |
| PLATFORM-06 | High availability and disaster recovery | Server-loss drills measure recovery/data-loss windows and cannot leave two systems placing the same calls. |
| PLATFORM-09 | Windows 10 and 11 server editions | Clean installation, calling, recovery and updates pass and qualified downloads are published. |
| RELEASE-05 | Final feature-equivalence release | Every in-scope task is closed, differences are explicitly documented and the public claims match actual results. |

## What closes the remaining core work

The immediate core gaps are independent first-deployment usability, provider/public-incoming/emergency/NAT matrices, complete hours and call-history boundaries, mixed queue/callback restart/duplication/starvation, real supervisor media, broader reports and role/isolation tests. Physical Android wake-up/network/hardware and approved Play distribution remain separate acceptance inputs. Hotel PMS/charging, other calling clients, enterprise/messaging/meeting/AI integration, complete C# work and HA are wider implementation goals.

Completion is recorded only against the relevant existing ID with actual evidence, qualified platforms and limits. New 1.0.11 presentation or policy tests do not automatically close these broader goals.

Operating guides: [core calling](core-calling.md), [Android](android.md), [availability](android-availability.md), [incoming wake-up](android-push.md), [updates](updates.md), [backups](backups.md), [V20 restore](v20-restore.md), [carrier cutover](carrier-cutover.md), [tenants](tenant-services.md), [mail](outgoing-mail.md), [Hotel Services](callbacks-and-hotels.md) and [Windows client plan](windows-client-plan.md).
