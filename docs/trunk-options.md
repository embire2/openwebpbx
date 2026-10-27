# SIP trunk options and ring-group ringing

Open **Admin → Voice & Chat → your SIP trunk → Options**. The incoming destination remains under **Incoming Calls** on the same page. These controls belong to the selected PBX; they do not change another tenant or a phone’s username/password.

## Add an incoming number

Open **Admin → Voice & Chat → your SIP trunk → Incoming Calls → Add DID Number**. Enter the number supplied by the provider, an optional friendly name and who should receive its calls. Spaces, brackets and dashes are removed; a leading `00` becomes `+`. Use the form your provider delivers: the PBX does not guess a country code.

**Accept incoming calls now** is selected for a connected trunk. Otherwise save the number switched off and connect the provider before enabling it. New numbers initially use their selected destination all day; configure their office hours in the existing routing controls after saving. The provider must already deliver the number to this trunk.

Select **Set up Call Me Back for this number next** to open its setup form with the new number selected. Until Call Me Back is ready and explicitly enabled, the number keeps the normal destination you chose. A number already assigned to a callback service remains available while editing that service and cannot create a second service.

Adding a number does not change provider passwords, registration, source-address controls, outgoing routes, phone credentials or calls in progress. Duplicate explicit routes are refused; imported overlapping wildcard routes must be reviewed instead of duplicated.

## Calling permissions and capacity

**Limit Outgoing Use To** chooses System Wide or one department. A department’s primary and secondary members can use the trunk. **Allow Inbound Calls** and **Allow Outbound Calls** control new calls in their respective direction. Disabling incoming permission does not delete the number’s saved route.

**Number of Simultaneous Calls Per Trunk** is shared by incoming and outgoing provider legs. The calling service releases a slot when that leg ends, including a failed attempt. A full or failed provider can follow the existing saved backup-provider order. Changing the limit does not disconnect calls already in progress.

Existing trunks retain their previous calling behavior until an owner saves Options for that trunk. The form explains this first activation; it enables the new permissions and shared capacity protection using the displayed values. The restored limit alone did not previously enforce this new shared policy.

## Provider connection

Choose **UDP**, **TCP** or **TLS** as supplied by the provider. **Re-Register Timeout** controls registration refresh, and **Alternative Proxy** optionally supplies a host name or IP address with a port. Leave the proxy empty to use the provider. Saving policy settings alone does not restart the connection.

Changing transport, proxy or registration timeout on an enabled connection requires explicit confirmation and no current calls. Only the selected gateway is refreshed. If its refresh cannot complete, the form keeps a visible pending message so an owner can retry; a saved form is not proof of successful registration. The normal provider checks remain necessary.

**Secure Audio (SRTP)** offers Automatic, Disabled, Optional and Required. Automatic retains the existing provider-leg media choice. Requiring secure audio refuses a provider that cannot negotiate it. **Support Re-Invite** controls provider-side renegotiation, including hold/resume; leave it enabled unless the provider requires otherwise. These options do not weaken the separate Android phone leg.

**PBX Delivers Audio** stays enabled. Provider audio passes through the PBX for remote phones, recording and hold music. Shared network addresses, address-family selection, provider video, Replaces, carrier transfers and header behavior are described under **Managed Connection Settings**. They are not represented as editable controls when this release cannot safely change them per trunk. This page does not claim every proprietary 3CX option is implemented.

## Ring groups

When routing a call to a Ring Group, the caller hears the UK ringing cadence while its phones are being offered the call. This also applies after an answered Digital Receptionist or transfer, and ignores early audio from group members during ringing. Answered conversation then passes through normally. Actual hold still uses the selected hold music.

The group’s configured timeout and no-answer destination remain in effect. A queue selected as that later destination can play its own queue music after the group times out; it does not replace ringback while the group is ringing. Member availability and office-hours rules continue to apply.

## Release and verification status

The ringback correction is installed on the hosted Debian instance. Independent software-call tests decoded UK ringing before answer in both a direct group call with member early media and a transfer from an answered receptionist; both directions of answered audio passed. Existing customer media, restored phone credentials and registrations were preserved. A separate completed incoming provider call after activation also produced eight decoded UK ringback windows at the PBX’s outgoing media interface; no packets or audio files were retained. This does not establish what a physical handset played or a new answered carrier-audio result.

Options and Add DID are included in complete server **1.0.21** for Debian 13 and Windows Server 2025. Use the [release qualification](release-1.0.21-qualification.md) and matching installation guide. Native provider-leg capacity, failed-attempt release and tenant isolation are tested separately from real carrier acceptance. Consult [feature coverage](feature-coverage.md) for remaining deployment checks. Android remains **1.0.19/code119**.
