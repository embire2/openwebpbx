# Debian changes to carry into Windows

Updated **19 November 2026**. This is the change ledger for Windows catch-up,
alongside the [release process](independent-platform-releases.md). Add a row
for every Debian feature, calling fix, migration or deployment change. Keep
the originating version and source commit even when Windows ships it later.
Update the Windows result only after checking the actual Windows package.

## Current versions

| Component | Current status |
|---|---|
| Hosted Debian at call.openweb.co.za | **1.0.26**, including matching native Core and updater; public installer27 is a separately qualified full release. |
| Public Debian installer | **1.0.27**, complete standalone installer; no previous PBX required. Source `72bb5406af4c057acb5ee4eddfd9d861d20d345f`; [qualification](release-1.0.27-qualification.md). |
| Public Windows installer | **1.0.23**, source `e1aaad63f99ac3b11714d9d0cd3f2a085778688f`; [qualification](release-windows-1.0.23-qualification.md). |
| Android | **1.0.19**. Server fixes do not imply an Android release. |

A hosted deployment, source commit and downloadable installer are separate
statuses. Debian 1.0.26 contains the Debian 24–26 features below. Windows remains its
separately qualified 1.0.23 suite; these rows do not imply Windows 26 parity.

## Hosted outgoing-call repair — 18 November 2026

| ID | Hosted acceptance | Windows follow-up |
| --- | --- | --- |
| H26-CALL-01 | `d2a7a9a4c`: configured script-root loading avoids a Lua logging-global collision before provider selection.494 regressions pass; owner confirms Android1000 outgoing call and sound both ways. No routing/credential change. | Included in frozen candidate `0bdfe5481` through `dfd710b951`; full package and actual Windows call acceptance pending. Public Windows23 and immutable Debian27 archives are unchanged. Carry into the next independently qualified Debian package. |
| H26-CALL-02 | [Calling release safeguards](calling-release-safeguards.md) and automatic 494-control push/PR workflow. Original policy fails the new regression; corrected policy passes. | Source-level check is shared. Real-engine call/media gates, required branch rules, live alerts and automated code rollback remain separate follow-up work; not claimed complete. |

## Hosted tenant API — 18 November 2026

Hosted PHP/UI source `2120ab3b073ce529cdc5fb4ee1fe8e6625de412b` adds the
installation-local tenant reference at `/api-docs` and a **Full tenant
administration** key preset. Nine existing scopes cover a tenant's current and
future CloudPBXs without instance, reseller or cross-tenant authority. Native
Main stays26; public Debian27 and Android19 artifacts/feeds remain unchanged.

| ID | Hosted acceptance | Windows follow-up |
| --- | --- | --- |
| H26-API-01 | Local123-path/153-operation reference/OpenAPI; tenant/PBX menus and key preset.26+117 PostgreSQL,29 DOM,334 reference,308 existing contract controls and actual UI key creation/revocation/isolation pass. [Guide](tenant-admin-api.md). | **Not in frozen Windows80526 package.** Carry the local reference/router/menu/preset and relevant isolation checks into a later independent Windows build. Do not describe the current Windows27 candidate as including this later overlay. |

## Debian 1.0.27 standalone release — 17 November 2026

One complete archive installs directly on clean Debian13 with no earlier PBX
or separate PBX patch. Package metadata and read-only preflight make this
explicit; existing-data updater admission remains a separate contract. Hosted
Main stays26. Public Windows23 and Android19 retain their own qualified bytes.

| ID | Debian change | Debian acceptance | Windows follow-up |
| --- | --- | --- | --- |
| D27-01 | Full-package installation metadata; no previous PBX required | Published27, source `72bb5406af4c057acb5ee4eddfd9d861d20d345f`; exact clean-machine/full-suite checks in the qualification record | Include and enforce full-release metadata in the next complete Windows package; qualify clean Server2025 setup |
| D27-02 | Help/check and full payload/old-data refusal before PBX/data writers | Published27; ordinary no-write/preflight and full installation checked separately from existing-data updates | Integrate the current ordered updater and required components; new full-package users must not apply the legacy repair |

