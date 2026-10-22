# Phone Health & Recovery

**Status — 22 October 2026:** live on hosted Debian through a focused patch. Native Windows Server components are implemented and have separate native checks; the latest complete Windows package failed its newly required event-to-firewall worker gate. Repairs and an unchanged-package diagnostic replay are in progress. The public full Debian server remains 1.0.16, the focused downloadable administration update remains 1.0.19, Android remains 1.0.18 and the public Windows archive remains 1.0.7. These additions are not a new complete downloadable release. See the [current roadmap](../3CX.md) and [server qualification record](release-1.0.20-qualification.md).

Phone Health & Recovery brings phone connections, provider problems and verified office security blocks together so an administrator can understand an outage and choose a safe next step. It addresses a common failure: a phone first tries the wrong sign-in details or address, its office is blocked, and the corrected settings cannot reach the PBX.

Sign in as the **PBX owner** and open **Admin → Phone Health**. The standalone page is `/app/pbx_phone_health/`. The hosted Debian activation keeps the existing full-core 1.0.16/admin 1.0.19 installation and does not change the Android app or its minimum version. These additions are not in the previously sealed Debian 1.0.20 archive; that archive's recorded qualification remains separate. A full release containing this feature needs a rebuilt Debian package and new fresh installation, upgrade, recovery and restore checks. The older candidate must not be used to upgrade the hosted instance: it would replace these new feature files.

The page refreshes every **15 seconds** while open; the background monitor checks every **30 seconds**. Critical incident banners persist until the underlying condition is resolved. These intervals are checks, so they do not promise instantaneous delivery or physical handset availability.

The page includes **Needs attention**, **Office security blocks**, **Recent recovery requests**, searchable **Phones**, **Phone providers** and **Administrator alerts**. The main Admin page also displays a persistent banner when a critical phone or provider issue needs attention.

## Read the evidence

| Result | What it establishes | What to do next |
|---|---|---|
| Phone online | The PBX currently has a valid connection for that phone or app. | Make an answered call to check ringing and sound. |
| Phone offline | No current connection was found. | Check the phone's power, internet, SIP server/proxy and restored sign-in details. |
| Verified office block | A current PBX security block matches a previously verified phone source. | Correct the phone settings, review the affected office, then request controlled recovery. |
| Provider needs attention | A saved setting or observed provider connection has a problem. | Read the reported result, check the provider account and follow the first-call checks. |
| Status unavailable or out of date | Fresh evidence could not be obtained. | Check the reporting service and refresh; an unavailable check does not establish that a phone is offline. |

A phone's **Online/Offline** connection is separate from its **Call Status**. A registered phone may be idle, busy or set to a forwarding status. Successful registration does not prove that a cordless handset was assigned to its account, that it rings, or that audio crosses a customer's firewall.

An intentionally disabled provider is different from an enabled provider that has failed. A provider that authenticates by IP can also have a different expected connection state from one that signs in. Recovery must not enable, reconnect or rewrite a provider just to make a status indicator green.

Verified office history starts when the monitor is installed. It records authenticated desk-phone contacts and uses observations from the last **30 days** as office proof; it does not import old private investigation logs or guess an office address from a failed sign-in. A desk phone that has been observed recently produces an offline incident only after it has disappeared for **90 seconds**. Newly created users and phones that have never connected can show offline without triggering that incident.

## Recover an office connection

1. Confirm which office and users are affected. When several phones in the same office go offline together, compare them with another office before changing individual passwords.
2. Check the phone's saved SIP server/proxy and sign-in details. A tenant's web address is not automatically its SIP registrar. A restored Authentication ID can differ from the extension number; preserve the imported credentials.
3. Review the current block and its source evidence. Recovery must refer to one current, owned block and an affected source that the PBX previously verified. If the address is shared across unrelated tenants, or across departments outside your authority, ask the instance administrator to investigate.
4. As the **PBX owner**, select **Review recovery**, check **I recognise this office and have checked its phone settings**, then choose **Remove this sign-in block**. A stale, foreign, shared or unverified request is refused rather than broadening access. A **15-minute cooldown** prevents repeated unblock requests from masking an unresolved sign-in problem.
5. Check **Recent recovery requests**. **Waiting for confirmation** means that the request is queued, while **Block removed** means the security service acknowledged removal. **Review required** or **Not confirmed** needs investigation. The original block remains blocked in the security log until acknowledgment; accepting the web request alone does not mark it removed.
6. Wait for the phones to reconnect, refresh their status and complete an answered internal call. Then test incoming and outgoing provider calls if that office is being put into service.

Controlled recovery removes a specific verified block. It does not turn off the firewall, create a permanent whitelist, replace passwords, enable a provider or change call routes. If the same problem returns, fix the underlying sign-in or network problem before trying again.

