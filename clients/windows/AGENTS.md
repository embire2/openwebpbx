# OpenWebPBX Free Phone for Windows

- Client version1.0.0 is independent of PBXServer20 and Android18. All client projects belong here, outside `platform/`; never alter the server's73-input native graph.
- Native C#/.NET10/WinUI3 UI and native Liblinphone signalling/audio/video only. No embedded browser calling UI. StoreMSIX and directWindowsServer distribution have separate update mechanisms and identities.
- Preserve strict HTTPS, SIPTLS and SRTP; never log tokens/passwords, put secrets in setup files, weaken certificate verification or reuse Android/server update floors. Use Windows per-user protected storage.
- Do not mutate the hosted PBX, customer phones/providers, owner test machine or public feeds. Any required server integration is branch-only with explicit root review before deployment.
- Record source-based Android parity and real test scope. A build, visible window, signalling, decoded audio, decoded video, physical hardware and Store certification are separate evidence.
- Keep large SDK/toolchain/cache/download/build outputs on GitHub-hosted Windows. Local/root and ownerC: capacity is reserved for PBX server qualification.

## Progress2026-10-23

- Isolated branch starts at08d80370133fc5de9367940fbe529ad87ee43978. Android18 source inventory and official Windows SDK/package guidance reviewed. No app or Store acceptance yet.
- Preferred native stack is official Liblinphone5.5.23 to match Android5.5.23. Official Windows64 ZIP is315,960,147bytes; bounded remote central-directory inspection reads388,253bytes, finds2664members and official C# binding. Full SDK downloads/builds remain on CI.
- Existing mobile API admits only `platform=android`; Windows admission and independent update policy require a reviewed branch patch. No server deployment is authorised by this file.
- Pure.NET10 domain/API/profile foundation now builds with warnings-as-errors.66 controlled tests cover tenant/setup restrictions, bounded secret-free invitations, password/idle rules, token-origin/redirect/error handling, profile identity/deduplication, ten-account concurrency, rename/removal and late-call refusal. HTTP/protected-storage/native-engine adapters remain explicit; no Windows UI, DPAPI, calling, hardware or Store pass follows.
- Hosted probe1 stops on unpinned preinstalled SDK10.0.402; probe2 pins401 correctly, retains exact WinGet0x80004005 partial failure and official-template0.0.7-alpha success, then rejects stale skill options. Probe3 uses verified official default packaged command and preserves template help/framework and independent SDK inventory. All original facts remain private under `windows-phone100/`; no large archive downloaded locally.

- Probe39955766746 confirms exact official SDK5.5.23 ZIP/binding hashes and actual default net10.0-windows10.0.26100.0 scaffold. Its Release build refuses NETSDK1102 because trimming requires self-contained publishing; the next probe explicitly selects self-contained and exports bounded source before build. The SDK's generic LICENSE.md is a bundled libjpeg notice, so complete exact licence-member evidence is now collected rather than claiming it as Liblinphone's licence. No native calling claim.
