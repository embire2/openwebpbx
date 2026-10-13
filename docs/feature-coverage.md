# OpenWeb PBX feature coverage

OpenWeb PBX is a free, independently developed PBX built on FusionPBX and FreeSWITCH. Version 1.0.9 adds core calling packages and Android call/recovery/status controls to the working native calling, managed updates, tenant, callback and hotel foundations. It does **not** implement every 3CX feature, run 3CX software or accept proprietary 3CX apps. No claim of being the world's first free PBX is made.

The published **1.0.10 Debian/Android release**, immutable source tag `fd8a5bc74`, and historical **1.0.9** at `5df031707` are described below. The 1.0.11 controls/settings/update-floor work is in preparation. New server features target Debian 13 amd64 only. The historical Windows 1.0.7 download remains available; actual installed Windows upgrade/audio evidence remains 1.0.6, and no Windows 1.0.9/1.0.10/1.0.11 release is claimed. [Core system status](core-system-status.md) inventories working capabilities and all 133 roadmap goals without claiming full parity.

The historical Windows edition includes a C#/.NET 10 background calling service and WinUI 3 administration manager, built with Visual Studio 2026. The existing web application uses PHP and the call engine uses FreeSWITCH/Lua. This is not a complete C# rewrite. The manager opens the authenticated web Admin and is not a calling app. The [native Windows calling-client plan](windows-client-plan.md) is a plan, including emailed one-use setup files; it does not provide a working Windows softphone.

## Visible call controls, personal Settings and instance phone floor — 1.0.11

The authorized 1.0.11 implementation places a full-width **Call Hold / Resume Call** action on every active-call page and holds both SIP legs during a merged three-way hold. Native hold/resume was already accepted under APP-10. An actual conference repeat reproduced a failed resume when local entry was delayed after adding two paused legs; synchronous entry corrected the SDK media ordering. A separate manual Hold→Switch→Switch back→End-second case corrected automatic original-call recovery. The final exact signed direct APK passed six native cases below; earlier candidate-byte timings remain separate development evidence.

| Final direct-APK case | Result |
| --- | --- |
| Manual hold, switch/back, end second, automatic original recovery | 23.960 seconds; the original call recovered without another Resume action. |
| Expanded Settings and ringing | 104.003 seconds; actual canonical Andromeda selection and unreadable-sound fallback on the same native Core, both incoming calls with two-way RTP, theme/haptics/sorting, all four startup pages after cold relaunch and account/update-trust-preserving reset. |
| Three-way hold and recovery | 72.814 seconds; both remote legs paused with music, strict resumed send/receive media and remote departure while held left the remaining call held until explicit Resume. |
| Visible hold and reset during hold | 76.051 seconds; full-width control on all four call tabs and Settings, retained paused state through connection checks/theme/reset and explicit Resume with media. |
| Outgoing/background/audio focus | 45.412 seconds; native two-way media, hold/resume and communication-audio release. |
| Incoming SDK ringing/audio focus | 18.363 seconds; native incoming media and SDK-owned ringtone/communication focus. |

The final APK SHA-256 is `9f23be7940bc02122516b094cc0af2deb5d8089c430332376075d3b607204dec`; the final AAB SHA-256 is `ad47ad9b7df441eee5a06a78e4e88259ef04b233484ff57c0f991bd064d49ceb`. The strict final conference proof includes local audio joined, both legs StreamsRunning/current+remote SendRecv/local-conference mode, received decoded RTP advances of 348/345 and sent advances of 400/400, fresh positive bandwidth and zero discards. The exact AAB-derived Play APK also passed four native cases: manual-switch recovery (23.104 seconds), Settings/selected and fallback incoming ringing (132.242), conference hold/resume/departure (72.208) and outgoing/background/audio focus (43.338), with relevant independent peer media. Twenty-nine direct/33 Play JVM checks and both zero-error release lint runs passed, with bundletool/signing/API36/26-library alignment checks. Eight current fictional-account screenshots include final light/dark Settings and held-call controls; the three additional direct screens were visually reviewed. Final source/submission-packet checks, compression, public release/production activation/public replacement and native-fixture cleanup remain pending. Local AAB conversion is separate from actual Google Play-track installation.

