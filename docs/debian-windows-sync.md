# Debian changes to carry into Windows

Updated **5 November 2026**. This is the change ledger for Windows catch-up,
alongside the [release process](independent-platform-releases.md). Add a row
for every Debian feature, calling fix, migration or deployment change. Keep
the originating version and source commit even when Windows ships it later.
Update the Windows result only after checking the actual Windows package.

## Current versions

| Component | Current status |
|---|---|
| Hosted Debian at call.openweb.co.za | **1.0.24**, including matching native Core and updater. |
| Public Debian installer | **1.0.23**, source `d27583e72018fcbd55c517a766697b8267658dc1`. |
| Public Windows installer | **1.0.23**, source `e1aaad63f99ac3b11714d9d0cd3f2a085778688f`; [qualification](release-windows-1.0.23-qualification.md). |
| Android | **1.0.19**. Server fixes do not imply an Android release. |

A hosted deployment, source commit and downloadable installer are separate
statuses. The hosted 1.0.24 changes below are not yet a public complete Debian
installer or a qualified Windows 1.0.24 package.

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
