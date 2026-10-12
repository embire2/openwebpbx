# Install OpenWeb PBX 1.0.9

This build targets **Debian 13 amd64** and the **native Android app**. Historical Windows server releases remain available; a native Windows calling app is planned separately. See the [Windows client plan](windows-client-plan.md).

Use the matching assets on the [1.0.9 release page](https://github.com/embire2/openwebpbx/releases/tag/v1.0.9) and verify the release status. Check each download against `SHA256SUMS` and extract the entire Debian archive into an empty folder. Current verification and release status are recorded in [feature coverage](feature-coverage.md).

## New Debian server

Use a clean Debian 13 computer. Point a hostname at its public IP address and supply a trusted HTTPS certificate for that hostname. Run from the extracted folder as root:

```sh
./install.sh --domain pbx.example.com --address YOUR_SERVER_IP --email admin@example.com \
  --certificate /path/to/fullchain.pem --certificate-key /path/to/privkey.pem
```

Enter the administrator password when prompted. For an isolated local test, use `--local-certificate` instead of the two certificate arguments. A local test certificate does not allow ordinary remote Android enrollment.

Setup installs PostgreSQL on the PBX computer, creates one database shared by all tenants, installs the call engine and web administration, and starts the independent updater and backup schedule checker. Tenants do not enter database settings. An existing PBX database or configuration is refused before replacement. Compatibility identifiers keep the internal name `fusionpbx`.

Open your server's HTTPS address and sign in. Setup creates Main PBX with **100 Reception** and **101 Office**. No provider is enabled automatically. Private configuration lives in `/etc/fusionpbx` and `/etc/openwebpbx`, media in `/var/lib/freeswitch`, and application source in `/var/www/fusionpbx`.

## Existing Debian server

Open **Admin → System → Updates** and install the new version. The complete signed download is checked before maintenance; active calls defer installation. Migration installs the new backup helpers automatically, including when the previous installed updater does not know those files. A private recovery snapshot covers the application, database, configuration and newly installed helper files. See [updates](updates.md) for policies and recovery.

The new additive distribution dependencies are SoX, Python cryptography and the OpenSSH client. If an older updater encounters a package mirror problem, the update fails and retains its recovery snapshot; check the instance's private update log and retry once the package source is available. Existing 1.0.3 installations still need the documented one-time updater bootstrap. The fresh installer must not be used over an installed PBX.

## Set up the first calls

Open **Admin → Voice & Chat → Add SIP Trunk**. Enter the provider's details, choose who answers the main number, set opening hours, and choose the outside dialing rule. New connections stay off until you enable them for the agreed handover. Use **First Calls** for connection checks and real internal, incoming and outgoing test results. Confirm speech, caller ID, menu keys and any backup-provider route on the actual phones. Keep the previous system available until those paths pass.

**Office Hours** includes multiple periods, overnight opening, breaks, holidays and temporary Open/Closed overrides. **Call Routing** previews the destination for a chosen time. **Switchboard** and **Queue Wallboard** show scoped calls and agent state; call handling uses connected phones. See the core operating guides linked from [feature coverage](feature-coverage.md) for qualified behavior and remaining limits.

## Android connection and wake-up

Install the signed APK, then open **Users → Phone Provisioning → Connect Android App → Show QR code**. Scan the single-use code in the native app and allow microphone and notification access. The app supports Android 9 or later. Use the matching 1.0.9 server for the new availability, queues and wake-up APIs.

In **System → Incoming Call Wake-up**, enable incoming wake-up and save. Automatic setup is the default. The instance generates its own notification keys; no Firebase project is needed. Supported phones use installed Google Play Services through the open-source native distributor. An optional Cloudflare relay forwards encrypted messages; audio and phone credentials stay on the PBX. See [wake-up setup](android-push.md).

Keep the connection notification enabled. Android force-stop prevents wake-up until the app is reopened. Physical handset sleep, battery restrictions, network handover and proximity qualification are tracked separately in [the roadmap](../3CX.md). Google Play publication still requires the owner's account verification and Google's review; the Play bundle is a submission artifact, not an approved store release.

## Backups and hold music

Open **System → Backups**, set a backup password and schedule, choose retention, and include voicemail/recordings when required. Save the password separately from the server. Encrypted backups support local storage and SFTP. Restore onto a separate clean Debian instance; restored calling and job services remain held until explicit activation. Read [backup and restore](backups.md) before using the restore command.

The stock hold-music default uses the bundled CC0 instrumental. Existing custom music choices are retained; phones do not stream the song from an external website. See [music on hold](music-on-hold.md) for its source, licence and actual call evidence.

Release archives contain no customer backups, account credentials, signing keys or existing recordings. The supported V20 configuration importer remains independent of 3CX software and proprietary clients.