Independent artifact-bound remote captures identified the selected hold track throughout 53.80 seconds of a single held call, 19.92 seconds on both conference legs and 10.08 seconds on the remaining held leg. **Every** overlapping ten-second window, plus the bounded trailing window, passed the unchanged **0.75** correlation threshold; direct minima were **0.8368 / 0.8424 / 0.8336** respectively. Continuous RTP, captured-byte hashes, source offsets through the 135-second loop and music stopping after Resume were required. The long single-capture fixed-offset comparison **failed at 0.593** and is retained. One fixed offset could not qualify that full loop capture; the complete window/continuity proof does not present the failed metric as a pass. Play captures separately identified 20.12/20.10 seconds on both legs and 10.18 seconds on the remaining leg, with every window above 0.75 and strict resumed decoded media.

Native **Settings** adds System/Light/Dark appearance, Android ringtone choice, keypad vibration, Keypad/Contacts/Recents/Voicemail startup, Name/Extension contact sorting, read-only account/version information and existing status/queues/audio/connection/update controls. Microphone, incoming-alert and battery controls open Android settings. Personal reset preserves account and update trust, and Disconnect remains separate. Silent, invalid and network ringtones are refused; unavailable saved sounds fall back to the system ringtone. The calling SDK owns ringtone/call audio focus. The final Settings/persistence and incoming-call checks above passed. APP-07/APP-04 remain open for favourites, outgoing-number choice, wider visibility/phone propagation and hardware/device acceptance; the official manual's complete messaging/video/voice-assistant behavior is not implemented by these settings.

The server adds an initially inactive instance minimum direct-Android release under **System → Updates**. Only an instance administrator may change it, with existing authentication/CSRF. It covers existing/future tenants and unassigned phones; tenant preferences are preserved and cannot weaken the floor. The compatible inactive phone API retains five fields, while an active floor adds minimum version, saved tenant mode and instance-requirement fields. Sixty-five disposable PostgreSQL checks pass. The app must require the update only below the minimum, then resume its tenant's saved mode. Signed package availability, compatibility, active-call deferral, urgent-call access and Android install confirmation still apply. Unpublished Play is unchanged; absent Windows/iPhone/browser calling apps are not installed clients to update. Fresh Debian under umask 077 and the actual installed-1.0.10→1.0.11 upgrade each passed 23 normal HTTPS/CSRF/API-floor-scope checks and all 7,096 file/hash/mode mappings. A forced migration failure rolled back successfully. Final native phone enforcement, production activation and public 1.0.11 assets/feed remain pending.

The actual installed-1.0.10 independent updater completed the signed HTTPS download, preflight, installed-helper upgrade and natural restart into 1.0.11. Both fresh/upgraded instances also passed sustained two-way internal RTP and service/timer mapping checks. The 23 policy HTTPS checks on each included an older assigned tenant's saved Notify mode overridden below the floor, an unassigned domain, a future tenant created after activation without a policy row, normal tenant sign-in/save and valid-CSRF refusal to change the global floor, Admin visibility and missing-CSRF refusal. A signed forced migration failure exactly restored 1.0.10, including the new floor column/value. Fresh default notification save/reload passed fourteen separate HTTPS checks. Isolated policy fixtures were removed and their floors reset. These are candidate-image checks; public production activation is still pending.

The fresh candidate installation also exposed a service-program permission gap: a private dotnet-publish root's mode 700 was inherited by the package/service directory, causing the actual `www-data` service to fail with systemd 200/CHDIR. Packaging and configuration now supply mode-755 server/updater/service roots, and a focused real-packager regression passed. The actual fresh repeat passed with private build roots still mode 700. The upgraded root-only updater slot retains its safe legacy mode 700, which is not a web-account service fault. This correction does not loosen private state/configuration permissions or alter immutable 1.0.10 artifacts. Private credential-free Debian evidence is retained under `/var/lib/openwebpbx/debian-native111/report.json`; both qualification units are stopped. The engine-source inventory contains 113 tracked platform/packaging/version/license files and 7,793 unchanged vendor entries; final archive generation follows documentation freeze.

