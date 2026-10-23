# Native Windows client media qualification

This is a candidate lab, not a release or a completed calling test. Its pure
decoder/consumer controls and cross-platform C# compilation do not qualify
Windows media, physical devices, the ordinary production binary, or Store approval.

Run `tools/Test-ClientMedia.ps1` only in a **separate disposable GitHub-hosted
Windows job**, with the clean source checked out at its explicit `SourceCommit`.
It refuses an installed `C:\OpenWebPBX` or `ProgramData\OpenWebPBX`. It accepts
existing runner-temporary files and does not download inputs, install the MSI,
start services, use PostgreSQL/IIS, add firewall rules or import certificates.
The CI job must supply .NET SDK10.0.401, Python, hosted 7-Zip and these original
previously authenticated component inputs:

| Input | Bytes | SHA256 |
| --- | ---: | --- |
| Official Linphone5.5.23 Windows SDK ZIP |315960147|`9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297`|
| Official FreeSWITCH1.11.3 x64 MSI |168300544|`f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d`|
| Accepted patched registrar engine ZIP, run39823852979 |39161015|`3d4091bd972c1ea82ff9b6899c091dbeebf66416d6d76475add523ebe10a7542`|

```powershell
./clients/windows/tools/Test-ClientMedia.ps1 `
  -SdkZip "$env:RUNNER_TEMP\linphone-sdk.zip" `
  -CoreMsi "$env:RUNNER_TEMP\freeswitch.msi" `
  -EngineZip "$env:RUNNER_TEMP\engine.original.zip" `
  -SourceCommit $clientCommit `
  -Report "$env:RUNNER_TEMP\client-media-qualification.json"
