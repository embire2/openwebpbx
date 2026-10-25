# Install OpenWeb PBX 1.0.21

This complete server build targets **Debian 13 amd64**, with a separate **Windows Server 2025 x64** package that requires its own qualification. The current Android client remains **1.0.18/code118**. Historical Windows server releases remain available; the native Windows calling app is under separate development. See the [Windows client plan](windows-client-plan.md).

**Windows Server1.0.21 has completed functional qualification; Debian1.0.21 remains a candidate.** For the Windows release, use the [focused Windows guide](installing-windows-1.0.21.md) and matching published assets. This general guide also records the candidate Debian flow. Follow the [release qualification record](release-1.0.21-qualification.md) and [Windows release checks](windows-parity-1.0.21.md); current public downloads are listed in the [README](../readme.md#downloads-and-platforms). Once your platform is published, use its matching archive and `SHA256SUMS`, and extract the complete archive into an empty private folder.

**Install only a published package whose release notes record the completed qualification for your platform. Development archives are not stable releases.** Release preparation is authorized; the exact package must finish its functional qualification before publication.

Version 1.0.21 includes admin incoming-route controls, the mandatory Android18 tenant-address support, managed tenant addresses, manual extension/app-password sign-in, separate simultaneous phone profiles and inline-QR/setup-file welcome invitations. Read [tenant phone accounts](tenant-phone-accounts.md) and [the Play submission audit](google-play-audit-1.0.17.md). It retains Meet audio/video conferences, Nathaniel UK default prompts, PIN-free own voicemail on **121**, the repaired GMT+2 clock on **1026**, optional Call Me Back and native Android video. It retains the department roles, phone-handover checks and provider evidence delivered in 1.0.15. Read [Meet](meet.md), [Android video](android-video.md), [staff access](department-staff.md), [phone handover](desk-phone-handover.md) and [first calls](core-calling.md). Physical phone/camera and carrier qualification remain separate.

Windows publication requires its own current native build, complete package, upgrade/recovery and restore checks. Check the release notes for the exact platform status; a Debian pass does not qualify Windows. Google Play publication, physical W60B/V62W checks and broader 3CX parity remain open.

## PHP security update

Apply the current PHP security updates before deployment. On 21 October 2026, PHP released 8.4.27 to fix two critical web-request vulnerabilities; see the [official advisory](https://www.php.net/archive/2026.php#2026-10-21-5). The Windows installer pins the fixed 8.4.27 runtime and its SHA256. Fresh Debian setup obtains PHP from its configured package repositories. Existing Debian installations must apply the vendor's PHP security updates too, including PHP-FPM and CLI, and verify that their installed build includes both fixes. The complete server archive does not bundle Debian PHP packages.

## Windows Server installation

Use the matching `openwebpbx-1.0.21-windows-x64.zip` only after publication with its completed Windows qualification recorded. Windows Server 2025 x64 with Desktop Experience is the supported server target. The server installer refuses Windows10/11; the native Windows calling client is a separate project.

Extract the complete archive to a private directory and run **Start-OpenWebPBX.cmd**. It checks Microsoft's required runtime before opening the WinUI manager. Choose **Setup**, enter the server hostname and administrator email/password, and select **Automatic public certificate**. Approve Windows' administrator prompt to install. The hostname must point at the server, with TCP80/443 and the documented SIP/audio ports reachable. After setup, use the installed desktop shortcut. The equivalent command in built-in **Windows PowerShell5.1 as Administrator** is:

```powershell
.\Install-OpenWebPBX.ps1 -DomainName 'pbx.example.com' -EnablePublicAccess -AdminEmail 'admin@example.com'
```

Setup installs the local PostgreSQL database, IIS/PHP, call engine, background service, updater, backup tooling, offline Nathaniel prompts, secure meeting proxy and the server manager. No separate database server is needed. The call engine starts during setup; provider trunks must be configured and explicitly enabled before provider calls can run. For a clean replacement receiving an encrypted **Windows** instance backup, add `-RestoreServer` and retain the original public hostname and HTTPS port. Debian instance backups are not accepted by the Windows restorer; the 3CX configuration importer is a separate migration path. See [Windows meeting transport](windows-meet.md) for the scoped proxy prerequisites and recovery behavior. Preserve existing installations and use the manager/updater's documented upgrade path; never run a fresh installer over an existing PBX. Check [Windows upgrade guidance](windows-upgrade.md), the platform's actual release notes and the feature-coverage limits before replacing a production system.

Before setup, finish any pending Windows restart and use an administrator account. The launcher checks the required Microsoft Visual C++ x64 runtime and verifies Microsoft's signature before installing it; follow a requested restart before continuing. Use built-in Windows PowerShell 5.1 for setup, because its IIS modules are required. The release supplies its application runtimes; installing Visual Studio is not a server prerequisite.

For public access, point one public IPv4 DNS record at the server or its forwarding router. The standard network plan uses TCP80/443 for certificate validation/web access, TCP/UDP5060 for phones, TCP/UDP5080 for providers, TCP5061 for phone TLS, UDP16384–32768 for call audio and UDP3478 for STUN. SIP rules follow the actual configured listeners. The installer does not configure an upstream router; STUN is not a TURN relay. See the [Windows network and certificate guide](../packaging/windows/ACME.md) for the exact checks and renewal behavior. PostgreSQL, the call-engine control socket and the local service API stay local.

After setup, verify all of the following before moving live numbers:

- Open the installed manager and check its version and Running status; sign in through the intended trusted HTTPS hostname without a certificate warning.
- Connect two phones and prove ringing, two-way audio, hold/resume and voicemail. Then test the configured provider's incoming/outgoing calls and routes.
- Verify Phone Health shows the expected registrations, send a controlled welcome email, and test the tenant address/Android connection and any browser meetings you use.
- Create and verify an encrypted backup. For a replacement, follow the [Windows backup and restore guide](windows-backups.md), including separate activation of calls and jobs.
- In a planned maintenance window, restart Windows and repeat service, HTTPS and calling checks. This is still an open qualification step, not a claim that a native reboot has passed.

## New Debian server

Use a clean Debian 13 computer. Point a hostname at its public IP address and supply a trusted HTTPS certificate for that hostname. Run from the extracted folder as root:

```sh
./install.sh --domain pbx.example.com --address YOUR_SERVER_IP --email admin@example.com \
  --certificate /path/to/fullchain.pem --certificate-key /path/to/privkey.pem
```

Enter the administrator password when prompted. For an isolated local test, use `--local-certificate` instead of the two certificate arguments. A local test certificate does not allow ordinary remote Android enrollment.

Setup installs PostgreSQL on the PBX computer, creates one database shared by all tenants, installs the call engine and web administration, and starts the independent updater and backup schedule checker. Tenants do not enter database settings. An existing PBX database or configuration is refused before replacement. Compatibility identifiers keep the internal name `fusionpbx`. The installer supplies the program-directory permissions required by its services, including installation prepared under umask 077; private configuration permissions stay restricted.

Incoming destinations are available under **Voice & Chat → select a trunk → Incoming Calls**. Choose an Extension, Ring Group, Digital Receptionist or a prepared Call Me Back service; preserve closed/holiday routes independently. See [incoming routing](incoming-routing-1.0.19.md). **Options** adds per-trunk calling permissions, department use, shared call capacity and provider connection/audio settings. Ring Groups use ringing while offering their member phones, including after an answered receptionist. Read [trunk options and ring-group ringing](trunk-options.md) before activating the new policy on a restored trunk.

The tenant-address worker proves control of the trusted public HTTPS hostname, reserves names through the OpenWeb registry and obtains tenant certificates. Allow inbound TCP80/443 and outbound trusted HTTPS/DNS; no central DNS credentials are distributed. Local-only test installations retain canonical QR setup while public proof is unavailable. Pending names must complete DNS and certificate checks before manual sign-in. The global outgoing-mail dispatcher is installed with fresh instances; existing custom or deliberately disabled dispatchers retain their settings.

Open your server's HTTPS address and sign in. Setup creates Main PBX with **100 Reception** and **101 Office**. No provider is enabled automatically. Private configuration lives in `/etc/fusionpbx` and `/etc/openwebpbx`, media in `/var/lib/freeswitch`, and application source in `/var/www/fusionpbx`. The installer configures the shared PHP/background-service notification store at `/var/lib/openwebpbx/mobile-notifications/config.json`, inside a web-account-owned mode-700 directory with mode-600 configuration and lock files. The root-owned parent retains its existing permissions and is not writable by the web account. No manual credential file is needed. Notification configuration and lock files are created when wake-up settings are first saved.

For a replacement receiving an encrypted instance backup, add **`--restore-server`** to the install command. Setup then creates an administrator and empty restore target, without sample extensions or tenants. Use the original server hostname and the same release as the backup; follow [backup/restore](backups.md) before activating calls.

## Existing Debian server

If you are on **1.0.16 with its original updater**, first apply the signed [revision 2 feed-compatibility patch](https://github.com/embire2/openwebpbx/releases/download/v1.0.18/openwebpbx-1.0.18-debian16-feed-compat-r2.tar.gz) from the [1.0.18 release](https://github.com/embire2/openwebpbx/releases/tag/v1.0.18). The patch is 102,260 bytes, with SHA256 `12e8a0fff65444badbdf965d15022b88302c73a103b90d4051b5456804a651e8`. Extract it into a private folder, enter its directory, and run as root:

```sh
python3 split-android-feed.py
python3 split-android-feed.py --apply
```

Preflight verifies the signature and exact supported files. Applying takes a recovery copy and restarts only the independent update worker; calling services and phone settings remain unchanged. The hosted instance already has this patch. The generic phone feed stays Android 1.0.18, while the patched server checks the separate Debian feed for 1.0.21. Older servers need the documented intermediate upgrade to 1.0.16 first. Do not use the fresh installer over an existing PBX.

Open **Admin → System → Updates** and install the new version. The complete signed download is checked before maintenance; active calls defer installation. Migration installs the new backup helpers automatically, including when the previous installed updater does not know those files. A private recovery snapshot covers the application, database, configuration and newly installed helper files. See [updates](updates.md) for policies and recovery.

Installed upgrades add only new default metadata; existing choices, permission denials and null voicemail preferences are preserved against the sealed previous source. Explicit manual defaults commands outside an active updater transaction keep their documented behavior.

Version 1.0.21 retains the notification-store permission correction introduced in 1.0.10 after a normal Incoming Call Wake-up save failed in 1.0.9. When the new store is absent, migration copies the legacy notification configuration without changing its keys; an existing new configuration takes precedence. PHP and the background service use the configured private store, and the previous file is retained untouched for rollback. Recovery restores prior file bytes, modes and owners. Use the updater rather than moving secrets or changing the private parent directory by hand.

The additive distribution dependencies introduced in 1.0.9 are SoX, Python cryptography and the OpenSSH client. If an older updater encounters a package mirror problem, the update fails and retains its recovery snapshot; check the instance's private update log and retry once the package source is available. Existing 1.0.3 installations still need the documented one-time updater bootstrap. The fresh installer must not be used over an installed PBX.

## Restore existing desk phones

Upload the supported 3CX V20 backup through **Admin → Backup & Restore**. Confirm the timezone and phone domain once. Original extension numbers, separate Authentication IDs and password bytes are preserved. See [the Yealink W60B/Fanvil V62W guide](desk-phone-handover.md). **Phones → Change phone domain** adds an exact owned address to an existing PBX while preserving its canonical app/routing domain. Domain ownership and enabled state are checked from the database on each relevant directory lookup; matching a hostname suffix is insufficient.

The Debian engine includes the reviewed FreeSWITCH registration patch. It preserves canonical registration bindings, response Contacts, refresh/unregister and original incoming phone identity. During an installed upgrade, the new hook verifies the signed package and the pinned engine library, atomically adds the previous module to the recovery snapshot, and replaces it only after the engine has stopped. The earlier updater can restore its bytes, mode and owner along with the previous database/configuration. An unrelated engine build is refused. Fresh installation installs the guarded directory before allowing separate SIP and authentication usernames.

Imported provider connections remain off until their arranged handover. In **First Calls**, **Connect Provider and Numbers** enables one reviewed provider and all its incoming routes together, retaining destinations, outgoing order and hours. A failed incoming-rule update rolls back the complete transaction. Finish the actual phone and carrier checks before switching off the previous PBX.

## Set up the first calls

Open **Admin → Voice & Chat → Add SIP Trunk**. Enter the provider's details, choose who answers the main number, set opening hours, and choose the outside dialing rule. New connections stay off until you enable them for the agreed handover. Use **First Calls** for connection checks and real internal, incoming and outgoing test results. Confirm speech, caller ID, menu keys and any backup-provider route on the actual phones. Keep the previous system available until those paths pass.

**Office Hours** includes multiple periods, overnight opening, breaks, holidays and temporary Open/Closed overrides. **Call Routing** previews the destination for a chosen time. **Switchboard** and **Queue Wallboard** show scoped calls and agent state; call handling uses connected phones. See the core operating guides linked from [feature coverage](feature-coverage.md) for qualified behavior and remaining limits.

## Android connection and wake-up

Install the signed APK. You may enter the tenant address, extension and administrator-chosen app password, scan a QR code, or import the `.openwebpbx` attachment from a welcome email. Settings provides Accounts and App password controls; multiple accounts can receive calls simultaneously. See [tenant phone accounts](tenant-phone-accounts.md). To show a QR code, open **Users → Phone Provisioning → Connect Android App → Show QR code**. Scan the single-use code in the native app and allow microphone and notification access. The app supports Android 9 or later. Use OpenWeb PBX 1.0.12 or later for availability, queues, wake-up and the instance-wide direct-app minimum release.

In **System → Incoming Call Wake-up**, enable incoming wake-up and save. Automatic setup is the default. The instance generates its own notification keys in the installer-managed private store; no Firebase project is needed. After saving, reload the page and check that the configuration remains enabled. Configuration success does not establish locked/idle phone delivery. Supported phones use installed Google Play Services through the open-source native distributor. An optional Cloudflare relay forwards encrypted messages; audio and phone credentials stay on the PBX. See [wake-up setup](android-push.md).

The native app uses an active, unsuspended network and successful trusted PBX registration for calling readiness. A failed Android public Internet check alone does not disable calls to a reachable PBX. Real network loss still triggers recovery and bounded cleanup.

Keep the connection notification enabled. Android force-stop prevents wake-up until the app is reopened. Physical handset sleep, battery restrictions, network handover and proximity qualification are tracked separately in [the roadmap](../3CX.md). Google Play publication still requires the owner's account verification and Google's review; the Play bundle is a submission artifact, not an approved store release.

## Visible call controls and personal Settings

During a connected call, **Call Hold** appears across the active-call panel on Keypad, Contacts, Recents, Voicemail and Settings. Tap it to put the call on hold with music for the caller; tap **Resume Call** to continue speaking. Holding a merged three-way conversation holds both remote participants. If one participant leaves while held, the remaining caller stays held until you press **Resume Call**. Keep **End call** for ending a conversation.

Open **Settings** beside the app heading to choose **System**, **Light** or **Dark** appearance; select an Android ringtone; turn **Keypad vibration** on/off; choose **Keypad**, **Contacts**, **Recents** or **Voicemail** as the startup page; and sort contacts by **Name** or **Extension**. Changes apply to this phone. The ringtone follows Android volume and Do Not Disturb settings. Silent, unavailable and network sounds are not accepted; an unavailable saved ringtone falls back to the system ringtone.

Settings also shows the account and app version, your status and queue controls, connection checks, call-audio controls and update options. Microphone, incoming-alert and battery shortcuts open the appropriate Android controls. Read-only account details do not expose your SIP password. **Reset personal settings** returns appearance, ringtone, startup, sorting and vibration to defaults without disconnecting your account or removing update trust. **Disconnect this phone** is a separate action that removes this phone's connection and local account data. Privacy/support and component licences remain available.

## Require the direct Android release across tenants

After the release downloads and signed feed are verified and the server is upgraded, an instance administrator can open **System → Updates → Minimum direct Android release for every phone** and set the minimum to **1.0.18** (Android version code **118**). The server refuses a minimum newer than its installed supported Android marker. This requirement starts inactive on a fresh installation and covers existing/future tenants, newly connected phones and phones without a tenant phone-policy assignment.

A direct app below the minimum receives a required update. A tenant administrator cannot lower the instance requirement; their saved update preference is retained and applies once a 1.0.18 app meets the minimum. Clearing the minimum removes the instance requirement. Signed package availability, platform/server compatibility, active-call deferral, urgent-call access and Android installation confirmation still apply. Users may need to tap **Open** after installation.

The setting does not create a published Google Play update: Google's account/testing/review and a verified production Play version remain required. Historical browser, iPhone and Windows calling-client plans are not installed clients to upgrade. See [updates](updates.md) for exact policy and recovery behavior, and [core system status](core-system-status.md) for delivered features and open acceptance goals.

## Backups and hold music

Open **System → Backups**, set a backup password and schedule, choose retention, and include voicemail/recordings when required. Save the password separately from the server. Encrypted backups support local storage and SFTP. Restore onto a separate empty installation of the same platform and release; restored calling and job services remain held until explicit activation. Follow the matching [Debian guide](backups.md) or [Windows guide](windows-backups.md), including each platform's current qualification limits. Debian/Windows cross-platform instance restores are unsupported.

Existing hold music is retained. The stock hold-music default uses the bundled CC0 instrumental. Existing custom music choices are retained; phones do not stream the song from an external website. The earlier 1.0.11 native tests verified music on the single held call, both conference legs and the remaining held caller, followed by resumed media. [Feature coverage](feature-coverage.md#visible-call-controls-personal-settings-and-instance-phone-floor--1011) records the complete window/continuous-RTP proof and preserved failed long fixed-offset comparison. See [music on hold](music-on-hold.md) for the track source and licence.

Release archives contain no customer backups, account credentials, signing keys or existing recordings. The supported V20 configuration importer remains independent of 3CX software and proprietary clients.

## Core 1.0.21 integration

This package includes Nathaniel UK default speech, PIN-free own-mailbox access on **121**, the repeating GMT+2 talking clock on **1026**, hosted audio/video meetings, and native Android video between supported OpenWebPBX Free Phone clients. Custom recordings and greetings remain unchanged. See [meetings and video](meet.md) and [voicemail and clock](voicemail-and-clock.md). Call Me Back is included as an optional service; its customer number remains disabled until an administrator explicitly assigns a DID and completes provider testing. Tenant-named announcements need a privately configured ElevenLabs key. No API key is distributed.

During upgrade from an older helper, meeting proxy configuration is validated without activation until the transaction commits. The new independent updater completes proxy activation on its natural restart. Failed migrations retain the previous proxy runtime and complete database/file recovery. The duplicate legacy call-record importer is retired after a successful commit; the current call-record worker remains responsible for records.

Android 1.0.18 uses the existing app identity and signing certificate. Instance administrators may require this direct-app version across tenants using the update settings after the public signed assets and installed core are verified. Downloads are verified before installation and active calls defer installation. Android still controls installation permission, confirmation and reopening. The Google Play edition requires an actually published Play release; the prepared bundle does not establish approval. Native video may briefly pause audio and video when a camera stream restarts; the observed interval was about 0.83 seconds. Physical-camera, carrier, network handover and capacity testing remain open.
