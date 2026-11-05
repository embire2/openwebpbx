# Windows Server 1.0.23 — local qualification and release transition

**Current status — 5 November 2026:** the user has authorized publication after
the actual remaining release checks. The corrected frozen e1/BADC installer
passes complete private package verification, native consumed-CDR controls,
actual interrupted-restore recovery and the final normal signed 1.0.22-to-1.0.23
transition. Original 1.0.23 data return, complete BADC reapply, final calling and
public checks remain **PENDING**. Windows 1.0.22 remains the public Windows download.

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
| Earlier installed22→23 manual upgrade and preservation | **PASS, 4 November component** — native exit0 in 739.944s; 23 SQL projections, identities, QR, media and task choices preserved. Not final BADC installation. |
| Actual Windows browser save, number-format choice and Call Me Back setup handover | **PASS** —49 checks; temporary disabled fixture removed, original config restored |
| Earlier original-credential calling and backup | **PASS, scoped component** —8 UDP/TLS registration/two-way audio cases after Windows buffering fix; verified encrypted backup downloaded. Final post-return calling is pending. |
| Consumed-CDR recovery correction | **PASS** — 89 native controls across 21 cases and actual corrected-helper recovery at 13:15:08 UTC on 5 November. |
| Unchanged late rollback | **REUSED WINDOWS 1.0.22** — actual signed cases 41752080297/41722715796; no new 1.0.23 late-canary pass. |
| Final signed normal BADC 22→23 | **PASS, 5 November** — all five normal gates in 1,340.0937s inside the original 3,600-second component and 1,800-second native bounds; fresh full baseline including both Health tables preserved. Failed result `c0ca49cf…` remains failed. |
| Original 1.0.23 data return and full BADC reapply | **PENDING** — original model, QR, six private identities, 16 media files and task choices, then complete reapply/preservation. |
| Public Windows 1.0.23 assets/feed/readback and ordinary installed Check | **PENDING** — publication authorized, acceptance not yet established. |

The original local build used a frozen working tree and explicit new-file
allowlist. The corrected release candidate now has immutable Windows source
`e1aaad63f99ac3b11714d9d0cd3f2a085778688f`. The ZIP SHA-256 is
`badc4326b48d1e7953990eb382f598602bb23bd068ca27c42abf22c25ce10907`;
its raw release manifest is
`8d6c8f5c7e34cd813df7b805c726c19eec4a676739c1441a7aec3cf4a2d1cd7b`.
The 50,251,792-byte application source archive is
`4d581c86667782bd49f998afb084e06af91af7958dbd130ca52f4a3ab37eb5c8`.
Its platform release/tag and public delivery remain pending. See the
[release qualification](release-windows-1.0.23-qualification.md) for exact
composite/recovery scope; Debian success cannot turn a pending Windows row
into a pass.

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
recovery. Return of the original 1.0.23 data, complete BADC reapply, final calls
and public release/Check still require their separate actual results.

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
to1.0.23 in 739.944 seconds, native exit0. Its four services and trusted HTTPS
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
supersedes that restriction; final Windows 1.0.23 publication remains pending.