```

The accepted engine is a component input; it is not a complete Windows PBX
release acceptance. The ZIP's exact `mod_sofia.dll` and source manifest are
verified, then overlaid on read-only MSI-table/cabinet extraction. The different
pthread experiment artifact must not be used. `extract_media_engine.py` extends
the exact hash-pinned repository MSI reader only to select the console and
required media modules. No installer actions execute. The original source
archive includes `codec-source/source/freeswitch/src/switch_pcm.c`, whose built-in
`CORE_PCM_MODULE` registers PCMU and PCMA; the loader preloads that module. Actual
runtime `show codecs as json` must independently expose both interfaces before
calls. The same archive's `switch_vpx.c` and loader define and preload
`CORE_VPX_MODULE`; VP8 is also built into the core, with no external `mod_vpx.dll`.
The lab requires exactly one actual `VP8 Video` codec under `CORE_VPX_MODULE`
before calls. The decoded video thresholds below remain independent requirements.
No external `mod_g711` is assumed.

The actual `NativePhone` class is referenced by a managed test assembly built
with `PhoneMediaFixture=true`. Engine-owned `PHONE_MEDIA_FIXTURE` seams are absent
from the ordinary production build. They add private file input/output, an
in-memory fixture CA, a static test picture, loopback bind configuration and
closed measurements. The same actual calling methods and SDK DLLs are used.
Certificate-chain and hostname validation and mandatory SDES SRTP stay enabled.
Wrong-CA and wrong-hostname registrations must explicitly fail, followed by
successful registrations with the same invented account and correct server.

The console PBX has three invented users8101–8103, a random `.invalid` realm,
loopback SIP/TLS/ESL and no external routes or providers. All synthetic telephone
numbers are restricted to those three. Owned TCP/UDP bindings are sampled during
execution; this is labelled socket sampling, not exhaustive packet capture.

Twelve required cases exercise:

1. TLS chain and hostname refusals plus successful registrations.
2. Outgoing and incoming calls with decoded audio both ways. The outgoing case
   also calls the real shared update guard with the actual active call count,
   requires its refusal, proves fresh audio continues, then hangs up and requires
   idle acceptance. No installer transaction or production update channel runs.
3. Hold with a selected WAV file and resumed decoded audio.
4. Exact received DTMF578#.
5. Blind transfer with decoded audio between the remaining peers.
6. Consultative transfer completion with consultation and final audio.
7. Consultation cancellation and resumed original audio.
8. Waiting-call answer and switching back, with audio on each selected leg.
9. Local conference: actual SDK conference recording contains all three tones,
   and each remote peer independently decodes the other two participants.
10. Software VP8: both peers decode at least20 new frames over3 seconds,
    at least64×64 pixels and measured received frame rate≥5.
11. Local voicemail WAV: the actual SDK Player advances, then an incoming call
    interrupts it and removes its private playback file before answering.

Incoming/outgoing are separate cases, making12 total. All ordinary audio phases
require at least3.3 seconds of newly decoded file samples over at least3.3 seconds
of observation, followed by a continuous current3-second tone window. Every
100ms block must meet RMS≥500, total expected-tone energy ratio≥0.65, each mixed
tone's ratio≥0.12 and clipping≤0.1%. Open WAV headers may be unfinished: the
explicit observation adapter reads the bytes already physically present with
read/write sharing and normalizes length interpretation only in memory. It never
adds samples or changes the native writer's file. Old final files cannot qualify
fresh call phases. SDK conference recordings are identified separately from the
ordinary global receive-file adapter.

Hold audio is an owned generated1553Hz test-tone WAV, exercising file playback;
this does **not** qualify the project's licensed song asset. Static-picture VP8,
file audio and the owned hidden video sink do **not** test a microphone, speaker,
camera, WinUI video rendering, public network/NAT, carrier or customer phones.
Local Player position proves its native playback pipeline, not physical sound.

The receipt consumer rejects incomplete/extra/duplicate cases, unknown fields,
nonfinite or untyped numbers, private identifiers, weak audio/video measurements,
missing cleanup and wider scope claims. A separate failure-only path exports
only a closed stage/type/completed-case count; it cannot accept a failed run as
qualified. A failed native run additionally retains its fixed operation name,
source basename/line, last accepted native startup stage and observed peer exit
and error type. Every native wait also has a fixed name and its original8/20second
deadline. Only after a failed wait, at most3 peers are sampled once for call
counts/states and up to32 native state/reason/SIP-status observations. These
fixture-only observations contain no number, address, display name or error text;
an observation failure cannot replace the original failure. The ordinary compiled
Windows assembly is checked for absence of the fixture types, fields and methods.
Service-difference diagnostics retain at most16 ordinary service
names, changed property names and typed status/start mode; command paths and
accounts never leave the runner. These observations do not relax the complete
system snapshot comparison. Process ownership queries the executable image on
the held Windows process handle with `QueryFullProcessImageNameW`; it requires
the exact launched path, PID, start time and pre-launch ordinary-file hash.
It does not depend on `Process.MainModule` becoming available during startup and
does not retry or restart a native peer. Durable PID/start-time/executable-hash journals permit cleanup of
exact owned processes, and nonce root lists permit only owned non-reparse tree
removal. The wrapper compares service identities/states, root-certificate
thumbprints and all nine firewall collections in ActiveStore/PersistentStore.
Any missing preservation or cleanup holds the result. Raw media, private keys,
SIP secrets, paths and child output are not published in the receipt.

Five additional read-only service observations bracket SDK extraction, MSI
extraction, compilation, entry to native media and its return. Each compares with
the original initial baseline; neither baseline nor final preservation predicate
is moved or relaxed. A transition identifies an observed interval, not its cause.

Pure controls that need no SDK or Windows execution:

```text
dotnet run --project clients/windows/tests/media/PureMediaChecks.csproj
pwsh -NoProfile -File clients/windows/tests/media/ReceiptControls.ps1
pwsh -NoProfile -File clients/windows/tests/media/OwnershipControls.ps1
python clients/windows/tests/media/test_engine_selection.py
```

These controls use generated PCM, explicitly modelled receipts and invented MSI
table rows. Their outputs explicitly keep actual native calling/hardware false.
`guard_controls.py` can additionally invoke the compiled assembly, wrapper and
extractor with only a non-hosted child environment, requiring all three to refuse
before reading absent input paths or creating a report. It needs explicit
`--dotnet`, `--pwsh` and `--assembly` paths and starts no native engine.
Only a later authenticated hosted Windows run with all actual cases and exact
cleanup may qualify the lab's software-media scope.
