# Windows Server 1.0.23 release qualification

**Published — 5 November 2026, 20:43:14 UTC.** Windows Server 1.0.23 is the
public Windows release. The corrected BADC package, interrupted-restore
recovery, final normal signed 1.0.22-to-1.0.23 transition, scoped original
1.0.23 data return, complete BADC reapply, final software calling,
preservation, manager and current encrypted backup are accepted below.
Whole public downloads, retained feeds, owned-lab cleanup and the ordinary
installed public Check also pass. Recovery reuse is explicitly scoped;
earlier failed attempts remain failed.

## Corrected package and frozen source

The complete Windows Server 2025 x64 Desktop Experience ZIP is
**643,269,105 bytes**, with SHA-256:

```text
badc4326b48d1e7953990eb382f598602bb23bd068ca27c42abf22c25ce10907
```

All **19,288 payloads** pass complete size/hash verification. The raw release
manifest SHA-256 is
`8d6c8f5c7e34cd813df7b805c726c19eec4a676739c1441a7aec3cf4a2d1cd7b`.
The frozen Windows source is `e1aaad63f99ac3b11714d9d0cd3f2a085778688f`.
Its 50,251,792-byte application source archive has SHA-256
`4d581c86667782bd49f998afb084e06af91af7958dbd130ca52f4a3ab37eb5c8`.
Later default-branch documentation does not change that product identity.

