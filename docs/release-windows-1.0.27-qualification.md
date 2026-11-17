# Windows Server 1.0.27 qualification

**In qualification; not a public release announcement.** The public Windows
release remains 1.0.23 until the final complete package is accepted and promoted.

The intended release is one standalone Windows Server 2025 x64 Desktop
Experience package. Fresh installation requires no previous PBX or separate PBX
repair. Existing-data updates retain separately enforced compatibility,
signature, backup and recovery checks.

## Acceptance work

| Area | Current evidence |
| --- | --- |
| Standalone installation contract | Source includes a complete-installation contract and read-only full-manifest preflight, using the included isolated interpreter. Final-package validation remains pending. |
| Native server, updater and WinUI manager | Must be rebuilt as 1.0.27.0 from the frozen Windows source; no relabelled older executables. Final build and target desktop checks remain pending. |
| Dedicated target | Actual Windows Server 2025 Desktop Experience at the owner's supplied target; existing Windows23 state captured before changes. |
| Recovery checkpoint | Ordinary full encrypted Windows23 backup, verified and copied offhost: 27,312,341 bytes, SHA-256 `9ebf36c24680d34bc26fa0fa275dd2244ea8e15982c85d99dfc24380a3602768`. Broader database, file, task, certificate and service baselines are retained privately. |
| Backup lock observations | Two earlier attempts correctly refuse active Windows lock contention. The successful bounded retry completes while Phone Health is still running. A separately approved short task stop happens afterward and is reversed; it is not the cause of that success or proof of a persistent lock defect. |
| Fresh installation and ordinary registration | Pending final complete archive; any reused OS/prerequisite evidence will be named explicitly. |
| Original23 automatic update | Pending actual original native-worker signed check/download/install using the final package. A manually invoked new helper is not a substitute. |
| Late failure and rollback | Pending a separate bounded failure transaction and independent data/identity/service comparison. |
| Windows integration | Tenant protection/recovery worker, IIS API routes, isolated upload admission and populated-target restore are being ported and tested. Source checks alone do not accept the final installation. |
| Calling and APIs | Pending actual Windows package controls. Software SIP/RTP checks do not establish physical phone, carrier or human audio acceptance. |
| Public downloads and feed promotion | Pending qualification. Existing Debian27, Windows23, Android19 and Windows catalogue bytes remain retained. |

## Preserved scope

Windows-specific audio buffering, phone identity/authentication bytes, reusable
QR identities, custom recordings, routes, allowances, certificate choices and
existing task enablement remain preservation requirements. Shared source
features from Debian24–27 need their relevant Windows checks before their
catch-up rows can close.

The immutable Debian27 canonical release is not retagged for Windows. Any
canonical Windows assets must be additive, with distinct Windows checksums and
matching platform-tag source. Retained feeds and historical assets are not
overwritten to simulate an upgrade path.

Raw logs, backups, passwords, QR payloads and provisioning URLs stay in private
operation storage. Earlier failed checks remain separate from corrected passes.
The broader roadmap remains 133 items: 21 accepted, 72 partial and 40 planned.

[Installation](installing-windows-1.0.27.md) ·
[Windows catch-up ledger](debian-windows-sync.md) ·
[Independent releases](independent-platform-releases.md).
