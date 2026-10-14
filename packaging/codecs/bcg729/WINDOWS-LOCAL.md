# Local Windows source codec

`build-windows-local.py` compiles the corrected G.729 library and retained MPL
wrapper locally. It does not install modules, change autoload settings, control
services or initialize the PBX. Source preparation and input hashes are in
`../../freeswitch/WINDOWS-NATIVE.md`.

The installer integration supplies an ordinary exact source bundle and its
manifest hash, the verified FreeSWITCH1.11.3 core/APR DLL hashes, the reviewed
core-export helper, and new private build/output/cache directories outside the
web and installed-engine trees. An x64 elevated Windows process is required.
Those work directories receive administrator/SYSTEM ACLs; the state parent
is not made writable by the web application.

The helper downloads the fixed
[LLVM-MinGW20261006 UCRT x64 compiler](https://github.com/mstorsjo/llvm-mingw/releases/tag/20261006),
190,836,485 bytes, SHA-256
`317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a`.
`windows-compiler.json` retains its exact source revision and upstream URL.
The complete unmodified compiler archive and its licences remain in the
protected cache/work directory. It supplies Clang/LLD and mingw-w64 headers;
no Visual Studio or proprietary Windows SDK headers are required for this
C-only codec build. The library remains a separate dynamically linked DLL.

The pinned FreeSWITCH headers select Windows networking/integer setup and RTP
packing through MSVC-specific conditions. The helper checks three exact
upstream header hashes, copies the headers into its private build directory,
and extends only those conditions to the MinGW Windows target. Original
prepared inputs stay unchanged; the output manifest records each original
and derived header hash. No structure members or core/module source change.

[Upstream explains](https://github.com/mstorsjo/llvm-mingw/tree/e1878a59f8bf3e1a73afe28f1b83168b1d029ed8#known-issues)
that mixing DLLs requires every allocator to free its own CRT resources. The
helper derives a DATA-aware core import library from the exact verified MSI
core and tests the boundary explicitly: genuine codec encode/decode/VAD/PLC/
buffer checks, exact addresses of the two imported core DATA objects, and
1,000 codec allocation/destruction cycles using a real MSI APR pool. The codec
DLL closes its own encoder/decoder objects; the original APR DLL frees its
pool and wrapper context. No file handle or C++ object crosses this boundary.

Only after both actual executables pass does the helper write
`local-codec-manifest.json` with source/compiler/core/APR/helper hashes and DLL
hashes. It retains `native_rtp_qualified:false`; source preparation or callback
tests alone do not prove SIP/media/native-engine integration. Hosted Windows
proof remains required before the installer may rely on this recipe.

The outputs are local `mod/mod_bcg729.dll`, `libbcg729.dll`, manifest and licence
copies. They remain outside the redistributable registrar artifact and hosted
upload allowlist. The existing [NOTICES.md](NOTICES.md) distribution boundary
is unchanged: no combined codec DLL is publicly shipped. The public package
may retain the source recipe, pins and licences; local installation compiles
from the verified sources.
