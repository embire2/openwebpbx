# OpenWeb PBX for Android

A standalone native Android phone, built with Kotlin and the Linphone SIP/media engine. There is no embedded website or WebView.

Version 1.0.5 supports Android 9 and newer. The universal APK contains ARMv7, ARM64 and x86-64 builds. Install the signed APK from the project's GitHub release, then scan the connection QR in your PBX's **Users → Phone Provisioning**. The QR contains a short-lived one-time code, not your SIP password.

See [the Android guide](../../docs/android.md) for connection, calling, voicemail, testing and current limitations. This client is licensed under AGPL-3.0-or-later; original server licenses are unchanged. See [third-party notices](THIRD_PARTY_NOTICES.md).

## Build

Install JDK 17 or 21 and the Android SDK (platform 35, build-tools 35.0.0). Set `ANDROID_HOME`, then run:

```sh
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

For a signed release, set `OPENWEB_ANDROID_KEYSTORE`, `OPENWEB_ANDROID_STORE_PASSWORD` and `OPENWEB_ANDROID_KEY_PASSWORD` in your private environment, then run `scripts/build-release.sh`. The key alias is `openwebpbx`. Keep the same private key for future upgrades. Never store the keystore or passwords in this repository.

Run device security/QR tests with `./gradlew :app:connectedDebugAndroidTest` on an Android 9+ device or emulator. Integration calling also requires a configured OpenWeb PBX 1.0.5 server with a trusted HTTPS/SIP TLS certificate and an isolated test extension. Live workflow tests are opt-in through instrumentation arguments and consume a private `live-fixture.json` in the app's external-files directory; never package this fixture or enrollment images. The native lifecycle tests require `lifecycleFixture=true` and a disposable voicemail.

For testing the signed distributed binary, use the same private signing environment and `-PopenwebInstrumentRelease=true :app:assembleReleaseAndroidTest`; install both release APKs and invoke the selected instrumentation class. The APK contains no test account or connection code. Device evidence and the distinction between QR decoder/result testing and physical-camera qualification are in the Android guide.

## Managed updates

The native updater uses the pinned public release key in `app/src/main/assets/release-public.pem`. It implements the shared [release protocol](https://github.com/embire2/openwebpbx/blob/v1.0.5/packaging/updates/PROTOCOL.md), authenticated tenant policy, bounded HTTPS downloads, APK/certificate validation and Android PackageInstaller. The original 1.0.3 client needs one manual installation of 1.0.5 to obtain this updater. Upgrade the server to 1.0.5 first. Android may require source permission and confirmation; notification/manual reopening is the supported fallback for background-launch restrictions.

`UpdateRulesTest` covers detached signatures, allowed origins, monotonic metadata, versions and required-update safety states. `UpdateWorkflowTest` is opt-in with `updateFixture=true`; it requires a disposable account, private signed future-version APK/envelope and a fixture peer. Keep those inputs outside source and release archives. It exercises real download verification, Android installation permission/confirmation/cancellation and account-preserving replacement. The internal transport interface permits private instrumentation to supply signed bytes without introducing any production test URL, private key or verification bypass.

Private qualification can override the build version using `-PopenwebPrivateVersionCode=106 -PopenwebPrivateVersionName=1.0.6`. Such APKs and manifests are local fixtures only. Published builds use the default 1.0.5/code105 values and the stable signing identity.

`CallAudioTest` uses `audioFixture=true` and a disposable `audio-setup.json` to verify Android communication audio mode, audio-focus hold/resume, background calling and incoming SRTP audio. An independent auto-answer peer must be registered as extension 1001 in that isolated PBX. Never point these checks at customer accounts.
