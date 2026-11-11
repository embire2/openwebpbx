# Full-media backup and replacement recovery — 9 November 2026

Hosted Debian remains **1.0.25**. Backup & Restore is available from the PBX
Dashboard and Tenant Admin. Public Debian/Windows 1.0.23 and Android 1.0.19
packages and signed feeds remain unchanged.

## Accepted backup and recovery

The administrator requested the full backup through the normal authenticated
Dashboard form. The natural installed worker completes it with media enabled:

- **2,435 files / 5,387,258,223 bytes** before compression.
- **3,098,453,525 bytes** encrypted; SHA256
  `e53e3b319333255cfb2fc6db43229ca0a589c0b620e070880bb8b21e42d27692`.
- The actual authenticated HTTPS download matches that size and checksum. A
  subsequent ordinary installed verification also succeeds.
- A wrong password is refused before replacement, with private files unchanged
  and no restore journal created.
- The downloaded copy restores through the normal replacement CLI in **887.157
  seconds**, within its original 1,200-second transaction bound.

The target is an independently booted, fresh Debian 13 container with its own
PostgreSQL 18 database, filesystem and network namespace. Its only interface is
loopback, with no external route. It uses matching 1.0.25 application/native
files and the reviewed current engine. The ordinary `configure.py
--restore-server` path prepares the empty target. The source operator's optional
G.729 module and library are supplied privately before activation; all 55
loadable engine modules then match source hashes. No optional codec binary is
added to a public package.

Independent comparison verifies all **202 tables**: 199 match exactly, while one
row in each of `v_pbx_backup_commands`, `v_pbx_backup_status` and `v_pbx_backups`
has the specified recovery-status change. Every other column/row remains exact.
All database object definitions and sequence state match. The target intentionally
owns its public schema through its local database account, with private default
permissions, rather than replaying source schema ownership/grants; that precise
initialisation difference is reviewed separately.

All **2,107 media files** match their archived SHA256 values. These are 2,063
PBX-storage files and 44 custom sounds; the dedicated recordings directory is
empty on this source. Nonempty recording-root recovery is covered by the fixture
suite. All 2,432 unchanged archived files, including media, private keys and
SIP/QR identity material, match. The two connection files retain the replacement
server's own database credentials and public media address, as designed.

The original administrator password works over verified lab HTTPS. Both recovery
status endpoints and the shared Tenant Admin controller work. The fresh server's
`/tenantadmin/` entry correctly keeps its normal **Connect your PBX** registration
gate; pairing is not bypassed in the offline clone. The live hosted Tenant Admin
entry separately verifies its Backup & Restore navigation.

All five persistent service holds remain present. A normal calls-only activation
starts a stable engine, exposes its protected event socket, runs the internal SIP
profile and loads the operator's G.729 codec. The calls hold is reinstated and
the engine stopped after that check. Background jobs, mail, backups and updates
stay held. The isolated test machine is stopped after qualification. Production
is never restored or stopped; its seven desk phones remain registered/Reachable
and its seven critical service activations predate this work.

The hosted instance now schedules full encrypted backups every day at **00:00
SAST (22:00 UTC)**, retaining **seven successful local copies**, with media
included. The saved encryption password is unchanged. The next run is tonight;
no extra daytime catch-up job is started. SFTP storage remains configurable.

## Maintenance changes and checks

- Both recovery pages refresh progress every 15 seconds without reloading or
  submitting forms. Polls retain authentication/workspace checks and do not
  create extra form tokens. Unsaved inputs survive updates; expired sessions
  stop polling and request sign-in.
- The worker refreshes liveness every 30 seconds during long create/check/send
  operations without overwriting results. The real large-archive verification
  observes **14 distinct active heartbeat timestamps**.
- Replacement recovery reports **Restore completed** instead of inheriting the
  source's **Creating** status. Schedules stay disabled until review.
- Full and tenant backups use gzip level 6 instead of level 9, with unchanged
  encrypted formats and full checksums. An 8 MiB media sample took 1.34 seconds
  at level 6 versus 8.66 at level 9, for about 3% more compressed data. This is a
  sample measurement, not a whole-server performance claim. The initial large
  production archive retains its original compression setting.

**21** real PostgreSQL/crypto/full-recovery tests and **54** tenant isolation,
encryption and recovery controls pass. Actual Chromium verifies progress,
unsaved inputs, session expiry and no page errors. A foreign workspace returns
403 and anonymous requests cannot read the authenticated status data.

Earlier preparation failures and readiness-only observation timeouts remain
retained. They never reset the production job or count as passed transactions.
The first strict DDL comparison rejects the expected public-schema initialisation
boilerplate; the corrected independent review admits only that exact difference,
checks local account permissions, and changes no product data or guard. The first
portal check incorrectly expects an already paired replacement; the subsequent
check explicitly verifies the unchanged fresh-registration gate. No product guard
or onboarding requirement is relaxed for acceptance. The temporary container stop
controller later reaches its 90-second timeout and kills only its remaining init
and nspawn processes. PostgreSQL has already logged a clean shutdown. That failure
is retained before releasing only the owned transient unit metadata; no test
processes remain. This is not clean whole-OS shutdown/reboot acceptance.

## Recovery boundaries and operator files

This qualifies PBX database/private-data/media recovery on matching Debian, not a
new signed installer, bare-metal/OS reboot, physical phone, carrier/audio, video
camera or broker-cutover test. Restore onto the same release with matching
optional calling components; complete normal registration before customer use.
The separate central domain-registry database, website, mail hosting and private
developer/signing state are outside this PBX archive. Browser uploads accept
2 GiB; this larger archive uses the replacement CLI. Existing local copies remain
usable by the dashboard's checked and confirmed restore workflow.

The archive, reference dump, complete comparisons and failed evidence are private.
The operation pointer is `/var/lib/openwebpbx/active-backup126-path.txt`; its label
is not a product version. The operator password is kept root-only at
`/root/OPENWEBPBX-BACKUP-PASSWORD-2026-11-09.txt`. Keep a downloaded/off-server copy
and its password separately. An archive on this same data volume does not protect
against loss of that volume. Windows catch-up remains in the platform ledger;
public releases and broader feature-goal counts do not change.

## Switchtel diagnostics

The stored and loaded gateway use **sip.switchtel.co.za:5060 / UDP**, resolving
to **196.216.192.1**. Loaded Contact and advertised SIP/media addresses use
**139.84.227.194**. Local firewall rules permit SIP and return traffic; no rules
or provider credentials are changed. Switchtel states it has no IP blocks.

ICMP 30-hop/three-probe tracert-style output and independent UDP/TCP 25-hop traces
receive replies through hop 5, then none. One unauthenticated SIP OPTIONS receives
no UDP answer in 5 seconds. Missing replies do not establish a block or its
location/owner. Registration remains FAIL_WAIT. The password-free owner report is
`/root/SWITCHTEL-TRACERT-2026-11-09.txt`, ready to forward to Switchtel; no support
message is sent by this work.
