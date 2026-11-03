# Windows Server 1.0.22 qualification

Windows 1.0.22 is being qualified. The downloadable Windows release remains
[1.0.21](https://github.com/embire2/openwebpbx/releases/tag/v1.0.21).
Debian 1.0.22 and Android 1.0.19 retain their existing packages and feeds.

## Latest qualification — 3 November 2026

The Windows candidate passes its full software qualification suite, clean native RestoreServer installation, original-backup import, restored Users/QR pages and eight original-credential calling cases over UDP and TLS. Independent inspection of all 16 audio streams, including call endings, finds no packet-clock errors. The matching source archive retains all tracked licences and notices.

The supplied server's first ten-minute readiness observation failed. Normal workers later made the tenant ready without a repair, and a separately declared current-state check passed; the earlier failure remains recorded. The restored final package now passes an actual reboot, all eight calling cases afterward, complete audio inspection and an encrypted backup containing all 22 recordings, registration state and the instance key, verified off-server.

A separate stock managed installation completes successfully on Windows Server 2025 in 12 minutes, generating a new installation identity and key. Ordinary owner-setup gating passes. The public wizard accepts its lookup, verified-account login and single tenant claim, then reaches Ready through normal background tasks. The fresh server passes eight software calling checks, all 16 audio streams and 34 stable-QR portal/enrollment/bootstrap checks. Its first natural scheduled encrypted backup verifies 471 files, all four fresh call recordings, registration state and the instance key; its off-server copy completes within 69 seconds. The complete wizard-to-backup flow takes 17 minutes 34 seconds, inside its original 40-minute limit.

The signed updater's native Scheduler/CDR checks and actual private-signature verification pass. [Run41676965068](https://github.com/embire2/openwebpbx/actions/runs/41676965068) now passes normal HTTPS download, unattended upgrade, automatic native restart, manager reopening, protected-data and empty-tenant content checks. Deliberate late-failure rollback and rollback manager reopening also pass. The whole run fails after 35 minutes 35 seconds when the administrator restores the sealed previous-version backup. That child exits with code 1, but its underlying error was not retained; the cause remains unknown. Cleanup fails separately. Error capture for the same installed restore command is being prepared without changing the product or treating either failure as passed.

Earlier [enabled41660031813](https://github.com/embire2/openwebpbx/actions/runs/41660031813) and [disabled41666346527](https://github.com/embire2/openwebpbx/actions/runs/41666346527) fail at old-worker baseline initialization. Their individual causes remain unknown; later cases pass those baseline checks without a runtime or wait-policy change. The intermediate [run41667221120](https://github.com/embire2/openwebpbx/actions/runs/41667221120) fails at a QA script-versus-action routing bug; its correction passes 202 focused controls and independent review before run41676965068.

[Disabled case41681939446](https://github.com/embire2/openwebpbx/actions/runs/41681939446) passes all nine normal/fault/restart/manager/protection gates. Its native previous-version restore returns and the original updater, manager, journal, task removal, policy and database checks pass. The whole case then fails because full file verification tries to hash the maintenance lock while it is in use (Windows sharing violation 32). The holder and duration are unknown. The correction waits only for that exact lock and sharing error, then retains the real hash, full inventory and equality checks. It passes 24 signed and 24 manual controls and independent review. [Corrected disabled case41692152736](https://github.com/embire2/openwebpbx/actions/runs/41692152736) is running; no worker is disabled or lock bypassed by the correction.

[Enabled case41687740984](https://github.com/embire2/openwebpbx/actions/runs/41687740984) fails before any upgrade or operator restore: the old tenant task reports idle/success, but all eight initialization paths remain absent at the original ten-minute limit. Its source can legitimately return success when maintenance causes it to defer, but the actual historical defer reason was not retained. The same initialization check is being moved before laboratory updater exposure and preflight, preserving every predicate and deadline. This ordering change does not establish the earlier cause. Complete operator file/task verification and public delivery remain required.

[Full run 41627350841](https://github.com/embire2/openwebpbx/actions/runs/41627350841) completed successfully in 78 minutes 35 seconds, using the unchanged authenticated release package. [Actual update-pair preparation 41638726340](https://github.com/embire2/openwebpbx/actions/runs/41638726340) also succeeds; this prepares unsigned test inputs and does not qualify a signed upgrade. Windows 1.0.22 is not published yet. Public Windows 1.0.21, Android 1.0.19 and Debian 1.0.22 remain available.

## Release action plan — 2 November 2026

Objective: publish Windows Server 1.0.22 with the registered setup wizard,
existing PBX services, stable phone QR setup, verified recovery and a working
signed updater. Additional feature development is deferred until this release
is published. The release target is Windows Server 2025 with Desktop Experience.

Original intermediate-installation evidence: registration reaches ready naturally, with managed DNS,
trusted HTTPS and preserved tenant authority. The supplied Windows Server
2025 machine passes eight software registration/calling cases before and
after an actual reboot. An encrypted backup has been verified, including
recordings, registration state and the instance key, with an off-server copy.
These actual-server checks use the earlier installation plus explicitly
reviewed fixes; they do not establish a fresh final-package installation.

The current candidate is `8f4256e4e`, including the Health correction and
automatic mobile-schema migration during restore. Full run41627350841 now
passes with the authenticated candidate and unchanged native/engine inputs.
Earlier run41535856855 failed; its result and the separate intermediate c5
run remain recorded without relabelling.

Earlier full runs remain failed. Diagnostics isolated a real Health defect:
it read advertised addresses rather than actual listeners. The correction
passes 133 focused checks on the Windows server and 176 portable runtime
controls, including the 133 focused cases. Ownership, firewall and existing
operation deadlines are preserved.

Clean recovery of the unchanged `dd073793f` code now passes: factory install
549 seconds, actual restore 465 seconds, exact tenant/extension model and all
14 recordings, source registration/private keys and the new target database
identity. The first verification failed with an unretained inner cause; a
diagnostic and one declared unchanged ordinary repeat passed. Original failed
results remain recorded. The original installation copies and encrypted
off-server backup remain intact. Secure phone preparation, ordinary activation, an actual reboot and
original-credential UDP/TLS calls before and after reboot pass. A broader
observer refused a normal task-state transition; the requested preservation
checks and full audio captures pass separately. Extension settings exposed
a missing QR-schema migration; that fix passes 14 PostgreSQL controls and
an isolated Windows migration test, but is not yet deployed here. This is a
recovery component, separate from the final corrected fresh managed setup.

Final managed setup, actual signed public21 update/recovery and public delivery
remain required. No public Windows 1.0.22 package has been promoted.

| Order | Action | Completion requirement |
|---|---|---|
| 1 — parallel with 2 | Correct the narrowly identified test portability problem. Run affected controls with the relevant Python versions before another full run. Bind one candidate and its native/engine inputs. | Portable control passes while preserving the exact subprocess arguments and deadlines; any runtime change creates a new candidate. |
| 2 — parallel with 1 | Resolve the test server's update-lock contention through a controlled maintenance window. Identify current owners, preserve data and original schedule choices, pause only owned conflicting work as needed, apply the reviewed registration correction and restore the original choices. | Exact new helpers, preserved data/security/identity and automatic worker recovery; ordinary tenant DNS, trusted HTTPS and registration reach ready. No manually fabricated ready state. |
| 3 | Run one complete CI suite and the actual Windows installation/setup checks in parallel once their prerequisites pass. Reuse already-qualified native and engine builds; authenticate the final package and source. | Genuine public21 upgrade/rollback plus the unchanged software suite pass. Actual final-package setup follows the public wizard, enforces registration and supports stable QR provisioning, software SIP calls with decoded two-way audio, voicemail, routing, media and Phone Health within their declared scope. |
| 4 | Complete recovery on the supplied Windows machine after functional acceptance: natural encrypted backup, protected off-server copy, actual reboot and clean replacement restore. Prepare the signed-update fixture independently while this runs. | Original extension credentials, tenant authority, configuration, voicemail and recordings survive; restored services and calls work. Restore qualification uses the final package. |
| 5 | Qualify the real installed public21 signed updater against the final candidate, including late failure/automatic rollback and normal completion. Check the installed22 operator path. | Five-minute checking, downloaded-and-verified package before shutdown, mandatory notice on Windows, red web banner, continued service while update is deferred, unattended install and automatic service restart. Failed install recovers the prior version/data. |
| 6 | Sign and publish after the required gates pass. Create windows-v1.0.22, add the byte-identical Windows ZIP mirror needed by the existing updater, publish the Windows feed and update the website, README and release documentation. | Unauthenticated public downloads match the signed metadata; the native updater accepts the actual public feed; download buttons and docs agree on the supported Windows release. Existing Debian/Android assets and feeds retain their separate versions. |

Execution rules for the quickest reliable release:

- Keep the two immediate blockers parallel, then run CI and actual-server
  qualification independently. Prepare publication text and recovery inputs
  while tests are running.
- Run focused checks before long suites. Repeat a passing gate only when the
  candidate, relevant environment or an unresolved failure warrants it.
- A test-only correction reuses valid runtime/build evidence. A runtime change
  requires the affected integration checks and a newly bound final package.
- Capture a specific failing boundary, fix it and rerun the affected work;
  avoid repeated blind lock attempts, package rebuilds or longer observation
  windows. Keep original failed attempts as failed.
- Give progress at blocker resolution, full-suite completion, recovery/update
  completion and publication. Establish a launch estimate after steps 1 and 2
  pass; the full CI job has a two-hour upper bound, not a promised release time.

Steps 1 and 2 have passed their focused controls and actual registration
recovery. Steps 3 and 4 are active in parallel; signed-update and publication
inputs are prepared. No additional user decision is currently required.
Publication closes only after the final required checks
and actual public delivery succeed. Physical-phone, carrier and camera tests
retain their explicit evidence limits.

The new Windows installer uses the same [public setup wizard](https://openwebpbx.com/wizard)
as Debian: connect an account, verify its email, choose the tenant address,
and let the server obtain its managed DNS, HTTPS certificates and installation
authorization. The PostgreSQL database remains on the Windows server.

The native manager opens the validated setup link after managed installation,
refreshes expired links and waits for a pending link without sending the user
to an unpublished server address. A Windows certificate check now distinguishes
the locally trusted temporary setup certificate from an issued certificate,
allowing automatic public certificate setup to proceed.

| Check | Current evidence |
|---|---|
| Native server, manager and updater build | [41075157082](https://github.com/embire2/openwebpbx/actions/runs/41075157082) passed; all three assemblies are 1.0.22 and the manager opens a responsive window |
| Native protocol checks | 41 installation-grant, 57 protocol, 82 updater and 20,050 STUN checks passed |
| Manager setup-link validation | 31 C# controls passed |
| Temporary-certificate correction | Six real loopback TLS checks and 132 isolated registration-worker controls passed; the actual Windows test server confirms that the correction rejects its locally trusted self-signed leaf |
| Tenant certificate expiry | Windows now emits whole-second UTC accepted by the unchanged registration gate; 26 actual Windows checks pass, including preservation of the certificate's expiry instant across three cultures |
| Public wizard | Windows wording is live; desktop/mobile layout, required links and browser console checks passed |
| Protection of the existing test server | Full encrypted 1.0.21 backup verified, including media, with a protected off-server copy; original backup settings restored |
| Windows registration data in backups | Current post-reboot encrypted backup verifies 482 files and all 14 recordings, both registration members and the instance key; encrypted off-server bytes match. The native OWNER_RIGHTS validator and backup-worker acquisition fixes pass focused Windows controls. Final-package replacement remains pending |
| Genuine public 1.0.21 to actual candidate 1.0.22 | The latest run passes its manual-helper upgrade, automatic rollback and original database/schema/customer preservation, then fails at Phone Health. This does not qualify the whole release or original signed updater |
| Original 1.0.21 signed updater | Compatibility correction committed as `31e93c155`; 262 local and 255 Windows adapter/file/security checks pass. Actual signed upgrade remains pending; a manual-helper test does not establish this path |
| Actual Windows registration and calls | Ready through normal workers; trusted canonical GUI and tenant API work. Two unchanged extension credentials pass four registrations and four decoded two-way calls over UDP/TLS before and after reboot. Basis: earlier installed package plus reviewed runtime fixes; final fresh package remains separate |
| Reboot and final publication | One actual reboot preserves tenant/database identities, private keys, registration and extension credentials; all four services start and eight software cases pass. An initial 300-second probe failed its API assertion and remains failed. Final replacement, signed update and publication are pending |

The upgrade fixture installs the immutable public 1.0.21 ZIP, then uses the
actual candidate 1.0.22 helper. It checks the original database, credentials,
media, Windows tasks and security, including removal of the new registration
task on rollback. A version-only canary does not qualify this transition.
Fresh registration is a separate requirement: an older fictional-host test
cannot satisfy the new installation authorization requirement.

The original 1.0.21 updater runs its installed helper even when downloading
1.0.22. Compatibility therefore stages the new registration helpers through
the existing tenant-domain installer, then creates the registration task only
after the upgrade commits. Existing disabled tasks remain disabled. Rollback
must remove only a task bound to that exact original backup. These source
changes still require the real signed-updater test.

The backup review found that Windows did not archive the private registration
session needed by a replacement. The correction includes the same two authority
files as Debian, preserves the replacement's local installation requirement,
and clears rebuildable registration caches with recovery snapshots. Tests cover
failed restore recovery and native Windows permissions/lock contention. This
does not establish a successful fresh native replacement installation.

The actual CEO account email verification is complete. Run
[41098161832](https://github.com/embire2/openwebpbx/actions/runs/41098161832)
predates the backup correction and is an intermediate component. The corrected
package must be rebuilt and qualified before publication.

Earlier runs remain failed: 41079281740 stopped at an outdated task-security
source contract; 41081098365 at a changed test phase anchor; and 41082501822 at
a backup-observer version pin. All stopped before server installation. Their
corrections retain the original protections. The next run,
[41083933798](https://github.com/embire2/openwebpbx/actions/runs/41083933798),
source `f4b8f7e996004dec2abd31b5aec5faa44d88bab7`, installed the genuine public
1.0.21 baseline but failed while preparing the upgrade checks, before the
version transition. Its nested diagnostic report was not retained by that
caller; the underlying cause remains unconfirmed. This is not an upgrade or
rollback pass. The subsequent certificate-expiry correction is committed as
`82fcdf57b` and requires a new package.

Run [41091274027](https://github.com/embire2/openwebpbx/actions/runs/41091274027)
uses source `4f67e60b3a9e7aacb8b49ab961b1f0d8a4af0bd0` and retains the nested
failure report. It fails during the ordinary candidate upgrade at the
combined original-security/customer-data comparison. Rollback recreates the
database schema, so the next test records its identifier-sensitive normal
baseline after rollback. The retained failure does not identify which
subcomparison differed; its cause is not relabelled as proven. This package
also predates the signed-updater compatibility correction and is not a
release candidate.

These checks do not establish physical-phone, carrier, camera or Store
approval coverage. Windows 10/11 server installation and cross-platform
instance-backup restoration remain unsupported; the Windows calling client
is a separate project. The broader [feature roadmap](../3CX.md) totals are
unchanged.
