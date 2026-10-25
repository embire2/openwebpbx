# Voicemail and talking clock

On the hosted [OpenWeb PBX](https://call.openweb.co.za/), dial **121** from your connected phone or OpenWebPBX Free Phone account. Your own mailbox opens without a PIN. The existing **\*97** shortcut continues to work.

Press **1** for new messages, **2** for saved messages, or **5** for greeting options. Under greeting options, **1** records a greeting, **2** chooses a saved greeting, **3** records your name and **0** returns to the main menu. A new mailbox may first offer its name/greeting tutorial; press **2** to skip it. Custom recordings and saved messages are preserved.

The PBX identifies your registered phone account, including restored accounts whose login name differs from their extension and active Android device accounts. Changing the displayed caller ID cannot select another mailbox. Another extension or outside caller cannot open your mailbox by presenting its number. PIN entry, creation, reset, import and export have been retired.

Dial **1026** for Keoma's talking clock. After a short “South African time” welcome, speech starts immediately. The clock announces the upcoming signal every **15 seconds**, using **South African Standard Time, GMT+2**, including seconds: “When you hear the signal, it will be nineteen hours, sixteen minutes and fifteen seconds exactly.” Quiet ticks fill the wait before each beep. It uses 24-hour time independently of the PBX's office-hours timezone. Hang up when finished; a call ends automatically after 30 minutes. Telephone/network delay affects when you hear the signal.

## Email a recording and remove it from the mailbox

An administrator can choose an email attachment or an attachment followed by mailbox deletion in the user's voicemail settings. All notifications use the instance's **Outgoing Mail** server. WAV attachments play in ordinary desktop media players.

The new hosted21 mail path keeps a durable audio copy while sending. Missing audio or an outgoing-server refusal keeps the voicemail for recovery. With attachment-and-delete selected, cleanup follows successful SMTP acceptance; temporary audio is then removed after mailbox/file cleanup is verified. A successful outgoing-server response does not prove delivery to a recipient's inbox. Existing custom greetings and unrelated messages are preserved.

The actual producer, PostgreSQL concurrency/failure handling, playable MIME attachment, SMTP acceptance/deletion ordering, permission failures and welcome QR/config compatibility have focused tests. A controlled live software voicemail also passes: Google accepts its playable WAV, then the mailbox recording and temporary audio copy are removed. Recipient inbox receipt and physical/carrier calling remain separate observations. Windows attachment-and-delete qualification is being completed in its next full suite. Complete public Debian16/Windows20 packages retain their original mail code until upgraded.

## Deployment and preservation

Both services are active on hosted core **1.0.21**, updated **25 October 2026**. Default voicemail now uses **Keoma stock voice1.0.2** and the talking clock uses **1.0.3**. Its [catalogue](../app/pbx_setup/resources/talking-clock/1.0.3/catalog.json) and [audio manifest](../app/pbx_setup/resources/talking-clock/1.0.3/audio-manifest.json) bind the new phrases, shared digits and exact timing dependencies. All 4,915 stock spoken files use Keoma; custom greetings, music and non-speech ticks are preserved. Playback works offline. Earlier Nathaniel catalogues remain as historical provenance.

Actual owned software calls verify Keoma default voicemail, an unchanged custom greeting and three complete installed-clock announcements with decoded audio. No customer mailbox or physical phone was called by these checks. The calling engine and ordinary call admission stayed running during deployment.

The nullable legacy `voicemail_password` column remains for old-schema compatibility; all current values are NULL and a trigger prevents credential rewrites. Current parsers discard old PIN fields. Successful encrypted imports reapply this policy before activation; exact factory recovery retains its original state. Original backup archives/private recovery evidence are not rewritten. Retired Lua helper paths contain fail-closed tombstones so future upgrades overwrite old code.

New PBXs receive reserved 121/1026 routes; existing hosted PBXs have global routes. Custom phone-button assignments remain saved; new provisioning defaults to121. Custom greetings, messages, music and SIP passwords are unchanged.

The complete public Debian 1.0.16 and Windows 1.0.20 packages retain their original audio. Windows 1.0.21 includes the matching Keoma code/audio and is undergoing full qualification; do not apply the new clock audio alone over older timing code. Physical phones and carrier calls retain separate checks. [Original voicemail verification](feature-coverage.md#voicemail-121-and-gmt2-talking-clock--2026-10-17) and [historical clock repair](talking-clock-1.0.2.md).
