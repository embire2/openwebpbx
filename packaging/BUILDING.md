# Building OpenWeb PBX

## Windows Server 1.0.20 candidate

The current checkout prepares native Windows Server 1.0.20. Qualification is in progress; the published Windows release remains 1.0.7. Public full Debian remains 1.0.16, with the separate 1.0.19 administration patch, and Android remains 1.0.18. Use each immutable release revision for its matching build. See the [current Windows acceptance record](../docs/windows-parity-1.0.20.md).

The manual `windows-native.yml` workflow uses .NET SDK 10.0.401 and Visual Studio 2026 on Windows Server 2025. It publishes the complete service, updater and WinUI output, immutable source hashes, assembly versions and an actual responsive top-level-window check. Select a successful build whose complete input inventory matches the candidate; a successful compile does not qualify installation or calling.

The `windows-engine.yml` workflow builds the registrar from pinned FreeSWITCH/Sofia source, including the original-identity and fragmented-WebSocket corrections. It reads the pinned MSI without executing its installer, derives DATA-aware imports, and checks the portable local codec's real callbacks and 1,000 APR memory-ownership cycles. Retain the complete source manifests, including legitimate hidden files. Combined codec DLLs are excluded from uploads and release packages.

Prepare the isolated Python backup runtime with `packaging/windows/build-backup-runtime.py`, the verified simple-acme bundle with `build-acme-runtime.py`, and the four-rate music bundle with `build-hold-music.py`. Retain their exact manifests, upstream sources and licences. Then package matching reviewed inputs:

```sh
python3 packaging/build-release.py --target windows \
  --server /private/native/server --updater /private/native/updater \
  --desktop /private/native/desktop --engine /private/engine/engine \
  --codec-source /private/engine/codec-source/source \
  --backup-runtime /private/backup-runtime --acme /private/acme \
  --music /private/music --voices /private/voices/1.0.1 \
  --output artifacts/release-1.0.20
```

Only tracked source and exact verified runtime inventories are copied. At installation, the local codec recipe downloads its pinned compiler, builds and proves the converter privately, and installs it while the engine is stopped. The installer never distributes a combined converter binary. Native ZIP integrity does not qualify SIP/media, global mail, phone health, STUN, real service permissions, encrypted clean-server restore or rollback; the disposable `windows-suite.yml` workflow exercises those separately. Its final package must include all reviewed runtime corrections; a previous archive does not qualify later changes.

After complete qualification, sign the exact Windows archive with `packaging/updates/sign-feed.py --windows-only --windows <archive> --version 1.0.20 --sequence <unused-sequence> --private-key <private-key> --output <windows-update-manifest.json>`. The private signing key stays outside the repository and hosted runners. Use a sequence above every preserved platform feed. Keep both published `update-manifest.json` (Android) and `debian-update-manifest.json` byte-for-byte in the new release. Validate all three before publication:

```sh
python3 packaging/updates/validate-platform-feeds.py \
  --generic /private/publication/update-manifest.json \
  --generic-reference /private/published/android-envelope.json \
  --generic-version 1.0.18 \
  --debian /private/publication/debian-update-manifest.json \
  --debian-reference /private/published/debian-envelope.json \
  --debian-version 1.0.16 \
  --windows /private/publication/windows-update-manifest.json \
  --windows-package /private/publication/openwebpbx-1.0.20-windows-x64.zip \
  --windows-version 1.0.20
```

Preserve the original envelopes and download provenance privately; do not recreate or re-sign them. Complete public downloads must match before updating the homepage catalogue. See [candidate installation](../docs/installing-1.0.20.md), [Windows upgrades](../docs/windows-upgrade.md) and [the update protocol](updates/PROTOCOL.md). The historical 1.0.13 candidate's results remain in their own record.

## Historical 1.0.12 source build

The commands below apply to the immutable 1.0.12 source revision. Its official server package targets Debian 13; no Windows 1.0.12 server package was published.

The web application and call engine retain their upstream licenses. The C# projects in `platform/` add a .NET 10 background calling service and an unpackaged WinUI 3 administration manager. This release does not rewrite the PHP application in C# and the manager is not a softphone.

## Service

Use .NET SDK 10.0.401 or a compatible .NET 10 SDK:

```sh
dotnet publish platform/OpenWebPbx.Server -c Release -r linux-x64 --self-contained true -o artifacts/linux-1.0.12/server
dotnet publish platform/OpenWebPbx.Server -c Release -r win-x64 --self-contained true -o artifacts/windows-1.0.12/server
dotnet publish platform/OpenWebPbx.Updater -c Release -r linux-x64 --self-contained true -o artifacts/linux-1.0.12/updater
dotnet publish platform/OpenWebPbx.Updater -c Release -r win-x64 --self-contained true -o artifacts/windows-1.0.12/updater
dotnet run --project platform/OpenWebPbx.Checks -c Release
dotnet run --project platform/OpenWebPbx.Updater.Checks -c Release
python3 tests/release_feed.py
python3 tests/debian_upgrade.py
```

The database integration checks additionally require `OPENWEB_TEST_DATABASE` pointing to a development PostgreSQL database containing the application schema. They create and remove their own schema. Never put connection strings in tracked files.

## Windows manager

Open `platform/OpenWebPbx.slnx` in Visual Studio 2026 with the WinUI desktop workload and Windows SDK installed. Alternatively, from a Windows developer terminal:

```powershell
dotnet build platform/OpenWebPbx.Desktop -c Release -p:Platform=x64 -p:RuntimeIdentifier=win-x64
```

The current qualified server release targets Debian 13. The Windows commands are retained for rebuilding the historical Windows edition; they do not establish Windows 1.0.12 installation or calling qualification.

