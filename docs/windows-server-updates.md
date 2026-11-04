# Windows Server updates

<!-- WINDOWS22-CURRENT-STATUS-BEGIN -->
## Latest Windows 1.0.22

Windows Server 1.0.22 is frozen at product source
`8f4256e4e3cbce092791eea60d1c053e10810bb6` for **Windows Server 2025 x64
with Desktop Experience**. Its qualified signed-update minimum is **installed
Windows 1.0.21**. The full software suite, actual older-backup restore/reboot,
and distinct managed fresh setup with QR and natural scheduled backup pass.

Signed cases [41752080297](https://github.com/embire2/openwebpbx/actions/runs/41752080297) (original worker enabled) and [41722715796](https://github.com/embire2/openwebpbx/actions/runs/41722715796) (original worker disabled) pass. Published **2026-11-04T01:59:14Z**; public assets/canonical mirror, retained feed bytes and the ordinary installed public-feed Check verify.
Debian 1.0.22 and Android 1.0.19 retain their own artifacts and feeds.

[Windows qualification and limits](release-windows-1.0.22-qualification.md) ·
[Independent Linux/Windows/Android releases](independent-platform-releases.md).
<!-- WINDOWS22-CURRENT-STATUS-END -->

The Windows updater checks its signed Windows feed every **five minutes**, verifies the complete newer compatible download and leaves the PBX running until an administrator requests installation. The qualified Windows 1.0.22 route requires installed **1.0.21 or newer**; signed/publication acceptance is recorded above. See the [Windows qualification record](release-windows-1.0.22-qualification.md) for current scope.

When an update is available, the Windows manager displays:

> Your Windows Server PBX system has a new update {newupdateversion} - you must update in order to continue using the service.

The same message appears in a bright red banner with white text at the top of the web console. **Later** dismisses the Windows modal; the banner remains. Calls, registrations, administration and other services continue. There is no forced sign-out, service expiry or shutdown for postponing. Previously saved automatic-install policies also wait for an explicit installation request on Windows.

## Install from either interface

- **Web console:** sign in as an instance administrator and choose **Update now** in the banner. Confirm installation. The request uses the existing protected update queue and form token. Other users can see the requirement but cannot update the shared server.
- **Windows desktop or RDP:** choose **Update now** in the native manager. Windows asks for administrator permission if required; the updater then runs unattended. The desktop never accepts a download URL, installer path or credentials from the public status file.

Both actions wait for a complete verified download and active calls to finish. The updater saves a private recovery backup, stops the old services, installs the new version without installer questions, checks its health and starts the phone system again. It also reopens the Windows manager in its registered interactive session. An installation failure uses the existing recovery journal and previous-version rollback; a failed recovery still requires administrator attention.

## Desktop notifications

The installer registers an unelevated monitor for Windows sign-in, including RDP. It opens the native manager once for each newly detected version in that session. The manager also starts the monitor for its current session. If nobody is signed in, the update downloads in the background and the prompt appears after the next sign-in. A Windows service cannot display an interactive modal in its own service session.

Closing or postponing the prompt never requests installation. Update errors keep an already verified requirement visible and retry the feed after five minutes. Invalid signatures, unsupported versions, expired metadata or unverified downloads do not become installation inputs. A restored server's existing maintenance holds still take precedence.

The check interval and download requirement apply to the Windows server. Debian's policy options and Android/Windows phone update settings remain separate.

## Earlier signed-update validation — original scope retained

The earlier1.0.21 normal40435466441 passes all17 essential gates. Its matching signed-newer result is **[run40501021425](https://github.com/embire2/openwebpbx/actions/runs/40501021425) passed all9 signed-upgrade gates and117 original Scheduler/file-sharing controls at QA source `8834f96bfc576dbcb5c864e718ac9bb31024dab2`; canonical cleanup and exact-owned temporary-secret removal passed**. The component and1.0.20 records below retain their original scope; [1.0.21 qualification](release-1.0.21-qualification.md) records that earlier release.

82 portable updater checks and 85 isolated PostgreSQL authorization/notice checks pass. [Native Windows run 40198754623](https://github.com/embire2/openwebpbx/actions/runs/40198754623) passes 13 actual worker controls with an isolated PostgreSQL database and PowerShell helper: the five-minute boundary, cached-download reuse, postponement under old automatic policies, single queued installation, active-call deferral and failed-feed retry. Its helper fixture does not claim a complete real-server upgrade. Ten UI Automation controls open the actual WinUI manager and test its modal, download readiness, Later, persistent banner and completed-notice removal. All 76 recorded native source inputs and the complete original artifact hash were independently checked against the dispatched commit. Ten Chromium checks exercise the real notice CSS/JavaScript at desktop and mobile sizes, including declined installation, offline retention, ordinary-user restrictions and the installation POST.

The existing complete signed upgrade, rollback and manager-reopening results belong to published 1.0.20. A new complete release must qualify its changed runtime bytes before publication.

The combined [Windows run 40200892861](https://github.com/embire2/openwebpbx/actions/runs/40200892861) also passes: the actual sign-in monitor opens the manager and modal (11 controls), the Windows updater worker passes its 13 controls, and the new Greetings worker passes 39 PostgreSQL/controlled-HTTP controls on Windows. The complete original artifact hash and all 77 recorded native inputs match the dispatched source and current native tree. This remains a component build/test, rather than a newly published full server installer.
