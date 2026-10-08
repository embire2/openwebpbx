# G.729 transcoding on Debian

The stock FreeSWITCH `mod_g729` in the 1.0.2 engine supports passthrough. It
cannot decode a carrier's G.729 audio into G.711 for a phone, recording, queue
or IVR. A carrier can answer with G.729 and then encounter a decoder error
even when the SIP codec offer is correct.

An optional local source recipe builds the reviewed `mod_bcg729` wrapper
against Debian 13's maintained `libbcg729` package. It preserves restored
G.729 preferences and supplies actual encoding and decoding. This recipe is
qualified for the current Debian 13 amd64/FreeSWITCH 1.11.3 build. Windows,
additional architectures and complete carrier interoperability remain open.
Published 1.0.2 archives do not include this module or its dependency.

From a complete source checkout, build on the target host:

```sh
sudo bash packaging/codecs/bcg729/build-local.sh
```

The recipe installs build dependencies, obtains the pinned upstream source,
applies the buffer-safety patch, links to the system codec library, and runs
AddressSanitizer and UndefinedBehaviorSanitizer checks. It records the source,
library and engine versions and SHA-256 digests in
`/usr/local/src/openwebpbx-bcg729/build-manifest.txt`. A repeat build exports
the same pinned source before applying the patch again. To use existing
dependencies and a different isolated build directory:

```sh
bash packaging/codecs/bcg729/build-local.sh --no-dependencies /absolute/build-directory
```

Building leaves the running engine and its module configuration untouched.
During a controlled maintenance window, confirm zero active channels, preserve
the current module autoload configuration, copy the built module into the
engine's native module directory, unload `mod_g729` and load `mod_bcg729`.
Only one implementation should provide G.729. Validate a local SIP fixture
that offers G.711 and selects G.729 on its provider leg, with two-way audio,
recording and IVR operation, before qualifying a real carrier. Then replace
the `mod_g729` autoload entry with `mod_bcg729` so a restart retains the codec.
To roll back, reverse those autoload entries and unload the new module/load
the original one with zero active channels. The recipe retains the original
stock module.

The isolated callback checks passed on 2026-10-08: 17 checks cover a one-second
440 Hz signal in 20 ms packets, twelve-frame packets, actual VAD SID decoding,
mixed speech/SID packets, packet-loss concealment, insufficient output buffers,
truncated input and repeated destruction. A clean pinned-source build and a
repeat build both passed AddressSanitizer and UndefinedBehaviorSanitizer checks.

The live Debian engine loaded `/usr/lib/freeswitch/mod/mod_bcg729.so` on
2026-10-08 after a zero-active-channel check. The original `mod_g729.so` is
retained and the previous autoload configuration is backed up privately.
`modules.conf.xml` now autoloads `mod_bcg729`.

A controlled Vox pilot registered successfully and received SIP 200 answer.
The carrier selected G.729 payload 18 while the test phone used PCMU payload 0;
the bridge stayed connected for 16 seconds. The phone fixture sent 765 RTP
packets and received 797, with no G.729 decoder errors after the module was
loaded. This verifies the deployed carrier-to-phone codec conversion flow.
User confirmation of audible speech, incoming carrier calls, and broader
provider, recording and IVR qualification remain pending. All 19 customer
gateways were switched off again after the pilot and no active calls remained.

Admin readiness now warns when configured G.729 trunks lack the audio support
needed for decoding/transcoding. The related 23 readiness checks passed.

Keep the [source and license notices](../packaging/codecs/bcg729/NOTICES.md)
with this optional recipe and any local build. The wrapper is MPL 1.1 and the
system library is GPL-3-or-later. Linked binary release distribution remains
unqualified until their compatibility is resolved. Neither this recipe nor
local codec tests establish full 3CX feature parity.
