# OpenWeb PBX update protocol 1

All clients pin `release-public.pem` under key ID `release-2026-a`.
The release signing private key is outside source; it must never be packaged.
Envelope at `https://github.com/embire2/openwebpbx/releases/latest/download/update-manifest.json`:

```json
{"key_id":"release-2026-a","payload":"BASE64_UTF8_JSON","signature":"BASE64_RSA_SIGNATURE"}
```

Verify RSA SHA-256 **PKCS#1 v1.5** against the decoded exact payload bytes before
using any payload field. Limit envelope to 256 KiB. The payload schema is:

```json
{
  "schema":1,"product":"openwebpbx","channel":"stable","sequence":104,
  "version":"1.0.4","published_at":"2026-10-09T00:00:00Z",
  "expires_at":"2027-04-07T00:00:00Z",
  "assets":[
    {"platform":"android-universal","name":"openwebpbx-1.0.4-android.apk",
     "url":"https://github.com/embire2/openwebpbx/releases/download/v1.0.4/openwebpbx-1.0.4-android.apk",
     "bytes":1,"sha256":"64lowercasehex","version_code":104,
     "package_id":"com.openweb.pbx","min_sdk":28,"minimum_server_version":"1.0.4",
     "certificate_sha256":"449740f6858cb092a0f67d9d79d2505a8d6e7e4d4c1a52a8eaed9b895e48e69d"},
    {"platform":"debian13-amd64","name":"openwebpbx-1.0.4-debian13-amd64.tar.gz",
     "url":"https://github.com/embire2/openwebpbx/releases/download/v1.0.4/openwebpbx-1.0.4-debian13-amd64.tar.gz",
     "bytes":1,"sha256":"64lowercasehex","minimum_version":"1.0.3"},
    {"platform":"windows-x64","name":"openwebpbx-1.0.4-windows-x64.zip",
     "url":"https://github.com/embire2/openwebpbx/releases/download/v1.0.4/openwebpbx-1.0.4-windows-x64.zip",
     "bytes":1,"sha256":"64lowercasehex","minimum_version":"1.0.3"}
  ]
}
```

The example sizes and hashes are placeholders, never publish them. Validate
three-part nonnegative numeric versions, newer-than-installed version, supported
schema/platform, expiry and persisted monotonic sequence. Repeated same sequence
must have identical payload digest. Future-dated metadata beyond clock tolerance
is invalid. Reject unknown keys; rotate by first shipping a trusted release that
adds the next verification key. No downgrade or trust-on-first-use key fetching.
Only GitHub URLs within this exact repository and signed version tag are accepted;
HTTPS redirects may go only to GitHub's documented release asset hosts. Never
forward PBX authentication headers to release servers. Bound bytes, verify whole
file size/SHA-256 and reject archives with traversal, symlinks or duplicate paths.
Android additionally verifies the archive package/version/signing identity.

## Policy and server command contract

`app/pbx_updates/resources/install.sql` defines PostgreSQL tables. Web endpoints
authenticate and authorize policy/command writes; workers never accept URLs,
paths, shell arguments or arbitrary code from the database.

- Instance scope `instance`: `notify` (default), `download`, `automatic`.
  Download stages only; automatic installs inside the configured daily UTC window
  (`maintenance_hour`, `maintenance_duration`) after calls finish. Explicit
  `install` permits installation outside the window but still waits for idle.
- Tenant scope `tenant:<uuid>`: `notify` (default), `download`, `required`.
  Required downloads automatically and requires installation when the verified
  package is ready, deferring active calls and obeying Android system consent.
- Server commands: `check`, `download`, `install`; atomic pending-to-running claim.
  Never replay a completed command. Reconcile interrupted running commands against
  the private install journal before retrying anything.
- Worker writes singleton `v_pbx_update_status.status_json`: `state`, `message`,
  `installed_version`, `available_version`, `progress_bytes`, `total_bytes`,
  `checked_at`, optionally `last_success_version`. Values must contain no secrets.
  `updated_at` is the worker heartbeat. Terminal errors remain visible.
- Phone GET `/app/pbx_mobile/api.php?action=updates` uses existing bearer auth:
  `{"schema":1,"mode":"notify","channel":"stable","server_version":"1.0.4","feed_url":"https://github.com/embire2/openwebpbx/releases/latest/download/update-manifest.json"}`.
  Tenant is derived from authenticated extension ownership, never caller input.
  On an older server without this endpoint clients may check the pinned feed in
  notify mode, but must honor signed minimum-server-version before offering it.

Download completion, verification, idle checks, backup and durable recovery state
must precede application shutdown. The independent updater survives PBX restarts.
Installers restart and health-check services and restore the prior application
and database on failure. Offline checks never stop a running PBX. Android may
require install-source permission and install confirmation; background reopening
uses a notification when the operating system prevents launching an activity.
