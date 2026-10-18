# Current review demonstration — 1.0.17

This is a capture plan, not a completed video or Google approval. The existing public 1.0.7 audio demonstration is historical. Do not submit it as proof of the current video/camera service or multi-account release.

## Available evidence

The existing Android13 software environment has **zero camera devices**, including virtual devices, according to its actual camera service. It can qualify software SIP/SRTP, generated media, native permissions and account UI, but cannot truthfully demonstrate a physical/virtual camera preview. No new emulator image or camera workaround was installed for this release. The 1.0.16 software video proof and known approximately 833 ms camera-restart transition interruption remain documented in the Android video guide; they do not replace a current camera-service demonstration.

The listing keeps six previously qualified native calling screenshots and adds current 1.0.17 onboarding/account screens. The latter use fictional local names; reconnect messages are actual app state, not simulated successful registration. The screens contain no connection codes, passwords, tokens or customer records. The packet's checksums bind the selected image bytes. Screenshots do not prove Play installation, physical calling or background notification delivery.

## Capture on a real review phone

Use the signed Play build through an actual internal test track, a camera-equipped Android14+ phone and isolated PBX extensions without carrier routes. Keep reviewer credentials private. Record the Android version, build/version, app installation source and actual permission states. Include readable gestures and the system prompts; do not splice synthetic media into a camera preview or claim an unseen system dialog was exercised.

1. Start disconnected. Show Terms, Privacy and Delete account links opening the three clean public URLs. Return to the native connection choices. Explain that deleting PBX data differs from disconnecting a device.
2. Connect a fictional account using an administrator's private setup code or app password. Stop recording while entering credentials; resume on the normal account screen. Show the microphone and notification permission requests, Ready for calls and the ongoing connection notification. The connection service is needed to receive calls from the network PBX.
3. Make and answer an internal audio call. Show actual two-way speech, Home/background audio, the call notification and hangup. Capture a real incoming notification and Answer/Decline. On Android14+, show full-screen permission behavior or its ordinary-notification fallback accurately.
4. With camera permission initially denied, press **Video call** and capture the Android camera prompt. Grant permission, show the real local preview and remote moving picture, then **Camera off**, camera re-enable and **Switch camera** where the phone has two cameras. The action is explicit; an incoming video offer alone must not start capture.
5. Receive a video offer and choose **Answer audio only**. Show the camera remains off. Separately choose **Answer video** after explicit permission. During a video call, go Home and lock the phone: camera capture stops while speech continues. Reopen and explicitly enable video. Show the actual foreground/camera indicator and notification behavior. Do not conceal the documented transition pause.
6. Connect a second fictional tenant using its setup file or app password. Show Accounts, selecting the outgoing account, an incoming call to the other account, separate history and local account naming. Demonstrate the active-call change guard. Show password change without revealing either password, then normal profile removal while the other account remains available.
7. Remove the final account and show the connection service/notification stops. Show the deletion-request link again. Complete a separate current Play update/account-preservation test through the track; direct APK installation is different evidence.

Provide the resulting stable HTTPS video URL in the foreground-service/full-screen declarations. Review all frames/audio for credentials, QR codes, tokens, customer names and private phone numbers before making it accessible. The owner must supply Console access, actual testers, the review phone and the public video link; no access, footage, store approval or tester participation is implied by this plan.
