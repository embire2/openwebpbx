# Windows ordered-upgrade repair

Published **16 November 2026**: [download the Windows updater repair](https://github.com/embire2/openwebpbx/releases/download/windows-v1.0.23/openwebpbx-1.0.23-windows-updater-repair.zip)
([checksums](https://github.com/embire2/openwebpbx/releases/download/windows-v1.0.23/windows-updater-repair-SHA256SUMS)).
The actual installed **1.0.21 → 1.0.22 → 1.0.23** chain passed on Windows Server
2025. Original customer data is preserved and the repaired updater runs
automatically. This component is added alongside the unchanged full Windows
1.0.23 installer and original signed feeds.

Extract the complete repair ZIP and open **Start-UpgradePathRepair.cmd** on the
Windows PBX server. Allow administrator access once and leave it running until
completion. The launcher downloads required signed releases and applies them
in order. Original installations need this one-time repair; publishing a feed
alone cannot teach their old updater the new sequence.

## Versions and purpose

| Item | Version and scope |
| --- | --- |
| Public qualified Windows Server suite | 1.0.23; its ordinary signed feed requires installed 1.0.22 |
| New Windows updater component | Product version 1.0.23, informational version `1.0.23+upgrade-path.1`, repair ID `upgrade-path-1` |
| Component repair applicability | Installed Windows 1.0.20–1.0.23; the signed component inventory contains exactly 227 files |
| Initial ordered catalogue | Supported starting floor 1.0.20, then 1.0.21 → 1.0.22 → 1.0.23 |
| Hosted Debian App/Core/updater | 1.0.26; this Windows component repair does not deliver Debian 1.0.26 features or Windows parity |

An original 1.0.20 or 1.0.21 worker cannot install the latest Windows 1.0.23
directly because its minimum is 1.0.22. That refusal is correct. Those older
workers also do not understand a newly published ordered catalogue, so they need
the explicit administrator bootstrap described below. Publishing metadata alone
cannot add code to an already installed original worker.

The component adds ordered planning and continuation to the updater. The core,
website, database and complete Windows release archives keep their existing
version identities. Each full release in the chain still uses its normal
preflight, backup, installation, recovery and health checks.

## Signed release authority

The new `windows-upgrade-path.json` catalogue uses the pinned `release-2026-a`
RSA/SHA-256 signing key in its separate `windows-upgrade-path` namespace. Its
payload identifies `openwebpbx`, the stable channel and `windows-x64`, with
publication/expiry dates and an independent monotonic sequence. It binds the
exact verified latest release payload hash and sequence, plus the SHA-256 of
every exact historical signed step envelope. Every step retains its original
release signature, validity dates, platform, asset checksum and minimum
installed version.

For the initial chain, the qualified historical source locations are:

| Release | Signed Windows envelope location |
| --- | --- |
| 1.0.21 | `releases/download/v1.0.21/windows-update-manifest.json` |
| 1.0.22 | `releases/download/windows-v1.0.22/windows-update-manifest.json` |
| 1.0.23 | `releases/download/windows-v1.0.23/windows-update-manifest.json`, matching the independent Windows latest envelope |

These paths belong to `github.com/embire2/openwebpbx`. There is no historical
`windows-v1.0.21` tag. The retained canonical `v1.0.22` Windows envelope still
advertises 1.0.21; it must not be rewritten or used as the 1.0.22 step. The
catalogue commits to the actual retained signed bytes, rather than inferring a
release from a tag name.

The planner first verifies the latest release against the ordinary saved release
trust floor. Only then can the separately verified catalogue authorize an older
intermediate envelope. Historical step sequences never replace or reset the
ordinary latest-release trust floor. Catalogue sequence/hash history is separate
and cannot move backwards or accept a conflicting payload at the same sequence.
Package admission rechecks the actual installed version and permits only the
next authorized step. Unsupported starting versions below 1.0.20 require their
separately supported legacy transition.

A signed `previous_version` chain defines installation order. It may declare a
future forward gap where no Windows release exists, such as 1.0.23 → 1.0.26
after Debian-only releases. The target's original minimum must still permit its
declared predecessor; the worker never invents missing releases or skips a
publisher-declared step.

The updater may use its original direct-update path after a catalogue HTTP 404
only when it has never retained a catalogue or catalogue trust file and the
installed version already satisfies the latest minimum. Retained catalogue
history makes a 404 fail closed. Invalid signatures, conflicting or expired
metadata, unsupported predecessors and other download errors do not bypass the
catalogue. No ordinary minimum is lowered, no saved trust history is deleted and
no old release/feed asset is overwritten by this repair.

## Normal behavior after the component is installed

Windows continues checking every five minutes. It downloads and verifies the
next required package while the phone system keeps running. Its desktop notice
and red web banner remain visible; postponement does not disable any service.

One explicit administrator installation request can approve the complete
verified chain. The worker records the original database command, its creation
time, the approved final release and catalogue hashes, and a maximum 24-hour
approval lifetime. It waits for active calls before installation. After an
intermediate release restarts the worker, the same still-active command resumes
the next step from its pinned signed authority. A completed, expired or missing
database command cannot be replayed by copying an old approval file. A changed
final release requires fresh approval.

The complete package is verified before the ordinary installer stops services.
Each step has its own normal backup and recovery journal. The updater component
does not treat phone registration or a green service state as proof of real
ringing, carrier operation or two-way audio.

Historical 1.0.21/1.0.22 packages contain their original updater and replace that
component during installation. Use the bootstrap for those steps: its separate
process continues across the old packages and reapplies the signed component
between them. Copying only the new executable into an old installation and
pressing Update Now is not the qualified historical transition. The continuous
worker journey above requires intermediate packages containing the ordered
worker; future Windows packages must include it.

## One-time administrator bootstrap for original workers

**Public repair download:** use the tested ZIP linked above. Its 37,292,554 bytes
have SHA-256 `0752fdcf27f38c964b53f01868ccd3209aefbb9b773322fe02a02ed88b37e417`.
The corresponding [source archive](https://github.com/embire2/openwebpbx/releases/download/windows-v1.0.23/openwebpbx-1.0.23-windows-updater-repair-source.tar.gz)
and signed component inventory are published separately. Do not change an old
feed or trust file to make an older worker accept a package.

The intended entry point is
[`Invoke-UpgradePath.ps1`](../packaging/windows/Invoke-UpgradePath.ps1), run in
**Windows PowerShell as Administrator** on the installed server. The real acceptance target
started at installed 1.0.21 and completed at 1.0.23. Applicability to a starting 1.0.20 is
represented by the signed range and planner tests; it is not a completed real
1.0.20 upgrade test.

The normal administrator steps are:

1. Download the published repair ZIP, verify its published SHA-256 and extract
   the complete ZIP into a local folder on the Windows PBX server.
2. Double-click **Start-UpgradePathRepair.cmd**, allow the Windows administrator
   prompt and leave the window open until it reports completion. The launcher
   prepares its protected files, verifies the signed component through the
   runner and downloads the required signed full releases before installation.
   No database password, release URL or technical setup option is required.

The launcher stages only the named bundle components into a new protected
`upgrade-path-repair\bundles\<unique-id>` folder. Shared downloaded archives,
original updater slots, logs and recovery records are retained. It refuses
linked source files or preexisting staging paths with untrusted ownership or
write access. Verified existing local-administrator ACEs are accepted; new
staging still grants only Administrators/SYSTEM. For qualification without installation, an administrator can run
`Start-UpgradePathRepair.ps1 -Check`; the switch survives UAC elevation and is
forwarded to the verified runner.

This bundle carries an exact latest Windows 1.0.23 parent. If a server's ordinary
saved trust has already advanced beyond that parent, use a newly qualified
bootstrap bundle published for the newer Windows release. The bundled 1.0.23
authority cannot authorize an unknown future parent; do not reset trust files
to reuse it. Future Windows publications must refresh this bundle along with
the catalogue and latest mirrors.

1. Confirm the intended server and actual installed version. Retain a verified
   full backup and its private recovery information. Preserve at least 10 GiB
   free beyond the expanded release and current application backup requirements.
   Use a naturally idle maintenance window for changes that affect calls.
2. Stage the verified repair component, its signed manifest, the latest Windows
   envelope, signed catalogue, required historical envelopes and complete
   archives inside `%ProgramData%\OpenWebPBX\upgrade-path-repair`. The workspace
   and its inputs must have trusted ownership and write access restricted to
   Administrators/SYSTEM; linked inputs are refused.
3. Run the bootstrap with `-Check`. It verifies the component inventory and
   signature, actual installed version, both saved trust histories, the complete
   signed plan, and downloaded archive sizes/checksums. This mode does not patch
   the updater or install a full release. Review the exact ordered plan before
   continuing.
4. Run the same verified bootstrap without `-Check`. It retains the selected
   updater slot's original files and inventory before applying the explicitly
   signed component repair. Each selected full release then runs through the
   ordinary installer with its authorized step envelope and protected signed
   parent context. The runner remains outside the mutable application tree
   between releases, verifies the actual completed version/journal and continues
   the next required step.
5. After the final full release, the runner retains the original final updater
   slot too, installs the persistent component repair, verifies the latest
   ordinary trust floor and starts the updater. Review its result, service
   health and normal administration access. Actual call/audio checks remain
   separate acceptance work.

The script takes these explicit inputs; paths below illustrate the protected
staging layout and are not download URLs:

```powershell
$work = Join-Path $env:ProgramData 'OpenWebPBX\upgrade-path-repair'
$repairArguments = @{
    RepairRoot       = "$work\runner"
    RepairManifest   = "$work\repair-updater-manifest.json"
    LatestFeed       = "$work\catalogue\1.0.23.json"
    UpgradeCatalogue = "$work\catalogue\windows-upgrade-path.json"
    HistoricalFeeds  = "$work\catalogue"
    ArchiveDirectory = "$work\archives"
}
& "$work\Invoke-UpgradePath.ps1" @repairArguments -Check
```

Historical envelope filenames are `1.0.21.json`, `1.0.22.json`, and so on. Once
the preceding checks and maintenance preparation are complete, installation is
requested with:

```powershell
& "$work\Invoke-UpgradePath.ps1" @repairArguments
```

The component's read-only planner CLI is also available for diagnosis:

```powershell
& "$work\runner\OpenWebPbx.Updater.exe" `
    --verify-windows-upgrade-path `
    --latest-feed-envelope $repairArguments.LatestFeed `
    --upgrade-catalogue $repairArguments.UpgradeCatalogue `
    --historical-feeds $repairArguments.HistoricalFeeds
```

Its JSON contains the verified selected steps and signed envelopes. It does not
write a new trust floor or approve installation. Preserve failed logs and
receipts separately from any successful retry. Do not delete an installation
journal, maintenance hold or lock file to force progress.

## Recovery and retained original updater slots

Full-release recovery and component rollback are different operations. If a
normal full-release transaction is interrupted or fails, its existing installer
recovery journal and verified backup own recovery. An administrator must review
that state before attempting another step or a component rollback.

For a component-only rollback after the full transaction has settled:

1. Preserve the failed component, result, logs, ordinary release trust and
   catalogue trust. Confirm the installed version, selected updater service path
   and selector all identify the same expected slot.
2. Locate the matching
   `%ProgramData%\OpenWebPBX\upgrade-path-repair\original-slots\<version>`
   receipt. Verify **every** retained original file against its
   `slot-inventory.json` before using it. A missing or mismatched original is a
   recovery failure requiring review.
3. Use the normal exclusive upgrade-maintenance guard, stop only the updater
   service and restore the verified original updater files to that same selected
   slot. Preserve its required permissions and retain the failed repaired bytes
   separately. Do not overlay another version's slot or manually change the
   installed PBX version.
4. Verify the restored slot and its service/selector paths before restarting the
   updater. Leave both trust histories intact. Restoring an original older
   worker can restore its inability to plan intermediate steps; it does not
   authorize a direct upgrade below the latest minimum.

The bootstrap performs its own component-copy recovery if patching fails and
retains the original inventory. A failure to restore those originals remains an
administrator recovery condition. This document does not replace the normal
full-PBX restore procedure or establish that a real rollback of this new chain
has passed.

## Evidence and acceptance boundaries

| Evidence | Result | Scope |
| --- | --- | --- |
| Offline catalogue signer tests | 13 passed | Generated-key catalogue construction, original signed release bindings and refusal cases; `tests/test_windows_upgrade_catalogue.py` |
| Portable ordered planner controls | 58 passed | Signed metadata, exact step envelopes, minimums, canonical history locations, next-step admission and independent anti-rollback; `--windows-upgrade-plan-checks` |
| Existing portable updater controls | 82 passed | Existing signed-feed, archive, download/recovery and policy controls |
| Native ordered worker fixture | 17 passed | Actual Windows PowerShell/ACLs and a dedicated PostgreSQL fixture; mocked package installer and local fake call engine; `--windows-upgrade-worker-checks` |
| Offline repair signer controls | 38 passed | Generated test keys only, exact 227-file inventory, independent signature verification, tamper and refusal cases; `tests/windows_updater_repair_signer.py` |
| Offline publication catalogue guard | 24 passed, plus 18 existing three-feed promotion tests | Generated-key snapshot fixtures; catalogue retention, exact latest binding, preserved history, anti-rollback and read-only CLI behavior; `tests/platform_release_catalogue.py` and `tests/platform_release.py` |
| Real installed 1.0.21 → 1.0.22 → 1.0.23 | **PASS, 16 November** | Both full ordinary signed transactions; 22 completed 12:26:22 UTC and 23 completed 12:38:30 UTC; final updater automatic/running and natural installed/available 23 status |
| Real starting 1.0.20 chain / new-path full rollback | **Not established** | Requires separate full installation/recovery qualification |
| Exact final public launcher | **PASS** | Published source `130ebbd95df171e701ac8a43d21ba01a5b4cdf72`; exact 238-file bundle; real starter `-Check` exits 0 with all service generations and nine customer-table digests unchanged |
| Download and permission guards | **PASS** | Seven downloader refusal/reuse controls; real 643,251,073-byte 1.0.22 GitHub download/checksum; nine native launcher permission/link controls |
| Natural five-minute checks | **PASS** | Two ordinary checks 300.789507 seconds apart; same automatic running updater process; installed/available 1.0.23 and native manager reopened/responding |
| Public repair and signed catalogue | **Published** | New assets only; original Android/Debian/Windows feed bytes and complete installer assets retained |

The first packaged launcher check refused a legitimate existing local
Administrator ACE. Its failed candidate and unchanged-state evidence are
retained. The corrected guard verifies actual local Administrator membership,
refuses ordinary-user/broad-group writes and unsafe ownership/links, and leaves
installed ACLs unchanged. Only the rebuilt exact ZIP above passed and was
published. Earlier checkpoint-path, descriptor/group and asynchronous profile
observation failures also remain distinct from their corrected successful runs.

The real chain starts from a verified full encrypted checkpoint copied offhost.
Independent comparison preserves all nine original customer-table projections,
including credential and reusable QR fields, all 66 original media/private
identity files, all 32 certificate-store identities/private-key choices and the
IIS bindings/pools. Only two host-address files and six precisely scoped old
host-address settings were repaired before upgrading. Those corrections start
the previously missing IPv4 SIP profiles; no customer route or password is reset.
The Windows test PBX has no provider gateways or registered phones, so these
results do not establish carrier, desk-phone or human-audio acceptance.

The native worker fixture passed in approximately three seconds. Its dedicated
temporary database and executable staging were removed; nine protected
production configuration-table fingerprints remained exact. It did not change
the production PBX services, invoke the real product installer or prove a full
server upgrade. Private database details, connection strings and raw evidence
are not part of this document.

These evidence groups are separate; their counts must not be added together and
described as complete real-upgrade acceptance. Earlier qualified Windows release
results retain their original scope. See also
[Windows update behavior](windows-server-updates.md) and
[independent platform releases](independent-platform-releases.md).

## Publishing the next Windows release

Use `packaging/updates/platform-release.py` on the complete reviewed `before/`
and proposed `after/` snapshots. Its CLI now requires an existing
`windows-upgrade-path.json` to survive every promotion: Debian/Android retain its
exact bytes; Windows supplies a freshly signed, advancing catalogue tied to the
new Windows latest. The original catalogue floor and step prefix remain exact.
Optional `catalogue/<version>.json` or top-level `<version>.json` historical
envelopes are verified when present. This metadata guard does not qualify full
packages or replace the C# planner/installer checks. The existing Python
`validate()` three-feed API retains its original contract.

1. Include the integrated ordered worker/verifier in the new complete Windows
   package. A catalogue cannot upgrade the code of original clients on its own;
   retain the explicit bootstrap route for those clients.
2. Qualify the actual signed package, ordinary upgrade, recovery and restart
   behavior. Publish its independent Windows envelope under the correct
   `windows-v<version>` tag without changing retained canonical/historical
   objects.
3. Build and sign a new catalogue with a strictly advancing catalogue sequence,
   valid dates and the exact new latest payload/sequence. Retain the supported
   predecessor chain and original historical envelope hashes. Every declared
   forward edge must satisfy its target's unchanged minimum version.
4. Publish the signed catalogue as `windows-upgrade-path.json` and keep the
   independent Windows latest envelope and the stable
   `releases/latest/download` mirrors aligned with its final release. Verify
   actual downloaded bytes after upload. A Linux-only or Android-only release
   must carry forward the existing Windows feed **and** catalogue mirrors
   unchanged so GitHub's latest-release movement cannot break Windows clients.
5. Keep any separately delivered updater component's exact inventory, manifest,
   rollback record and download instructions aligned with the delivered bytes.
   [`sign-windows-updater-repair.py`](../packaging/updates/sign-windows-updater-repair.py)
   signs only this fixed `upgrade-path-1`/1.0.23 component using an account-owned
   mode600 key outside the checkout. It verifies against the pinned public key
   and refuses to overwrite an existing output. Future component identities
   require their own reviewed applicability and qualification.
6. Record the actual qualified result, installed component identity and public
   download link here. Update Windows catch-up separately; do not describe this
   updater-only repair as Debian 1.0.26 feature parity or publish an unqualified
   full Windows suite under that version.

The public bootstrap ZIP must also be refreshed for each new supported Windows
parent, including its runner, exact signed catalogue, historical envelopes,
latest parent envelope and starter/download scripts. An old bundle remains
bound to its own signed parent and must refuse a newer saved release trust floor.
