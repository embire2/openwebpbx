# Debian 1.0.22 qualification

Status: candidate qualification in progress on 29 October 2026. The public server
release remains 1.0.21; this document does not announce a published installer.
Windows Server remains 1.0.21 and Android remains 1.0.19.

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
server reboot/calling checks pass; the genuine original21 signed repeat is still
required for this rebuilt archive. Earlier candidate results remain historical.

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
| Exact final-package clean installation | New ec91 full installations remain in progress. Earlier0aaa full installations on two healthy nodes are retained separately; their exact six-runtime-file correction is checked against all12,243 installed targets and exercised again. They are not relabeled as fresh installations of the rebuilt archive. |
| Genuine original21 signed rollback and upgrade | The ec91 cold-download fault/automatic rollback and normal-upgrade repeat is running under prospectively declared1,800-second bounds. Prior0aaa strict rollback passes in1,092.269 seconds; its separate source-defined normal-file comparison passes, but actual post-upgrade backup testing exposed the timer defect corrected above. Neither earlier result qualifies the rebuilt archive. |
| Independent replacement restore | Accepted with an explicit mixed basis: a distinct clean0aaa factory installation restores the exact source database, local registration identity, voicemail and recordings while preserving target machine/database roles and identities. All changed ec91 payloads are then applied and all12,243 installed targets checked. Maintenance skip, the same queued encrypted backup completing naturally, actual reboot, original-credential UDP/TLS/alias two-way calls and the complete target-map recheck pass. Both temporary servers are stopped, centrally revoked and destroyed; original IP records are restored. |
| Webhotel checkout and credential access | Accepted:103 onboarding,34 lifecycle,61 route,12 IP-owner,123 session-recovery and39 live authenticated browser/API controls. All68 existing catalogue entries are preserved; temporary UI fixtures are removed. |
| Per-node image availability | Staging and full node certification are separate. Nodes with storage errors, insufficient resources or no customer-IP pool remain unavailable. |

The final upgrade repeat declares an1,800-second observation bound before starting
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

Actual software calls use SIP signaling and decoded two-way RTP. They do not
certify a new physical handset, carrier, Android device, Windows installation or
app-store submission. Existing published artifacts remain immutable.

See [installation](installing-1.0.22.md), [Webhotel onboarding](webhotel-onboarding.md)
and [updates](updates.md). Private raw evidence remains on the controlled
qualification hosts; it contains customer-shaped fixtures and access material and
is not part of the public release.
