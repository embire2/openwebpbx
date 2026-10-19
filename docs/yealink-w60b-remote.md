# Yealink W60B phones outside the office

Use the tenant's assigned SIP address. For the hosted OpenWeb tenant, this is **openweb.sip.openwebpbx.com**. The tenant's browser address, `https://openweb.openwebpbx.com/admin`, is separate.

The hosted three-phone registration and server checks do not qualify every W60B firmware, router or handset. A base station's SIP ringing response does not prove its cordless handset rings or that a person hears audio. Finish the answered-call checks below.

The hosted STUN endpoint was activated on **19 October2026** and verified from an external Windows server using both current and older Binding requests. The setting below is ready to use for this instance. Current source includes the optional Debian installer; immutable1.0.16 packages have not been replaced.

The PBX now explicitly delivers audio through the server and generates audible ringback when a destination signals ringing. The three enabled providers' restored incoming rules are active. Provider announcements, saved office-hours routes and phone credentials remain in place. Software-call audio passed; physical handset checks below remain required. [Call progress and private diagnostics](call-diagnostics.md).

## Phone settings

For the existing International Lighting accounts, preserve the restored extension, Register Name and password. Do not enter the Android app password as the desk-phone password. The current accounts register over UDP on port5060.

| W60B setting | Hosted OpenWeb value |
|---|---|
| Account → Register → SIP Server 1 → Server Host | `openweb.sip.openwebpbx.com` |
| SIP Server port / Transport | `5060` / `UDP` for these existing accounts |
| Enable Outbound Proxy Server | Enabled |
| Outbound Proxy Server 1 / Port | `openweb.sip.openwebpbx.com` / `5060` |
| User Name | The user's extension, such as `1050` |
| Register Name / Password | Original restored Authentication ID / SIP password |
| Network → NAT → STUN → Active | Enabled when using STUN |
| STUN Server / Port | `openweb.sip.openwebpbx.com` / `3478` |
| Account → Register → NAT | STUN when using STUN; the global setting must also be enabled |
| Account → Advanced → Keep Alive | Keep enabled; SIP OPTIONS /30seconds is suitable for checking this deployment |
| Account → Advanced → RPort | Enabled; use the appropriate received-address option where offered by firmware |

Yealink documents a separate global STUN server setting and per-account NAT choice. Merely entering an outbound proxy does not enable STUN. Different firmware may use slightly different labels. The PBX's managed STUN service uses UDP3478 and does not change SIP credentials. See [installation and scope](stun.md).

On **Account → Number Assignment → Incoming lines**, check the extension's account against the handset that should ring. Check **Outgoing lines** and its default account too. On a cordless handset, also check Do Not Disturb, ringer volume, registration to the base and power. The existing shared accounts and handset assignments should be reviewed rather than reset.

## Firewalls and CGNAT

The phone starts connections to the public PBX; keep-alives maintain the router's return path. STUN reports the public mapping. The PBX keeps call audio through its media service and learns the phone's actual return address; it does not require two customers' private phones to contact each other directly.

STUN alone cannot guarantee service through symmetric CGNAT, a firewall blocking required traffic, or a SIP-altering router. An authenticated media relay or a controlled VPN may be necessary for those networks. The managed STUN-only service does not supply TURN. Do not expose a handset's administration page or disable the customer's firewall to make a call work.

## Verify a phone

1. Confirm the account is Registered and the correct extension shows Online in **Admin → Users**.
2. Call the extension from another extension. Confirm the physical handset rings, answer it and check speech both ways.
3. Call back from that handset. Confirm the correct account is used and check speech both ways.
4. Make and receive an approved outside call. Check caller ID, sound, hold/resume and hangup.
5. Leave the phone idle, repeat an incoming call, then repeat after a controlled router reconnection. Registration alone does not complete these checks.

For after-hours internal calls, enable **Users → user → Call Forwarding → Allow internal calls outside office hours**. Outside-number office hours and manually chosen Away/Do Not Disturb statuses continue to apply. Ring time and no-answer forwarding are separate settings.

## References

- [Yealink W60P/W60B administrator guide](https://support.yealink.com/de-de/docs/w56p-w60b-w56h/yealink-w60p-dect-ip-telefon-administratorhandbuch-v81-31-pdf/36fa6f8b81f644729ab5e2776cc87b21): NAT/STUN, ports and keep-alives.
- [Yealink DECT phone user guide](https://support-cdn.yealink.com/attachment/upload/attachment/2018-4-18/3/cb051c9c-365f-4c58-aa70-0935a6ecdd4c/Yealink_DECT_Desk_Phone_User_Guide_V82_40.pdf): separate incoming/outgoing handset assignments.
- [FreeSWITCH media handling](https://developer.signalwire.com/freeswitch/media-and-codecs/handling/): early media, anchored audio and NAT address adjustment.
