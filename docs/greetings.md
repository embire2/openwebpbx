# Greetings

Open **Admin → Greetings** to create reusable voicemail greetings, Digital Receptionist messages, queue welcomes, queue waiting announcements, music on hold and general announcements.

Choose a category, company name and recording method. A blank name becomes a unique category/date name, and the audio always gets a separate UUID-based filename. Names can be changed later.

- **Call a phone to record:** choose an extension or outside number and the calling extension whose normal outside-call rules should apply. Keoma explains what will be recorded and asks the person to record after the tone and press **#**. The system replays the completed recording before saving it. Hanging up before recording/replay finishes, exceeding the duration without pressing #, or returning an incomplete WAV does not replace an existing greeting. There is one call attempt per request; retry is an administrator action.
- **Let Keoma read my text:** type the script, up to 3,000 characters. The instance creates a mono WAV with the configured ElevenLabs account. OpenWebPBX adds no charge; provider generation consumes that account's allowance. Only typed text and the public company/category instructions go to ElevenLabs. Phone recordings remain on the PBX.

All instructions use **Keoma**, voice ID `i8SlcaZfyeP1st7wHsjM`. The service verifies that the provider's configured voice is named Keoma. There is no fallback to another narrator.

Ready audio can be listened to, downloaded, renamed and assigned to appropriate destinations. Voicemail greetings can be reused across extensions. Assigning one creates a new mailbox greeting file and leaves every old/custom file intact. Digital Receptionist and queue assignments update their saved calling configuration; music can be assigned to queues or extension hold settings. Current assignments can also be removed; this selects default audio only when this greeting is still chosen, preserving a newer choice made elsewhere. Other existing prompt selectors also receive ready audio through the normal recording/media library. Archiving an unused item retains its audio for the operator's retention policy.

An enabled PBX owner or instance administrator must manage this page. Every query, audio download and assignment is bound to the selected PBX domain. Ordinary users, disabled administrators and other tenants cannot use the library. HTTP actions require a form token. A PBX may have up to five pending preparations and 40 new requests per day, with three preparation attempts per request. Phone recordings are limited to five minutes; text-generated audio is limited to three minutes.

## Installation and activation

The dedicated migration is `app/pbx_greetings/resources/install.sql`. It creates `v_pbx_greetings`, `v_pbx_greeting_uses` and `v_pbx_greeting_status`. The shared `packaging/windows/bootstrap.php` includes it in both fresh-domain and migrate paths. Debian's fresh installer and upgrade also use that shared bootstrap, so all supported installation paths receive the same migration.

Deploy the newly compiled **OpenWebPbx.Server** service and its registered `GreetingWorker`, the new web app/classes, and `app/pbx_setup/resources/switch/scripts/app/pbx_greetings/` into the engine's `app/pbx_greetings/` scripts directory. The existing script deployment prefix covers both supported platforms. The Debian service's existing private-storage drop-in now permits writes inside the PBX media root; fresh configuration, support installation and upgrades already copy that drop-in. Apply the updated unit/drop-in with `systemctl daemon-reload` when activating the new build. Normal service upgrade/idle checks still apply.

Configure **`ElevenLabs:ApiKey`** only in the instance's protected runtime configuration, with account access to the Keoma voice. Never include the deployment key in source, release packages, browser responses or independent installations. The production media root defaults to the configured standard FreeSWITCH storage's `openwebpbx` directory on Debian and Windows. A custom `Greetings:MediaRoot` must match the engine's storage layout; the test harness overrides it only for isolated fixtures.

The worker skips all greeting jobs until the tables exist. It reports readiness to the database. Until an updated worker reports recently and a provider key is configured, the page clearly identifies the missing service/configuration, disables creation and refuses creation on the server. A visible page on an older server therefore does not silently queue work that no worker can perform.

## Validation scope

The standalone SQL fixture passes 49 actual PostgreSQL permission, tenant isolation, readiness, destination/category, multiline-text, renaming, repeat-assignment and custom-file controls. The C# fixture passes 39 checks of the actual worker against PostgreSQL and controlled HTTP/engine endpoints, checking exclusive Keoma URLs, complete WAV output, cancellation, dispatch and duplicate-call refusal. Those controlled HTTP responses are synthetic audio and do not establish physical-phone or provider operation. The Lua fixture passes 52 recording/hash/replay/commit and interruption-cleanup controls with synthetic call sessions.

A separate Debian FreeSWITCH loopback smoke passes the unchanged recorder helper with genuine generated Keoma instruction/replay/saved audio, actual `recordFile`, injected #, callback removal, replay and commit order. Its saved mono 16 kHz WAV contains 2.02 seconds of the independently supplied 430 Hz input tone, and both owned legs close. The initial loopback fixture did not answer and is retained separately; the corrected fixture explicitly answers its owned inline-Lua callee. This native result covers the recorder helper, not the complete routing/tenant worker, external phones or Windows calling.

[Windows build 40200892861](https://github.com/embire2/openwebpbx/actions/runs/40200892861) compiles the new service and passes the same 39 Greetings worker controls against isolated PostgreSQL on Windows. It uses controlled HTTP/engine endpoints; actual Windows recording calls and complete installer/upgrade acceptance still need separate qualification.
