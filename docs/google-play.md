# Publishing OpenWeb PBX on Google Play

The version 1.0.10/code110 submission package is published in the [1.0.10 release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.10). It retains the 1.0.9 calling controls and incoming notification permissions and pairs with the Debian private wake-up-storage correction. **The app has not been submitted or approved by Google Play.** The direct APK and the Google Play bundle are separate builds of the same native app. Google determines approval; account verification and any required testing must be completed honestly.

## What is prepared

- Store title, descriptions and release notes: `mobile/android/play/metadata/en-US/`.
- Icon and feature artwork: `mobile/android/play/metadata/en-US/images/`. Phone screenshots are captured from the actual app using fictional review data.
- Public [privacy policy](https://openwebpbx.com/privacy.html), [support](https://openwebpbx.com/support.html) and [data removal](https://openwebpbx.com/data-removal.html) pages; in-app links and an explanation before connection.
- Play-specific build targeting Android 16 / API 36. APK installation permissions, package installer and direct updater receivers are excluded. Google Play handles store downloads, installation and reopening.
- A separate review PBX with no outside calling or customer records. Permanent portal: `https://call.openweb.co.za/app/pbx_mobile/review.php`. Review credentials are private and belong only in Play Console’s **App access** section; see the [operator guide](google-play-review.md).
- Foreground-service demonstration: [historical 1.0.7 app video](https://openwebpbx.com/android-review.html). It demonstrates the earlier basics and is omitted from the 1.0.10 packet; capture the new incoming-call controls on a real phone for the final Console declaration.
- Prepared content/permission answers in [declarations](../mobile/android/play/declarations.md); confirm them against the final build and the owner’s actual practices before submission.

## Organisation account preparation

The owner has selected an organisation account. Use the registered company’s
legal details for ownership; OpenWeb PBX remains the app/developer display name. Have its legal name/address, website, working phone/email and D-U-N-S number
ready; the legal details must match its Google Payments profile. D-U-N-S lookup
or registration is free and obtaining a new number can take up to 30 days.
Google publishes the organisation’s legal name/address and developer contacts.
The 12-testers/14-days requirement below applies to new personal accounts; an
organisation still completes verification, app testing and Google review.
A free open-source app can use either account type. See Google’s
[organisation requirements](https://support.google.com/googleplay/android-developer/answer/13628312).

The owner handles identity, payment and legal acceptance. Once the account is
verified and publishing access is available, the build operator can complete the
technical upload, listing, signing export and declaration preparation below.

## The owner’s short checklist

1. Open [Google Play Console](https://play.google.com/console/) with the Google account that will own OpenWeb PBX. Pay Google’s US$25 one-time registration fee and complete identity, contact and any organisation verification shown by Google. [Registration instructions](https://support.google.com/googleplay/android-developer/answer/6112435). Use the real account type; a nonprofit project name alone is not proof of a registered organisation. Organisation accounts normally require a D-U-N-S number. See [account types](https://support.google.com/googleplay/android-developer/answer/13634885) and [required information](https://support.google.com/googleplay/android-developer/answer/13628312). Identity checks and accepting Google’s legal agreements must be done by the owner.
2. Choose **Create app**: OpenWeb PBX, English (United States), App, Free. Use the prepared support contact and listing files. The package ID is `com.openweb.pbx`. Do not create a different package. [Google’s setup instructions](https://support.google.com/googleplay/android-developer/answer/9859152).
3. Configure **Play App Signing with the existing app signing key** before the first release. In the signing setup choose the option to export/upload an existing key using Google’s PEPK tool. Save Google’s account-specific encryption key/instructions privately for the build operator, who will export the already existing signing key encrypted for Google. Never send the raw keystore or its password to a public site or repository. Using a new Google-generated app-signing identity would prevent ordinary updates over current GitHub installations. Expected existing certificate SHA-256: `449740f6858cb092a0f67d9d79d2505a8d6e7e4d4c1a52a8eaed9b895e48e69d`. After import, verify the Console certificate matches. Google’s [signing documentation](https://developer.android.com/studio/publish/app-signing#enroll) explains this existing-key option. A separate upload key can then be registered; it is not the app-signing key.
4. Upload `openwebpbx-1.0.10-google-play.aab` to **Internal testing**. Use the prepared descriptions, icon, feature graphic, actual screenshots and public URLs. The five screenshots show the identical 1.0.9 UI with fictional owned accounts. Complete **App content** using the prepared declarations. Copy the isolated reviewer login and permanent portal URL from the private operator handover into **App access**. No customer administrator password is needed.
5. Install from the testing-track link and check QR connection, an internal call in both directions, voicemail, background calling, notifications and the proximity sensor on real phones. Review and resolve Google’s pre-launch report. Google Play installation and update replacement must be tested through an actual Play track; a locally installed APK cannot establish that result.
6. If Google requires a closed test for the account, run it with real testers and keep their feedback. New personal accounts created after 13 November 2023 require at least 12 continuously opted-in testers for 14 consecutive days before applying for production access. Internal testing does not replace that requirement. Use the prepared [closed-test plan](../mobile/android/play/closed-test-plan.md). [Google’s testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465).
7. Choose production availability, complete the rating/privacy/permission forms, review the exact release and send it to Google. Keep the review PBX reachable throughout review and later reviews. Once Google approves and the release is actually available to the intended users, update the website with the live store link. If a tester already has direct APK version 107 installed, use a later version code for the Play replacement test; installing the same code does not prove the store’s update path.

With a verified account and authorized publishing access, the build operator can handle the artifact upload, listing and technical responses. No Play Console session or service-account access has yet been supplied here. Owner-only identity/payment/legal steps cannot be completed from the repository.

## Build and package

Use JDK 17, Gradle 8.11.1, Android platform 36/build-tools 36.0.0 and the persistent private release signing identity. Supply the three `OPENWEB_ANDROID_*` signing environment variables described in the Android guide. Run:

```sh
mobile/android/scripts/build-release.sh
```

The direct APK is for GitHub and the website; the Play AAB is for Google Play. Never upload the direct APK to Play. Both use the same package identity and monotonically increasing version code. Corresponding source includes the exact app, native SDK and dependency sources. The public submission packet must exclude all signing material, reviewer credentials, private server settings and customer records.

## How required updates work

For direct installations the tenant’s required policy stages and verifies the complete APK, waits for calls to finish, then requires installation with Android’s consent controls. The screen shows progress and a clear action. An urgent-call bypass remains available.

The Play edition opens its fixed Google Play listing and leaves download/install decisions to the store and Android. It never sideloads an APK or pretends it can observe Google Play’s download progress. A required Play gate needs signed metadata confirming a fully published production version, a supported server/device and an idle phone. Initial 1.0.7 metadata omits any published Play version because approval has not happened. Publication on GitHub alone must never activate a Play requirement.

Record approval in a later immutable signed release with a higher sequence, using the optional `android_play` field documented in the [update protocol](../packaging/updates/PROTOCOL.md). Never replace already published same-sequence metadata. Verify store availability before turning on that field.

## Open-source and store policy choices

Play prohibits ordinary apps from using package-install permission as a self-updater; see the [permission policy](https://support.google.com/googleplay/android-developer/answer/12085295). The app therefore has a separate Play build. We also avoid bundling Google Play Core: its SDK licence is proprietary and no applicable exception was established for the free AGPLv3 Linphone integration. This is a conservative distribution choice, not a legal determination. See [Play Core terms](https://developer.android.com/guide/playcore#play-core-software-development-kit-terms-of-service), [Linphone licensing](https://www.linphone.org/en/liblinphone-voip-sdk/) and the official [store-link method](https://developer.android.com/distribute/marketing-tools/linking-to-google-play).

## Verification and remaining gates

The signed 1.0.10 AAB passed Google bundletool validation, the expected signing certificate check, API36/manifest verification and alignment checks for all 26 64-bit native libraries. Both 1.0.10 builds completed release lint with zero errors; 25 direct/29 Play JVM tests passed. Signature/version and 16 KiB ZIP alignment checks passed for the direct APK. Public privacy/support pages and the restricted review portal previously passed HTTPS and desktop/mobile browser checks. Exact 1.0.9 native evidence and the separate 1.0.10 runtime/upgrade status are recorded in the [Android guide](android.md). Real-handset ear detection, locked/idle wake-up, Android16/16 KiB runtime behavior, Play-track installation, final Console declarations and Google approval remain separate gates. APP-16 remains open.

## New notification declaration in 1.0.9

The app now uses `USE_FULL_SCREEN_INTENT` for incoming voice calls. Complete its separate Play Console declaration under **App content**, identify voice calling as the core functionality, and show Answer/Decline on the actual phone. The app checks Android 14+ permission and keeps ordinary incoming notifications when full-screen access is unavailable. Google's [foreground-service and full-screen requirements](https://support.google.com/googleplay/android-developer/answer/13392821) govern approval; declaring a calling app alone does not prove approval.

The optional wake-up channel uses the open-source UnifiedPush connector and installed Google Play Services. Update Data safety from the refreshed [declarations](../mobile/android/play/declarations.md), including notification subscriptions and any configured Cloudflare relay. No Firebase project or proprietary Google client SDK is bundled. Actual locked/idle handset delivery and the Play-track test remain open.

The exact 1.0.10 AAB-derived APK passed three native Android13 software-device workflows: outgoing/background/audio-focus/hold/resume (41.830 seconds), three-way/removal (25.965), and availability/queue controls (9.543), with independent remote RTP on call cases and the existing enrolled account retained. This local AAB conversion is separate from installation or replacement through an actual Google Play track. The public packet contains 20 files, five fictional-account screenshots and no historical video; its 19 internal checksums and exact AAB bytes passed verification.
