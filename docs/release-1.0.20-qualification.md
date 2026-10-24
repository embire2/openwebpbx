# Server 1.0.20 qualification

This is an in-progress qualification record, not a publication announcement.
The complete server 1.0.20 release is not public, and the hosted instance has
not received the complete server upgrade. Android remains 1.0.18, including its
existing mandatory minimum.

**Current work on 24 October:** the unchanged candidate from normal40005106134
passes all 17 full-suite gates. Independent replacement restore40100133999 passes its source
job, then refuses a meeting-setting snapshot guard. The exact Windows path-format
QA correction ce38c420b passes actual PostgreSQL/PHP tests and independent review;
native restore repetition remains required. The historical raw field/value is
unretained. Updater40097476201 passes all nine upgrade gates and
cleanup for the accepted archive and its existing signed canary. Actual IIS
import/calling diagnostic40098653401 passes its six scoped upload, preserved-credential,
direct/ring-group decoded-audio and cleanup cases. The earlier
restore and updater failures remain recorded with their limited evidence;
independent restore remains unqualified. Physical phones, carrier cutover and rendered UI
are outside the import diagnostic. A default-HTTPS-port
restore compatibility correction is now reviewed in source. Fresh normal40100370382
is building and testing that product change without replay or diagnostic flags.
Publication and further signing remain held for build-host
and credential recovery; owner migration, actual OS reboot and external access
remain open. See the [current Windows release-gate table](windows-parity-1.0.20.md#windows-release-gates)
and [Windows work record](windows-parity-1.0.20.md).

The Debian archive described below is historical: it predates Phone Health and must not be
published or installed over the newer hosted patch. A Debian release containing
that feature needs a rebuilt package and new installation/update/restore checks.

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
Native build39825672102 passed, including a responsive WinUI manager; its
71 platform inputs and original artifact were independently verified. Corrected
engine build39823852979 passed its native parser, registration and codec
controls. Neither result alone qualifies the complete server.

The accepted normal40005106134 package now passes the installed Phone Health,
STUN, calling, provider failover, clock, Call Me Back, conference and background
call-history checks, alongside fresh installation, backups and recovery. Earlier
component-only results do not replace this complete package evidence.

The owner's original1.0.6 installation has retained file/ACL, database/global,
configuration, IIS, certificate, service/task and firewall recovery copies.
It has not been upgraded. Migration/interruption/recovery on that installation,
actual OS reboot, public certificate issuance/renewal, external phone/provider
access and final release integrity remain open. Independent restore and newer
updater results must also pass; see the current table above. Public releases
and all retained platform feeds are unchanged.

### Earlier Windows candidate checks

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

The genuinely rebuilt package from that correction passed its actual native
fresh installation, 29 trusted sign-in/readiness controls, and 49 conference
transport controls. The transport checks reproduce the old locked override
failure and verify the correction, strict backend TLS and actual IIS WebSocket
connections. They do not establish decoded browser conference media.

That run still failed the tenant static-proof and voicemail-default checks.
A later helper reapplication correctly refused two unexpected Python bytecode
files in the expanded candidate. Those failures are retained.

The next rebuilt candidate, from `d97df9e8`, passed its fresh installation,
the same 29 readiness and 49 conference transport controls, and 75 native
tenant-worker, ACL, IIS alias and trusted-HTTPS controls. The proof-file test
reproduced HTTP 401 with the old ACL, then returned HTTP 200 with the exact
nonce after the packaged public-file ACL was applied. Private-key access was
not widened. Explicit Python `-B` also prevents the earlier bytecode additions;
the 19,122-file candidate inventory stayed unchanged.

The complete run still failed its Windows voicemail-default fixture and a
later rollback comparison. A separate isolated Windows run reproduced the
fixture's configuration-loading failure after 18 checks. Reading the factory
INI without pinning the application's project-root constants allowed the
corrected fixture to complete its 45 Windows filesystem and PostgreSQL checks
in both connection modes. The same run proved the temporary test folder needs
the named installer account's access, which the product installer already
grants. It also identified background database output pipes holding the test
wrapper open. These corrections affect QA only; the original failures remain
retained and complete installer acceptance is still pending.

The rollback comparison is being replayed with corrected closed diagnostics
and unchanged exact-equality checks. The candidate remains
unpublished. Voicemail, decoded calls and browser conferences, independent
restore, newer-version installation and recovery still need complete native
acceptance of the final package. Public ACME issuance is separate from the
trusted fixture-certificate checks and remains unqualified.

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
ring-group phones ring and the caller hears ringing. The owner subsequently
answered an outside call and confirmed sound in both directions. This accepts
that actual affected-group call; other handsets, sites and provider routes
remain separate checks. Roadmap totals remain 133 items: 21 accepted, 72 partial
and 40 planned.
