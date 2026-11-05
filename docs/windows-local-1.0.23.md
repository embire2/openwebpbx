# Windows Server 1.0.23 — local qualification and release transition

**Current status — 5 November 2026:** Windows Server 1.0.23 was published at
**20:43:14 UTC**. The corrected frozen e1/BADC installer passes complete package
verification, native consumed-CDR controls, actual interrupted-restore recovery,
the final normal signed 1.0.22-to-1.0.23 transition, scoped original 1.0.23 data
return, complete BADC reapply and final software calling/preservation/manager/
current backup. Whole public readback, owned-lab cleanup and the ordinary
installed public Check pass. Windows 1.0.22 rollback evidence is explicitly
reused; earlier failed cases remain failed.

**Historical scope — 4 November 2026:** the original task authorized only local
Windows 1.0.22-to-1.0.23 development/testing, with no GitHub or website publication. Its
manual upgrade, UI and audio results remain separate accepted components.
That publication restriction was superseded by the user's 5 November instruction;
it neither changes earlier results nor qualifies a pending release component.
Windows 1.0.22 evidence remains explicitly 1.0.22 evidence.

Use the [local installation guide](installing-windows-1.0.23.md). Linux, Windows
and Android keep their own qualified artifacts and release cadence; see
[independent platform releases](independent-platform-releases.md).

## Current status

| Component | Actual scope/status |
|---|---|
| Corrected complete package and source inventory | **PASS** — BADC — 643,269,105 bytes/all 19,288 payloads; source `e1aa…`, raw manifest `8d6c…`; exact identities below. Earlier BFC remains historical/withheld. |
| Native server/updater and WinUI manager | **PASS** — all three builds are 1.0.23.0. Final normal installation, natural updater restart and manager reopen now pass; earlier window responsiveness remains its own component. |
| Focused real Windows DID/alias/runtime-policy fixtures | **PASS** —188 PostgreSQL/PHP controls on actual Windows Server2025; no new native-Lua claim |
| Earlier installed22→23 manual upgrade and preservation | **PASS, 4 November component** — native exit 0 in 739.944s; 23 SQL projections, identities, QR, media and task choices preserved. Not final BADC installation. |
| Actual Windows browser save, number-format choice and Call Me Back setup handover | **PASS** —49 checks; temporary disabled fixture removed, original config restored |
| Earlier original-credential calling and backup | **PASS,4November component** —8 UDP/TLS registration/two-way audio cases after Windows buffering fix and verified encrypted backup. Final results are separate below. |
| Consumed-CDR recovery correction | **PASS** — 89 native controls across 21 cases and actual corrected-helper recovery at 13:15:08 UTC on 5 November. |
| Unchanged late rollback | **REUSED WINDOWS 1.0.22** — actual signed cases 41752080297/41722715796; no new 1.0.23 late-canary pass. |
| Final signed normal BADC 22→23 | **PASS, 5 November** — all five normal gates in 1,340.0937s inside the original 3,600-second component and 1,800-second native bounds; fresh full baseline including both Health tables preserved. Failed result `c0ca49cf…` remains failed. |
| Original 1.0.23 data return | **PASS, scoped closure** — same native restore exit 0; original customer model/QR, six private file bytes/attributes, 16 media files and task choices preserved with exactly one ACL-order equivalence and five stock StartBoundary differences. Original wrapper remains failed; raw comparator remains review_required. |
| Complete BADC reapply | **PASS, 5 November** —896.534s within original 1,800s extraction/apply/closure bound; ordinary full same-version upgrade and strict original 1.0.23 customer/six private files/QR/16 media files/task preservation, using only already-scoped ACL/boundary classifications. |
| Final original-credential calls/full wire | **PASS** —8 cases/28.687s, four registrations and four decoded two-way UDP/TLS calls; all 16 streams/3,363 RTP packets including tails, zero invalid packets/clock violations, unchanged thresholds. |
| Final model/private/task/media preservation | **PASS** —exact accepted post-reapply customer model/six private files raw rows/task XML and enabled choices, all 16 original media plus four exact native-proven source-folder UUID-WAV recordings. Raw legacy-prefix comparator remains review_required; no broad media waiver. |
| Final manager and current encrypted backup | **PASS** —installed 1.0.23 manager visible/responsive/left open; ONE ordinary Create/natural scheduler/49.867s complete encrypted download, independently verified all 20 media/481 files. |
| Public Windows 1.0.23 assets/feed/readback | **PASS** — published 20:43:14 UTC; seven platform assets/four canonical additions fully read back, all three signed feeds verified, original 23 releases/172 assets/37 tags preserved. |
| Owned lab cleanup | **PASS** — only approved owned resources removed; foreign IIS/certificates/hosts, current product identities/source pins and private evidence preserved. |
| Ordinary installed public Check | **PASS** — public offer accepted 20:46:37.7647 UTC inside the original 180-second bound; up to date, no archive download/install or service/task/port action. |

