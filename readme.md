# OpenWeb PBX

**A free, open-source business phone system, built to make calling simpler.**

Run your own multi-tenant PBX with FreeSWITCH-powered calling, a Windows 11-inspired administration desktop and a native Android phone app. Give each business its own people, numbers and call rules, while managing the server in one place.

[Website](https://openwebpbx.com/) · [Downloads](#downloads-and-platforms) · [Get started](#get-started) · [Documentation](#documentation) · [Roadmap](3CX.md) · [Community](https://github.com/embire2/openwebpbx/discussions)

![OpenWeb PBX setup checklist inside its desktop administration interface](docs/images/pbx-setup.png)

*The administration interface, showing an empty setup workspace. No customer data is pictured.*

## Our mission

OpenWeb PBX is a nonprofit, open-source project working towards a business phone system that anyone can install, understand and improve. Our first goal is to deliver the familiar, practical workflows people value in 3CX, then build beyond them with our community.

There is no OpenWeb software licence fee. You control your server and data; hosting, phone providers and optional external services have their own costs. Businesses, telecom providers, IT teams and self-hosting enthusiasts are welcome.

## Downloads and platforms

**Choose a component below.** Server, administration updates and phone apps have separate versions; the most recent GitHub release is not necessarily a complete server installer.

| Component | Public download | Platform and status |
|---|---|---|
| **PBX server** | [Debian 1.0.21](https://github.com/embire2/openwebpbx/releases/download/v1.0.21/openwebpbx-1.0.21-debian13-amd64.tar.gz) · [Install guide](docs/installing-debian-1.0.21.md) | Complete server for **Debian 13 amd64**. Includes the local database, calling engine, web administration and background services. |
| **Earlier administration update** | [Admin 1.0.19](https://github.com/embire2/openwebpbx/releases/tag/v1.0.19) · [Apply guide](docs/incoming-routing-1.0.19.md) | A focused incoming-call-routing update for supported Debian/core 1.0.16 installations. **Not a complete server installer.** |
| **OpenWebPBX Free Phone — Android** | [Android 1.0.19 APK](https://github.com/embire2/openwebpbx/releases/download/v1.0.19/openwebpbx-1.0.19-android.apk) · [Release notes](https://github.com/embire2/openwebpbx/releases/tag/android-v1.0.19) · [Setup guide](docs/android-tenant-addresses-1.0.18.md) | Native **Android 9+** app with a five-second logo launch screen; calls and updates bypass branding. Registered `*.openwebpbx.com` tenant addresses and compatible APIs are required. Managed updates require server 1.0.20+. Mandatory on the hosted instance. Google Play publication is pending. |
| **OpenWebPBX Free Phone — Windows** | [Development source](https://github.com/embire2/openwebpbx/tree/feature/windows-free-phone-v1.0.0/clients/windows) · [Client plan](docs/windows-client-plan.md) | Native C# and WinUI 3 client in development for **Windows 11 and Windows Server 2025 Desktop Experience**. Development-package install/update/relaunch checks pass; calling and production distribution remain under qualification. No client download or Microsoft Store listing is available yet. |
| **Windows Server** | [Windows 1.0.21 ZIP](https://github.com/embire2/openwebpbx/releases/download/v1.0.21/openwebpbx-1.0.21-windows-x64.zip) · [Install guide](docs/installing-windows-1.0.21.md) | Complete implemented server suite for **Windows Server 2025 x64 with Desktop Experience**, including the local database, calling, web administration, Phone Health, conferences, backups, updater and native server manager. |

**Server 1.0.21 — Complete Windows and Debian server1.0.21 release.** Choose the complete Windows Server 2025 Desktop Experience or Debian 13 amd64 package and its matching guide. Both include Greetings, company-group hours, Keoma speech, Add DID and Android19 tenant/QR support. Windows adds five-minute update checks with desktop notices and a red web banner. **Later** keeps services running; chosen installation waits for active calls. Windows 1.0.20 uses its signed updater. Original Debian 1.0.16 first requires the verified signed revision2 feed-compatibility bootstrap. [Release scope](docs/release-1.0.21-qualification.md) records separate platform checks and limits.

**Android compatibility:** Android 1.0.19 remains the phone release. Install app updates over the existing app to retain accounts. Server 1.0.21 includes compatible tenant/QR APIs; an app update alone does not add them to a stock Debian 1.0.16 server. Follow the [tenant-address guide](docs/android-tenant-addresses-1.0.18.md) and the Debian server upgrade instructions.

Release pages include checksums, signed update metadata and corresponding source. [All releases](https://github.com/embire2/openwebpbx/releases) · [Download catalogue](https://openwebpbx.com/#downloads) · [Updates and recovery](docs/updates.md)

**Build from the matching source.** Windows uses [`v1.0.21`](https://github.com/embire2/openwebpbx/tree/v1.0.21) and its [application source](https://github.com/embire2/openwebpbx/releases/download/v1.0.21/openwebpbx-1.0.21-source.tar.gz). Debian uses [`debian-v1.0.21`](https://github.com/embire2/openwebpbx/tree/debian-v1.0.21), its [application source](https://github.com/embire2/openwebpbx/releases/download/v1.0.21/openwebpbx-1.0.21-debian-source.tar.gz) and [complete Debian engine source](https://github.com/embire2/openwebpbx/releases/download/v1.0.21/openwebpbx-1.0.21-debian13-engine-source.tar.gz). Choose the Debian snapshot for Debian builds. The unchanged Windows engine retains its [corresponding source](https://github.com/embire2/openwebpbx/releases/download/v1.0.16/openwebpbx-1.0.16-engine-source.tar.gz).

## Get started

### Windows Server 2025

Download the Windows ZIP and its `SHA256SUMS`, verify the checksum, extract the complete archive and open **Start-OpenWebPBX.cmd**. Choose **Setup**, enter the server hostname and administrator details, and follow the first-call checks. Setup installs PostgreSQL locally; tenants do not need separate databases. Follow the [Windows guide](docs/installing-windows-1.0.21.md) for certificates, network access and backup/restore. Use the upgrade guide for an installed PBX.

### Debian 13

1. **Prepare a Debian 13 amd64 server.** Point your PBX hostname at it and obtain a trusted HTTPS certificate. Download the complete Debian archive above, verify its `SHA256SUMS` entry and extract it into an empty directory.
2. **Install the server.** Run the command below as root, using your hostname, public IP and certificate paths. Setup prompts for the administrator password and installs PostgreSQL on the same machine; tenants do not configure databases.
3. **Add your team and test a call.** Sign in at your server's HTTPS address, open **Users**, connect two phones, and call between them. Add your phone provider under **Voice & Chat**, set your incoming destinations and outbound rules, then test an incoming and outgoing call before moving live numbers.

```sh
./install.sh --domain pbx.example.com --address YOUR_SERVER_IP --email admin@example.com \
  --certificate /path/to/fullchain.pem --certificate-key /path/to/privkey.pem
```

The [installation guide](docs/installing-debian-1.0.21.md) covers certificates, local trials and existing installations. Use the documented updater for an installed PBX; fresh setup protects existing installations from replacement.

For Android, use **Users → Phone Provisioning → Connect Android App · QR Code** on a compatible server and scan the single-use setup code. Current hosted accounts first confirm their tenant address. Read the [Android guide](docs/android.md) for permissions, supported controls and incoming-call setup.

## What you can build with it

- **Business calling:** SIP providers, extensions, incoming numbers, outbound rules, ring groups, digital receptionists and voicemail. [Calling guide](docs/core-calling.md)
- **Add numbers from the trunk:** enter a DID and choose who receives its calls, then continue directly into Call Me Back with that number selected. Included in the complete 1.0.21 server packages. [Guide](docs/trunk-options.md#add-an-incoming-number)
- **A PBX for multiple businesses:** separate tenant workspaces, departments, staff roles and routing, with one local database per installation. [Users and departments](docs/users-and-departments.md) · [Staff permissions](docs/department-staff.md)
- **Practical call handling:** office hours, breaks, holidays, temporary Open/Closed overrides and a routing preview; receptionist transfer, pickup and parking; queues, callbacks and a wallboard. [Routing](docs/core-calling.md#opening-hours-and-routing) · [Switchboard](docs/core-calling.md#receptionist-switchboard) · [Queues](docs/core-calling.md#queues-callbacks-and-wallboard)
- **Company schedules:** manage office hours directly inside a company group, with optional separate in-office and out-of-office destinations for each extension. Included in the complete 1.0.21 server packages. [Guide](docs/company-office-hours.md)
- **Greetings:** call an extension or outside number to record, press #, replay and save; create Keoma narration from text; manage and reuse voicemail, receptionist, queue and hold audio. Existing custom recordings are preserved. Included in the complete 1.0.21 server packages. [Guide and activation](docs/greetings.md)
- **Native mobile calling:** Android voice and optional colleague-to-colleague video, a company directory, recent calls, visible Hold/Resume, transfers, personal settings and multiple tenant profiles on compatible servers. [Android](docs/android.md) · [Video](docs/android-video.md)
- **Meetings and useful services:** hosted audio/video conferences, versioned system voice prompts, own voicemail on **121**, a GMT+2 talking clock on **1026** and optional Call Me Back services. [Meet](docs/meet.md) · [Voicemail and clock](docs/voicemail-and-clock.md) · [Call Me Back](docs/call-me-back.md)
- **Manageable operations:** encrypted scheduled backups, retention and restore, global outgoing mail, and signed downloads with call-aware update policies and recovery. [Backups](docs/backups.md) · [Updates](docs/updates.md)
- **Phone Health & Recovery:** see which phones and providers need attention, identify verified office security blocks and request controlled recovery. Included in the complete 1.0.21 server packages; deployment checks still apply. [Feature guide](docs/phone-health.md)

The desktop provides familiar windows, a searchable Start menu, a centred taskbar and light/dark themes. Administration stays in your browser; the Android app handles calls natively.

## Moving from 3CX

The supported **3CX V20 backup importer** preserves restored extension numbers, separate authentication IDs, password bytes and supported call-handling settings. Review **Restore Report** for unsupported items and use the [desk-phone migration guide](docs/desk-phone-handover.md) before changing phone domains. A successful import still needs real phone and provider checks before a cutover.

OpenWeb PBX is independently developed software. Proprietary 3CX apps and hosted services are not supplied or made compatible by importing a backup. Complete 3CX feature parity is our development goal; the [roadmap](3CX.md) currently tracks **133 goals: 21 accepted, 72 partial and 40 planned**.

## Current status

The published Debian release has documented installation, signed-update/recovery, encrypted restore and software calling checks. The hosted ring-group repair has also been confirmed on an actual outside call: the phones ring, the caller hears ringing and both parties hear each other after answering. Hosted trunk Options and incoming routing are documented in the [core status](docs/core-system-status.md).

Hosted Debian now also provides Phone Health, persistent incident banners and optional administrator emails through the global outgoing-mail queue. Recovery is limited to a verified office sign-in block, with explicit owner confirmation and security-service acknowledgment. [Operating guide and tested limits](docs/phone-health.md).

Hosted core **1.0.21** also provides Greetings and company-group office hours. Deployment preserves existing extension credentials, provider routes and customer audio; all seven expected desk phones remain registered. A normal administrator sign-in, genuine Keoma text generation and authenticated greeting download pass. This focused hosted deployment does not replace the separately versioned public Debian installer.

Hosted voicemail email now queues complete audio before sending. Failed delivery retains the mailbox recording; attachment-and-delete removes it after outgoing-server acceptance. The hosted recipient has confirmed test-email receipt and WAV playback. [Delivery verification and retention limits](docs/voicemail-mail-delivery.md).

Hosted system speech now uses **Keoma voice pack1.0.2**, including default voicemail and **clock 1.0.3**. All 4,915 stock spoken files were replaced; custom recordings and music were preserved. Actual software calls verify Keoma default voicemail, an unchanged custom greeting and three complete GMT+2 clock announcements. Android 1.0.19 is published and mandatory on hosted accounts; its signed APK, Play bundle, corresponding source and public download feeds have been verified.

Hosted21 also repairs automatic office reopening and protects voicemail email attachments. A controlled live recording passes outgoing-server acceptance and deletion checks; failed sends retain the message. [Voicemail and email](docs/voicemail-and-clock.md).

These results cover their recorded test scope. Broader physical phone/camera coverage, restrictive networks and TURN, measured meeting capacity, carrier cutovers and Google Play acceptance remain open. [Feature coverage](docs/feature-coverage.md) records evidence and limitations; [release qualification](docs/release-1.0.21-qualification.md) records the current packages. Recent development details belong there and in [release notes](https://github.com/embire2/openwebpbx/releases), rather than in the installation steps.

## Automate tenant setup

The hosted [Tenant API](https://openwebpbx.com/api-docs) lets integrations register and verify an account, create an isolated PBX from an approved starter template, and request its managed `*.openwebpbx.com` address. It includes tenant-scoped keys, password changes, quotas, idempotent creation and DNS/certificate readiness polling. See the [integration and operator guide](docs/tenant-api.md) and [OpenAPI 3.1 contract](docs/tenant-api.openapi.json).

The API is live on the hosted installation. This separate source update does not modify the published 1.0.21 server archives; self-hosted packaging and Windows native qualification for the new API belong to the next server release.

**Installing your own server?** The [public setup wizard](https://openwebpbx.com/wizard) connects a new installation using its setup code, email confirmation and chosen `*.openwebpbx.com` address. The central API now also documents signed installation authorization and a dedicated [Webhotel/first-boot API](https://openwebpbx.com/wizard-openapi.json). Your local PBX and database stay on your server; no second hosted PBX is created. See the [image and onboarding guide](docs/webhotel-onboarding.md).

The [self-install registration guide](docs/self-install-onboarding.md) explains the installer flow, calling rules, accepted checks and remaining package/image release work.

The public wizard and central API overlay are deployed. Mandatory registration gates, the portable first-boot worker and updated Debian/Windows installers are current source for the next packaged build; complete native/package qualification and provider-image publication remain separate. Existing published downloads and working phone settings are unchanged. A controlled central pairing test has completed real DNS, Let’s Encrypt and verified tenant HTTPS readiness; its email code was intercepted privately, so no new inbox-delivery or native-installer pass is implied.

## Documentation

| Start here | Administration and operation | Development |
|---|---|---|
| [Windows installation](docs/installing-windows-1.0.21.md) · [Debian installation](docs/installing-debian-1.0.21.md) | [Provider and first calls](docs/core-calling.md) | [Roadmap](3CX.md) |
| [Android setup](docs/android.md) | [Desk-phone migration](docs/desk-phone-handover.md) | [Feature coverage](docs/feature-coverage.md) |
| [Remote Yealink W60B](docs/yealink-w60b-remote.md) | [Phone health and recovery](docs/phone-health.md) · [Backups](docs/backups.md) | [Core system status](docs/core-system-status.md) |
| [Tenant addresses](docs/tenant-phone-accounts.md) | [Meetings](docs/meet.md) | [Windows calling-client plan](docs/windows-client-plan.md) |

## Help shape OpenWeb PBX

Try it in a test environment, share your experience in [Discussions](https://github.com/embire2/openwebpbx/discussions), report a reproducible problem in [Issues](https://github.com/embire2/openwebpbx/issues), or contribute a focused pull request against **`customization`**, the development/default branch. Useful contributions include phone/provider testing, documentation, translations, accessibility and code.

Include the server/app version, expected behaviour and a small reproduction. Remove credentials, phone numbers, account data and private logs before posting. Check the roadmap and discuss a substantial change before building it. [Source history](https://github.com/embire2/openwebpbx/commits/customization/) retains both upstream and OpenWeb development history; its commit count is not a count of original OpenWeb changes.

## Origins, licences and credits

OpenWeb PBX began from [FusionPBX](https://github.com/fusionpbx/fusionpbx), originally its stable `5.6` branch, and is powered by [FreeSWITCH](https://github.com/signalwire/freeswitch). We acknowledge those projects and their contributors. This project's branding, roadmap and releases are maintained by OpenWeb; original history, copyright notices and licences remain intact. [Repository independence](docs/repository-independence.md) records the pending GitHub fork-network detachment and the owner request needed to preserve releases and history.

The server retains the [Mozilla Public License 1.1](LICENSE) and existing component licences. The native Android client in [mobile/android](mobile/android/) is **AGPL-3.0-or-later**, with its own component notices and corresponding source. Additional distribution notices are in [packaging/licenses](packaging/licenses/). Operational paths such as `/etc/fusionpbx` remain for installation compatibility.

The bundled hold track is Seth_Makes_Sounds' **Lofi Beat Loop Schmoop**, released under CC0. [Music credits and provenance](docs/music-on-hold.md). OpenWeb PBX is not affiliated with or endorsed by 3CX.

[Privacy](https://openwebpbx.com/privacy) · [Terms](https://openwebpbx.com/terms) · [Delete account/data](https://openwebpbx.com/delete) · [Cookie choices](https://openwebpbx.com/cookies) · [Company information](https://openwebpbx.com/legal)
