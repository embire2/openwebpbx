# Independent platform releases

Linux development can advance while Windows finishes its own qualification.
Debian, Windows and Android have separate release versions, migration minima,
signed feeds and acceptance evidence. A passing Linux build does not promote
Windows or require a phone-app release.

| Component | Independent example | Compatibility to review |
| --- | --- | --- |
| Debian server | 1.0.23 | Its own signed `minimum_version` and qualified upgrade/restore path. |
| Windows server | 1.0.22 | Its own signed `minimum_version`, native package and Windows qualification. |
| Android app | 1.0.19 | `minimum_server_version`, API capabilities, `min_sdk`, version code and APK identity. |

These example versions can coexist; this is not a publication announcement or a
claim that a future minimum has been qualified. Server and app versions need not
match. Review protocol/API and schema compatibility, not numerical equality.
Android's runtime checks its actual server compatibility; the offline envelope
verifier validates the minimum's syntax, not a connection to a running server.

## Source and release identity

Freeze each platform from its own tested commit. Use immutable platform tags
such as `debian-v1.0.23`, `windows-v1.0.22` and `android-v1.0.19`, with matching
artifacts, corresponding source and qualification notes. Current packagers and
native metadata still read that checkout's `VERSION` (Android uses its own
version input). Use the retained qualified Windows checkout/package while Linux
advances; do not build newer Linux source and relabel or overlay it as Windows 1.0.22.

Existing clients require signed artifact URLs shaped as
`.../releases/download/v<platform-version>/<platform-artifact-name>`. A prefixed
release therefore also needs its exact signed artifact at that canonical
`v<version>` location. Add the same bytes only: never move an existing tag,
overwrite an asset, replace its checksums or rewrite another platform's release.
Platform-specific artifact/source filenames avoid collisions when versions
happen to coincide. Keep the prefixed tag tied to the platform's qualified source
even if a pre-existing canonical tag names an earlier release commit.

GitHub has one release selected as **latest**. Every release selected latest must
carry all three fixed signed envelopes:

| Client | File under `releases/latest/download/` |
| --- | --- |
| Android | `update-manifest.json` |
| Debian | `debian-update-manifest.json` |
| Windows | `windows-update-manifest.json` |

The latest release tag or date is not a shared component version. Copy the two
unpromoted envelopes byte-for-byte from the reviewed published snapshot. Do not
re-sign them, update their timestamps/sequences or replace their minima to match
the promoted platform. All envelopes must still pass signature and expiry
checks. An expired retained feed requires its own reviewed publication decision;
the single-platform guard does not silently refresh it.

## Promote one platform

1. Keep a reviewed `before/` snapshot of all three published feed bytes and
   qualify the new platform package from its frozen source. Keep the other
   platform artifacts and release evidence unchanged.
2. Sign only the new platform envelope with the existing signer and external
   release key. Its version and sequence must advance against its own prior
   envelope; Android's version code must advance too. Choose migration and API
   minima from that platform's qualification. Do not copy another platform's
   minimum or infer a supported path from its version.
3. Assemble `after/` with that new envelope and exact copies of the other two.
   Run the offline check from the repository root:

   ```sh
   python3 packaging/updates/platform-release.py \
     --platform debian13-amd64 --before before --after after
   ```

   Use `windows-x64` or `android-universal` for the corresponding promotion. The
   check verifies signatures, expiry, designated platforms, own-feed advancement
   and unchanged retained bytes; it does not sign, upload or qualify packages.
   Review its reported minima explicitly. Keep the resulting feed hashes with
   the publication evidence and confirm those exact bytes after upload.
4. Satisfy the platform's existing release gates, add only authorized immutable
   assets/canonical mirrors, and put all three checked envelopes on the release
   selected latest. Verify the public assets and ordinary client update check.

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
and Android signed envelopes exactly. No supported platform needs to wait for a
shared version number, forced rebuild or tag move.
