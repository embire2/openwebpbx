# SIP trunk options and ring-group ringing

Open **Admin → Voice & Chat → your SIP trunk → Options**. The incoming destination remains under **Incoming Calls** on the same page. These controls belong to the selected PBX; they do not change another tenant or a phone’s username/password.

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

The ringback correction is installed on the hosted Debian instance. Independent software-call tests decoded UK ringing before answer in both a direct group call with member early media and a transfer from an answered receptionist; both directions of answered audio passed. Existing customer media, restored phone credentials and registrations were preserved. These tests do not establish a new physical-handset or customer-carrier audio result.

Options and complete server **1.0.20** remain under qualification until the release is published. Native provider-leg capacity, failed-attempt release and tenant isolation have been tested separately from real carrier acceptance. Consult [feature coverage](feature-coverage.md) and the release notes for final installer, updater and Windows status. Android remains **1.0.18/code118**.
