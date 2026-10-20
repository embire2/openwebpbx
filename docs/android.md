# OpenWeb PBX for Android — 1.0.18

**Tenant addresses are now required.** Install1.0.18 over your existing app, open it and type your `https://company.openwebpbx.com` address when prompted. For OpenWeb, use **https://openweb.openwebpbx.com**. Each saved account needs this once. Credentials and personal settings are retained; other domains are refused. This is an Android connection change; SIP desk phones keep their existing settings. Read the [upgrade and server-readiness guide](android-tenant-addresses-1.0.18.md) before installing on a self-hosted server. The complete Debian release remains1.0.16.

OpenWebPBX Free Phone is a standalone Android phone with native screens and its own calling engine. Version 1.0.16, code116, adds optional native video between colleagues and retains calling, transfers, voicemail, personal Settings and secure updates. Use the matching Debian 1.0.16 server for the integrated video, Meet, own-mailbox **121** and Nathaniel **1026** clock features. Android 9 or newer is required; the universal APK supports ARMv7, ARM64 and x86-64. Physical handset coverage and mobile-network qualification are still being established.

See [video calls and the known brief camera-restart interruption](android-video.md), [Meet](meet.md), and [voicemail and clock](voicemail-and-clock.md). Camera sharing always requires your choice; an incoming call cannot start it.

## Connect your phone

1. In your PBX, open **Users**, select your extension, then open **Phone Provisioning**.
2. Under **Connect Android App · QR Code**, choose **Show QR code**. The PBX displays a QR code for that extension.
3. Open the Android app, choose **Scan QR code** and point your camera at it. Confirm the server name before connecting.
4. Allow the microphone and notifications so you can make calls and see incoming calls.

A code expires after ten minutes and works once. It contains the HTTPS tenant address and a random enrollment code, never the SIP password. If the camera is unavailable, choose **Enter a connection code instead** and enter the tenant address and code shown by your administrator. The app accepts registered `*.openwebpbx.com` tenant origins with trusted certificates and refuses redirects during enrollment or authenticated API calls.

Each phone receives its own revocable credentials, valid for 180 days. Create a new QR code when they expire. They are encrypted with an Android Keystore key and excluded from device backup. The SIP connection uses TLS, validates the server certificate and requires SRTP media encryption. The server certificate must match the public SIP hostname. Account and calling permissions remain scoped to the tenant and extension.

## Five phone features

1. **Connect by QR code.** Native camera scanning, confirmation, one-time enrollment, encrypted account storage and device revocation.
2. **Make and receive calls.** Dial an extension or permitted outside number. Incoming calls ring and show a notification. Open the notification and choose **Answer**, or decline it. A persistent connection notification indicates that the phone is running.
3. **Call controls.** Mute/unmute, speaker/earpiece, hold/resume and keypad tones for phone menus. Available audio devices can be selected in **Settings → Audio device**; Bluetooth requires the nearby-device permission.
4. **Contacts and Recents.** Search the company directory and tap to call. Recents is phone-reported history, not the billing call record. It includes incoming, outgoing and missed calls; tap a record to call back. Completed phone calls are queued privately when offline. Upload retries are idempotent and run when the phone starts, another call ends or Recents is refreshed.
5. **Voicemail.** List your mailbox, play messages, mark them read and delete them after confirmation. Audio downloads are authenticated and kept in the app's private cache only while needed.

Use **Settings → Disconnect this phone** to revoke this phone and remove its saved connection. An administrator can also revoke a lost phone in the PBX. A new QR code is required to reconnect.

## New calling controls in 1.0.9

- **Incoming wake-up:** optional native notification handling, locked-screen Answer/Decline, authenticated call checks and cancellation when the call ends or advances. Actual sleeping-phone delivery remains a separate qualification requirement.
- **Connection recovery:** automatic re-registration after internet loss without another QR scan; interrupted calls either recover or show a useful bounded failure. A native network-loss/reconnection and next-call test passed; physical Wi-Fi/mobile switching remains open.
- **Transfer:** choose **Call options → Transfer**, enter an extension or choose a contact. Transfer immediately, or choose **Talk first** and then **Transfer now**. **Cancel transfer** returns to the original conversation. Native internal blind/attended transfer and failure/cancel recovery passed with continuing media; outside-carrier transfer qualification remains open.
- **Call waiting and three-way calls:** answer a second call, switch between held conversations, then choose **Merge calls**. Individual participants can be removed without ending the other conversation. **Mute sound** silences that participant on your phone; it does not mute that person's microphone for everybody. Three actual native endpoints passed waiting, switching, merge, media and participant removal.
- **Status and queues:** the **Status** button opens Available, Away and Do Not Disturb, a chosen duration and assigned queue checkboxes. A queue can remain joined while your status pauses delivery; the app explains the reason. Native UI and real server routing/concurrency/expiry checks passed; see [availability](android-availability.md).

