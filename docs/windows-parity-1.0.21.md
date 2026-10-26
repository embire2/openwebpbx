# Windows Server 1.0.21: coverage and release status

**Candidate — qualification pending.** The supported server target is **Windows Server 2025 x64 with Desktop Experience**. The public Windows release remains [1.0.20](https://github.com/embire2/openwebpbx/releases/tag/v1.0.20); 1.0.21 is not published.

The latest [complete test40377313091](https://github.com/embire2/openwebpbx/actions/runs/40377313091), [source3fbb9c12f9013f82b4350aa9c5f4a2f43f842878](https://github.com/embire2/openwebpbx/tree/3fbb9c12f9013f82b4350aa9c5f4a2f43f842878), failed in its newly added temporary PostgreSQL DID test before the complete suite; canonical cleanup passed. Separate [component40383982749](https://github.com/embire2/openwebpbx/actions/runs/40383982749) isolates the refusal to initdb, whose original stderr remains unretained. No complete package acceptance follows. The same66 real DID controls pass on the owner’s Windows Server2025 through a separate bounded PowerShell adapter; that result does not qualify the original Python/Job driver. The preceding4310 package passes all17 essential software gates. A correction for tenant-address HTTPS443 across automatic, local and installed certificate modes passes source/binder controls; its new native build40388086310 succeeds, with independent archive admission and a fresh full run pending. Matching restore, signed-update and restored-conference checks remain required.

## What the Windows server includes

These features are implemented; the current package must still complete the release checks below.

| Area | Windows delivery | Operator guide |
|---|---|---|
| Complete local installation | PostgreSQL on the PBX machine, FreeSWITCH, IIS/PHP administration, background service, native server manager and installer | [Install Windows](installing-windows-1.0.21.md) |
| Tenants, users and calling | Shared instance database with tenant controls; extension accounts, providers, incoming/outgoing routes, groups, queues, callbacks and voicemail | [Current feature roadmap](../3CX.md) |
| Add a provider number | Add a DID and destination directly from its trunk; optional continuation into Call Me Back with that number selected. Live on hosted Debian; separate owner Windows66 controls pass, final package qualification pending | [Number setup](trunk-options.md#add-an-incoming-number) |
| Company schedules | Company-group hours, breaks, holidays and overrides; optional separate extension routing during and outside office hours | [Company office hours](company-office-hours.md) |
| Greetings and system audio | Keoma system speech; reusable phone recordings and configured typed narration, dedicated Windows storage and preservation of existing custom audio | [Greetings](greetings.md) |
| Mail and onboarding | One outgoing SMTP setup, including IP-whitelisted relays; welcome email, QR/configuration setup and voicemail mail processing | [Tenant phone accounts](tenant-phone-accounts.md) |
| Phone Health and connectivity | Registration/recovery status, Windows protection integration, configured public listeners and STUN | [Installation and network checks](installing-windows-1.0.21.md) |
| Conferences | Meeting service, secure browser transport and software audio/video tests; replacement restores have a separate conference gate | [Windows meetings](windows-meet.md) |
| Backups and recovery | Encrypted scheduled/manual Windows instance backups, retention, media and controlled replacement activation | [Windows backups](windows-backups.md) |
| Updates | Five-minute signed-feed checks and verified predownload; desktop modal and red web banner. Services continue until an administrator chooses installation. Existing idle, backup/restore and recovery protections remain | [Windows upgrades](windows-upgrade.md) |

The browser administration remains the main PBX administration interface. The native WinUI server manager handles installation, status and update controls; a complete WinUI administration rewrite is unfinished. This coverage is not a claim that every 3CX feature is complete.

## Required before publishing 1.0.21

All four functional results must match the same final package. Audit its archive and corresponding source before signing or publication.

| Release requirement | Required evidence | Current status |
|---|---|---|
| Complete normal run | Fresh installation and all17 essential calling, service, security, backup, update/recovery and cleanup gates | 40377313091 failed at the added temporary database driver; corrected full repeat pending |
| Independent replacement restore | Clean target, preserved database/media/credentials, original-credential calling and restored jobs | Pending for the final matching package |
| Signed newer-version update | Actual verified download, upgrade, failure rollback, natural restart, manager reopen and preservation | Pending for the final matching package |
| Restored conferences | Actual browser audio/video on the replacement, preserved data and complete cleanup | Pending for the final matching package |
| Archive and source audits | Exact package inventory, hashes, required native/source inputs and private-data exclusions | Matching3fbb source audit passed; installer audit waits for an accepted fresh package |

[Windows1.0.20 qualification](windows-parity-1.0.20.md) remains evidence for that public release. The [older21 results and detailed qualification record](release-1.0.21-qualification.md) retain their original scope, including the earlier7d package and native component tests. They do not substitute for the requirements above.

A separate owner test machine has confirmed Server2025 administrator access,8GB RAM,144GB free storage,UTC+2 and running Microsoft Defender. The corrected standalone recovery fixture passes220 checks on stock Windows PowerShell5.1; this excludes an actual updater binary. The published1.0.20 baseline has completed installation with the recorded process-scoped crypto configuration and standard443 workaround; all four services and its native manager are running. Owner calling, upgrade and reboot checks remain pending.

## Explicit limits

- Real Windows reboot, legacy Windows1.0.6 migration and external physical-phone/carrier handover remain unqualified.
- Public ACME issuance/renewal and continuity of old meeting invitation links remain unqualified; controlled HTTPS and new/restored meeting tests have narrower scope.
- Debian instance backups are not Windows restore inputs. The supported 3CX configuration importer is a separate migration path requiring its Restore Report and actual deployment checks.
- Windows10/11 server installation is unsupported. Windows Free Phone is a separate development client; its media, distribution and Microsoft Store acceptance are unfinished.

Use the [installation guide](installing-windows-1.0.21.md) for prerequisites and deployment checks, and the [roadmap](../3CX.md) for remaining product work.