The complete `win-x64` output directory is required; the executable alone is insufficient. The tested package uses Windows App SDK 2.5.1. The server installer and manager are separate so a remote administrator can run only the manager and save an HTTPS PBX address.

## Release contents

Both installer archives include a clean `web/` source tree, `server/` and `updater/` self-contained binaries, `bootstrap.php`, installation scripts and license notices. The Windows archive also includes `desktop/`. Include only tracked application source and explicitly reviewed new files. Exclude `.git`, `.env`, browser profiles, test accounts, customer ZIPs, media, machine configuration, build logs and validation artifacts.

Windows downloads the official FreeSWITCH 1.11.3 MSI, PHP 8.4.27 NTS and PostgreSQL 18.6 binaries. Pinned SHA-256 values are checked before extraction or installation. These downloads require an internet connection.

Debian includes an `engine.tar.gz` compiled on Debian 13 amd64. It contains FreeSWITCH 1.11.3, its Sofia-SIP and SpanDSP shared libraries, stock English 8 kHz prompts and music. Debian libraries are installed with APT using `engine-dependencies.txt`. The corresponding upstream source snapshots, licenses and build configuration accompany the release as `openwebpbx-1.0.12-engine-source.tar.gz`. This source archive retains the pinned engine snapshots and the reviewed registrar patch and includes the tracked `platform/` and `packaging/` source, `VERSION`, and original license. Its SHA-256 manifest identifies every source file; it contains no installed PBX configuration. The binary `engine.tar.gz` is a separate build input and must not be substituted for this source archive.

The Debian registrar module also includes [the original-identity registration patch](freeswitch/README.md). The build recipe checks the original file and patch SHA-256 before applying it, then checks the resulting source. Other engine members remain unchanged.

Engine source revisions:

- FreeSWITCH: `ef32e205295e29f034f1453ad245ba5efb07b94a` (`v1.11.3`)
- Sofia-SIP: `ad36ac8f755308e8b87f98a505e83d4e408e5cc3`
- SpanDSP: `8f1e1646bdec99eac5fd2cd92c35563f736b9b89`

After committing the reviewed source, create installation archives with:

```sh
python3 packaging/build-release.py --target debian --server artifacts/linux-1.0.12/server --updater artifacts/linux-1.0.12/updater --engine /path/to/clean-engine.tar.gz --output artifacts/release-1.0.12
python3 packaging/build-release.py --target windows --server artifacts/windows-1.0.12/server --updater artifacts/windows-1.0.12/updater --desktop artifacts/windows-1.0.12/desktop --output artifacts/release-1.0.12
```

The packager writes `release-manifest.json` with the version and SHA-256 for every packaged file. Both fresh and update scripts are included; update scripts preserve installed configuration. The packager excludes Android source from the PHP web root and distributes only the local G.729 build recipe, not a combined codec binary.

The packager uses the Git index for application source, includes documentation and license notices, and refuses private/archive-shaped application files. Supply clean build output directories, never installed server directories. It does not compile the engine or Windows manager itself. The engine build recipe is provided for rebuilding; the published engine was validated through the fresh installer, not by rerunning that recipe in this release workflow.

The stock engine and source dependencies are separate from private PBX configuration. Never build a release archive from `/etc/freeswitch` or the live media directories.

## Android app and final release

The native Android project is built separately; follow `mobile/android/README.md`. The release APK is signed with a persistent private release key kept outside the checkout. Never publish the keystore or its password. Copy the verified output to `artifacts/android/openwebpbx-1.0.12-android.apk` and verify the APK signature before release.

Stage and review new application files before packaging, because the packager reads the Git index. Build the Linux service/updater and Android APK from the same reviewed release source. Rebuild the Windows service/manager separately if qualifying a new Windows release. Generate `SHA256SUMS` over the actual release assets. Inspect every archive for private files, configuration and known secrets, and compare its manifest hashes before upload. Preserve the old 1.0.2 assets unchanged.

Update the public homepage's release catalogue only after the GitHub release and downloadable assets exist and their downloaded SHA-256 values match. Record actual platform test results in the roadmap, coverage guide, operating guides and release notes; do not infer device compatibility from successful compilation.

## Signed update feed

The separate updater only installs archives named in a valid signed feed. Keep the RSA release-signing private key outside the checkout with mode `600`. The public pin is `packaging/updates/release-public.pem`; the private key is never copied into a release or website. See [the protocol](updates/PROTOCOL.md).

After the final archives and Android APK are verified, sign their actual hashes and sizes:

```sh
python3 packaging/updates/sign-feed.py --private-key /private/release-signing.pem \
  --version 1.0.12 --sequence 111 \
  --debian artifacts/release-1.0.12/openwebpbx-1.0.12-debian13-amd64.tar.gz \
  --android artifacts/android/openwebpbx-1.0.12-android.apk --android-version-code 111 \
  --minimum-server-version 1.0.10 \
  --android-certificate-sha256 449740f6858cb092a0f67d9d79d2505a8d6e7e4d4c1a52a8eaed9b895e48e69d \
  --output artifacts/release-1.0.12/update-manifest.json
```

Publish `update-manifest.json` alongside the exact referenced assets, include its hash in `SHA256SUMS`, and verify the public downloads before marking the release latest. Never reuse a sequence with changed payload bytes; issued feeds are immutable. Keep a dated private copy of each signed envelope. A refreshed expiry needs a greater sequence even when archive bytes do not change. Clients refuse expired metadata, a lower sequence, a conflicting payload at an already observed sequence, and downgrades. Offline clients retain their current installation.