## Call Hold and personal Settings in 1.0.11

During a connected call, press **Call Hold**. Your caller hears the PBX’s hold music until you press **Resume Call**. You can browse Contacts, Recents, Voicemail or Settings without resuming the call. For a three-way call, both remote callers are held separately and hear music; Resume Call brings the remaining people back together. If one person leaves while held, the remaining caller stays held until you resume. The PBX controls the music; its bundled default is a licensed CC0 music loop, and custom tenant music remains supported.

Open **Settings** at the top of the app:

- **Choose theme:** System, Light or Dark.
- **Ringtone:** choose an available Android ringtone or System ringtone. Silent and unavailable selections are refused; a deleted or inaccessible saved sound falls back to the system ringtone. Android volume and Do Not Disturb still apply.
- **Keypad vibration:** turn touch feedback on or off, subject to Android’s touch feedback setting.
- **Start page:** open on Keypad, Contacts, Recents or Voicemail.
- **Sort contacts:** Name or Extension.
- **Calling:** Status and queues, Audio device and Check connection use the existing calling controls.
- **Android permissions:** see microphone, incoming-alert and background-battery status; open the appropriate Android permission/settings screen.
- **Updates and support:** check App updates, privacy/help and source licenses.
- **Reset personal settings:** reset presentation choices without clearing your connection, account, call or administrator’s update policy. Disconnect is a separate confirmed action unavailable during a call.

