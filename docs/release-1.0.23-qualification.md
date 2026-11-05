# Debian 1.0.23 release qualification

**Published — 5 November 2026, 13:00:15 UTC.**
[Debian 1.0.23](https://github.com/embire2/openwebpbx/releases/tag/v1.0.23)
has its own package, source and signed feed. This page does not turn earlier
1.0.22 results into new 1.0.23 results. Windows remains 1.0.22 and Android
remains 1.0.19.

## Scope

One incoming-number wizard owns the destination, external forwarding,
local/international aliases and Call Me Back setup. Disabled numbers retain
ownership of their explicit forms and cannot fall through to another
provider destination. Optional number format is per PBX. This release also
contains the current RTP timestamp policy; its actual Debian media behavior
must be checked against the earlier hosted installation.

| Component | Evidence |
|---|---|
| Hosted DID correction | Accepted local component: actual provider-number evidence, installed route decisions, owner browser saves and preserved customer configuration. No answered provider-call confirmation is inferred. |
| Current routing fixtures | Accepted: 188 isolated PostgreSQL controls, 235 Lua decisions and audio-policy controls. |
| Upgrade unit controls | Accepted: 17 current tests. An earlier mock omitted the real process stdout field; the mock-only correction and failed attempt are retained. |
| Native server/updater | Existing 1.0.23 outputs verified against their source inputs and all 565 output hashes/sizes. |
| Final complete package/source binding | Accepted: stock package from commit `d27583e72018fcbd55c517a766697b8267658dc1`, 487,501,845 bytes, SHA-256 `5b0ad3c5c823cfae9067c3a95a1a9d52c7c76d8fcec6adb8ee99662a2e3e0dab`. All 12,210 payloads and matching application source are verified. |
| Fresh managed setup | Accepted on a separate Debian 13 guest: stock installer, ordinary verified-owner registration, two ordinary users, 49 DID browser checks, 34 stable-QR checks and eight UDP/TLS calling cases. Full capture: 16 streams, 3,301 RTP packets, no packet or clock errors under unchanged thresholds. |
| Signed 22-to-23 failure recovery | Accepted: genuine public 1.0.22 worker downloads the signed fault fixture from the original URL, reaches an intentional late migration failure and automatically restores 1.0.22 in 375.004 seconds. All six services return; original data, identity, credentials and file security are compared. |
| Signed final 22-to-23 upgrade | Accepted: the same original worker downloads the unmodified final package and exact public-candidate envelope, then completes in 394.115 seconds. All 184 original tables, relevant schema, roles, private identities and 12,248 mapped targets are checked. Post-upgrade calling/QR and the public-feed check are recorded separately below. |
| Post-upgrade behavior | Accepted: the same original phone credentials pass all eight UDP/TLS cases in 25.285 seconds. Full capture: 16 streams, 3,292 RTP packets, no packet or clock errors. DID browser checks pass 49; stable QR checks pass 34, with only the two temporary devices self-revoked. |
| Ordinary public feeds/downloads | Accepted: all seven anonymous complete downloads match SHA-256 and size; canonical/source tags bind the qualified source. Latest-feed bytes match the new Debian offer and retained Windows/Android envelopes. The ordinary installed public-feed Check is recorded separately when it closes. |

Unchanged 1.0.22 engine, installer, registration, restore and security components
retain their original [acceptance record](release-1.0.22-qualification.md).
New artifacts and affected behavior receive their own checks. The
signed minimum is 1.0.22, matching the transition qualified here.

The stable-QR migration is the only intended schema change. Existing mobile
accounts retain their credentials. This upgrade fixture had no historical
enrollment rows, so it does not establish a new legacy-invitation conversion
result. Unrelated rows remain exact apart from the source-defined updater and
timer timestamps. The installed support script sets its one public nginx site
file to mode 0644, preserving its bytes and root ownership. Two PostgreSQL
CHECK expressions are deparsed differently during rollback; their exact
literal sets and behavior, including NULL, were checked against PostgreSQL.
The one regenerated Python cache is bound to the unchanged source and
interpreter. These narrow comparisons and their original failed assertions
are retained; there is no general permission, schema or data exclusion.

Physical handsets, actual providers, restrictive networks, capacity and app-store
approval remain deployment-specific. The Webhotel image is a separate rollout.
