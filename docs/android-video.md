# Video calls in OpenWebPBX Free Phone

Android 1.0.16 preview adds native video calls between colleagues on a PBX that enables the `video_calls` capability. Older servers continue to support audio calls. Video uses VP8, with the existing encrypted call connection and SRTP media. The app package and signing identity are unchanged.

Install the preview APK over the existing app to retain its account. It is a separate prerelease; the stable update feed and minimum supported phone version remain unchanged. The Play bundle is a submission artifact, not an approved store release. Self-hosted servers need the matching video-capable server changes; installing the phone preview alone does not enable video on an older server.

In **Contacts**, choose **Video** next to a colleague. You can also enter their extension on **Keypad** and choose **Video**. The app checks that the number belongs to your company directory. Calls to ordinary external phone numbers remain audio calls. During an audio conversation, **Video call** opens the video screen; **Camera on** requests video from the other person.

Incoming video calls offer **Answer audio** and **Answer video**. A request to add video to an existing call offers **Keep audio** or **Accept video**. Neither an incoming call nor a request from the other person starts your camera. The first explicit video action asks for camera permission. Notification answer actions remain audio-only.

The video screen shows the other person and a small preview of your camera. **Camera off** stops sharing your camera while you can continue seeing and hearing the other person. **Audio only** removes video from the conversation. **Switch camera** changes between the available phone cameras. Mute, speaker, hold, resume and end-call controls remain available. **Back to phone** returns to the full keypad, transfer and other existing phone controls.

Leaving the video screen, locking the phone or placing a call on hold turns the camera off. Returning to the screen or resuming the call does not turn it back on; choose **Camera on** again. Video is for conversations with one person; existing three-way calls remain audio-only. If permission is denied or video cannot be negotiated, audio remains available.

## Verification and limits

The signed 1.0.16/code 116 APK passed the native software workflow on Android 13 using two isolated app instances, generated camera pictures and recorded test tones. Four cases decoded real VP8 pictures and SRTP audio: an outgoing video call, camera restart after hold/resume, an explicitly answered incoming video call, and an accepted request to add video to an audio call. The native texture checks contained 275–277 distinct sampled colours; both phones recorded the other phone’s decoded tone. Audio-only answers, rejecting a video request, stale incoming-call actions, camera-off, background/lock behaviour and explicit camera restart also passed.

The same APK passed a call to an ordinary plaintext SIP test phone, including native hold/resume and two-way decoded audio, while its own connection remained SRTP. The selected-pair video forwarding flags remained disabled for this mixed call. A separate call to the test account’s own **121** mailbox received 10 seconds of decoded speech with its camera off, without entering commands or creating a message. Actual keypad and directory Video buttons connected test calls. The earpiece/speaker/Bluetooth proximity check exercised the actual service with simulated routes and a simulated lock; this software environment has no physical proximity sensor.

**Known preview limitation:** restarting the camera can briefly interrupt audio or video while the PBX and phone renegotiate encryption. The final workflow recorded 48 rejected RTP packets and three rejected RTCP packets within one 833 ms transition on the second phone. The retained logs do not prove which warning context belongs to audio or video, so this is not described as a video-only interruption. No further SRTP failures occurred during the subsequent steady calls; decoded picture/audio checks continued to pass. This interoperability issue remains open. Encryption stays mandatory, and no global key or verification workaround was applied.

The final direct and Play builds passed 32 and 36 JVM tests respectively, with zero lint errors (90 and 80 existing/new warnings remain). Package identity, signing certificate, 16 KB library alignment and bundle validation passed. The verified direct APK SHA-256 is `f5cca96e8e688cf897747ade6450abb31da97ee5b88aab272bdf322bcc31a785`; the Play AAB SHA-256 is `2b07fd55cb714e508ff7f6dffbe091b53555cb199e4270530c098afc056e00d4`.

These checks do not establish physical front/back camera behaviour, physical proximity protection, handset battery performance, Android 14+ camera-service behaviour or every mobile network. Those device checks remain open. This preview does not qualify a new complete Debian/Windows installation or a Google Play release.

Android 1.0.16 declares the camera foreground-service type because a video call uses the camera while its visible video screen is open. A Play submission must update its permission declarations, data-safety answers and public privacy information consistently before review. It does not request background camera capture or bypass Android permission and lock-screen rules.
