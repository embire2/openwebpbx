# Call Me Back

Status: included in Debian 1.0.16, with earlier isolated native calling qualification and current full-package installation/update/restore checks. No hosted customer number is enabled automatically. Enable only an explicitly selected incoming number after its controlled carrier checks.

## Set up a service

Open **Admin → Call Handling → Call Me Back**. Create a service using the company name callers should hear, an existing individual incoming number, and an enabled user whose ordinary outgoing permissions apply. Save it switched off while its named Nathaniel greeting is generated. After the greeting is ready, explicitly confirm the incoming-number handover and enable the service.

Create **Call Me Back accounts** with the account holder's name, a valid South African ID number and their total minute allowance. The ID entry is hidden, is never shown again, and is not stored as plaintext. Administrators can change the allowance, disable an account, revoke a saved caller, or delete the account's identity after its active calls finish.

The initial announcement is:

> Gooday, thank you for calling. You may now disconnect this call and we will call you back. Goodbye.

The server ends that incoming call before releasing its callback request. The durable worker normally dispatches the request on its next one-second cycle. It calls the original caller number, never a different number entered by the caller.

A new caller hears:

> Hello, this is {tenantname} calling you back. You may now authenticate by entering your South African ID Number and press #.

A matching enabled account is bound to the answered callback number. The caller then hears:

> You have successfully authenticated, in the future, you will not need to authenticate again.

The caller enters the destination number followed by #. The server connects the calls using the chosen user's existing outgoing rules, provider availability and failover policy. Internal extensions, feature codes, emergency shortcuts and numbers outside the service's allowed prefixes cannot be dialled through this service.

When a bound caller calls again, the incoming announcement says:

> Hello, you are already authenticated to use this service. We will now call you back.

That call disconnects. The subsequent callback goes directly to:

> Kindly enter the telephone number of the person you wish to call and press #.

The service does not ask a recognised caller to repeat their ID because their quota is exhausted or another call is using their account. A first-time caller who enters the correct ID also receives an allowance or availability message in those cases, without an incorrect-ID penalty. A saved binding is created when authentication and a usable allowance are granted.

## Minutes and safeguards

The allowance is a lifetime total of the destination’s answered call time, counted in seconds and rounded up once per call. It does not count the identification announcement, destination ringing or the carrier's separate charges for two outside legs. Adding allowance increases the lifetime total; it does not reset prior usage. The editor refuses a total below already used plus reserved time.

A transaction reserves at most **600 seconds** before destination dialling. One account can have only one active authenticated call. A destination's actual answer starts independent native engine cutoffs for both legs before any database operation, so an accounting lock cannot extend the permitted call. Each conversation ends after ten minutes, or sooner when the account has fewer seconds left. Completion debits the observed destination answer duration once and returns the unused reservation.

Requests and usage survive a worker restart. A request is never silently redialled after an uncertain launch. Recovery checks both owned call UUIDs; an ambiguous engine response retains the reservation. If a crashed interpreter cannot prove the final duration, recovery charges the bounded reservation and records **interrupted_review_usage** for administrator review. This deliberately prevents a restart from granting free unmetered calls; the displayed total can require review after an interrupted call.

The callback accepts normalised South African mobile/landline/VoIP caller numbers only. National `0…`, `27…` and `+27…` forms share a `+27…` binding. Anonymous, malformed, international and `086…` shared-cost caller numbers are refused. The ordinary tenant route must still permit the callback leg. International destination calling requires an explicitly allowed prefix and a matching ordinary outgoing rule; DTMF callers use the configured `00…` format.

The defaults are 30 requests per hour per service, at most four pending/active requests across the tenant, one new request per caller per minute, and a fifteen-minute lockout after three failed identification callbacks. Request expiry, bounded ringing, bounded ID attempts and a short pre-bridge safety timer limit unpaid callback/authentication time. A caller must actually answer the callback before identification or reuse of their saved binding. Spoofing an incoming CLI therefore does not give the spoofer a connected outside call; it can still cause an unwanted callback, which the limits mitigate.

## Voice generation and private configuration

Voice-pack **1.0.1** supplies the fixed announcements. The named tenant greeting uses saved British Nathaniel voice `7S3KNdLDL7aRgBVRQb1z` through ElevenLabs, with `eleven_multilingual_v2`. Generation runs in its own hosted worker, so a slow provider never delays callback dispatch.

An instance administrator supplies a licensed ElevenLabs key in the protected runtime configuration as `ElevenLabs:ApiKey`. No key is included in a public package, web form, source file or generated voice archive. Independently installed instances need their own account access to the selected voice. Without a usable key, the greeting remains pending or failed and the service cannot be enabled. Saving a failed service switched off requests generation again. Changing the company name disables the service and requires a newly sealed greeting before re-enabling.

Only the system script and tenant display name are sent for generation. Caller numbers, ID digits, conversations, recordings and customer backups are not sent. Generated named greetings live in the private PBX storage subtree `openwebpbx/call-me-back/<service UUID>/greeting.wav`. Debian's narrow service drop-in permits writes only to that subtree in addition to existing worker paths. The Windows worker uses the corresponding protected ProgramData storage path.

