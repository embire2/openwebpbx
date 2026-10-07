# Building OpenWeb PBX 1.0.2

The web application and call engine retain their upstream licenses. The C# projects in `platform/` add a .NET 10 background calling service and an unpackaged WinUI 3 administration manager. This release does not rewrite the PHP application in C# and the manager is not a softphone.

## Service

Use .NET SDK 10.0.401 or a compatible .NET 10 SDK:

```sh
dotnet publish platform/OpenWebPbx.Server -c Release -r linux-x64 --self-contained true -o artifacts/linux/server
dotnet publish platform/OpenWebPbx.Server -c Release -r win-x64 --self-contained true -o artifacts/windows/server
dotnet run --project platform/OpenWebPbx.Checks -c Release
```

The database integration checks additionally require `OPENWEB_TEST_DATABASE` pointing to a development PostgreSQL database containing the application schema. They create and remove their own schema. Never put connection strings in tracked files.

## Windows manager

Open `platform/OpenWebPbx.slnx` in Visual Studio 2026 with the WinUI desktop workload and Windows SDK installed. Alternatively, from a Windows developer terminal:

```powershell
dotnet build platform/OpenWebPbx.Desktop -c Release -p:Platform=x64 -p:RuntimeIdentifier=win-x64
```

The complete `win-x64` output directory is required; the executable alone is insufficient. The tested package uses Windows App SDK 2.5.1. The server installer and manager are separate so a remote administrator can run only the manager and save an HTTPS PBX address.

## Release contents

Both installer archives include a clean `web/` source tree, `server/` self-contained binaries, `bootstrap.php`, installation scripts and license notices. The Windows archive also includes `desktop/`. Include only tracked application source and explicitly reviewed new files. Exclude `.git`, `.env`, browser profiles, test accounts, customer ZIPs, media, machine configuration, build logs and validation artifacts.

Windows downloads the official FreeSWITCH 1.11.3 MSI, PHP 8.4.26 NTS and PostgreSQL 18.6 binaries. Pinned SHA-256 values are checked before extraction or installation. These downloads require an internet connection.

Debian includes an `engine.tar.gz` compiled on Debian 13 amd64. It contains FreeSWITCH 1.11.3, its Sofia-SIP and SpanDSP shared libraries, stock English 8 kHz prompts and music. Debian libraries are installed with APT using `engine-dependencies.txt`. The corresponding upstream source snapshots, licenses and build configuration accompany the release as `openwebpbx-1.0.2-engine-source.tar.gz`.

Engine source revisions:

- FreeSWITCH: `ef32e205295e29f034f1453ad245ba5efb07b94a` (`v1.11.3`)
- Sofia-SIP: `ad36ac8f755308e8b87f98a505e83d4e408e5cc3`
- SpanDSP: `8f1e1646bdec99eac5fd2cd92c35563f736b9b89`

After committing the reviewed source, create installation archives with:

```sh
python3 packaging/build-release.py --target debian --server artifacts/linux/server --engine /path/to/clean-engine.tar.gz
python3 packaging/build-release.py --target windows --server artifacts/windows/server --desktop /path/to/windows-built-manager
```

The packager uses the Git index for application source, includes documentation and license notices, and refuses private/archive-shaped application files. Supply clean build output directories, never installed server directories. It does not compile the engine or Windows manager itself. The engine build recipe is provided for rebuilding; the published engine was validated through the fresh installer, not by rerunning that recipe in this release workflow.

The stock engine and source dependencies are separate from private PBX configuration. Never build a release archive from `/etc/freeswitch` or the live media directories.
