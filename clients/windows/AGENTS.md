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
