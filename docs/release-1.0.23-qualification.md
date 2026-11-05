# Debian 1.0.23 release qualification

**Release preparation — 5 November 2026.** Publication is now authorized.
This page records actual acceptance as it completes; it does not turn earlier
1.0.22 results into new 1.0.23 results. Public downloads remain 1.0.22 until
publication succeeds. Android remains 1.0.19.

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
| Final complete package/source binding | Pending exact committed-source package and readback. |
| Affected fresh setup and signed 22-to-23 upgrade/rollback | Pending actual final-package qualification. |
| Ordinary public feeds/downloads | Pending signed metadata, immutable upload and public readback. |

Unchanged 1.0.22 engine, installer, registration, restore and security components
retain their original [acceptance record](release-1.0.22-qualification.md).
New artifacts and affected behavior receive their own checks. The proposed
signed minimum is 1.0.22, matching the transition being qualified.

Physical handsets, actual providers, restrictive networks, capacity and app-store
approval remain deployment-specific. The Webhotel image is a separate rollout.
