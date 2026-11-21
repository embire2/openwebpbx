# OpenWeb PBX working guide

Updated **21 November 2026**. Start with this guide, then read the part of the [roadmap](3CX.md) that covers your task. The roadmap is the active list of delivered workflows, next work and open acceptance criteria. [Feature coverage](docs/feature-coverage.md) and the release records provide deeper evidence.

## Debian 1.0.29 qualification

The **Debian 1.0.29** release is a complete standalone installer. The source adds unchanged-voice detection and recoverable temporary files, private disk-backed large restore uploads, and saved **First Calls** blockers with a next step. Use an isolated host for destructive qualification and retain hosted evidence separately. [Installation guide](docs/installing-1.0.29.md)

- Use customer backup archives only for authorized inspection and isolated restore qualification. Keep unknown builds gated, imported trunks disabled and unsupported source objects visible in Restore Report. Compare credentials and media privately.
- The Debian page uses the existing independent signed updater, opt-in policy and daily UTC window. **Update Now** submits a manual request that waits for idle calls. Windows import qualification and explicit automatic-install consent are tracked for the next Windows pass. Existing Windows policy needs to preserve manual approval until an administrator gives fresh consent. [Windows catch-up](docs/debian-windows-sync.md)
- The Debian 1.0.29 release has exact package verification, a clean install and a separate signed upgrade. See the original evidence for each older package and hosted rollout. [1.0.29 qualification](docs/release-1.0.29-local-qualification.md) · [1.0.28 qualification](docs/release-1.0.28-local-qualification.md)
- The exact 1.0.29 installer passed an isolated clean Debian 13 installation with a newly created PostgreSQL database, six running services, administrator sign-in over local HTTPS and all 4,915 system WAVs verified. The guest used the normal registration gate with a local certificate. External activation remains a separate check. [Clean installation evidence](docs/release-1.0.29-local-qualification.md#complete-installer)
- A separate guest completed the signed 1.0.27 to 1.0.29 upgrade using **Update Now** after a first request failed before applying changes. The retry preserved ten protected database tables and the update policy, started all six services, and verified 4,915 voice files and their pack marker with zero rewrites. The test used scoped bulk filesystem flush batching. [Signed upgrade evidence](docs/release-1.0.29-local-qualification.md#signed-upgrade-on-the-test-host)
- The owner confirmed calling works on the live test PBX on 21 November. Record that pilot substep independently from carrier failover, an independently guided signup and the physical-device matrix. Use the existing caller and tenant boundaries when recording first-call results. [Roadmap](3CX.md)
- The goal is functional 3CX-level workflows in an independent OpenWeb implementation. Proprietary 3CX clients and hosted services require OpenWeb equivalents. Keep each platform's delivered status separate from the broader parity goal.

## Live systems and public releases

| Component | Current state | Reference |
| --- | --- | --- |
| Hosted PBX at `call.openweb.co.za` | Application, native Core and updater **1.0.29**. | [Hosted rollout](docs/release-1.0.29-local-qualification.md#hosted-rollout), [tenant administration API](docs/tenant-admin-api.md) |
| Debian PBX server | Public **1.0.29**, Debian 13 amd64, complete standalone installer. The signed existing-data offer starts at Debian 1.0.27. | [Install](docs/installing-1.0.29.md), [qualification](docs/release-1.0.29-local-qualification.md) |
| Windows PBX server | Public **1.0.27**, Windows Server 2025 x64 with Desktop Experience, complete standalone installer. Actual installed 1.0.23 → 1.0.27 signed upgrade qualified. | [Install](docs/installing-windows-1.0.27.md), [qualification](docs/release-windows-1.0.27-qualification.md) |
| Android Free Phone | Public **1.0.19** APK. Google Play publication is pending. | [Android setup](docs/android.md), [tenant addresses](docs/android-tenant-addresses-1.0.18.md) |
| Windows Free Phone | In development on its own branch. Separate from the working Windows server manager. | [Client plan](docs/windows-client-plan.md) |

The prior Windows 1.0.23 ordered-updater repair remains available as an additive historical asset. Each complete installer includes its own database setup, engine, application, workers and updater. Fresh installation needs no earlier PBX. Upgrades against existing data have a separately tested signed path. [Independent platform releases](docs/independent-platform-releases.md), [Windows ordered-updater repair](docs/windows-upgrade-path-repair.md).

## Production and customer data

- Before deployment, check the supported target, mount layout and free capacity for extraction, verified backups and retained rollback copies. Keep persistent state on its provisioned data volume and account for guest and host storage separately.
- Keep retired recovery systems powered off. When restoring, use a separate target and protect the live database, persistent state, certificate renewal and DNS automation.
- Keep customer calling running. Inspect state without writes where possible. Use a naturally idle window for authorized changes affecting calling. Do not close ports. SSH remains key-only. SIP Fail2Ban jails stay disabled. SSH bans affect TCP 22 and web bans affect TCP 80/443 only. Never remove a ban, relax a security baseline or rotate credentials just to make a check pass.
- Preserve extensions, distinct authentication IDs, exact password bytes, reusable QR identities, call routes, allowances, media and custom recordings. A QR can be retrieved repeatedly through its authorized workflow. Reset it only when specifically requested. Preserve live role, tenant, PBX, department and ownership boundaries. Never initialize an empty workspace or widen a key to hide a target-selection error.
- Use root-private operation directories for archives, credentials, configuration beforeimages, browser logs and diagnostic receipts. Never commit secrets, `.env`, private keys, QR payloads, private provisioning URLs, raw logs/browser data or customer backups. Keep customer archives out of Git and public test runners. Send external messages only with explicit authorization.

## Testing, migration and releases

1. **Identify the target and its role.** A hosted fix, source branch, development package, exact installer qualification and public signed release are separate outcomes. Check the currently running version and the private operation pointer when relevant. Avoid modifying unrelated production services, other tenants, provider accounts or foreign VM resources.
2. **Work on isolated systems for destructive or intrusive cases.** Never restore an archive onto the live hosted PBX for testing. Preserve exact installation state before authorized change, then compare credentials, QR, authorized scopes, recordings, routes and service generations afterward. Use normal product UI and worker paths for acceptance. Never enable imported trunks or start a carrier cutover just to test a parser.
   Run the Debian 13 qualification guest on the dedicated test host with protected storage, scoped services and isolated networking. Keep a privately signed test offer and its trust sequence in a separate disposable upgrade guest. Preserve the host OS and keep access credentials outside Git.
3. **Specify what the evidence shows.** A registered phone is not proof of ringing or two-way audio. Software calls are not physical-device, carrier or camera qualification. Package verification is not Store acceptance or 3CX parity. Keep failed runs and recovered attempts distinct. Record exact release, platform, source and supported starting state. Reuse earlier tests only for explicitly unchanged components, with a reason.
4. **Keep public release history intact.** Preserve existing tags, assets, checksums, signed feeds and ordered upgrade history. Publish each platform separately when authorized and qualified, while retaining the other platforms' exact feed assets. The existing `v1.0.27` tag remains Debian's source tag. Its Windows files were added under distinct names. Track Debian-to-Windows changes in the [catch-up ledger](docs/debian-windows-sync.md).
5. **Keep guidance honest and useful.** Update affected roadmap IDs, release notes and operator guides when evidence changes. Preserve the existing 133 goals and **21 accepted / 72 partial / 40 planned** baseline until a relevant acceptance criterion is met. Add substeps under stable IDs for newly discovered work. Keep failures and sensitive evidence outside public summaries.

## Recent evidence worth carrying forward

### Hosted Debian 1.0.29, deployed 21 November

- The idle handover verified an encrypted pre-update checkpoint, preserved all 17 checked configuration tables and retained all eight registrations. The live web application, Core and updater report 1.0.29. [Hosted rollout](docs/release-1.0.29-local-qualification.md#hosted-rollout)

### Hosted Debian 1.0.28, deployed 20 November

- The frozen local package supplies eight changed web files, VERSION, Core and the updater. The verified encrypted pre-update checkpoint captured the 1.0.26 database and 331 private files, excluding media. The deployment used an idle window, completed in 11.603 seconds and retained the previous runtime and web files for recovery.
- All 14 protected configuration tables matched exactly. All eight registrations survived and FreeSWITCH, nginx, PHP-FPM, PostgreSQL, SSH and Fail2Ban retained their process generations. Trusted HTTPS and API authentication checks passed. [Hosted update](docs/release-1.0.28-local-qualification.md#hosted-deployment)
- The owner-designated test host completed an exact functional fresh install in an isolated Debian 13 guest, with normal local HTTPS administration, six running services and verified hashes for all 4,915 voices. A second guest proved the real automatic signed rollback from the controlled validation failure. Its manual retry exposed the fixed 600-second voice migration limit on slow storage and rolled back with its original services, slot and ten protected tables verified. Keep that result distinct from the hosted update and fresh install. [Test scope and release blocker](docs/release-1.0.28-local-qualification.md#signed-update-and-recovery-on-the-dedicated-test-host)

### Windows 1.0.27, published 19 November

- `windows-v1.0.27` identifies source `ccccfe56ed7012455e1cf00395407389a7226daf`. The complete ZIP is **643,869,682 bytes**, SHA-256 `fd02d054ae21b06ca6be7945e515513d02f1c4989851b83e395e53a8103a88fb`. A real elevated RDP installation on clean Windows Server 2025 finished in **1,577.259 seconds**, with no older PBX or separate repair. Managed registration and default-trusted HTTPS, manager UI, admin/personal API, STUN, UDP capacity and TLS two-way software audio passed.
- Tenant and full encrypted backup, verification and restore passed. Preserve the initial tenant backup busy refusal separately from its successful normal retry. Full restore revokes API keys and clears phone readiness. Use the [documented phone certificate verification](docs/installing-windows-1.0.27.md) after full restore. The original QR payloads were returned unchanged after this step. A normal reboot after full recovery proved four auto-start services and working calls, API and QR again.
- An existing 1.0.23 test machine passed a real signed upgrade through the native manager in RDP. Keep the accepted migration, earlier separately recovered failure and reused automatic rollback evidence distinct. Both test machines observed the public signed feed.
- All twelve anonymous downloads verified. The website, README and release catalogue were updated. The [qualification](docs/release-windows-1.0.27-qualification.md) contains the exact source and test scope.

### Debian 1.0.27, published 17 November

- `debian-v1.0.27` and canonical `v1.0.27` identify source `72bb5406af4c057acb5ee4eddfd9d861d20d345f`. The complete installer is **488,884,221 bytes**, SHA-256 `fa771a66999ec2811212ed452588025c5cbe78b0502b8afd7794588c0e236198`. Clean Debian 13 install, owner/DNS/TLS, admin and personal API, software SIP/RTP, boot recovery behavior and a genuine signed 1.0.26 → 1.0.27 upgrade were qualified within the [release scope](docs/release-1.0.27-qualification.md).
- Distinguish actual last-hop tests from reused historical update and rollback evidence. This release used disposable test guests.

### Hosted work and outstanding operations

- The hosted `/api/v2` and `/api-docs` have scoped instance, tenant and personal/department workflows. The later hosted **Full tenant administration** preset operates on the selected tenant's current and future CloudPBXs, using nine existing scopes. Keep that later overlay separate from frozen Windows 1.0.27. An otherwise valid key can target an unconfigured workspace. Use the configured PBX and respect the descriptive `pbx_not_configured` response instead of widening permission. [Hosted tenant API](docs/tenant-admin-api.md).
- Switchtel2 uses the verified registrar, but observed production REGISTER attempts receive no reply. An independent Windows probe received SIP `401` from both provider addresses. The evidence does not establish the cause of the production path failure. Keep [the permanent report](https://call.openweb.co.za/reportswitchtel) and its nginx include. No external provider message has been sent in this task.
- The scoped Fanvil V62W migration preserved the phone's restored identity and credentials and demonstrated remote registration after reprovisioning. Factory-reset zero-touch discovery and real handset audio remain separate. Keep its private provisioning route and storage private. [Handset migration](docs/desk-phone-handover.md).
- The hosted full-media recovery was proved on a separate Debian system, with encrypted media and database comparison. Hosted backups use the configured nightly schedule and local retention. Remote storage and further disaster recovery qualification remain open. Never restore Main during verification. [Full-media recovery](docs/backup-recovery-2026-11-09.md).

## Reference and history

- [Roadmap and next pass](3CX.md), [carrier cutover](docs/carrier-cutover.md), [3CX V20 restore](docs/v20-restore.md), [update operation](docs/updates.md).
- [Previous working guide, frozen before this rewrite](https://github.com/embire2/openwebpbx/blob/da38c916eb4bb3cfebf9fd7c060f71c8e94a2c02/AGENTS.md). Earlier exact records also remain in [the Windows qualification archive](docs/history/agents-before-windows127-final9-direct-2026-11-19.md) and [the November 12 archive](docs/history/agents-before-access-repair-2026-11-12.md). Read history only when relevant. Dated pending statements do not supersede newer qualified results.