The hosted Debian service supports its **IPv4 iptables phone-sign-in filter**. The Windows candidate supports its owned **Windows Defender Firewall IPv4 phone-sign-in rules**. IPv6 addresses, custom firewall adapters, ambiguous or additional overlapping security rules and unverifiable firewall state require instance-administrator review. The page does not bypass those restrictions. The security service processes a separate targeted request and rechecks its ownership and exact rule before it changes the original block.

## Alerts and privacy

On-page alerts are always available to permitted administrators. Email is **off by default**: under **Administrator alerts**, enable **Email me when phone health changes** and select **Save alerts** to receive messages at the PBX owner's saved email address. All messages use the instance's global outgoing-mail queue; no per-tenant SMTP server is required.

An email is queued when an incident starts and when it clears. Repeated checks are deduplicated; they do not send the same unchanged incident every 30 seconds. Administrator alerts describe the affected service, the observed problem and the next useful action. Incident detection, queue dispatch, SMTP acceptance and actual inbox delivery are separate results: a queued message is not proof that someone received it. Two loopback messages passed in isolated tests; actual customer-inbox delivery has not been claimed. Email remains off on the hosted instance until its owner opts in.

Phone contacts, office addresses, failed sign-ins and recovery evidence are operational data. Keep them within the permitted tenant and administrator views. Do not post raw logs, customer inventories, credentials or private diagnostics in public issues. The [call diagnostics guide](call-diagnostics.md) covers the separate finite call/media observer.

## Verification and limits

The final component checks passed **63 combined isolated PostgreSQL/native-worker controls**, including a two-process recovery race, and **20 actual iptables controls in an isolated network namespace**. These prove the targeted handler and exact rule checks without unblocking a customer office or modifying the host firewall as a fixture.

Debian worker/installer checks passed **19 controls**, including installation-hook coverage with **20 actual PostgreSQL schema checks**. Mail passed **25 controls** and two loopback deliveries. Browser fixtures passed **38 checks**; the real hosted owner workflow passed **10 trusted HTTPS checks** and **20 browser checks** across six light/dark layouts at 1440, 390 and 320 pixels. The actual menu entry, phone search and currently connected phones were checked.

The first managed service start failed during its privilege drop. The failure was retained; paired native units reproduced it and proved the correction. The protected launcher now drops its groups and user identity before enabling its privilege restriction, and PHP verifies the restricted identity before loading application code. The actual corrected managed service completed successfully, and its timer repeated at the configured 30-second interval.

Hosted activation preserved current customer media byte-for-byte with modes and ownership, all 23 original backup sign-in/password tuples, existing call configuration and firewall policy. The call engine stayed running and resumed with its original process; only the security worker was restarted. Five additive health tables store observations, incidents, settings and requests. Existing table differences were limited to normal service heartbeats, one explicit disabled-alert-settings audit and controlled owner login records, with original rows retained. No customer unblock, call or external email was performed for these checks.

Registration and office-block recovery do not qualify physical handset audio, every provider path or every office firewall. A real answered call remains the final check after a phone reconnects. Complete installer qualification, Windows support and wider **REPORT-06** criteria remain separate.

## Windows Server follow-up

The candidate uses one protected **OpenWebPBX-PhoneHealth** SYSTEM task. Its security-event connection stays open continuously; health scans run every 30 seconds. The shared PHP implementation provides the same phone/provider explanations, tenant and department permissions, persistent incidents, optional deduplicated global mail and recovery history. Loss of the security observer or Defender Firewall is itself a visible incident.

The native adapter creates separately owned TCP and UDP rules for the PBX's actual running phone listener ports. It does not assume every installation uses port 5060. RDP, SSH, other administrator ports, RTP media and unrelated firewall rules are preserved. Correctly registered sources and saved allowed networks are checked before creating an authentication-failure block. Recovery verifies rule identifiers, ownership, address, action and listener scope, and refuses changed, shared, additional or ambiguous restrictions. It never disables a firewall profile or adds a permanent whitelist.

Helpers and their response spool are protected against IIS or ordinary users replacing executable code or acknowledgment data. A private installation identity binds requests to this Windows installation; copying an old database cannot authorize a new server's recovery. Upgrade and restore holds prevent database and firewall actions. Same-install upgrade recovery preserves the installation identity and explicit disabled-task choices; restored pending recovery requests need separate invalidation before activation.

Actual Windows Server 2025 component qualification passed **16 native Defender Firewall controls**, including exact recovery with every original projected rule/filter/profile preserved, and **62 native SYSTEM controls**. The latter includes restricted ACL checks, 49 actual PHP filesystem/TCP/subprocess checks, a real bounded child termination, .NET-to-PHP lock interoperability and all four restore holds. Original PBX services remained stopped with unchanged process identifiers; no customer phone was called. Initial missing-rule, port-overlap, module-path and volume-root ACL refusals were retained and corrected before these passing repeats.

