# Windows runtime inputs

The isolated backup runtime is built with
`packaging/windows/build-backup-runtime.py`. Its fixed inputs, upstream URLs,
SHA-256 hashes and deployed file inventory are in `runtime-manifest.json`.
The release source download includes the exact upstream archives and wheels.
The Python licence and each wheel's licence files remain in the installed runtime.

- CPython 3.13.16: Python Software Foundation License.
- cryptography 50.0.2: Apache-2.0 or BSD-3-Clause; bundled dependency notices
  remain in its wheel licence directory.
- cffi 2.1.1 and pycparser 3.11: MIT; upstream notices remain intact.
- The PHP CA bundle is Mozilla certificate data converted by curl, dated
  2026-09-25, under MPL-2.0. Its SHA-256 is
  `a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505`.
  The converted source is `packaging/windows/cacert.pem`.
  [Upstream source, conversion and licence](https://curl.se/docs/caextract.html).

The original upstream licences apply; these files do not replace them.