The original local build used a frozen working tree and explicit new-file
allowlist. The corrected release candidate now has immutable Windows source
`e1aaad63f99ac3b11714d9d0cd3f2a085778688f`. The ZIP SHA-256 is
`badc4326b48d1e7953990eb382f598602bb23bd068ca27c42abf22c25ce10907`;
its raw release manifest is
`8d6c8f5c7e34cd813df7b805c726c19eec4a676739c1441a7aec3cf4a2d1cd7b`.
The 50,251,792-byte application source archive is
`4d581c86667782bd49f998afb084e06af91af7958dbd130ca52f4a3ab37eb5c8`.
Its public release is
[windows-v1.0.23](https://github.com/embire2/openwebpbx/releases/tag/windows-v1.0.23),
ID 435407275, published at 2026-11-05T20:43:14Z with the annotated tag bound to
that frozen source. See the
[release qualification](release-windows-1.0.23-qualification.md) for exact
composite/recovery scope and separate public-delivery evidence; Debian results
are not substituted for Windows checks.

## Actual signed normal transition — 5 November 2026

The final BADC signed offer completed the genuine installed 1.0.22-to-1.0.23 normal
transition in **1,340.0937 seconds**, from 19:22:54 to 19:45:14 UTC, inside the
original 3,600-second component bound. Native installation completed 19:44:26 UTC
before its original 19:55:37 UTC deadline. All five normal gates pass: signed
HTTPS download, installation, natural updater restart, manager reopen and
protected data. Before maps and the immediate command cursor were durably
retained; the new full database comparison includes both Phone Health tables.
Original registration/Health task choices were restored.

The retrospective comparison to an older pre-fault baseline remains **FAILED**
on digest differences in `v_pbx_phone_health_issues` and
`v_pbx_phone_health_state`. Row details and cause remain unknown. The earlier
failed baseline case (`62f2e423…`) and comparison (`22575466…`) are retained,
not converted into a pass. They are not prerequisites for the distinct normal
component's own fresh before/after preservation check. No early-rollback
database/full-file preservation or Windows 1.0.23 late-canary pass is claimed.
The [qualification record](release-windows-1.0.23-qualification.md) explains
the explicit Windows 1.0.22 rollback reuse and independently exercised corrected
recovery. Scoped original 1.0.23 return and complete BADC reapply are accepted
below; final calls/current backup and public release/readback/installed Check
are separately accepted below.

## Original 1.0.23 return — 5 November 2026

The original ordinary restore process 20784 exited 0 at 20:01:44 UTC, before the
original 20:15:22 UTC deadline. The observer's strict SCM Running poll failed;
its `fabc8737…` wrapper remains failed. A separate read-only closure passed
at 20:10:21 UTC in 1.348 seconds, using the same native process and original
deadline, without another restore or data/security repair.

The raw comparison `591d3a38…` remains **`review_required`**. The independent
closed semantic comparison passes the unchanged customer model/secret/QR/media
and task-choice checks. All 16 original media and six private file contents and
attributes are preserved. Five private SDDL strings are exact; only onboarding
`session.json` has the same SYSTEM owner/group/control flags and exact inherited
Full Access Allow ACE multiset (SYSTEM, Administrators, Owner Rights) in another
order. Nine actual native controls confirm this one equivalence. No broader
missing-file, owner, access or ACL normalization is admitted.

Five stock task start boundaries differ; all other XML including Date/Author
is exact. Only these fields and the exact one-file SDDL pair were normalized
in memory for the unchanged comparison. No snapshot, ACL, task, file or SQL row
was changed. The returned source bundle contained earlier BFC support bytes;
the complete BADC reapply below replaces them through the normal full installer.

## Complete BADC reapply — 5 November 2026

Native process 8684 exited 0 at 20:25:26 UTC. Full extracted-package reapply and
closure completed 20:26:41 UTC in 896.534 seconds, before the original 20:41:44 UTC
deadline and inside the shared 1,800-second limit starting 20:11:44 UTC. The
ordinary stock helper completed/finalized version 1.0.23 and verified its retained
rollback bundle; no manual helper patch, signed-archive mode or trust reset was
used for this same-version operation.

Strict preservation passes for all captured original 1.0.23 customer projections,
credential/stable-QR fields, six private files contents/attributes/security, 16 media files,
task names/enabled choices, same boot and zero channels. Only the already
accepted session ACE ordering and exactly five stock time boundaries are
classified. Their inferred creation times, using the pinned installers'
exact offsets of one or two minutes, fall inside actual native apply. All other XML,
including Date/Author, is exact. Final original-credential calls and public
release/Check are separately accepted below.

## Final calls and current backup — 5 November 2026

All eight original-credential UDP/TLS software cases pass in 28.687 seconds
inside the 180-second active bound: four registrations and four opposite calls
with decoded two-way audio. Full-wire replay covers all 16 streams/3,363 packets,
including tails, with zero invalid packets or clock violations. Thresholds
remain 0.8 coherence/80ms maximum gap/5% missing clock. No runtime/threshold
change or automatic repeat was used. Carrier/physical-phone scope is unchanged.

Post-call data preserves all captured customer tables, six private files full raw
rows and task XML/enabled choices exactly against the accepted post-reapply
snapshot. All 16 old media files remain exact and four new recordings bring
the total to 20. The original comparator's `storage/recordings` assumption
remains review_required; a separate source-bound component verifies only the
actual four UUID-WAVs in the existing original-domain `storage/openwebpbx`
recording folder. Native lengths/hashes/ordinary files/direct containment and
ancestor checks pass; 15 focused controls deny unrelated paths and metadata.
No ACL, time, media, task or customer-data normalization is added after calls.

The installed 1.0.23 native manager is visible/responsive in the ordinary
desktop session and remains open. One ordinary backup request completes via
the natural scheduler and full encrypted download in 49.867 seconds, inside
its original 600-second fence. Independent verification in 2.851 seconds checks
all 20 media/481 manifest files, all six live identities and five archived source
private files. The Phone Health target identity remains live, not falsely
claimed as an archive member. Normal logout completes; no settings or workers
are manipulated.

## Public release and installed Check — 5 November 2026

Windows 1.0.23 was published at **20:43:14 UTC**. All seven platform assets and
four immutable canonical `v1.0.23` additions pass complete anonymous download
size/hash verification. The original seven canonical Debian assets and all
23 earlier releases/172 assets/37 tags are preserved. Latest Windows 1.0.23,
Debian 1.0.23 and Android 1.0.19 signed feeds verify; the latter two remain
byte-for-byte unchanged.

Owned loopback-lab cleanup passed at 20:40:20 UTC, preserving foreign IIS,
certificates/hosts, current product identities/source pins and private evidence.
One ordinary CSRF-protected public **Check** then accepted the installed
1.0.23 offer at **20:46:37.7647 UTC**, before the original 20:49:29.876 UTC
observer deadline. Sequence 1793892995, minimum installed 1.0.22 and exact
BADC archive metadata were accepted; the result is `up_to_date`.

The Check performs ordinary cache/trust/status/journal writes. It downloaded
no archive and performed no apply/install, service/task, firewall or port action.
Boot, four service generations, 16 runtime pins, six private identities,
20 media files and task definitions remain exact. Full archive delivery is
proved by the separate public readback. This does not create a new 1.0.23
late-canary, fresh-install, carrier, physical-phone or Store acceptance.

## Packaging and copy coverage

The four new shared runtime files are:

- `resources/classes/pbx_did_routes.php`
- `app/pbx_setup/did-wizard.php`
- `app/pbx_setup/did-wizard.js`
- `app/pbx_setup/did-wizard.css`

The changed shared routing code also includes the DID entry points, provider
summary, Call Me Back settings, native incoming-rule projection and the
`app/pbx_setup/resources/switch/scripts/app/pbx_setup/policy.lua` policy.

The stock [packager](../packaging/build-release.py) starts with `git ls-files`.
An untracked new file is therefore **not included automatically**. The original
4 November private build inventoried these runtime files and guides in its own
source snapshot/index without changing shared HEAD or committing. A build must
exclude live configuration, credentials, signing keys and unrelated user files.
The final `release-manifest.json` must contain the actual new payload entries.

The existing Windows copy paths need no filename-specific installer patch:

| Existing path | Coverage |
|---|---|
| [Fresh installer](../packaging/windows/Install-OpenWebPBX.ps1), whole `web` tree copy | Installs the new PHP class and wizard assets when present in the package. |
| [Upgrade helper](../packaging/windows/Upgrade-OpenWebPBX.ps1), whole `web` tree copy | Adds/replaces those files after complete manifest verification. |
| Upgrade helper, native `pbx_setup` script copy before and after migration | Deploys the updated incoming Lua policy and related scripts. |
| Existing backup/rollback `web` mirror | Restores previous bytes and removes new package files absent in the previous web snapshot. |

These are source coverage findings. They do not replace final package-member
verification or installed-file readback. The actual23 package must carry its own
matching native version metadata; a web-only overlay on22 is not a full23 build.

## Routing behavior to verify

The canonical editor is **DID Numbers**, at `?view=incoming&edit=new` or an owned
rule UUID. Trunk pages show summaries and links rather than independent routing
forms. Call Me Back service settings preserve routing state; the DID wizard owns
the destination switch. The setup option is a handover, not service activation.

Number matching has three relevant inputs:

- The trunk's saved To-user or Request-URI source field selects the provider's
  actual incoming number. Sender address and native gateway binding still apply.
- One DID may retain explicit `number_aliases`; PHP/native XML and Lua must use
  the same primary number and aliases. A saved disabled DID keeps ownership of
  those forms and must not fall through to another destination.
- `country_calling_code='27'` enables only the supported South African
  national/E164 equivalence. An absent or different setting does not enable it.

Fallback matching remains limited to numbers declared on that provider, with
the existing source-IP/gateway/PBX ownership checks. A catch-all must not steal
a configured DID merely because that DID is off. A global leading-zero removal
or a hardcoded hosted-company number/destination is not part of the candidate.

### Country selection boundary

The earlier Windows install/Create my PBX flow did not supply a country field.
It cannot safely be treated as South African by default. This candidate adds an
optional **Number format** choice in wizard step1: **South Africa (+27)**,
**Use current PBX setting**, or **Use exactly what I enter**. The submitted
`number_country` is respectively `27`, empty, or `exact`. Empty/absent keeps the
existing setting; an already explicit27 setting is the default. Selecting exact
entry does not retroactively delete saved aliases or their destination. The
ordinary Windows browser check must prove per-PBX scope and preservation of
an absent/current setting.

An owned qualification fixture may explicitly select27 through that UI to test
the national/E164 positive case. That does not authorize setting every existing
Windows tenant to27. A future restored-PBX country migration would need a known,
explicit source-country binding and the owner's confirmation; no such migration
or guessed-country setup is claimed here.

## Original local qualification scope — 4 November 2026

Reuse unchanged accepted Windows 1.0.22 components, while recording the following
affected checks separately for the local candidate:

1. **Freeze and preserve.** Bind the exact complete private package and source
   inventory. Retain a verified encrypted current22 backup and private identities,
   configuration, task/service choices and media. Record actual idle calls and
   current host/install identity before any maintenance.
2. **Verify affected behavior in isolated fixtures.** Cover scoped/stale saves,
   provider binding, exact and aliased DID projection, explicit/absent country,
   disabled-DID fallback refusal, hours/holiday preservation and atomic Call Me
   Back selection/setup. Real Windows results remain separate from portable
   PHP/Lua checks and Linux results.
3. **Use one ordinary manual upgrade.** From the verified complete extracted
   payload, use built-in elevated Windows PowerShell5.1 and the existing
   `Upgrade-OpenWebPBX.ps1 -Check`, then its normal manual installation. Preserve
   every maintenance/restore/call/ownership/recovery check. No worker invocation,
   status/clock reset, new registration claim or arbitrary SQL repair substitutes
   for installation.
4. **Read back the installed result.** Confirm23 assembly/application versions,
   all newly required PHP/JS/CSS and native Lua bytes, retained source registration
   and key identity, existing phone authentication, providers, greetings, current
   data and original enabled/security choices. Verify trusted tenant web access.
5. **Exercise the ordinary UI and calling.** Use the actual Windows browser to
   edit a test DID, save an external destination without losing leading zeros,
   select explicit country only in the owned test PBX, and check aliases/native
   projection and disabled fallback behavior. Check the Call Me Back setup
   redirect without activating it. Then qualify actual registration and decoded
   two-way software calling with unchanged packet/audio predicates; replay the
   complete capture including tails. A provider/physical answered call has its
   own scope and is not inferred from UI checks.
6. **Verify a current backup.** Include the new DID/country/alias configuration,
   existing credentials/private keys and current media in an encrypted backup;
   verify it and its retained copy. Keep the upgrade rollback snapshot. Reuse
   unchanged22 recovery tests honestly; expand only if recovery/migration code
   changes or an actual failure requires it.

No new full public release suite, forced failure on customer data, fresh managed
registration, cold retirement or arbitrary repeat is required merely to call
this a locally tested manual upgrade. A later public release needs its own
approved release qualification and publication decision.

## Manual updater route and trust — original 4 November scope

The selected local route is the complete extracted payload's manual helper,
**without `-Archive`/`-FeedEnvelope`**. It checks the manifest and uses the normal
maintenance and recovery code. The private package/source hashes are verified
before launch. This route does not change public feeds or their installed trust
floor and does not claim signed worker download/install qualification.

The separate signed-archive path calls the installed verifier. That verifier
checks the pinned release key, Windows platform, package hash/size, canonical
asset name/URL, expiry, sequence floor and minimum version. Successful
`--verify-package` also persists trust history. A higher-sequence private23 feed
can therefore make the still-public 1.0.22 feed stale on the test installation; an
arbitrary localhost asset URL is not accepted instead. Do not lower that floor,
replace the release key or rewrite public metadata to disguise the distinction.

No signer or new signed packet is needed for the selected manual check. An
offline signing key must never be transferred to Windows. If a later task
requests a private signed updater test, review its exact caller, metadata,
trust consequences and cleanup separately. Public22 signed enabled/disabled
qualification stays recorded as22 evidence, unchanged.

## Actual local results — 4 November 2026

The test server 149.248.36.197 completed the ordinary extracted manual upgrade
to1.0.23 in 739.944 seconds, native exit 0. Its four services and trusted HTTPS
returned normally. Sixteen changed/shared runtime leaves and the native routing
policy match source; all three native component versions are1.0.23.0. All 23
captured SQL table projections, six private identity/configuration files,
original QR/mobile credentials and ten original media files were preserved.
Task names and enabled choices were preserved; five stock installers reset only
their scheduled start timestamps. The native manager is visibly responsive
and remains open in the normal user's RDP session.

The ordinary browser passed 49 checks: one canonical DID editor, country27
selection, national/international alias preservation, exact external forwarding,
Call Me Back setup handoff without activation,390px layout and no script errors.
The disabled temporary provider/DID/outbound fixture was removed through an
exact scoped transaction; all 23 SQL projections then matched the original.

Two initial software-call attempts failed strict audio-tone quality checks.
Their packet captures remain failed: one contained an output clock gap, and
both contained brief output silence/phase changes. The internal receive/network
condition was not established. A Windows-only60ms receive buffer, allowed to
grow to 200ms and retained during bridging, then passed the unchanged full
eight-case UDP/TLS registration and two-way audio matrix in 28.990 seconds.
Existing administrator buffer/off/bridge choices are preserved. Debian policy,
codecs, encryption, NAT learning and credentials remain unchanged. The two
installed Lua copies were atomically replaced with unchanged ACLs and no
service restart. The final private package must contain this correction; the
original `dd9ac9f9…` ZIP is an intermediate artifact.

One ordinary encrypted backup completed with media and built-in full archive
verification. Its 26,559,387-byte encrypted download has SHA-256
`5af7b0513aa706ed2d86d9e8f5ed2e582972b55932c6d46a3edb5fa59ba6053a`.
Creation to full off-server download took 201.715 seconds. It includes the
11 recordings present at its creation; later calling-test recordings remain
on the test server. Earlier wrapper/transport/checksum-observer refusals are
retained separately, rather than relabelled as successful whole runs.

These are private build, installed upgrade, UI, software calling and backup
results. No new fresh-install, carrier, physical desk-phone, Store, signed
update or public-release acceptance is claimed.

## Earlier private BFC repack — 4 November 2026

The earlier complete BFC package was 643,268,769 bytes with 19,288 verified
payloads. It is withheld after the consumed-CDR recovery issue and superseded
by the corrected e1/BADC package above. Historical SHA-256:

```text
bfc02f54e6c6978748b7ce8b3e8ec432c7d25b21330ccaee915919ea94939e95
```

Private Windows location:
`C:\W123-f47528e0\o\openwebpbx-1.0.23-windows-x64.zip`.
All three native build outputs were reused only after their source inputs and
output hashes/sizes were proved unchanged; no engine, prompt or music rebuild
was needed. Stock packaging and complete archive readback finished in 535.077
seconds. The earlier `dd9ac9f9…` ZIP remains retained as an intermediate.

Independent replay verified 16 RTP streams/3,371 packets, including tails, under
the original thresholds. Measured two-way tone coherence was at least 0.999825;
the least coherent tail window was 0.963796, above the unchanged 0.8 threshold.
One later tail phase/gap observation remains recorded; this is a genuine pass
of the defined checks, not a claim that all network/media events vanished.
After all calls, all 23 captured SQL projections and six private identities
remain exact, all ten original recordings survive, and six new calling-test
recordings remain. No temporary DID/provider or live test call remains.

These 4 November notes include post-build results; that archive's frozen source
map and manifest remain separate. No GitHub/feed/website publication occurred
under the original local-only task. The user's 5 November publication instruction
supersedes that restriction; the 5 November publication and its separate checks
are recorded in Current status above.
