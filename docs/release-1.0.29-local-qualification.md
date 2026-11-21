# Debian 1.0.29 qualification

**21 November 2026.** This record covers the full Debian 13 amd64 standalone
installer and isolated signed upgrade. [Release](https://github.com/embire2/openwebpbx/releases/tag/debian-v1.0.29) · [Standalone installation](installing-1.0.29.md)

## Complete installer

The original qualification used the full 1.0.29 archive. The publication
build uses the same executable and installer inputs with publication-ready
documentation. For the published download’s size and digest, use its
[release checksums](https://github.com/embire2/openwebpbx/releases/download/debian-v1.0.29/SHA256SUMS).
[Matching source](https://github.com/embire2/openwebpbx/tree/debian-v1.0.29).

The public rebuild matched all 12,151 runtime payload hashes from the
qualified archive, including the native binaries and voice files. The
comparison accounted for publication documentation edits and thirteen
non-executable permission differences in tar headers. Installation normalizes
those files or uses them as root-only helpers.

The published archive is **489,045,328 bytes**, SHA-256
`2593595a0077b19346eaebfe1a46189acbe8a308f7558298ff7d636e63aea3c2`. Both GitHub download locations matched. Verification also checked the
latest signed feeds and prior release history.

The original archive manifest and all 12,283 payload
hashes passed independent streaming verification. The standalone contract
sets `previous_installation_required` to false. The app, Core and updater
all identify as 1.0.29.

The exact package completed the normal installer on a dedicated Debian 13
test guest with no previous PBX files or database. This
isolated restore-server case used a local certificate and stopped at the
normal registration gate. All six services were active. Administrator
sign-in and Software Updates passed over trusted local HTTPS. Seventeen
selected installed file hashes, all 4,915 WAVs and the pack marker matched.
The running PHP-FPM configuration used the private mode-0700 upload
directory on disk-backed storage.

The first attempt stopped because the test guest's root directory was
mode 0700. Correcting the guest's mode to 0755 allowed PostgreSQL to start.
The successful test used the same package and a clean guest. On the slow
test disk, the fixture used session-only PostgreSQL startup acceleration
and scoped voice-file flush batching, then verified normal PostgreSQL
durability, ran a database checkpoint, synced the files and checked their
hashes. This establishes standalone functional startup. External enrollment
and power-loss durability have separate acceptance criteria. The guest
shut down cleanly.

## Hosted rollout

The application, Core and independent updater at `call.openweb.co.za`
reported 1.0.29 after a 24.590-second idle handover. The rollout verified
an encrypted 1.0.28 checkpoint and preserved all 17 protected configuration
tables and all eight registered phones. Six independent service generations,
including FreeSWITCH, stayed up. The private disk-backed PHP-FPM upload
directory was active. Trusted HTTPS checks passed for the sign-in, tenant
desktop, documentation and support report. The Core reported Running.

## Upgrade reliability

The new migration leaves verified matching voice files in place, records
transaction-owned staging paths in the recovery snapshot, and reports
progress under a bounded voice-worker deadline. Signed package, checkpoint,
idle-call and ownership checks still control admission. The previous
1.0.28 timeout and rollback keep their own evidence.

The 42 voice tests include an actual killed worker and recovery using the
existing helper. They check restored bytes and metadata, removal of the
owned partial stages, and retention of an unrelated temporary file. Seventeen
Debian upgrade and 15 support tests passed. [Previous timeout evidence](release-1.0.28-local-qualification.md#signed-update-and-recovery-on-the-dedicated-test-host)

The genuine 1.0.27 voice inventory matched all 4,915 WAVs and the pack marker.
The candidate's activation comparison wrote zero files and preserved all
existing inodes and modification times.

### Signed upgrade on the test host

The public signed offer requires installed Debian 1.0.27 or newer.
A separate Debian 13 guest ran the stock 1.0.27 updater against a privately
signed 1.0.29 offer. The guest reached the offer over its loopback-only TLS
fixture. The administrator used **Update Now** from the normal HTTPS page.
The first request verified the archive and passed helper preflight. The
worker then reported a generic error before it started the apply helper or
created a 1.0.29 install journal. The guest was still on 1.0.27. The failure
record does not identify the exact cause. Authenticated call-engine probes
then confirmed zero calls and channels before an ordinary manual retry.

On that retry the voice worker completed on the slow disk beyond the
previous ten-minute limit. It verified 4,916 matching entries, comprising
4,915 WAVs and the pack marker, and wrote zero voice files.

The signed upgrade finished on 1.0.29. The recovery journal and its startup
finalization completed, the new updater slot became active, and the signed-in
Updates page reported **Up to date**. All six services ran, and the digests
of ten protected PostgreSQL tables, two private configuration files and
the update policy matched their original values. The upgraded installation
used the private PHP-FPM upload directory. The guest recorded the first
request as failed and the retry as completed. The temporary update transport
and its trust root were removed after verification.

The fixture batches selected bulk snapshot and updater-slot flushes on the
slow disk. The real signature, recovery journal and database durability
settings remain in use. Power-loss behavior is outside this test scope.

## Large 3CX restore uploads

Managed Debian installations set a private disk-backed PHP upload directory.
Existing operator choices retain precedence. The temporary archive is
validated before a restore draft is created. Upload failures report the
cause and permit retry. The existing updater's recovery inventory covers the
managed configuration fragment.

Eleven isolated checks used real PHP-FPM multipart requests. A synthetic
Update 10 ZIP of 230,687,344 bytes hit ENOSPC on a constrained private mount
and subsequently passed analysis on disk. An interrupted body, a dropped
socket, an invalid ZIP and an oversized request also passed their refusal
and retry checks. The tests verified mode 0600 on staged archives, no
partial files after failure, the private directory's 0700 permissions, and
operator override and recovery behavior. The 66 backup parser checks passed.
In separate tests, the real cleanup job retained locked or unrelated files
and removed expired temporary archives. A disk-full voicemail copy rolled
back its partial output and preserved an existing recording. Retrying then
saved the correct recording.
[V20 restore guide](v20-restore.md)

## Native calling qualification

The installed 1.0.29 calling policy, trunk options and ordinary Lua
configuration were verified in an isolated FreeSWITCH test. A synthetic
primary provider returned SIP 503. The engine sent exactly one INVITE to
the backup, connected the call and passed bidirectional PCMA RTP. The test
released the temporary calls and call-capacity records. It stayed behind
the managed-registration gate and used no customer, carrier or handset traffic.

## First Calls

An administrator can record a blocker even when a call never connects,
find the next unfinished test and see whether a backup provider is configured.
Positive confirmation still requires evidence from the returned call.
Failover confirmation requires a primary failure and exactly one connected
backup within the same call. The 79 isolated PostgreSQL checks covered
result persistence, tenant boundaries, valid recovery and invalidation
after routing changes.

The owner confirmed calling on the live test PBX. This closes the hosted
pilot substep. Broad carrier failover, a new administrator's independent
setup and the physical-device matrix retain separate acceptance criteria.
[Calling guide](core-calling.md) · [Roadmap](../3CX.md)
