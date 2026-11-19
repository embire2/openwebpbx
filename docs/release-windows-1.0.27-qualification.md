# Windows Server 1.0.27 qualification

**In qualification; not a public release announcement.** Public Windows remains
1.0.23 until the complete installer passes its remaining Windows tests.

The intended release is one standalone package for Windows Server 2025 x64
with Desktop Experience. A fresh installation needs no previous PBX or separate
PBX repair. Existing-data updates retain their own signed compatibility,
backup, active-call and recovery checks.

## Final5 background registration correction — in progress

The final4 complete package is retained unqualified. Its genuine zero-prior
installer exits0 in1393.4958864seconds; the original60-minute owner setup case
fails124 at23:54:23UTC. Exactly one ordinary owner login/claim is used and its
private setup token is self-revoked204→401. Subsequent readiness cases remain
separate; a trusted canonical certificate does not imply tenant activation.

A natural native process trace identifies the next correction: image bind and
proof helpers exit0; the sign helper then exits1 in7.02seconds before its body,
while an ordinary tenant-domain task holds maintenance. Both scheduled Windows
onboarding and image helpers still use a five-second acquisition window. The
new correction gives scheduled work an explicit bounded30-second acquisition,
retaining foreground5, Linux behavior, native sharing/lock-only retries and all
existing identity/ACL/maintenance checks. It never repeats a guarded body or
patches the installed target. Focused native tests and a new complete package
are required before promotion. A NULL current challenge field was an insufficient
historical diagnosis: the prior session did reach challenge201 before noauthorize;
a later same-owner session refresh clears those fields.

The separate ordinary sealed operator return23 fails with a generic CopyTree
error; no persistent access failure or cause is established. Plain unmodified
installed recovery later exits0 in280.04seconds, restoring stock23. A separate
ordinary updater start naturally finishes its restored request as failed without
replay. Original schema, customer rows, files, task choices, security, partial
backup and seals plus eight software SIP/RTP checks pass. This is manual support,
not automatic acceptance, and the original operator failure stays retained.

## Previous complete final4 package — unqualified

Frozen source `fcf21dd48ce770c1f8529889f86f62ba5a91798d` changes one
Windows product line, its native regression and compatibility workflow.
Actual Windows PowerShell5.1 strips embedded double quotes in the protection
worker's Python `-c` argument, causing a syntax error before tenant jobs are
claimed. Both owned Windows targets reproduce it independently. The corrected
single-quoted Python literals retain the exact protected root, isolated runtime,
worker arguments and `runpy` entry.23 actual native controls pass, including old
failure, corrected exits0/7, body-once execution and untrusted PYTHONPATH refusal.

The complete ZIP is **643,867,544bytes**, SHA-256
`e2f28074ec921d9945b25af0bc3a55df8e1d98d97983e35cc4d0cdeba301b75d`.
All19,351 payload hashes,4,915 voices,6,809 shipped source files,11,440 vendor
files and1,099 native files verify independently. All90 compiled native inputs
remain unchanged from9f6. Source archive **50,692,297bytes**, SHA-256
`ff78942cac9b0247da86c1d8b4bd723e2f0d47a57815c91e663f7026edd8d200`,
verifies7,842 Git blobs and modes. Canonical3-entry and primary7-entry checksums,
independent Debian/Android retention and private signed sequence1795042256 pass.

