# Local Debian 1.0.23: DID routing

This candidate is deployed only on `call.openweb.co.za`. GitHub commits, releases, tags, public assets and signed feeds are unchanged. The public Debian/Windows downloads remain1.0.22; Android remains1.0.19. Local Core, updater and Admin report1.0.23. Windows qualification and publication of this candidate are separate future work.

## Manage a number

Open **Admin → Voice & Chat → your trunk → Incoming Calls**, then choose **Add DID Number** or **Edit**. Both lead to the same wizard at `/app/pbx_setup/?view=incoming`:

1. Enter the telephone number, provider and optional name.
2. Choose the destination. External forwarding, extensions, voicemail, ring groups, queues, digital receptionists and Call Me Back are supported. Use All day, or optionally choose office hours and a closed-hours destination.
3. Review the number, provider, destination, schedule and incoming-call status, then save.

The DID list and trunk page show the current destination. Trunk pages no longer contain a second editable route/add form. Existing holiday routes are retained during a basic edit and shown clearly. Concurrent edits require refreshing rather than overwriting another saved route. Duplicate numbers are rejected, including their known international forms and disabled reservations.

Choose **Call Me Back (set up)** to continue into its company/account setup. Existing normal routing stays in place; new setup numbers stay off. After its greeting and accounts are ready, select the named service in the DID wizard. Callback configuration has no separate incoming-routing toggle. Existing user allowances, authentication and calling permissions continue to apply.

## Confirmed Switchtel correction

The test call at18:03 SAST arrived from the bound Switchtel gateway/IP with `To: +27800014509`. The explicit route expected `0800014509`, and its inherited provider inventory incorrectly listed `08000014509`. Neither number condition matched; the actual call ended UNALLOCATED_NUMBER. The older fallback destination was extension1000.

The single canonical DID0800014509 now accepts the observed international form and forwards to0317102222 all day. The incorrect extra-zero inventory entry is removed. The provider pilot0875500273 keeps its own existing destination. Country calling code27 is explicitly configured for this South African PBX, so future wizard saves generate the corresponding local/international forms. Unconfigured countries keep exact matching. Gateway ownership and provider-address checks remain enforced; arbitrary zeros, wildcards or similar-looking numbers are not inferred.

A disabled DID retains ownership of its number forms and cannot fall through to another provider destination. The stored rule is the source of routing settings; native dialplan/destination rows are generated from it.

## Verification and preservation

- 183 controls on a disposable PostgreSQL cluster cover owner/tenant boundaries, revisions, duplicates, number forms, callback handoff, hours and native gateway/phone preservation.
- 235 Lua decisions cover matching, disabled ownership, provider guards and existing call policies.
- Six read-only decisions in the actual installed FreeSWITCH Lua/current database select the canonical rule uniquely for local/international forms, reject foreign provider bindings and find the outgoing route for0317102222. This check originates no call.
- Twenty browser checks cover normal owner authentication, actual CSRF-protected saves, current destinations, the callback setup handoff,390px layout and normal logout. Final page/console errors are zero. Earlier QA selector/module/logout-path refusals remain retained separately.
- The native XML accepts both intended forms and rejects the incorrect extra-zero number. Existing extension/gateway credentials, other routes, private keys, stable QR codes and mobile-device credentials are preserved. A fresh encrypted328-file configuration/database backup verifies before deployment. The call engine is not restarted.

**Answered carrier-call/two-way-audio confirmation after the fix remains pending.** Route selection and browser checks do not establish an answered external call.

Private source/payload hashes, deployment snapshots, backups and test receipts are retained under `/var/lib/openwebpbx/did123-9a5fb5b5d6194344adf3d0dc155bfa52`. Keep passphrases, user snapshots and QR material private. Local binaries are ready for testing; this record does not authorize publishing a release or update feed.
