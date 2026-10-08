# OpenWeb PBX for Android

A standalone native Android phone, built with Kotlin and the Linphone SIP/media engine. There is no embedded website or WebView.

Version 1.0.3 supports Android 9 and newer. The universal APK contains ARMv7, ARM64 and x86-64 builds. Install the signed APK from the project's GitHub release, then scan the connection QR in your PBX's **Users → Phone Provisioning**. The QR contains a short-lived one-time code, not your SIP password.

See [the Android guide](../../docs/android.md) for connection, calling, voicemail, testing and current limitations. This client is licensed under AGPL-3.0-or-later; original server licenses are unchanged. See [third-party notices](THIRD_PARTY_NOTICES.md).

## Build

Install JDK 17 or 21 and the Android SDK (platform 35, build-tools 35.0.0). Set `ANDROID_HOME`, then run:

```sh
./gradlew :app:testDebugUnitTest :app:assembleDebug
```

For a signed release, set `OPENWEB_ANDROID_KEYSTORE`, `OPENWEB_ANDROID_STORE_PASSWORD` and `OPENWEB_ANDROID_KEY_PASSWORD` in your private environment, then run `scripts/build-release.sh`. The key alias is `openwebpbx`. Keep the same private key for future upgrades. Never store the keystore or passwords in this repository.

Run device security/QR tests with `./gradlew :app:connectedDebugAndroidTest` on an Android 9+ device or emulator. Integration calling also requires a configured OpenWeb PBX 1.0.3 server with a trusted HTTPS/SIP TLS certificate and an isolated test extension. Live workflow tests are opt-in through instrumentation arguments and consume a private `live-fixture.json` in the app's external-files directory; never package this fixture or enrollment images. The native lifecycle tests require `lifecycleFixture=true` and a disposable voicemail.

For testing the signed distributed binary, use the same private signing environment and `-PopenwebInstrumentRelease=true :app:assembleReleaseAndroidTest`; install both release APKs and invoke the selected instrumentation class. The APK contains no test account or connection code. Device evidence and the distinction between QR decoder/result testing and physical-camera qualification are in the Android guide.
