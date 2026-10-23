# Technical Windows privacy text for owner review

This is proposed text for the existing public privacy notice. It is not a statement that the Windows client has been released, Store-certified or legally reviewed. The public `/terms`, `/privacy` and `/delete` links returned HTTPS200 on2026-10-23. A reviewed Windows tester section was published at `/privacy` on2026-10-23. This longer technical text remains a working reference for checking the final accepted build and Store submission; publication does not establish legal or Store approval.

## OpenWebPBX Free Phone for Windows

OpenWebPBX Free Phone connects to the OpenWebPBX tenant that you choose. A compatible PBX account is required. Your PBX operator controls your extension, call routing, directory, voicemail, account access and server-side records. Connecting a Windows app device does not replace another phone’s SIP password.

The Windows app stores its saved account tokens, app-device SIP credentials and queued call-history records with Windows Current User DPAPI. These protected files are accessible through the Windows user account that created them; Windows administrators and SYSTEM have the access provided by Windows security. The app also keeps an update sequence/hash receipt protected with DPAPI. No tenant administrator supplies an update signing key.

Non-secret personal preferences, including theme, selected audio/camera device identifiers, ringtone path, notification choices and startup choices, are JSON in the protected user data folder. They are not DPAPI-encrypted. Native SDK account, authentication, call-log, chat and LIME databases are disabled; SIP authentication is supplied to the native engine in memory. Technical startup tests verify that this configuration does not create native account/authentication/database files. This is distinct from the app’s own DPAPI-protected records.

Microphone audio is used for calls. Camera access is used for a video call or a QR-code scan initiated in the app. The user can select available devices and stop the camera. Call signalling uses SIP over TLS and call media requires SRTP to the configured PBX. Native SIP/media traffic does not pass through a required paid calling cloud. Operating-system permissions, device availability and the PBX operator’s network remain relevant to availability.

Directory, voicemail and account information are requested from the chosen tenant using HTTPS and its app bearer token. Voicemail audio downloaded for playback is a plaintext WAV in a protected private user folder, rather than a DPAPI-encrypted recording. The app attempts to close and delete it when playback stops, an incoming call interrupts playback or the app shuts down normally. Do not state that every crash residue is automatically removed: a startup sweep has not been implemented or qualified. The caller’s chosen ringtone remains a user-selected file.

Incoming notifications may display caller information according to the user’s choices and Windows notification settings. The app offers a setting to hide caller information and respects disabled notifications. Keeping the app running in the tray can maintain its phone registrations. A fully exited app does not currently claim a cloud-push wake-up service.

For direct distribution, the app requests a public signed Windows-phone release catalogue and package from GitHub. These public download requests do not carry tenant bearer tokens or cookies. The app verifies the independent built-in public signing key, release purpose, publication/expiry, sequence, package identity/publisher, length and SHA256. The Store edition uses Microsoft Store package-update services instead. Direct Windows-phone, Android and PBX Server update policies/feeds are separate.

Removing an app account removes its local saved connection and associated queued call history; the normal online path also asks the PBX to revoke that app device. An explicitly confirmed offline removal may leave the device listed by the PBX until an administrator revokes it. This does not delete server-side call records or the underlying PBX extension. The existing deletion-request page explains how to contact the responsible operator about those records.

## Review before publication

Verify this text against the final accepted client source, actual package/storage/media test results, final public download locations and the live privacy page. Retain the distinction between protected plaintext preferences/WAVs and DPAPI data. Do not add a recording, crash-cleanup, background-wake, Store approval or legal-compliance guarantee without evidence.