## Identity, deletion and retention

Each ID is validated for thirteen digits, date, citizenship/status positions and checksum. Matching uses HMAC-SHA-256 with a tenant-derived secret from the existing private, 32-byte `openweb-template.key`. The database retains only that keyed verifier and the last four ID digits. The DTMF input is confined to the interpreter, with native sensitive-DTMF handling and no plaintext channel variable or regex debug output. A missing private key refuses callbacks; restore must preserve the original key alongside the database.

A saved caller binding persists until the owner revokes it or disables/deletes the account. The owner should revoke numbers that are reassigned, shared or no longer controlled by the account holder. A number cannot silently be rebound to another account by entering a different ID. Account and request foreign keys include the domain and service to enforce tenant ownership.

Completed callback requests and revoked bindings are retained for the service's selected period, initially **90 days**, adjustable between 7 and 3,650 days. Cumulative account usage remains for allowance enforcement. Mutation audit records contain action, actor UUID, subject UUID and timestamp, with no ID digits or caller number, and expire after 365 days.

**Delete account identity** removes its name, verifier, last four digits, caller bindings and linked callback-request caller numbers. It retains cumulative totals and usage records under the PBX retention policy. These records can still correlate with ordinary PBX call records; they are not asserted to be anonymous. Standard PBX call records, recordings, exported reports and encrypted backup retention require the operator's separate privacy process. Existing encrypted database/configuration/media backups cover the callback tables, private authentication key and stored greetings; Debian 1.0.16 clean-server encrypted restore preserved the disabled service, its private authentication key and genuine named greeting exactly.

## Qualification boundaries

Tests use fictional tenants and loopback SIP providers in an isolated Debian network namespace. They do not establish real-carrier billing, caller-ID delivery, handset behaviour or public-network availability. See the private qualification facts referenced in development notes for the exact source/build and observed cases. Do not enable a customer DID until its tenant and number have been selected, its routes/greeting/accounts are ready, and its controlled carrier handover is authorised.


### Recorded software qualification — 2026-10-17

The frozen runtime at `9b48dd897` passed nine actual SIP/RFC2833/decoded-RTP cases with fictional tenants and two loopback providers: correct first-time ID with no allowance, incorrect ID, successful first-time authentication, saved-number reuse, a caller hanging up during the initial announcement, five seconds remaining with a three-second database lock at destination answer, three seconds remaining, exhausted saved authentication without another ID request, and the full 600-second limit.

The full-limit call ended both legs **599.76 seconds** after the destination's SIP answer, charged **600 seconds once**, and released the reservation. The five-second locked-accounting case ended after **4.60 seconds** despite the three-second accounting lock. Decoded cross-leg tone identity was **0.9998** in both directions. Engine scheduling uses whole seconds, so measured durations can finish slightly before the nominal boundary; neither test exceeded its allowance.

A subsequent one-condition correction limits timer cleanup to the invocation that actually claimed its request. Eight actual-Lua ownership controls and a separate native duplicate-delivery test qualify that correction. The duplicate invocation preserved exactly two live call legs and both native cutoffs; the original three-second call ended after **2.61 seconds**, charged three seconds once, and released its reservation. This does not relabel the earlier ten-minute test as a complete post-correction run.

An independent review repeated **323** scoped SQL/Lua/C# controls across ownership/admin boundaries, concurrent tenant/service limits, reservations/settlement, HMAC matching, audio activation, authentication errors, recovery and pre-database timer order. These include actual PostgreSQL, source-executing Lua and an actual-worker harness with a controlled local event socket; they are distinct from the native timing/media cases. The callback dispatcher/prompt workers also passed fourteen focused .NET/PostgreSQL/HTTP protocol controls. A real ElevenLabs HTTPS request through the production prompt-worker source generated the fictional tenant greeting, which the final native duplicate test played. Thirty responsive admin layouts passed.

The private qualification database was separate from the fixture's original database. All **157 original table multisets** remained exact. Cleanup verified zero owned calls, contacts and timers, removed the new database and restored ten sealed original configuration/runtime files. The owned container and isolated PostgreSQL cluster were stopped. Twelve actual engine log/runtime-database files contained neither full fictional test ID. This is scoped log evidence, not a proof that third-party carrier equipment never retains key presses.

Private evidence is retained under `/var/lib/openwebpbx/cmb-work/` and `/var/lib/openwebpbx/cmb-runtime-review-20261017/`. The final source/build bindings, nine-case native results, duplicate test, actual-provider generation, preservation and restoration facts are recorded separately. Earlier incomplete fixture/observer runs remain retained with their original outcomes.

Debian 1.0.16 now includes the verified voice pack and completed fresh-install, installed-updater, recovery and separate clean-server encrypted restore checks. The restored disabled service, private authentication key and genuine named greeting were preserved; no customer number was enabled. The nine native callback cases above were not rerun as a new carrier test. Windows runtime/media/installer acceptance and controlled real-carrier/DID handover remain open. See [release qualification](release-1.0.16-qualification.md).