The [1.0.11 installation guide](installing-1.0.11.md), [update guide](updates.md) and [core system status](core-system-status.md) describe operation and open acceptance boundaries. The report preserves 133 unique task IDs and 21 accepted checkmarks, with 72 partial/qualification and 40 planned/unintegrated entries. These are different-sized acceptance goals, not a completion percentage.

## Notification-store permission patch — 1.0.10

A normal authenticated HTTPS save on the published 1.0.9 installation exposed a default-path gap: the web account could not create the notification lock in the root-owned private directory. Tests using a separate private path had missed this production permission boundary. Customer calling and provider settings were unchanged.

Version 1.0.10 places PHP/C# notification configuration in `/var/lib/openwebpbx/mobile-notifications/config.json`. Its dedicated web-account-owned directory has mode `700`, and configuration/lock files remain mode `600`; the parent private directory remains root-owned with unchanged permissions. The installer/update migration atomically copies bounded ordinary legacy identity bytes only when the new configuration is absent and retains the old file untouched for rollback. Recovery inventories preserve exact previous file bytes, modes and owners. Operators use **System → Incoming Call Wake-up**; they should not create credential files or loosen the parent directory's permissions.

Thirty-four PHP, 65 C#, 15 real-filesystem installer/recovery and ten offline-upgrade checks pass. Fresh Debian setup under umask 077 passed 14 normal authenticated default-path HTTPS save/reload/stable-identity checks. The actual installed-1.0.9 independent worker passed signed HTTPS download/verification, preflight, old-helper upgrade and natural restart into 1.0.10; upgraded Admin HTTPS passed 16 checks. Legacy JSON remained byte-identical before the first HTTP save, the VAPID identity stayed stable and the old file was retained. Both images passed all 7,096 deployed hash/mode/service/timer mappings and sustained two-way internal RTP. Database identity/grants/Admin/SIP/role credential hashes and private configurations were unchanged. Two signed installed-1.0.9 forced failures restored exact prior bytes/modes/owners, both removing newly absent config/lock/helper files and restoring deliberately pre-existing files. Migration retained the active current identity over a different legacy identity. Fourteen backup scenarios passed; the unchanged SFTP scenario was skipped in this repeat.

Hosted normal CEO HTTPS subsequently passed eighteen checks, including two genuine saves/reloads, correct private directory/file permissions and unchanged root-state/legacy metadata. Production had no prior VAPID identity; its newly generated identity remained stable. The clone separately proved preservation of an existing identity. No push delivery was sent by these configuration checks. APP-17 remains open for locked/idle Answer/Decline, cancellation and battery restrictions. See the [installation guide](installing-1.0.10.md) and [wake-up guide](android-push.md).

The source-package audit also found that broad SDK directory-name filters omitted **465 tracked upstream SDK/submodule files** from the 1.0.9 Android source archive: 456 legitimate `build`-directory inputs and nine tracked IDE inputs, including CMake/Android build material. The 1.0.10 correction enumerates recursively tracked SDK files, retains legitimate `build` directories/internal symlinks and rejects tracked changes or mismatched submodule revisions; independent rebuilt-source byte/type/mode comparison passed all 38,406 tracked SDK entries, including eleven safe symlinks, plus 88 Android project entries. Archive checks also covered 42 dependency source JARs and version/guide/license files. The final source-only Android README repack passed the same comparisons and SHA-256 verification; the complete archive is 364,274,590 bytes.

Release packages include root `VERSION` and matching operating guides. The 1.0.9 tag/assets remain immutable; its release notes now link the complete 1.0.10 archive for the unchanged SDK. Asset-hash verification establishes downloaded bytes, while exact tracked-file validation establishes source completeness.

Signed 1.0.10 Android APK/AAB packaging passed 25 direct/29 Play JVM checks and both release lint runs, existing signing identity/version-code checks, direct non-debuggable/16-KiB ZIP checks and AAB bundletool/26-library 64-bit ELF checks. Android runtime source is unchanged from immutable 1.0.9 except its version.

