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

The source includes additive schema/profile/menu installation, a unique private loopback certificate, VP8 configuration and a Debian proxy migration for the standard installer site. Unsupported/custom web-server configurations refuse automatic modification. A portable restore onto another address must rebind the meeting profile's RTP addresses to the target before use. Full signed fresh-install, upgrade/fault recovery, separate-server restore and Windows qualification of these new meeting components remain open. The immutable Debian 1.0.15 package does not contain this hosted overlay.

Do not copy the complete current source over a production installation: other unreleased components have independent activation and qualification gates. Follow the published installer for its released version and the current release notes for additional hosted features.
