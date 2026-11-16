# Debian 1.0.26 release qualification

**Debian 1.0.26 published on 16 November 2026 at 18:37:48 UTC.** Product qualification, anonymous download verification and an installed client's ordinary check against the real public feed all pass.

## Corrected release artifact

- Source: `5b60f57458ab336cc5c9e928128054b8d9491bba`.
- Archive: `openwebpbx-1.0.26-debian13-amd64.tar.gz`,488,851,358 bytes.
- SHA256: `3f951c94b2454e4f232f07126d3782ae8a2fa6e9d51fed270f2c27112963cfb5`.
- Manifest SHA256: `08dd1673be96f0cb9245ac6fef0f85cee4cc78562077f8ef0087be491f92bc3a`.
- All 12,253 payload files match their manifest, including 4,915 offline Keoma WAVs. The corrected source changes the two personal web-QR dispatches and the stock-site installer parser; it does not weaken native account-generation or registration checks.
- Core 26 reuse is explicit:21 tracked project inputs/props and16 portable-PDB source hashes match the earlier26 build; all 339 Core outputs match its verified archive. The updater is rebuilt from frozen source. Existing engine/source/licence provenance is retained; optional combined G729 binaries are not distributed.

## Superseded pre-correction artifact

- Source: `212e04de5fdbfbb2848604810aa22fdf7258a918` (superseded by corrected source `5b60f57458ab336cc5c9e928128054b8d9491bba`).
- Archive: `openwebpbx-1.0.26-debian13-amd64.tar.gz`,488,849,640 bytes.
- SHA256: `b3812c7c149c0b379e059fa15b8b2541184dd50e209dd49faf5c32fe578e7d30`.
- Its archive checks, original fresh install and diagnostic results remain evidence for that artifact only. They are not relabelled as qualification of the corrected archive above.

## Acceptance evidence

| Component | Result | Actual scope |
|---|---|---|
| Complete archive/source binding | PASS | Corrected 3f951 archive above, source archive and reviewed native input/output provenance |
| Stock fresh 26 installer | PASS,16 November | Corrected unmodified installer on clean Debian 13,17:57:31.576963–18:02:43.227291 UTC; exits0 in311.650347 seconds; managed registration remains required |
| Fresh 26 managed setup/features | PASS | Ordinary verified-owner wizard and natural DNS/trustedHTTPS readiness ; 11 company/user/QR controls, 28administration API controls and 15personal API controls, within the original setup deadline |
| Fresh 26 software calling | PASS, software only | Two owned endpoints register, answer an internal call, sustain two-way RTP with independently decoded 440/660 Hz tones, then unregister; 8 controls |
| Fresh 26 actual OS reboot | PASS | New boot identity; automatic Core 26Running and service readiness in41.486 seconds, without manual service starts |
| Public 22 baseline managed setup | PASS,16 November | Genuine published 22 archive; one ordinary owner claim and natural DNS/TLS; company/two owned users; one legacy invitation and ordinary software-device enrollment |
| Signed 22→26 late failure recovery | PASS,16 November | Distinct corrected private fault2 fixture reaches its intended late boundary; automatic rollback preserves 184 original tables, full captured schema/functions/triggers/roles, original files/configuration/links and custom WAV. The final package is not relabelled as this failure fixture |
| Signed 22→26 final upgrade | PASS,16 November | Original installed public 22 worker/helper and ordinary Admin request; 393.314231 seconds from queue to completion; natural 26worker finalization, original trust preserved |
| Signed 23→26 upgrade | PASS,16 November | Genuine public 23 baseline; one ordinary Admin Check and Install through its original worker/helper; natural 26completion/finalization and up-to-date status in475.052 seconds; no manual migration/recovery/finalization, version spoofing or trust reset |
| Public 23→26 preservation | PASS | All 184 original row projections and exact source-defined 11 new tables/defaults/schema/permissions; cluster/roles/passwords,324 private files, recordings and original directory/link security preserved. 12,293 source-bound file targets and the separately checked upload pool match; two exact source-compiled caches and the managed alias renderer are proved separately |
| Public 23→26 normal user access | PASS | 24 ordinary administrator/software-device identity checks and two existing stable-QR payload comparisons; original account, extension/authentication ID/password bytes and both reusable QR payloads remain exact |
| Public 22→26 final preservation/calling | PASS | 184 original table projections, exact source-defined schema changes, cluster/roles, private identities, custom media and12,293 source-bound file targets plus upload pool pass independent comparison; 24 ordinary credential/Bearer controls and 8 controlled software SIP/two-way RTP controls pass |
| Public promotion | PASS | Published at 18:37:48 UTC; latest `debian-v1.0.26` and canonical `v1.0.26` carry the same eight immutable asset bytes from source 5b60 |
| Anonymous public feeds/downloads | PASS | 20 actual anonymous downloads, 1,078,929,766 bytes SHA256-verified: both eight-asset tag sets plus the latest four feed/catalogue objects; 24 earlier public releases/assets retained; Android/Windows signed envelopes and Windows catalogue remain exact |
| Installed client's real public Check | PASS | Actual ordinary Admin Check completes at 18:38:45.297188 UTC against the real public signed feed: installed/available 26 and up-to-date; original trust and six service generations remain exact after owned test transport/hosts/CA removal |

