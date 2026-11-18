# Independent platform releases

Linux development can advance while Windows finishes its own qualification.
Debian, Windows and Android have separate release versions, migration minima,
signed feeds and acceptance evidence. A passing Linux build does not promote
Windows or require a phone-app release.

| Component | Independent example | Compatibility to review |
| --- | --- | --- |
| Debian server | 1.0.26 | Its own signed `minimum_version` and qualified upgrade/restore path. |
| Windows server | 1.0.23 | Its own signed `minimum_version`, native package and Windows qualification; the updater repair is a separate component. |
| Android app | 1.0.19 | `minimum_server_version`, API capabilities, `min_sdk`, version code and APK identity. |

These example versions can coexist; this is not a publication announcement or a
claim that a future minimum has been qualified. Server and app versions need not
match. Review protocol/API and schema compatibility, not numerical equality.
Android's runtime checks its actual server compatibility; the offline envelope
verifier validates the minimum's syntax, not a connection to a running server.

## Every server release is a complete installer

A new Debian or Windows server release must install its complete current suite
on a clean supported operating system. It must not require an older OpenWeb PBX
installation or a separate PBX repair/update package to finish first setup.
Include the application, calling engine, web administration/API, local database
setup, tenant registration, system prompts, background workers and current
updater together. The full archive must carry sealed installation metadata
stating `package_type: full` and `previous_installation_required: false`.

Keep fresh installation and updating existing data separate in product copy and
release metadata. The main download card and new-server guide state the clean
OS requirements. An existing-data updater may enforce its independently
qualified compatibility minimum, signed history and recovery rules. That minimum
is not a prerequisite for a new installation and must never be lowered just to
change the wording. A full installer must refuse accidental overwrite of an
existing PBX.

Qualify the actual full archive on a clean machine with no previous PBX state,
through the ordinary tenant setup wizard. Confirm every included service starts
and the recorded administration/calling checks pass. Qualify updates and
preservation separately, explicitly naming any reused unchanged component
proof. A partial overlay or patch is not a substitute for this fresh-install
acceptance.

Calling changes must also satisfy the [calling release safeguards](calling-release-safeguards.md):
the automatic regression check, loading in the real configured call engine and
controlled call/media checks against the exact package. Service health or phone
registration alone cannot qualify a calling change.

The retained original Windows 1.0.23 installers and earlier installed clients
have their separately documented one-time ordered-updater repair. The next
complete Windows release must include the current ordered updater itself;
new users must not need that legacy repair. Existing immutable releases and
historical evidence remain unchanged.

## Source and release identity

Freeze each platform from its own tested commit. Use immutable platform tags
such as `debian-v1.0.26`, `windows-v1.0.23` and `android-v1.0.19`, with matching
artifacts, corresponding source and qualification notes. Current packagers and
native metadata still read that checkout's `VERSION` (Android uses its own
version input). Use the retained qualified Windows checkout/package while Linux
advances; do not build newer Linux source and relabel or overlay it as Windows 1.0.23.

Existing clients require signed artifact URLs shaped as
`.../releases/download/v<platform-version>/<platform-artifact-name>`. A prefixed
release therefore also needs its exact signed artifact at that canonical
`v<version>` location. Add the same bytes only: never move an existing tag,
overwrite an asset, replace its checksums or rewrite another platform's release.
Platform-specific artifact/source filenames avoid collisions when versions
happen to coincide. Keep the prefixed tag tied to the platform's qualified source
even if a pre-existing canonical tag names an earlier release commit.

GitHub has one release selected as **latest**. Every release selected latest must
carry all three fixed signed envelopes **and the existing signed Windows
ordered-upgrade catalogue**:

| Client | File under `releases/latest/download/` |
| --- | --- |
| Android | `update-manifest.json` |
| Debian | `debian-update-manifest.json` |
| Windows | `windows-update-manifest.json` |
| Windows ordered-upgrade authority | `windows-upgrade-path.json` |