Windows security changes save an unconfirmed intent before changing Defender rules. If the task stops or PostgreSQL refuses the final commit after a rule was created, the observer reconciles the exact owned native rule on its next scan. Unknown native state remains visible as a security update needing confirmation, is excluded from confirmed blocked-office totals and cannot be recovered automatically; an absent rule is recorded as incomplete. Reconciliation never creates a rule from a restored or interrupted intent without a new validated sign-in failure. The PostgreSQL controls include a deliberate interruption after rule creation, an independent connection checking durable intent, a deferred commit failure and an intent-insertion failure before any firewall change.

A separate isolated native SYSTEM Task Scheduler check confirms that stopping the PowerShell task terminates its resident PHP child. The product also checks that no exact installed SYSTEM health wrapper or PHP child remains before source replacement, including when the task is already Ready or missing. An unexpected executable, owner or surviving process refuses the operation; no uncertain PID is killed. Full installed observer, continuous scans and restart acceptance remain required in the complete Windows suite.

Portable checks additionally pass **96 actual isolated PostgreSQL policy controls**, **68 firewall-adapter controls** with cmdlet doubles and **46 PowerShell task/ACL controls**. Policy signalling doubles do not establish native phone registration or audio. The complete Windows suite has a separate required installed-feature gate for the real SYSTEM observer, native engine collection, PostgreSQL boundaries, runtime, Defender rules and cleanup.

The complete package at source `568b3ab5f761e1d072ef271544674e037daae201` passed fresh setup, **29** web-readiness and **33** native STUN checks, then failed the new native-worker result check. Its earlier installed-task, collector, continuous-scan and restart steps do not establish a successful event-to-block-to-recovery flow. The original report omitted the child's PHP failure phase; later QA retains only closed phase, exception class, source basename/line and SQLSTATE, plus a distinct cleanup failure. An unchanged-package diagnostic replay remains ineligible for release or an owner upgrade even if later independent gates pass.

A separate real local-engine comparison found that a generic `event json CUSTOM` subscription with subclass filters could accept an event publication without delivering that subclass to the subscriber. The repaired stream explicitly subscribes to all three required subclasses before applying its filters. **26 actual Windows PHP loopback/child-process controls pass** against the exact repaired stream; the old `568b3ab5f` stream fails the same control. The loopback peer models subscription semantics; this proves the Windows client handshake and bounds, not the full Windows engine/security flow. A newly rebuilt complete package must pass that real flow before publication.

Native Windows maintenance-lock checks also distinguish real contention from unsafe paths or permissions. **11 native guard controls pass**: only actual sharing/byte-lock conflicts produce a typed busy result. The tenant-address worker defers on that result, rechecks restore holds under a successfully acquired lock and retains other failures. This avoids treating a healthy concurrent observer as an installation failure, without hiding ACL/path errors. It does not replace the complete upgrade/restore checks below.

The tenant correction separately passes **19 source/OS-lock controls** and **five actual Windows SYSTEM/Scheduler cases**: free held work defers successfully, real contention with or without a restore hold defers successfully, an actual SYSTEM ACL denial remains a failure, and normal work resumes after lock release. The old source fails the contention case. One intermediate fixture polling timeout is retained; the instrumented repeat passed against both exact final source files and all198 verified runtime members, with no remaining fixture task/process. This does not establish the lost numeric result of the earlier full-run tenant failure.

- [x] Implement native collection, the Windows security adapter, shared incident/mail behavior and guarded installer/task integration.
- [x] Qualify native Defender operations, SYSTEM identity/ACLs, process bounds and maintenance/restore holds in an isolated component workspace.
- [ ] Pass the rebuilt complete package's installed continuous-task, restart, observer and actual ESL-to-Defender-to-PostgreSQL recovery checks.
- [ ] Pass trusted IIS owner/staff/department/tenant acceptance, including denied recovery.
- [ ] Pass same-version repair, exact upgrade recovery and encrypted clean/same-machine restore with pending-request invalidation.
- [ ] Complete the wider Windows gates, including decoded conference media, independent encrypted backup/restore and signed upgrade/recovery, before publication.

Broader system health remains part of **REPORT-06** in [3CX.md](../3CX.md): service failures, storage, backup/certificate failures, protected exports and remote logging are not completed by a phone-registration page. Roadmap totals remain **133 goals: 21 accepted, 72 partial and 40 planned**.

## Related guides

- [Desk-phone migration and office-block troubleshooting](desk-phone-handover.md)
- [Remote Yealink W60B, proxy and STUN settings](yealink-w60b-remote.md)
- [Providers and first calls](core-calling.md)
- [Users and department access](department-staff.md)
- [Global outgoing mail](outgoing-mail.md)
