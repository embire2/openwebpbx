# Call Me Back and Speed Dial — Debian 1.0.24

**Live on call.openweb.co.za — 5 November 2026.** The hosted web app, native
Core and updater are all 1.0.24. Public Debian installers and Windows retain
their separately qualified versions; this feature deployment does not replace
a downloadable installer or Windows package. Source commit: `6471988d07d571e4277237318197a2650e4d2f49`.

## Choose the callback provider

Open **Call Me Back**, edit the service and choose **Callback SIP trunk**.
Select an enabled trunk or **Use normal outgoing call rules**.

The selected trunk calls the client back only. It uses that provider's existing
gateway authentication, transport, availability and caller-ID settings. It
does not change the trunk, incoming DID destination or outside-call rules.
The client's onward call still uses the normal permitted route and its normal
provider fallback. With an explicit callback choice, an unavailable selected
provider produces a clear failure instead of silently using another provider.
Without a choice, the original callback routing and fallback remain in use.

## Nine speed dials

In **Call Me Back → account → Speed Dial**, administrators can name and save
nine numbers, numbered **1–9**. A blank telephone number clears the slot.
Leading zeros are preserved. Numbers must contain 7–16 digits and may start
with `+`.

For self-service, link the account to an existing web user when editing it.
That user opens **My PBX → Speed Dial** and sees only their own nine slots.
An account has one explicitly linked web user, and one web user has one linked
callback account per tenant. Existing staff access and tenant suspension are
checked on each request. Staff cannot choose another account identifier to
edit its slots.

During an authenticated callback:

- Enter `1#` through `9#` to call a saved number.
- Enter `1*0317102222#` to save slot 1, then enter `1#` to call it.
- Enter `1*0#` to clear slot 1. The same pattern applies to slots 2–9.

External callback-only users can use this phone setup without a web account.
Configuration entries return to the number prompt; up to three entries are
accepted within the existing callback time limit. Saved numbers are checked
again against allowed prefixes and outside-call permissions when called.
They cannot bypass authentication, reservations, quotas or the ten-minute
connected-call limit. The administrator can include the instructions above
in the number prompt.

From a linked, authenticated PBX phone, dial `**1` through `**9`. These shortcuts
use the extension's ordinary outside-call permissions and providers; callback
trunk choices and callback minute reservations are not applied to ordinary PBX
calls. Ambiguous shared-extension account links are refused.

## Edit Keoma's script

In the service's **Keoma voice scripts** section, edit any of the nine steps:

| Step | Default script |
|---|---|
| First incoming call | Gooday, thank you for calling. You may now disconnect this call and we will call you back. Goodbye |
| Recognised incoming caller | Hello, you are already authenticated to use this service. We will now call you back. |
| Callback: ask for ID | Hello, this is {companyname} calling you back. You may now authenticate by entering your South African ID Number and press hash. |
| Authentication successful | You have successfully authenticated, in the future, you will not need to authenticate again. |
| Ask for the number / speed dial | Kindly enter the telephone number of the person you wish to call and press # |
| Authentication failed | We could not authenticate you. Please contact your service administrator. Goodbye. |
| Service unavailable | This service is not available at present. Please try again later. Goodbye. |
| Number unavailable | This number is not available through this service. Goodbye. |
| No minutes remaining | You have used your available calling minutes. Please contact your service administrator. Goodbye. |

Use plain text, up to 1,500 characters per step. `{companyname}` is the only
template placeholder. Each step shows its requested text, current recording
text and default. Keep prompts brief: existing authentication and call time
limits remain enforced.

**Record scripts with Keoma** submits changed text to the existing instance
Greetings service. The provider key stays on the server. Only the narration
text and company name are sent for synthesis; IDs, caller numbers and call
recordings are not sent. The existing Keoma voice and stock pack remain in use.
OpenWebPBX adds no generation fee; the instance's ElevenLabs usage terms and
charges apply.

New recordings receive unique Greeting IDs and paths. The previous ready
generation remains selected while replacement audio is prepared, and after a
provider, queue or file failure. Active script greetings cannot be archived
until their script assignment is replaced or reset. Other user recordings
are untouched.

**Reset Default Scripts** requires its confirmation checkbox. It removes the
service's text overrides and selects its original system/company prompts.
It does not overwrite or delete any recording. Existing custom company
recordings are retained; their transcripts cannot be reconstructed by reset.

## Deployment and verification

The additive schema component is
`app/pbx_setup/resources/call_me_back_124.sql`; the complete installation schema
contains the same component. Existing services retain their enabled states,
incoming destinations, account identities, saved caller authentication and
minute totals. The new gateway/user links start empty and new feature tables
start empty. Deployment must apply the component before activating the new PHP
and Lua leaves. The existing Greetings worker supplies audio without a new
worker protocol or a provider key in source.

The isolated PostgreSQL suite exercises actual owner and staff checks, route
preservation, nine-slot limits, immutable recording selection and reset.
Its full production-Lua scenarios use real PostgreSQL authorization, quota and
answer accounting with fixture SIP endpoints: selected callback provider,
unchanged onward provider, provider caller ID, DTMF save/call and unavailable
selected provider. These software controls do not establish new carrier or
physical-phone acceptance. No real customer calls are placed by the tests.

## Hosted verification

190 PostgreSQL/production-Lua/UI and regression controls pass; an independent
63-control run also passes. The live HTTPS interface passes 75 checks. One
ordinary Keoma text job completes through the existing background worker in
6.153 seconds; its WAV is verified, then the unassigned test greeting is
archived through the normal interface. Archive retains that test audio under
the normal retention policy. Custom customer audio is preserved.

The matching native Core/updater builds contain unchanged qualified calling
code with version 1.0.24 metadata. After deployment, both processes remain
stable for 91.9 seconds with no further restarts. Existing runtime/private
configuration and 32 captured phone, route, QR and account projections remain
exact; FreeSWITCH and nginx keep their original process generations. Actual
external-provider callback calls are a separate deployment check and are not
claimed by the isolated two-leg tests.
