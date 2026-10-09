# Moving SIP providers from 3CX to OpenWeb PBX

Keep the existing 3CX service available while preparing OpenWeb PBX. A restored
provider connection is configuration, not proof that incoming calls, outgoing
calls or audio work. Enable one reviewed connection at a time, with a rollback
plan and a provider-approved change window.

Select the correct tenant and PBX service before opening **Admin → Voice & Chat**.
The provider editor and incoming numbers belong to that service.

## Review the restore before a change

Read **Backup & Restore → Restore Report**. Resolve missing prompts and call-menu
destinations, select the intended voicemail greetings, and arrange replacements
for 3CX apps, account activation, email and office bridges. Recheck business hours,
queues, forwarding and the users who may make outside calls.

The inspected `20.0.9.995` backup contains 18 carrier connections and one 3CX
bridge. Its four missing audio files, two missing PIN-menu destinations and
replacement app/bridge work still prevent a blanket instruction to shut down
3CX. See [V20 restore](v20-restore.md) and [the roadmap](../3CX.md).

Before changing a working connection, keep private backups of both systems and
the OpenWeb application, database, configuration, keys and media. Record the
working provider settings, phone addresses and the steps to restore incoming
delivery. Keep credentials and customer numbers outside the public repository.

## Review each provider connection

Keep the trunk **Off** while reviewing its server, port, transport,
authentication, main number and caller ID. The editor retains registration
expiry, call limits, codec preferences, realm, authentication ID, From settings,
Contact settings and registrar/outbound proxies under Advanced. Retain the
restored values unless the provider requires a change.

Authentication and registration are separate settings:

| Provider arrangement | Authentication | Register with provider |
| --- | --- | --- |
| Registration-based account | Username/password | On, when the provider requires REGISTER |
| Call authentication without registration | Username/password | Off; the provider may challenge an INVITE |
| IP-authenticated connection | IP authentication | Off; the provider must accept this server's public address |

The inspected carrier configuration has ten registration-based connections,
three credential-based connections without registration, and five IP-based
connections. The bridge requires separate replacement work. Do not turn
registration on simply because credentials are present.

Ask the provider to confirm its approved signalling/audio addresses, transport,
caller-ID requirements and the destination server's public SIP/RTP addresses.
For IP authentication, arrange the provider's whitelist before calling. A server
that resolves in DNS may use different addresses to deliver incoming calls;
enter the provider-approved **Incoming provider IP addresses** explicitly.

In **Outbound Rules**, review rule order, department/user restrictions, number
lengths, prefixes, strip/prepend changes, caller ID and ordered backup providers.
Check the resulting dialled number with the provider. Review emergency routing
separately using the provider's approved procedure.

## Prepare incoming numbers

Keep incoming numbers off until their provider connection and ownership are
reviewed. Confirm the main number, declared DID numbers, destinations, business
hours and **Incoming number source**. Retain the imported To-header or Request-URI
selection unless a provider trace establishes a different format.

An exact DID takes priority over a suffix rule, and both take priority over that
provider's default destination. The default accepts the provider's declared
main/DID numbers; it does not accept arbitrary numbers. A connection without
declared numbers has no public default route. Matching also checks the enabled
provider, approved source addresses and any native provider binding. Ambiguous
ownership must be resolved before enabling overlapping routes. Two tenants
cannot enable the same incoming number on the same provider connection.

Changing provider addresses refreshes saved incoming checks. Turning a provider
off also turns its incoming numbers off. Recheck both lists after a change.

## Understand readiness results

**Check provider** checks DNS and, for TCP/TLS, the connection or certificate.
It sends no SIP registration or call; UDP results explain that signalling has
not been tested. The provider status reads the running PBX separately.

- **Off** means the provider is intentionally disabled.
- **Registered** means REGISTER succeeded. Calls and audio still need tests.
- **Configured** on a nonregistering provider means its native connection is
  loaded. Provider acceptance, incoming delivery and calls remain unverified.
- **Needs settings**, **Not connected** or **Connection failed** requires the
  displayed next action before proceeding.

A SIP response to an operator's OPTIONS probe confirms signalling reachability
only. DNS, TCP, TLS, OPTIONS and registration results cannot replace answered
call tests.

## Qualify and switch one connection

Arrange a provider-approved pilot and use permitted test endpoints and numbers.
If 3CX is currently registered, avoid registering the same account from OpenWeb
until the provider approves concurrent registration or the coordinated handover.
Confirm that the approved pilot actually uses the intended OpenWeb route.

Every preserved route candidate for the current permitted pilot requires
REGISTER. An IP-authenticated connection cannot verify that pilot's existing
route. Select one registration-based trunk and agree an explicit handover with
the provider and the operator of the active 3CX service. Record the account,
change window, expected incoming delivery and rollback steps privately. Disable
only that trunk's registration on 3CX before enabling it on OpenWeb, unless the
provider has explicitly approved concurrent registration. Keep the other 3CX
connections active until they have their own verified handover.

1. Verify internal calling and the pilot phone's new server/realm first.
2. At the agreed time, hand over only the selected provider's registration or
   incoming delivery. Confirm the previous registration is released or approved
   to coexist. Keep other working 3CX services available.
3. Enable the reviewed OpenWeb provider and selected incoming numbers.
4. Verify incoming and outgoing answered calls, caller-ID presentation, two-way
   audio and key presses. Record the codec actually selected by the provider and
   confirm the engine can decode and encode it for the phone's media path;
   a passthrough-only codec cannot transcode between different phone/provider
   codecs. Check busy, rejection and no-answer results.
5. Test hold, transfers, forwarding, voicemail and protected recordings. Exercise
   hours, queue/callback routing and a sustained call where applicable.