The archive is first assembled from5fe913bec0bc2c64d925b8b61e8a2a3b98a547ff.
Its initial CI fails only because the native fixture casts several discovered
Python executables into one path. The final source changes only that excluded
test lookup; every shipped Git blob/mode and the entire archive stay byte-identical.
The final source archive includes the corrected fixture; [exact-source CI](https://github.com/embire2/openwebpbx/actions/runs/44414855077)
passes23 terminal,39 recovery,39 registration,169 maintenance and23 protection
entry controls. Earlier failed CI and successful explicit-interpreter native
results remain distinct. No installed product is patched to pass.

The genuine no-prior whole installer passes in1393.4958864seconds/native0.
Its22:54:23UTC→23:54:23UTC setup case remains FAILED124 as described above.
Actual tenant-ready/UI/API/QR, software calling, changed protection worker
backup/restore and reboot remain required for the corrected complete package. The unchanged493 PHP/PostgreSQL
and six native Lua fixture results are explicitly reused from final3; they are
not relabelled final4 execution. Final3 transaction results below are also separate
from the pending new whole signed tests. No public release is announced.

## Previous complete final3 package — unqualified

Frozen source `06d651d497b9d301ef564900d66ef720cedd37fb`; complete ZIP
**643,867,551bytes**, SHA-256
`7ba1115b05f0093c14814c5d9f3077e70faa39485b5edd185f6d9d206c5ab653`.
Independent verification accepts19,351 payloads,4,915 voices, the explicit full/no
previous-installation contract,6,809 shipped source files,11,440 vendor files
and1,099 native files. All90 compiled inputs remain exact from native source9f6;
19,347 other compressed members and metadata remain exact from final2. Four
reviewed product leaves and the manifest change: terminal handoff, strict legacy
recovery, pre-claim backup locking and IIS API hosting. Matching source archive,
checksums and independently retained platform feeds are prepared privately.
[Exact frozen-source Windows CI](https://github.com/embire2/openwebpbx/actions/runs/44390235931)
passes23 terminal,39 recovery,39 registration and169 maintenance controls.

The genuine zero-prior final3 installer exits0 at21:13:08UTC in1848.2861239seconds;
all four principal services run. Ordinary verified-owner registration, managed
DNS and trusted HTTPS reach ready21:23:58UTC:48m12.672s within the original
60-minute setup case. Exactly one owner login and claim are used; its temporary
token is self-revoked204→401. Earlier30-minute failures remain failed.

Separate installed company11, administrative API28 and personal HTTPS15 controls
pass, including ordinary API DELETE, stable reusable QR and withdrawn-role
refusal. PostgreSQL/PHP493, six native Lua groups, UDP/RTP/capacity18, strict
TLS/RTP11 and STUN9 pass. The preservation baseline covers195 tables,16 protected
table projections and467 files. One full backup completes through the natural
SYSTEM worker; actual verified download, tenant/full restore and reboot gates
remain open. Private observer failures are retained, with no product patch,
manual worker or duplicate backup request.

The existing23 target separately passes an ordinary idle reboot, original data,
security, startup choices and eight software SIP/RTP controls. Windows naturally
resizes its system-managed paging file; no paging setting changes or native DISM
cleanup occurs. New service generations are recorded explicitly. Ordinary
signed final3 download and full preflight reach ready; native UpdateNow and
normal elevation start21:53:36UTC. Overall automatic rollback, terminal request,
backup topology and preservation must pass before the normal upgrade test.
No public release is announced by these component results.

## Earlier final2 failure and corrections — 18 November 2026

The complete **final2** archive below is retained **unqualified**. Its genuine
stock23 transaction restores the old version, but the dot-sourced legacy caller
then starts another transaction without its released maintenance lock. That
second attempt leaves a partial unsealed backup and `recovery_required`.
The transient `rolled_back` observation is not automatic acceptance. Customer
configuration,184-table schema,471 archived files, certificates and task choices
verify; operational changes are reviewed individually.

Source `ced796783ee7e485bfb409682e23c6e599ac3221` corrects terminal handoff
for a dedicated PowerShell host and narrowly recovers this known pre-backup
state without restoring data or changing seals.23 actual native host controls,
39 admission controls and [independent Windows CI](https://github.com/embire2/openwebpbx/actions/runs/44376973779)
pass. A source-assisted manual recovery is separate from the required new
whole-package automatic transaction.
The approved source-assisted manual `-Recover` completes at19:20:58UTC in
5.072seconds: ordinary `rolled_back`/healthy23, four service generations,
13,175 partial-backup files/identities/attributes, nine customer projections,
471 archived files and eight prior requests stay exact. No database restore,
seal rewrite or direct SQL finalizer is used. This manual result does **not**
qualify the failed automatic transaction.

The real clean final2 installer completes in **2123.0761515seconds**, with no
older PBX, resume or patch. Its original30-minute case remains failed; a separate
ordinary post-install wizard reaches ready and self-revokes its sole owner token.
Company11, personal15/stable QR,493 PostgreSQL, UDP/capacity18, TLS11 and STUN9
checks pass. Admin API DELETE fails with IIS401.3 before PHP authorization;
a scoped hosting correction is under isolated qualification. Earlier invalid
fixture realm, incorrect TLS SNI and private IIS-observer failures are retained.
No new public release or final-package acceptance follows from these components.

Source `138c5cef2bf497591a087a44a8d4ce98811dd929` additionally acquires the
registration snapshot before a queued Windows backup is claimed. Busy acquisition
leaves the same request pending; guarded work runs once. The archive/business body
remains AST-equivalent to the prior source apart from its held-guard call.33
portable and39 actual native registration controls pass;169 maintenance controls
remain separate. An initial native scaffold used three transient installed
backup-control request files despite passing assertions; retain it as a **scope
defect**. The corrected fixture touches only new private paths and preserves449
authority pins, four service generations and zero backup-control requests. No
installed patch or final-package acceptance follows from these source controls.

## Previous complete final2 package (unqualified)

Frozen package source: `0bdfe5481d592f54ae602a331f63e62f1f73166f`.
The archive is **643,866,028 bytes**, SHA-256
`cb316b88b4677fd89eb23e87ecf882d629a92703e3cbc70bf91127c33a57a9da`.
Independent extraction and the ordinary full-package checker validate every
one of **19,351 manifested payloads**, **4,915 spoken files**, the full-install
contract and the reviewed Windows installer/worker source bindings.
`installation.json` explicitly declares `package_type=full` and
`previous_installation_required=false`; local PostgreSQL setup and the current
updater are included.

Native build [44345474762](https://github.com/embire2/openwebpbx/actions/runs/44345474762)
compiles Core, updater and WinUI manager **1.0.27.0** from source
`9f6a0ac42999614755ee0838c0660324970f11c1`. All **90** compiled inputs remain
exact in the final packaged source; **1,111** native checksum entries are
independently verified. Every shipped native file uses this new build; the
earlier D3 build is retained as historical evidence. The IIS admission module
is compiled separately during ordinary Windows setup.

The complete archive retains the ordinary builder's verified payloads and new
native outputs. Reviewed reassembly changes only the provider loader, two
registration helpers and manifest, preserving all19,348 other compressed members
and metadata. Independent provenance checks cover1,099 shipped native
files,11,440 unchanged vendor inputs and6,809 shipped source files. No customer
applies a patch or supplies an earlier PBX. Engine,
ACME, backup runtime, music and voice inputs retain their recorded Windows23
provenance; the three native applications are rebuilt27. Optional locally built
codec DLLs are not redistributed.

## Acceptance status — 18 November 2026

| Area | Actual evidence and remaining gate |
| --- | --- |
| Full installation contract | Current complete ZIP independently extracts; every payload hash, source binding, voice count and full-release contract passes. Actual fresh installation is a separate gate. |
| Native applications | New native27 versions and responsive manager window pass.41 signed-grant,57 protocol,82 updater,14 actual Windows worker,57 recovered-request PostgreSQL,63 MTA entry,11 native notice and20,050 STUN controls pass. Database-backed calling capacity and installed target manager remain separate gates. |
| Windows recovery integration | Authenticated fixed-command call-engine adapter passes three actual Windows controls; query-only import classifier passes213; IIS identity handling31; fixed support-directory ownership122; generated-cache ACL admission39. These do not replace a real restore. |
| Background registration contention | A naturally scheduled tenant-domain worker misses its two short acquisition windows while the ordinary onboarding task owns the lock. Only this background caller now requests30seconds; default/foreground5seconds, native32/33-only retry and guarded-body-once rules remain.41 actual Windows,45 portable,34 orchestration and21 tenant-worker checks pass. Final ordinary wizard readiness remains separate. |
| Shared outgoing-call correction | Configured script-root loading avoids a Lua logging-global collision before provider contact.494 controls and automatic push CI pass; three read-only actual Main mod_lua checks reproduce the old failure and accept the installed correction. Owner confirms Main Android1000 outgoing sound both ways. These are Main/portable results, not final Windows carrier acceptance. |
| Supplied existing server | Owner's dedicated Windows Server2025 target; original23 checkpoints and independent schema, files, identities, certificates, tasks and service baselines retained privately. |
| Original recovery checkpoint | Verified ordinary encrypted backup copied offhost:27,312,341 bytes, SHA-256 `9ebf36c24680d34bc26fa0fa275dd2244ea8e15982c85d99dfc24380a3602768`. |
| Owned phone fixtures | Separate checkpoint27,316,626 bytes, SHA-256 `6a8f83fad7cbc4b4b68d75fe3eaac0ddc49696a828ef0765f9535b7c1b9fe00c`; two owned extensions preserve distinct authentication IDs, special password bytes, app-password state and one custom WAV. All nine original customer projections and468 original archived files remain exact before the transaction. |
| Baseline software calling | Eight original23 registration, answered-call and decoded two-way RTP controls pass; fixtures unregister afterward. Post-upgrade calling remains separate. |
| First-candidate read-only entry | Unelevated Help and Check pass using the included Python;19,352 files/1,200,354,057 bytes and five existing service generations remain exact. This was the earlier82bc archive, not current final-byte acceptance. |
| Actual original23 updater | First82bc package is downloaded, verified and preflighted by the original installed worker. Mandatory notice, red banner, postponement with services running, enabled UpdateNow and normal elevation are observed. Final current-package transaction remains pending. |
| Late failure and automatic rollback | First82bc controlled late failure enters ordinary rollback, which fails. The defects and manual recovery below remain distinct. A successful current-package automatic rollback has not yet been established. |
| Manual recovery | The gated MTA continuation succeeds248.248879s/exit0 and restores healthy23.184 tables/schema,18 roles, original credentials and469 archived files are independently checked; specified operational timestamps/one owned update request differ.32 original certificates and both original IIS sites/pools remain exact. This is explicitly manual support, not automatic rollback. |
| Clean Windows machine | OS-only Server2025 Desktop VM has no earlier PBX, six GiB RAM and a retained clean snapshot. Unmodified80526 full setup completes through ordinary same-version resume after a private observer interruption. Its original30-minute case fails on the QA example.invalid ACME contact. A separate normal own-profile correction preserves credentials; that bounded case also expires while real background lock contention prevents readiness. Both failures are retained. Final whole-package clean reinstall is approved, using valid contact from the start and normal verified-owner onboarding without quota or authority override. |
| Feature integration | Tenant/instance protection worker, IIS API routing and body-free upload admission are ported. Final installed API roles/templates/resources, stable QR, capacity, full/tenant restore, software calling and reboot checks remain pending. |
| Public release | No Windows27 tag, public assets or latest-feed promotion. Debian27, Android19, public Windows23 and historical catalogue remain retained. |

The current private **final3** signed offer has sequence **1795033781**, minimum
installed version **1.0.23**, envelope SHA-256
`daf525f22be6b9a73a942fb5bb7274c72f6027b8b788e48ca4ae93b1d52fbd8a`.
Its catalogue SHA-256 is
`089474b06cd21b64e56101cf4793c8fd30f91d6f5bba5993572278b5a828055d`;
it retains the original20→21→22→23 prefix and appends the exact final3 offer.
Minimum1.0.23 applies only to existing-data updates; a clean install needs no
previous PBX. Package/feed checks preserve Debian27 and Android19 envelopes
exactly. These are private test feeds until actual acceptance and promotion.

The supplied legacy23 instance has no issued reusable QR payload and is
unregistered under its grandfathered setup. Its ordinary readiness guard refuses
new QR issuance. No onboarding guard or original identity is changed to force a
test. Fresh registered27 requires its own stable QR/reuse checks.

## Distinct failures and corrections

The first82bc candidate is superseded, never retrospectively accepted. Actual
rollback exposes a valid IIS application-pool identity represented as a name
rather than an integer, then seven legitimate saved support-directory names
missing from the restore allowlist. Corrected source uses strict provider
types and one shared fixed directory map; unknown names and wrong paths refuse.

The first approved manual recovery then refuses four absent generated cache
files. Ordinary update and restore deliberately clear that cache; their sealed
ACL inventory can still name its old children. The current correction accepts
only absent descendants of the exact ordinary cache root, rejects links and
malformed descriptors, and retains missing-target refusal everywhere else.
No missing customer file is invented, original sealed backup changed, recovery
entry edited, trust floor lowered or ad-hoc SQL restore substituted.

A later manual attempt waits inside IIS native configuration disposal. Matching
Microsoft public symbols identify the notification-thread wait; they do not
implicate the file ACL setter. The owned attempt is stopped after20minutes,
with journal, entry, backup seals and trust bytes exact. A strict continuation
uses MTA and accepts only that legitimate stopped transaction; it does not reset
the journal. A successful read-only IIS disposal probe is not a restore or a
proven fix. Automatic recovery still needs an actual final-package transaction.

The original native workflow fails when a test tries creating filenames Windows
rejects or normalizes. Its corrected hostile-manifest fixture and the final
workflow pass. A separate disposed-handle assertion captures the handle before
disposal; product delegation code is unchanged. An alias-test reflection fixture
needs a typed delegate on actual Windows PowerShell5.1; its correction leaves
the product classifier unchanged. These initial failures remain failed.

The authenticated Windows call-engine adapter replaces an unauthenticated
fs_cli invocation with a fixed command allowlist through installed PHP/private
configuration. Authentication failures and false reload acknowledgements refuse;
no secret is passed in process arguments.

Two early backups correctly refuse real lock contention. A bounded ordinary
retry succeeds while Phone Health is still running. A separately approved short
task stop occurs afterward and is reversed; it does not establish a persistent
Phone Health defect or explain that backup's success.

The first fresh VM host runs out of memory. The owned VM is stopped and moved
with its clean snapshot to a host admitted by both current available RAM and
summed configured maximum RAM plus a six-GiB host reserve. No foreign VM is
restarted or resized. A separate private observer hang is caused by serializing
PowerShell-decorated Get-Content output; bounded pure-string reading corrects
the observer without changing the product. Other transport, foreground exit143,
first-boot and receipt failures remain in private evidence.

## Preserved scope

Windows audio buffering, credential bytes, authentication IDs, reusable QR
identities, recordings, routes, allowances, certificate choices and task
selection remain required invariants. Shared Debian features require actual
Windows checks before their catch-up rows close. Hosted tenant-API changes
made after the Windows source freeze are separate deployments.

Canonicalv1.0.27 already belongs to Debian27 and is never retagged. Eventual
Windows assets must be additive with separate Windows checksums and an exact
Windows platform source tag. Historical assets and feed objects are not replaced.

Raw evidence, backups, passwords, QR payloads and private URLs stay private.
Software checks do not establish physical-phone, carrier, human-audio, camera,
Store or complete3CX-parity acceptance. The broader roadmap remains133 goals:
21 accepted,72 partial and40 planned.

[Installation](installing-windows-1.0.27.md) ·
[Windows catch-up ledger](debian-windows-sync.md) ·
[Independent releases](independent-platform-releases.md).
