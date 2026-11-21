# Windows Server 1.0.29 qualification

The complete installer targets Windows Server 2025 x64 with Desktop Experience.
A clean installation starts with this one ZIP and an empty PBX workspace. The
installer provides the native server and manager, the call engine, the web
application, the local PostgreSQL setup, the independent updater and system
prompts. [Installation guide](installing-windows-1.0.29.md)

## Package identity

- Source `3f89c926ed68dcf3a347c8a2a3db208df8a7fe15`.
- Full installer `openwebpbx-1.0.29-windows-x64.zip`, 643,902,920 bytes,
  SHA-256 `f3683b91832a1ff3d62c12174c0c1684979868313f97aa2850f9771c06bd2608`.
- Source archive `openwebpbx-1.0.29-windows-source.tar.gz`, 50,763,852 bytes,
  SHA-256 `8049c1ea5fa1726e1115d43f3762ab2bde7ab5d1b1f2e2272ed7bbcc34011ef3`.
- An independent streaming check verified all 19,356 sealed payloads,
  all 4,915 system WAVs and the installer contract. The contract identifies a
  full package with `previous_installation_required: false`.

## Windows native build and regressions

The native components built from `384e8b81fbdf90f6a1348aca91824c1afcda5b85`
using .NET SDK 10.0.401 on Windows Server 2025. The final correction changes
only the installer script and setup guide. All 90 native source inputs and all 1,111 files
in the build's checksum inventory matched. The Core, manager and updater assemblies report 1.0.29.0. The manager
opened a responsive **OpenWeb PBX 1.0.29** window when launched outside its
application folder. Native protocol, standalone preflight, updater with real
isolated PostgreSQL, and desktop update notice and postponement checks passed.
[Exact-source native workflow](https://github.com/embire2/openwebpbx/actions/runs/44947113433)

The Windows package includes the inspected 3CX V20 Update 10 build while
retaining Update 9, clearer upload errors, First Calls blockers, scoped API
references and the clearer Software Updates page. The 66 shared parser checks
and the scoped API reference and setup controls passed. Existing Windows
configuration already uses private disk-backed PHP upload storage and the voice
installer skips matching system audio. Full Windows restores from the private
3CX archives and real carrier routing require separate qualification.

## Fresh-install correction

The first clean run verified the full archive, then stopped while granting
IIS access to the FreeSWITCH database directory. The MSI had not yet created
that directory. The installer now creates and validates the ordinary directory
before granting the same IIS application pool access. The corrected package
retains 19,355 unchanged ZIP members with their exact compressed bytes and
metadata. The updated installer script and its checksum in the release
manifest are the two changed ZIP members.
[Initial run](https://github.com/embire2/openwebpbx/actions/runs/44949909459)

A second clean case reached the existing restricted-write ACL check for
installer recovery files. Its drive-root extraction was outside the protected
package working directory. The successful retry used an administrator-owned
package folder. The release guide now directs customers to extract into their
Windows administrator profile. [Extraction-permissions case](https://github.com/embire2/openwebpbx/actions/runs/44951560529)

## Standalone installation and release equivalence

A clean Windows Server 2025 Desktop Experience runner proved the absence of
previous PBX files, registry state and services before and after the ordinary
read-only package check. It downloaded and verified the full runtime package
SHA-256
`ec0e2c373df36d9370e1dc658b32f30f29c12b6e4a29b7081916dbb8b61b5184`
and installed it in 613.866 seconds, including archive
extraction and verification. The installer provisioned the ordinary FreeSWITCH
database directory and initialized this instance's PostgreSQL 18 database.

FreeSWITCH, the Core, the independent updater and PostgreSQL were running.
The native calling-engine SIP/RTP readiness check and private PHP upload
path passed. HTTPS passed normal local certificate and hostname validation,
and the administrator signed in and opened Software Updates for 1.0.29.
[Clean-install run](https://github.com/embire2/openwebpbx/actions/runs/44952796084)

The release ZIP changes the installation guide and its manifest entry from
the directly installed runtime archive. Independent validation verified all
19,356 payloads in both archives and compared the exact compressed bytes and
metadata of all 19,355 unchanged ZIP members. Every installer and runtime
component is identical.

The runner had IIS and Visual C++ preinstalled. The supported local-certificate
recovery setup reached **Registration required**. The separate native build
verified the manager window. Managed tenant DNS and enrollment, answered
calls and an existing Windows signed upgrade were outside this qualification.
The Windows updater feed continues to offer 1.0.27; the standalone 1.0.29 ZIP
is for fresh installations.

## Public release

Published on 2026-11-21. All four anonymous GitHub downloads matched the
verified lengths and SHA-256 checksums. The release is specific to fresh Windows
Server installations. [Public assets](https://github.com/embire2/openwebpbx/releases/tag/windows-v1.0.29)
