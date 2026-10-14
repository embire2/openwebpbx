# Windows native build recipe

These helpers build sources and DLLs in dedicated work directories. They do not
install modules, change native profiles, stop services, or read PBX credentials.
No Windows native binary qualification is implied by preparing the sources.

The target engine is the official FreeSWITCH 1.11.3 x64 MSI, SHA-256
`f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d`.
The existing `FreeSwitch.dll` must have its separately reviewed exact SHA-256
recorded in the dependency lock and the resulting native manifest. Matching a
version string alone is not an ABI qualification.

## Sources and hashes

- [FreeSWITCH](https://github.com/signalwire/freeswitch/tree/ef32e205295e29f034f1453ad245ba5efb07b94a):
  `ef32e205295e29f034f1453ad245ba5efb07b94a`.
- [Sofia-SIP](https://github.com/freeswitch/sofia-sip/tree/ad36ac8f755308e8b87f98a505e83d4e408e5cc3):
  `ad36ac8f755308e8b87f98a505e83d4e408e5cc3`.
- [mod_bcg729](https://github.com/xadhoom/mod_bcg729/tree/4203247dee4719545005ec7ab9ea536fc83df1d8):
  `4203247dee4719545005ec7ab9ea536fc83df1d8`.
- [Debian bcg729 source](https://deb.debian.org/debian/pool/main/b/bcg729/):
  `1.1.1-3+deb13u1`, including all six retained source patches. The final
  `LP2LSPConversion.c` SHA-256 is
  `1baa079f18eb15e9ec355ca1b9de982100b45f16b6eb1ac79eecf8e02bf850f1`.
  This includes the upstream division-by-zero correction used by the qualified
  Debian library; building the unpatched 1.1.1 source would omit it.

The fixed source archives are:

| File | SHA-256 |
| --- | --- |
| `bcg729_1.1.1.orig.tar.gz` | `68599a850535d1b182932b3f86558ac8a76d4b899a548183b062956c5fdc916d` |
| `bcg729_1.1.1-3+deb13u1.debian.tar.xz` | `4674343d5150b5b60db633c1a8ee54590f0a1714928f77e74ee641e004dd14b6` |

The registrar patch is `restore-registration.patch`, SHA-256
`db4fa115b4323eb9c084ad0ffb946488a4a50ba5709886cd3fdc3812c0ad51f6`;
its original and patched registrar hashes are recorded in [README.md](README.md).
The codec buffer patch is
`../codecs/bcg729/buffer-safety.patch`, SHA-256
`39af6200772e1eb3373cbf8a75ba7b991ca4e102a0b2688de682e84ec66a62df`;
the patched wrapper SHA-256 is
`c2731d5cf1ea076c4d0c274cb7ed85e66a06c1e401ee0e8c065c3bf90eeb8ecc`.

## Prepare and build

Run `prepare-windows-native.py` with local Git repositories containing the exact
three source revisions, the two bcg729 archives, and a new output directory.
It exports the pinned commits, retains the original registrar and codec wrapper,
checks every archive and patch hash, applies the reviewed patches with GNU patch,
and writes a complete `source-manifest.json`. Git for Windows supplies GNU patch.
The input repositories and their working trees are not modified.

The upstream Windows project uses nine registrar C inputs and separate APR,
pthreads and static Sofia libraries. Its default dependency downloads include a
mutable Sofia branch and unhashed downloads. The build helper suppresses those
download targets. Supply independently reviewed OpenSSL/curl/zlib/pthreads/gawk
inputs and generated matching core import headers/library in the prepared
`freeswitch` tree. A dependency lock has `schema:1`, the target `core_sha256`, and
`files` mapping every dependency path relative to the prepared source root to
its SHA-256. It must include `freeswitch/x64/Release/FreeSwitch.lib`.
The dependency lock itself needs an exact reviewed SHA-256.
`windows-native-inputs.json` pins the official MSI, eight upstream Windows build
inputs and two Debian codec source archives. `windows-native-dependencies.py`
can retrieve those exact public HTTPS bytes or prepare the offline dependency
tree. It verifies each hash and preserves the upstream Windows path separators
when unpacking. `core-exports.py` inspects the verified MSI's x64 PE export
table and writes a definition that distinguishes function and data exports;
MSVC `lib.exe` derives the matching import library from that definition.

Use an x64 Visual Studio developer terminal with MSVC, Windows SDK, MSBuild and
CMake. `Build-WindowsNative.ps1` requires the prepared source manifest and its
hash, dependency lock and its hash, installed engine directory and exact core
hash, plus new build/registrar/local-codec output directories. The default toolset is v143 and SDK
10.0.26100.0; explicitly record the toolset/SDK actually used on the qualified
runner. It builds private APR/pthreads/Sofia libraries, the patched registrar,
the shared bcg729 library and wrapper, and runs the existing native codec
callback test. It never rebuilds or replaces the installed core.

Registrar outputs use the native package contract:

- `mod/mod_sofia.dll`
- `native-manifest.json`, with exact upstream/patch/source/core/MSI/input hashes
  and complete DLL hashes. Its `native_runtime_qualified` remains false until
  independent Windows ABI, registration and media tests pass.

The separate local codec directory contains `mod/mod_bcg729.dll`,
`libbcg729.dll` and `local-codec-manifest.json`. These are local build/test
outputs, excluded from the registrar artifact and the hosted job's upload
allowlist. The workflow in `.github/workflows/windows-engine.yml` publishes
the registrar, credential-free build/callback evidence and the verified public
`codec-source` bundle. `extract-windows-core.py` opens the exact MSI database
read-only, reads its File/Component tables and extracts cabinet data with
7-Zip; it never executes installer actions. Its reviewed core/APR hashes are
checked again after extraction. It never substitutes the MSI's stock registrar
for the patched source build.

`bundle-windows-native.py` copies only the prepared manifest's verified public
members into `codec-source/source`, preserving all 6,214 original prepared
inputs and `source-manifest.json`. Built dependency libraries, private build
outputs and combined codec DLLs are outside that allowlist. The bundled
`core-exports.py` and `codec-source-manifest.json` pin the exact helper, source
manifest, MSI core and APR hashes for the installer local source recipe.

Preserve the source manifest, dependency lock, build-tool versions, PE import
reports and callback result. Actual Windows qualification must include the
same original/canonical identity, collision, response/Contact, refresh/query/
unregister/multiple-contact, cache/revocation and copied-Call-ID cases recorded
in the registrar README, plus genuine two-way G.729 transcoding, hold/resume
and the recoverable old-helper installation path. A successful compiler exit
does not establish these results.

## Licences and distribution boundary

Retain FreeSWITCH and wrapper MPL 1.1 notices, Sofia-SIP LGPL notices, the complete
bcg729 GPL licence, Debian copyright/source patches and all Windows dependency
source/licences. The codec sources and copies of their licences are retained
by the preparation helper. The existing [codec notice](../codecs/bcg729/NOTICES.md)
limits this codec integration to a local source build pending resolution of
linked-binary distribution compatibility. The helper preserves that boundary
as `codec_distribution_status:local-source-build-only`; it does not authorize
publishing a combined codec binary. The [upstream bcg729 licence](https://github.com/BelledonneCommunications/bcg729#licensing)
also describes a separate commercial licensing option.
