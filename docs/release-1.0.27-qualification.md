# Debian 1.0.27 release qualification

**Qualification in progress.** Public Debian remains 1.0.26 until the exact
1.0.27 artifact passes its release checks and is published. A source change,
build or hosted overlay alone does not promote an installer.

## Standalone installation contract

The 1.0.27 release is a **complete standalone server for clean Debian 13 amd64**.
It requires no previously installed OpenWeb PBX version and no separate PBX
patch. The full download contains the current application, calling engine,
web administration/API, updater, background services and bundled system prompts;
setup installs local PostgreSQL.

The manifest-sealed `installation.json` declares `package_type: full` and
`previous_installation_required: false`. Setup prepares missing OS dependencies automatically, then validates the
complete package and refuses existing PBX data before starting PBX/database
writers. Read-only
`--help` and `--check` do not install packages or initialize services.

Signed updater compatibility is a separate existing-data contract. It never
becomes a prerequisite for installing a new machine. The published offer's
minimum, source binding and actual/reused acceptance must be recorded below
without changing earlier signed assets or resetting trust.

## Artifact identity

Final archive/source/manifest hashes, sizes, frozen source and signed update
offer are pending. The archive name is
`openwebpbx-1.0.27-debian13-amd64.tar.gz`. Only the accepted immutable bytes may
be promoted as `debian-v1.0.27` with their canonical `v1.0.27` mirror.

## Acceptance evidence

| Check | Status | Required evidence |
| --- | --- | --- |
| Complete standalone package contract | PENDING | Manifest inventory, installation metadata and every required component in the full archive |
| Help and read-only preflight | PENDING | Ordinary installer invocation; no package/service/data mutation; missing/mismatched payload and existing-PBX refusal |
| Clean Debian 13 installation | PENDING | No prior PBX files, services or database; exact unmodified archive and ordinary installer |
| Managed registration and user/API access | PENDING | Ordinary owner wizard, tenant DNS/trusted HTTPS, local sign-in, QR stability and current-role checks |
| Software calling and startup | PENDING | Actual owned SIP/RTP and automatic service startup/reboot within recorded scope |
| Original 1.0.26 signed update | PENDING | Original installed worker, signed full download, natural commit/finalization and preserved trust |
| Existing-data preservation | PENDING | Credentials/authentication IDs, QR/private identity, media, routes, roles/schema and exact source-defined changes |
| Reused unchanged component evidence | PENDING | Explicit source/input binding and older proof references; not relabelled as new 27 transactions |
| Public assets and signed update check | PENDING | Anonymous downloads/checksums; real installed Check; preserved Windows/Android feeds and Windows catalogue |

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
