# Windows Server 1.0.22 qualification

Windows 1.0.22 is being qualified. The downloadable Windows release remains
[1.0.21](https://github.com/embire2/openwebpbx/releases/tag/v1.0.21).
Debian 1.0.22 and Android 1.0.19 retain their existing packages and feeds.

## Release action plan — 2 November 2026

Objective: publish Windows Server 1.0.22 with the registered setup wizard,
existing PBX services, stable phone QR setup, verified recovery and a working
signed updater. Additional feature development is deferred until this release
is published. The release target is Windows Server 2025 with Desktop Experience.

Current state: the native standard package from source `f2d755560` builds on
the supplied Windows Server 2025 machine. All 19,276 payload hashes and sizes
match the prospective manifest. This is a successful package build, not a
completed release qualification. Its private ZIP SHA256 is
`714486c49552c9fe2f7d629cc9008d5c6fe00e36e671b6ac3857b47f7bc61ae8`.
Full-suite [41462303601](https://github.com/embire2/openwebpbx/actions/runs/41462303601)
failed before packaging at a Python-version-sensitive AST test. Three attempts
to exchange the registration helpers on the test server encountered sharing
conflicts before writing anything. Registration recovery remains untested.

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

Execution has started with steps 1 and 2 in parallel. Automated qualification,
actual-server registration and recovery/publication preparation have separate
owners. No additional user decision is currently required.
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
| Windows registration data in backups | Corrected in `d0382f67a`; encrypted archive/PG restore, private-file ACL and real consumer-lock controls pass. The next package and native replacement flow remain unqualified |
| Genuine public 1.0.21 to actual candidate 1.0.22 | Still unqualified. The normal database baseline now follows rollback; a later run exposed the test observer writing two Python cache entries after its file baseline. Explicit bytecode suppression passes 14 differential controls; strict preservation checks remain unchanged |
| Original 1.0.21 signed updater | Compatibility correction committed as `31e93c155`; 262 local and 255 Windows adapter/file/security checks pass. Actual signed upgrade remains pending; a manual-helper test does not establish this path |
| Fresh Windows registration | Account email verified; actual installation, managed DNS, public HTTPS and calling checks remain pending |
| Reboot and final publication | Pending |

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
