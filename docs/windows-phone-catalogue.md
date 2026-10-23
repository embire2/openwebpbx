# Windows phone release catalogue

Status: source work under qualification. No Windows phone release or catalogue is published.

The PBX uses a separate signed Windows phone catalogue. The Android and Windows server update channels are unchanged. The catalogue is public metadata; it does not contain tenant passwords, SIP credentials or account tokens. The PBX API reads the local verified catalogue and never fetches a release while answering an account request.

The privileged refresh verifies the original RSA-signed envelope, component, channel, platform, publisher/package identity, expiry, hash, size and increasing sequence. A prepared publication journal protects the accepted high-water mark across interruption. Missing, expired, malformed or conflicting data makes the release unavailable without discarding the previous high-water mark. Tenant restore preserves the destination instance's catalogue; operator rollback refuses to lower its accepted trust state.

Windows stages an owned, disabled SYSTEM task under the same maintenance lock used for upgrades and recovery. Exact task XML and security are retained. Activation follows a durable completed installation or upgrade, preserves an administrator's disabled choice and can resume from its own prepared activation record. The source and catalogue files belong to the sealed upgrade recovery inventory.

Debian uses the shared `/run/openwebpbx-upgrade.lock`. A new updater lends its actual exclusive file descriptor through the PHP/bootstrap/support child chain. The helper checks the descriptor's inode, owner, mode and kernel `fdinfo` lock record; an unrelated busy lock or an update journal does not authorize writes. Standalone setup acquires the same lock itself. Existing managed catalogue units are verified and stopped before replacing their helpers, with the timer's previous active choice restored on failure.

An older updater cannot lend that descriptor. When the catalogue is entirely absent, migration can retain seven inert, bounded `windows-phone-catalogue.pending.*` files in the existing private updates directory. All seven original bytes or absence entries are added to the durable support rollback inventory before writing. The new updater's finalization checks the exact completed version, original release manifest and every retained input before executing the helper under its actual maintenance lease. Existing catalogue installations cannot use this first-install compatibility path. The pending inputs remain available for retry.

Current checks: 128 actual PHP signature/filesystem controls, 23 isolated Linux groups including the actual inherited-descriptor child chain and file rollback, 36 task-definition controls, 76 activation controls, 33 stage-reader controls and 179 strict native-receipt/source controls, 124 actual failure/early-catch/owned-process cleanup controls and 9 PHP failure-producer controls. Linux paths and systemd operations are explicit test adapters; task/ACL observations in portable PowerShell tests are adapters. These counts do not establish a native Windows, full installer, upgrade or release pass.

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

Run40003413070/source85ae862f reached mutual exclusion, then refused while
FinishPhp parsed child JSON. The retained receipt does not identify the child
action or raw-output shape, so no warning or lock cause is established. A focused
QA diagnostic now retains the original JSON-conversion exception plus fixed
action, original exit, expected-success flag, bounded character counts and output
shape. A warning-prefix flag and any valid existing PHP failure record contain no
raw output. Nothing is stripped or accepted after parsing fails. Real PHP child
output and actual FinishPhp controls pass53 checks; the hosted wrapper will run
them against the exact prepared PHP runtime. This is diagnostic coverage, not a
native catalogue or historical-cause pass.


Run40006107690/sourcefd1da72c preserves the actual failing `--refresh` child:
exit0, expected-success false,272 stdout characters,0 stderr characters,
non-JSON output and no plain warning-prefix match. The retained original job
and artifact contain no child text, so the underlying cause remains unknown.
The diagnostic now frames the exact captured .NET UTF16 code units (stdout and
stderr, each at most32768 characters) in a new private file, preserving the
original JSON-conversion failure. The exporter checks actual bytes, framing and
SHA256 before sealing with the pinned QA public key using RSA3072-OAEP-SHA256
and AES256-GCM. Authenticated metadata binds purpose, exact source/run, edition,
stage, size and hash. Only that sealed envelope and closed fields enter the
existing JSON artifact. No private key enters the runner; failed collection or
encryption cannot replace the primary error. No output is stripped or accepted.

