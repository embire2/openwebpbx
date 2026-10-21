# Incoming routing — admin update 1.0.19

Open **Admin → Voice & Chat → your SIP trunk**. **Incoming Calls** appears above the provider settings. Each saved incoming number shows its first selected destination now, taking account of office hours, holidays and temporary opening overrides. A switched-off number is identified as a saved destination. Destinations can apply their own forwarding and availability rules after this first step.

Choose **Route Calls To**, then **Save Incoming Route**. Extensions, Ring Groups and Digital Receptionists are named in the list. Existing queues, voicemail and external destinations are also supported. Office Hours & Holiday Routes keeps separate closed-hours and holiday destinations. Each number is saved separately; changing one does not replace the trunk's other numbers or its fallback order. A stale form refuses to overwrite a newer route.

For **Call Me Back**, first set up that incoming number under **Call Me Back**, including its calling user, accounts, limits and ready Nathaniel greeting. Its service then appears in the trunk's destination list. Confirm switching the number to or from Call Me Back. Callback mode answers that number at all times; normal open/closed/holiday destinations remain saved underneath. Switching back disables that number's callback interception. Already connected calls keep their existing limits; pending callbacks follow the service's enabled state. A disconnected provider, disabled incoming number or unready greeting prevents activation.

The PBX owner manages these destinations. Department staff retain their existing access. Saves are tenant-scoped, transactional and audited. No SIP passwords, phone registrations, provider enablement or provider reconnects are part of a destination change. Incoming-number activation is still managed by Number Settings / the confirmed provider handover.

## Release scope

This is **admin update 1.0.19**, installed over the complete **Debian 13 core 1.0.16**. Android remains **1.0.18/code118**, with its existing mandatory minimum and signing identity. The unqualified full-server candidate1.0.17 and Windows development are separate. This package is not a full server installer, Android APK or automatic full-core upgrade. The retained signed Android and Debian feeds continue to advertise their respective qualified releases.

## Install the admin update

Download `openwebpbx-1.0.19-admin-update.tar.gz` and check it against `SHA256SUMS` from the [1.0.19 release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.19). Extract into a private directory, then run as root:

```sh
tar -xzf openwebpbx-1.0.19-admin-update.tar.gz
cd openwebpbx-1.0.19-admin-update
python3 install-admin-update.py
python3 install-admin-update.py --apply
```

The first command verifies the release signature, all payloads and exact supported original files. The second takes the shared maintenance lock, preserves recovery copies and atomically installs the web files, with the entry page last. It refuses other operating systems/core versions, links and custom inputs. Applying again is safe. On a caught installation failure it restores the files it changed. Recovery copies and their hash/mode/owner journal are kept under `/var/lib/openwebpbx/updates/admin119/`. No database migration or SIP service restart is required. Refresh the page after installation.

Existing unpatched Debian16 update workers should separately install the [1.0.18 r2 feed compatibility update](https://github.com/embire2/openwebpbx/releases/tag/v1.0.18). The admin patch does not replace the update worker.

## Verification

Passed: 44 isolated PostgreSQL checks, 20 actual-filesystem installer checks against stock/hosted16 (including partial-failure recovery and idempotence), 16 normal trusted-HTTPS form checks, and 42 browser assertions across 12 desktop/mobile light/dark layouts. Existing194 calling-runtime,218 routing-policy and48 provider-preservation checks passed. The browser's normal Save selected a Ring Group and displayed it after navigation. Callback handovers, closed/holiday selection, stale forms, foreign numbers, audit writes and exact native provider/phone preservation are covered. Disabling callback interception remains possible after its calling user becomes unavailable.

The first filesystem run exposed an unclear failure on a dangling entry-page link; preflight now refuses that entry explicitly before planning other files. Earlier fixture setup/CLI-permission and browser-driver errors were corrected and repeated; they are not product passes. These checks do not establish a new physical-phone, carrier-audio, Google Play or full-server installation pass.
