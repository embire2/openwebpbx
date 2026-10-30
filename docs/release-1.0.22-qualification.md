# Debian 1.0.22 qualification

Published on **29 October 2026 at21:36 UTC** as
[Debian1.0.22](https://github.com/embire2/openwebpbx/releases/tag/v1.0.22).
Windows Server remains1.0.21 and Android remains1.0.19; their original packages
and compatibility feed bytes are preserved. Hosting-node qualification and the
ordinary customer-order result are recorded separately below, including their
retained failures and timing limits.

The complete Debian 13 amd64 package uses application source
`ec91a24fca9268be814f377f4564cbc384acf402`. Its 487,451,837-byte archive has SHA256
`f55bf2f4e63f45fe478027f44d328d3742814d93bb53cb8c86a73a136c00765d`.
The provider's 487,827,456-byte read-only media contains that same complete
installer; its SHA256 is
`b706a99dfc1fc95c7e4e03b9662fd570a7f353fd26588613c6a0a91fdfaa10e8`.

Real upgrade qualification exposed a scheduled-backup timer that could remain
elapsed after maintenance skipped its service. The final package adds a calendar
trigger and re-arms enabled managed timers after upgrade or restore. It preserves
disabled/custom choices, waits for maintenance to finish, and starts no backup
worker directly. Natural maintenance-skip, queued-backup completion and restored
server reboot/calling checks pass. The genuine original21 signed rollback and
normal upgrade now pass for this rebuilt archive, followed by natural backup,
actual OS reboot and original-credential calling. Earlier candidate results
remain historical.

## Release scope

Fresh self-installations obtain a managed server hostname, prove control of their
public address, and complete email verification, company details and tenant
registration through the setup wizard. A registered `*.openwebpbx.com` tenant
address and valid authorization are required before new calling work starts.
Existing installations retain their existing calling policy and credentials.

Webhotel adds the image to Create Instance, checks and reserves the chosen tenant
address before provisioning, and presents the initial PBX credentials permanently
to the authenticated owner or an explicitly permitted credential viewer. These
credentials are encrypted in provider storage and separated from provider root
and account credentials. Cancellation holds the allocated IP until owned-instance
shutdown and fresh central revocation/DNS-absence checks succeed.

The signed upgrade feed requires Debian 1.0.21 or newer. This release does not
qualify a direct upgrade from 1.0.16. The Windows21 and Android19 feed envelopes
must remain byte-identical in the new latest release.

## Acceptance gates

| Gate | Current evidence |
|---|---|
| Package and source provenance | Accepted: independent audits bind all12,193 payloads,6,708 packaged Git blobs,565 native files and36 native build inputs. The separate source archive passes7,645 exact Git blob/mode checks and contains no supplied live credential. |
| Central registration authority | Accepted: source and exact deployed native registry each pass326 controls; privileged PHP128 and dispatcher46 also pass. Existing customer projections and calling processes are preserved. |
| Backup safety and scheduled contention | Accepted components: nineteen real backup/restore controls,132 onboarding controls,21 domain controls,19 Phone Health controls, six native activation checks and eleven calendar/condition checks. Actual restored-server maintenance skip and natural queued backup completion pass without changing schedules or invoking workers manually. |
| Exact final-package clean installation | Accepted directly on two healthy nodes: exact ec91 archive, all12,243 installed files, pre-registration refusal with otherwise valid credentials, real owner registration/DNS/ACME/trusted GUI,24 initial/post-reboot UDP/TLS/alias calling cases, natural manual/scheduled encrypted backups and actual reboot. Two additional nodes completed within the pre-existing production command bound and pass separately declared same-install functional components; their earlier shorter QA observers remain failed. Earlier0aaa installations plus exact corrections remain explicitly separate. |
| Genuine original21 signed rollback and upgrade | Accepted: genuine original21 cold signed fault/automatic rollback in1,169.916 seconds and normal upgrade/finalization in1,342.509 seconds, both below their original1,800-second bounds. All176 original table sets, roles/cluster,321 private files,12,243 mapped targets and original metadata pass. Raw187 original relation owners/OIDs/ACLs remain exact with only eight source-defined new tables. Natural encrypted backup completes in36.558 seconds, with391 files/20 recordings verified; actual reboot, native22 signed Check and original440/660 two-way calling pass in separately declared components. Failed observers below remain failed. |
| Independent replacement restore | Accepted with an explicit mixed basis: a distinct clean0aaa factory installation restores the exact source database, local registration identity, voicemail and recordings while preserving target machine/database roles and identities. All changed ec91 payloads are then applied and all12,243 installed targets checked. Maintenance skip, the same queued encrypted backup completing naturally, actual reboot, original-credential UDP/TLS/alias two-way calls and the complete target-map recheck pass. Both temporary servers are stopped, centrally revoked and destroyed; original IP records are restored. |
| Webhotel checkout and credential access | Accepted components:103 onboarding,34 lifecycle,61 route,12 IP-owner,119 current session-recovery controls with the source-identical prior123 actual-session basis retained, and39 fresh live authenticated browser/API controls. Thirty-two production certificate-admission controls bind the final installer pin. All68 original catalogue rows are preserved. Current functional ordinary-order acceptance covers actual installation/registration, the permanent owner connection card, real PBX administrator login and paid cleanup. Its original 40-minute observation remains failed by5.323130 seconds; see the detailed result below. |
| Per-node image availability | Six locations complete their recorded checks. Six remain held: two for available memory, one for storage health, one without a customer-IP pool, one after installed-file comparisons time out, and one after installation/readiness fails. Six qualified locations are enabled on30 October after fresh media/capacity checks. The other six remain unavailable; staged media alone does not authorize sales. |

The accepted upgrade repeat declares an1,800-second observation bound before starting
either phase. It retains signature, resource-floor, idle-call, natural-updater,
raw database, schema, identity, role, file and late-fault witness checks. The
disposable fixture quiesces unrelated background writes for its strict snapshots;
its original timer choices must be restored and backups exercised afterwards.
Historical1,200-second results are not relabeled.

The first earlier-image audio attempt failed its coherence predicate; its historical
packet stream was not retained, so its cause is unknown. One complete independent
serial matrix passes the unchanged eight calling predicates with decoded ratios
of0.9998; its retained packet trace has no sequence errors. A reboot request lost
its guest-agent acknowledgment during shutdown, while the changed boot ID,
preserved identities, running services and post-reboot calls prove the actual
reboot. Neither original observation is rewritten as a successful command.

A later retained trace exposed a test receiver concatenating samples across RTP
timestamp gaps. Its replacement uses each packet's sampling clock, retains the
original energy/coherence/rate limits and adds bounded gap/coverage checks.
Twenty-seven observer controls, replay of four actual captured streams and new
complete serial call matrices pass. Product signaling, sender, credentials and
audio configuration are unchanged; earlier failed observations stay failed.

The first post-rollback receiver attempt failed on a retained160-sample RTP
clock gap; independent replay shows clock-aware coherence0.999833 versus
flattened0.668216. A new complete two-direction component uses the original
440/660 tones and accepted observer. The first reboot collector separately
failed its temporary-feed readiness check: cloud-init restored its original hosts
file and the check reached the public21 feed. All reboot/data comparisons had
passed; a guarded restoration of only the owned test line on the same boot,
followed by a new native-check/calling component, passes. Neither original failed
collector is relabeled.

Provider nodes that exceed the original installation observation or fail their
installer remain unavailable while their logs are checked. No failed timed
attempt is extended retrospectively. Two successful same-install components use
the unchanged first-boot source's pre-existing1,800-second command bound; they do
not relabel the earlier1,500-second observers. The node whose installed-file
comparisons repeatedly exceeded600 seconds remains unqualified and unavailable.
Its owned test VM, reservation and IP allocation are cleaned up; no partial file
count is treated as a passed comparison. The one new production-RAW installation
after an earlier external Debian package-fetch failure also misses its original
whole2,100-second readiness gate; cloud-final then exits1. Its exact inner error
is unretained. The recorded installation.json start belongs to preflight, so it
does not prove when the separate1,800-second installer-command limit began.
This location remains unavailable, with no further retry for this rollout.

Webhotel database readiness and a real ordinary customer-order journey remain
independent rollout gates. The ordinary browser test reached a valid reservation
and authoritative quote, then exposed a Back-navigation defect that discarded
the client-side setup ID. The minimal correction preserves the setup component
between steps without changing server authorization or billing checks. Its
TypeScript check,61 provider contracts, independent source review and staged
build pass. The frontend-only deployment preserves the running backend, its
bundles, existing catalogue and prices. The actual browser forward/Back check
passes, preserving its ready reservation and hiding the inactive step's controls.
The first funded normal browser order is accepted with HTTP202 on30 October,
then fails before its installer checkpoint: Webhotel sends contact_name in a
seven-field guest company contract. A narrow projection retains the full central
record while sending exactly the supported guest fields; TypeScript,63 provider
contracts and the actual rendered-input/frozen-validator test pass.

Normal destruction succeeds and the job refunds its charge once, but its late
failure handler retries completed cleanup and overwrites newer lifecycle state.
A second terminal cleanup refuses changed IP ownership; fresh readback shows
the address already free/unassigned, with the physical VM and DNS gone. The
deployed provider correction preserves current teardown intent and ownership;
its actual terminal cleanup and single refund pass. A second ordinary order
completes native installation and trusted tenant HTTPS, then fails a generic
hostname finalizer. Its automatic cleanup and single refund also pass. These
failures remain failed, with original records retained. The old housekeeping
job later pruned the two terminal service rows; the deployed narrow retention
correction preserves subsequent PBX terminal history.

## Ordinary customer path and hosting admission — 30 October

The third distinct paid order completes installation, native registration and
trusted tenant HTTPS. The service becomes running at 12:10:30.866 UTC against the
original deadline 12:10:33.936 UTC. Queue completion at 12:10:39.259130 UTC is
**5.323130 seconds late**, so the original 2,400-second whole-order observation
**fails**. It is never extended or relabeled. A separate current functional
component proves the owner's permanent connection card and actual tenant
administrator login with the credentials selected from that card. A failed
postpatch 180-second observer remains in the evidence chain; the later functional
result does not replace it. The real-running connection card required a
frontend-only active-or-running correction; the backend remained unchanged.

One ordinary owner destruction of the completed paid instance succeeds. Fresh
checks prove VM/config/image-volume/process absence, tenant/canonical DNS absence,
revoked setup and a free/unassigned IP. The completed queue, retained destroyed
service and 12 USD debit remain; there is no third refund, new credit or external
funding. Current functional receipt SHA256:
`68044050d084c1df18dddfb7de7aef4bc9ecb00dedc5fe25987a4dda17ff2038`.

At 13:47:40 UTC on 30 October, six qualified plans are enabled with fresh protected
template, full installer-media hash, available memory/storage, empty active-task
and paid-IP headroom checks. Exactly five false-to-true active flags and the
admission certificate change; every other raw field across 237 plans, including
prices/resources/scripts, is exact. Production order-readiness passes for all six;
six held plans stay inactive. The certificate explicitly retains the timed failure
and different node bases: two exact final-package fresh installations, two earlier
clean installations plus exact corrections, and two original installations with
separately accepted functional components whose shorter observers remain failed.
This is not six new whole fresh-install passes. Activation receipt SHA256:
`ec6e78324577f6e088e3c5b8c37918373321a236d66db0a77598442a11dacbb2`.

The main PBX's original customer projections across 18 tables are unchanged, with
exactly 12 known QA additions retained: eight disabled A/B rows and four unchanged
Guest22 rows. The original strict whole-table and eight-extra-row comparisons
remain failed; the separately declared exact12-row component passes. Main calling
services remain on 1.0.21 without restarts; all seven expected desk phones remain
registered. This rollout does not upgrade the public Windows/Android packages.

Actual software calls use SIP signaling and decoded two-way RTP. They do not
certify a new physical handset, carrier, Android device, Windows installation or
app-store submission. Existing published artifacts remain immutable.

See [installation](installing-1.0.22.md), [Webhotel onboarding](webhotel-onboarding.md)
and [updates](updates.md). Private raw evidence remains on the controlled
qualification hosts; it contains customer-shaped fixtures and access material and
is not part of the public release.
