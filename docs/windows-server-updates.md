# Windows Server updates

The next Windows Server build checks its signed Windows release feed every **five minutes**. It downloads a newer compatible release automatically, verifies its signature, complete archive and installation requirements, and leaves the PBX running until an administrator requests installation. These changes are under native qualification; the published 1.0.20 package is unchanged.

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

## Validation

82 portable updater checks and 85 isolated PostgreSQL authorization/notice checks pass. [Native Windows run 40198754623](https://github.com/embire2/openwebpbx/actions/runs/40198754623) passes 13 actual worker controls with an isolated PostgreSQL database and PowerShell helper: the five-minute boundary, cached-download reuse, postponement under old automatic policies, single queued installation, active-call deferral and failed-feed retry. Its helper fixture does not claim a complete real-server upgrade. Ten UI Automation controls open the actual WinUI manager and test its modal, download readiness, Later, persistent banner and completed-notice removal. All 76 recorded native source inputs and the complete original artifact hash were independently checked against the dispatched commit. Ten Chromium checks exercise the real notice CSS/JavaScript at desktop and mobile sizes, including declined installation, offline retention, ordinary-user restrictions and the installation POST.

The existing complete signed upgrade, rollback and manager-reopening results belong to published 1.0.20. A new complete release must qualify its changed runtime bytes before publication.
