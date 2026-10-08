# OpenWeb PBX — 3CX feature roadmap

Last updated: **2026-10-08**. Released baseline: **[1.0.2](https://github.com/embire2/openwebpbx/releases/tag/v1.0.2)**, tag commit `30036bb82`.

Our goal is a free OpenWeb PBX that is as straightforward to install and use as 3CX, provides equivalent calling and administration features, restores supported 3CX backups with equivalent behavior, and runs on Windows Server or Debian 13. This includes Hotel Services, replacement calling apps, multiple tenants, reusable PBX templates, and the requested C#/.NET 10 and WinUI 3 development work.

**The goal is not complete.** Version 1.0.2 has working foundations and tested internal calls. Outside carrier calls remain unverified. The Windows manager administers the PBX; it cannot make calls. Most of the existing web application and call handling still use PHP/Lua/FreeSWITCH.

The migration baseline is the supplied **3CX V20 Update 9, build `20.0.9.995`** backup. The broader feature target includes the official [3CX feature catalogue](https://www.3cx.com/ordering/pricing/features/) across its editions, including hotel and enterprise features; that catalogue says it was updated on 28 August 2026 and was reviewed for this roadmap on 8 October 2026. The [V20 administration manual](https://www.3cx.com/docs/manual/) supplies the workflow reference. Later features must be added explicitly as the comparison changes. OpenWeb equivalents must use our own implementation, branding and services; proprietary 3CX apps and hosted services need replacements.

## How to maintain this checklist

- Treat this file as the current task list. [Feature coverage](docs/feature-coverage.md) describes the released behavior; [AGENTS.md](AGENTS.md) records the work and verification history.
- An unchecked item is unfinished. **Build** means a working equivalent is missing; **Partial** means part exists; **Verify** means existing code or an upstream module needs integration or proof; **Needs input** identifies an external prerequisite. These labels do not imply work is currently running.
- **P0** is the path to a dependable, simple first deployment. **P1** completes everyday calling, migration, hotel and platform requirements. **P2** completes the wider enterprise, communications and AI scope. P2 remains part of the goal.
- Keep task IDs stable. Update an affected item whenever implementation, testing, deployment or a newly discovered limitation changes its status. Split large items into smaller linked tasks when work starts.
- Check an item only after its stated outcome works through the supported user interface, applicable Windows/Debian checks pass, and tenant permissions are verified. Record the date, commit/release, evidence and remaining limits beside it. Code presence, a successful build or a simulated call alone is insufficient.
- If blocked, record the precise missing input and continue independent work. Keep credentials, customer backups, recordings and private test artifacts out of this file and the public repository.
- Reconcile this checklist, the coverage summary, relevant guides and release notes before each release. Preserve completed entries and reopen them if a regression invalidates their evidence. No completion percentage is used because the tasks differ greatly in size.

## Verified foundations already delivered

These checkmarks cover only the stated 1.0.2 baseline. The outstanding items below extend it.

- [x] **BASE-01 — Branding and desktop administration.** OpenWeb PBX name, public `embire2/openwebpbx` repository, permission-filtered Windows-inspired desktop, responsive layouts and familiar Admin page names. Browser checks recorded in [AGENTS.md](AGENTS.md).
- [x] **BASE-02 — Production HTTPS and administrator.** Requested administrator and trusted HTTPS on `call.openweb.co.za`; renewal dry run passed. Credentials remain private. This does not cover automated certificates in fresh installers.
- [x] **BASE-03 — Tenants and templates.** Invite-only companies, separate PBX services, scoped administrators and encrypted reusable templates; database and live isolation checks passed. See [tenant services](docs/tenant-services.md).
- [x] **BASE-04 — Guided setup and administration.** Company, users, providers and routing workflow, with editors for restored calling objects. See [guided setup](docs/guided-pbx-setup.md).
- [x] **BASE-05 — Observed V20 backup import.** The supplied build's supported objects and private media were restored and checked. Missing source material and unsupported behavior still need the work below. See [V20 restore](docs/v20-restore.md).
- [x] **BASE-06 — Internal calling.** Registration, two-way audio, restored ring groups, queues, receptionist keys and protected recording playback passed on the live engine. All 19 restored trunks remain off; no carrier-call result is implied.
- [x] **BASE-07 — Automatic callbacks.** Request, timed offer and automatic modes; agent-first calls, retries, expiry and offline-agent waiting. Actual callback/audio checks passed on Windows and Debian. See [callbacks](docs/callbacks-and-hotels.md).
- [x] **BASE-08 — Hotel basics.** Room check-in/out, status, DND, vacant-room restrictions, mailbox index/greeting/PIN reset and audit history; scoped operations checks passed. See [Hotel Services](docs/callbacks-and-hotels.md).
- [x] **BASE-09 — Administrator wake-up scheduling.** Confirmed calls with bounded retries passed on both operating systems. Guest self-service and hotel-system scheduling remain open.
- [x] **BASE-10 — Shared outgoing mail settings.** Password and IP authentication, secret masking and global relay precedence passed local SMTP tests. An actual relay and inbox delivery remain unconfigured. See [outgoing mail](docs/outgoing-mail.md).
- [x] **BASE-11 — Native installation and release.** Fresh Windows Server 2025 Desktop Experience and Debian 13 amd64 installations passed; .NET 10 service and WinUI 3 manager built with Visual Studio 2026. Public 1.0.2 archives and checksums were verified. See [installation](docs/installing-1.0.2.md) and [build instructions](packaging/BUILDING.md).

## Delivery order

| Order | Deliverable | Main tasks and dependencies |
| --- | --- | --- |
| 1 | A simple setup that proves the first real calls work | SETUP-01–05, CALL-01–04, CALL-07, RESTORE-01; real provider and mail details needed for final checks |
| 2 | Usable replacement calling apps and phone onboarding | APP-01–07, PHONE-01–04; shared application API from PLATFORM-01 |
| 3 | Complete queues, callbacks, operator tools and Hotel Services | QUEUE-01–08, HOTEL-01–10, REPORT-01–04; phones and hotel test systems for qualification |
| 4 | Reliable migration, upgrades and tenant operations | Remaining RESTORE, TENANT, PLATFORM and RELEASE tasks; retain existing data throughout |
| 5 | Remaining enterprise integrations, messaging, meetings and AI | INTEGRATION, MESSAGE, MEETING and AI tasks; each external connector needs its own account and tests |
| 6 | Final comparison and release qualification | SCOPE-01, RELEASE-01–05 and every outstanding acceptance condition |

This is a dependency order, not a promised release date. Work that is independent of an external account can proceed sooner.

## P0 — Setup and simple administration

- [ ] **SETUP-01 — Finish the first-call wizard (Partial).** One guided path creates a company, users, provider, main number, opening hours and destination, then runs internal/incoming/outgoing call checks. Done when a new administrator can complete it without editing files, SQL or call-engine settings.
- [ ] **SETUP-02 — Keep everyday screens simple (Partial).** Audit the familiar Users, Phones, Voice & Chat, Call Handling, Office Hours, Reports and System workflows against the V20 page names while retaining OpenWeb branding. Put specialist settings behind Advanced and explain errors with a next action. Done when ordinary tasks never require the legacy technical editors.
- [ ] **SETUP-03 — Automatic public HTTPS (Partial).** Add hostname/DNS checks and Let's Encrypt issuance, renewal and expiry reporting to both fresh installers. Done when a clean public Windows and Debian installation obtains and renews a trusted certificate through setup. The production certificate already works.
- [ ] **SETUP-04 — Network and firewall check (Build).** Detect wrong public addresses, blocked phone/audio ports, local DNS issues and one-way audio; offer specific corrections. Done when deliberate faults are detected on local and remote-phone test networks and rerunning the check confirms the repair.
- [ ] **SETUP-05 — Complete outgoing mail setup (Needs input).** Configure a real relay and verify welcome/reset messages, voicemail attachments and failure reporting. Done when both supported authentication modes are qualified with suitable relays and delivery to test inboxes is confirmed.
- [ ] **SETUP-06 — User onboarding and account recovery (Partial).** Add a simple welcome flow, self-service password reset, session/device revocation and second-factor sign-in. Done when an invited user can activate, recover and protect an account without an administrator exposing a password.
- [ ] **SETUP-07 — Bulk changes and accessible help (Partial).** Complete previewed user/contact imports, bulk edits, searchable help, keyboard navigation and screen-reader labels. Done when failed rows are explained and desktop/mobile workflows remain usable with assistive input.

## P0/P1 — Calling and provider readiness

- [ ] **CALL-01 — Real provider qualification (Needs input; P0).** Test a configured SIP provider on both platforms: incoming/outgoing calls, caller ID, key presses, busy/no-answer, transfers, recordings and long calls. Done when a published provider/model matrix records passing results; enable restored trunks only as their configuration is validated.
- [ ] **CALL-02 — Route and provider failure handling (Partial; P0).** Finish ordered backup routes, number rewriting, department restrictions and caller-ID choice. Done when an unavailable first route reaches the correct backup route for ordinary calls and callbacks without duplicate calls or cross-tenant routing.
- [ ] **CALL-03 — Everyday call controls (Verify; P0).** Qualify hold/resume, attended/blind transfer, transfer-back, pickup, shared parking, call waiting, multiple devices and external forwarding. Done when real endpoints produce the expected audio and call history for each flow on both platforms.
- [ ] **CALL-04 — Hours and forwarding consistency (Partial; P0).** Cover breaks, holidays, overnight periods, daylight-saving changes, temporary overrides and each presence profile. Done when new and restored PBXs route the same test calls to the expected destinations at every boundary.
- [ ] **CALL-05 — Complete voicemail workflows (Partial; P1).** Finish user and group mailboxes, phone menus, greetings, notifications and message retention. Done when users can record/select greetings and manage messages from phones and apps, and shared messages reach only intended recipients.
- [ ] **CALL-06 — Caller rules and number blocking (Verify; P1).** Expose caller-based routing, anonymous/unwanted-number blocking, permitted destinations and consistent number formatting in simple controls. Done when imported and newly created rules pass positive and negative call checks.
- [ ] **CALL-07 — Emergency calling (Verify; P0).** Add explicit emergency routes, location/caller identity and administrator notifications, including occupied/vacant hotel-room behavior. Done after provider-approved test procedures verify routing under restrictions and provider failure; do not use live emergency numbers for routine tests.
- [ ] **CALL-08 — Phone-network compatibility (Verify; P1).** Qualify remote networks, encrypted signalling/audio, supported codecs, key-press formats, reconnects and changing network addresses. Done when a published compatibility matrix includes real devices and both server platforms.
- [ ] **CALL-09 — Fax and analogue equipment (Verify; P1).** Integrate the existing fax/gateway capabilities into the simplified Admin. Done when supported equipment sends/receives actual test faxes, fax email delivery works, and documented analogue calling flows pass.
- [ ] **CALL-10 — Assistant screening (Build; P1).** Provide ordinary boss/secretary screening and delegated call handling, with allowed caller exceptions. Done when the selected assistant can handle the intended calls while other users cannot impersonate that role.

These are OpenWeb implementation and qualification tasks. The reference workflows include [3CX advanced calling settings](https://www.3cx.com/docs/manual/advanced-features/).

## P1 — Queues, callbacks and operator tools

- [ ] **QUEUE-01 — Callback place in the queue (Partial).** Implement and document callback ordering relative to waiting callers; 1.0.2 always gives live callers priority. Done when mixed waiting/callback scenarios follow the selected equivalent policy across restarts without starvation or duplicate delivery.
- [ ] **QUEUE-02 — Finish outside callbacks (Partial).** Verify busy, rejected, unanswered and invalid destinations, office closure, restart during a call and provider fallback. Done when real carrier callbacks connect with two-way audio, bounded retries and an accurate result; depends on CALL-01/02.
- [ ] **QUEUE-03 — Queue announcements (Partial).** Add actual position/estimated-wait playback and configurable periodic messages. Done when callers hear correct, localized announcements as the queue changes, including imported settings.
- [ ] **QUEUE-04 — Routing choices (Partial).** Audit and complete ordinary and skill-based strategies, priority queues, escalation, capacity limits and overflow. Done when deterministic multi-agent scenarios demonstrate the chosen order and limits.
- [ ] **QUEUE-05 — Agent controls (Partial).** Provide per-queue login/logout, breaks, wrap-up and supervisor overrides in apps and Admin. Done when agent state remains consistent across concurrent calls, devices, status changes and reconnects.
- [ ] **QUEUE-06 — Supervisor calling tools (Verify).** Integrate listening, private coaching and joining a call with appropriate permissions. Done when real audio tests prove who can hear whom and unauthorized users are refused.
- [ ] **QUEUE-07 — Receptionist switchboard (Build).** Add live calls, searchable people, presence and transfer/park/pickup actions. Done when a receptionist can manage simultaneous calls without opening engine-specific screens.
- [ ] **QUEUE-08 — Wallboard and service alerts (Build).** Show live waiting/answered/abandoned calls, agent state and service-target alerts with controlled statistics resets. Done when displays and notifications reconcile with actual calls and the reports in REPORT-01.

The behavior reference is [3CX queues and ring groups](https://www.3cx.com/docs/manual/call-center-queues/). Existing callback verification is documented in [our callback guide](docs/callbacks-and-hotels.md).

## P1 — Calling apps

- [ ] **APP-01 — Browser calling (Build).** Deliver a Web Client with dialler, incoming-call alerts, hold, transfer, voicemail, history and audio-device selection. Done when a normal user can handle calls in supported browsers on local and remote networks.
- [ ] **APP-02 — Windows calling app (Build).** Build the requested C#/.NET 10 and WinUI 3 softphone with background ringing, device selection and the everyday call controls. Done when installed builds handle calls across lock/unlock, restart and reconnection; the current administration manager does not satisfy this.
- [ ] **APP-03 — iPhone app (Build).** Provide call handling, voicemail and reliable incoming-call push. Done when signed builds ring on locked/suspended devices and recover after Wi-Fi/mobile-network changes using our own app identity.
- [ ] **APP-04 — Android app (Build).** Provide equivalent calling and notifications. Done when signed builds handle background restrictions, battery-saving modes and network changes on a published device matrix.
- [ ] **APP-05 — Simple app activation (Build).** Add expiring activation links/QR codes and device management. Done when a user provisions a replacement app without typing technical phone credentials and a revoked device loses access.
- [ ] **APP-06 — Headsets and click-to-call (Build).** Add supported headset buttons, operating-system call links and browser number detection. Done when answer/end/mute state and selected calling device remain synchronized during real calls.
- [ ] **APP-07 — People, presence and personal settings (Partial).** Provide a shared/personal directory, favourites, busy lamps, forwarding/status controls and permitted outgoing-number choice. Done when changes propagate to apps/phones while respecting company and department visibility.

The interaction reference is the [3CX Web Client manual](https://www.3cx.com/user-manual/web-client/). Apps use OpenWeb accounts and services; importing a backup does not activate proprietary 3CX apps.

## P1 — Desk phones and remote offices

- [ ] **PHONE-01 — Supported phone catalogue (Verify).** Qualify the inherited templates for selected desk phones, cordless systems and gateways. Done when each listed model has a tested firmware version, provisioning steps and supported-feature record.
- [ ] **PHONE-02 — Easy phone setup (Partial).** Add discovery/assignment, secure provisioning links, firmware updates, reprovisioning and customer logos. Done when a reset supported phone joins the intended tenant and cannot download another phone's credentials.
- [ ] **PHONE-03 — Remote-phone connector (Build).** Provide an OpenWeb SBC/remote-office connector with guided installation, enrolment, status and recovery. Done when several remote phones work behind one network connection without manual per-phone port forwarding.
- [ ] **PHONE-04 — Office bridges (Build).** Replace the unsupported imported bridge with controlled site-to-site calling, number routing and required presence. Done when calls, failover and tenant restrictions pass between two independent PBXs.
- [ ] **PHONE-05 — Phone buttons and shared desks (Verify).** Integrate busy lamps, speed dials, shared parking and hot-desking login/logout. Done when button state and a user's identity follow the intended phone without leaving the previous user's data behind.
- [ ] **PHONE-06 — Paging and intercom (Verify).** Expose supported one-way/two-way announcements and multicast groups. Done when real phones obey permissions, target groups and audio direction.

## P0/P1 — 3CX migration and Backup & Restore

- [ ] **RESTORE-01 — Resolve the supplied backup's remaining items (Needs input; P0).** Recover or explicitly replace the four missing audio files and two missing PIN-menu destinations; select active voicemail greetings. Recreate the bridge through PHONE-04. Done when each Restore Report entry has a verified resolution or a clearly accepted source-data limitation; do not silently delete warnings.
- [ ] **RESTORE-02 — V20 version/feature matrix (Partial; P1).** Catalogue each source object, setting and media type; add adapters and behavior checks for additional V20 builds using authorized fixtures. Done when every declared supported build has repeatable import and post-import call results, with unmapped fields reported.
- [ ] **RESTORE-03 — Encrypted backup import (Build; P1).** Add password-assisted reading of verified encrypted formats. Done when supported encrypted samples restore successfully, wrong passwords fail clearly and temporary decrypted material is removed. Unknown formats remain clearly unsupported until verified.
- [ ] **RESTORE-04 — Guided migration reconciliation (Partial; P1).** Show a readable before/after comparison, missing-item repair actions, app/phone enrolment and a first-call checklist. Done when a new administrator can resolve each supported migration step without editing database records.
- [ ] **RESTORE-05 — Import failure and rollback checks (Verify; P1).** Exercise large archives, interrupted uploads, disk exhaustion, malformed input and repeat confirmation. Done when failures leave existing services intact, retries cannot duplicate a service and private temporary files expire correctly on both platforms.
- [ ] **RESTORE-06 — OpenWeb backups (Verify; P1).** Integrate complete configuration, keys, tenants, templates, jobs and optional media into an encrypted backup with scheduling, retention and notifications. Done when it restores an independent working PBX, including encrypted settings.
- [ ] **RESTORE-07 — Remote storage (Build; P1).** Provide tested local, SFTP, SMB and supported cloud/archive connectors, plus a documented decision for each reference storage option. Done when uploads, integrity checks, rotation, download and restore work after a connection failure.
- [ ] **RESTORE-08 — Windows/Debian portability (Verify; P1).** Restore the same supported 3CX and OpenWeb fixtures on each OS and migrate OpenWeb backups in both directions. Done when file paths, ownership, scheduled jobs, media and call behavior survive the move.
- [ ] **RESTORE-09 — Custom call flows (Partial; P1).** Expand the supported replacement for PIN menus and other imported call scripts; supply an equivalent visual flow editor and documented C# scripting/API option. Done when supported flows are recreated and tested, while unknown source programs receive an actionable migration report.
- [ ] **RESTORE-10 — Replacement accounts and services (Partial; P1).** Make renewed web accounts, app activation, certificates, mail and integration authorizations part of the restore workflow. Done when an administrator sees exactly what needs reconnecting and can finish it; source licenses, tokens and executable services are not reusable equivalents.

Current import evidence is in [V20 restore](docs/v20-restore.md). Operational backup requirements use the [3CX backup and storage workflow](https://www.3cx.com/docs/manual/backup/) as a comparison.

## P1 — Hotel Services

- [ ] **HOTEL-01 — Guest identity on phones (Partial).** Update and clear guest names in directories and supported handsets during check-in/out. Done when reprovisioning updates the actual room phone and the next guest sees no previous identity.
- [ ] **HOTEL-02 — Finish guest-data clearing (Partial).** Define and implement room voicemail/recording deletion and retention controls. Done when checkout enforces the selected policy in indexes, private media and archives; 1.0.2 clears mailbox indexes but retains private audio under operator retention.
- [ ] **HOTEL-03 — Guest wake-up menu (Build).** Let guests schedule, review and cancel wake-ups from their room phone. Done when room identity, timezone, invalid entry and confirmation are tested with actual calls.
- [ ] **HOTEL-04 — Housekeeping by phone (Build).** Add authorized room-status dial codes and mappings. Done when staff can update the correct room and rejected codes cannot affect another tenant.
- [ ] **HOTEL-05 — Minibar entry (Build).** Provide item/quantity entry and delivery to the connected hotel system. Done when duplicate submissions and connection failures cannot double-charge a stay.
- [ ] **HOTEL-06 — Call charging and guest account (Build).** Add rates, rounding, charge records and PMS posting/export. Done when sample stays reconcile to their actual calls, including retries and checkout boundaries.
- [ ] **HOTEL-07 — Fidelio/FIAS connection (Build; needs a test PMS for qualification).** Add setup, check-in/out, room state, wake-ups and supported charge messages. Done when a real or vendor-approved test system passes reconnect and message-replay checks.
- [ ] **HOTEL-08 — Mitel-compatible connection (Build; needs a test PMS for qualification).** Implement the supported SX2000 operations and disclose protocol limits. Done when hotel operations pass; do not label phone-charge posting available through a protocol that lacks it.
- [ ] **HOTEL-09 — Front-desk permissions and workflow (Partial).** Provide simple room search, stay changes and reception/housekeeping roles. Done when staff can perform their tasks without broader PBX privileges and all guest-affecting actions are traceable.
- [ ] **HOTEL-10 — Full hotel acceptance test (Verify).** Run a stay from arrival to checkout on both platforms, including unanswered wake-up escalation, room move, outside-call restrictions, DND and a subsequent guest. Done when phone, PMS, billing and privacy results agree; depends on the preceding hotel tasks and CALL-07.

Comparison details: [3CX Hotel Module](https://www.3cx.com/docs/hotel-pbx/) and [PMS interfaces](https://www.3cx.com/docs/pms-integration/). OpenWeb's current subset is documented in [Hotel Services](docs/callbacks-and-hotels.md).

## P1 — Tenants and PBX templates

- [ ] **TENANT-01 — Complete template contents (Partial).** Extend reusable templates to departments/hours, incoming numbers, queues, receptionists, phones and hotel settings as supported. Done when a tenant creates a service with the expected complete setup and fresh per-service secrets.
- [ ] **TENANT-02 — Friendly template editing (Partial).** Replace raw setting names with plain controls, validate provider presets and show a versioned preview. Done when an administrator can publish a usable template and its existing services remain unaffected by later edits.
- [ ] **TENANT-03 — Granular staff roles (Partial).** Complete owner, administrator, department manager, receptionist, queue supervisor and ordinary-user permissions. Done when each role can perform its documented actions and is denied every cross-role/cross-tenant action outside that scope.
- [ ] **TENANT-04 — Suspension and service limits (Partial).** Make web access, phone registration, outside calls, active calls, emergency exceptions and background jobs follow an explicit suspension policy. Done when operators can see and verify the effect; current tenant suspension alone does not disable existing SIP accounts.
- [ ] **TENANT-05 — Tenant domains and resource usage (Partial).** Provide custom hostname/certificate management where offered, and visible limits for calls, users and storage. Done when one tenant cannot consume another's allocation or obtain its data.
- [ ] **TENANT-06 — Isolation across new features (Verify).** Extend checks to apps, live events, chat, reports, recordings, PMS, integrations and backup restore. Done when two tenants using identical extension numbers remain isolated through every supported interface.

## P1 — Reports, recordings and system health

- [ ] **REPORT-01 — Complete calling and queue reports (Partial).** Add call detail/cost, agent activity, waiting/abandonment, callbacks and service-target reports. Done when totals reconcile to known completed, missed and transferred test calls in each timezone.
- [ ] **REPORT-02 — Scheduled reports (Build).** Add filters, saved views, exports and scheduled email delivery. Done when recipients receive only their permitted data and failures/retries are visible.
- [ ] **REPORT-03 — Recording controls (Partial).** Expose policy inheritance, start/stop rights, pause/resume and caller consent choices. Done when internal, outside, queued and transferred calls record exactly the permitted portions.
- [ ] **REPORT-04 — Media lifecycle (Partial).** Add storage usage, configurable retention, archive/retrieval and deletion history. Done when playback permissions and retention remain correct after moves, restores and guest checkout.
- [ ] **REPORT-05 — Data connections (Build).** Provide scoped call/event exports and supported database/analytics connectors for external dashboards. Done when reconnects and repeated delivery neither lose nor double-count events.
- [ ] **REPORT-06 — System health and alerts (Partial).** Expose provider/phone status, service failures, disk space, backup/certificate failures and protected diagnostic exports; add remote logging. Done when injected failures produce useful tenant-appropriate alerts without exposing secrets.

## P2 — Business integrations and automation

- [ ] **INTEGRATION-01 — Microsoft 365 (Build).** Add tenant-authorized sign-in, people/contact sync, presence/calendar behavior and mail integration. Done when initial sync, changes, revoked consent and separate customer directories pass. Reference: [Microsoft 365 integration](https://www.3cx.com/docs/manual/microsoft-365/).
- [ ] **INTEGRATION-02 — Google Workspace (Build).** Add equivalent supported sign-in, directory, contacts and calendar workflows. Done when sync ownership, conflicts, account changes and revoked access behave predictably without affecting another tenant.
- [ ] **INTEGRATION-03 — Microsoft Teams calling (Build).** Add a qualified direct-routing workflow and presence mapping. Done when supported accounts can make, receive and transfer calls through the PBX with documented external requirements.
- [ ] **INTEGRATION-04 — CRM connectors (Build).** Inventory every connector in the comparison baseline and implement/test customer lookup, screen opening, activity logging and supported record creation. Done per connector only after a named version passes with a test account; a generic API alone does not complete the catalogue. Reference: [3CX CRM catalogue](https://www.3cx.com/docs/crm-integration-guides/).
- [ ] **INTEGRATION-05 — Public management and call APIs (Build).** Provide documented, versioned APIs and events for user/service provisioning and permitted call control. Done when sample integrations work with scoped credentials, replay handling, rate limits and permission checks.
- [ ] **INTEGRATION-06 — Integration setup and troubleshooting (Build).** Put connection tests, status, reconnect and secret rotation in Admin. Done when an administrator can repair a disconnected integration without accessing server files.

## P2 — Chat and customer messaging

- [ ] **MESSAGE-01 — Team messaging (Build).** Add direct/group chat, permitted file sharing, history and notifications to replacement apps. Done when delivery, reconnects, membership changes and tenant isolation pass.
- [ ] **MESSAGE-02 — Website chat (Build).** Provide an embeddable widget and WordPress setup with opening hours, queue assignment and escalation to a call. Done when website visitors and agents can finish a conversation without losing its history.
- [ ] **MESSAGE-03 — SMS and MMS (Build).** Connect supported providers, route numbers to teams and handle media/delivery status. Done when inbound/outbound messages and webhook retries pass with a real provider account.
- [ ] **MESSAGE-04 — WhatsApp (Build).** Add business-account connection and supported message/template/media handling. Done when the real channel passes inbound/outbound, reassignment and expiry/failure scenarios.
- [ ] **MESSAGE-05 — Facebook messaging (Build).** Add page connection, conversations and team assignment. Done when access revocation, duplicate events and message delivery pass with a test page.
- [ ] **MESSAGE-06 — Public contact links (Build).** Provide OpenWeb call/chat links for users and teams. Done when visitors can reach the intended destination and abuse controls protect the PBX.
- [ ] **MESSAGE-07 — Unified inbox and chat reporting (Build).** Add ownership, handover, search, response statistics, export and retention across supported channels. Done when conversations and reports reconcile without exposing another company's messages.

## P2 — Meetings and AI

- [ ] **MEETING-01 — Audio/video meetings (Verify/Build).** Integrate existing conferencing capabilities and add browser meetings, invitations, dial-in, host controls and recording. Done when supported clients join reliably from different networks and host permissions are enforced.
- [ ] **MEETING-02 — Meeting collaboration (Build).** Add screen/document sharing, polls and consent-based remote assistance. Done when each function works for hosts/guests and access ends when sharing or the meeting ends.
- [ ] **MEETING-03 — Self-hosted capacity (Build/Verify).** Provide the meeting service, scheduling and deployment guidance needed for an independent installation. Done when measured audio/video capacity meets the documented comparison target on published hardware.
- [ ] **AI-01 — Transcription (Build/Verify).** Add call/voicemail transcription with speaker labels and selectable local or supported external processing. Done when queued work survives failures, permissions protect transcripts and accuracy is measured on representative languages/audio.
- [ ] **AI-02 — Summaries and analysis (Build).** Provide searchable summaries, sentiment and agent-quality reports linked to source calls. Done when evaluation examples demonstrate useful results and authorized users can inspect the original evidence.
- [ ] **AI-03 — Voice assistants (Build).** Add receptionist, personal-assistant and call-screening flows with knowledge sources and human transfer. Done when realistic callers can finish supported tasks and failed/uncertain requests reach the configured human destination.
- [ ] **AI-04 — AI administration (Build).** Expose provider/local-model setup, consent, retention, usage limits and fallback behavior. Done when disabling an AI service or exhausting its budget leaves ordinary calling usable and removes access as configured.

These areas complete the broader [3CX feature catalogue](https://www.3cx.com/ordering/pricing/features/). Each implementation must name its supported provider/model and test coverage; third-party service fees are separate from free OpenWeb software.

## P1 — C#, native platforms and reliable operation

- [ ] **PLATFORM-01 — Complete the C# application work (Partial).** Move remaining application/business APIs and administration functionality into the intended .NET 10 architecture, with staged data migration and regression checks. Done when all promised C# application workflows run on both OSes; document any retained native FreeSWITCH engine separately. The present background worker is not a full application rewrite.
- [ ] **PLATFORM-02 — Finish the WinUI administration experience (Partial).** Extend the current installer/status/browser-launch manager with the planned native administration and diagnostics. Done when normal install, connect, update and recovery workflows are tested in Visual Studio 2026 builds on supported Windows Server releases.
- [ ] **PLATFORM-03 — In-place upgrades and rollback (Build).** Add versioned migrations, pre-update backups, maintenance state and recovery for both platforms. Done when upgrading from 1.0.2 preserves tenants, credentials, media and calling, and an interrupted update can recover without rerunning a fresh installer.
- [ ] **PLATFORM-04 — Signed Windows distribution (Build).** Sign the application and installer, secure update verification and complete repair/uninstall behavior. Done when clean machines verify publisher identity and upgrades do not damage unrelated applications or private data.
- [ ] **PLATFORM-05 — Reproducible builds and release automation (Partial).** Build the engine, .NET service, Windows manager and packages from documented source in clean CI workers. Done when automated tests, dependency inventories, license checks, hashes and private-data exclusions run before publication. The engine recipe has not yet passed a clean rebuild comparison.
- [ ] **PLATFORM-06 — High availability and disaster recovery (Build/Verify).** Add monitored standby operation, scheduled restore/synchronization and controlled failover/failback. Done when server-loss drills measure recovery/data-loss windows and cannot leave two systems placing the same calls.
- [ ] **PLATFORM-07 — Capacity and endurance (Verify).** Define capacity tiers, then test many tenants, registrations, calls, callbacks, recordings and wake-ups over sustained runs. Done when resource limits, recovery after overload and recommended hardware are published from measurements.
- [ ] **PLATFORM-08 — Supported deployment matrix (Verify).** Declare exact Windows Server editions, Debian 13 architecture and virtual/cloud environments; test installation, reboot, patching and recovery. Done when every advertised combination has evidence. Current qualification covers Windows Server 2025 Desktop Experience and Debian 13 amd64.
- [ ] **PLATFORM-09 — Windows 10 and 11 server editions (Build/Verify).** Add an installation path for supported desktop Windows editions and qualify the full PBX on actual Windows 10/11 systems. Done when clean installation, calling, recovery and updates pass and qualified downloads are published. The 1.0.2 installer uses Windows Server components; the homepage correctly lists desktop Windows server editions as planned.

## P1/P2 — Completion and public release requirements

- [ ] **SCOPE-01 — Maintain a complete feature-to-test map (Partial; P1).** Expand each catalogue entry and V20 workflow into linked implementation/test cases under these IDs, including each provider, phone and integration variant. Done when no baseline feature is unclassified and every claimed equivalent has repeatable evidence. New vendor features require a dated scope update.
- [ ] **RELEASE-01 — End-to-end regression suite (Partial; P1).** Automate the installer, migration, tenant, app, call, queue and hotel scenarios, with real engine/audio checks where relevant. Done when both platform release candidates pass and test records are removed without changing customer data.
- [ ] **RELEASE-02 — Access and abuse controls (Partial; P1).** Qualify roles, second-factor sign-in, session revocation, phone/call abuse limits, administration network restrictions and audit logs across all new interfaces. Done when permission and isolation checks cover successful and denied operations, including recordings and APIs.
- [ ] **RELEASE-03 — Prove setup simplicity (Verify; P1).** Have new administrators independently install, restore, add a phone/provider, change hours, create a queue and recover a backup using only the product and its help. Done when both OS workflows need no developer intervention; record task times and fix observed stumbling points.
- [ ] **RELEASE-04 — Free and maintainable distribution (Partial; P1).** Preserve compatible open-source licenses, source/build availability and a dependency update process; document external account/service costs. Done when the declared OpenWeb feature set has no OpenWeb license paywall and a new contributor can build and maintain it.
- [ ] **RELEASE-05 — Final feature-equivalence release (Build/Verify; P2).** Publish tested Windows/Debian installers, upgrade instructions, app downloads, compatibility matrices and release evidence. Done when every in-scope task is closed, differences are explicitly documented and the public claims match actual results. Preserve the already-published 1.0.2 tag and use new versions for new binaries.

## Public project website

- [x] **WEB-01 — Homepage and current release catalogue.** Built the Windows 11-inspired nonprofit/open-source homepage with interactive desktop controls, service cards, mission, project links and current release downloads. Published a [live preview](https://call.openweb.co.za/openwebpbx-preview/) on 2026-10-08. Browser checks cover desktop/mobile, all six feature dialogs, Start search, window controls, themes, keyboard use and no-JavaScript downloads. Download/support labels reflect the verified 1.0.2 platforms. Source and maintenance instructions: [website](website/README.md).
- [ ] **WEB-02 — Publish on openwebpbx.com (Needs input; P0).** Deploy the reviewed public files to the domain's existing cPanel document root and verify live HTTPS, redirects and downloaded file hashes. Done when the homepage works at the requested domain. The token is stored privately and the cPanel endpoint is reachable; the account username is still needed to authenticate. Preserve the current DNS/mail routing and keep the website release catalogue current with future publications.

## External inputs needed for final verification

| Input | Work it unlocks | Current state |
| --- | --- | --- |
| Working SIP trunk, test numbers and provider-approved test procedure | CALL-01/02/07, QUEUE-02, outside calls and charging | Imported trunks are off; no carrier qualification yet |
| Outgoing SMTP relay and permitted test inboxes | SETUP-05, report and voicemail delivery | Local transport tests passed; no production relay configured |
| Missing source audio/destinations and chosen active greetings | RESTORE-01 | Backup omissions need recovery or explicit replacement |
| Authorized backups from additional V20 builds, including encrypted samples | RESTORE-02/03 | Only the observed native Update 9 build is verified |
| Representative phones, headsets and remote networks | APP, PHONE and interoperability checks | Local software-phone tests do not qualify hardware |
| Public Windows PBX hostname/DNS and deployment network settings | SETUP-03/04 and remote Windows calling | Windows test installation currently uses local HTTPS |
| Hotel test systems/protocol access and tariff examples | HOTEL-05–08 and full hotel acceptance | No PMS or billing connection qualified |
| Mobile signing/push identities and test devices | APP-03/04 | Replacement mobile apps are not built |
| Test accounts for business, messaging and AI connectors | INTEGRATION, MESSAGE and hosted AI qualification | Validate separately for each supported service |
| Windows signing identity and additional platform/hardware test capacity | PLATFORM-04/07/08 | 1.0.2 binaries are unsigned; broad capacity remains unmeasured |
| cPanel account username | WEB-02 | Token saved privately; verified endpoint available; production website publishing pending |

Development and local test doubles can proceed before these inputs arrive; external qualification stays open until it is actually performed.

## Update history

| Date | Change | Evidence |
| --- | --- | --- |
| 2026-10-08 | Created the maintained roadmap from the released 1.0.2 baseline, current source/guides and official comparison documentation. Identified remaining implementation, verification and external-input work; corrected obsolete callback and backup-reader guide statements. | Release tag `30036bb82`; [verification history](AGENTS.md); [feature coverage](docs/feature-coverage.md). Documentation review only; no new calling or compatibility test is claimed. |
| 2026-10-08 | Added the nonprofit project homepage, verified release catalogue and browser-tested live preview. Recorded the missing cPanel username and the Windows 10/11 installer qualification gap. | WEB-01/02, PLATFORM-09; [website maintenance](website/README.md). Existing 1.0.2 binaries and qualification claims are unchanged. |
