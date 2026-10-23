# Windows Phone distribution and updates

Windows Phone **1.0.0** is a separate client product. It is not the Windows PBX server, Debian package or Android application. The two routes below are planned release contracts; no client release, update feed, signature or Store approval is established by this document.

| Route | Intended target | Installation identity | Updates |
|---|---|---|---|
| Microsoft Store MSIX | Supported Windows 11 x64 | Partner Center-issued name/publisher; currently unknown | Store-delivered MSIX updates |
| Direct self-contained desktop client | Windows Server 2025 **Desktop Experience**, and separately tested Windows 11 x64 | Publisher-signed client installer/distribution; final format and signer pending | Independent signed **Windows Phone** update channel; implementation/qualification pending |

This choice follows [Microsoft's distribution guidance](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/choose-distribution-path). It does not promise that Microsoft Store is available on Server, or that a desktop UI works on Server Core. Microsoft's current [Windows App SDK support matrix](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/support) does not explicitly list Server 2025; retain that gap and qualify the exact direct build on the intended Server 2025 Desktop Experience installation before claiming support.

## Shared release inputs

Record the exact client source commit, version/assembly/package versions, architecture, dependency lock and native SDK manifest. The current SDK candidate is official Liblinphone5.5.23 win64:315,960,147bytes, SHA256`9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297`. Do not replace this with an unpinned latest SDK or silently mix native DLL versions. Publish only the required tested DLL/plugin/dependency set, not the SDK's test tools, headers or import libraries by default. Source/licence closure is still pending; see [third-party notices](THIRD_PARTY_NOTICES.md).

Use the actual reviewed client build scripts and pinned .NET10/toolchain. This guide does not invent a production build command or working signing certificate. Keep CI caches and large SDK builds on the disposable build runner. Retain hashes, source manifests, package inspection, actual assembly-version evidence and test results for each flavor.

## Store flavor

Associate the package with the reserved product before the final build. Development `Name`/`Publisher` values are placeholders, not Store identity. Bundle the native calling libraries and required dependencies; validate the complete MSIX dependency graph and actual install/launch in a clean Windows 11 user session. The upstream SDK offers a separate `windows-store-sdk` source preset; the generic `win64` ZIP alone does not establish Store compatibility. Final native imports and certification-kit results must decide whether that SDK flavor is usable.

Store MSIX obtains Store-managed updates. Do not download and replace its installed program files, launch the direct updater, change Store package identity to force a version, or reuse any PBX-server/Android feed. Open the actual Store listing when user action is needed. Microsoft documents the different update responsibilities in [publish/update guidance](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/publish-first-app). Enterprise and user policies can disable automatic delivery; the client must not promise installation at an exact time or override Windows policy. See [MSIX group policy](https://learn.microsoft.com/en-us/windows/msix/group-policy-msix).

A tenant-required minimum may produce a clear, server-compatible upgrade notice and reject a *new* sign-in when necessary; it is not authority to kill an active call or bypass Store delivery. Preserve an ongoing call and explain recovery if the installed client becomes incompatible. Test the final behaviour rather than marking this policy as implemented.

## Direct flavor

Use a deliberate unpackaged/self-contained build and an installer or complete signed distribution appropriate to Server 2025 Desktop Experience. Include the native VC/runtime requirements actually required by the final payload. Test with no Visual Studio, developer SDK or preinstalled developer certificate. Trusted HTTPS downloads and Authenticode signing are distinct from the signed update manifest; both need their own verified provenance. Do not ask customers to disable SmartScreen, certificate validation or machine security.

The independent client updater must be implemented and qualified before automatic-update claims:

1. Identify the installed **direct client** and its version/architecture. Store packages must not enter this path.
2. Verify an independently named Windows Phone feed with its own trusted key ID, sequence/expiry, client product/channel, supported upgrade path, exact asset bytes/hash and rollback policy. No PBX server archive or Android APK may qualify.
3. Download the complete asset to protected staging and verify it before stopping anything. Interrupted, substituted, expired or wrong-product downloads must leave the running client usable.
4. Explain optional/required state visibly. Wait for calls/consultations and profile writes to finish; retain preferences/DPAPI data. Never claim a mandatory update can ignore the operating system or administrator's policy.
5. Close only the owned client instance; install transactionally, preserve a recoverable previous version and reopen the user's client with the correct flavor/profile scope. Prove fault recovery, retry and failed-install behaviour in isolation.

These are acceptance requirements, not evidence that an updater exists. Do not publish a feed URL, signing key, package checksum or download link until the corresponding immutable artifact has been accepted. A manual signed download can be the initial route if automatic upgrade is still unfinished, provided the listing says so accurately.

The reserved direct-client channel is `https://github.com/embire2/openwebpbx/releases/download/windows-phone-stable/windows-phone-update-manifest.json`. This is a planned fixed address, not a claim that the asset exists. Use independent immutable package tags such as `windows-phone-v1.0.0` and keep both those releases and the component's stable-feed release out of GitHub's generic Latest selection (`make_latest=false`). Never add this feed to the core release's `releases/latest` assets. Backend release availability is deliberately false until an accepted signed-client release catalogue is integrated; completing that activation and its preservation tests remains an explicit release TODO.

## Installation, privacy and migration checks

Both flavors require a valid tenant address, extension and admin-issued app password, or a bounded one-use invitation. Setup files contain enrolment information, not reusable SIP passwords. Store/normal-user DPAPI profile migration, separate package identities, uninstall, reinstall and changing Windows users must be tested before promising migration between routes. Do not copy another user's protected profile database.

Microphone/audio output are required for voice; video additionally needs a supported camera. Device permission denial must leave a clear usable state. Windows11minimum build22000 is a source-declared floor only; final measured memory/disk/CPU requirements remain pending. ARM64, x86, Windows10, Server Core, physical headsets/webcams, RDP media redirection, background incoming delivery and both distribution upgrade paths remain unqualified unless an exact client-specific receipt proves them.

Publish the exact binary, corresponding-source bundle, build instructions, licences/notices, SHA256SUMS, release notes and clear platform limits together. Keep Store and direct client release labels separate from PBXServer20 and mandatory Android18. Use [STORE_SUBMISSION.md](STORE_SUBMISSION.md) for the owner's final submission steps; no server rollout is authorised here.
