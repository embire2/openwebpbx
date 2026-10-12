# Incoming-call wake-up for Android

The 1.0.9 candidate adds optional native incoming-call wake-up. The public release remains 1.0.7 until 1.0.9 is published. Keep the phone's connection notification running and qualify your actual devices before depending on wake-up. Locked and idle physical handset delivery has not yet passed release qualification.

Automatic setup creates a stable P-256 VAPID identity on the PBX. No Firebase project, Google developer account or uploaded Google configuration is needed. The Android app uses the open-source UnifiedPush connector 3.3.5 and embedded FCM distributor 3.0.0. The latter uses Google Play Services already installed on a supported phone; no Google Firebase client SDK is bundled in this app. This is the native delivery channel described by [UnifiedPush's implementation guide](https://unifiedpush.org/developers/implementations/). The candidate currently accepts that distributor's `fcm.googleapis.com/fcm/send/` endpoints; another UnifiedPush distributor is not qualified or selectable.

## Enable automatic setup

1. Install the matching 1.0.9 server and Android app, and connect the phone with its one-use QR code as described in [the Android guide](android.md).
2. As the instance administrator, open **System → Incoming Call Wake-up**. Enable **incoming wake-up**, choose **This PBX server**, and save. This automatically generates the instance's keys; it does not change SIP or provider configuration.
3. Open the app, then use **Settings → More → Check connection** to refresh the account and register its wake-up endpoint. Allow notifications and microphone access. If Android offers incoming full-screen notification access, allow it when that behavior is wanted.
4. Check that the phone reports **Incoming wake-up is connected**. Saved server settings indicate that the channel is configured; they do not establish that an individual phone can receive it.

The PBX needs trusted HTTPS reachable from the phone, a running background service, and outbound HTTPS to the push endpoint. The phone needs internet access and working Google Play Services for this embedded channel. Ordinary calling continues independently when the optional channel is disabled or unavailable. Wake-up does not bypass Do Not Disturb, office hours, forwarding, queue membership or the PBX's normal call policy.

An instance that previously used the legacy Firebase HTTP adapter is explicitly reported as unavailable to the current Android app. Enable automatic setup and save to replace its active mode. The server retains the advanced legacy adapter for explicitly compatible clients, but the current native app cannot use that mode; uploading a Firebase project does not enable it.

## Optional Cloudflare ciphertext relay

Use the supplied [Worker](../integrations/cloudflare-push/worker.mjs) when you want Cloudflare to forward encrypted messages. This does not replace the phone's native push channel. It requires your own Cloudflare account; none has been connected or deployed as part of the local qualification.

From an administrator's local machine with Node.js and Cloudflare Wrangler available:

```sh
cd integrations/cloudflare-push
npx wrangler login
npx wrangler deploy
npx wrangler secret put PBX_RELAY_TOKEN
```

Choose a random relay key in your password manager, such as 64 hexadecimal characters, and paste it at the secret prompt. Use the same key in the PBX form. Keep it out of source files, shell command arguments and logs. Cloudflare documents [Wrangler login](https://developers.cloudflare.com/workers/wrangler/commands/general/#login) and [Worker secrets](https://developers.cloudflare.com/workers/configuration/secrets/); adding a deployed secret updates the Worker deployment.

Record the deployed `https://worker-name.account-name.workers.dev` address. In **Incoming Call Wake-up**, select **Cloudflare Worker relay**, enter that exact address and the relay key, and save. Only that HTTPS `workers.dev` address format is accepted; custom domains and paths are currently unsupported. Blank relay fields retain the saved address/key. Changing the Worker address requires its key. No `FCM_SERVICE_ACCOUNT` secret is needed for the encrypted Web Push mode.

The included Worker rejects unauthenticated requests, browser-origin requests, arbitrary destinations and payload fields, invalid VAPID signatures and excessive body sizes or TTLs. It forwards only to the allowed push host and refuses redirects. Worker observability is disabled in the supplied configuration, and application code does not log request bodies or secrets. Cloudflare's own infrastructure can still observe delivery metadata.

To return to direct delivery, select **This PBX server** and save. To rotate the relay key, update the Worker secret and PBX form with the same new value. Calls continue while relay delivery is unavailable; phones may miss wake-up during the mismatch.

## Delivery, cancellation and private keys

The PBX encrypts the short message on its own server before sending it directly or through Cloudflare. Its decrypted contents are only a random call-request identifier, device identifier, event (`incoming` or `ended`) and expiry. Caller names/numbers, phone passwords, call audio, recordings and account tokens are absent. Push providers and an optional relay see the endpoint, ciphertext, public signing identity, TTL, urgency and network/timing metadata. They do not receive the phone's decryption keys or PBX account token.

After decryption, the app authenticates to the PBX and checks that the call still exists, targets its extension in its own PBX, is unexpired and has not been dismissed or answered elsewhere. A forwarded-away call or expired request cannot be revived by a delayed notification. An ended event cancels only its matching wake-up notification. The SIP call owns the ringtone and media; push does not add a second ringtone.

PostgreSQL stores a short-lived delivery row with a bounded retry count and durable lease. A restarted worker respects an outstanding lease and recovers once it expires. Cancellation is retried after transport failure. Only definitive endpoint invalidation removes the matching subscription; an expired old endpoint cannot erase a replacement endpoint registered while its response was in flight. Permission, quota, relay and project failures retain a valid subscription. Expired delivery rows are removed after 24 hours even when wake-up is disabled.

Instance keys and relay secrets are stored outside the website in `/var/lib/openwebpbx/mobile-push.json`, mode `600` on Debian. An instance administrator's save is serialized, published atomically and restored if the database commit fails. Neither the form nor the phone bootstrap reveals the private signing key. Disable/re-enable and service restart preserve the public identity. The [Debian instance backup](backups.md) includes supported private push configuration when present. Preserve that file with the matching database during recovery; do not publish it or copy one identity to an unrelated PBX. Replacing the signing identity requires phones to refresh and register against the new public key.

## Phone qualification and troubleshooting

Android force-stop prevents this app from receiving wake-up until it is reopened. Reopen the app after reboot. Manufacturer battery controls, revoked notification permission, disabled Play Services, network loss and Android background/full-screen restrictions can prevent or delay delivery. **Unavailable** means the phone has not completed usable registration; keep its connection notification running, open **Check connection**, and have the administrator verify the server/relay settings. A configured server alone is insufficient.

For each supported phone and Android version, record these actual results before considering APP-17 complete:

- Receive, answer and decline while locked; repeat after a realistic idle period and the manufacturer's battery restrictions.
- End the caller before delivery, answer on another phone, forward away and revoke the Android device. Delayed notifications must never ring a stale or inaccessible call.
- Repeat after service restart, phone reopen/reboot, endpoint replacement and network loss/recovery. Verify media after answering.
- Confirm that force-stop requires reopening and that disabled/unavailable wake-up leaves normal SIP calling usable.

Local qualification on 2026-10-12 passed 33 PHP checks for private settings, stable keys, configuration locking/rollback, subscription validation and tenant scope. The .NET suite passed 64 checks, including the published RFC8291 encryption vector, independent Node/OpenSSL decryption and ES256 verification, real PostgreSQL leases/retries/invalidation, and the actual Worker forwarding server-generated ciphertext and cancellation with no external request. The standalone Worker suite passed 27 tests. These are server/protocol checks; they do not establish Google delivery, a deployed Cloudflare relay or locked/idle physical-phone reliability. Current status is maintained in [APP-17 and the release roadmap](../3CX.md).

The exact signed 1.0.9 direct app also passed a 15.206-second native stale-action regression: invalid local-call and authenticated push-request actions closed while the original conversation and two-way media remained active. The initially blocked UI wait came from Android's nearby-device permission dialog, not a stale call being revived; after permission was accepted the unchanged app passed. This proves the tested notification-action guard, while real locked/idle delivery, manufacturer restrictions and native answered-elsewhere cancellation still require physical phones. The [Android guide](android.md#version-109-candidate-qualification--2026-10-12) records the full final direct/Play native matrix.
