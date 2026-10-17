# Building and installing system voices

System voice **1.0.1** replaces the complete installed English stock/default
spoken inventory with Nathaniel UK. Its source of truth is
[`catalog.json`](../../app/pbx_setup/resources/voicepacks/1.0.1/catalog.json).
The four-rate offline audio archive is built separately from Git source. No
customer recording, caller ID, South African ID number or PBX backup is sent
to the speech provider. The generator sends catalogue text only. The optional
tenant greeting command sends only the administrator-approved tenant display
name and the fixed greeting script.

Use an existing paid ElevenLabs account which supports 44.1 kHz PCM. Configure
`ELEVENLABS_API_KEY` in a private environment or a mode-0600 ignored `.env` file.
The API key must never appear in command arguments, Git, a release, screenshots
or logs. API use is needed when producing audio, not when installing or playing
the completed system voice pack.

```sh
python3 packaging/voices/voicepack.py plan
python3 packaging/voices/voicepack.py generate \
  --output /private/voice-1.0.1 --cache /private/voice-cache \
  --env-file /private/voice.env --execute
python3 packaging/voices/voicepack.py verify --pack /private/voice-1.0.1
python3 packaging/voices/voicepack.py archive \
  --pack /private/voice-1.0.1 --output /private/openwebpbx-voices-1.0.1.tar.gz
```

The generator confirms the live voice ID and British label, requires a paid
plan with sufficient included character balance, and never buys credits. It
deduplicates identical scripts and keeps a content-bound private provider cache
so a failed build can resume without regenerating successful items. An active
paid account and the normal API request charges remain the owner's
responsibility. The `--execute` flag is required to make generation requests.
Generation uses `eleven_multilingual_v2`, seed 101, stability 0.65, similarity
0.8, style 0, speed 1 and speaker boost. The model's seed is best effort,
not a promise of identical new generations.

Provider PCM is converted with FFmpeg to mono PCM WAV, normalised to -20 LUFS
with a -3 dB true-peak target. The checker verifies finite WAV headers, exact
frame/rate/channel/width measurements, non-silent audio, clipping limits and the
full file inventory. Every output is sealed by SHA-256. `pack.json` records the
voice version, catalogue digest, original synthesis binding/master digest and
each installed audio digest. A complete `pack.json` is written only after all
audio has been created. Production publication still requires independent
decoded-call/audio checks; file validation alone is not an end-to-end call test.

The tenant greeting builder produces the Call Me Back greeting with a fixed
script; it accepts a plain tenant display name, not arbitrary SSML or caller
data. Existing files cannot be overwritten by this command:

```sh
python3 packaging/voices/voicepack.py tenant-greeting \
  --tenant-name 'Fictional OpenWeb' --output /private/fictional-greeting.wav \
  --env-file /private/voice.env
```

For an archive copied from a trusted release, check its separately authenticated
SHA-256 before staging. Staging refuses links, traversal, duplicate/unknown
members, oversized entries and incomplete inventories. It changes no installed
sound files:

```sh
python3 packaging/voices/deployment.py stage \
  --archive /private/openwebpbx-voices-1.0.1.tar.gz \
  --sha256 SHA256_FROM_THE_AUTHENTICATED_RELEASE \
  --destination /private/verified-voice-1.0.1
python3 packaging/voices/deployment.py plan \
  --pack /private/verified-voice-1.0.1 \
  --sounds-root /usr/share/freeswitch/sounds
```

New Debian release builds require `--voices /private/verified-voice-1.0.1`.
The ordinary signed release manifest seals every offline WAV and all voice tools.
The fresh installer checks the entire pack and installs it after the stock
engine files, before the call engine starts. The updater adds **all 4,888 spoken
targets and the selected-version marker** to its normal deployment map before
taking the file snapshot. It pauses calls and stops services through the
existing update transaction, then installs only verified complete audio.
Its existing recovery restores original bytes, modes, owners and absent-file
states. An older installed updater receives the candidate helper during its
normal migration step; the helper augments its authenticated recovery snapshot
before changing any previously untracked spoken target. It also checks the
true pre-upgrade original prompt hashes so an older copy step cannot conceal
an administrator's custom replacement.

Unrecognised stock replacements, unexpected directories, missing stock files
and symbolic links refuse before normal activation. Customer media and music
are outside the mapping. Existing deployments are never activated by an
untracked standalone recursive copy. A failed update must use the ordinary
instance updater's private recovery snapshot. Do not apply this pack to an
unknown stock sound version or manually replace a customer's custom prompt.

The voice version is recorded at `sounds/openwebpbx/voice-pack.json` after it is
part of a successful transaction. No API credential is bundled. Independent
installations need their own private API configuration for **new tenant-name
greetings**; the complete stock pack and fixed Call Me Back prompts work offline.
The callback worker's private storage is restricted to its explicit systemd
write path and is covered by the ordinary encrypted media backup.

Windows can carry the same offline PCM pack, but its native installer/recovery
transaction has not yet been qualified for this overlay. Do not describe the
existing frozen Windows candidate as containing or accepting these voices.

Official references: [speech API and formats](https://elevenlabs.io/docs/api-reference/text-to-speech/convert),
[voice identity API](https://elevenlabs.io/docs/api-reference/voices/get),
[stock prompt source and licence](https://github.com/freeswitch/freeswitch-sounds/tree/0c9642c28de78728544f3ed988ec450cfddab9e6/en/us/callie),
[FreeSWITCH sound path/rate handling](https://developer.signalwire.com/freeswitch/media-and-codecs/audio-files/).
