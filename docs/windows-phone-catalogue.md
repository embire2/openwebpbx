# Windows phone release catalogue

Status: source work under qualification. No Windows phone release or catalogue is published.

The PBX uses a separate signed Windows phone catalogue. The Android and Windows server update channels are unchanged. The catalogue is public metadata; it does not contain tenant passwords, SIP credentials or account tokens. The PBX API reads the local verified catalogue and never fetches a release while answering an account request.

The privileged refresh verifies the original RSA-signed envelope, component, channel, platform, publisher/package identity, expiry, hash, size and increasing sequence. A prepared publication journal protects the accepted high-water mark across interruption. Missing, expired, malformed or conflicting data makes the release unavailable without discarding the previous high-water mark. Tenant restore preserves the destination instance's catalogue; operator rollback refuses to lower its accepted trust state.

Windows stages an owned, disabled SYSTEM task under the same maintenance lock used for upgrades and recovery. Exact task XML and security are retained. Activation follows a durable completed installation or upgrade, preserves an administrator's disabled choice and can resume from its own prepared activation record. The source and catalogue files belong to the sealed upgrade recovery inventory.

Debian uses the shared `/run/openwebpbx-upgrade.lock`. A new updater lends its actual exclusive file descriptor through the PHP/bootstrap/support child chain. The helper checks the descriptor's inode, owner, mode and kernel `fdinfo` lock record; an unrelated busy lock or an update journal does not authorize writes. Standalone setup acquires the same lock itself. Existing managed catalogue units are verified and stopped before replacing their helpers, with the timer's previous active choice restored on failure.

An older updater cannot lend that descriptor. When the catalogue is entirely absent, migration can retain seven inert, bounded `windows-phone-catalogue.pending.*` files in the existing private updates directory. All seven original bytes or absence entries are added to the durable support rollback inventory before writing. The new updater's finalization checks the exact completed version, original release manifest and every retained input before executing the helper under its actual maintenance lease. Existing catalogue installations cannot use this first-install compatibility path. The pending inputs remain available for retry.

Current checks: 128 actual PHP signature/filesystem controls, 23 isolated Linux groups including the actual inherited-descriptor child chain and file rollback, 36 task-definition controls, 76 activation controls, 33 stage-reader controls and 179 strict native-receipt/source controls, 120 actual failure/early-catch/owned-process cleanup controls and 9 PHP failure-producer controls. Linux paths and systemd operations are explicit test adapters; task/ACL observations in portable PowerShell tests are adapters. These counts do not establish a native Windows, full installer, upgrade or release pass.

The prepared disposable Windows component uses real NTFS, PHP locks, exclusive .NET file handles, durable replacement, Scheduler operations and owned child interruptions. Its reader SID alone is mapped to LocalService in the fixture; it does not test a reader process. Actual IIS identity/read permissions, installed fixed paths, normal unpublished-channel behavior, complete backup/restore, signed upgrade and final release publication remain separate acceptance gates. No private production signing key is part of the fixture.

The first actual standalone Windows run (40000139958, catalogue source da482791)
refused in Desktop preflight at its first Get-FileHash command, before any native
catalogue case or fixture task. Its original bounded failure remains retained.
The focused fixture correction imports the exact stock Desktop Utility and
Security manifests and verifies their distinct FunctionInfo/CmdletInfo sources,
ordinary ancestry, module identities and native assembly provenance. It changes
neither PSModulePath nor production catalogue code. Ninety portable source/type/
path controls pass on Linux (the three Linux-only ancestry/platform controls are
not Windows claims). Read-only Windows checks also pass the exact bootstrap and
real stock-manifest hash/ACL reads in both original and explicitly inherited Core
module-path child environments; the parent environment remains exact. This is
bootstrap acceptance only. A new complete native catalogue run is still required.

The next actual standalone run (40002573255, source9194e35d) passed Desktop
bootstrap but refused at the seed directory's original IIS-account lookup. The
fixture had written its reviewed reader-SID adapter for child processes while
the parent retained the original Common definitions. The narrow fixture fix now
verifies the adapted copy's exact bytes and imports it before the parent's first
catalogue call. Eight additional actual-function/import/refusal controls pass;
no native ACL or IIS-read acceptance follows from these portable controls.
Original vectors, stock runtime inventory and owned cleanup were verified in
the failed native run. A fresh component run remains required.
