# Debian 1.0.27 release qualification

**Debian 1.0.27 published on 17 November 2026 at 16:12:26 UTC.**
The complete standalone installer, original26 signed update, anonymous public
downloads and ordinary installed-client public-feed check all pass within the
scope recorded below.

## Standalone installation contract

The 1.0.27 release is a **complete standalone server for clean Debian 13 amd64**.
It requires no previously installed OpenWeb PBX version and no separate PBX
patch. The full download contains the current application, calling engine,
web administration/API, updater, background services and bundled system prompts;
setup installs local PostgreSQL.

The manifest-sealed `installation.json` declares `package_type: full` and
`previous_installation_required: false`. Setup prepares missing OS dependencies
automatically, then validates the complete package and refuses existing PBX
data before starting PBX/database writers. Read-only `--help` and `--check`
do not install packages or initialize services.

Signed updater compatibility is a separate existing-data contract. It never
becomes a prerequisite for installing a new machine. The published offer's
minimum, source binding and actual/reused acceptance must be recorded below
without changing earlier signed assets or resetting trust.

## Artifact identity

- Frozen source: `72bb5406af4c057acb5ee4eddfd9d861d20d345f`.
- Archive: `openwebpbx-1.0.27-debian13-amd64.tar.gz`, **488,884,221 bytes**.
- SHA256: `fa771a66999ec2811212ed452588025c5cbe78b0502b8afd7794588c0e236198`.
- All **12,260** manifest payloads match, including **4,915** bundled Keoma voice files.
- The full installation contract is sealed and declares `previous_installation_required: false`.
- Signed update sequence: `1794929086`. Its existing-data update admission starts at installed 1.0.22; this is not a new-server installation requirement.

Both immutable releases carry the same eight accepted asset bytes from the
frozen source: canonical `v1.0.27` was published at 16:12:24 UTC, followed by
latest `debian-v1.0.27` at 16:12:26 UTC. This is a full fresh-install release;
its existing-data updater admission is a separate compatibility contract.

## Acceptance evidence

| Check | Status | Evidence and scope |
| --- | --- | --- |
| Complete standalone package contract | PASS | Exact frozen `72bb` archive above; all 12,260 payloads / 4,915 voice files match their manifest; full metadata requires no previous PBX, and required server components are present |
| Help and read-only preflight | PASS actual complete archive | Unmodified fa771/source `72bb` on clean Debian 13: ordinary --help and --check pass, full contract matches, no previous PBX before/after and no apt/dpkg/service/PBX writes. The same complete installer refuses fresh overwrite of a genuine 26 server, preserving apt/dpkg, private config/version and six service generations. Focused malformed-payload controls remain separate |
| Clean Debian 13 installation | PASS actual unmodified installer | Exact fa771 full 27 archive starts on clean Debian 13 without any previous PBX or separate PBX patch; ordinary installer exits 0 in 281.563497 seconds, 15:30:37.082794–15:35:18.646291 UTC. Managed setup and calling acceptance remain separate rows |
| Managed registration and user/API access | PASS actual ordinary flow | Normal new-owner-pairing wizard and natural tenant DNS/trusted HTTPS; 11 local company/user/repeated-stable-QR controls,28 administrator API controls and15 personal-role API controls pass by15:57:50.822814UTC within the original16:05:37.082794UTC whole setup deadline. Test keys revoked/role withdrawn, no pending contact, no invitation email requested and no QR reset |
| Software calling and startup | PASS fresh27 software | Eight actual original-credential SIP/RTP controls: both owned endpoints register, answer and exchange decoded440/660Hz tones before unregistering. A real OS reboot changes the boot identity and automatically returns Core27Running/all six critical services in38.09seconds; no manual product service starts. No physical phone or carrier audio acceptance is claimed |
| Original 1.0.26 signed update | PASS actual ordinary updater | Original 26 worker processes the complete signed 27 download; queue 15:45:50.076107 → finish 15:53:13.322656 UTC, 443.246549 seconds. Native worker and journal finalization complete naturally, installed/available 27. No manual helper/migration/recovery/tick; independent preservation/calling checks remain separate |
| Existing-data preservation | PASS independent exact comparison | All195 original tables/full schema/columns/roles/cluster remain exact under finite updater/heartbeat transitions;190 unrelated multisets are exact. All12,293 source-bound targets plus the upload pool match;324 private files/media/security remain unchanged. One named backups bytecode cache and the original26 worker's finite source-bound recovery-helper promotion are proved separately; no product/cache edit is used to pass comparison |
| Post-update original user access | PASS | 24 ordinary existing device/Bearer, account and both users' original extension/authentication-ID/password-byte/server/realm checks pass; no QR issuance or reset. This26 baseline retains its older enrolled profile; it is not relabelled an original stable-QR payload test. Eight actual post-update SIP/RTP controls also pass with original credentials and two-way decoded tones |
| Reused unchanged component evidence | PASS source binding; earlier acceptance explicitly reused | 45 original upgrade/verification/native transaction inputs are byte-exact from qualified 26 source `5b60` to frozen 27 source `72bb`; native version metadata changes separately. Earlier genuine 22/23 updates and late rollback keep their original 26 acceptance; the actual 26→27 transaction is recorded separately above |
| Public release promotion | PASS | Canonicalv1.0.27 and latestdebian-v1.0.27 published from frozen72bb at16:12:24/16:12:26UTC; both carry the same eight complete asset bytes. Public content verification is a separate row |
| Anonymous public assets | PASS actual public downloads |20 actual anonymous downloads,1,079,064,268bytes SHA256-verified across both8-asset releases plus latest4feed/catalogue paths. All26 prior published releases/assets remain; Windows23/Android19 signed envelopes and Windows ordered catalogue stay byte-exact |
| Installed client real public Check | PASS actual ordinary check | Original26→27 client queues16:15:01.318011 and completes16:15:19.033671UTC: installed/available27/up_to_date, official signed sequence1794929086 and exact fullfa77 archive/feed43666de3…9653d5f9. Real GitHub DNS/TLS after owned transport/hosts/CA removal; both trust hashes unchanged, Core27Running/all6active, no install/restart/version/trust reset requested |

