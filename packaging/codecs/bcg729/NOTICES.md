# Optional locally built G.729 codec

The module is derived from `xadhoom/mod_bcg729`, revision
`4203247dee4719545005ec7ab9ea536fc83df1d8` (2025-07-30):
<https://github.com/xadhoom/mod_bcg729>.
Original contributors include Matteo Brancaleoni and the original `fsg729`
contributor identified as `<mkrivushin@yandex.ru>`. The original FreeSWITCH
copyright and MPL 1.1 source notices remain in the patched source.
`MODULE-LICENSE.txt` contains the upstream license.

OpenWeb PBX modifications dated 2026-10-08 in `buffer-safety.patch` validate
contexts, complete frames, rates and output capacities before codec writes;
correct the packet-loss concealment output length; and pass individual frame
lengths to the decoder. The module is dynamically linked to the Debian system
library instead of building or statically embedding a separate codec copy.
The build recipe retains the upstream source and the complete patch.

bcg729 is Copyright 2011-2019 Belledonne Communications, Grenoble, France, and
is provided by Debian under GPL-3-or-later. `BCG729-COPYRIGHT.txt` preserves the
Debian copyright record, including its BSD and Debian-packaging sections.
`BCG729-GPL-3.txt` contains the full GPL v3 text. The library's source is at
<https://github.com/BelledonneCommunications/bcg729>, with Debian source and
security patches at <https://sources.debian.org/src/bcg729/>.

This recipe is for a local source build. No combined codec binary is included
in OpenWeb PBX release archives. The MPL 1.1 wrapper/FreeSWITCH and GPL codec
licenses require a separate distribution-compatibility resolution before
shipping linked binaries; keeping this source recipe does not resolve that
question. A commercial library license is an upstream alternative described
in <https://github.com/BelledonneCommunications/bcg729#licensing>.
