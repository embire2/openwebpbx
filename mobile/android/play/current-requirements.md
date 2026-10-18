# Android and Google Play review — 18 October 2026

This records the source requirements for Android candidate 1.0.17 (code 117). Published 1.0.16 artifacts are unchanged. Source checks are not Google Play approval, an installed Play-track test, or physical-device qualification.

## Policy access and account controls

Onboarding and Settings contain separate **Terms of use**, **Privacy policy**, and **Delete account / request data deletion** browser links to `https://openwebpbx.com/terms`, `/privacy`, and `/delete`. They do not require a connected profile. Before connection, the app explains PBX processing of account/device details, call history, microphone audio, optional video, and optional encrypted notification delivery. Camera use for QR scanning is local; choosing video sends pictures through the PBX. Removing a saved profile first revokes its phone connection and deletes its local credentials. If the server cannot be reached, a separate explicit confirmation can remove the local profile only; the PBX may still list the device and its administrator should revoke it when available. Other accounts remain connected. The deletion link requests removal of the PBX account/server data. These are distinct actions.

Google requires an accessible privacy policy and accurate disclosures for sensitive data, including third-party processing. Where data use is outside reasonable expectations, disclosure must precede access and include affirmative consent. This app shows its explanation alongside each connection choice and requests Android permissions before microphone/camera use. Administrators and the publisher must confirm the actual Data safety answers and retention/provider arrangements. [User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311)

The app connects administrator-created extensions; it does not offer account signup. The public deletion route remains available anyway. Apps with account creation must also offer deletion inside and outside the app; all publishers must answer the Console deletion questions. [Account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111)

## Build and native libraries

`compileSdk` and `targetSdk` remain **36**; `minSdk` remains **28**. The current requirement for new mobile submissions and updates is API36. [Target API requirement](https://support.google.com/googleplay/android-developer/answer/11926878)

The existing pinned Linphone native libraries and ABI set are unchanged. The build verifier checks every 64-bit ELF load segment for 16-KiB alignment, bundle contents, SDK level, signing identity and installer exclusions. APK ZIP alignment is a separate check. A compatible artifact does not establish runtime behavior on a device whose page size is16384; actual 16-KiB-device/emulator calling remains a separate gate. Do not enable compatibility mode to conceal a failure. [Android page-size guidance](https://developer.android.com/guide/practices/page-sizes)

## Calling, camera and incoming alerts

The manifest declares `connectedDevice`, `microphone` and `camera` foreground types and their matching permissions. Network state permission satisfies the documented connected-device prerequisite; no unsupported Telecom `phoneCall` claim is made. The microphone is activated for a user-started/answered call, and camera activation requires explicit visible Video/Answer video action plus camera permission. Incoming offers, push, boot and background activity do not start the camera. Leaving the video screen or locking stops capture. [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)

Android restricts background foreground-service starts and access to while-in-use microphone/camera permissions. A denied push-triggered connection start falls back to tapping the incoming notification. The visible answering activity starts/answers the phone; it never bypasses platform consent. Reapplying the microphone type is avoided once already active. [Background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)

Full-screen alerts are reserved for real incoming calls. The app checks platform permission and falls back to ordinary call notifications. The Console requires the relevant foreground-service and full-screen declarations, use-case explanations and actual demonstrations. The older audio-only review demonstration does not prove current camera behavior or physical locked/idle delivery. A new camera/microphone/permission demonstration and actual Play-track/handset checks remain required. [Play foreground-service and full-screen declarations](https://support.google.com/googleplay/android-developer/answer/13392821)

## Multiple accounts

Up to ten saved profiles use one Android-Keystore-encrypted collection, including a non-destructive migration of the prior single account. They register concurrently. Outgoing calls and normal pages follow the selected profile; each actual call keeps its original profile for routing/history, and push instances resolve to their own saved device. Account names can be edited locally. Profile changes wait for calls and installation to finish. Cross-account conference merging is refused.

App-password login uses the chosen tenant HTTPS origin and extension. It never persists the app password. The server returns a separate per-device SIP secret. Changing the app password retains this device and invalidates other sessions/setup codes according to the server contract. `.openwebpbx` import accepts only bounded one-use-code JSON through the system file picker or matching content intent, asks for confirmation, and rejects password-bearing files.

The strongest verified update rule applies across saved profiles; selecting another account cannot bypass it. Candidate compatibility must satisfy every account's server version. Each profile caches its authenticated rule and server version for up to 24 hours, bound to that exact origin/token. One unavailable profile cannot discard another online required rule. Missing/expired compatibility evidence holds installation while retaining required-update status; revoked profiles remain available for sign-in recovery. An unavailable or invalid feed does not disable urgent calling. The Play edition contains no direct APK installer and sends the user to Google Play, whose installation behavior remains outside the app's control.
