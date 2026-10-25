# Keoma system voice 1.0.2

This complete English system pack uses the authorized ElevenLabs professional
voice `i8SlcaZfyeP1st7wHsjM`, **Keoma**, with the provider's South African English
labels (`en-ZA`). It replaces default system speech, including voicemail menus
and default greetings, IVRs, conferences, queues, callbacks, recovery prompts,
numbers and spelling. Existing compatibility paths such as `en/us/callie` stay
the same; their new spoken voice is Keoma.

The sealed offline archive contains **4,915 spoken files** from **1,241 script
entries**, deduplicated to **1,217 final synthesis bindings**. Stock English
speech retains 8, 16, 32 and 48 kHz mono signed 16-bit PCM variants. Fixed
OpenWeb/Call Me Back prompts, legacy system aliases and talking-clock speech
are included. The active talking clock has its own version, **1.0.3**, and an
unchanged locally produced non-speech timing tick.

[The catalogue](catalog.json) lists every transcript, destination, provider
identity/settings and authenticated old stock/system hash. [Release metadata](release.json)
seals the archive and complete manifest. New deployments install only a verified
complete pack. Upgrades accept old Nathaniel bytes only through the exact
previous manifest identity and known target hashes. Unknown/custom replacements
refuse before activation. User recordings, uploaded/custom greetings, voicemail
messages, instrumental hold music and tones are preserved. Directory location
alone does not establish whether a recording is custom or system-owned.

Ready older Call Me Back tenant-name caches need the instance's private
ElevenLabs configuration. A bounded refresh verifies their saved hash, preserves
the active audio and enabled state during generation, and selects an immutable
Keoma file through a guarded database commit. Custom or changed audio is
preserved. Missing keys/provider errors produce an operator status; no deployment
key is borrowed or bundled. Independent providers may charge for generation.
The fixed system archive works offline without an API key.

The original stock transcript copyright and CC BY 3.0 terms are retained in
[LICENSE-FreeSWITCH.txt](LICENSE-FreeSWITCH.txt). The replacement synthetic
performance was generated using the owner's authorized paid ElevenLabs account;
no voice model/weights or endorsement are distributed. Further generation is
subject to the [ElevenLabs terms](https://elevenlabs.io/terms-of-use) and
[Voice Library Addendum](https://elevenlabs.io/vla).

Audio generation and strict inventory validation are complete. This source
record does not claim live hosted activation, physical-phone acceptance or
full Windows installer/update qualification; those require their own exact
runtime and release receipts. See [the voice guide](../../../../../packaging/voices/README.md).
