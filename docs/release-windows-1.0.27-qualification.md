# Windows Server 1.0.27 qualification

**In qualification; not a public release announcement.** Public Windows remains
1.0.23 until the complete installer passes its remaining Windows tests.

The intended release is one standalone package for Windows Server 2025 x64
with Desktop Experience. A fresh installation needs no previous PBX or separate
PBX repair. Existing-data updates retain their own signed compatibility,
backup, active-call and recovery checks.

## Current complete package

Frozen package source: `80526bff862f6b71c7629c408a6d7bf7ca601f92`.
The archive is **643,863,921 bytes**, SHA-256
`b1c9f0ba0ad2f31d019f67a7276cd65898d317b91b9e3bd24cc00cded5c490f6`.
Independent extraction and the ordinary full-package checker validate every
one of **19,351 manifested payloads**, **4,915 spoken files**, the full-install
contract and the reviewed Windows installer/worker source bindings.
`installation.json` explicitly declares `package_type=full` and
`previous_installation_required=false`; local PostgreSQL setup and the current
updater are included.

Native build [44156649617](https://github.com/embire2/openwebpbx/actions/runs/44156649617)
compiles Core, updater and WinUI manager **1.0.27.0** from
`d3d1651635c7337d25c7285f9910b486b9d2f0d7`. All **89** compiled native source
inputs and **1,110** output/checksum entries remain exact in the frozen package
source. Five reviewed recovery/IIS runtime leaves and five focused tests differ;
none changes those native build inputs. The IIS admission module is compiled
separately during ordinary Windows setup. No older Core, updater or manager
executable is relabelled as 1.0.27.

This new complete archive reuses byte-exact compressed members from the earlier
complete package where source and metadata are unchanged. It contains every
component: no customer applies a patch or supplies an earlier PBX. Engine,
ACME, backup runtime, music and voice inputs retain their recorded Windows23
provenance; the three native applications are rebuilt27. Optional locally built
codec DLLs are not redistributed.

## Acceptance status — 18 November 2026

| Area | Actual evidence and remaining gate |
| --- | --- |
| Full installation contract | Current complete ZIP independently extracts; every payload hash, source binding, voice count and full-release contract passes. Actual fresh installation is a separate gate. |
| Native applications | Native27 versions and responsive manager window pass in the Windows build environment. 41 signed-grant, 57 protocol, 82 updater, 13 Windows worker, 11 native notice and 20,050 STUN controls pass. The protocol run does not claim database-backed call-capacity acceptance. Installed target manager remains pending. |
| Windows recovery integration | Authenticated fixed-command call-engine adapter passes three actual Windows controls; query-only import classifier passes213; IIS identity handling31; fixed support-directory ownership122; generated-cache ACL admission39. These do not replace a real restore. |
| Supplied existing server | Owner's dedicated Windows Server2025 target; original23 checkpoints and independent schema, files, identities, certificates, tasks and service baselines retained privately. |
| Original recovery checkpoint | Verified ordinary encrypted backup copied offhost:27,312,341 bytes, SHA-256 `9ebf36c24680d34bc26fa0fa275dd2244ea8e15982c85d99dfc24380a3602768`. |
| Owned phone fixtures | Separate checkpoint27,316,626 bytes, SHA-256 `6a8f83fad7cbc4b4b68d75fe3eaac0ddc49696a828ef0765f9535b7c1b9fe00c`; two owned extensions preserve distinct authentication IDs, special password bytes, app-password state and one custom WAV. All nine original customer projections and468 original archived files remain exact before the transaction. |
| Baseline software calling | Eight original23 registration, answered-call and decoded two-way RTP controls pass; fixtures unregister afterward. Post-upgrade calling remains separate. |
| First-candidate read-only entry | Unelevated Help and Check pass using the included Python;19,352 files/1,200,354,057 bytes and five existing service generations remain exact. This was the earlier82bc archive, not current final-byte acceptance. |
| Actual original23 updater | First82bc package is downloaded, verified and preflighted by the original installed worker. Mandatory notice, red banner, postponement with services running, enabled UpdateNow and normal elevation are observed. Final current-package transaction remains pending. |
| Late failure and automatic rollback | First82bc controlled late failure enters ordinary rollback, which fails. The defects and manual recovery below remain distinct. A successful current-package automatic rollback has not yet been established. |
| Manual recovery | Source-assisted recovery verifies original seals and binds27 unchanged original functions plus four reviewed support helpers. Its new read-only Check passes. The second manual attempt stalls in IIS configuration disposal and is stopped at its20-minute bound with seals unchanged. A separately gated MTA continuation is under test; neither is automatic-rollback acceptance. |
| Clean Windows machine | Owned OS-only Windows Server2025 Desktop VM proves four PBX roots absent and zero PBX/PostgreSQL services. After moving to an admitted host it has six GiB RAM and retained clean snapshot. Current whole-package download, Check, installation and ordinary registration are in progress. |
| Feature integration | Tenant/instance protection worker, IIS API routing and body-free upload admission are ported. Final installed API roles/templates/resources, stable QR, capacity, full/tenant restore, software calling and reboot checks remain pending. |
| Public release | No Windows27 tag, public assets or latest-feed promotion. Debian27, Android19, public Windows23 and historical catalogue remain retained. |

The current private signed offer has sequence **1795014530**, minimum installed
version **1.0.23**, envelope SHA-256
`96ecfc3784ef0613925c4a86bb19d4f7de9bd3914083af0a64783cf19f991990`.
Its catalogue SHA-256 is
`832f392cc4ca1bbad3d9020a90250275f72258b10ce776a2117432fcda724994`;
it retains the original20→21→22→23 prefix and appends the exact new27 offer.
Offline platform promotion guards and package/feed checks pass, preserving
Debian27 and Android19 envelopes exactly. This is private test authority only.

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