The signed minimum is confirmed as 1.0.22 after actual published 22→26 and 23→26 transitions pass. This prevents the new latest-feed watermark stranding existing 22 clients; it is not lowered to hide a refusal. Public 22 and 23 helpers are byte-identical and invoke the candidate bootstrap/support hook, which seals additional recovery targets before writes and activates new workers only after commit. Actual runtime checks include upload-pool/protection-worker finalization, not just Core health.

## Preserved failures and limits

The older Nov11 candidate and the earlier documentation/compression candidate are retained as distinct unpromoted artifacts. One early controller correctly refused an incomplete baseline 22 transfer before any PBX/database mutation. Baseline22's transient guarded tenant-domain defer resolved through its normal timer. A browser's first 20-second navigation bound failed without writes; the later normal flow passed within the original whole deadline. Private GitHub draft-by-tag lookup returned 404 and was corrected through authenticated release/asset-ID lookup; temporary draft assets are not public promotion.

Private credentials, QR payloads, browser/log evidence, signing keys and customer backups are excluded from source/release assets. Main is never an install/restore target. Broader roadmap totals remain 133 goals / 21 accepted / 72 partial / 40 planned. Windows stays 23 plus its independent updater repair and Android stays 19. No new physical-phone, carrier, camera, Store approval, complete 3CX parity or Webhotel image publication follows from this installer qualification.

## Corrections found by actual qualification

The first registered-fresh 26 personal web-key QR call returned 503 because its
web authority was incorrectly sent through a native app password-generation
method. Two dispatches now use the existing own-extension checked web QR methods;
the native generation guard remains unchanged. Eighteen focused controls fail
against the old source and pass the corrected source. Actual diagnostic live
checks 16 preserve original 100/101 codes and confirm reset/confirmation/role
withdrawal only on a newly owned 303 fixture. This one-leaf diagnostic overlay is
not a new exact-package fresh-install acceptance.

The first signed22→26 transaction genuinely failed before its intended late
fault: the normal stock 22 HTTPS site writes `root /var/www/fusionpbx; index
index.php;` on one line. The reseller API installer wrongly required the root
directive to end the line. The corrected parser admits only that known suffix;
foreign/multiple roots and unknown trailing directives still refuse. Seventeen
installer controls and exact saved stock-site parsing pass. No installed security
guard was disabled.

That first automatic rollback is accepted **as the real early migration failure
recovery only**, not the intended late-witness case. It restores all original
runtime/private files, links, directories,184 original tables/schema/roles and the
custom WAV; only exact command/status/greeting heartbeat changes and one
source/interpreter-bound verifier cache are separate allowed differences. The
original software-device and desk-phone credentials pass24ordinary checks.
These failures required a corrected immutable archive, a new signed fault and
a final envelope. The affected fresh-install, late-recovery and final-upgrade
gates were repeated with those corrected artifacts, as recorded above.

Those affected fresh-install gates are now repeated with the corrected 3f951
archive, including the real managed wizard, administration/personal APIs,
software calling and actual OS reboot. The corrected late-fault rollback also
passes separately. The original public 23 installer has completed its normal
signed upgrade and preservation checks. The final public 22 transaction,
independent preservation and controlled software calling checks now pass too.
Public promotion, anonymous download verification and the ordinary
installed-client check against that real public release now pass independently.

The public 23 file comparator initially refused an unlisted verifier bytecode
cache and the naturally regenerated managed tenant-alias Nginx configuration.
That failure remains retained. Closure proves only the two named Python caches
against their exact source, interpreter magic, compiled code, timestamp headers,
ownership and transaction window. The verifier cache is a new 0600 root-owned file
created by the original helper. Independently verified public 23 worker/template
output reproduces the original alias configuration hash; corrected 26 renderer
output exactly reproduces the new file, retaining its alias, instance-key hash,
certificate/key paths and 0600 root ownership. No product file, cache, guard or
credential is changed to make these comparisons pass.

Fresh-schema fixture results on the pre-correction source are 117 administration,
142 staff,308 OpenAPI,12 installer and41 pure signed-grant controls. The account 169
and full Core 65 legacy-context fixtures correctly refuse the fresh required
registration marker; they are not reported as fresh passes, and that marker is
not removed, hidden or bypassed. Actual normal registration and live personal API
checks provide their separate fresh-install evidence.

## Related recovery evidence

Full-media encrypted backup and replacement recovery retain their separate
[9 November qualification on hosted 1.0.25](backup-recovery-2026-11-09.md).
This release adds the fresh-install, signed-upgrade and automatic-rollback
evidence above; the older full-media restore is not relabelled as a new 1.0.26
restore test.
