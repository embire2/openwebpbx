# Nathaniel UK system voice — 1.0.1

The system voice pack has its own version, independent of the PBX and phone app.
It uses ElevenLabs voice `7S3KNdLDL7aRgBVRQb1z`, **Nathaniel — Deep, Rich and Mature**,
with the provider's British / `en-GB` voice labels. The owner's saved voice has
the display alias “Nathaniel - WrightFamily Weather”; both names refer to the
same voice ID. No cloned voice or voice-model weights are distributed.

`catalog.json` is the complete, reviewable script and destination inventory:

| Spoken material | Scripts | Installed WAV files |
| --- | ---: | ---: |
| Existing English FreeSWITCH stock prompts | 1,219 | 4,876 |
| Existing OpenWeb queue callback / wake-up prompts | 4 | 4 |
| New Call Me Back fixed prompts | 8 | 8 |
| **Total** | **1,231** | **4,888** |

Every stock script has mono, signed 16-bit PCM variants at **8, 16, 32 and
48 kHz**. Existing OpenWeb and Call Me Back files use 8 kHz. The stock categories
include voicemail, IVR menus, conferences, directories, numbers and ordinals,
letters, phonetic spelling, time, currency, security announcements and the full
512-word base256 dictionary. The `en/us/callie` destination spelling is retained
for compatibility with existing phone menus and relative sound paths; the
spoken voice in those files is Nathaniel.

The inventory was obtained from the installed English stock pack **1.0.53**.
Stock speech was transcribed to preserve complete instructions and keypad
choices, then recognition errors were corrected. Original numbered fragments
remain fragments so the call engine can compose counts and menus. Old insulting
demo phrases, misleading shared-password advice and obsolete promotional lines
are replaced with professional wording in the catalogue. Music, ring/busy
tones, voicemail messages, personal greetings, tenant recordings and restored
customer prompts are excluded. No other spoken language is installed in the
audited default tree; this is an English pack, not a claim of multilingual
voice qualification.

The original stock copyright and CC BY 3.0 terms are retained in
`LICENSE-FreeSWITCH.txt`. The replacement performance is synthetic Nathaniel
speech generated through ElevenLabs on the owner's paid account. It does not
claim endorsement by ElevenLabs, the voice performer, FreeSWITCH or its
contributors. Voice availability and future generation remain subject to the
[ElevenLabs terms](https://elevenlabs.io/terms-of-use) and
[Voice Library Addendum](https://elevenlabs.io/vla).
Generated audio can be used offline; an API key is not included in a PBX release.

See [the generation and deployment guide](../../../../../packaging/voices/README.md)
for verification, preservation and recovery details. A catalogue in source does
not by itself mean that a generated pack has been installed or released.
