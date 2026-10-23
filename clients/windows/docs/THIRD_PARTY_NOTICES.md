# Third-party notices and corresponding source — Windows Phone 1.0.0

**Release status: incomplete source/licence closure; do not treat this file as permission to distribute an accepted binary.** This records verified inputs and the work needed for the final Windows client. It does not license unrelated server code or declare that every SDK component is shipped by the app.

## Client and Liblinphone licence

OpenWebPBX's first-party Windows Phone client code in this directory is offered under **GNU Affero General Public License version3 or, at your option, any later version**, except files/components with their own notices. The full unmodified AGPLv3 text is in [../LICENSE](../LICENSE). Keep the original Belledonne notices in the generated binding and native sources. The repository root licence remains applicable to its existing scope; adding this client licence does not relicense the PBX/server tree or Microsoft's runtimes.

The official C# binding's header says AGPLv3-or-later and identifies Copyright2010–2022 Belledonne Communications SARL. [Liblinphone's licensing page](https://www.linphone.org/en/liblinphone-voip-sdk/#licensing-model) offers AGPLv3 or a separately obtained commercial licence. No commercial licence is assumed here. The free/open-source route is the one documented for this client.

## Exact SDK evidence

| Input observed in probe39957178477 | Verified identity |
|---|---|
| Official Windows x64 SDK | `linphone-sdk-win64-5.5.23.zip`,315,960,147bytes |
| SDK SHA256 | `9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297` |
| Official C# binding | 2,317,396bytes; SHA256`a99c5197be469d58812afc33a2adb104505134b9a03ac7654d11e4e4341d3a15`; version constant5.5.23 |
| Source release tag | [5.5.23 in the official mirror](https://github.com/BelledonneCommunications/linphone-sdk/tree/5.5.23) |
| Annotated tag object | `699ca639ea2752efdda23bd949eb1f1eb8310f1b` |
| Tag's source commit | `348e8de32fb2ac56b7b0a7167968fc1ac707f7b2` |

The [official Windows download location](https://download.linphone.org/releases/windows/sdk/) and mirror establish the candidate version/source graph. They do **not** yet attest which exact build configuration, patches, toolchain, linked third-party objects and source archive produced this binary ZIP. That mapping remains a blocker. A single SDK version is not proof that every bundled library has the same semantic version.

The ZIP's generic `share/doc/linphone-sdk/LICENSE.md` is actually **libjpeg-turbo's licence notice**. It is not an umbrella Liblinphone licence. Three exact licence members were exported by the bounded probe:

| SDK member | Original bytes / SHA256 | Meaning |
|---|---|---|
| `win64/include/OpenGL/LICENSE` | 1,784 / `0cf6dfbb5eaf75965f42ea7a95631a48120433e1c6782ebfef622cd265b6508c` | ANGLE/Microsoft BSD notice, reproduced below |
| `win64/share/doc/linphone-sdk/LICENSE.md` | 5,755 / `d18720d8abf40123d52891e8a88df2c37d713bc73c7662ced0aee5e59401c084` | libjpeg-turbo IJG/BSD guidance and BSD text, reproduced below |
| `win64/share/doc/ortp-5.5.0/LICENSE.txt` | 35,184 / `e0eedba615d5cd1b986afb6c5b3a4b1ae33713e7e9dc74d19daec5e3221f9d2e` | Full AGPLv3 text; content equals ../LICENSE after CRLF→LF conversion |

The copied [client LICENSE](../LICENSE) is the unmodified upstream AGPLv3 text,34,523bytes/SHA256`0d96a4ff68ad6d4b6f1f30f713b18d5184912ba8dd389f86aa7710db079abcb0`. The oRTP directory label5.5.0 is an observed path, not a claimed version for all SDK libraries. Three discovered licence files do not prove the complete third-party notice inventory.

## Bundled component inventory and unresolved obligations

The SDK inventory contains Liblinphone, BCToolbox, BelCard, Belle-SIP, BelR, BZRTP, LIME, Mediastreamer2 and oRTP DLLs; their core sources are present in the release's merged source tree. Other observed DLLs/import/static libraries include Mbed TLS/crypto/x509, Decaf, Opus, Speex/SpeexDSP, GSM, BroadVoice16, libSRTP2, libxml2, libjpeg/TurboJPEG, JSONcpp, SOCI/SQLite, Xerces-C, libyuv, zlib, ZXing, HIDAPI, AOM, libvpx and RNNoise. Native WASAPI/WebRTC/OpenH264 plugins and test-library files are also present.

This is **SDK membership**, not the final app's shipped/loaded library list. Imports alone cannot identify statically linked code. Release engineering must collect the final DLL/plugin whitelist, transitive dependencies and static-link/build metadata, then match every included component to its exact licence, copyright and source revision. Do not assume a `.dll` filename is a version or omit statically linked notices. Exclude unnecessary SDK test executables, tester DLLs, headers and import libraries from the client package.

The exact upstream release has31 submodule pins. The following are source-graph candidates, not a claim that each optional component is active in the binary:

| Source path | Exact commit |
|---|---|
| `bcg729` | `8bec1e5fc072f3669e435edd137eb3da6da2eef7` |
| `bcmatroska2` | `ca080c1689a3bfebe6b71c69444b94b0dba8e54a` |
| `belle-sip/tester/cpp-httplib` | `a2ed0d11c134b6c23da275103b5183b423cea8a8` |
| `external/aom` | `65ad4cd63cbe7f10eaa4b4af7f55fd540617516a` |
| `external/bv16-floatingpoint` | `c4a341a3277e8adcc42427c4fd80a457fe934f2a` |
| `external/codec2` | `164447c2fcb4ded07cfe7cee406f9c5052629536` |
| `external/dav1d` | `1fd0bab43674eef68eb8427b543bb8a5e4271f9f` |
| `external/decaf` | `e5cc6240690d3ffdfcbdb1e4e851954b789cd5d9` |
| `external/gsm` | `ff67768db9e49fc749920422ea4061b7f8f01b3f` |
| `external/hidapi` | `d6b2a974608dec3b76fb1e36c189f22b9cf3650c` |
| `external/jsoncpp` | `dadce78005ba1147c3f840167123d66e76e9707f` |
| `external/libjpeg-turbo` | `91f8025a3071d6cec2c41265a038f47fcd28f092` |
| `external/liboqs` | `e219b1a679254c0eef9e3d9b224d0bb6555d474a` |
| `external/libvpx` | `5a4dda49fda0f6226173c27b93659c953f094fe0` |
| `external/libxml2` | `d6131eb375dd507006ed4d3541915cb1b3da5aa2` |
| `external/libyuv` | `a3a7937e762a7ce33b79f4b05f2ad44093e7ba1c` |
| `external/mbedtls` | `7cbc810e5645e16206555343deb2e9263c0f3750` |
| `external/opencore-amr` | `084d2a08e2bce13a27cb33f4b371030dab8c2460` |
| `external/openh264` | `5ac757be463248e36fcde4c5417d4ac6e04a9051` |
| `external/openldap` | `c4d91453d12497e4db66e1bad9056ad55ac12adb` |
| `external/opus` | `f86ad14bbbe9644efee876ebb73a5931b25c4627` |
| `external/rnnoise` | `d107462bff3bcda43d8115487959d1e66da905dc` |
| `external/soci` | `3a9c79088212941d0175c22cd2da8fe1bdd639df` |
| `external/speex` | `52f01d5a680efd0433df5e130997f01e1976939a` |
| `external/sqlite3` | `ceb88c26e1bde0ab02b09d09cbb481d9baeeefc4` |
| `external/srtp` | `930ec54bf0c5b63b7e319d8551028af897127f8c` |
| `external/vo-amrwbenc` | `986a52ced2a02511a3c250f101df18e7f7d36dde` |
| `external/xerces-c` | `372c0114568b9325c0bb3af93ad5f2994429233e` |
| `external/zlib` | `446edd4aeeaec542ce2b3ef78286d2c1088c93ea` |
| `external/zxing-cpp` | `722123ad0cadee0e4c313f80eac5162a9f8d7d73` |
| `msoboe/oboe` | `5975ab04b02861dc126f3c8fd687321520cd8ae4` |

The source URLs for these paths are in the release's [pinned .gitmodules](https://github.com/BelledonneCommunications/linphone-sdk/blob/348e8de32fb2ac56b7b0a7167968fc1ac707f7b2/.gitmodules). Preserve each recursive dependency, including nested repositories, when building a source bundle. The [pinned build presets](https://github.com/BelledonneCommunications/linphone-sdk/blob/348e8de32fb2ac56b7b0a7167968fc1ac707f7b2/CMakePresets.json) distinguish desktop `windows-sdk` from `windows-store-sdk`; exact final options are still needed. No full SDK/source archive was downloaded for this documentation task.

Microsoft.WindowsAppSDK, Windows build tools, .NET runtime and other NuGet packages also need their **resolved** licence/redistribution/third-party notices. A repository's MIT label must not be assumed to cover Windows itself or every redistributable. Preserve the actual package licence metadata and applicable runtime notices from the final build. Patented/optional codecs need their own verified distribution basis; the mere presence of an OpenH264 plugin or import library does not prove its runtime binary or rights have been supplied. No codec patent licence or commercial grant is asserted here.

## Corresponding-source release packet — still required

For every exact Store or direct binary, publish an equally versioned, independently hashed source/build asset with access alongside that binary. The AGPL's [Corresponding Source and object-code terms](https://www.gnu.org/licenses/agpl-3.0.html) require more than pointing to an unrelated moving branch. Preserve all applicable licence rights and any required installation information; do not impose conflicting additional restrictions through app or distribution terms.

The release packet is not complete until it contains:

1. Exact OpenWebPBX Windows client source commit, generated C# binding, local modifications and all first-party build/packaging/update scripts. Include the actual project files, dependency locks, resources and instructions needed to build the corresponding release.
2. Matching Linphone SDK source tree, all required recursive submodule contents, local/vendor patches, configuration presets/cache/options, generator/binding inputs, compiler/toolchain and dependency versions. A plain `git archive` of the superproject excludes submodule contents and is insufficient.
3. Every included library's licence and copyright text, including required IJG documentation, the complete BSD/zlib/Apache notices where applicable, and relevant source/build materials. Complete this using the actual shipped/static-linked inventory, not assumptions from the generic SDK notice.
4. A machine-readable source/component/hash manifest mapping the binary ZIP/MSIX and every SDK/runtime dependency to its source/build/notice materials; original input/output hashes and exact build commands; no private signing keys, passwords, customer data or CI tokens.
5. A clean-runner rebuild/install/launch and calling/device test record. If the vendor binary's exact source/build mapping cannot be established, build a new SDK from an explicitly pinned complete tree and qualify that new binary; do not relabel the existing ZIP as reproduced.
6. A public source download that is actually available with the binary, plus an in-app licence/source route, and retained versioned access. A project link, unexecuted clone command or tag name alone is not the completed source delivery.

No source asset, SBOM, final native dependency closure, Store-term compatibility approval or reproducible release has been produced by these notes. Do not submit/publish the binary while those blockers are represented as complete.

## ANGLE/OpenGL notice

Original notice text below, with line endings normalised only:

```text
// Copyright (C) 2002-2013 The ANGLE Project Authors. 
// Portions Copyright (C) Microsoft Corporation.
//
// BSD License
//
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
//     Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
//
//     Redistributions in binary form must reproduce the above 
//     copyright notice, this list of conditions and the following
//     disclaimer in the documentation and/or other materials provided
//     with the distribution.
//
//     Neither the name of TransGaming Inc., Google Inc., 3DLabs Inc.
//     Ltd., Microsoft Corporation, nor the names of their contributors
//     may be used to endorse or promote products derived from this
//     software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
// COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
// LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
// ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

```

## libjpeg-turbo notice

This software is based in part on the work of the Independent JPEG Group.

The original bundled notice follows, with line endings normalised only. Its referenced IJG README must also accompany the final applicable distribution; the current SDK evidence does not establish that this requirement is satisfied.

```text
libjpeg-turbo Licenses
======================

libjpeg-turbo is covered by two compatible BSD-style open source licenses:

- The IJG (Independent JPEG Group) License, which is listed in
  [README.ijg](README.ijg)

  This license applies to the libjpeg API library and associated programs,
  including any code inherited from libjpeg and any modifications to that
  code.  Note that the libjpeg-turbo SIMD source code bears the
  [zlib License](https://opensource.org/licenses/Zlib), but in the context of
  the overall libjpeg API library, the terms of the zlib License are subsumed
  by the terms of the IJG License.

- The Modified (3-clause) BSD License, which is listed below

  This license applies to the TurboJPEG API library and associated programs, as
  well as the build system.  Note that the TurboJPEG API library wraps the
  libjpeg API library, so in the context of the overall TurboJPEG API library,
  both the terms of the IJG License and the terms of the Modified (3-clause)
  BSD License apply.


Complying with the libjpeg-turbo Licenses
=========================================

This section provides a roll-up of the libjpeg-turbo licensing terms, to the
best of our understanding.  This is not a license in and of itself.  It is
intended solely for clarification.

1.  If you are distributing a modified version of the libjpeg-turbo source,
    then:

    1.  You cannot alter or remove any existing copyright or license notices
        from the source.

        **Origin**
        - Clause 1 of the IJG License
        - Clause 1 of the Modified BSD License
        - Clauses 1 and 3 of the zlib License

    2.  You must add your own copyright notice to the header of each source
        file you modified, so others can tell that you modified that file.  (If
        there is not an existing copyright header in that file, then you can
        simply add a notice stating that you modified the file.)

        **Origin**
        - Clause 1 of the IJG License
        - Clause 2 of the zlib License

    3.  You must include the IJG README file, and you must not alter any of the
        copyright or license text in that file.

        **Origin**
        - Clause 1 of the IJG License

2.  If you are distributing only libjpeg-turbo binaries without the source, or
    if you are distributing an application that statically links with
    libjpeg-turbo, then:

    1.  Your product documentation must include a message stating:

        This software is based in part on the work of the Independent JPEG
        Group.

        **Origin**
        - Clause 2 of the IJG license

    2.  If your binary distribution includes or uses the TurboJPEG API, then
        your product documentation must include the text of the Modified BSD
        License (see below.)

        **Origin**
        - Clause 2 of the Modified BSD License

3.  You cannot use the name of the IJG or The libjpeg-turbo Project or the
    contributors thereof in advertising, publicity, etc.

    **Origin**
    - IJG License
    - Clause 3 of the Modified BSD License

4.  The IJG and The libjpeg-turbo Project do not warrant libjpeg-turbo to be
    free of defects, nor do we accept any liability for undesirable
    consequences resulting from your use of the software.

    **Origin**
    - IJG License
    - Modified BSD License
    - zlib License


The Modified (3-clause) BSD License
===================================

Copyright (C)2009-2023 D. R. Commander.  All Rights Reserved.<br>
Copyright (C)2015 Viktor Szathmáry.  All Rights Reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- Neither the name of the libjpeg-turbo Project nor the names of its
  contributors may be used to endorse or promote products derived from this
  software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS",
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.


Why Two Licenses?
=================

The zlib License could have been used instead of the Modified (3-clause) BSD
License, and since the IJG License effectively subsumes the distribution
conditions of the zlib License, this would have effectively placed
libjpeg-turbo binary distributions under the IJG License.  However, the IJG
License specifically refers to the Independent JPEG Group and does not extend
attribution and endorsement protections to other entities.  Thus, it was
desirable to choose a license that granted us the same protections for new code
that were granted to the IJG for code derived from their software.

```
