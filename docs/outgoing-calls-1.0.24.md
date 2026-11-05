# Outgoing call correction — Debian 1.0.24

Deployed to `call.openweb.co.za` on 5 November 2026. This correction keeps
version 1.0.24 and does not require a new Android APK.

## What failed

Extension 1000's selected provider accepted registration but rejected actual
outgoing calls with **403 Auth Failed**. A private packet capture and independent
Digest calculation confirmed the PBX used the saved authentication identity and
secret correctly. Changing caller-ID headers for a call did not resolve that
provider rejection. Android's generic permissions message did not identify the
provider as the source of the rejection.

The retained configuration from before the 1.0.24 feature deployment selected
the existing **OpenWeb Porta** connection for extension 1000. Its provider
selection had subsequently changed. The correction restores that single
extension-scoped selection to OpenWeb Porta. The new reseller connection remains
configured; its provider-side authentication/authorization failure is not
claimed repaired. Other users, providers, incoming numbers, callback selections
and routing are preserved.

## Core corrections

- An imported provider with `SRTPDisabled` now uses plain RTP on its outgoing
  leg, even when the calling phone uses SRTP. This does not change the phone's
  encryption. Explicit saved provider options still take precedence, and the
  options page shows the restored setting correctly.
- The provider receives its complete configured codec list. The tested restored
  connection negotiates G.729; offering PCMU alone was rejected. The existing
  G.729 transcoder remains in use; no global codec order or dependency changed.
- A provider's 183 early-media response is no longer counted as an answered
  call when its final response is a rejection. Outgoing calls and queue
  callbacks use the actual answer hook and final bridge failure. Existing
  permitted fallback rules apply only to unanswered calls; an answered call
  cannot be duplicated. When there is no backup, the last provider failure is
  retained. Historical call observations are not rewritten.

## Verification

241 policy controls, 214 routing/runtime controls, 37 provider-option controls,
17 attempt-observation controls and 60 isolated PostgreSQL controls pass. A real
loopback SIP provider verifies that the restored plain-RTP setting overrides a
mandatory-SRTP caller choice without changing phone identities or a real trunk.

One authenticated call using extension 1000's original credentials to the
reported landline completes with SIP 200 and a normal acknowledged hangup.
The existing provider negotiates G.729. The software phone sends 96 and receives
116 RTP packets during the short call. These packet counts do not establish a
human two-way-audio or physical Android-device result.

Seven installed web/native runtime files are updated with their owners and
permissions preserved. The tenant configuration differs at exactly one existing
route's provider key. Native gateway rows, extension credentials and the original
calling-engine, web-server, Core and updater process generations remain exact.
No registration, QR reset, custom recording change or server restart is needed.

[Windows catch-up ledger](debian-windows-sync.md) records the source and Windows
regression checks required before these shared changes are released there.