The public Windows-only signed offer has sequence **1793892995**, minimum
installed Windows **1.0.22**, and envelope SHA-256
`0832577ee2d4627c1dbeb8f2ee7d37ec27a82a3dd3c8054e5013da739f1a1f28`.
Release [windows-v1.0.23](https://github.com/embire2/openwebpbx/releases/tag/windows-v1.0.23)
(ID 435407275) was published at **2026-11-05T20:43:14Z**; its annotated tag binds
the frozen Windows source above. Debian 1.0.23 and Android 1.0.19 retain their
separate existing artifacts and signed envelopes.

| Component | Actual evidence |
|---|---|
| Server, updater and native manager | Accepted build component: all three builds are 1.0.23.0; code inputs match qualified 1.0.22 except version metadata. The actual final BADC normal transition also verifies installed 1.0.23 and natural updater restart. |
| Earlier ordinary installed upgrade | Accepted 4 November component: normal complete 22-to-23 manual upgrade in 739.944 seconds, exit 0, followed by the scoped audio correction. This does not establish installation of the later BADC package. |
| DID editor and routing | Accepted: 188 actual Windows PostgreSQL/PHP controls and 49 ordinary browser checks. Temporary disabled provider/number fixtures were removed; the original PBX configuration was restored exactly. |
| Earlier calling | Accepted 4 November component: four registrations and four two-way software calls over UDP/TLS in 28.990 seconds; all 16 RTP streams/3,371 packets pass unchanged limits. Two earlier audio failures remain recorded. Final calling is a separate result below. |
| Windows audio default | A 60 ms receive buffer, allowed to grow to 200 ms, stays active while bridging. Explicit administrator values/off choices remain intact. Debian's platform branch is unchanged relative to the shared timestamp policy. |
| Earlier local preservation | All 23 captured SQL projections, six private identities, QR/mobile credentials and ten original media files are exact; six later recordings are retained. Task names/enabled choices survive; five stock start timestamps regenerate. The separately accepted return below restores the original 1.0.23 model and all 16 media files. |
| Native manager | **PASS:** final installed 1.0.23 manager visible and responsive in ordinary session 2, left open. The final signed transition separately passes manager reopen. |
| Final encrypted backup | **PASS:** one ordinary Create, natural scheduler, built-in verification and complete off-server download in 49.867s within 600s. Independent verification 2.851s checks 481 manifest files/all 20 media, six live identities and five source-private archive files. Phone Health target identity is preserved without falsely claiming it is archived. |
| Fresh/restore/reboot and unchanged infrastructure | The relevant unchanged components retain their original 1.0.22 evidence, explicitly scoped below. |
| Corrected consumed-CDR recovery | Accepted: 89 native controls across 21 cases and actual corrected-helper interrupted-restore recovery; details below. |
| Signed late-rollback orchestration | Explicitly reused Windows 1.0.22 runs 41752080297/41722715796; not a new 1.0.23 late-canary pass. |
| Final BADC normal signed transition | **PASS, 5 November:** all five normal gates—signed HTTPS download, original 1.0.22-to-1.0.23 installation, natural updater restart, manager reopen and protected data. Component 1,340.0937s within 3,600s; native completion inside its original 1,800s bound. |
| Original 1.0.23 data return | **PASS, scoped closure:** same native restore exited 0 at 20:01:44 UTC; separate read-only closure passed 20:10:21 UTC before the original 20:15:22 UTC deadline. Customer model/secrets/QR, 16 media files, six private file contents and attributes/task choices preserved. One exact ACL ordering and five task start boundaries are classified below; the failed wrapper/raw review-required result remain unchanged. |
| Full BADC reapply | **PASS, 5 November:** complete ordinary same-version package reapply in 896.534s, inside the original 1,800s including extraction. Original 1.0.23 customer projections/secrets/QR/six private files/16 media files/task choices pass the strict comparison with only the already-scoped ACL order and five source-bounded task boundaries. |
| Final calling and post-call preservation | **PASS:** all 8 cases in 28.687s; four registrations/four two-way UDP/TLS software calls. Whole capture 16 streams/3,363 packets including tails has zero invalid packets or clock violations. Original 16 media plus exactly four source-bound recordings; captured customer model/six private files/task XML exact against accepted post-reapply anchor. |
| Public release and whole readback | **PASS:** seven platform assets and four canonical additions fully downloaded anonymously; all three latest feeds verified. Original 23 releases, 172 assets and 37 tags preserved. |
| Owned qualification-lab cleanup | **PASS:** only owned lab resources removed; foreign IIS/certificates/hosts and current product identities/source pins exact, private evidence retained. |
| Ordinary installed public Check | **PASS:** actual public offer accepted at 20:46:37.7647 UTC, within the original 180-second bound; current 1.0.23 remains up to date, without archive download or installation. |

## Explicit composite scope

Independent comparison of qualified 1.0.22 source
`8f4256e4e3cbce092791eea60d1c053e10810bb6` with frozen corrected 1.0.23 source
`e1aaad63f99ac3b11714d9d0cd3f2a085778688f` establishes:

- 74 of 75 Windows installer/recovery paths are identical; only the narrow
  consumed-CDR recovery correction changes.
- 82 of 83 native-project/source paths are identical; only global version
  metadata changes from 1.0.22 to 1.0.23.
- All 26 SQL files, Windows bootstrap, schema upgrader and additive-default
  initializer are identical. There is no new 1.0.23 DDL/down-migration contract.

Actual Windows 1.0.22 runs
[41752080297](https://github.com/embire2/openwebpbx/actions/runs/41752080297) and
[41722715796](https://github.com/embire2/openwebpbx/actions/runs/41722715796)
retain their signed late-failure rollback, manager reopen, database/files/ACL/
task preservation and operator-recovery acceptance. Their unchanged
orchestration is reused alongside 89 native controls and actual corrected-helper
recovery evidence.
Automatic rollback, interrupted recovery and operator restore reach the same
`RestorePbx`/support/CDR recovery path.

The new 5 November fault attempt, retained as result `c0ca49cf…`, **FAILED**:
rollback occurred before the intended late canary, its witness was absent and
the controller timed out. No normal installation request followed in that
case. Its exact deployment cause remains unknown. It is not a Windows 1.0.23
late-canary pass, and the Windows 1.0.22 results are not relabelled as 1.0.23 results.

The accepted composite scope is **Windows 1.0.23 normal signed transition, with unchanged
rollback orchestration reused from Windows 1.0.22 and corrected CDR recovery
independently exercised**. The actual normal component retained its before
maps, command cursor, original 1,800-second native bound and five normal gates.
It ran **19:22:54–19:45:14 UTC on 5 November**, taking 1,340.0937 seconds inside
the original 3,600-second component limit. Native installation completed at
19:44:26 UTC before its original 19:55:37 UTC deadline. The database projections,
including both Phone Health tables, private identities, protected files and
original task choices match this new component's own fresh baseline.

A separate retrospective comparison against the older pre-fault database
snapshot **FAILED** on digests for `v_pbx_phone_health_issues` and
`v_pbx_phone_health_state`. The individual row differences and their cause
remain unknown. Its earlier normal-baseline case (`62f2e423…`) and comparison
(`22575466…`) stay failed. That retrospective comparison is not a prerequisite
for the distinct current-baseline normal transition. No early-rollback database
or full-file preservation pass is claimed. The new normal component still
requires and passes its own unchanged before/after comparison, including both
Health tables; no table is excluded to obtain the normal result.

An early-rollback full-preservation claim would need its own actual comparison.
Composite evidence cannot fabricate an eight-gate pair or extend a failed
component's deadline.

## Scoped return of the original 1.0.23 data

The ordinary installed `-RestoreBackup` process, native PID 20784, completed
successfully at **20:01:44 UTC on 5 November**, before its original 20:15:22 UTC
deadline. Its first observer wrapper failed during a strict Running-service
SCM poll; that wrapper (`fabc8737…`) remains failed. No operator replay was
used. A separate read-only closure (`145725b7…`) passed in 1.348 seconds at
**20:10:21 UTC**, within the same original return deadline.

The raw preservation comparison (`591d3a38…`) remains **`review_required`**.
The separately accepted semantic comparison (`d3faea5f…`) preserves the
customer model under the existing declared runtime/audit rules, credential and
QR/device fields, all 16 original media files, same boot, zero active channels,
six private files' bytes/attributes and original task names/enabled choices.

Five private security descriptors are raw-exact. For only the onboarding
`session.json`, the owner remains SYSTEM, the group remains SYSTEM, and control
flags are identical. Its exact three inherited Full Access Allow ACEs for
SYSTEM, built-in Administrators and Owner Rights have only changed order;
no grant was added, removed or changed. Nine actual native descriptor controls
confirm that exact equivalence and its binding to the sealed source descriptor.
This is not a claim that all six raw descriptor strings are identical.

Exactly five stock tasks differ only in their TimeTrigger `StartBoundary`:
Outgoing Mail, Backups, Onboarding, Phone Health and Tenant Domains. Their
other XML, including registration Date/Author, is exact. The semantic check
normalizes only those five fields and the one exact ACL pair in memory before
the unchanged preservation comparison. It does not edit a snapshot, ACL,
task, customer row or private file.

The returned sealed bundle contained earlier BFC support files. The complete
normal BADC reapply below replaces those through the ordinary full installer;
no manual helper patch substitutes for that operation.

## Complete BADC reapply — 5 November 2026

The ordinary extracted full-package same-version upgrade completed at
**20:26:41 UTC**, taking 896.534 seconds inside the original
**20:11:44–20:41:44 UTC / 1,800-second** shared extraction/apply/closure bound.
The native installer process 8684 exited 0 at 20:25:26 UTC. Its journal and
finalization completed at 1.0.23, the corrected 93 support helper is installed,
and the retained rollback bundle passed the stock complete-file verification.
This is an ordinary full reapply, not another signed-download or fresh-install
claim; no trust floor was reset.

The strict original 1.0.23-to-final comparison (`9da0447a…`) passes the captured
23-table customer model under existing declared audit/runtime rules, secret
and stable-QR fields, six private identities, all 16 original media, task names
and enabled choices, same boot and zero calls. The one exact session ACL-order
equivalence remains the only security classification. Five stock task start
boundaries are the only XML-field differences; Date/Author and all other XML
remain exact. The pinned installers schedule these tasks at creation plus one minute
(four tasks) or plus two minutes (Tenant Domains); subtracting those exact offsets
places all five generations inside the actual native apply interval. No broad
time allowance or new security exception was introduced.

## Final calling, preservation and backup — 5 November 2026

The original-credential software matrix passes all eight cases in
**28.687 seconds**, inside its 180-second active bound: four registrations and
four opposite-direction decoded calls over UDP/TLS. The complete captured wire,
including tails, passes all 16 streams and 3,363 RTP packets with zero invalid
packets or clock violations. Limits remain 0.8 coherence, 80ms maximum individual
gap and 5% missing-clock fraction. No threshold/runtime change or automatic
repeat was used. These are software calls, not carrier/physical-phone tests.

The post-call snapshot has 20 media files, the original six private identities,
17 tasks and zero channels. Its captured customer tables, private-file contents/
attributes/raw descriptors and full task XML/enabled choices match the accepted
post-reapply snapshot. Original 1.0.23 preservation therefore continues through
the accepted reapply anchor without another ACL or time normalization.

The first unmodified post-call classifier remains `review_required`: it
recognized only the legacy `storage/recordings` prefix. The unchanged product
recorder instead writes `storage/openwebpbx/<domain UUID>/<call UUID>.wav`, the
same domain folder already holding ten original recordings. A separate closed
classification accepts only the four actual matrix UUID-WAV files in that
original domain folder, with exact lengths/hashes and native proof of ordinary
files, canonical direct-child paths and ordinary ancestors. Fifteen focused
controls include foreign-domain/path/traversal/extra-file/hash/size/link-type
denials. Every other preservation gate stays unchanged. The raw review result
is retained; no media, snapshot or product data was repaired to obtain a pass.

One ordinary **Back up now** request at 20:30:50 UTC then completed through the
natural scheduler. Its 26,611,495-byte encrypted archive was fully downloaded
and hashed in 49.867 seconds, before the original 600-second fence. Independent
verification in 2.851 seconds verified 481 manifest files, all 20 media files,
all six live private identities and the five source-private archive members.
The target-only Phone Health identity is not falsely counted as an archive
member. Settings, clock and workers were not reset or manually invoked; normal
logout completed. The earlier backup and failed observers remain separately
retained.

Unchanged fresh setup, restore/reboot infrastructure, backup, engine, codec,
prompt and music components retain their
[Windows 1.0.22 evidence](release-windows-1.0.22-qualification.md). This is not a
new 1.0.23 fresh-install pass. Direct transitions from versions older than
1.0.22 need their own evidence.

## Public delivery, cleanup and installed Check — 5 November 2026

The seven platform-release assets and four immutable Windows additions to
canonical `v1.0.23` pass complete anonymous download size/SHA-256 readback.
The original seven canonical Debian assets remain unchanged. All three latest
signed feeds verify: Windows 1.0.23, retained Debian 1.0.23 and retained
Android 1.0.19. The original 23 releases, 172 assets and 37 tags are preserved.

Owned loopback qualification resources were removed at 20:40:20 UTC before
the installed public Check. Only the approved owned site/pool, certificates,
host mapping and related bindings were removed. Foreign IIS resources,
certificates/hosts, the four current product service identities and source
pins remain exact; private evidence is retained. No product service, worker
or runtime file was changed by cleanup.

One ordinary CSRF-protected **Check** command against the actual public feed
was accepted at **20:46:37.7647 UTC**, before its original 20:49:29.876 UTC
observer deadline. The installed 1.0.23 verifier accepted the signature,
sequence 1793892995, minimum 1.0.22 and exact BADC archive metadata; the result
is `up_to_date`. Its normal cache, trust, status and journal writes are expected.
This same-version Check did not download the archive, apply an installation,
or change services, tasks, firewall rules or ports. Complete public archive
delivery is established by the separate whole-download readback above.

Before/after checks preserve the current boot, four service generations,
16 runtime pins, six private identities, 20 media files and task definitions.
Debian and Android feed bytes/signatures remain exact. This closes the scoped
release checks without creating a new Windows 1.0.23 late-canary,
fresh-install, physical-phone, carrier or Store result.

## Recovery correction

An ordinary restore of the sealed public 1.0.22 backup failed because its
permission inventory still listed a transient call-record XML file already
consumed by the normal importer. Permission inventories do not archive these
XML bytes. The failed attempt and its guarded recovery evidence are retained;
the earlier ZIP is not relabelled as corrected.

The correction permits only an absent, canonical UUID-named direct file in
the owned default spool, with a privileged saved file owner and current spool
owner. It never recreates records. All present files, directories, importer
locks, custom spools, links, malformed descriptors and other I/O failures
retain their strict validation. Native isolated Windows checks pass **89
controls across 21 cases**, including actual ACLs, hard links, dangling
symbolic links, junctions and access/sharing failures. Denials preserve
surviving bytes and permissions before any recovery write.

Default-branch fix: `03050db58823dc5c5c014cadede83296fb00a620`.
Corrected helper SHA-256:
`93e51eba827dfee0839f91f7ba497a99d75fd0ef01ae9c15a03c7a54a39a41ea`.
On 5 November, recovery using the exact corrected whole-file helper bundle
completed at **13:15:08 UTC**, native exit 0. Subsequent readback confirmed
journal `rolled_back`, no remaining hold, genuine restored public 1.0.22 helpers,
all three native versions 1.0.22 and all four services running. The earlier wrapper
remains failed. This is an actual recovery component, not a final 1.0.23 normal
installation, automatic late-canary or fresh-install result. Native executables,
engine and voice inputs did not need rebuilding for this correction.

## Earlier private artifact — 4 November 2026

The earlier BFC ZIP was 643,268,769 bytes, SHA-256
`bfc02f54e6c6978748b7ce8b3e8ec432c7d25b21330ccaee915919ea94939e95`,
with 19,288 verified payloads. Its 7,725-file source snapshot is commit
`54779be475d0aab867b04f4908b7b656aee77b57`; its source archive is
`e8e493513d7108630fe2ab18ebbd1e92e3387fb1f5a5c6bb0a1fd1d66921c210`.
It remains historical and withheld. The 4 November local-only/no-publication
restriction was superseded by the user's 5 November publication authorization;
the corrected-package checks and public delivery are recorded separately above.

The audio checks do not prove that every network/media timing event vanished.
The separately confirmed hosted Debian 1.0.24 Android outside call does not qualify
Windows carrier calling. No new physical-phone, carrier, capacity, Store or
complete 3CX feature-parity claim is made.