[Installation](installing-1.0.27.md) · [Actual and reused evidence](release-1.0.27-qualification.md).
Existing D24–D26 Windows catch-up rows remain open until the relevant Windows
package passes; a newer Debian version does not claim Windows parity.

## Debian 1.0.26 public release — 16 November 2026

Debian 1.0.26 is independently published with signed minimum 1.0.22, immutable
`debian-v1.0.26` source and matching canonical `v1.0.26` assets. The earlier
Nov11 candidate retains its separate evidence. Windows remains 1.0.23 plus its
additive updater repair; Android remains 1.0.19.

[Installation](installing-1.0.26.md) · [Actual qualification](release-1.0.26-qualification.md).
Rows D24–D26 remain Windows catch-up requirements; shared source does not accept
a port. Existing dated evidence retains its original scope.

## Changes since the Windows 1.0.22 baseline

| ID | Debian version | Feature or fix | Debian status and source | Windows catch-up status / required checks |
|---|---|---|---|---|
| D23-01 | 1.0.23 | One add/edit DID wizard and one incoming destination; trunk and number pages show the same route. | Hosted and public; `d27583e7`. | **Published Windows 23.** Actual PostgreSQL/browser checks and final signed update/data preservation pass. |
| D23-02 | 1.0.23 | Preserve leading zeros on external forwarding; explicitly match local/international DID forms and prevent a disabled number falling through to another trunk destination. | Hosted and public; `d27583e7`. | **Published Windows 23.** Route/number-format controls and original-data restore/reapply pass. |
| D23-03 | 1.0.23 | Select Call Me Back as a DID destination; guide service setup without replacing the old route before it is ready. | Hosted and public; `d27583e7`. | **Published Windows 23.** Actual browser handover checks pass. |
| D23-04 | 1.0.23 | Saved per-PBX number format, including supported restore mapping, without guessing a country for an existing PBX. | Hosted and public; `d27583e7`. | **Published Windows 23.** Per-PBX controls and original configuration preservation pass. |
| D23-05 | 1.0.23 | Complete Debian package includes stable reusable QR credentials and their additive migration. Viewing, emailing or scanning does not rotate a code. | Public 23 and hosted; [QR behavior](../readme.md#connect-android-with-a-qr-code). | Included in Windows 22 and 23. Final signed update and original-data restore/reapply preserve QR setup. Recheck future migration changes. |
| D23-06 | 1.0.23 | Shared RTP timestamp policy and ordinary provider routing retained through the DID changes. | Debian fresh and signed-upgrade UDP/TLS software calls pass. | **Published Windows 23** retains its Windows-only receive buffer policy. Four registrations/four two-way calls and all 16 audio streams pass. Preserve that policy during later ports. |
| D24-01 | 1.0.24 | Select a SIP trunk for the callback-to-client leg only. Preserve onward provider selection, normal routing and incoming destinations. | Live and committed `6471988d0`. | **To port.** Test selected-provider auth/caller ID/availability, no silent fallback, and unchanged onward/default routes. |
| D24-02 | 1.0.24 | Nine named speed dials, slots 1–9, managed by administrators and an explicitly linked user's My PBX page. | Live and committed `6471988d0`. | **To port.** Apply additive schema; test tenant/user isolation, unique account links and clear/save validation. |
| D24-03 | 1.0.24 | Authenticated callback DTMF can save, clear and call speed dials. Linked PBX phones can use `**1` through `**9`. | Live and committed `6471988d0`. | **To port.** Test production Lua, permissions, prefix checks, quota/time limits and ordinary provider choice for direct shortcuts. |
| D24-04 | 1.0.24 | Administrators edit nine Keoma script stages, including callback prompts; display requested, recorded and default text. | Live and committed `6471988d0`. | **To port.** Check all stages, `{companyname}` substitution, length limits and Windows audio paths. |
| D24-05 | 1.0.24 | Generate narration through the existing Greetings worker. Keep the previous ready recording during generation or provider failure. | Live; one ordinary Keoma job and HTTPS playback verified. | **To port.** Exercise actual worker/audio generation, immutable versions and failure fallback. Preserve custom recordings. |
| D24-06 | 1.0.24 | Confirmed **Reset Default Scripts** removes assignments/text overrides without deleting recordings. | Live and committed `6471988d0`. | **To port.** Verify default selection, active-recording archive guards and unchanged custom audio. |
| D24-07 | 1.0.24 | Additive callback schema and matching native Core/updater version metadata. | Live; existing rows, QR/private configuration and calling-engine generation preserved. Native build defaults match checkout VERSION24; the deployed binaries already use explicit Version24. | **To port.** Include schema in fresh install and upgrade; test restore from older schemas, native version coherence and signed update/recovery. Keep the frozen Windows23 checkout at Version23. |
| D24-08 | 1.0.24 | Restore extension 1000's original provider selection after the replacement provider rejects calls with 403 Auth Failed. | **Live; user confirms Android connects with sound both ways.** The original-credential software call also returns 200 through the existing OpenWeb Porta provider; its configured G.729 is preserved. New reseller account still needs provider-side correction. [Details](outgoing-calls-1.0.24.md). | **Hosted configuration only.** Do not copy this customer's route into Windows or other tenants. Test their own permitted provider and caller ID. |
| D24-09 | 1.0.24 | Honour imported provider SRTPDisabled on its outgoing leg and display that effective setting when editing provider options. | **Live**, `06f139229`. Explicit options override the imported default; native mandatory-SRTP caller/plain-provider check passes. | **To port.** Preserve the phone's encryption and configured codec order. Test restored plain providers, explicit overrides and native media negotiation. |
| D24-10 | 1.0.24 | Distinguish 183 early media from an actual answer in outgoing/queue callback attempts; preserve final rejection and existing safe fallback policy. | **Live**, `06f139229`. Actual-answer hooks and final bridge cause control results; answered calls never duplicate, and no backup is invented. | **To port.** Run 183→403/503, genuine-answer→later-error, cancellation, unknown-success and last-provider-failure regressions plus native calls. |

The full 1.0.24 feature scope, scripts and verification are in
[Call Me Back and Speed Dial](call-me-back-1.0.24.md). Actual carrier/handset
acceptance remains separate from isolated provider and software-phone checks.

## Windows-specific changes to preserve

| Change | Source / status | Keep when carrying Debian changes forward |
|---|---|---|
| Recover permissions after the normal importer has consumed a transient call-record XML file. | `03050db58823dc5c5c014cadede83296fb00a620`; corrected Windows source `e1aaad63f9`. Native 89 controls, actual corrected recovery and genuine normal 22-to-23 update pass; unchanged late rollback is explicitly reused from Windows 22. [Scope](release-windows-1.0.23-qualification.md). | Only the narrowly validated absent default-spool UUID file is admitted. Keep all other ACL, link and I/O denials. |
| Windows receive buffer while bridging. | Published Windows 23; [actual scope](windows-local-1.0.23.md). | Preserve explicit administrator choices and the separate POSIX behavior. |
| Native manager and five-minute update notice. | Public Windows 22 baseline retained in 23; automatic updater/manager restart verified on the final 23 package. | Keep desktop modal, web notice, service continuity before installation, verified predownload, call-aware installation and restart. |
| Signed ordered Windows upgrades and legacy bootstrap. | Updater component `1.0.23+upgrade-path.1`; [scope and qualification](windows-upgrade-path-repair.md). **Published repair, 16 November:** actual 21→22→23 transactions, preserved customer identities and final launcher pass. Full 23 installers/feeds retain their original bytes. | Retain separate catalogue trust, exact historical envelopes, current installed-version admission, one bounded approval, call-aware backups/recovery and catalogue publication guards. Do not infer Debian26 feature parity. |
| Windows API verbs and upload admission. | Frozen Windows source `06d651d49`; actual company/admin/personal controls and isolated API/UI/upload controls pass. Retained failures include IIS401.3 before PHP. | Preserve scoped PHP method mapping, native file permissions and explicit upload-module preconditions. Exact final6 whole-package API and restore acceptance is still required. |
| PowerShell5.1 protection-worker entrypoint. | `fcf21dd48` retains the one-line native argument correction;23 actual Windows controls prove old failure, corrected argv/body-once/exit codes and isolated Python paths. | Keep single-quoted Python literals inside the PowerShell native command. Actual tenant and full backup/restore remain release gates; source tests alone are insufficient. |
| Windows background onboarding admission. | `5b264a7f0`;28 portable and15 native controls accept a30-second background acquisition while foreground5/Linux behavior and authority remain intact. | Propagate explicit background context to image helpers and scheduled ticks; preserve fail-closed I/O, restore holds and one execution of the business body. New full installation/registration must pass. |
| Bootstrap IIS object lifecycle. | `61325afe1`; unforced old/current native reproduction proves cached-object HRESULT0x800710D8 and corrected HTTP200, with original IIS/runtime/services restored exactly. | Reacquire the site/pool through a new manager after commit. Exact-source CI has five source controls; native IIS is separate. Final6 clean-install acceptance is pending. |

Windows27 also retains dedicated legacy terminal handoff (`ced796783`) and
pre-claim registration snapshot coordination (`138c5cef2`). These Windows-specific
source corrections have native controls; public Windows stays23 until actual
whole-package rollback, upgrade, fresh setup, recovery and public readback pass.
Source-assisted manual recovery of the earlier failed candidate remains separate.
Current frozen source is `61325afe155950c2b8961f8001054eb9d246c92e`;
[qualification](release-windows-1.0.27-qualification.md) distinguishes actual, reused
and failed results. Public Windows remains23. Port later hosted API presets/local
docs independently; a version cannot prove parity.

## Before promoting a Windows catch-up release

1. Freeze a Windows source commit; include each applicable row above and
   record deliberate platform differences. Never infer parity from `VERSION`.
2. Check Windows paths, service accounts, audio access and native dependencies.
   Exercise the additive migration in fresh install, upgrade and old-backup
   restore. Preserve phone passwords, reusable QR codes and custom recordings.
3. Run the affected browser, PostgreSQL and production-Lua controls plus
   software calls. Qualify signed installation/recovery using the complete
   Windows package. Reuse explicitly unchanged evidence instead of rebuilding
   unrelated native dependencies.
4. Record the tested package/source hashes, update this ledger and the Windows
   qualification document, then publish Windows independently. Retain Debian
   and Android signed feeds byte-for-byte and update the README/download site.

## Hosted Debian 1.0.25 — 6 November 2026

| ID | Feature | Debian status | Windows acceptance required |
|---|---|---|---|
| D25-01 | Full-instance backup from Dashboard; verified and confirmed web restore | Live; encrypted engine retained, browser access and disposable-tenant worker round trip pass. Full production media backup/download and isolated replacement recovery now pass; see the [9 November record](backup-recovery-2026-11-09.md). | Port root recovery queue to SYSTEM and qualify populated-target rollback, private identity/media and service restart. |
| D25-02 | Tenant-scoped encrypted backup/download/check/restore | Live; same-instance recovery, current credentials/usage/history/ownership/keys/billing preserved. | Port worker paths/ACLs, tenant media isolation, authentication/tamper checks and failure recovery. |
| D25-03 | Reseller packages, extension allowances and simultaneous-call admission | Live; 47 PostgreSQL and 21 native admission controls pass. Legacy allocations remain unchanged. | Port schema and atomic calling admission; test concurrent registrations/calls and Windows audio policy unchanged. |
| D25-04 | Templates with provider presets, package binding and working modern administration | Live; modern template provisioning and starter package verified. | Test fresh template services, isolated provider credentials, defaults and restored legacy tenants. |
| D25-05 | Hosted resource pricing, repeat-safe orders and explicit approval | Live; priced requests and approvals. Payment collection remains external. | Test owner/reseller/operator roles, no self-service quota escalation, approvals and self-hosting exemption. |
| D25-06 | Scoped API v2 and API key creation/expiry/rotation/revocation | Live; v1 preserved, 140 v2 paths/75 actions, fresh permissions and key ancestry checks. | Port front-controller hosting and fresh permission/scoping checks; qualify every supported operation and secret redaction. |
| D25-07 | Debian installer worker/API integration and matching native25 metadata | Live matching Core/updater25, isolated upload pool and root recovery timer; no new public installer claim | Independently build and qualify Windows package after the feature ports. Do not reuse Linux worker units. |
| D25-08 | Long-backup heartbeats, automatic progress/session handling, balanced compression and correct restored status | Hosted 1.0.25 maintenance; 21 backup and 54 tenant checks pass. Actual full archive/download and replacement restore verified; results are in the [recovery record](backup-recovery-2026-11-09.md). | Port worker liveness/restored status to SYSTEM; bundle shared web changes and independently qualify large archives, service holds and recovery. Windows compression remains a separate implementation. |

[Hosted25 verification, storage and distribution limits](reseller-1.0.25.md). Windows catch-up must preserve current app/QR revocations, callback usage and history during tenant recovery; port the body-free upload admission and isolated worker behavior.

Windows upload ports must isolate body-reading settings from ordinary web and phone XML handlers; Debian uses a separate PHP pool and body-free server admission. Qualify ordinary sign-in, registrations, header CSRF, early rejection and populated restore.

## Hosted Debian 1.0.26 — 11 November 2026

| ID | Feature | Debian status | Windows acceptance required |
|---|---|---|---|
| D26-01 | Personal API keys and `/me` workflows | Live; current extension identity, own calls/voicemail/status/devices/password/QR/contacts/speed dials/conferences. Role withdrawal tested through both public API addresses. | Port web navigation and current-role validation; test ownership, expiry, delegation, QR stability and app/desk-phone credential separation. |
| D26-02 | Explicit department API authority | Live; `/staff` applies existing roles to configuration, reports, media, calls and staff delegation even for broadly privileged issuers. | Verify injected access scope on Windows; no inherited owner bypass; cross-department and cross-tenant denial. |
| D26-03 | Company/personal contact CRUD | Live; ownership and validation, transactional updates, stable imported contact IDs. | Exercise imported contacts, concurrent writes and no changes to unrelated entries. |
| D26-04 | Public API gateway, comprehensive docs and panel links | Live; 197 paths/250 operations; API Keys and API Documentation in both admin panels and My PBX; v1 preserved. | Port installation front-controller hosting, API auth/body admission, public links and all supported routes. Public hosted gateway is nginx-specific, not an IIS configuration to copy. |
| D26-05 | Matching26 native metadata and complete Debian bundle | Public 26 with matching Core/updater, source `5b60f57458ab336cc5c9e928128054b8d9491bba`; 488851358B/SHA256`3f951c94b2454e4f232f07126d3782ae8a2fa6e9d51fed270f2c27112963cfb5`. Fresh/upgrade/recovery acceptance is recorded separately; the old local candidate retains its own evidence. | Build Windows independently; qualify complete package, service-account file access, signed upgrade/rollback and backup recovery. Never set a version to claim parity. |
| D26-06 | Web personal API stable QR/reset uses live staff-key authority; native app password-generation guard stays separate | Published Debian 1.0.26, source5b60;18focused controls, diagnostic16controls and15actual personal API controls on the corrected unmodified fresh package pass. Original QR identities and role-withdrawal boundaries are verified. | Port exact PHP dispatches; verify me:credentials/write/confirmation, current own binding, stable reuse and role withdrawal without resetting unrelated QR identities. |
| D26-07 | Accept exact stock Debian22 root-plus-index nginx syntax when installing reseller/API support | Published Debian 1.0.26, source5b60;17installer controls and actual original22/23 signed upgrades plus original22 late-failure automatic recovery pass. | Linux nginx integration only; preserve Windows IIS guards. Do not copy this parser into Windows or infer Windows26 parity. |

[Actual API scope and tests](api-1.0.26.md). Public Windows remains1.0.23.
