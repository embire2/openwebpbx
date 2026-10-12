# Core calling in 1.0.9

Version 1.0.9 adds a provider setup flow, explicit opening-hours routes, a receptionist switchboard and queue supervision. Keep an existing telephone service available while validating a new provider.

## Add a SIP trunk and make the first calls

In Admin, open **Voice & Chat → Add SIP Trunk**. Enter the provider's server, authentication method, incoming IP addresses and main number. Approved IP sign-in hides and disables credentials and registration; switching back to password sign-in preserves what you typed. Without JavaScript, leave credentials blank and turn off registration for IP sign-in. Choose who answers, optional opening hours and the outside-call digit changes. An optional existing backup provider is added after the new provider in the outgoing rule. Both routes initially use the same digit changes; edit Outbound Rules if either provider requires another format.

Saving creates the provider, main-number route, optional hours and outgoing rule together. The new provider and incoming number remain off. Review the provider readiness message and enable each during your agreed handover window. Existing carrier connections are preserved. Registration verifies sign-in; it does not prove incoming calls or speech.

**First Calls → Check Server Connection** checks the configured public hostname and trusted encrypted phone listener. Remote audio still needs actual phone calls.

**Call My Connected Phone** checks the chosen enabled extension and its ordinary outgoing rule. Review the displayed providers and rewritten numbers, then confirm the call. Your connected phone rings first; the outside leg begins after you answer. The route must initially select the provider whose checklist is open. The worker rechecks the registration and provider route before dialing, uses the ordinary route's failure behavior and limits the test to three minutes. The administrator can start one test per PBX every four minutes. Provider charges may apply. Emergency numbers and internal calling objects cannot be used as outside test numbers.

For an incoming test, call the main number from an actual outside phone. Check the intended destination, menu keys, caller ID and speech in both directions. Select the answered, completed call from the last 24 hours and confirm the observed result. Outside steps require a CDR identifying the selected provider. The backup step instead requires an answered outgoing call identifying a configured provider after the selected trunk in an ordered route. A five-minute check requires at least 300 answered seconds. A generated test alone never confirms speech. Checks are invalidated by changed provider, route or instance configuration, including native settings of a backup in the same outgoing route. Use the [carrier cutover guide](carrier-cutover.md) for a controlled transition and provider-specific limits.

## Opening hours and routing

**Office Hours** supports several opening periods per day, overnight periods, breaks, dated holidays and a department timezone. An end time of `24:00` means midnight. A start/end pair with the same time is refused; use Always Open for continuous service.

A main number created by the provider flow can use explicitly selected hours even when its receiving extension belongs to another department. User status and forwarding still apply after the main-number route selects its destination. Existing imported department schedules are retained.

Use **Temporary Opening Hours** to force a department open or closed for 15 minutes through 24 hours. The normal schedule resumes at expiry. **Call Routing → Where Will This Call Go?** previews a user or incoming number for a selected local date and time. Configure blocked numbers and anonymous-call rejection there. Emergency numbers use separate explicit provider routes and provider-approved location caller ID. Arrange an approved emergency test with the provider.

## Receptionist switchboard

**Switchboard** lists this PBX's live calls, searchable people and availability. Users granted `pbx_core_view` can open the standalone Switchboard application. Call actions additionally require `pbx_core_control`; only active calls and enabled destinations within the selected PBX are accepted. Admin access includes these controls.

Choose a call to hold/resume, transfer or move it to the selected phone with Pick Up. End asks for confirmation. Enable shared parking in Admin to expose twenty slots; dial `*701` for slot 1 through `*7020` for slot 20. Parking must be explicitly enabled for the PBX. Call actions recheck native ownership and write an audit result. An ended call requires refreshing the display before retrying.

The live display polls every three seconds while visible. Losing the engine connection shows a retry message. An explicit native zero-call result displays an empty call list.

## Queues, callbacks and wallboard

In **Call Handling → Call Queues**, choose the ringing strategy, waiting capacity, agent ring/wrap-up times and optional priority groups. Priority 1 is attempted first; the configured strategy chooses among agents at the same priority. Periodic messages can announce a tracked queue position and estimated wait. Estimates use recent answered queue visits and are approximate.

Callbacks can be disabled, requested with key 2, offered after a wait or requested automatically. Set the maximum attempts and outgoing prefix. Choose Live Callers First or Keep Original Queue Position. The latter orders ready callback requests against tracked live callers; temporarily unavailable requests retry without preventing newer available callers from being served. An agent is reserved across their assigned queues before callback delivery. No-answer and unavailable providers retain bounded retries, and disabled queues cancel pending delivery.

When optional Web Push is configured for an assigned agent's active mobile device, the native queue route wakes only the agent selected by the ringing strategy. The helper validates the live queue caller or current callback lease, the tenant and agent's current availability before waking or dialing. This delivery never falls through to the agent's voicemail. Direct contacts remain in use when no matching Web Push device is configured. Locked/idle physical handset delivery remains a separate Android qualification requirement.

**Wallboard** shows native waiting callers, longest wait, agent state and an in-page alert after the configured waiting target. Ready, Break and Sign Out require `pbx_core_supervise`. Changes persist in PBX preferences and are reconciled by the background service without resetting an active bridge, native ready time or wrap-up. Android membership and status still apply to the agent's ability to receive calls.

**Queue Reports** separates finished answered/abandoned visits from callback connected/failed/pending results over the last 24 hours, 7 days or 31 days. Live waiting calls and requests converted to callbacks are excluded from finished visit totals. These scoped operational reports are not carrier billing reports. There is no statistics-reset or external notification action in this candidate.

## Verification

On 2026-10-12 the candidate passed 48 isolated PostgreSQL setup/schedule/ownership/first-call checks, 149 call policy checks and 75 runtime checks, including selected-agent validation, concurrent caller identity and first-call provider selection.

Nineteen actual native checks passed using a separate disposable PBX and three local SIP phones: waiting and service-target display, top-down agent selection, queue media, switchboard hold/resume, transfer, parking/pickup/end, agent-first callback, queue reports, bounded ordinary-provider First Calls, selected-agent loopback media and rejection, forced-open/closed explicit main-number routing, and two simultaneous waiters with answer accounting attributed to the selected older caller. The provider endpoint was a local SIP fixture. Twenty-one live HTTPS checks passed for authentication, ownership, CSRF, new pages, outgoing route preview and actual provider-wizard persistence, including disabled initial enablement, backup order and independent hours.

Chromium review passed all seven screens in the desktop's light and dark appearance at 1440, 390 and 320 pixels, with no horizontal overflow or page errors. The review covered approved-IP credential hiding and disabled submission, password masking, advanced fields, preserved typed values across sign-in-method changes, routing preview, breaks/holidays/temporary opening controls, readable dark mobile layout and live switchboard updates.

The disposable tenant, users, sessions, native queue/agents, exact phone registrations, call records and private media were removed after review. Cleanup verified zero remaining fixture calls, contacts and domain-scoped rows. Private evidence is retained outside source and web roots. These checks do not qualify real carrier incoming delivery, emergency service, representative desk phones or locked physical handsets. No customer provider or PBX setting was changed by the fixture tests, and no phone result was marked confirmed automatically.
