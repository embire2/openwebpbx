# Move existing Yealink and Fanvil phones

OpenWeb PBX preserves the extension number, separate Authentication ID and SIP password from the supported 3CX V20 backup. An extension number and Authentication ID can be different; keep both exactly as they are. Do not factory-reset the phones.

The verified backup format is **3CX 20.0.9.995**. Other builds require a checked adapter. A successful restore is not evidence that a carrier or a physical handset has passed a call test.

## Restore once

1. Open **Admin → Backup & Restore** and upload the backup.
2. Confirm the company, timezone and **Phone domain**. Point that domain to the OpenWeb PBX server before moving phones. A hosted installation can assign an address automatically when the instance administrator has configured a managed phone-domain suffix.
3. Review **Dashboard → Restore Report**. Referenced files missing from the backup, missing destinations and unsupported connections are listed explicitly.
4. Open **Phones** to see the selected address. For an existing PBX, **Change phone domain** adds an owned address while retaining the PBX's call routes and existing mobile-app accounts.
5. Review **Voice & Chat → First Call Checklist**. At the arranged handover time, **Connect Provider and Numbers** enables that reviewed provider and its saved incoming routes together. Their destinations, outgoing rules and opening hours are retained. Imported connections and incoming numbers start off to avoid taking calls away from an existing PBX during restore.

Keep a backup of the phone's existing configuration. Use one phone first, then move the remaining phones after its calls pass.

## Yealink W60B

The W60B is the base station. Open its local web administration page and select the existing account for the handset being moved. In that account, replace the old 3CX hostname with the address shown in **OpenWeb PBX → Admin → Phones**.

Keep the account's User Name, Register Name/Authentication ID, password, server port, transport, registration interval, codecs, handset assignments and dial plan. If an outbound proxy or a second server address contains the same old 3CX hostname, replace that hostname too; retain its other settings. Save the account and confirm that it registers.

The manufacturer's [SIP account configuration guide](https://support.yealink.com/docs/faq/sip-account-configuration/7da55209fa774e3f996e439fdc9833f8) and [W60B/W60P administrator manual](https://www.yealink.com/upfiles/products/201809/1536559648392.pdf) cover the separate account and server fields. Their labels can vary with firmware.

## Fanvil V62W

Open the phone's local web administration page and select its existing SIP line. Replace the old 3CX hostname in the SIP server address with the address shown in **OpenWeb PBX → Admin → Phones**. Replace a matching old hostname in the SIP domain/realm or outbound proxy if those fields are explicitly set.

Keep the SIP user/extension, Authentication User/ID, password, server port, transport, registration interval, audio formats, Wi-Fi settings and local dial plan. Save the line and confirm that it registers. Fanvil publishes the V62W's instructions on its [official manual page](https://www.fanvil.com/service/doc/file/p1/v%20seri/v62w/index.html); labels depend on firmware.

## Confirm calls before moving the rest

For the first phone, check:

- A call to another extension and a call back, with sound both ways.
- Each ring group and queue it uses, including no-answer routing and agent sign-in.
- Hold, the selected hold music, resume and transfer.
- Incoming and outgoing carrier calls, correct caller ID and voicemail.
- Its normal office-hours and closed-hours destination.

If the phone fails to register, check the address, existing connection type and port, and that the Authentication ID was not replaced with the extension number. **Admin → Users → Phone Provisioning** shows the restored values privately to an authorized administrator. Do not reset passwords as a troubleshooting shortcut.

If registration works but a queue does not ring the phone, check the user's restored status and queue sign-in. Restore retains these settings; it does not automatically sign everyone into every queue.

Phones still receiving automatic provisioning from 3CX can have manual edits overwritten. Retain their existing configuration export, and move or disable the old provisioning source before declaring the handover complete. A 3CX provisioning URL, SBC, tunnel, proprietary application or proprietary phone-button action requires its own replacement; a hostname edit cannot replace those services.

## What is qualified

The candidate server has passed all 23 original SIP identity/password combinations over UDP, TCP and TLS, including separate Authentication IDs, refresh, unregister and exact ownership of a new phone address. Physical W60B and V62W firmware, each site's router/NAT behavior and customer carrier calls still require the checks above. The backup contains only two phone-setting records; it does not describe every physical handset or its active port/transport. Keep the settings on the actual phone when those values are absent.

The 3CX Android app is not supported by OpenWeb PBX. Use the native OpenWeb PBX Android app and the extension's setup QR code. Existing OpenWeb Android accounts keep their canonical account domain when an additional desk-phone address is added.

## Guided handover in 1.0.15

**Admin → Phones → Move Your Phones** records the move of each Yealink W60B account or Fanvil V62W SIP line. New supported restores seal a proof of each original extension, authentication ID and password. For an older restore, upload its original backup in **Check Original Backup Credentials**. This comparison changes no credentials, routes or provider enablement.

1. Enter the phone's actual model, firmware, account/line, current domain, port and connection type. Review old 3CX provisioning/RPS/DHCP settings so they cannot overwrite the move.
2. Optionally upload a complete unmasked phone configuration export. The download changes only the selected account's matching old SIP server/domain/proxy hostnames. It preserves credentials, ports, other accounts and unrelated settings byte for byte. Encrypted, unfamiliar, masked or mismatched exports are refused. Use the displayed manual domain change instead.
3. Keep the original export for rollback. Stored exports are encrypted with the instance key; authenticated, CSRF-protected downloads expire after 48 hours. Changed credentials, phone domain or call settings invalidate an old preparation.
4. Test internal calls in both directions, outside calls in both directions, hold/music/resume, transfer, a ring group/queue and voicemail. Link each confirmation to an answered call made after preparation. Confirm the actual physical phone and the expected audio. Registration alone does not complete this checklist.

The original Restore Report stays visible. An explicitly accepted source-data limitation records its explanation without claiming that the missing behavior now works. Replace missing prompts and choose an active greeting where the backup omitted that choice.

**Verification boundary, 2026-10-16:** 23 original backup extension/authentication/password tuples registered successfully on a new owned SIP domain using software phones. Vendor configuration preservation and encrypted-export tests passed. The actual W60B and V62W are unavailable; physical firmware, audio, buttons and provisioning behavior remain **awaiting handset access**, with no physical-device pass recorded. Domain-only migration also requires the existing port/transport to be supported and reachable and any required TLS certificate to cover the new name.
