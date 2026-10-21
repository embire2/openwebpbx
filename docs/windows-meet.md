# Windows meeting transport

Windows Server 2025 uses IIS for the public HTTPS connection and the PBX's
existing private meeting profile for SIP over WebSocket. The exact
`/meet-sip/` route connects to `https://openweb-meet.internal:7444/`, which
resolves only to loopback. It accepts HTTPS WebSocket GET upgrades without
query parameters. Existing meeting admission and SIP authentication still
apply; installing the proxy does not admit guests or create meetings.

`Install-Meet.ps1` installs the Windows WebSocket feature, Microsoft URL Rewrite
2.1 and ARR 3.0. Downloads have fixed SHA-256 values and must also pass Windows'
Microsoft signature validation. The helper checks the existing private/public
certificate pair locally before registering only its public leaf in Windows
trust. It explicitly sets ARR's `SecureConnectionIgnoreFlags` to zero, because
ARR's default can ignore a backend certificate name mismatch. The backend's
private key stays in the engine's protected configuration.

Conflicting hosts entries, unowned meeting certificates, duplicate meeting
rules, existing certificate exceptions and affected foreign reverse-proxy
rules stop installation for administrator review. Other hosts-file bytes,
site handlers, rewrite rules and proxy attributes are retained. The helper
recycles only the owned PBX application pool while maintenance is held.

The target-only ownership ledger is
`C:\ProgramData\OpenWebPBX\meet-proxy.json`. It is not portable backup data.
Installer failure keeps a private recovery snapshot. The updater also seals
the original private certificate, ledger, helper state and scoped machine
settings in its recovery inventory. Recovery removes only the exact introduced
hosts line, public trust leaf, IIS prerequisites and feature, restoring prior
proxy and certificate-policy values. Conflicting changes require administrator
recovery instead of overwriting another configuration.

After an encrypted restore replaces the private certificate pair, the closed
restore transaction calls the installed helper with
`-RebindRestoredTransport -MaintenanceLockHeld`. This mode requires the private
restore journal, all calling/job/update holds, stopped PBX services/site and
the parent's retained exclusive maintenance lock. It refreshes the target's
owned public leaf without copying another server's hosts, IIS state or ledger.

`tests/windows_meet_proxy.ps1 -Installed` checks an actual Windows-trusted
backend TLS connection, a rejected wrong hostname and an IIS WSS upgrade with
the SIP subprotocol. These checks are separate from decoded browser audio and
video and do not establish carrier or physical-camera acceptance.

References: [Microsoft ARR downloads](https://www.iis.net/downloads/microsoft/application-request-routing),
[Microsoft URL Rewrite downloads](https://www.iis.net/downloads/microsoft/url-rewrite),
[ARR certificate-validation flags](https://learn.microsoft.com/en-us/iis/extensions/configuring-application-request-routing-arr/arr-support-added-for-winhttpoptionsecurityflags).
