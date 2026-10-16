# OpenWebPBX Free Phone for Android

Version **1.0.12 (code 112)** keeps the native calling interface, fixes readiness on private LAN/VPN networks without requiring Android Internet validation, and accompanies the restored desk-phone/server compatibility update. Exact signed-artifact regression and public release are tracked in [feature coverage](../../docs/feature-coverage.md#restore-and-desk-phone-handover--1012).

A standalone native Android phone, built with Kotlin and the Linphone SIP/media engine. There is no embedded website or WebView.

The 1.0.14 candidate is named **OpenWebPBX Free Phone** (code 114), with the same package and signing identity for upgrades. Public downloads remain on 1.0.12 until candidate runtime/release qualification finishes.

Version 1.0.12 supports Android 9 and newer. It adds visible Call Hold / Resume Call and personal Settings, retains the 1.0.9 calling features and 1.0.10 private wake-up-storage correction, and honours the instance minimum-version policy without interrupting active calls. Use the matching [1.0.12 release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.12); publication, production and handset qualifications are recorded separately in feature coverage. The universal APK contains ARMv7, ARM64 and x86-64 builds. Install the signed APK from the project's GitHub release with the matching server, then scan the connection QR in your PBX's **Users → Phone Provisioning**. The QR contains a short-lived one-time code, not your SIP password.

See [the Android guide](../../docs/android.md) for connection, calling, voicemail, testing and current limitations. This client is licensed under AGPL-3.0-or-later; original server licenses are unchanged. See [third-party notices](THIRD_PARTY_NOTICES.md).

## Build

Install JDK 17 or 21 and the Android SDK (platform 36, build-tools 36.0.0). Set `ANDROID_HOME`, then run:

```sh
./gradlew :app:testDirectDebugUnitTest :app:assembleDirectDebug
```

For a signed release, set `OPENWEB_ANDROID_KEYSTORE`, `OPENWEB_ANDROID_STORE_PASSWORD` and `OPENWEB_ANDROID_KEY_PASSWORD` in your private environment, then run `scripts/build-release.sh`. The key alias is `openwebpbx`. Keep the same private key for future upgrades. Never store the keystore or passwords in this repository.

Run device security/QR tests with `./gradlew :app:connectedDirectDebugAndroidTest` on an Android 9+ device or emulator. Integration calling also requires a configured OpenWeb PBX 1.0.6 or newer server with a trusted HTTPS/SIP TLS certificate and an isolated test extension. Live workflow tests are opt-in through instrumentation arguments and consume a private `live-fixture.json` in the app's external-files directory; never package this fixture or enrollment images. The native lifecycle tests require `lifecycleFixture=true` and a disposable voicemail.

For testing the signed distributed binary, use the same private signing environment and `-PopenwebInstrumentRelease=true :app:assembleDirectReleaseAndroidTest`; install both release APKs and invoke the selected instrumentation class. The APK contains no test account or connection code. Device evidence and the distinction between QR decoder/result testing and physical-camera qualification are in the Android guide.

## Managed updates

The native updater uses the pinned public release key in `app/src/main/assets/release-public.pem`. It implements the shared [release protocol](https://github.com/embire2/openwebpbx/blob/v1.0.7/packaging/updates/PROTOCOL.md), authenticated tenant policy, bounded HTTPS downloads, APK/certificate validation and Android PackageInstaller. The original 1.0.3 client needs one manual installation of 1.0.7 to obtain this updater. Upgrade the server to at least 1.0.6 first. Android may require source permission and confirmation; notification/manual reopening is the supported fallback for background-launch restrictions.

`UpdateRulesTest` covers detached signatures, allowed origins, monotonic metadata, versions and required-update safety states. `UpdateWorkflowTest` is opt-in with `updateFixture=true`; it requires a disposable account, private signed future-version APK/envelope and a fixture peer. Keep those inputs outside source and release archives. It exercises real download verification, Android installation permission/confirmation/cancellation and account-preserving replacement. Adding `updatePublic=true` uses the normal production HTTPS feed/download transport instead of fixture bytes, while still requiring the fixture guard and disposable account. The internal transport interface permits private instrumentation to supply signed bytes without introducing any production test URL, private key or verification bypass.

Private qualification can override the build version using `-PopenwebPrivateVersionCode=115 -PopenwebPrivateVersionName=1.0.15`. Such APKs and manifests are local fixtures only. The 1.0.14 candidate release build uses the default 1.0.14/code114 values and the stable signing identity. The corresponding-source archive includes the root VERSION file, all recursively tracked SDK/submodule source (including upstream build directories), and the exact Maven runtime source JARs.

`CallAudioTest` uses `audioFixture=true` and a disposable `audio-setup.json` to verify Android communication audio mode, audio-focus hold/resume, background calling and incoming SRTP audio. An independent auto-answer peer must be registered as extension 1001 in that isolated PBX. Never point these checks at customer accounts.

## Google Play build

The `direct` flavor contains the verified GitHub APK installer. The `play` flavor contains only a Google Play listing handoff; no package-install permission, installer code or proprietary Play Core library is included. Both use the same package/signing identity. `scripts/build-release.sh` builds both the signed direct APK and Play AAB. Use `:app:assemblePlayDebugAndroidTest` for Play-only publication-policy instrumentation.

Store preparation, current publication status and owner steps are in [the Play guide](../../docs/google-play.md). Public listing inputs are under `play/`; never add review credentials or signing material there. `scripts/verify-play-bundle.py` validates the actual signed AAB with Google bundletool, checks its merged permissions/identity, excludes direct installer classes and checks every 64-bit native ELF load alignment for 16KB pages. Runtime page-size/device qualification is separate.

`PersonalControlsTest` requires `personalControlsFixture=true` and an enrolled disposable `mobile-check-*.invalid` PBX. It exercises native Settings, visible hold/resume and both conference media legs; independent peers verify timed received hold music. Preferences control theme, Android ringtone, keypad haptics, startup page and contact sorting. Reset clears only those preferences. Hardware audio, haptics, proximity and physical locked/idle wake-up remain separate qualification gates.

The final 1.0.11 direct APK passed six guarded native workflows on Android13,
including personal Settings with selected/default-fallback incoming ringtone,
visible single/conference Hold/Resume, remote departure and manual-hold switch
recovery, plus outgoing/background and incoming audio focus. Independent peers
received the selected hold track continuously until Resume; the Android guide
records artifact hashes, windowed music identity and the retained failed
full-capture fixed-offset metric. The build passed 29 direct/33 Play JVM tests
and both release lint checks. Current store images are actual native captures
using fictional owned accounts. Four focused native workflows also passed on the exact AAB-derived APK,
including the same Settings/ringtone, manual-hold switch recovery,
conference/media/music/departure and outgoing/background cases. The genuine public 1.0.10→1.0.11 replacement passed exact-byte/account/receiver/TLS and subsequent native SRTP checks; actual Play-track qualification remains separate; physical handset gates remain open.

The public replacement used the original offline-preserved 1.0.10 app/userdata,
normal pinned-feed/HTTPS transport and no seeded APK cache. This eligible
Android13 accepted unattended required installation. Its genuine receiver
recorded completion before later instrumentation; account and TLS registration
survived, and a 43.304-second post-update native media call passed. Reopening used
the supported manual launcher; automatic UI reopening is not claimed. The source
archive verifies 38,406 exact SDK entries, 95 Android entries and 42 source JARs.
The prepared Play packet verifies 24 files/23 internal checksums/eight screenshots.
Physical installation eligibility and actual store delivery remain separate.

Final scoped cleanup removed the disposable tenant/native accounts and contacts,
stopped the owned Android/peer environment, removed its ADB authorization and
four labelled firewall exceptions, and preserved customer/reviewer resources,
original keys, unrelated processes and production services.
