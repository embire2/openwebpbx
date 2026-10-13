# Install OpenWeb PBX 1.0.11

This build targets **Debian 13 amd64** and the **native Android app**. Historical Windows server releases remain available; a native Windows calling app is planned separately. See the [Windows client plan](windows-client-plan.md).

Use the matching assets on the [1.0.11 release page](https://github.com/embire2/openwebpbx/releases/tag/v1.0.11) and verify the release status. Check each download against `SHA256SUMS` and extract the entire Debian archive into an empty folder. Current verification and release status are recorded in [feature coverage](feature-coverage.md).

Published qualification covers eight complete SHA-matching downloads, the signed feed, fresh/installed Debian checks, six direct/four AAB-derived native cases and the production server update. The reference production instance activated minimum 1.0.11 with nineteen normal HTTPS policy checks; new installations still start without an active instance minimum. Genuine public phone replacement/account/media and final scoped cleanup passed; details are recorded in [feature coverage](feature-coverage.md#visible-call-controls-personal-settings-and-instance-phone-floor--1011).

## New Debian server

Use a clean Debian 13 computer. Point a hostname at its public IP address and supply a trusted HTTPS certificate for that hostname. Run from the extracted folder as root:

```sh
./install.sh --domain pbx.example.com --address YOUR_SERVER_IP --email admin@example.com \
  --certificate /path/to/fullchain.pem --certificate-key /path/to/privkey.pem
```

Enter the administrator password when prompted. For an isolated local test, use `--local-certificate` instead of the two certificate arguments. A local test certificate does not allow ordinary remote Android enrollment.

Setup installs PostgreSQL on the PBX computer, creates one database shared by all tenants, installs the call engine and web administration, and starts the independent updater and backup schedule checker. Tenants do not enter database settings. An existing PBX database or configuration is refused before replacement. Compatibility identifiers keep the internal name `fusionpbx`. The installer supplies the program-directory permissions required by its services, including installation prepared under umask 077; private configuration permissions stay restricted.

Open your server's HTTPS address and sign in. Setup creates Main PBX with **100 Reception** and **101 Office**. No provider is enabled automatically. Private configuration lives in `/etc/fusionpbx` and `/etc/openwebpbx`, media in `/var/lib/freeswitch`, and application source in `/var/www/fusionpbx`. The installer configures the shared PHP/background-service notification store at `/var/lib/openwebpbx/mobile-notifications/config.json`, inside a web-account-owned mode-700 directory with mode-600 configuration and lock files. The root-owned parent retains its existing permissions and is not writable by the web account. No manual credential file is needed.

## Existing Debian server

Open **Admin → System → Updates** and install the new version. The complete signed download is checked before maintenance; active calls defer installation. Migration installs the new backup helpers automatically, including when the previous installed updater does not know those files. A private recovery snapshot covers the application, database, configuration and newly installed helper files. See [updates](updates.md) for policies and recovery.

Version 1.0.11 retains the notification-store permission correction introduced in 1.0.10 after a normal Incoming Call Wake-up save failed in 1.0.9. When the new store is absent, migration copies the legacy notification configuration without changing its keys; an existing new configuration takes precedence. PHP and the background service use the configured private store, and the previous file is retained untouched for rollback. Recovery restores prior file bytes, modes and owners. Use the updater rather than moving secrets or changing the private parent directory by hand.

The additive distribution dependencies introduced in 1.0.9 are SoX, Python cryptography and the OpenSSH client. If an older updater encounters a package mirror problem, the update fails and retains its recovery snapshot; check the instance's private update log and retry once the package source is available. Existing 1.0.3 installations still need the documented one-time updater bootstrap. The fresh installer must not be used over an installed PBX.

## Set up the first calls

Open **Admin → Voice & Chat → Add SIP Trunk**. Enter the provider's details, choose who answers the main number, set opening hours, and choose the outside dialing rule. New connections stay off until you enable them for the agreed handover. Use **First Calls** for connection checks and real internal, incoming and outgoing test results. Confirm speech, caller ID, menu keys and any backup-provider route on the actual phones. Keep the previous system available until those paths pass.

**Office Hours** includes multiple periods, overnight opening, breaks, holidays and temporary Open/Closed overrides. **Call Routing** previews the destination for a chosen time. **Switchboard** and **Queue Wallboard** show scoped calls and agent state; call handling uses connected phones. See the core operating guides linked from [feature coverage](feature-coverage.md) for qualified behavior and remaining limits.

## Android connection and wake-up

Install the signed APK, then open **Users → Phone Provisioning → Connect Android App → Show QR code**. Scan the single-use code in the native app and allow microphone and notification access. The app supports Android 9 or later. Use the matching 1.0.11 server for availability, queues, wake-up and the instance-wide direct-app minimum release.

In **System → Incoming Call Wake-up**, enable incoming wake-up and save. Automatic setup is the default. The instance generates its own notification keys in the installer-managed private store; no Firebase project is needed. After saving, reload the page and check that the configuration remains enabled. Configuration success does not establish locked/idle phone delivery. Supported phones use installed Google Play Services through the open-source native distributor. An optional Cloudflare relay forwards encrypted messages; audio and phone credentials stay on the PBX. See [wake-up setup](android-push.md).

Keep the connection notification enabled. Android force-stop prevents wake-up until the app is reopened. Physical handset sleep, battery restrictions, network handover and proximity qualification are tracked separately in [the roadmap](../3CX.md). Google Play publication still requires the owner's account verification and Google's review; the Play bundle is a submission artifact, not an approved store release.

## Visible call controls and personal Settings

During a connected call, **Call Hold** appears across the active-call panel on Keypad, Contacts, Recents, Voicemail and Settings. Tap it to put the call on hold with music for the caller; tap **Resume Call** to continue speaking. Holding a merged three-way conversation holds both remote participants. If one participant leaves while held, the remaining caller stays held until you press **Resume Call**. Keep **End call** for ending a conversation.

Open **Settings** beside the app heading to choose **System**, **Light** or **Dark** appearance; select an Android ringtone; turn **Keypad vibration** on/off; choose **Keypad**, **Contacts**, **Recents** or **Voicemail** as the startup page; and sort contacts by **Name** or **Extension**. Changes apply to this phone. The ringtone follows Android volume and Do Not Disturb settings. Silent, unavailable and network sounds are not accepted; an unavailable saved ringtone falls back to the system ringtone.

Settings also shows the account and app version, your status and queue controls, connection checks, call-audio controls and update options. Microphone, incoming-alert and battery shortcuts open the appropriate Android controls. Read-only account details do not expose your SIP password. **Reset personal settings** returns appearance, ringtone, startup, sorting and vibration to defaults without disconnecting your account or removing update trust. **Disconnect this phone** is a separate action that removes this phone's connection and local account data. Privacy/support and component licences remain available.

## Require the direct Android release across tenants

After the release downloads and signed feed are verified and the server is upgraded, an instance administrator can open **System → Updates → Minimum direct Android release for every phone** and set the minimum to **1.0.11** (Android version code **111**). The server refuses a minimum newer than its own installed release. This requirement starts inactive on a fresh installation and covers existing/future tenants, newly connected phones and phones without a tenant phone-policy assignment.

A direct app below the minimum receives a required update. A tenant administrator cannot lower the instance requirement; their saved update preference is retained and applies once a 1.0.11 app meets the minimum. Clearing the minimum removes the instance requirement. Signed package availability, platform/server compatibility, active-call deferral, urgent-call access and Android installation confirmation still apply. Users may need to tap **Open** after installation.

The setting does not create a published Google Play update: Google's account/testing/review and a verified production Play version remain required. Historical browser, iPhone and Windows calling-client plans are not installed clients to upgrade. See [updates](updates.md) for exact policy and recovery behavior, and [core system status](core-system-status.md) for delivered features and open acceptance goals.

## Backups and hold music

Open **System → Backups**, set a backup password and schedule, choose retention, and include voicemail/recordings when required. Save the password separately from the server. Encrypted backups support local storage and SFTP. Restore onto a separate clean Debian instance; restored calling and job services remain held until explicit activation. Read [backup and restore](backups.md) before using the restore command.

The stock hold-music default uses the bundled CC0 instrumental. Existing custom music choices are retained; phones do not stream the song from an external website. Final 1.0.11 native tests verified music on the single held call, both conference legs and the remaining held caller, followed by resumed media. [Feature coverage](feature-coverage.md#visible-call-controls-personal-settings-and-instance-phone-floor--1011) records the complete window/continuous-RTP proof and preserved failed long fixed-offset comparison. See [music on hold](music-on-hold.md) for the track source and licence.

Release archives contain no customer backups, account credentials, signing keys or existing recordings. The supported V20 configuration importer remains independent of 3CX software and proprietary clients.