The latest release tag or date is not a shared component version. Copy the two
unpromoted envelopes byte-for-byte from the reviewed published snapshot. Do not
re-sign them, update their timestamps/sequences or replace their minima to match
the promoted platform. All envelopes must still pass signature and expiry
checks. An expired retained feed requires its own reviewed publication decision;
the single-platform guard does not silently refresh it.

The Windows catalogue is a separate signed authority, not a fourth ordinary
release feed. A Debian-only or Android-only promotion must retain its exact
published bytes alongside the unpromoted Windows envelope. Do not omit the
catalogue, refresh its dates or re-sign it to match a Linux or phone-app version.
Workers with catalogue history refuse an unavailable or conflicting authority;
moving GitHub's latest release without the catalogue can therefore strand them.

A Windows promotion supplies a freshly signed catalogue bound to its new exact
latest payload and sequence. It must advance its own catalogue history while
preserving the original supported floor and historical step prefix. Every step
retains its original signature, envelope hash and minimum. The [ordered-upgrade
guide](windows-upgrade-path-repair.md) describes legacy bootstrap and qualification
boundaries. For the Debian 1.0.26 promotion, Windows remains 1.0.23 plus its
qualified updater repair and Android remains 1.0.19; this document does not itself
announce or qualify the Debian package.

## Promote one platform

1. Keep a reviewed `before/` snapshot of all three published feed bytes and
   `windows-upgrade-path.json`, and qualify the new platform package from its
   frozen source. Keep the other platform artifacts and release evidence
   unchanged. Snapshotting only the three ordinary feeds is incomplete once
   Windows catalogue publication has begun.
2. Sign only the new platform envelope with the existing signer and external
   release key. Its version and sequence must advance against its own prior
   envelope; Android's version code must advance too. Choose migration and API
   minima from that platform's qualification. Do not copy another platform's
   minimum or infer a supported path from its version.
3. Assemble `after/` with that new envelope and exact copies of the other two.
   For Debian/Android, copy the Windows catalogue byte-for-byte too; for Windows,
   include its newly qualified catalogue. Run the offline check from the
   repository root:

   ```sh
   python3 packaging/updates/platform-release.py \
     --platform debian13-amd64 --before before --after after
   ```

   Use `windows-x64` or `android-universal` for the corresponding promotion. The
   check verifies signatures, expiry, designated platforms, own-feed advancement
   and unchanged retained bytes. Its CLI also enforces catalogue retention on
   Debian/Android promotions and advancing, latest-bound catalogue history on a
   Windows promotion; its existing three-feed Python API remains separate.
   The check does not sign, upload or qualify packages.
   Review its reported minima explicitly. Keep the resulting feed hashes with
   the publication evidence and confirm those exact bytes after upload.
4. Satisfy the platform's existing release gates, add only authorized immutable
   assets/canonical mirrors, and put all three checked envelopes **and the
   checked Windows catalogue** on the release selected latest. Verify their
   actual downloaded bytes, public assets and ordinary client update check.

This additional check does not replace `validate-platform-feeds.py` or waive its
accepted Windows package/manifest and sequence gates. That existing Windows
publication check currently also requires the Windows sequence above retained
feeds. A sufficiently higher Windows sequence does not require matching versions
or re-signing the other envelopes. No client trust state or fixed URL changes.
Legacy Debian workers using the generic Android URL still need the existing
qualified feed-selection compatibility patch; there is no fallback to a server
package from another platform.

## Windows catches up later

Continue Linux work on the development branch and publish its independently
qualified release. Keep Windows on its last accepted artifact/feed. When the
Windows port is ready, freeze its own source commit and version, adapt and test
the affected native paths and migrations, then run the existing Windows fresh,
upgrade, rollback, backup/restore, calling and signed-update gates. Reuse valid
unchanged component evidence; a newer shared source commit alone is not Windows
acceptance. Promote only Windows afterward, retaining the then-current Debian
and Android signed envelopes exactly and advancing only Windows' catalogue.
No supported platform needs to wait for a shared version number, forced rebuild
or tag move.

Track each Debian feature and fix in the [Windows catch-up ledger](debian-windows-sync.md),
including its source commit, hosted/public status and required Windows checks.
