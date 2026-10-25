# Building and installing system voices

System voice **1.0.2** replaces the complete installed English stock/default
spoken inventory with Keoma (South African English). Its source of truth is
[`catalog.json`](../../app/pbx_setup/resources/voicepacks/1.0.2/catalog.json).
The four-rate offline audio archive is built separately from Git source. No
customer recording, caller ID, South African ID number or PBX backup is sent
to the speech provider. The generator sends catalogue text only. The optional
tenant greeting command sends only the administrator-approved tenant display
name and the fixed greeting script.

Voice **1.0.2** is generated and sealed, with hosted activation and full Windows
release qualification tracked separately. The previous Nathaniel 1.0.1 pack
remains an authenticated upgrade origin. Do not infer activation from this
source catalogue or from an earlier release's acceptance.

Use an existing paid ElevenLabs account which supports 44.1 kHz PCM. Configure
`ELEVENLABS_API_KEY` in a private environment or a mode-0600 ignored `.env` file.
The API key must never appear in command arguments, Git, a release, screenshots
or logs. API use is needed when producing audio, not when installing or playing
the completed system voice pack.

```sh
python3 packaging/voices/voicepack.py plan
python3 packaging/voices/voicepack.py generate \
  --output /private/voice-1.0.2 --cache /private/voice-cache \
  --env-file /private/voice.env --execute
python3 packaging/voices/voicepack.py verify --pack /private/voice-1.0.2
python3 packaging/voices/voicepack.py archive \
  --pack /private/voice-1.0.2 --output /private/openwebpbx-voices-1.0.2.tar.gz
```

The generator confirms the live voice ID, exact name and South African English labels, requires a paid
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
  --archive /private/openwebpbx-voices-1.0.2.tar.gz \
  --sha256 SHA256_FROM_THE_AUTHENTICATED_RELEASE \
  --destination /private/verified-voice-1.0.2
python3 packaging/voices/deployment.py plan \
  --pack /private/verified-voice-1.0.2 \
  --sounds-root /usr/share/freeswitch/sounds
```

New Debian release builds require `--voices /private/verified-voice-1.0.2`.
The ordinary signed release manifest seals every offline WAV and all voice tools.
The fresh installer checks the entire pack and installs it after the stock
engine files, before the call engine starts. The updater adds **all 4,915 spoken
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
are outside the mapping. Do not activate existing deployments with an
untracked standalone recursive copy. A failed normal update must use the ordinary
instance updater's private recovery snapshot. Do not apply this pack to an
unknown stock sound version or manually replace a customer's custom prompt.

The voice version is recorded at `sounds/openwebpbx/voice-pack.json` after it is
part of a successful transaction. No API credential is bundled. Independent
installations need their own private API configuration for **new tenant-name
greetings**; the complete stock pack and fixed Call Me Back prompts work offline.
The callback worker's private storage is restricted to its explicit systemd
write path and is covered by the ordinary encrypted media backup.

Windows stages the same offline PCM archive from a fixed audio-only prerelease
URL and exact SHA-256. No provider key is required in CI or a published installer.
Its new native build, full installer, runtime audio and upgrade/restore gates
must qualify these exact Keoma bytes before a complete Windows release.

Old ready Call Me Back tenant-name greetings are refreshed only when their
recorded 1.0.1 hash matches the actual fixed file. A bounded three-attempt claim
prepares Keoma without holding a database row lock during provider requests.
An immutable `greeting-keoma-<sha256>.wav` is created first; a guarded transaction
selects it only if the name, version, stored hash, old file hash and claim still
match. Failed generation or commit leaves the previous ready/enabled service
and fixed audio untouched. Custom mismatches are preserved with an owner-only
retry/status action. New generation needs each instance's private provider key;
missing keys preserve active audio and display an operator message. Provider
body reads have a 90-second maximum linked deadline. On Windows the original
maintenance lease spans the entire worker tick, including network/file work.

The active clock is independently versioned **1.0.3**: nine Keoma phrases and
24 frozen Keoma number dependencies, plus the unchanged non-speech timing tick.
The complete voice pack also replaces known old speech aliases. Instrumental
music, tones, voicemail messages and customer recordings are outside synthesis.

Official references: [speech API and formats](https://elevenlabs.io/docs/api-reference/text-to-speech/convert),
[voice identity API](https://elevenlabs.io/docs/api-reference/voices/get),
[stock prompt source and licence](https://github.com/freeswitch/freeswitch-sounds/tree/0c9642c28de78728544f3ed988ec450cfddab9e6/en/us/callie),
[FreeSWITCH sound path/rate handling](https://developer.signalwire.com/freeswitch/media-and-codecs/audio-files/).