These choices follow the personalisation categories in the [official 3CX Android manual](https://www.3cx.com/user-manual/installation-android/). SIP credentials, server addresses, network transport, encryption, codecs, microphone gain and ear protection are managed by the app/PBX so ordinary personal changes preserve the working calling configuration.

## Ear protection

During outgoing setup and active earpiece calls, supported Android phones use their proximity sensor to turn off the display and suppress touches near your face. Moving the phone away restores the screen. Speaker, wired/Bluetooth audio, local hold and call termination release this protection. Phones without a supported sensor retain ordinary power-button behavior. Physical sensor behavior must still be checked on representative handsets.

## Privacy and support

Before connecting, the app explains that your chosen PBX receives device/connection details, call history and microphone audio during calls. Settings → Privacy and support opens the public privacy policy, data-removal instructions and support page. Disconnect removes this phone’s access and local account data; server records remain subject to the administrator’s deletion/retention process.

## Phone updates

Version 1.0.7 adds a prominent update card, clear Download/Install action, live progress and a notification that opens update details. Required updates finish downloading and verifying before the direct app asks you to install, and active calls defer installation. Android may still require permission or confirmation.

If you currently use 1.0.3, install the current signed GitHub APK once: that older app does not contain an updater. Install over the existing app to retain your connection; do not uninstall it first. The updater was introduced in 1.0.4. Use the matching current server and APK. The earlier 1.0.6 server audio correction remains required for the repaired calling path.

The direct APK checks the stable release feed when opened and approximately every twelve hours when Android permits network background work. In **Tenant Admin → Updates**, your tenant administrator chooses one of these policies:

- **Let users choose:** the phone tells you an update is available; choose when to download and install it.
- **Download automatically:** the complete update downloads privately in advance; choose when to install it.
- **Require the update:** the phone downloads and verifies the update, then asks you to finish installation when your call ends. Where Android permits a self-update, the app can request installation automatically; Android may still require your confirmation.

An instance administrator can also require a **minimum Android version** for every tenant and phone on that instance, including future enrollments. Tenant preferences remain saved for releases after that minimum has been met. A required update never interrupts an active call or blocks calling on an unverified, unsupported or unavailable release.

Open **Settings → App updates** to check manually, install a prepared update or retry. Android may first show **Allow from this source**. Enable it for OpenWeb PBX, return to the app, and choose **Install update**. After installation, choose Android’s **Open** button, tap the update notification or reopen OpenWeb PBX. Android controls whether an app can reopen automatically; the updater does not bypass these restrictions or start microphone services from a background receiver.

A required-update screen appears only after a supported, newer download has passed every check. Existing calls finish first. For calling or connection recovery, choose **Use phone for an urgent call**, then open **Settings** if needed. Use that route if the update screen's connection/account shortcut returns to the same screen. An unavailable server, failed download, unsupported Android/PBX version or invalid release cannot lock the phone. Canceling installation retains the current app and account; the verified download remains available for another attempt. Phone registration pauses during actual installation and resumes when the app is opened. This work extension does not replace your normal phone for emergency calls.

The release envelope is verified using a pinned RSA public key and SHA-256 signature before its contents are used. The app rejects expired/replayed release metadata, an unexpected download origin, an incorrect file size/hash, a different application/signing certificate, an incompatible Android version and a downgrade. Downloads and installer staging use private app storage. Signed metadata, APK identity and bytes are checked again before committing an Android PackageInstaller session. Updates never include tenant credentials.

### Google Play edition

The Play edition has separate update handling and excludes package-install permissions and the direct APK installer. It opens the fixed Google Play listing; Google Play controls download, installation and reopening. It does not display fictitious download progress. A required store update is offered only when signed metadata confirms a fully published production Play release, and active/urgent calling remains available. A GitHub release does not establish Google Play availability. Play publication remains pending account setup, actual-track testing and Google review; the tested AAB and prepared 1.0.16 submission packet do not establish approval. See the [submission guide](google-play.md).

### Required 1.0.15 → 1.0.16 update qualification

Thirteen native cases passed on Android 13 against an isolated, fully installed Debian 1.0.16 server. Its instance minimum overrode all three tenant policies below version116, then restored each saved policy after the update. The actual signed 1.0.15 app downloaded and verified the complete 1.0.16 APK, retained an answered call during checking and installation attempts, and started Android PackageInstaller automatically after hangup. Android accepted this self-update after the source-install permission was explicitly granted. The package replacement receiver ran; reopening restored registration with exactly the same account credentials and personal preferences.

A real staged installation session was canceled safely, with no remaining session and a successful recovery call. Invalid signatures, unavailable feeds and a modified APK could not require installation. Six controlled calls before, during and after the workflow decoded real encrypted-call media in both directions; both tone-energy ratios exceeded 0.9998. Original server policies, mobile records and prior call history were restored exactly after removing the owned test data.

The acceptance harness supplied a privately signed release envelope and mapped its planned stable APK URL to the already-public preview URL containing the identical signed bytes. APK download used real GitHub HTTPS and the unchanged production verification/installer code. This is separate from verification of the published stable feed. No physical handset, manufacturer-specific installer or automatic background reopening is inferred. Android may still require an installation confirmation on other devices.

## Call connection help

Your extension and connection state appear at the top. Calling your own extension displays an explanation before following its forwarding/voicemail rules. Failed calls remain visible with a plain-language reason and **Call again**. **Settings → Check connection** checks access to your PBX and reconnects the phone if idle; it does not claim to certify the provider or every destination.

The keypad and call controls use native vector icons and labelled touch targets. The Call button stays visible while the keypad scrolls on a short screen. Answer and Decline are distinct, and Mute/Speaker show their current state. Call Hold / Resume Call remains visible above the content on every active-call tab, including Settings. It becomes available when the call connects and waits for hold/resume to finish before accepting another press.

## Incoming calls and current limits

Keep the connection notification running. Optional incoming wake-up uses instance-generated keys and an open-source native distributor; no Firebase project is required. Open **System → Incoming Call Wake-up**, enable incoming wake-up and save. Read the [wake-up guide](android-push.md) for setup and qualification. Supported phones use installed Google Play Services; Cloudflare can forward encrypted messages. Android force-stop prevents delivery until the app is reopened. Actual locked/idle physical handset delivery, manufacturer battery restrictions, Wi-Fi/mobile handover, Bluetooth and proximity still require qualification.

Chat, video, meetings, Android Auto and emergency-location integration remain planned. This is an OpenWeb PBX client, not the proprietary 3CX app. Existing 3CX provisioning codes do not connect it. Outside calls still depend on a working PBX carrier connection and the extension's rules; do not retire the old phone system before the site's calling tests pass.

## Source, licenses and building

The Android project is in [mobile/android](https://github.com/embire2/openwebpbx/blob/v1.0.11/mobile/android/README.md), licensed AGPL-3.0-or-later. Pre-existing server code keeps its original license. See [component notices](https://github.com/embire2/openwebpbx/blob/v1.0.11/mobile/android/THIRD_PARTY_NOTICES.md). The release includes the corresponding Android source, the exact Linphone SDK 5.5.23 source and submodules, and Maven dependency source JARs. No signing key, enrollment code, account credentials or customer data is distributed.

Use JDK 17 or 21, Android SDK platform 36/build-tools 36.0.0, and the included Gradle 8.11.1 wrapper. The project pins Android Gradle Plugin 8.10.1, Kotlin 2.1.20, Linphone SDK 5.5.23, AndroidX Media 1.7.1 and ZXing Embedded 4.3.0. `scripts/build-release.sh` runs both variants’ unit checks and Android lint, builds a signed direct APK and a signed Play AAB. Set the private signing environment variables described in the project README. Preserve the signing key for future app upgrades.

To rebuild the SDK itself, follow its included upstream README and CMake presets. In the source archive, pass `-DLINPHONESDK_VERSION=5.5.23` when configuring without Git metadata. The original default SDK build contains additional media components whose licenses are retained even when the phone UI does not expose video. The Gradle build consumes the pinned official SDK AAR; this guide does not claim reproducible byte-identical SDK binaries.

## Verification record

On 2026-10-08, the following checks passed using an isolated PBX service and Android 13 x86-64 running in a native Android container:

- Four JVM input-validation tests and Android lint; native Keystore encryption, tamper rejection and QR decoding.
- The actual PBX-generated QR image decoded with ZXing and completed the app's scanner-result callback, server confirmation and one-time enrollment. Instrumentation supplied the decoded image result in place of physical camera capture. The separate manual enrollment form also worked.
- Strict certificate validation and native TLS registration, outgoing and incoming SRTP calls, sustained RTP in both directions, mute/unmute, speaker selection, hold/resume and DTMF digit 5 received by the other phone.
- An incoming call while the app was behind the Home screen displayed its notification; tapping it and choosing Answer connected the call. Declining a second call produced a missed-call record.
- Company-directory search, tapping a contact to make an answered call, and tapping Recents to make another answered call.
- Native voicemail playback, automatic read status, confirmed deletion and disappearance from the mailbox.
- Rotation followed by enrollment-worker completion connected the replacement screen. Canceled audio downloads created no player or cache file, and repeated Play requests retained only the current player/file.
- Light and dark native call screens were reviewed at 420 × 900 pixels; the 360 × 640 light keypad and Settings/Disconnect flow were also checked.
- The final signed, non-debuggable universal APK was installed and repeated QR enrollment, native TLS/SRTP calling, controls, directory calling and Recents redial. Administrator revocation terminated an active incoming call, rejected its API token and rejected native SIP re-registration. The final signed update preserved the revoked account, then Settings → Disconnect cleared it and returned to Scan QR code.

The test environment exposes a speaker but no physical earpiece or Bluetooth headset. Android 9–12 and 14+, physical camera capture, handset audio/echo, Bluetooth hardware, lock-screen/Doze behavior, manufacturer battery controls and mobile-data/Wi-Fi handover still need device qualification. A native Android container test is not physical-handset certification. No live carrier call or 3CX app interoperability is claimed by these Android checks.

On 2026-10-09, the 1.0.4 updater and revised native controls were qualified on the same Android 13 environment:

- Ten JVM tests passed, including detached-signature tampering, trusted download origins, monotonic release metadata, numeric versions and required-update safety conditions; release Android lint passed.
- Authenticated tenant **Notify**, **Download** and **Required** policies drove the real app. Required mode downloaded and verified a complete APK, deferred installation during an active call, displayed the update screen afterward and retained a fixed urgent-call recovery action.
- The pinned manifest, exact APK bytes/hash, package/version and application signing certificate were verified on Android. Altered signatures and APK bytes were refused. A stale cached release was removed after a newer trusted sequence had been recorded, even while offline. Invalid checks and expired candidates cannot block calling.
- Android’s real **Allow from this source** and installation-confirmation screens were exercised. Canceling the confirmation kept version 104 and its account. A non-success installation result also retained the account and offered retry; a forged stale status callback was ignored.
- A private, signed 105 test APK replaced 104 through PackageInstaller. The account token remained unchanged, **MY_PACKAGE_REPLACED** posted the Open notification, and tapping it reopened the phone and completed native TLS registration. That synthetic 105 fixture was never published; it is different from the later 1.0.5 audio-fix release.
- The revised native controls made an answered fixture call and passed mute/unmute, hold/resume, DTMF 5 received by the other phone, and sustained two-way media over twelve seconds. The full keypad and fixed Call button fit 360×640 pixels. Self-dial confirmation and an actual rejected-call recovery card were exercised.

These update results cover Android 13 on this container. Android 9–12/14+, manufacturer-specific installers, device-owner deployment and unattended installation eligibility require further device qualification. Android may request confirmation even for a required self-update; automatic background reopening is not guaranteed. Installation cancellation, storage-failure handling and notification reopening are explicitly supported.

## Audio correction verified for 1.0.5

The published 1.0.4 APK reproduced an answered encrypted call while Android still reported its ordinary audio mode. Its runtime was missing AndroidX Media, which the SIP SDK needs for call audio focus. Version 1.0.5 includes that dependency and gives the SDK sole ownership of incoming ringing, avoiding a second competing ringtone.

On 2026-10-09, the final signed 1.0.5/code105 APK passed ten JVM tests, release lint and two focused native Android 13 tests against disposable extensions:

- An answered outgoing call obtained Android communication audio mode and carried two-way SRTP. Media continued while the app was in the background and after returning. Competing audio focus placed the call on hold; manual resume restored media, and hang-up released the audio mode. The test ran for 42.9 seconds, including three twelve-second media checks.
- An incoming call delivered through the PBX from a separate registered fixture phone used SDK ringing, answered with communication audio mode, carried two-way SRTP for twelve seconds, and returned to ordinary audio mode after hang-up. The test ran for 17.9 seconds.

These native tests establish the tested app and PBX media workflows. After the production server upgrade and Android 1.0.6 installation, the user also confirmed an outside call from extension 1000 stays connected with sound both ways. That confirms the reported handset failure is repaired for this outgoing path; it does not qualify every handset, mobile-network change, headset or carrier route. The later server 1.0.6 correction makes the server audio-module choice persist through configuration regeneration; upgrade the server before the phone update.

## Version 1.0.6 qualification

Version 1.0.6 keeps the same phone audio implementation and dependencies as the tested 1.0.5 APK. Its version and distribution guidance are updated to pair it with the persistent server calling correction. Ten JVM tests, release lint, the signed universal build and APK identity/certificate checks passed again. The native call evidence above belongs to the final 1.0.5 APK; those calls were not repeated for the version-only 1.0.6 phone change. The user subsequently confirmed an actual 1.0.6 outside call with sound both ways; broader handset acceptance remains open.

The release APK uses version name `1.0.6` and version code `106`. Its signing-certificate SHA-256 fingerprint is `449740f6858cb092a0f67d9d79d2505a8d6e7e4d4c1a52a8eaed9b895e48e69d`. Compare the download with the release's SHA256SUMS before installing. Signing keys are private and are not part of any download.

## Version 1.0.7 qualification

The final direct APK is version 1.0.7/code 107, SHA-256
`27a940eb00c6e2de9415e02b34b6679f3b8321df69563fb4ece19cf3d7059e60`.
The Play AAB is SHA-256
`57d34247ab5accf2c52c8402f7f0bf41fdfbe46453f0c63cd53376f82f721d71`.
Both keep the existing certificate fingerprint above and target API36.

- Release lint and 25 direct/29 Play JVM checks passed, including 11 proximity and
  four update-presentation checks. Both direct and AAB-derived Play APKs passed
  signature and 16 KiB ZIP alignment verification. Bundletool validated the AAB;
  all 26 64-bit native libraries passed ELF alignment checks.
- Exact signed direct 1.0.7 passed the native proximity adapter’s sensorless
  fallback and a 42.939-second outgoing SRTP call, background/return,
  communication-audio mode, competing-focus hold and resume.
- Android’s real PackageInstaller replaced signed 1.0.6 with the exact 1.0.7 APK.
  The installed version, account-token hash and extension were retained; tapping
  the actual update notification reopened the app and SIP registration returned.
  This used a private signed release fixture. Its newer trust correctly refused
  the then-public 1.0.6 feed after replacement; private trust was removed after
  the check. This does not claim a public 1.0.7 feed was available during that test.
- The final Play APK generated from the AAB passed four native methods,
  including signed store-publication policy tests and a 42.922-second
  SRTP/background/audio-focus/hold/resume call.
- Native 320/360dp checks covered the complete 12-key keypad, call controls,
  bottom navigation, visible required-update state/progress and preserved
  screen-capture protection. The update card stays compact during calls.

The software test device has no physical proximity sensor. Actual handset
near/far, headset route transitions and screen recovery remain required.
Android 16 and 16 KiB operating-system runtime qualification also remains open;
binary alignment checks do not establish that runtime result. Play-track
installation/replacement and Google approval await the owner’s account.

The final AAB-derived Play app also completed the 149.236-second permanent-review
workflow: fresh private-code enrollment, visible keypad 7000 echo, background
connection notification, portal-triggered incoming Answer with two-way SRTP,
new 7002 voicemail recording/play/deletion while retaining the supplied sample,
blocked outside-number attempt, and Disconnect removing its foreground
notification. The fresh message was 18.52 seconds/296,364 bytes; 98.45% of measured
power matched the injected 430/730 Hz synthetic microphone tone. This proves the
software microphone/media path used by the fixture, not physical-handset audio.
The 312-frame demonstration records actual native views with screen-capture
protection retained. It excludes QR codes and credentials; enrollment uses the
real API privately and permissions are granted before capture.

## Version 1.0.9 qualification — 2026-10-12

The exact signed direct APK is version 1.0.9/code 109, SHA-256
`f2ca8c39124fc9b907a2e5d5e035ea1dd716074b5e32bc2a57f1c5d2a9525145`.
The final Play AAB is SHA-256
`fd27013815ade9fd79e58d4f89d444d790df9620e75ff33c21bef2068dbce1e1`.
Both retain the established signing certificate and target API36. The installed
direct APK matched the frozen artifact exactly. The release compilation includes
the HTTP 401 push-unregister/service-stop/account-clear branch; source/compiler
timestamps and compiled bytecode were checked. No product source was changed
during these final native checks.

Twenty-five direct and 29 Play JVM checks, both release lint tasks, AAB validation,
certificate and binary-alignment checks passed. All 42 runtime dependency source
JARs are available for corresponding-source packaging. Binary alignment does not
qualify Android 16/16 KiB runtime behavior.

Twelve direct-build workflows passed against the actual Debian call engine and
two disposable auto-answer SIP phones on Android 13 x86-64:

- Consultation/cancel and unavailable-consultation recovery returned to the
  original call with continuing two-way remote RTP.
- Blind and attended transfers released Android's calls while both remote phones
  remained connected and exchanged RTP in each direction over a further
  four-second interval. Fixture calls were ended through an ownership-checked
  native operation after verification.
- Three-way hold/switch/merge, local participant sound mute and removal preserved
  the remaining conversation. The exact signed repeat lasted 25.836 seconds and
  both real remote phones exchanged media.
- Second-call answer held the original conversation; ending the second returned
  to the original with media. Hold/resume also passed on the final APK.
- Temporary DND, directory status, assigned-queue pause, the native status dialog,
  Available and per-queue leave matched server state in 9.619 seconds.
- A deliberate seven-second loss of the Android interface recovered without
  changing enrollment, then a new call carried media. The ADB transport was
  interrupted by that fault, so the native completion marker written after the
  account/reconnection/media assertions is its evidence; this case has no complete
  runner output. The other eleven workflows returned successful runner results.
- Outgoing/background/return/competing-audio-focus/hold/resume/audio-release passed
  in 43.635 seconds, and incoming SDK ringing/answer/SRTP/audio-release passed in
  16.406 seconds with fresh remote RTP counters.
- Stale local-call and authenticated push actions closed without answering or
  ending the existing conversation; the repeat passed in 15.206 seconds. An initial
  test UI wait was blocked by the nearby-device permission dialog, which was
  accepted on the disposable device before rerunning.

The APK generated from the exact Play AAB retained the existing enrolled account
and passed three functional workflows: a 42.213-second SRTP/background/audio-focus/
hold/resume call (1,835 sent and 1,909 received remote RTP packets), a 26.579-second
three-way/switch/merge/mute/removal workflow with both remote phones, and the
10.519-second availability/queue workflow. A separate 19.846-second capture test
saved five actual native 420×808 views—keypad, active call, the current empty
fictional mailbox, fictional contacts and a live three-way call—with production
screen-capture protection retained. They contain no QR codes, credentials or
private configuration. Test-only capture code does not ship in the application.

The direct build was restored afterward with enrollment retained. Same-version
direct/Play replacement does not establish a managed upgrade from 1.0.7. Version
1.0.9 assets and feed are published and remain immutable; the owned 1.0.7 device subsequently
passed the separate 1.0.10 production-feed replacement check below. No new carrier call, physical handset,
locked/idle FCM delivery, Wi-Fi/mobile handover, Bluetooth, proximity or Google
Play approval is established by these software-device results. See [the
roadmap](../3CX.md), [wake-up](android-push.md) and [availability](android-availability.md).

## Version 1.0.10 patch qualification — 2026-10-12

The direct APK and Play bundle use version name `1.0.10` and version code `110`,
with the existing signing identity. Phone runtime/UI source and dependencies
match 1.0.9; the Android product change is its version. The matching Debian server
moves optional notification configuration into
`/var/lib/openwebpbx/mobile-notifications/config.json`, with a private directory
owned by the web account, preserving existing VAPID keys and state-root
permissions. See the [wake-up guide](android-push.md).

The final signed direct APK has SHA-256
`0d1b3f6ea8df76f4af4d17f3f381a758c10f977f57cd5fef0a265a43e4b6344c`;
the Play AAB has SHA-256
`c85deac2efc753718f801a18f6f9b21e918de860fd6839bf8a909ea76a08c6e1`.
Twenty-five direct and 29 Play JVM tests passed with no failures or skips; both
release lint tasks completed with zero errors. Signature/package/version,
non-debuggable direct build and 16 KiB APK ZIP alignment checks passed.
Bundletool validated the AAB, its direct installer was excluded, and all 26
64-bit native libraries passed ELF alignment checks. All 39 native libraries
across the three ABIs are identical between the direct APK and AAB. The exact 42
Maven runtime source JARs passed ZIP integrity checks; the source archive includes
the root VERSION file needed by the release build script.

All eight complete public release downloads matched their local SHA-256 hashes;
the signed sequence110 feed and hosted Debian 1.0.10 service were verified. The
corrected Android source archive independently matched all 38,406 recursively
tracked SDK/submodule entries by bytes, type and mode, including 11 safe symlinks
and 456 tracked build-directory inputs, plus 88 Android files and 42 source JARs.
The previous broad directory filter had omitted 465 tracked SDK inputs, including
nine IDE inputs; 1.0.9 assets and tag remain unchanged. The 1.0.10 source archive
has SHA-256 `2821f40617048e851f539430d471adaee9cde77f9272cdc36c96b901bb1a8e1a`.

The owned public 1.0.7 app used its normal pinned feed and HTTPS transport to
download and verify the real 1.0.10 APK. Android's native confirmation installed
the exact published bytes and retained the account token. Normal manual Open
recorded installation completion and native TLS registration returned. A test
driver started verification too soon and interrupted the real replacement
receiver; this run therefore qualifies the supported launcher recovery, not
automatic notification reopening. The current public feed also correctly removes
an obsolete update notice once the installed version is current. Test-only fixes
handled the old API constructor, a slow public download exceeding a 90-second
fixture wait, and an adb-owned marker directory. Product binaries were unchanged.

Five focused native direct workflows passed with independent remote RTP:
outgoing/background/audio-focus hold/resume in 41.959 seconds, incoming SDK
ringing/media in 16.497, stale authenticated actions in 13.147, three-way/removal
in 26.261, and availability/queue controls in 9.507. The 1.0.9 native results above
remain evidence for their exact tested artifacts. The exact AAB-derived 1.0.10 Play APK also passed outgoing/background/audio-focus in 41.830 seconds, three-way/removal in 25.965 and availability in 9.543, with independent remote RTP and enrollment retained. The final direct build was restored afterward. Exact scoped cleanup removed the generated tenant, native accounts, records and media; 722 preserved synthetic REGISTER identifiers were checked in eight bounded batches, two live peer contacts and four exact-realm Android contacts were flushed, and no fixture contact remained. Customer and permanent reviewer resources were outside that scope. Physical locked/idle delivery, handset audio/proximity,
Wi-Fi/mobile handover, Android16/16 KiB runtime and actual Google Play-track
installation/approval remain open. The five current Play screenshots show the
identical 1.0.9 UI with fictional owned accounts; the demonstration video is
explicitly historical 1.0.7 basics and is omitted from the new submission packet.

## Version 1.0.11 qualification — 2026-10-13

The release build uses version name `1.0.11`, code `111` and the persistent
signing certificate. The exact signed direct APK SHA-256 is
`9f23be7940bc02122516b094cc0af2deb5d8089c430332376075d3b607204dec`;
the Play AAB is
`ad47ad9b7df441eee5a06a78e4e88259ef04b233484ff57c0f991bd064d49ceb`.
Twenty-nine direct and 33 Play JVM tests passed, and both release lint checks
reported zero errors. Bundletool, certificate, API36/permission and all 26
64-bit native-library alignment checks passed. These results apply to the final
binaries after the conference-entry and manual-hold recovery corrections.

Six guarded direct native workflows passed on an owned Android13 software
device with independent SIP peers:

- Manual Hold → Switch → Switch back → End second → automatic original-call
  recovery: 23.960 seconds, with decoded incoming and outgoing RTP advancing.
- Personal Settings: 104.003 seconds, covering System/Light/Dark, all four cold
  startup pages, haptics preference and actual Name/Extension sorting. A real
  built-in Andromeda ringtone was selected through Android's picker and used by
  the SDK. An unavailable cached sound fell back before the next incoming call
  on the same native Core; both calls answered with two-way media. Personal reset
  retained the account and signed-update trust, restored defaults and permitted
  another call.
- Conference Hold/Resume and remote departure: 72.814 seconds. Both native SIP
  legs paused; after Resume both were StreamsRunning, joined to local audio,
  SendRecv in both directions, with advancing decoded RTP and positive fresh
  bandwidth. A remaining caller stayed paused after the other participant left
  until explicit Resume.
- Visible full-width Hold/Resume on all four call tabs and Settings, including
  connection checking, theme changes and preference reset while held:
  76.051 seconds, followed by decoded two-way media.
- Outgoing/background/audio-focus/hold/resume: 45.412 seconds.
- Incoming SDK ringing and communication audio focus: 18.363 seconds.

Independent remote captures identified the selected CC0 music throughout
53.80 seconds of single-call hold, 19.92 seconds on each conference leg and
10.08 seconds on the remaining leg. Every overlapping ten-second identity
window (five-second steps, a bounded final partial window) exceeded the unchanged
0.75 correlation threshold: minima 0.8368, 0.8424 and 0.8336 respectively. RTP
continued without a gap over 65 milliseconds, and music stopped after Resume.
The full single-capture fixed-offset correlation was 0.593 and failed; it is
retained as a diagnostic limitation of fitting one source offset across the
135-second loop. Window offsets, full captures, SIP transition intervals and
strict resumed native packet deltas are preserved in private artifact-bound
reports. This windowed proof does not claim that the failed global metric passed.

Four native workflows also passed on the APK derived from the exact final Play
AAB: manual-hold switch recovery (23.104 seconds), expanded Settings/selected and
fallback ringtone/incoming media (132.242), both-leg conference hold/resume and
remote departure (72.208), and outgoing/background/audio focus (43.338).
Independent Play captures verified 20.12/20.10 seconds of music on both held
legs and 10.18 seconds on the remaining caller; every identity window exceeded
0.75 and resumed native decoded RTP advanced on both legs. The derived APK
SHA-256 is `0b242251cac5b8c1ee54dc1a998e7c24a3e6d628ddc49c869fd06767d3bcd9a5`.

The genuine public 1.0.10→1.0.11 replacement is recorded below. The eight current store images use fictional
owned accounts and include actual light/dark Settings and a held-call Resume
screen. A software-device AAB conversion does not establish Play-track
installation or Google approval. Physical ringtone audibility/haptics,
handset/earpiece/proximity/Bluetooth, locked/idle notification delivery,
Wi-Fi/mobile handover and Android16/16 KiB runtime coverage remain open.
No carrier or customer call was used. Historical version evidence above retains
its original binary and release attribution.

## Published 1.0.11 and public phone replacement — 2026-10-13

[Version 1.0.11](https://github.com/embire2/openwebpbx/releases/tag/v1.0.11)
is published at source tag `15e1edcd1`. All eight complete public downloads
matched their frozen checksums, and the signed sequence111 feed was verified.
Production completed its existing updater's 1.0.10→1.0.11 installation and
natural restart; the instance minimum is now 1.0.11. The source/Play packet and
public tags remain immutable. Corresponding-source checks cover all 38,406 exact
SDK entries, 95 exact Android entries and 42 source JARs; the Play packet contains
24 files, 23 verified internal checksums and eight actual screenshots.

The untouched original public-1.0.10 Android app/userdata performed a genuine
pinned-feed and HTTPS 1.0.11 download, with no seeded APK or partial update cache.
Android13 accepted the required app's unattended PackageInstaller replacement
on this eligible software device. The old instrumentation was terminated by
normal package replacement before its assumed confirmation marker; that
harness report is retained. There was no Java/application crash and no native
confirmation screen in this run. Protected app-owned marker permissions also
required the private driver to use read-only container access.

The genuine replacement receiver recorded completion before later verification
instrumentation. Installed bytes matched the exact `9f23be79…` APK above; the
same account-token hash and extension survived, and native TLS re-registration
passed. Reopening used the supported manual launcher because no update
notification remained. Automatic UI reopening and notification-tap reopening
are not claimed. A subsequent 43.304-second internal native SRTP call passed
two-way media, background return, competing audio focus, hold/resume and audio
release, with independent remote RTP. Eligibility for unattended installation
and background activity launch must still be qualified on physical devices;
Android can require consent and manual Open.

Final scoped cleanup removed the generated tenant/owner, domains, native accounts,
call records, restore rows, contacts and media. Seventy-five preserved synthetic
REGISTER IDs were checked in one bounded batch; two live peer contacts and one
exact-realm Android contact were flushed. Both peer units and the owned Android
container/environment were stopped. The dedicated ADB5038 daemon, four labelled
firewall exceptions and owned runtime directory were removed. Two owned ADB
authorizations, including the binary timestamp-store entry, were removed;
original authorization bytes/permissions and unrelated keys/timestamps were
preserved. The original host key and ADB5037 daemon remain unchanged. Customer
and permanent reviewer resources were outside the cleanup scope. Production
services remained active; physical handset and Google Play gates remain open.
