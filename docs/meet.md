# Meet: audio and video conferences

On [the hosted PBX](https://call.openweb.co.za/), open **Meet** from the desktop or application menu. You can also open [/app/pbx_meet/](https://call.openweb.co.za/app/pbx_meet/) after signing in. Choose the correct PBX first.

Give the meeting a subject, choose a time and duration, then select **Create Meeting**. Leave the time blank to start now. Times in the form use your browser's timezone; calendar invitations contain UTC times. A meeting lasts 15 minutes to 8 hours.

Copy its private invitation, download a calendar invitation, or enter participants' email addresses. Email uses the instance's global outgoing mail server. **Start Now** or **Start / Join as Host** opens the meeting in a new tab. Choose **Join with Audio** or **Join with Camera**; allow the relevant browser permission. A camera is optional.

Guests open the invitation, enter their name and wait for admission. The host can **Admit**, **Mute**, **Allow Microphone**, **Remove**, **Lock Meeting** and **End Meeting for Everyone**. A locked meeting refuses new guests. A new invitation link invalidates the old link while preserving people already admitted. Staff can manage their own meetings; PBX owners can manage meetings on their PBX.

A registered extension on the same PBX can call the displayed meeting number. The host sees **Phone <extension>** in the waiting room and admits it. An outside caller's displayed number does not grant access. There is no default public telephone dial-in number; an administrator must separately design and authorise outside access.

Use **Mute Microphone**, **Turn Camera Off**, **Share Screen**, and **Leave Meeting** during a browser meeting. The browser asks which screen/window to share. Leaving, removal or ending the meeting stops capture. Hiding the meeting tab stops its camera; returning requires an explicit camera action. Screen sharing, if explicitly started, may continue while another tab is visible. Stopping sharing in the background cannot silently resume the camera. Share invitation links privately: possession allows someone to request admission, or enter directly if the host chose open admission. The meeting record stores a token hash; calendar invitations, copied links and queued invitation emails contain the usable private link and must be protected.

## Current scope

Hosted Debian provides scheduled meetings, private links, waiting rooms, registered-extension audio dial-in, mixed VP8 browser video, microphone/camera choices, screen sharing controls and host actions. Rooms have a configured ceiling of 25 participants, including the host; that is a limit, not a measured 25-person capacity claim. Chromium host/guest calls passed with decoded video pictures and two-way sound. A registered software phone passed admission, audio and removal checks. Tests use generated pictures and tones. Physical cameras, mobile networks, restrictive networks requiring TURN, browser/handset diversity and capacity need separate acceptance.

Meeting recording, polls, shared documents, whiteboards, remote assistance, public telephone access, migration from proprietary 3CX meeting invitations and complete 3CX meeting parity are not delivered. Existing 3CX apps do not become compatible. OpenWebPBX Free Phone has its own native video-calling implementation; browser meeting links remain separate.

The hosted installation uses public HTTPS/WSS and a certificate-verified encrypted loopback connection to a dedicated meeting profile. Short-lived meeting SIP credentials can reach only their admitted room and do not inherit extension or provider permissions. Video/audio passes through the selected PBX; meetings do not record by default. Operators must set retention/deletion procedures for meeting metadata and protect invitation links.

## Installation and recovery status

The complete Debian 1.0.16 package includes additive schema/profile/menu installation, a validated private loopback certificate, VP8 and proxy migration. Fresh installation, the installed signed updater/recovery and separate-server encrypted restore have passed the documented software checks. Supported standard and exact hosted web-server configurations retain their other rules; unsupported configurations refuse modification. Restore rebinds the fixed meeting profile to the target address, keeps the target certificate pair and revokes transient participant credentials. Meeting schedules, invitations and history are preserved. Windows and physical/network/capacity acceptance remain open.

Do not copy the complete current source over a production installation: other unreleased components have independent activation and qualification gates. Follow the published installer for its released version and the current release notes for additional hosted features.
