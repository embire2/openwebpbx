# Talking clock 1026 — 1.0.2

The hosted clock now starts a time announcement immediately after its short Nathaniel welcome and repeats every **15 seconds**. It gives the upcoming signal in **24-hour GMT+2**, including seconds. Quiet half-second ticks fill the interval before the 1000 Hz beep. Dial **1026** from a connected account; no app download is required for this hosted repair.

The old implementation could wait almost a minute after its welcome. A reported 58-second call ended before the next announcement. This repair changes the clock scheduler and introduces seven small Nathaniel UK phrases plus a locally generated timing tick. The existing system voice **1.0.1**, customer recordings, greetings and call configuration are preserved.

## Verification on 17 October 2026

The final staged and installed calls used fresh fictional SIP accounts, real digest registration, the normal engine and captured/decoded RTP. The installed case used the actual global 1026 route with no script, audio or dialplan overlay.

| Check | Staged final call | Installed global route |
|---|---:|---:|
| Complete, correct announcements | 3 | 3 |
| First numeric speech after answer | 3.46 seconds | 3.46 seconds |
| Time between signals | 15 seconds | 15 seconds |
| Native signal lateness | 18 ms | 18 ms |
| Decoded local beep onset after target | 54.89 ms | 41.786 ms |
| Minimum per-component speech correlation | 0.99989 | 0.99989 |
| Maximum decoded quiet interval | 600 ms | 560 ms |
| Missing RTP timeline | 0 ms | 0 ms |
| Captured RTP packets | 2,525 | 2,663 |

Independent transcription matched all **seven new spoken scripts** and all **six final captured full-time announcements**. The installed announcements were 19:18:00, 19:18:15 and 19:18:30 GMT+2. This is specific ASR coverage, not a new transcription review of every stock prompt. Telephone/network delay still affects when a listener hears the beep.

The Lua suite passed **104,502 controls**, including every second of a GMT+2 day, every 15-second speech sequence, midnight, immediate speech, late playback, clock adjustments, hangup, missing media, playback/time failure and the native 30-minute cap. Offline native-harness checks cover RTP reordering/loss reconstruction, signal detection, actual reference matching, singular units and all eight sample phases.

The first staged capture was retained as a failed candidate. Its checker skipped sample phases, causing two false-low speech correlations; the corrected checker recovered 0.99991/0.99990 from the unchanged audio without lowering the acceptance threshold. That call also exposed a real 1.38-second wait gap; the shorter tick fixed it before the final native repeats. No failed observation was relabelled as a pass.

## Hosted activation and recovery

Activation held the shared updater lock, required an idle/resumed engine and saved exact original file bytes/modes/owners/absence before copying only **22 clock targets**. Calls paused **11.766 seconds**; the engine resumed without a service restart. No customer database, route, provider, voicemail selection, application binary or callback runtime was changed. Two private fault fixtures exercised the actual narrow writers and recovery journal, including a late write failure and an interrupted-journal recovery; engine responses were simulated in those file-recovery fixtures.

Final checks passed all 22 installed hashes, all **4,888 unchanged system-voice files**, 26 frozen clock dependencies, all **1,273 customer media/music files** and **17 original configuration-table multisets**. Only the two precisely identified new Meet dialplans from a separately coordinated task were excluded from the pre-existing-row comparison. Six checked services were active, the engine was resumed and calls were zero. Both final test tenants, contacts, channels and channel-owned timers were removed; only exact owned CDR bytes were retained privately under the existing importer lock.

Private diagnosis, source bindings, audio/transcriptions, preservation and recovery evidence remain in `/var/lib/openwebpbx/clock1026-repair-20261017/`, especially `candidate-final-bindings.safe.json`, `preflight-final/`, `installed-final/`, `activation-journal.json` and `installed-final.safe.json`. Raw customer inventories, credentials and audio are not committed.

[The catalogue](../app/pbx_setup/resources/talking-clock/1.0.2/catalog.json) and [audio manifest](../app/pbx_setup/resources/talking-clock/1.0.2/audio-manifest.json) record the voice identity, scripts, master/output hashes and dependencies. This is an independent **clock 1.0.2** repair. Immutable Debian/Android **1.0.15** downloads, the full voice 1.0.1 archive, new Windows native acceptance, complete signed installation/upgrade and physical/carrier qualification are unchanged.