## Finite update-file closure

The first file comparison correctly refused an unlisted recovery-helper change
and a generated backups bytecode cache. Both failures remain retained. Closure
binds the recovery-helper promotion to the exact source emitted by the original
26 worker's `ensure_recovery_integration()` and its expected ownership/mode.
The one named cache is proved against its exact source, interpreter/header,
compiled code and captured transaction window. No blanket file exception,
product/cache rewrite or security change is used to make the comparison pass.

## Unchanged component reuse

All **45** recorded upgrade, verification and native transaction inputs match
between qualified 1.0.26 source
`5b60f57458ab336cc5c9e928128054b8d9491bba` and frozen 1.0.27 source
`72bb5406af4c057acb5ee4eddfd9d861d20d345f`. The native version change is in
`platform/Directory.Build.props`; server and updater are compiled as 1.0.27.
The source comparison contains no new PBX PHP, call-routing Lua or database
schema logic. Fresh installer, package contract and builder changes are assessed
separately through the new artifact and clean-install checks.

The genuine original 22/23 signed updates to 26 and original 22 late-failure
rollback recorded on 16 November are reused only for those unchanged
transaction components. They are **not** described as newly executed 22/23→27
updates. The new actual original 26→27 update, its data preservation and its
public-feed check have independent rows above. Signed admission and saved trust
remain enforced; none is lowered or reset to change fresh-install messaging.

## Retained preparation observations

Initial private infrastructure controllers refused snapshot-generated parent
metadata and a restore-generated hypervisor generation ID; those exact
observations remain separate from the corrected ownership checks. A private
inspection helper also stopped on a script-module mismatch before infrastructure
access. The storage assessment was corrected from the OS filesystem to the
separate VM image volume without deleting files. None of these preparation
refusals is counted as product installation acceptance.

The first existing-owner wizard login reached the normal active API-key limit
and returned `409 token_limit`; that refusal is retained separately. A proven
owned Windows QA setup key, unused for 18 days, is authenticated to its exact
owner/token and self-revoked through the normal v1 DELETE route. The API returns
204, subsequent use returns 401, and active keys decrease 10→9 while every other
key's identity/hash/expiry/revocation stays exact. No quota, password, role,
security baseline or PBX configuration is changed. This is supported cleanup
of an unused owned test credential, not a product login fix. Actual new 27
managed-setup acceptance subsequently passes through the ordinary flow recorded
above; the earlier quota refusal remains distinct.

Pre-publication update testing uses guest-only owned HTTPS transport while
retaining the official package signature, installed-version admission and saved
trust history. The first transport readiness probe raced a reload and remains
retained; its strict retry does not bypass certificate validation. Owned test
transport and trust additions are removed before the accepted real public-feed
check; only the recorded owned objects are removed.

## Scope and retained evidence

The public [1.0.26 record](release-1.0.26-qualification.md) retains its original
fresh-install, genuine 22/23 update, late-failure rollback, QR/media preservation,
software calling and reboot evidence. Any unchanged evidence reused for 27 must
be named explicitly, with new 27 checks separate.

The 1.0.26 installer was already a complete clean-server bundle. Its signed
existing-server minimum was incorrectly easy to read as a fresh-install
requirement in the download messaging. Version 1.0.27 makes the full-install
contract explicit in package metadata, preflight and setup documentation.

No failure is erased or relabelled as a pass. Private credentials, keys, QR
payloads, provisioning URLs, raw logs and customer backups stay outside source
and public release assets. Main is not an installation or restore fixture.

Windows remains its independently qualified 1.0.23 suite with the retained
legacy updater repair; Android remains 1.0.19. Future complete server releases
must include their current updater in the full package. Webhotel image
publication, physical phones/carriers/cameras, Store approval and complete 3CX
parity remain separate. Roadmap totals remain **133 goals / 21 accepted /
72 partial / 40 planned**.
