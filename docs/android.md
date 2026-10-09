# OpenWeb PBX for Android — 1.0.7

This is a standalone Android phone with native screens and its own SIP/media engine. It does not display the PBX website in a frame. Install the signed APK from the [1.0.7 release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.7). Android 9 or newer is required; the universal APK supports ARMv7, ARM64 and x86-64. Physical handset coverage and mobile-network qualification are still being established.

## Connect your phone

1. In your PBX, open **Users**, select your extension, then open **Phone Provisioning**.
2. Under **Connect Android App · QR Code**, choose **Show QR code**. The PBX displays a QR code for that extension.
3. Open the Android app, choose **Scan QR code** and point your camera at it. Confirm the server name before connecting.
4. Allow the microphone and notifications so you can make calls and see incoming calls.

A code expires after ten minutes and works once. It contains the HTTPS server address and a random enrollment code, never the SIP password. If the camera is unavailable, choose **Enter a connection code instead** and enter the server address and code shown by your administrator. The app accepts HTTPS origins with trusted certificates and refuses redirects during enrollment or authenticated API calls.

Each phone receives its own revocable credentials, valid for 180 days. Create a new QR code when they expire. They are encrypted with an Android Keystore key and excluded from device backup. The SIP connection uses TLS, validates the server certificate and requires SRTP media encryption. The server certificate must match the public SIP hostname. Account and calling permissions remain scoped to the tenant and extension.

## Five phone features

1. **Connect by QR code.** Native camera scanning, confirmation, one-time enrollment, encrypted account storage and device revocation.
2. **Make and receive calls.** Dial an extension or permitted outside number. Incoming calls ring and show a notification. Open the notification and choose **Answer**, or decline it. A persistent connection notification indicates that the phone is running.
3. **Call controls.** Mute/unmute, speaker/earpiece, hold/resume and keypad tones for phone menus. Available audio devices can be selected in **Settings → More → Audio device**; Bluetooth requires the nearby-device permission.
4. **Contacts and Recents.** Search the company directory and tap to call. Recents is phone-reported history, not the billing call record. It includes incoming, outgoing and missed calls; tap a record to call back. Completed phone calls are queued privately when offline. Upload retries are idempotent and run when the phone starts, another call ends or Recents is refreshed.
5. **Voicemail.** List your mailbox, play messages, mark them read and delete them after confirmation. Audio downloads are authenticated and kept in the app's private cache only while needed.

Use **Settings → Disconnect** to revoke this phone and remove its saved connection. An administrator can also revoke a lost phone in the PBX. A new QR code is required to reconnect.

## Ear protection

During outgoing setup and active earpiece calls, supported Android phones use their proximity sensor to turn off the display and suppress touches near your face. Moving the phone away restores the screen. Speaker, wired/Bluetooth audio, local hold and call termination release this protection. Phones without a supported sensor retain ordinary power-button behavior. Physical sensor behavior must still be checked on representative handsets.

## Privacy and support

Before connecting, the app explains that your chosen PBX receives device/connection details, call history and microphone audio during calls. Settings → More → Privacy and support opens the public privacy policy, data-removal instructions and support page. Disconnect removes this phone’s access and local account data; server records remain subject to the administrator’s deletion/retention process.

## Phone updates

Version 1.0.7 adds a prominent update card, clear Download/Install action, live progress and a notification that opens update details. Required updates finish downloading and verifying before the direct app asks you to install, and active calls defer installation. Android may still require permission or confirmation.

Install **1.0.7 once from the signed GitHub APK** if you currently use 1.0.3: the older app does not contain an updater. Install over the existing app to retain your connection; do not uninstall it first. The updater was introduced in 1.0.4. Upgrade the PBX server to 1.0.6 before installing the 1.0.7 phone update; this pairs the phone audio correction with the server calling fixes.

The direct APK checks the stable release feed when opened and approximately every twelve hours when Android permits network background work. In **Tenant Admin → Updates**, your tenant administrator chooses one of these policies:

- **Let users choose:** the phone tells you an update is available; choose when to download and install it.
- **Download automatically:** the complete update downloads privately in advance; choose when to install it.
- **Require the update:** the phone downloads and verifies the update, then asks you to finish installation when your call ends. Where Android permits a self-update, the app can request installation automatically; Android may still require your confirmation.

Open **Settings → More → App updates** to check manually, install a prepared update or retry. Android may first show **Allow from this source**. Enable it for OpenWeb PBX, return to the app, and choose **Install update**. After installation, choose Android’s **Open** button, tap the update notification or reopen OpenWeb PBX. Android controls whether an app can reopen automatically; the updater does not bypass these restrictions or start microphone services from a background receiver.

A required-update screen appears only after a supported, newer download has passed every check. Existing calls finish first. **Use phone for an urgent call** and connection/account settings remain accessible. An unavailable server, failed download, unsupported Android/PBX version or invalid release cannot lock the phone. Canceling installation retains the current app and account; the verified download remains available for another attempt. Phone registration pauses during actual installation and resumes when the app is opened.

The release envelope is verified using a pinned RSA public key and SHA-256 signature before its contents are used. The app rejects expired/replayed release metadata, an unexpected download origin, an incorrect file size/hash, a different application/signing certificate, an incompatible Android version and a downgrade. Downloads and installer staging use private app storage. Signed metadata, APK identity and bytes are checked again before committing an Android PackageInstaller session. Updates never include tenant credentials.

### Google Play edition

The Play edition has separate update handling and excludes package-install permissions and the direct APK installer. It opens the fixed Google Play listing; Google Play controls download, installation and reopening. It does not display fictitious download progress. A required store update is offered only when signed metadata confirms a fully published production Play release, and active/urgent calling remains available. A GitHub release does not establish Google Play availability. Initial 1.0.7 Play publication is pending account setup, testing and Google review; see the [submission guide](google-play.md).

## Call connection help

Your extension and connection state appear at the top. Calling your own extension displays an explanation before following its forwarding/voicemail rules. Failed calls remain visible with a plain-language reason and **Call again**. **Settings → More → Check connection** checks access to your PBX and reconnects the phone if idle; it does not claim to certify the provider or every destination.

The keypad and call controls use native vector icons and labelled touch targets. The Call button stays visible while the keypad scrolls on a short screen. Answer and Decline are distinct, and Mute/Hold/Speaker show their current state.

## Incoming calls and current limits

Keep the connection notification running. Reopen the app after restarting the phone, force-stopping the app or using an Android battery setting that stops it. This release does **not** include push wake-up through Firebase; it cannot guarantee ringing after Android terminates the process. Manufacturer battery restrictions, switching between mobile data and Wi-Fi, Bluetooth models and physical handset audio still require broader qualification.

Chat, video, meetings, attended transfer, conference calling, presence controls, Android Auto and emergency-location integration are not part of this release. This is an OpenWeb PBX client, not the proprietary 3CX app. Existing 3CX provisioning codes do not connect it. Outside calls still depend on a working PBX carrier connection and the extension's rules; do not retire the old phone system before the site's calling tests pass.

## Source, licenses and building

The Android project is in [mobile/android](https://github.com/embire2/openwebpbx/blob/v1.0.7/mobile/android/README.md), licensed AGPL-3.0-or-later. Pre-existing server code keeps its original license. See [component notices](https://github.com/embire2/openwebpbx/blob/v1.0.7/mobile/android/THIRD_PARTY_NOTICES.md). The release includes the corresponding Android source, the exact Linphone SDK 5.5.23 source and submodules, and Maven dependency source JARs. No signing key, enrollment code, account credentials or customer data is distributed.

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
