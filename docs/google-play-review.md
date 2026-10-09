# Google Play review access

The Android app needs a real PBX account. Give Google the permanent review portal URL and its reusable English login through Play Console’s **App access** form. Do not upload credentials, connection codes or reviewer screenshots containing a QR code to the public repository or store listing.

The review portal uses the regular PBX login, a dedicated `pbx_mobile_review` permission and an explicit user-to-demo-extension assignment. It cannot choose an arbitrary extension or access PBX administration. Fresh QR codes still expire after ten minutes and work once; the portal URL and login remain reusable.

## Provision an isolated demo

On the hosted Debian instance, after installing the current server files and mobile schema, run the operator CLI as the instance administrator. Use an existing private directory outside the application and web root:

```sh
install -d -m 700 /var/lib/openwebpbx/play-review
php /var/www/fusionpbx/app/pbx_mobile/provision-review.php /var/lib/openwebpbx/play-review/credentials.json
```

The CLI writes credentials and exact ownership identifiers only to the mode-600 output file. Keep that original file: repeating the command with it preserves the password and demo data. It refuses an existing review tenant when the original ownership file is missing, and refuses a demo service containing providers or external rules. A partially completed first provisioning can resume from the same file.

The script creates one isolated tenant with a workspace domain and one service domain, one restricted web user, two extensions and two mailboxes. No provider or external calling rule is created. A tenant-specific catch-all rejects other numbers before shared feature rules. The extra service and users are persistent review resources, not disposable validation fixtures.

The installation must have working public HTTPS, secure phone connections and the current native scripts. Normal release installation copies `app/pbx_setup/resources/switch/scripts/app/pbx_setup/review_echo.lua` to the call engine’s `scripts/app/pbx_setup/` directory. An operator deploying this feature separately must copy that one script there too. No call-engine restart is required.

## Reviewer instructions

1. Visit the portal URL from the private output file and sign in with its supplied username and password.
2. Select **Show a fresh QR code**. Open the Android app and scan it, or select **Enter a connection code instead** and copy the displayed server address and code.
3. Allow microphone access for calls and notifications for incoming calls. Your demo extension is **7001**.
4. Dial **7000** to hear your voice returned. Try Mute, Speaker, Hold and End call.
5. Select **Ring my demo phone** on the portal to receive a call on that same phone. Answer it to hear your voice returned. Requests are limited to one per two and a half minutes; ringing lasts up to 25 seconds and an answered test ends after two minutes.
6. Dial **7002** to leave a message in your demo mailbox. End the call, open **Voicemail**, and refresh, play or delete it. A two-second sample tone is supplied initially.
7. Open **Contacts** for the demo numbers and **Recents** for call history. The demo cannot call outside numbers.

Up to ten demo phones can be connected. The portal can remove only phones assigned to its own demo extension. Removing an unused phone frees a slot without disabling review access. Keep the permanent account available throughout submission and later review; revoke only temporary qualification devices after testing.

The sample and any review messages are isolated from customer media. An operator can suspend access by disabling this dedicated user or tenant, but should coordinate that with an active Google review. Removing review data should use the exact identifiers in the private ownership file, never a broad customer-domain cleanup.

## Verification

The isolated PostgreSQL suites cover fixed assignment, disabled accounts/domains/tenants, device ownership, single-use code replay, phone limits, repeat provisioning, no external providers/rules, and the rate-limited incoming-test target. Live portal checks cover regular login, permission denial, CSRF/replay, desktop/mobile layout and fresh QR generation. The final signed Play APK completed real enrollment, 7000 echo and incoming-call Answer with two-way SRTP, then recorded/played/deleted a fresh 7002 voicemail while preserving the sample. The 18.52-second message matched the injected synthetic microphone tone. Outside calling was refused and Disconnect removed the phone connection. These are Android 13 software-device results; physical handset and Google Play-track testing remain separate.

Google requires reusable, available, location-independent review credentials and a static URL when QR access is used: [Google Play app access requirements](https://support.google.com/googleplay/android-developer/answer/15748846). Google makes the final approval decision.
