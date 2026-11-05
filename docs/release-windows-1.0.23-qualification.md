# Windows Server 1.0.23 release qualification

**Release preparation — 5 November 2026.** Publication is now authorized.
The final private installer and installed components are accepted below;
remaining signed-publication checks are recorded separately. Earlier failed
attempts remain failed.

## Frozen artifact and source

The complete 643,268,769-byte Windows ZIP has SHA-256:

```text
bfc02f54e6c6978748b7ce8b3e8ec432c7d25b21330ccaee915919ea94939e95
```

All 19,288 payload hashes/sizes match its frozen source/input map. The exact
7,725-file source snapshot is preserved byte-for-byte and mode-for-mode in
commit `54779be475d0aab867b04f4908b7b656aee77b57`. The matching source archive
has SHA-256 `e8e493513d7108630fe2ab18ebbd1e92e3387fb1f5a5c6bb0a1fd1d66921c210`.
The commit was created after testing from that exact frozen tree. The default
branch carries subsequent publication documentation; no native build or
artifact is relabelled to hide that distinction.

| Component | Actual evidence |
|---|---|
| Server, updater and native manager | Accepted: all three builds are 1.0.23.0; their code inputs match the prior qualified code except version metadata. |
| Ordinary installed upgrade | Accepted component: normal complete 22-to-23 manual upgrade in 739.944 seconds, exit 0, followed by the scoped audio correction. The corrected repack was not installed again during that private component. |
| DID editor and routing | Accepted: 188 actual Windows PostgreSQL/PHP controls and 49 ordinary browser checks. Temporary disabled provider/number fixtures were removed; the original PBX configuration was restored exactly. |
| Calling | Accepted corrected component: four registrations and four two-way software calls over UDP/TLS in 28.990 seconds; all 16 RTP streams and 3,371 packets pass unchanged limits, including tails. Two earlier audio failures remain recorded. |
| Windows audio default | A 60 ms receive buffer, allowed to grow to 200 ms, stays active while bridging. Explicit administrator values/off choices remain intact. Debian's platform branch is unchanged relative to the shared timestamp policy. |
| Preservation | All 23 captured SQL projections, six private identities/configuration files, original QR/mobile credentials and ten original media files are exact. Six later test recordings are retained. Task names/enabled choices survive; five stock task start timestamps are regenerated. |
| Native manager | Accepted: installed 1.0.23 has a visible, responsive top-level window in the ordinary user's desktop session and remains open. |
| Encrypted backup | Accepted: one normal request, built-in full verification and complete encrypted off-server download in 201.715 seconds. Earlier observer interruptions remain recorded separately. |
| Fresh/restore/reboot and unchanged infrastructure | The relevant unchanged components retain their original 1.0.22 evidence, explicitly scoped below. |
| Signed final-package transition and recovery | Pending actual scoped qualification of the final 1.0.23 offer/package. |
| Public feed/download readback | Pending final publication. |

No installer PowerShell, Windows backup/restore implementation, onboarding,
schema SQL, engine, codec, prompt or music input changed from the qualified
1.0.22 implementation. Their [existing component evidence](release-windows-1.0.22-qualification.md)
is reused explicitly. It is not a new 1.0.23 fresh-install or signed-update pass.
The new signed offer is proposed with minimum Windows 1.0.22; direct older
transitions need their own evidence.

The audio change passes the specified checks; it does not prove that every
network/media timing event has disappeared. No new physical-phone, carrier,
capacity, Store or complete 3CX feature-parity claim is made.
