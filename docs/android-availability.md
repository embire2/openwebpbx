# Status and queues on Android

Android 1.0.9 added **Status and queues** under **Settings → More**. The prepared 1.0.10 patch keeps the same phone controls; 1.0.9 remains the published baseline until the patch is published.

Choose your status, then **Save status**. The choices come from your PBX user settings: normally **Available**, **Away**, **Out of office**, custom statuses and **Do Not Disturb**. The change applies to your PBX user, including your other phones; it is not a separate setting stored only on this device. Contacts show colleagues' effective status in the same PBX.

Choose a duration to return automatically after 15 minutes, 30 minutes, 1 hour, 2 hours, 4 hours or 8 hours. **Until I change it** keeps the selection. Changing a temporary status again preserves the original return selection. Saving a permanent status cancels the return timer. An administrator's later user edit takes precedence over an older timer.

If automatic office hours are enabled for your user, a temporary selection overrides that schedule until it expires. The PBX then reapplies office hours, breaks, holidays and any active office open/closed override. This means a temporary **Available** selection can return to **Out of office** after the office closes. A permanent **Do Not Disturb** selection remains in effect outside office hours.

A new **Do Not Disturb** profile stops direct ringing, ring-group ringing and queue offers. It sends callers to your own mailbox when voicemail is enabled; otherwise it ends the call. Existing administrator-defined forwarding profiles are preserved.

Your assigned queues appear below your status. Check a queue to join it or uncheck it to leave. Leaving one queue keeps your other selections. If the PBX had signed you out of all queues, joining one signs you back in to that queue only; other inherited memberships remain off until you select them. Joining a queue does not override **Do Not Disturb**, a profile that pauses queues, or a callback that has already reserved your phone.

The page explains why queue calls are paused: you left the queue, you are signed out, your status pauses calls, or a callback is using your phone. Queue readiness still follows the PBX's normal busy state and time to finish the previous call. Changing a selection preserves those native timings and any call already in progress.

A phone can change only its own status and assigned queues. Other tenants, unassigned queues, disabled users, disabled PBXs and suspended tenant accounts remain inaccessible. Settings are saved together so simultaneous phone and administrator edits do not lose each other's changes.

## Operation and verification

The shared PBX configuration remains the source of status and membership. Temporary return timers are also stored in PostgreSQL. Native calling decisions apply an expired timer even if the background service is unavailable; the service reconciles the stored profile and refreshes the user's assigned agents. An unavailable native agent keeps a durable retry until synchronization succeeds. A recent administrator edit or renewed timer cannot be replaced by an old expiry.

The internal `mobile_state.lua` operation checks that every agent belongs to the requested PBX. It updates agent status without unloading active queues, resetting readiness or changing colleagues' agents. Multiword native statuses require single quotes; this was verified against the actual call engine.

Verification on 2026-10-12:

- `php tests/pbx_mobile_state.php`: 48 checks with isolated PostgreSQL schemas, including tenant/extension denial, suspended accounts, temporary statuses, office/break/holiday boundaries and overrides, independent PHP requests contending for the same row lock, and individual sign-in after global sign-out.
- `dotnet run --project tests/mobile-state-worker/MobileStateChecks.csproj`: focused tests require a privately supplied `OPENWEB_TEST_DATABASE`; no database credentials are printed. Eleven checks cover real PostgreSQL expiry, competing workers, administrator changes, replaced users, native failure/retry and a renewed timer while the worker waits for the phone API's row lock.
- Separate disposable native PBX: individual join/leave, preserved ready time/wrap-up/state, callback reservation, DND agent isolation, an actual call reaching its own native voicemail, an actual call ending without a mailbox, temporary DND, foreign-domain agent denial and suspension guard passed. No provider connection or outside call was used.
- The optional `OPENWEB_NATIVE_STATE_FIXTURE` worker check uses an explicitly provisioned private `availability-check-*.invalid` tenant and an isolated presence table. It cannot enumerate customer timer rows. The suite passed 19 checks with this native mode, including expiry before reconciliation, restored Admin status, both assigned agents resuming, colleague preservation and recovery after an agent was deliberately removed and reloaded.
- Cleanup verification confirmed no disposable tenant, user, queue, agent, timer, call record or voicemail row remains; native agents/queues/tiers and private voicemail files were removed. No outside call or real email was sent.
- Actual Android availability qualification passed in 12.425 seconds: authenticated temporary Do Not Disturb, an assigned queue paused by status, the native status dialog, return to Available, and native per-queue leave agreed with server state. Fixed empty receiving labels and retained the specific pause reason after a queue change. Only disposable accounts/queues were used.
- The exact final signed 1.0.9 direct APK repeated that native status/directory/temporary-DND/queue workflow in 9.619 seconds. The APK derived from the exact signed Play AAB passed it in 10.519 seconds. Both restored the fixture's preceding status and queue choices; no customer account or queue was changed. These are actual Android 13 software-device checks, with physical handset coverage still separate.

Broader Android qualification, physical handset coverage and release publication are recorded separately in [the roadmap](../3CX.md). These results do not claim complete 3CX compatibility.