The focused checks pass85 real binary/CreateNew/hash/ephemeral-crypto controls,
63 actual PHP/FinishPhp controls and132 strict failure/primary-preservation
controls. Protected-file/ACL APIs are explicit portable adapters. No Windows
catalogue case, lock cause, installed IIS reader or release pass is inferred;
a fresh native run is still required. Runtime catalogue and lock behavior stay
unchanged.


Run40008746341/source39a05353 reproduces the same Desktop failure and retains
its original272/0-character child output encrypted. Verified private decryption
identifies a Notice from `stream_get_contents` in the protected reader (line63),
with errno13 while reading the empty maintenance lease before the competing
refresh returns valid deferred JSON. The fixture's PHP holder owns both leases
at that point. No raw private output or paths are published.

The correction changes only the reader's content assignment: after actual
`fopen` and `fstat`, an opened zero-byte file supplies empty data without issuing
a content read against Windows' mandatory byte lock. The complete subsequent
before/opened/after identity and metadata checks and finally-close remain exact;
real lease acquisition remains unchanged. There is no error suppression, output
stripping or early return. Thirty-five actual isolated Linux file/refusal checks
pass, including explicit read/metadata adapters that show zero content reads and
all nine later metadata guards. The unchanged old reader fails the empty-read
adapter at the expected operation. Existing128 PHP and23 Debian groups pass.
A fresh Windows component must still prove the corrected native lifecycle.


Run40009929505/source7672632c retains a different original failure: Desktop
mutual exclusion, PHP exit3, `refresh.fixture.php` line53. That exact source
operation reports a nonzero exit from the PowerShell durable-commit child; its
inner error was discarded by the original NUL descriptors. The underlying
PowerShell cause is not yet established. Original vectors, child/task cleanup
and the stock runtime inventory remained exact; no complete native pass follows.

A fixture-only observer changes exactly those two descriptor destinations to
private precreated files supplied through each direct PHP child's environment.
Without those child-only values the descriptors remain NUL, preserving scheduled
worker behavior. Executable, arguments, proc_close invocation, real lock checks
and product source stay unchanged. Capture uses the failing child's exact index
and only its validated RuntimeException at the original commit-failure source
line. Unrelated later failures cannot attach stale output. Up to65536 raw bytes
per stream are framed with UInt32LE lengths, without text decoding, then sealed
under the existing QA public key. Distinct authenticated stage `commit_child`
and explicit raw encoding bind source, run, edition, PHP exit/action, size and
hash; the earlier UTF16 diagnostic remains separate. Original failures survive
capture/encryption refusal. Fifty actual PHP/raw-file/ephemeral-crypto controls
and141 strict failure controls pass with explicit ACL/native-reader adapters;
actual Windows commit acceptance still requires another reviewed run.


Run40012022141/sourcef29f0d35 retains the actual commit child's raw error in the
purpose-bound encrypted record. Verified private decryption identifies
`Get-Acl` with `CouldNotAutoloadMatchingModule`, surfaced through the state
permission check at Common line46. This is an actual Security module-loading
failure; no lock or ACL permission-denial cause is inferred.

The runner now bootstraps only on Windows PowerShell Desktop before importing
Common: it imports absolute stock Security and Utility manifests and validates
the actual Get-Acl, ConvertFrom-Json and Add-Type CmdletInfo identities, module
paths/versions/GUIDs, ordinary ancestry, native assemblies, strong-name token and
implementation types. The two Utility commands are explicit dependencies of the
existing Refresh/Commit paths. PSModulePath and the entire original runner body,
shared Recovery helpers and real locks remain unchanged.

Eighty portable source/type/proxy/path controls pass. Read-only Windows PS5
probes separately establish native Utility3.1.0.0/assembly3.0.0.0 provenance:
with child-only autoload disabled both commands are absent, then explicit stock
import makes both real operations succeed with empty stderr. The original-mode
392-byte stderr record is retained and contains only CLIXML progress. Parent
environment stays exact. The owner lacks the GHA Core module directory, so no
inherited-Core reproduction is claimed. A further optional exact-prelude probe
refused at transport command length before execution; it is retained separately
and does not qualify the new runner. A fresh native component is still required.
