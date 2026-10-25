# Fixture WAV producer contract

This manual-only hosted contract builds a distinct fixture recorder against the real public Windows Liblinphone SDK5.5.23 headers/import libraries. It checks public factory selection, real asynchronous WAV production, empty/append/format guards, exact payload bytes and the existing41 first-data/original-parser controls. Inputs are invented PCM vectors; success is not decoded calling, hardware, Store or originalSDK-writer acceptance.

`producer.patch` is against `original/msfilerec.c`; other copied upstream producer sources retain their notices and full AGPL licence. Public API source pins refer to superproject348e8de32fb2ac56b7b0a7167968fc1ac707f7b2. OfficialSDK binaries remain unchanged. No private ABI hooks, format repair or manufactured call samples are used. Source correspondence does not establish exact officialSDK internal-binary equivalence.

The standalone readiness helper is tested against a byte-identical copy of the current strict AudioProof.cs. `readiness/capture-first-data.patch` documents a later proposed integration only: it is not applied to this source tree and cannot qualify actual media. Existing12-second/100ms capture budget,3.3-second fresh tail and complete strict parser remain required in any later separate media run.

Run only through the separately reviewed `windows-phone-wav-producer.yml` workflow with an exact40-character source commit. Its new protected runner-temporary roots, pinned officialSDK acquisition and strict complete system baseline are independent of ordinary app/media/package modes. It never installs a PBX, modifies services, restores unknown service differences, accesses signing identities or publishes releases. Actual MSVC/import/registry/output/cleanup results remain pending.
