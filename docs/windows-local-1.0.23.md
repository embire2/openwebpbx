# Windows Server 1.0.23 — local candidate scope

**Unpublished, privately installed and tested.** This work catches the Windows
server up to the shared DID wizard and routing corrections. A normal manual
**Windows22→23** upgrade completed, followed by a scoped audio correction.
The final installer is being repackaged with that correction.
It authorizes no GitHub commit/push, workflow, release asset, tag, public feed or
website publication. Windows 1.0.22's accepted release evidence remains valid
for that version; it is not relabelled as a 1.0.23 result.

Use the [local installation guide](installing-windows-1.0.23.md). Linux, Windows
and Android keep their own qualified artifacts and release cadence; see
[independent platform releases](independent-platform-releases.md).

## Current status

| Component | Local 1.0.23 status |
|---|---|
| Complete private package, full source/payload inventory and archive SHA-256 | Initial19,288-payload package passed; **final audio-corrected repack pending** |
| Native server/updater and WinUI manager build | **PASS** — all three components1.0.23.0; installed manager visibly responsive |
| Focused real Windows DID/alias/runtime-policy fixtures | **PASS** —188 PostgreSQL/PHP controls on actual Windows Server2025; no new native-Lua claim |
| Actual installed22→23 manual upgrade and preservation | **PASS** — native exit0 in739.944s;23 captured SQL tables, identities, QR, media and task choices preserved |
| Actual Windows browser save, number-format choice and Call Me Back setup handover | **PASS** —49 checks; temporary disabled fixture removed, original config restored |
| Original-credential software calling and encrypted backup | **PASS** —8 UDP/TLS registration/two-way audio cases after Windows buffering fix; verified encrypted backup downloaded |
| New public Windows23 signed offer/download/publication | **NOT REQUESTED** |

The package must include the frozen **working-tree** source plus an explicit
allowlist of new files. There is no new immutable product commit or published
tag for this local candidate. Record the actual archive hash, source-file hashes,
runtime inputs, build outputs and test receipts when they exist; no pending row
above is a pass merely because shared code works on Debian.

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
An untracked new file is therefore **not included automatically**. The private
build must inventory the exact new runtime files and these guides in its own
source snapshot/index without changing shared HEAD or making a commit. It must
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

## Minimum actual22→23 qualification

Reuse unchanged accepted Windows22 components, while recording the following
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

## Updater trust and private callers

The selected local route is the complete extracted payload's manual helper,
**without `-Archive`/`-FeedEnvelope`**. It checks the manifest and uses the normal
maintenance and recovery code. The private package/source hashes are verified
before launch. This route does not change public feeds or their installed trust
floor and does not claim signed worker download/install qualification.

The separate signed-archive path calls the installed verifier. That verifier
checks the pinned release key, Windows platform, package hash/size, canonical
asset name/URL, expiry, sequence floor and minimum version. Successful
`--verify-package` also persists trust history. A higher-sequence private23 feed
can therefore make the still-public22 feed stale on the test installation; an
arbitrary localhost asset URL is not accepted instead. Do not lower that floor,
replace the release key or rewrite public metadata to disguise the distinction.

No signer or new signed packet is needed for the selected manual check. An
offline signing key must never be transferred to Windows. If a later task
requests a private signed updater test, review its exact caller, metadata,
trust consequences and cleanup separately. Public22 signed enabled/disabled
qualification stays recorded as22 evidence, unchanged.

## Actual local results — 4 November 2026

The test server149.248.36.197 completed the ordinary extracted manual upgrade
to1.0.23 in739.944 seconds, native exit0. Its four services and trusted HTTPS
returned normally. Sixteen changed/shared runtime leaves and the native routing
policy match source; all three native component versions are1.0.23.0. All23
captured SQL table projections, six private identity/configuration files,
original QR/mobile credentials and ten original media files were preserved.
Task names and enabled choices were preserved; five stock installers reset only
their scheduled start timestamps. The native manager is visibly responsive
and remains open in the normal user's RDP session.

The ordinary browser passed49 checks: one canonical DID editor, country27
selection, national/international alias preservation, exact external forwarding,
Call Me Back setup handoff without activation,390px layout and no script errors.
The disabled temporary provider/DID/outbound fixture was removed through an
exact scoped transaction; all23 SQL projections then matched the original.

Two initial software-call attempts failed strict audio-tone quality checks.
Their packet captures remain failed: one contained an output clock gap, and
both contained brief output silence/phase changes. The internal receive/network
condition was not established. A Windows-only60ms receive buffer, allowed to
grow to200ms and retained during bridging, then passed the unchanged full
eight-case UDP/TLS registration and two-way audio matrix in28.990 seconds.
Existing administrator buffer/off/bridge choices are preserved. Debian policy,
codecs, encryption, NAT learning and credentials remain unchanged. The two
installed Lua copies were atomically replaced with unchanged ACLs and no
service restart. The final private package must contain this correction; the
original `dd9ac9f9…` ZIP is an intermediate artifact.

One ordinary encrypted backup completed with media and built-in full archive
verification. Its26,559,387-byte encrypted download has SHA-256
`5af7b0513aa706ed2d86d9e8f5ed2e582972b55932c6d46a3edb5fa59ba6053a`.
Creation to full off-server download took201.715 seconds. It includes the
11 recordings present at its creation; later calling-test recordings remain
on the test server. Earlier wrapper/transport/checksum-observer refusals are
retained separately, rather than relabelled as successful whole runs.

These are private build, installed upgrade, UI, software calling and backup
results. No new fresh-install, carrier, physical desk-phone, Store, signed
update or public-release acceptance is claimed.
