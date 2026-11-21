# Debian 1.0.28 local qualification

**20 November 2026.** The standalone Debian 13 amd64 candidate is held locally
alongside its source and roadmap. Hosted Main runs 1.0.28. Public Debian and
Windows remain on 1.0.27, and Android remains on 1.0.19.

## Scope

- The shared analyzer, guided preview, native restore and phone handover use
  the same allowlist for 3CX V20 Update 9 `20.0.9.995` and the inspected Update 10
  `20.0.10.1801`. The importer reports additional missing audio and service
  numbers needing replacement.
- An instance administrator sees the Debian installed version, compatible
  verified offer, download state, status timestamp and **Update Now** on
  **Admin → System → Updates**. The existing automatic install policy uses a
  daily UTC window. The form displays the current or next window in the browser
  time zone.
- An exact previously failed release remains paused for automatic installation.
  The updater verifies it again before offering an administrator a manual
  retry. The existing signature, compatibility, active-call, backup and
  rollback checks still govern an installation.

## Regression evidence

| Check | Result |
| --- | --- |
| Import and phone mapping | 66 bounded parser checks, 18 phone identity and readiness checks, and 241 Lua calling policy decisions passed. The real Update 10 archive passed read-only guided and native validators. |
| Debian Updates page | 105 isolated PostgreSQL controls passed. Chromium saved and displayed the selected UTC window in Johannesburg time, queued one authenticated installation request, denied a request without CSRF, updated download and active-call status, and denied tenant access to instance controls. |
| Updater | 82 native signature, archive and maintenance checks, 18 native checks backed by isolated PostgreSQL, 17 Debian installer-tool checks and 12 Python signed-feed checks passed. The native database checks verified failed-release pause across restart and explicit retry. |

## Standalone package

`openwebpbx-1.0.28-debian13-amd64.tar.gz` is **489,018,172 bytes**, SHA-256
`5a84f62f17d31a020cef047337d6bcfbbe3ab3175a36ebf7098310ae69cc6f19`.
Its source is local commit `b98a741d2cb9bab91edfa27f56f20746ce228fc9` on
`debian-1.0.28-local`. The complete package manifest matches all 12,281
payload files and includes 4,915 spoken WAVs. The web application, separately
built Core and updater identify as 1.0.28. The fresh-install contract requires
Debian 13 amd64 and includes local PostgreSQL setup and the calling engine.

## Real Update 10 archive

The lab used a dedicated Debian 13 installation with a separate PostgreSQL
database and a loopback-only network. The verified 1.0.27 calling-engine input
is identical to the 1.0.28 package input. All changed application files in the
lab matched the frozen 1.0.28 archive byte for byte. This setup tests the
candidate application on a known calling baseline. The separate fresh
installer test is recorded below. The restore lab sped up
voice-file sync without changing the verified files, which leaves installation
durability outside this test.

The ordinary guided analyzer produced an encrypted draft and zero new PBXs
before confirmation. Isolated PostgreSQL restore then passed 26 identity and
configuration checks. All 23 extension numbers, authentication IDs and SIP
passwords matched the raw source. Both saved phones retained their identities
and provisioning settings. The 44 incoming rules and eight outgoing rules
kept their source choices, and all 19 trunks and imported incoming routes
started disabled.

Authenticated HTTPS passed the complete 498,469,175-byte upload, guided
preview and confirmation into a new PBX. An authorized download returned
partial WAV audio as requested and an anonymous request could not play it.
The first upload ran out of space in the lab's 197 MiB temporary filesystem.
The retry used the same application files and a private disk-backed PHP
upload directory. Follow the [temporary-space guidance](v20-restore.md) for
large backups.

The restore imported 128 recordings, 79 prompts, 66 voicemail messages,
12 voicemail greetings, 34 contacts and 43,999 call-history records. All
23 mailboxes used the existing PIN-free policy. Independent SHA-256 comparison
matched all 273 supported audio files and their 195,141,624 bytes to the ZIP.
Restored native voicemail messages and greetings also matched their source
audio. Carrier cutover and physical phone provisioning remain separate
acceptance steps.

Two software phones used their original distinct extension and authentication
IDs to register on the restored PBX. An answered call carried 245 and 243
packets in the two directions and decoded the expected tones on both sides.
The three authentication boundary checks passed and the registrations were
removed. The initial lab registration refusal came from a test-only directory
permission. Retain that result separately from the successful retry with
normal directory permissions and identical product code.

### Items requiring attention

| Item | Restore outcome |
| --- | --- |
| One bridge, one fax endpoint, one conference number and four park orbits | Restore Report lists them for replacement. Supported shared parking is handled separately. |
| Two PIN menu destinations | The target users were absent from the source. Select replacement destinations before use. |
| Four referenced prompts and 19 indexed voicemail messages | The archive lacked their audio. Replace the call prompts or recover the missing media from another authorized source. |
| Twelve saved greetings | Their audio was restored. Seven mailbox owners need to select an active greeting because the archive lacked that assignment. |
| 3CX apps, web account passwords and hosted mail | Use OpenWeb clients and account setup, and configure the PBX mail relay. |
| Two saved phones | Their settings and identities were preserved. Model-specific provisioning and handset cutover still need verification. |

