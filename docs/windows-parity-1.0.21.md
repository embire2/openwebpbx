# Windows Server 1.0.21: coverage and release scope

**Complete Windows and Debian server1.0.21 release**. Supported server: **Windows Server 2025 x64 Desktop Experience**. The native Windows phone client is separate and unreleased.

Windows [normal40435466441](https://github.com/embire2/openwebpbx/actions/runs/40435466441) passes all 17 essential software gates and package/source/private-data audits for source `cab93`. Matching [replacement restore40446022002](https://github.com/embire2/openwebpbx/actions/runs/40446022002) passes source 9/target 20, and [restored conferences40452374400](https://github.com/embire2/openwebpbx/actions/runs/40452374400) passes source 9/target 21 with decoded audio/video and 16 WebSocket roundtrips; canonical cleanup passes.

The authorized Windows Server 2025 owner test passes the ordinary signed 1.0.20→21 upgrade, installed Greetings recording/replay/save, an actual Windows reboot, four running services and two opposite original-credential TLS calls with decoded two-way audio.

Debian 13 source `89ae` passes its complete fresh-installation, calling/media, clock, Greetings, STUN and encrypted-backup matrix; a genuine 1.0.16 installation with verified signed revision 2 passes rollback and automatic 1.0.21 updater finalization. A separate current-backup restore preserves target database identities/roles, all customer rows and 374 protected files, with only the existing previous-server backup-job status handling. Restored browser audio/VP8 video, mute/unmute/end and all 16 original WebSocket roundtrips pass.

Android remains 1.0.19; Windows Free Phone is unreleased. Broader physical phone/camera/carrier, public ACME delivery and Store approval remain separate. The roadmap stays 133 goals / 21 accepted / 72 partial / 40 planned. Earlier records retain their date/package scope.

## Current exact-package checks

| Check | Current record |
|---|---|
| Fresh/full server, software calling and media, services, backup/update/recovery and cleanup | [40435466441](https://github.com/embire2/openwebpbx/actions/runs/40435466441), all 17 essential gates passed |
| Original published20 automatic upgrade, installed Greetings, actual Windows reboot, four services and opposite TLS calls | Owner test passed with original credentials and scoped data/pin/cleanup checks |
| Independent clean replacement restore | passed: [40446022002](https://github.com/embire2/openwebpbx/actions/runs/40446022002), source9/target20 with canonical cleanup |
| Signed genuinely newer22 upgrade/late rollback/natural restart/manager/preservation | [run40501021425](https://github.com/embire2/openwebpbx/actions/runs/40501021425) passed all9 signed-upgrade gates and117 original Scheduler/file-sharing controls at QA source `8834f96bfc576dbcb5c864e718ac9bb31024dab2`; canonical cleanup and exact-owned temporary-secret removal passed; all nine signed-upgrade gates and117 scheduling/file-sharing controls apply to the unchanged CAB product |
| Restored browser conferences/audio/video | passed: [40452374400](https://github.com/embire2/openwebpbx/actions/runs/40452374400), source9/target21, decoded audio/video and16 WSS roundtrips |
| Exact archive/source/native/audio/private-data audits | Currentcab93 package/source audits passed; matching functional records are listed above |

The server includes a local PostgreSQL database, FreeSWITCH, IIS/PHP browser administration, native setup/status/update manager, tenants, routes, queues, callbacks, voicemail, company-group hours, Greetings, Add DID, Phone Health, STUN, encrypted backups and browser meetings. Built-in Keoma prompts are included; typed narration uses a configured provider account and its charges. Windows uses dedicated Greetings storage and preserves working custom/legacy media. The browser is the primary administration interface; a complete native WinUI administration rewrite is unfinished.

## Historical signed-run record

**Historical signed-newer attempt:** [40471666785](https://github.com/embire2/openwebpbx/actions/runs/40471666785) failed. This earlier result does not qualify later exact-package repeats.

## Limits

- Controlled software phones/HTTPS and an owner upgrade/reboot do not establish every physical phone, camera, carrier, NAT or public ACME issuance/renewal.
- Existing meeting-invitation continuity and legacy Windows1.0.6 migration remain unqualified. The ordinary public upgrade minimum is1.0.20.
- Windows 10/11 server installation and Debian-to-Windows instance-backup migration are unsupported. The 3CX V20 configuration importer is a separate path requiring its report and actual cutover checks.
- Android remains1.0.19. Windows Free Phone and Microsoft Store/Google Play approvals remain separate; no full3CX parity is claimed.

[Install Windows](installing-windows-1.0.21.md) · [Backup/restore](windows-backups.md) · [Updates](windows-server-updates.md) · [Historical qualification](release-1.0.21-qualification.md) · [Roadmap](../3CX.md)
