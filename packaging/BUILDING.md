# Building OpenWeb PBX 1.0.5

The web application and call engine retain their upstream licenses. The C# projects in `platform/` add a .NET 10 background calling service and an unpackaged WinUI 3 administration manager. This release does not rewrite the PHP application in C# and the manager is not a softphone.

## Service

Use .NET SDK 10.0.401 or a compatible .NET 10 SDK:

```sh
dotnet publish platform/OpenWebPbx.Server -c Release -r linux-x64 --self-contained true -o artifacts/linux-1.0.5/server
dotnet publish platform/OpenWebPbx.Server -c Release -r win-x64 --self-contained true -o artifacts/windows-1.0.5/server
dotnet publish platform/OpenWebPbx.Updater -c Release -r linux-x64 --self-contained true -o artifacts/linux-1.0.5/updater
dotnet publish platform/OpenWebPbx.Updater -c Release -r win-x64 --self-contained true -o artifacts/windows-1.0.5/updater
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

The complete `win-x64` output directory is required; the executable alone is insufficient. The tested package uses Windows App SDK 2.5.1. The server installer and manager are separate so a remote administrator can run only the manager and save an HTTPS PBX address.

## Release contents

Both installer archives include a clean `web/` source tree, `server/` and `updater/` self-contained binaries, `bootstrap.php`, installation scripts and license notices. The Windows archive also includes `desktop/`. Include only tracked application source and explicitly reviewed new files. Exclude `.git`, `.env`, browser profiles, test accounts, customer ZIPs, media, machine configuration, build logs and validation artifacts.

Windows downloads the official FreeSWITCH 1.11.3 MSI, PHP 8.4.26 NTS and PostgreSQL 18.6 binaries. Pinned SHA-256 values are checked before extraction or installation. These downloads require an internet connection.

Debian includes an `engine.tar.gz` compiled on Debian 13 amd64. It contains FreeSWITCH 1.11.3, its Sofia-SIP and SpanDSP shared libraries, stock English 8 kHz prompts and music. Debian libraries are installed with APT using `engine-dependencies.txt`. The corresponding upstream source snapshots, licenses and build configuration accompany the release as `openwebpbx-1.0.5-engine-source.tar.gz`.

Engine source revisions:

- FreeSWITCH: `ef32e205295e29f034f1453ad245ba5efb07b94a` (`v1.11.3`)
- Sofia-SIP: `ad36ac8f755308e8b87f98a505e83d4e408e5cc3`
- SpanDSP: `8f1e1646bdec99eac5fd2cd92c35563f736b9b89`

After committing the reviewed source, create installation archives with:

```sh
python3 packaging/build-release.py --target debian --server artifacts/linux-1.0.5/server --updater artifacts/linux-1.0.5/updater --engine /path/to/clean-engine.tar.gz
python3 packaging/build-release.py --target windows --server artifacts/windows-1.0.5/server --updater artifacts/windows-1.0.5/updater --desktop /path/to/windows-built-manager
```

The packager writes `release-manifest.json` with the version and SHA-256 for every packaged file. Both fresh and update scripts are included; update scripts preserve installed configuration. The packager excludes Android source from the PHP web root and distributes only the local G.729 build recipe, not a combined codec binary.

The packager uses the Git index for application source, includes documentation and license notices, and refuses private/archive-shaped application files. Supply clean build output directories, never installed server directories. It does not compile the engine or Windows manager itself. The engine build recipe is provided for rebuilding; the published engine was validated through the fresh installer, not by rerunning that recipe in this release workflow.

The stock engine and source dependencies are separate from private PBX configuration. Never build a release archive from `/etc/freeswitch` or the live media directories.

## Android app and final release

The native Android project is built separately; follow `mobile/android/README.md`. The release APK is signed with a persistent private release key kept outside the checkout. Never publish the keystore or its password. Copy the verified output to `artifacts/android/openwebpbx-1.0.5-android.apk` and verify the APK signature before release.

Stage and review new application files before packaging, because the packager reads the Git index. Build the Linux service, Windows service/manager and Android APK from the same reviewed release source. Generate `SHA256SUMS` over the Debian, Windows, Android and engine-source assets. Inspect every archive for private files, configuration and known secrets, and compare its manifest hashes before upload. Preserve the old 1.0.2 assets unchanged.

Update the public homepage's release catalogue only after the GitHub release and downloadable assets exist and their downloaded SHA-256 values match. Record actual platform test results in the roadmap, coverage guide, operating guides and release notes; do not infer device compatibility from successful compilation.

## Signed update feed

The separate updater only installs archives named in a valid signed feed. Keep the RSA release-signing private key outside the checkout with mode `600`. The public pin is `packaging/updates/release-public.pem`; the private key is never copied into a release or website. See [the protocol](updates/PROTOCOL.md).

After the final archives and Android APK are verified, sign their actual hashes and sizes:

```sh
python3 packaging/updates/sign-feed.py --private-key /private/release-signing.pem \
  --version 1.0.5 --sequence 105 \
  --debian artifacts/release-1.0.5/openwebpbx-1.0.5-debian13-amd64.tar.gz \
  --windows artifacts/release-1.0.5/openwebpbx-1.0.5-windows-x64.zip \
  --android artifacts/android/openwebpbx-1.0.5-android.apk --android-version-code 105 \
  --minimum-server-version 1.0.5 \
  --android-certificate-sha256 449740f6858cb092a0f67d9d79d2505a8d6e7e4d4c1a52a8eaed9b895e48e69d \
  --output artifacts/release-1.0.5/update-manifest.json
```

Publish `update-manifest.json` alongside the exact referenced assets, include its hash in `SHA256SUMS`, and verify the public downloads before marking the release latest. Never reuse a sequence with changed payload bytes; issued feeds are immutable. Keep a dated private copy of each signed envelope. A refreshed expiry needs a greater sequence even when archive bytes do not change. Clients refuse expired metadata, a lower sequence, a conflicting payload at an already observed sequence, and downgrades. Offline clients retain their current installation.