## Update 9 regression

The previous private archive `20.0.9.995` passed preview, the same 26 restore
checks and all eight outbound-rule comparisons. All 1,168 supported WAVs
matched the original archive, including the audio for 66 native voicemail
messages and 12 greetings. Two restored identities registered and an answered
internal call carried 244 and 245 RTP packets with decoded audio verified in
both directions. The restored PBX passed its final ownership boundary checks.

## Hosted deployment

`call.openweb.co.za` is running 1.0.28. The hosted deployment verified the full
candidate checksum, retained an encrypted and authenticated 1.0.26 recovery
checkpoint and switched the eight changed web files, version file, native
Core and independent updater. The source and binary hashes matched the
candidate. The operation used an idle calling window and required 11.603
seconds to complete service and preservation checks.

All eight existing registrations remained present. The canonical row contents
of fourteen configuration tables matched, and the FreeSWITCH, nginx, PHP-FPM, PostgreSQL,
SSH and Fail2Ban service generations matched. HTTPS login, tenant console
and API documentation served with valid certificates. The API refused
anonymous credentials as expected. The independent updater verified its
normal signed feed and reported installed 1.0.28 as up to date. The deployed
runtime and original 1.0.26 recovery files remain available for recovery.

## Fresh install on the dedicated test host

The exact standalone Debian 13 installer completed on
the dedicated test host in a disposable Debian 13 guest with six
previous-installation paths absent and loopback-only network access. The
Ubuntu host OS was preserved. The archive checksum matched after transfer.
The standalone preflight and the installer each validated the full manifest.
The normal installer created its local database and administrator and
finished with the application, PostgreSQL, FreeSWITCH, PHP-FPM, Nginx, Core
and updater running. Core reported 1.0.28 and the fresh registration gate.

The guest's disk was slow during voice activation. After 315 ordinary durable
voice-file writes, the temporary trace accelerated only file and directory flushes
by the identified voice installation process. The trace detached, storage
was flushed and all 4,915 installed WAV hashes and the voice catalogue marker
matched the package. The immutable installer and product bytes were used.
An administrator signed in over locally trusted HTTPS and opened
**Software Updates**, with the installed 1.0.28 status, **Update Now** and
automatic installation options. Eleven selected installed web and native
files independently matched their package hashes.
This records functional clean-install and startup acceptance. Power-loss
durability and an external managed enrollment remain separate tests.

## Signed update and recovery on the dedicated test host

A separate disposable Debian 13 guest started from the verified stock 1.0.27
installer with normal PostgreSQL durability. A private, short-lived 1.0.28
offer admitted 1.0.27 and bound its pinned signature to the exact archive.
The guest served the offer at the canonical update URL within its loopback
network. An administrator saved an automatic window and used **Check for
updates**. No manual install command was queued during this automatic test.

The regular worker downloaded and verified the 489,018,172-byte archive. It
passed stock preflight, sealed a recovery checkpoint and deployed 1.0.28
under the saved automatic policy. A disposable guest-only startup fault
then caused the planned failure during validation. Both the helper and
worker reported `rolled_back`, and Core and the updater slot returned to
1.0.27. All ten protected tables matched the sealed checkpoint's exact
PostgreSQL rows. The original pre-login comparison flagged the expected
first-login password rehash. The accepted comparison uses the checkpoint's
post-login rows without column exclusions.

The guest used scoped batching for bulk filesystem flushes. The package,
signature validation, application installation, PostgreSQL, journal checks
and rollback logic used the stock inputs. This is functional rollback
evidence. Power-loss durability remains separate.

After the automatic recovery check, the administrator queued one ordinary
manual install request. The stock worker reused the verified download and
sealed a second checkpoint. This retry reached the real voice migration
and hit the package's fixed 600-second subprocess timeout on the constrained
test disk. The installer recorded failure in `migrating` and started
automatic recovery. Both journal and worker reached `rolled_back` from
`migrating`, and the manual request finished as failed. All six services
returned on 1.0.27, the original native slot and seven baseline file hashes
matched, and all ten protected tables matched the exact second checkpoint.
One partial voice temporary file was retained in the isolated guest as
evidence. This is an observed signed upgrade limitation on the test host.
The fresh and hosted 1.0.28 cases have their own acceptance.

## Remaining release acceptance

The earlier updater contract checks use fixture signing keys and a controlled
installer. The next Debian upgrade pass must avoid rewriting verified,
unchanged system voices, handle temporary files left if a voice worker is
terminated, and qualify a migration bound that accommodates slow disks
while preserving signed admission, maintenance and recovery. A successful
signed install after that correction is still open.
Windows importer acceptance and Windows automatic installation opt-in are
tracked in the [Windows ledger](debian-windows-sync.md).

[Installation guide](installing-1.0.28.md) · [V20 import behavior](v20-restore.md) ·
[Roadmap](../3CX.md)
