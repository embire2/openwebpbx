# Windows Server 1.0.22

<!-- WINDOWS22-RELEASE-STATUS-BEGIN -->
**Windows Server 1.0.22 — published 2026-11-04T01:59:14Z.** The unchanged product `8f4256e4e3cbce092791eea60d1c053e10810bb6` passes the complete software suite, actual restore/reboot, distinct fresh managed installation and signed updater cases [41752080297](https://github.com/embire2/openwebpbx/actions/runs/41752080297) (original worker enabled) and [41722715796](https://github.com/embire2/openwebpbx/actions/runs/41722715796) (original worker disabled). Public release assets/canonical mirror, retained Android/Debian envelopes and the ordinary installed Windows public-feed Check are verified. Qualification limits remain in force.
<!-- WINDOWS22-RELEASE-STATUS-END -->

A complete PBX package for **Windows Server 2025 x64 with Desktop Experience**, with its local database, calling engine, web administration, native manager and updater.

- **Guided managed setup:** use the same public registration wizard as Debian, with owner verification, a chosen tenant address, managed DNS and trusted HTTPS. The PBX and database stay on your server.
- **Reusable phone QR setup:** Windows 1.0.22 includes the stable QR behavior already available on the hosted service. Views, emails, exports, scans and password changes retain the code; an explicit reset invalidates earlier codes/files while keeping connected devices. The older Debian 1.0.22 archive retains its original invitation behavior.
- **Recovery compatibility:** restore automatically applies the current mobile schema to older accepted Windows backups, preserving existing credentials, registration identity and recordings. Actual old-archive restore, ordinary Users/QR pages, original-credential UDP/TLS calling, reboot and encrypted backup components pass.
- **Windows reliability corrections:** installation and upgrade include the native onboarding gate, registration/backup workers tolerate bounded genuine lock contention, calling exports the supported RTP timestamp policy, and Phone Health reads actual listener binds while retaining ownership/firewall checks.

[Full software run41627350841](https://github.com/embire2/openwebpbx/actions/runs/41627350841) passes. A distinct stock managed installation also passes ordinary public registration, eight software calling cases with full-stream packet validation, 34 QR checks and its first natural scheduled backup inside the declared limits. The signed-update cases and public delivery are accepted as recorded above. See the [qualification record](https://github.com/embire2/openwebpbx/blob/customization/docs/release-windows-1.0.22-qualification.md) for scope and retained failures.

**Install:** download `openwebpbx-1.0.22-windows-x64.zip`, verify its `SHA256SUMS` entry, extract the complete archive and open **Start-OpenWebPBX.cmd**. Follow the matching `installing-windows-1.0.22.md` release asset. The qualified signed update path requires **Windows 1.0.21 or newer**; fresh setup protects an existing installation.

The ZIP is **643,251,073 bytes**, SHA-256 `66c93cdcfdf1a69ccbc478d68a335290da7174283921f25318dd94f0cf340c0b`. Matching source is `openwebpbx-1.0.22-windows-source.tar.gz`, from product commit `8f4256e4e3cbce092791eea60d1c053e10810bb6`. Existing licences/notices and engine corresponding-source references are retained.

Debian remains **1.0.22** and Android **1.0.19** with their existing artifacts/feeds. Linux can advance while Windows completes its own qualification, then Windows can catch up independently: [release cadence and compatibility](https://github.com/embire2/openwebpbx/blob/customization/docs/independent-platform-releases.md). The Windows phone client is separate. Physical phones, carriers, camera scanning, mobile SRTP, restrictive networks and Store acceptance require their own evidence.
