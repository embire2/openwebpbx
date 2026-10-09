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

## Google Play publication metadata

The Play edition uses the same pinned signed envelope, expiry and persisted
sequence/digest checks. It never downloads the direct APK and does not use an
APK installer. The optional top-level `android_play` object announces only a
confirmed Google Play production publication:

```json
"android_play": {
  "status":"published", "track":"production", "rollout":"complete",
  "package_id":"com.openweb.pbx", "version":"1.0.7", "version_code":107,
  "minimum_server_version":"1.0.6", "min_sdk":28,
  "published_at":"2026-10-10T12:00:00Z"
}
```

The example is illustrative; it is not evidence of Play approval. Omit this
object until an operator confirms approval and a completed production rollout
across the selected supported regions. A GitHub APK release, uploaded bundle,
test track, pending review or staged rollout does not establish availability.
Absent or null metadata means no known published Play update and cannot activate
a required-update gate. Malformed or unsupported publication metadata is refused.

The Play version must not exceed the envelope version. Numeric version codes
must be 1–2,147,483,647; minimum SDK must be 28–100. Publication time must be UTC,
at or after 1970, no later than the feed publication and not more than five minutes
in the future. An app requires both a newer version name and version code, plus
supported Android/PBX versions. The fixed store link is
`https://play.google.com/store/apps/details?id=com.openweb.pbx`; metadata cannot
supply an arbitrary link, code download or installation command.

After verifying actual Play publication, pass the reviewed object as
`sign-feed.py --play-published-metadata /private/reviewed-play-publication.json`.
The signer validates every field before signing. Existing direct/server assets
and validation rules are unchanged. Do not rewrite an immutable released feed or
reuse its sequence for changed metadata. Publish a later consistent full release
with a higher sequence; it may announce an older approved Play version. A Play
approval by itself does not permit rebinding a 1.0.7 feed to 1.0.6 native assets.

Tenant `required` applies only to verified published Play metadata. Cached policy
is bound to the currently enrolled account and expires after 24 hours; signed
publication expiry also applies. Active calls and urgent calling bypass the gate.
The app waits for an active call to finish before opening Google Play. Google
Play controls its download, installation, eligibility and reopening; this app
cannot silently install, cancel, track its byte progress or guarantee that a
store-managed installation waits for calls arriving after that handoff. Tenant
`download` cannot override the user's Google Play automatic-update settings.

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