The earlier twelve direct/three Play native-flow results remain historical exact-1.0.9-artifact evidence. The genuine public 1.0.7→1.0.10 update passed pinned-feed verification, HTTPS APK download, native installation confirmation, exact installed public hash, retained token/extension and TLS re-registration. Completion used the supported manual Open action; immediate follow-on instrumentation interrupted the genuine replacement receiver, so automatic notification reopening is not qualified in this run. The current-feed check removed the obsolete update note. Exact direct-1.0.10 tests passed five real-peer RTP cases: outgoing/background, incoming, stale actions, three-way/removal and availability. Three exact AAB-derived Play-1.0.10 cases also passed, with relevant calls verified by independent real-peer RTP. Scoped cleanup passed with zero owned domains/extensions/devices/CDRs/restore rows, contacts or media, and the temporary tenant/owner removed. Exact direct 1.0.10 was restored and disconnected; customer and permanent reviewer data stayed outside the cleanup scope.

Published on 2026-10-12 at `fd8a5bc74`: all eight complete public downloads matched SHA-256, and the latest signed sequence-110 envelope was byte-identical to the reviewed feed with a valid signature. Production resumed its existing update request using the exact verified package atomically seeded in its cache after interrupting only the download/updater service. The production C# worker did not itself complete the full HTTP package download; that path passed separately on the isolated upgrade. Installed-helper preflight and the production update completed, with last-success/up-to-date 1.0.10.

Production preservation passed 23 users, 19 gateways, 137 typed dialplans, all 801 condition/action rows, twelve queues, fifteen agents/tiers, restored configurations, permanent reviewer and database identity/roles/grants/credential hashes/private configurations. Only the proved stock domain-variables timestamp refreshed. PORTA is REGED/UP, calls are zero and customer extension 1000 remains explicitly offline. The homepage passed fourteen files, 38 links, eight assets, twelve dialogs and light/dark 1440/390/320px browser checks with zero console errors, plus historical review-video playback/range delivery. The separate fourteen-file preview was refreshed. The final production audit passed all 7,096 public mapping hashes/modes/owners, the 1.0.10 updater slot, seven services, backup timer/enablement links and private recovery-snapshot integrity. New files were inventoried before mutation; private config/lock are regular single-link files readable by the actual `www-data` C# service, and the existing root:root mode-755 state directory remains unchanged and not writable by the web account. The genuine public Android update, five direct and three exact AAB-derived Play native cases passed as recorded above; scoped fixture cleanup passed without changing customer or permanent reviewer data.

## Combined Debian/Android release — 1.0.9

The user authorized five Android features and five core server packages. Current-source qualification on 2026-10-12 used disposable tenants, isolated database schemas and local SIP/native-engine fixtures. Customer configuration and provider activation were preserved. No new carrier call or external email was made for these checks.

