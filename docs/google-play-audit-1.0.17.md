# Google Play submission audit — 18 October 2026

This is the submission checklist for the candidate after public 1.0.16. It is not a claim of Google approval. The published 1.0.16 artifacts and their evidence remain immutable. Candidate implementation, automated checks, actual Android runs and Play Console acceptance must be recorded separately.

| Requirement | Application or operator action | Acceptance still needed |
|---|---|---|
| Accessible privacy policy | Show `https://openwebpbx.com/privacy` before connecting and in Settings; open the real external browser. Use the same URL in Console. | Check signed candidate on an unconfigured and a connected phone. |
| Terms and deletion | Also show `/terms` and `/delete`; explain that removing a local profile only disconnects that phone. | In-app deletion request must reach an operational contact; do not claim inbox delivery from an HTTP check. |
| Accurate Data safety | Declare PBX account/device identifiers, communications, call metadata, microphone audio, optional camera video, notification subscriptions and relevant SDK processing. Explain independent tenant operators and the central domain service. | Reconcile the final dependency inventory, actual operations and Console answers. No blanket “no data collected” answer. |
| Prominent disclosure and permissions | Explain calls/background microphone, optional video and notifications before the corresponding permission. Camera/QR scanning is optional. Refusal must leave manual login and audio-only use available. | Fresh-install, refusal, later grant, lock/background and camera shutdown on real devices. |
| Target Android version | Official requirements currently require API36 for new phone apps and updates from 31 August 2026. Existing project targets36. | Inspect the final AAB manifest, not only Gradle source. |
| Foreground services | Declare the actual connected-device, microphone and camera uses, explain their user benefit and provide a current demonstration video. | Record the final build, including video permission, explicit start/stop and background audio. Do not claim Telecom integration that is absent. |
| Incoming call full-screen intent | Calling is core functionality; retain permission checks and ordinary notification fallback. Complete the separate Console declaration. | Real supported Android devices, lock screen, denied full-screen access and idle wake-up. |
| Native compatibility | Check every final 64-bit native library and delivered APK alignment. Current official page lists 1 February 2027 for the 16KB requirement. | Actual 16KB-kernel execution; static alignment and a 4KB software device cannot establish it. |
| Reviewer access | Supply permanent isolated credentials and a static review portal, with no real customers or paid/provider dependency. Expiring customer invitation QR codes alone are insufficient. | Test exact submitted login, outgoing echo, incoming call, voicemail and optional video from outside the operator network. |
| Signing and updates | Retain `com.openweb.pbx` and existing signing identity; use the Play AAB. Play edition must use Google Play rather than sideloading its own APK. | Enrol existing signing key through Google's account-specific procedure; test actual Play-track installation and replacement. |
| Listing and content | Current app name, publisher, support contact, truthful screenshots, content rating, target audience, ads declaration and applicable distribution/country forms. | Complete Console forms using the exact final behavior. Existing historical screenshots/videos do not demonstrate new features. |
| Publisher verification | Owner completes organisation verification, D-U-N-S where required, legal/contact verification and payment. | Open ISP cc owner evidence and authorised Console access are still external prerequisites. Never fabricate these. |

Google specifically requires a privacy policy and accurate handling disclosures; a terms URL is also included because the owner requested it, not because every app universally requires one. Account-deletion rules depend on whether account creation is offered in the app; these PBX accounts are created by administrators. We still provide a clear request route and distinguish server-account deletion from local disconnection.

## Official sources checked

- [User data, privacy and disclosure policy](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en).
- [Account-deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en).
- [Data safety definitions](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).
- [Target API requirements](https://developer.android.com/google/play/requirements/target-sdk).
- [Foreground services and full-screen intent](https://support.google.com/googleplay/android-developer/answer/13392821?hl=en).
- [16KB page sizes](https://developer.android.com/guide/practices/page-sizes).
- [App access instructions for reviewers](https://support.google.com/googleplay/android-developer/answer/15748846?hl=en).
- [App signing](https://developer.android.com/studio/publish/app-signing).

Google may change requirements or request additional evidence. Recheck Console warnings at upload. A repository build cannot guarantee approval.
