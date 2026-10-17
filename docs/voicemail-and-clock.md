# Voicemail and talking clock

On the hosted [OpenWeb PBX](https://call.openweb.co.za/), dial **121** from your connected phone or OpenWebPBX Free Phone account. Your own mailbox opens without a PIN. The existing **\*97** shortcut continues to work.

Press **1** for new messages, **2** for saved messages, or **5** for greeting options. Under greeting options, **1** records a greeting, **2** chooses a saved greeting, **3** records your name and **0** returns to the main menu. A new mailbox may first offer its name/greeting tutorial; press **2** to skip it. Custom recordings and saved messages are preserved.

The PBX identifies your registered phone account, including restored accounts whose login name differs from their extension and active Android device accounts. Changing the displayed caller ID cannot select another mailbox. Another extension or outside caller cannot open your mailbox by presenting its number. PIN entry, creation, reset, import and export have been retired.

Dial **1026** for Nathaniel's talking clock. After a short “South African time” welcome, he starts speaking immediately. The clock announces the upcoming signal every **15 seconds**, using **South African Standard Time, GMT+2**, including seconds: “When you hear the signal, it will be nineteen hours, sixteen minutes and fifteen seconds exactly.” Quiet ticks fill the wait before each beep. It uses 24-hour time independently of the PBX's office-hours timezone. Hang up when finished; a call ends automatically after 30 minutes. Telephone/network delay affects when you hear the signal.

## Deployment and preservation

Both services are active on the hosted Debian instance as of **17 October 2026**. The talking-clock addition is **1.0.2**, with seven Nathaniel UK phrases and a local timing tick. Its [catalogue](../app/pbx_setup/resources/talking-clock/1.0.2/catalog.json) and [audio manifest](../app/pbx_setup/resources/talking-clock/1.0.2/audio-manifest.json) bind the scripts/audio and 26 unchanged dependencies. The original system voice **1.0.1**, customer recordings and earlier clock assets are preserved. Playback works offline.

The nullable legacy `voicemail_password` column remains for old-schema compatibility; all current values are NULL and a trigger prevents credential rewrites. Current parsers discard old PIN fields. Successful encrypted imports reapply this policy before activation; exact factory recovery retains its original state. Original backup archives/private recovery evidence are not rewritten. Retired Lua helper paths contain fail-closed tombstones so future upgrades overwrite old code.

New PBXs receive reserved 121/1026 routes; existing hosted PBXs have global routes. Custom phone-button assignments remain saved; new provisioning defaults to121. Existing greetings, messages, music and SIP passwords are unchanged.

This hosted/source update leaves immutable Debian/Android **1.0.15** downloads unchanged. Full new-release signed installation/upgrade, new Windows native acceptance, physical phones and carrier calls retain separate qualification work. [Voicemail verification](feature-coverage.md#voicemail-121-and-gmt2-talking-clock--2026-10-17) and [clock repair verification](talking-clock-1.0.2.md).