| Area | Release behavior | Actual evidence and remaining limits |
| --- | --- | --- |
| Provider and First Calls setup | Atomic disabled provider/main-number/hours/outgoing-rule creation, optional existing backup provider, readiness, ordinary-route preview and connected-phone-first test worker | 48 core PHP checks cover setup, schedules, ownership and first-call validation. Actual HTTPS saved the provider/rules together and opened the existing enablement editor. Native tests verified provider selection/digit rewrite and the bounded worker's ordinary local-provider leg with two-way media. Public incoming/outgoing speech, independent new-administrator acceptance and independent fresh-deployment first-call acceptance remain open. |
| Hours and routing | Multiple/overnight periods, breaks/holidays/timezones, explicit main-number hours, temporary open/closed override, destination preview, number blocking and explicit emergency routes | 149 policy and 75 runtime checks passed. Actual main-number ingress selected the explicitly open/closed destinations with media. Full restored/new-PBX timezone/forwarding boundaries, deliberate remote faults, caller-rule and provider-approved emergency qualification remain open. No emergency call was made. |
| Receptionist switchboard and parking | Tenant-owned live calls, searchable people/presence, hold/resume, transfer, shared park/pickup and end with separate view/control permissions | Actual native control flows preserved continuing media and returned the call list to zero. Authentication, tenant/role scope, missing CSRF and foreign/unavailable-call refusal passed live HTTPS. Seven core screens passed light/dark browser checks at 320/390/1440 pixels; simultaneous-call operator qualification remains open. The switchboard controls phones; it does not provide browser audio. |
| Advanced queues, callbacks and supervision | Strategies/priority groups, capacity/overflow, tracked position/estimated wait, periodic messages, original-position/live-first callbacks, agent reservation and supervisor Ready/Break/Sign Out | Actual top-down queue delivery, waiting counts/target alert and agent-first internal callback passed with media. Selected-agent loopback kept media and refused missing-source and on-break targets. Position/announcement localization, mixed waiting/callback restart/starvation scenarios, broader strategies and real-carrier callbacks remain open. |
| Queue reports and wallboard | Native waiting/agent state and in-page alert; scoped completed-visit and callback results over 24 hours, 7 days and 31 days | Actual completed answered visit reconciled separately from the connected callback. Full missed/transferred/abandoned/timezone totals, carrier cost/billing, statistics reset and external notifications are not qualified or implemented. |
| Native Android advanced calls and recovery | Consultation/cancel/failure recovery, blind/attended transfer, second-call handling, hold/switch/merge/participant removal and reconnection without rescanning | Twelve final signed-direct APK native checks passed through the real calling engine, including transfer, waiting, conference, recovery, status, basic incoming/outgoing media and stale-alert preservation. Transfers preserved remote RTP, conference media/removal passed over a 27-second repeat, and network loss recovered in seven seconds with the same account followed by a new call with media. Both transferred remote legs continued RTP after Android teardown. Broader history/teardown scenarios remain on the roadmap. Physical Wi-Fi/mobile handover, earpiece/Bluetooth/proximity and manufacturer battery restrictions remain unqualified. |
| Android availability and queues | Effective directory status, DND/Away/Available, expiring temporary status, office-hour interaction and individual assigned-queue membership | 48 isolated PHP checks and 19 worker checks including actual native expiry/retry passed. Disposable native routing/agent tests passed; the 12.425-second Android DND/Available/queue workflow agreed with server state. Empty receiving labels and specific pause reasons were corrected. The final signed direct APK repeated native status and queue controls successfully. |
| Optional incoming-call wake-up | Automatic stable VAPID identity; open-source UnifiedPush connector/embedded distributor using installed Google Play Services; optional Cloudflare ciphertext relay | No Firebase project is needed and no Google client SDK is bundled. 33 PHP, 64 server and 27 Worker checks passed, including the published RFC8291 vector, independent decryption/ES256 verification, real Worker forwarding of encrypted incoming/ended messages, durable restart/cancellation and subscription rotation. The legacy Firebase adapter is explicitly unavailable to the current app. Real Google delivery, a deployed Cloudflare relay and locked/idle physical-phone Answer/Decline/cancellation are unqualified. |
| Encrypted instance backups | Daily/manual full-instance configuration/keys/database/optional media, retention, protected download, pinned-key SFTP copy and guarded separate-Debian restore/recovery | 42 PHP checks and 13 Python scenarios passed. Independent native Debian source/target machines preserved encrypted templates, original keys/media hashes and SIP credentials, with two-way internal calls after restoration. Actual systemd worker/activation holds and HTTPS authentication/CSRF/download/tenant refusal passed. Those machines used a historical 1.0.4 factory image with current helpers. Whole-package fresh/legacy-upgrade/rollback integration now passes with installed helper and timer verification. Windows portability, remote-provider infrastructure and backup notifications remain open. |
| Bundled hold music | Seth_Makes_Sounds' CC0 Lofi Beat Loop Schmoop, original public MP3, normalized 135-second telephone WAV and four native sample rates with SHA-256 provenance | Actual Android hold/resume passed; 9.98 seconds of the held phone's received RTP matched the selected track's energy envelope at 0.895 correlation. The stock default survived XML reload after a correction limited to its hold variable; custom music and every other variable were preserved. |

Core qualification records **19 actual native checks** and **21 live HTTPS checks**, including the provider wizard, first-call worker, queue/wallboard, switchboard actions and permission failures. The results above describe distinct tests, not complete 3CX parity or a general phone/provider compatibility matrix. The core browser review passed seven screens at 320/390/1440 pixels in light/dark embedded themes, routing preview, hours controls and credential-preserving authentication toggles, without page errors or horizontal overflow. Backup layout checks separately passed 320/390/768/1440 pixels in light/dark modes with no overflow, clipped fields or console errors/warnings.

