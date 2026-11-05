# Windows Server 1.0.23 release qualification

**Release preparation — 5 November 2026.** The user has authorized publication,
subject to the actual checks below. The corrected BADC package, interrupted
restore recovery and final normal signed 1.0.22-to-1.0.23 transition are accepted
components. Original 1.0.23 data return, full BADC reapply, final calling and
public release checks remain **PENDING**. Windows 1.0.22 remains the public download.
Earlier failed attempts remain failed.

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

The prepared Windows-only signed offer has sequence **1793892995**, minimum
installed Windows **1.0.22**, and envelope SHA-256
`0832577ee2d4627c1dbeb8f2ee7d37ec27a82a3dd3c8054e5013da739f1a1f28`.
Its prospective release is `windows-v1.0.23`; actual publication time and
public delivery remain unbound until publication/readback. Debian 1.0.23 and
Android 1.0.19 retain their separate existing artifacts and signed envelopes.

| Component | Actual evidence |
|---|---|
| Server, updater and native manager | Accepted build component: all three builds are 1.0.23.0; code inputs match qualified 1.0.22 except version metadata. The actual final BADC normal transition also verifies installed 1.0.23 and natural updater restart. |
| Earlier ordinary installed upgrade | Accepted 4 November component: normal complete 22-to-23 manual upgrade in 739.944 seconds, exit 0, followed by the scoped audio correction. This does not establish installation of the later BADC package. |
| DID editor and routing | Accepted: 188 actual Windows PostgreSQL/PHP controls and 49 ordinary browser checks. Temporary disabled provider/number fixtures were removed; the original PBX configuration was restored exactly. |
| Earlier calling | Accepted corrected component: four registrations and four two-way software calls over UDP/TLS in 28.990 seconds; all 16 RTP streams and 3,371 packets pass unchanged limits, including tails. Two earlier audio failures remain recorded. Final post-return calling remains pending. |
| Windows audio default | A 60 ms receive buffer, allowed to grow to 200 ms, stays active while bridging. Explicit administrator values/off choices remain intact. Debian's platform branch is unchanged relative to the shared timestamp policy. |
| Earlier local preservation | All 23 captured SQL projections, six private identities, QR/mobile credentials and ten original media files are exact; six later recordings are retained. Task names/enabled choices survive; five stock start timestamps regenerate. The pending original 1.0.23 data return must restore its own model and all 16 media files. |
| Native manager | Earlier installed 1.0.23 had a visible, responsive window in the ordinary user's desktop session. The final normal signed transition now also passes manager reopen. |
| Encrypted backup | Accepted ordinary creation, built-in full verification and complete encrypted off-server download. Unchanged backup implementation and accepted current-data backup evidence may be reused; no new BADC backup is inferred. |
| Fresh/restore/reboot and unchanged infrastructure | The relevant unchanged components retain their original 1.0.22 evidence, explicitly scoped below. |
| Corrected consumed-CDR recovery | Accepted: 89 native controls across 21 cases and actual corrected-helper interrupted-restore recovery; details below. |
| Signed late-rollback orchestration | Explicitly reused Windows 1.0.22 runs 41752080297/41722715796; not a new 1.0.23 late-canary pass. |
| Final BADC normal signed transition | **PASS, 5 November:** all five normal gates—signed HTTPS download, original 1.0.22-to-1.0.23 installation, natural updater restart, manager reopen and protected data. Component 1,340.0937s within 3,600s; native completion inside its original 1,800s bound. |
| Original 1.0.23 data return and full BADC reapply | **PENDING:** exact SQL/model, QR, six private identities, 16 media files and task choices, then complete reapply/preservation. |
| Final calling and public checks | **PENDING:** calling/full-wire confirmation, seven public assets/canonical additions, retained feeds and installed ordinary public Check. |

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

The original 1.0.23 return uses the ordinary installed `-RestoreBackup` path and
must restore its exact model, six private identities, 16 media files, QR and
task choices. Its sealed bundle contains earlier BFC support files, so a
complete normal BADC reapply is required afterward. A manual helper patch is
not a substitute.

Unchanged fresh setup, restore/reboot infrastructure, backup, engine, codec,
prompt and music components retain their
[Windows 1.0.22 evidence](release-windows-1.0.22-qualification.md). This is not a
new 1.0.23 fresh-install pass. Direct transitions from versions older than
1.0.22 need their own evidence.

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
completed at **13:15:08 UTC**, native exit0. Subsequent readback confirmed
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
that authorization does not waive the pending corrected-package checks.

The audio checks do not prove that every network/media timing event vanished.
The separately confirmed hosted Debian 1.0.24 Android outside call does not qualify
Windows carrier calling. No new physical-phone, carrier, capacity, Store or
complete 3CX feature-parity claim is made.
