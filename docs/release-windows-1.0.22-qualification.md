# Windows Server 1.0.22 qualification

<!-- WINDOWS22-RELEASE-STATUS-BEGIN -->
**Windows Server 1.0.22 — published 2026-11-04T01:59:14Z.** The unchanged product `8f4256e4e3cbce092791eea60d1c053e10810bb6` passes the complete software suite, actual restore/reboot, distinct fresh managed installation and signed updater cases [41752080297](https://github.com/embire2/openwebpbx/actions/runs/41752080297) (original worker enabled) and [41722715796](https://github.com/embire2/openwebpbx/actions/runs/41722715796) (original worker disabled). Public release assets/canonical mirror, retained Android/Debian envelopes and the ordinary installed Windows public-feed Check are verified. Qualification limits remain in force.
<!-- WINDOWS22-RELEASE-STATUS-END -->

## Package and supported route

Windows Server 1.0.22 targets **Windows Server 2025 x64 with Desktop Experience**. The complete package includes the local PostgreSQL database, call engine, IIS/PHP administration, native manager, updater and background services. Use the [installation guide](installing-windows-1.0.22.md). The separate Windows phone client remains in development.

| Item | Frozen identity |
|---|---|
| Product source | `8f4256e4e3cbce092791eea60d1c053e10810bb6` |
| Windows ZIP | `openwebpbx-1.0.22-windows-x64.zip` — 643,251,073 bytes; SHA-256 `66c93cdcfdf1a69ccbc478d68a335290da7174283921f25318dd94f0cf340c0b` |
| Corresponding application source | `openwebpbx-1.0.22-windows-source.tar.gz` — 49,886,646 bytes; SHA-256 `fae120e41a61b0b7732c8add68190d402830b90ac09795b040d63ad71f923d21` |
| External installation guide | `installing-windows-1.0.22.md` — 6,827 bytes; SHA-256 `baa5a86226e09d9bbfa96b29aabebac073a50b2ccb0f06968e3807781d143454` |
| Payload comparison | All 19,276 payload hashes and sizes match the independently built native package. The published ZIP must be the exact file above. |

The qualified signed upgrade minimum is **Windows 1.0.21**. Earlier releases need a separately supported transition. Fresh setup protects an existing installation; it is not an in-place upgrade. Windows backup restore and the 3CX configuration importer are separate paths. Same-host replacement checks do not establish a cross-IP or different-machine migration.

## Completed checks

| Component | Accepted evidence and scope |
|---|---|
| Complete software suite | [41627350841](https://github.com/embire2/openwebpbx/actions/runs/41627350841) passes in 78 minutes 35 seconds against the unchanged package. It includes genuine public21 upgrade/rollback and the suite's native/runtime feature checks. Final signed transaction cases remain separate below. |
| Clean restoration | A clean native RestoreServer installation imports the retained older Windows archive. The ordinary restore completes in 447.395 seconds inside its original 600-second bound. Tenant data, original extension authentication, registration files, instance key and all 14 source recordings are preserved; the fresh target database identity remains its own. |
| Restored Users and QR | Ordinary Users edit and QR pages pass after the automatic mobile-only schema migration. No manual SQL repair substitutes for the restore path. |
| Restored calling and reboot | Four original-credential registrations and four decoded two-way calls over UDP/TLS pass before and after one actual reboot. Both full packet captures, including tails, contain 16 PCMU streams each with zero strict packet/clock errors. Trusted canonical web access, tenant API, authorization and four services return within the original 300-second reboot window. |
| Restored encrypted backup | Ordinary scheduler-processed backup creation, content verification and off-server copy complete within the original 600-second bound. All 22 recordings then present, registration files and instance key verify. |
| Distinct fresh managed installation | Stock managed setup generates a new native installation identity/key. Ordinary verified-owner login and one public-wizard claim reach Ready through normal background tasks. The local PBX/database remain on the Windows server. No manual worker, fabricated readiness, DNS/cache repair or clock reset is used. |
| Fresh users, QR and calls | Two ordinary users pass all eight UDP/TLS registration/calling cases. Full-wire replay covers all 16 PCMU streams/3,363 packets including tails with zero errors. Thirty-four QR portal/enrollment/bootstrap checks preserve the same code across reloads, independent sessions, exports and two software enrollments; only those two temporary devices are self-revoked. |
| First natural scheduled backup | One ordinary backup-settings save produces a command with no user requester. The normal scheduler creates the encrypted archive; verification and off-server copy finish in 68.960 seconds within the original 600-second bound. All 471 files, four fresh recordings, both registration files and the instance key verify. The complete wizard-to-backup flow takes 17 minutes 34 seconds inside its original 40-minute limit. |

The restored-server reboot is an accepted separate component of the same final product. No second fresh-install reboot is claimed. Actual fresh pre-owner checks cover the ordinary UI/setup gate; a valid-credential pre-owner SIP refusal was not executed in that case. The complete software suite's native registration gate has its own scope.

## Signed update and public delivery

| Gate | Accepted result |
|---|---|
| Signed actual public21 update, original worker enabled | **PASS** — [41752080297](https://github.com/embire2/openwebpbx/actions/runs/41752080297); unchanged actual package/pair, required upgrade/fault/operator-restore/manager/protection gates and cleanup. |
| Signed actual public21 update, original worker disabled | **PASS** — [41722715796](https://github.com/embire2/openwebpbx/actions/runs/41722715796); the original disabled task choice is preserved. |
| Public release and retained assets | **PASS** — seven release assets and the exact ZIP canonical mirror verify; original release assets/tags/body/checksums and retained Android/Debian envelopes are preserved. |
| Ordinary installed public update Check | **PASS** — current Windows22 accepts the actual public signed Windows22 feed/minimum21 and same-version result; no archive installation or download is claimed by Check. |

Earlier runs remain failed: [41738665149](https://github.com/embire2/openwebpbx/actions/runs/41738665149) exhausted its tenant-initialization window; [41744764313](https://github.com/embire2/openwebpbx/actions/runs/41744764313) failed because the QA process-proof dependency was imported after first use; [41747961846](https://github.com/embire2/openwebpbx/actions/runs/41747961846) passed the ordinary updater startup milestone, then exhausted its original shared600-second window with all eight tenant-initialization paths absent. The actual historical lock holder was not captured. The later enabled case above supplies its own acceptance.

The enabled signed fixture first observes the exact original21 updater's ordinary first tick with Core running. It then quiets only the owned Core for natural tenant initialization and the original backup warmup. Startup and tenant initialization share one original600-second bound; backup warmup retains its original60-second/first-success criteria. Core's captured running choice is restored before preservation baselines and signed laboratory exposure. Original task choices, all eight initialization paths, identity guards, product locks, file/database/security comparisons and deadlines remain in force. Failure diagnostics stay private/encrypted; they do not convert earlier failed cases into passes. See the [Windows qualification history](windows-parity-1.0.22.md).

## Features and limits

Managed installation uses the same [public wizard](https://openwebpbx.com/wizard) as Debian. Reusable phone QR codes are included in **Windows Server 1.0.22 and the hosted service**. Viewing, emailing, exporting, scanning and password changes preserve the code; an explicit scoped reset invalidates earlier codes/files while retaining connected devices. Existing valid legacy invitations keep their validity; expired or consumed invitations are not revived. The older published Debian 1.0.22 archive does not automatically inherit the hosted QR correction.

Software calling uses the provisioned SIP realm and canonical SIP endpoint/TLS name. Tenant-alias trusted HTTPS/API is checked separately. Recorded media thresholds remain unchanged, and packet replay includes call endings. These results do not qualify physical handsets, carrier cutovers, camera scanning, mobile SRTP calling, restrictive-network/TURN coverage, capacity, universal email delivery or Store publication. Google Play publication and the separate Windows phone client retain their stated status.

Linux, Windows and Android advance from their own qualified commits, minima and signed feeds. A later Linux release does not rebuild or relabel this Windows package. The release selected as latest carries all three envelopes, preserving the other platforms' bytes; matching version numbers do not establish compatibility. See [independent platform releases](independent-platform-releases.md). This Windows release does not replace or relabel the existing Debian 1.0.22 or Android 1.0.19 artifacts.
