# Play Console declarations — OpenWeb PBX 1.0.7

Prepared from the application source and the final build’s permission inventory. These are submission inputs, not a claim that Google has accepted them. The owner must confirm their legal identity, contact details, target audience and actual server data practices. Update this document if the binary or service changes.

## Listing and content

| Console item | Prepared answer |
| --- | --- |
| App / game | App |
| Category | Communication |
| Price | Free; no in-app purchase or subscription billing |
| Ads | No |
| Target audience | Adults, 18 and over, for workplace communication; owner to confirm |
| News / government / financial / health | No such features |
| App access | Some functionality restricted: existing PBX extension required. Provide the isolated reviewer portal URL, username, password and call instructions privately. |
| Account creation | No self-service account signup in this app. An organisation’s administrator creates the extension; scanning a code connects a device to that existing extension. |
| Privacy policy | https://openwebpbx.com/privacy.html |
| Data deletion resource | https://openwebpbx.com/data-removal.html |
| Support | hello@openwebpbx.com; https://openwebpbx.com/support.html |

For the IARC rating questionnaire, describe real-time voice communication with other users accurately. The app has no public feed, matchmaking, user discovery, chat, video, gambling or developer-supplied mature content. Do not preselect a rating or pretend voice communication is absent; the questionnaire determines the rating.

## Data safety worksheet

The app sends information to the user’s chosen PBX, so **do not answer “no data collected.”** HTTPS/TLS/SRTP protect the app-to-PBX connection; PBX and carrier audio is not end-to-end encrypted. No advertising, sale of user data, advertising ID or analytics SDK is present. The server operator is identified by the PBX address displayed before connecting and in Settings.

| Data type to disclose | Actual use and purpose | Required / retention |
| --- | --- | --- |
| Personal info → User IDs | Extension identity, device connection ID and authentication information; app functionality and account management | Required for a connected phone; connection record retained on PBX until administrator removal/retention expiry |
| Personal info → Name | Extension display name used in the phone account/directory and calling identity; app functionality | Account information supplied by the organisation; declare required conservatively across supported configurations |
| Personal info → Phone number | Extension/calling numbers used to route calls and display call history; app functionality | Required for calling; retained in PBX call records |
| App activity → Other actions | Call direction, start time, duration, answered status and voicemail-read actions; app functionality | Required for those features; PBX retention policy applies |
| Audio files → Voice or sound recordings | Microphone voice routed through PBX; voicemail and administrator-enabled recordings; app functionality | Required for voice calling. Do not claim ephemeral-only processing because supported PBXs retain voicemail/recordings. |
| Device or other IDs | Per-device connection identifier; network address and device name associated with phone registration and operational logs; functionality/security/account management | Required for the connection; server operator controls retention |
| App info and performance → Diagnostics | App version, connection failures and server-side operational events; functionality and security | Declare conservatively for supported operational logs; no third-party crash/analytics reporting |

Company contacts and voicemail are downloaded from the PBX. The app never reads or uploads the device address book. Camera frames remain on the device and are only decoded into an enrollment code; there is no photo/video upload. There is no location-permission access, location inference, SMS access, Android call-log access, financial/health data or advertising identifier collection.

Sharing answers depend on the actual PBX operator relationship and the user-initiated calling flow. Calls intentionally deliver audio and numbers to the other party and telephone providers. The app explains transmission to the selected organisation before connection. Assess the service-provider and user-initiated-action exceptions using the [official data safety definitions](https://support.google.com/googleplay/android-developer/answer/10787469); do not automatically claim that every independently hosted PBX is our service provider. Where an exception cannot be established, declare the affected types as shared for app functionality. The final form must represent every supported configuration.

Users can request deletion through the public resource and their PBX administrator. Disconnect removes the device connection and local data, not all server records. Organisations determine retention and may have legitimate reasons to keep some records; the deletion page requires those reasons and periods to be explained. Google allows a reachable support-email route for requests; see [account deletion guidance](https://support.google.com/googleplay/android-developer/answer/13327111).

## Permissions and foreground services

The Play manifest must contain **no REQUEST_INSTALL_PACKAGES or UPDATE_PACKAGES_WITHOUT_USER_ACTION** and no direct updater installer/receivers. The app uses the Android browser/store intent for Google Play. No accessibility service, VPN, broad file access, SMS/call-log permission, exact alarm or full-screen intent permission is requested.

| Permission / service | Purpose and demonstration |
| --- | --- |
| Microphone / FOREGROUND_SERVICE_MICROPHONE | User initiates/answers a voice call. Show permission request, connected call, Home/background operation, notification and hangup. Interrupting this work cuts speech; deferral prevents the call. Audio capture is limited to the call. |
| FOREGROUND_SERVICE_CONNECTED_DEVICE | User connects the phone to their organisation’s network PBX. An ongoing notification maintains that user-requested phone connection for incoming calls. Show enrollment, Ready for calls, notification, incoming call and Disconnect stopping the service. Interruption loses registration/incoming availability. Explain the network-connected PBX use in the Console rather than selecting an unrelated hardware use case. Google must assess this declaration. |
| CHANGE_NETWORK_STATE / network access | Network PBX connection; platform prerequisite for the connected-device foreground type |
| Camera | QR setup only; manual code entry remains available |
| Notifications | Connection, incoming-call and update visibility |
| Bluetooth connect | User-selected call audio route |
| Wake lock | Active-call audio and proximity screen protection |
| Receive boot completed | Persisted scheduled update checks; does not claim to start the microphone on boot |

The current service is not a Telecom `ConnectionService`; do not claim `FOREGROUND_SERVICE_PHONE_CALL` qualification or add `MANAGE_OWN_CALLS` merely to pass review. The [Android foreground-service type reference](https://developer.android.com/develop/background-work/services/fgs/service-types) documents the declared network/microphone cases. The reviewed demonstration is available at https://openwebpbx.com/android-review.html and included in the submission ZIP. It shows actual native screens at four frames per second using isolated demo data; it is not a physical-device audio or proximity qualification. Enrollment uses a fresh private portal code through the real API and permissions are granted before capture, so the video does not show a human scanning a QR code or the Android permission prompts. Capture those prompts during the real Play-track device test if requested by the Console/reviewer. Google requires descriptions, interruption impact and a video for the declared features: [foreground-service declarations](https://support.google.com/googleplay/android-developer/answer/13392821).

## Reviewer access

Use the permanent HTTPS review portal and reusable username/password created by the operator. Its QR/code is freshly generated for each device through the ordinary single-use enrollment flow. Reviewers can remove their own old review phones and reconnect. The isolated PBX has fictional contacts, demo audio and internal test destinations; no carrier routes or customer privileges.

Keep the login active without OTP, geographic restrictions or a short expiry. Do not put its password in listing text, screenshots, public docs or the submission ZIP. Google’s [review-access requirements](https://support.google.com/googleplay/android-developer/answer/15748846) require reusable access; a customer QR code that expires after ten minutes is insufficient.

## Owner confirmations still needed

The verified developer identity/account type; selected countries; actual support inbox delivery; intended age group; how requests for OpenWeb-hosted account/data deletion are handled and the applicable server retention periods. The app cannot establish those organisational facts from code. Console access, Play-track testing, pre-launch findings and Google’s review decision remain external gates.
