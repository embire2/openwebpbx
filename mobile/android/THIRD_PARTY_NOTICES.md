# Android component notices

OpenWeb PBX Android code: Copyright 2026 OpenWeb PBX contributors, AGPL-3.0-or-later. The repository's pre-existing server licenses and notices remain unchanged.

- **Linphone SDK 5.5.23**, Belledonne Communications and contributors. Exact upstream tag: `5.5.23`, commit `348e8de32fb2ac56b7b0a7167968fc1ac707f7b2`. SDK source is licensed under GNU AGPL v3; subcomponents retain their respective licenses. The Maven POM describes GPL v3, while the authoritative SDK source includes AGPL v3 and explains its client-side use. This app is distributed under AGPL-3.0-or-later with the SDK's original license texts and corresponding source. Source/build instructions: <https://gitlab.linphone.org/BC/public/linphone-sdk/-/tree/5.5.23>.
- **ZXing Android Embedded 4.3.0**, Journey Mobile, Inc. and contributors, Apache License 2.0. <https://github.com/journeyapps/zxing-android-embedded/tree/v4.3.0>.
- **ZXing core 3.4.1**, ZXing authors, Apache License 2.0. <https://github.com/zxing/zxing/tree/zxing-3.4.1>.
- **AndroidX Activity 1.10.1** and its AndroidX runtime dependencies, The Android Open Source Project, Apache License 2.0. <https://android.googlesource.com/platform/frameworks/support/>.
- **AndroidX Media 1.7.1**, The Android Open Source Project, Apache License 2.0. Provides the audio-focus compatibility classes required by the Linphone Android SDK. <https://android.googlesource.com/platform/frameworks/support/>.
- **UnifiedPush Android connector 3.3.5** and **embedded FCM distributor 3.0.0**, UnifiedPush contributors, Apache License 2.0. These source-available libraries register with installed Google Play Services and decrypt Web Push messages; no proprietary Google client SDK is bundled. <https://unifiedpush.org/kdoc/connector/>, <https://unifiedpush.org/kdoc/embedded_fcm_distributor/>.
- **Tink 1.23.0**, Google and contributors, Apache License 2.0, with its separately licensed open-source Gson/Protobuf dependencies. Provides the UnifiedPush cryptographic implementation. <https://github.com/tink-crypto/tink-java>.
- **Kotlin compiler 2.1.20 / runtime 2.2.10**, JetBrains and contributors, Apache License 2.0. <https://github.com/JetBrains/kotlin>.

The release's Android source archive contains the app source/build files and exact Linphone SDK source with initialized submodules and upstream license notices. Maven source JARs for the Java/Kotlin dependencies and their artifact inventory accompany that archive. SDK build options and Android prerequisites remain documented in its upstream README. No customer configuration, signing key or credentials belong in the source or APK.