6. Test an unavailable first provider reaching the intended backup. Confirm that
   busy, no-answer and answered calls stop further attempts. Check each provider's
   error/rejection responses against the configured fallback policy; a retryable
   service failure may intentionally select the next provider.
7. Record results and repeat on each intended server platform and phone/network
   combination. Keep unqualified connections off.

Ensure only the intended PBX runs callbacks and other scheduled outside calls
during the change. A new administrator should not have to edit database records
to complete a normal cutover; the guided reconciliation workflow remains open
in RESTORE-04.

If qualification fails, turn off the selected OpenWeb incoming numbers and
provider, return incoming delivery/registration to the recorded working 3CX
configuration, and restore the pilot phones' previous server addresses. Confirm
calling on the original system before resuming the change. Avoid leaving both
systems placing the same scheduled calls.

## Verification state — 2026-10-08

The development source passes bounded parsing, complete provider-field mapping,
guarded reconciliation, tenant isolation and native transaction checks. A full
private-backup restore also passed. Existing-provider reconciliation defaults
to a dry run, refuses unexpected source identity/behavior changes, and retains
gateway identities, enablement, source-address bindings, users and media.

The production restore has received this guarded repair: 19 native gateways,
44 incoming XML/detail/provider bindings and 19 fallback-order corrections.
Stored credentials and identities were retained, and all customer connections
remain off. Configuration repair does not switch carrier traffic.
The subsequent production dry run reported zero changes to gateway fields,
policy, incoming XML, details, bindings and rule order.

An actual Debian FreeSWITCH test with isolated local providers passed outgoing
503-to-backup routing, stopping on 486 busy, number rewriting, caller ID,
dynamic Contact/RPID headers, a 407 authentication challenge without REGISTER,
intact PCMU/PCMA offers, PCMA negotiation and two-way RTP audio, using two actual
registered local phones. Durable callbacks to synthetic external numbers also
passed agent-first delivery, 503 provider fallback and fresh 407 authentication
without REGISTER. Both callback jobs completed with one attempt, a Connected
result and cleared leases; accepted hangup and native agent release passed.
Ordinary and callback transmit/receive streams sustained 30–70 negotiated RTP
packets per second, around the expected 50, over at least 20 packets.
Incoming delivery also passed when the DID was in the To header and the Request
URI contained a contact alias. Unknown numbers, wrong gateway bindings,
unapproved sources and disabled providers were rejected. Temporary providers,
phones, calls, jobs, XML/CDR files, domain media and native queue/agent/tier
objects were cleaned up. These are local engine results. The callback fixture
starts an already-leased durable job, then verifies Lua delivery and completion;
it does not repeat the C# worker's claim/dispatch checks.
An additional registration-only check tracked both original REGISTER Call-IDs
privately and confirmed that exact-ID cleanup removed both contacts; a new
expires=0 transaction alone can leave the original Sofia registration in place.
The policy suite passed 149 decisions, the mocked runtime suite passed 41 checks
and the actual native codec-parser regression passed six checks.

Nine configured SIP endpoints resolved; seven returned a SIP response to a
nonregistering probe and two timed out. One separately authorized,
registration-based carrier pilot then registered and answered a controlled
outgoing call. The 16-second call exchanged 765 sent and 797 received RTP
packets while transcoding carrier G729 to phone PCMU, without native audio
errors. The caller's confirmation that the message was audible is pending;
packet exchange alone does not confirm that result. The pilot was rolled back,
its original source-IP bindings were restored, all 19 customer connections are
off and the engine has no remaining pilot calls.

Full carrier qualification remains open: public-network incoming delivery,
DTMF, transfers, sustained-call stability, real carrier callbacks and caller
audibility still need verification. Windows qualification for these changes,
emergency routing, replacement calling apps and broad phone interoperability
also remain open. The published 1.0.2 archives do not yet include this
development work. CALL-01 and CALL-02 remain open in [the roadmap](../3CX.md).

Maintainer checks include `php tests/pbx_v20_trunks_integration.php`,
`php tests/pbx_trunk_refresh.php`, `php tests/pbx_trunk_admin_integration.php`,
`php tests/pbx_trunk_readiness.php`, `lua tests/pbx_call_policy.lua` and
`lua tests/pbx_route_runtime.lua` and `python3 tests/pbx_codec_native.py`.
`tests/sip_trunk_live.py` is an explicit,
actual-engine local-provider fixture; run it only with its documented opt-in
and local SIP-profile binding. It creates a separate temporary PBX and never
enables existing customer trunks.

## Answered calls disconnecting immediately — 1.0.5

A production attempt exposed a configuration conflict that registration checks
could not detect: both `mod_bcg729` and passthrough-only `mod_g729` loaded on startup.
The passthrough codec shadowed the converter after restart. The provider answered,
but the engine failed to decode its G.729 audio and immediately ended both call
legs. Keep only the reviewed converter enabled when conversion is required;
module presence alone does not establish that the active codec can process audio.
The Admin readiness check now rejects this conflict in either inventory order.

After removing the conflicting handler from the running engine and its persistent
startup file, a call through the owner-enabled provider to the authorized test
number answered and sustained 25.1 seconds, with 1,034 sent and 1,249 received RTP
packets and no native engine errors. The test caller ended it normally. Physical
handset audibility, public incoming calls and full provider acceptance remain
separate checks. Customer trunks, routes and credentials were preserved.

An independent voicemail defect also answered calls then returned immediately:
the restored handler passed `leave` to a native dispatcher that accepts `save`.
Version 1.0.5 corrects that action and retains `check` for mailbox login. Test
unregistered, busy and unanswered extensions as well as connected phones; a
successful internal bridge alone does not qualify the voicemail fallback.
