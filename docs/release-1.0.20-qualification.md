# Server 1.0.20 qualification

This is an in-progress qualification record, not a publication announcement.
The complete server 1.0.20 release is not public, and the hosted instance has
not received the complete server upgrade. Android remains 1.0.18, including its
existing mandatory minimum.

The Debian candidate is built from immutable source
`01eafb5d4056d7c6ad60c21847a0ff5efee8620d`. Its archive is 428,715,394 bytes,
SHA256 `92c1f381292c02e30f2b1cbe0658e7283d42ac3dc883a72322f6177350dd5686`.
Independent archive checks cover all 12,053 payloads and 13,208 member metadata
records. Later Windows-only packaging or qualification changes do not change
these Debian archive bytes.

| Debian 13 check | Observed result |
| --- | --- |
| Normal installation with empty PBX/application state | Passed in 149.83 seconds; eight services active, all 12,139 installed mappings plus 59 engine metadata checks passed. |
| Empty restore-server installation | Passed in 223.751 seconds; the same installed-file and service checks passed. |
| Tenant-address activation | Normal trusted owner HTTPS and the installed activation helper passed twice on each fresh target, including idempotence. |
| Upgrade from real 1.0.16 with the published compatibility repair | Normal owner HTTPS installation completed, then the new 1.0.20 worker completed finalization and reported up to date. No manual activation patch was needed. |
| Deliberately failed late upgrade | All three late-stage witnesses were reached. Recovery restored 164 complete table multisets, 13,044 regular files, 320 private files, 31 links and 1,376 directories, with no exclusions or extra directories. The original server resumed. |
| Encrypted backup restored onto a distinct empty PBX/application installation | Passed verification and activation. All 167 tables and 361 private/media files matched the documented restore transforms. Wrong-password refusal and dry-run checks passed separately. |
| Ordinary calls | Fresh, restored and upgraded systems passed actual engine calls with independently decoded audio in both directions and automatic call history. |
| Voicemail and talking clock | Own-mailbox 121 played Nathaniel; three 1026 time signals passed on each final system. Maximum observed signal lateness was 15 milliseconds. |
| Restored browser conference | Normal trusted sign-in, invitation, admission, mixed VP8 decoding, two-way audio, host mute/unmute and complete media shutdown passed. The intended WSS origin was checked. |

The installation targets use reused Debian 13 operating systems. Their prior
application, database, roles and media were archived and reset; these are empty
application installations, not newly imaged operating systems.

Normal upgrade preservation compares every original table and column. Of the
164 original tables, 161 are entirely unchanged; the remaining three contain
only the expected install command, update-status and owner-login changes.
Three new tables are empty, and one new purpose column is added to the existing
empty enrollment table. All 320 original private files and 4,908 original audio
and voicemail files retain their bytes, modes and owners. Database identity,
roles, existing SIP credentials and routing remain exact.

The distinct restore preserves all table contents except three prescribed
in-flight backup operational tables and two meeting-address rows. File bytes
are exact except the two target connection configurations. Product permission
normalization is checked explicitly. The target database identity and roles
are preserved; public-schema ownership and ACLs are normalized by restore and
are not claimed to remain catalog-identical. Saved non-default SIP trunk
Options, the full native gateway, voicemail, stereo recordings and a disabled
Call Me Back service with its exact key, HMAC challenge and named greeting are
included in the comparison. Call Me Back accounts, bindings and requests were
empty in this source fixture; nonempty accounts are not implied by that check.

The historical isolated targets use their explicitly recorded, signed PHP
8.4.27 package build. The current signed Debian security repository also
provides 8.4.27. These are different package builds; their bytes are not claimed
to be identical.

## Windows Server

Windows Server 2025 x64 with Desktop Experience remains under qualification.
The native build and responsive WinUI manager window passed. Static checks of
the current candidate cover its immutable source, bundled native programs,
corresponding engine source and Nathaniel audio.

The superseded candidate at `2310f466` completed its initial installer but its
normal IIS sign-in page returned HTTP 500. Precise native configuration reads
identified the generated child WebSocket override being rejected with
`0x80070021`, before PHP executed. This agrees with Microsoft's documented
[IIS configuration-lock behavior](https://learn.microsoft.com/en-us/troubleshoot/developer/webapps/iis/site-behavior-performance/http-error-500-19-webpage).
The old candidate is not publishable.

Correction `9e5cb02a` omits the unnecessary override and checks the effective
owned-site WebSocket setting. It preserves IIS's existing parent policy. A
trusted local sign-in check also prevents installer success while the web
frontend is broken. Fifteen real TLS/HTTP protocol cases passed on Linux
PowerShell, including strict single-Boolean results and HTTP 500 refusal;
these supplement native Windows qualification.

A genuinely rebuilt Windows package is now under native qualification.
Working conferences, independent restore, newer-version installation and
recovery are not yet accepted for that new package. No Windows release
follows from the source or protocol checks alone.

Windows 10 and 11 server installations, upgrades from historical Windows
packages and the separate planned native Windows calling client are not
qualified by these results.

## Retained failures and practical limits

Earlier candidate F exposed an installed tenant-domain finalization defect;
the final Debian candidate contains its correction and passed the real old
worker upgrade. Two subsequent private build attempts failed source or member
metadata checks and were refused before publication. Their bytes and failures
remain archived.

The first final-candidate fault observer took its baseline before Check and
Download, so it correctly rejected operational-row and generated-cache
differences. The later correctly timed recovery comparison passes without
exclusions. Two initial short-window fresh-call observations failed the strict
audio threshold; a longer 23-second collection passed the unchanged threshold.
An insufficient collection window is an inference, not a proven root cause or
product correction. Restored conference observers initially had no guest default
route and therefore no ICE candidates; an isolated guest-only route allowed
the unchanged product to be tested. Those failed observations remain retained.

These software tests do not establish physical camera operation, every desk
phone model, all carrier routes, TURN traversal, capacity or Google Play
approval. The owner's separate live outside test confirms that the affected
ring-group phones ring and the caller hears ringing. It does not establish
answered two-way audio. Roadmap totals remain 133 items: 21 accepted, 72
partial and 40 planned.
