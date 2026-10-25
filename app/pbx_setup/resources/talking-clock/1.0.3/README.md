# Keoma talking clock 1.0.3

The active clock announces precise GMT+2 time using Keoma, professional voice
`i8SlcaZfyeP1st7wHsjM` (South African English). The immediate announcement,
15-second cadence and signal calculations are unchanged. Actual processed
speech durations are sealed and rounded up for the existing timing guards.
Network/telephone latency still affects when callers hear each signal.

The active [audio manifest](audio-manifest.json) contains nine Keoma phrases,
one unchanged locally generated timing tick, and 24 frozen Keoma digit
dependencies from system voice 1.0.2. The [catalogue](catalog.json) also lists
legacy spoken aliases covered by the full system pack. Complete Keoma voice
1.0.2 is required; copying only the small flat clock files is insufficient.
No API key is needed for playback, and no instrumental/customer audio is changed.

The old Nathaniel catalogues and immutable duration fixture remain for history
and timing regression tests. They are not selected by the new runtime. Native
and complete installer/call acceptance must qualify these exact new bytes;
prior-release receipts do not prove a new narrator deployment.
