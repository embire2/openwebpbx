# Queue callbacks and Hotel Services

## Queue callbacks

Open **Admin → Call Handling → Call Queues**, select a queue and choose a callback option:

- **Off**: callers keep waiting or reach the queue's usual timeout destination.
- **Caller requests a callback**: the caller presses 2 while waiting.
- **Offer after waiting**: after the selected time, the caller can press 2 for a callback or 1 to continue waiting.
- **Automatic after waiting**: after the selected time, save the request and end the waiting call.

Set the waiting time, attempt limit and any prefix required by your outgoing rules. Outside callbacks need a working enabled provider, a valid caller number and an outgoing rule that permits that number for the selected agent. A number supplied by an outside caller cannot be used to call an internal extension or feature code.

The background service calls an available, registered agent first. After the agent answers, it calls the waiting caller and connects the two. It respects office hours, agent status, wrap-up time and recording settings. Requests survive a service restart. Interrupted attempts are checked against active calls before retrying. Repeated requests for the same queue and number are combined while a request is active.

Open **Queue Callbacks** to see results, cancel a waiting request or retry a failed one. Calls already connected are not disconnected by the Cancel button. Attempts are bounded; a request expires after one day. Waiting for office hours or an available agent does not consume an attempt.

Live waiting calls have priority over callbacks. This release does not preserve a callback's exact position among live queue callers. Provider route failover and outside carrier calling require further tests; this release's callback audio checks used internal test phones.

## Hotel Services

Create a user for each room phone, then open **Admin → Hotel Services → Add Room**. Select the phone and enter the room name.

**Check In** assigns the guest. **Check Out** clears the guest, marks the room Dirty and cancels pending wake-up calls. Both actions clear the room's voicemail message indexes, reset the active greeting and generate a new voicemail PIN. Retrieve the current PIN through the room user's protected **Phone Settings** action. Audio files remain in private storage under the operator's retention policy.

Vacant rooms cannot place outside calls or use voicemail. Internal calling remains available. **Do Not Disturb** sends calls to voicemail while the room is occupied. Room status can be Clean, Dirty, Inspected or Maintenance. Each change is recorded in Recent Activity.

Schedule a **Wake-up Call** using the room's date, time and timezone. Guests hear the announcement and press 1 to confirm. Unanswered or unconfirmed calls are retried up to three times during the twenty-minute delivery window. **Wake-up Calls** shows the result. A checked-out room cannot receive a newly scheduled wake-up call.

PMS/Fidelio integration, automatic call charging, minibar billing and room-status entry from a handset are not implemented in 1.0.2. These are separate from the room-management and wake-up features above.

## Operations

The .NET service binds its readiness endpoint to `127.0.0.1:8087` only. It uses the existing PBX database and local call engine. On Debian its service name is `openwebpbx`; on Windows it is `OpenWebPBX`. The web application's authentication, tenant checks and form tokens protect all administration actions.

The private service configuration is `/etc/openwebpbx/runtime.json` on Debian and `%ProgramData%\OpenWebPBX\runtime.json` on Windows. Installer-generated configuration contains secrets and must not be copied into the web directory or public repository.