The signed APK/AAB builds passed **25 direct and 29 Play JVM checks plus release lint**. All 42 Android runtime dependency source JARs are available for corresponding-source packaging. Six real-filesystem Debian support-hook recovery checks and ten existing offline-upgrade checks passed, including atomic snapshot extension before installing new helpers and timer enablement. Full fresh Debian setup under umask 077, the original installed 1.0.7 updater and two forced-failure rollback cases also passed. All 7,093 runtime files match in the fresh and upgraded images; database/role/credential identity, native SIP/audio and installed backup timer/helpers passed.

Published on 2026-10-12 at immutable tag `5df031707`: all eight complete public asset downloads matched their frozen SHA-256 values and the signed feed was verified. The fourteen-file homepage allowlist and 38 public links passed. Actual-domain browser checks passed twelve feature dialogs, Start/taskbar, mobile/support/privacy flows and light/dark 1440/390/320px layouts with zero console errors; the historical 78-second review video played and HTTP 206 range delivery passed. The production 1.0.7→1.0.9 update preserved 23 customer users, 19 gateways, 137 typed dialplan rows, all 801 condition/action rows, other restored configurations, database identity/owners/grants/roles/credential hashes and the permanent review setup. Only the proved stock domain-variables update timestamp refreshed. PORTA remained REGED/UP, the background service was Running and calls were zero. Extension 1000 was offline; the private checker retained that result and used an explicit exception for phone presence only. Google Play review/public listing, locked/idle handset push, physical network/hardware coverage and broader carrier/Windows qualification remain separate roadmap tasks.

Operator guides: [core calling](core-calling.md), [Android](android.md), [wake-up](android-push.md), [status and queues](android-availability.md), [backups](backups.md), [hold music](music-on-hold.md), and [installation](installing-1.0.9.md).

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

Version 1.0.7 is published at source tag
`4075316e5f84ed568dc786518abbfae24ae302ee`. All nine complete public asset
downloads matched their frozen SHA-256 values, including the separate Play AAB
and submission ZIP. The latest signed feed matched the reviewed envelope.
The fourteen-file homepage refresh passed served-file checks, all 36 public
links, actual review-video playback and desktop/mobile browser checks with no
overflow or console errors. Organisation details supplied on 2026-10-10 are
saved privately and the D-U-N-S request is drafted. Postal-address confirmation,
company registration proof, D-U-N-S and account verification remain pending;
no request or Play submission has been sent and no approval is claimed.

The production Debian 1.0.6→1.0.7 update completed through the already installed
updater and reports Running. All 6,245 packaged web files and 216 native files
match the release; the private recovery snapshot passed integrity and database
identity/grant checks. Customer configuration and the review setup were preserved.
Among 137 customer-domain dialplan rows, 136 were byte-identical and the stock
domain-variables row changed only its update timestamp during defaults
regeneration; all conditions, actions and routing fields remained identical.
All 801 condition/action rows were byte-identical. The codec remains ready with
the conflicting passthrough disabled in both database and XML; the existing
provider and extension 1000 remain registered. The service and updater report
1.0.7 Running/up to date. Authenticated Admin, Updates and fresh reviewer QR
access passed. The OpenWeb tenant's Android policy is now required, verified in
both the phone response and administration page; other tenant and global update
policies were unchanged. APP-15 is complete. No additional carrier call was made
for this release, and the physical proximity check remains open under APP-14.

## Work still required

The maintained [3CX roadmap](../3CX.md) contains the detailed checklist, priorities,
acceptance conditions and external dependencies. The released baseline and
development evidence above are separate; CALL-01 and CALL-02 remain open.

These are explicit gaps:

- Replacement Windows, browser and iOS calling apps; real locked/idle delivery of the optional Android wake-up, broader handset/network qualification, headset integration and activation for future clients.
- Hotel PMS/Fidelio/Mitel interfaces, guest folios, call charging, minibar entry, handset housekeeping codes and guest wake-up scheduling.
- Complete simultaneous-call operator/wallboard/report qualification, supervisor monitoring/coaching and remaining queue analytics.
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
