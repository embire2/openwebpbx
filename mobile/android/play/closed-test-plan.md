# Closed test plan

Use this plan if Google applies the new-personal-account test requirement. The owner supplies real testers; do not invent identities, feedback or attendance. A verified organisation account follows the requirements shown in its own Console.

1. Upload the reviewed AAB to the closed test track, choose the intended countries and add the actual tester Google accounts in Play Console. Share the track’s opt-in link with the testers. Each person must opt in and install through Google Play, not the GitHub APK.
2. Give each tester a separate demo extension/connection through the isolated review PBX. Keep carrier routes off. Never use the owner’s production administrator credentials. Log tester IDs privately; do not publish their emails or connection codes.
3. On the first day, each tester checks installation, QR or manual setup, permissions, directory and an answered internal test call. Record phone model, Android version, Wi-Fi/mobile connection and whether both people can hear.
4. During the test, check incoming calls with the app visible and behind Home; mute, speaker, hold, keypad tones, voicemail and return from the notification. Hold the phone to the ear and move it away, then repeat on speaker and with a headset. Record accidental touches or a screen that does not recover. Reopen after a restart or force-stop; push wake-up is not included.
5. Keep the test running with at least 12 testers continuously opted in for 14 consecutive days when that requirement applies. Gather genuine feedback and fix issues, including Google’s pre-launch report. An opt-out breaks that tester’s continuous period.
6. Summarize the actual testing and fixes when applying for production access. Google may require more testing; reaching the elapsed-day count alone is not an approval promise. Keep the reviewer portal active.

A basic private test log can use these columns:

`tester_id, device_model, android_version, opted_in_date, installed_from_play, test_date, scenario, result, issue_reference, fixed_version, retest_result`

Do not mark an update-over-existing-installation test passed until Google Play actually distributes a newer version with the same signing identity. The local signed APK replacement test is separate evidence.

[Google’s personal-account testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465).
