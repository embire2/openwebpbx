# Calling release safeguards

The 18 November 2026 outgoing-call failure was a software error before the
provider was contacted. The call engine loads configuration that replaces Lua's
`debug` library with logging settings. The provider-options loader assumed
`debug.getinfo` was available and raised an exception. Source `d2a7a9a4c` uses the
configured scripts directory instead. Credentials, routing and provider choice
were preserved. The owner confirmed the corrected Android call connected with
sound both ways.

## Implemented

- `tests/pbx_trunk_options.lua` reproduces the configured-engine global collision
  and verifies that a missing trusted module location refuses safely.
- The **Calling policy regression** workflow runs on pushes, pull requests and
  manual dispatch. It runs 39 provider-option, 241 policy and 214 simulated
  runtime checks. Its jobs use fictional identities and make no phone calls.
- The fix is present in Main source and the next Windows27 candidate. Published
  Debian27 and Windows23 archives remain immutable; this does not claim they
  already contain the correction.

This workflow is an automatic check, not branch protection or a carrier test.
Releases must not proceed with a failing result. A required GitHub status check
must be configured separately before claiming that GitHub enforces the gate.

## Required evidence for calling changes

1. Run the regression workflow against the exact source being packaged. Retain
   the commit, result and package hash; rerun after any calling-code change.
2. Load the changed scripts in the real FreeSWITCH Lua environment, with normal
   configuration loaded. Standalone interpreter tests alone are insufficient.
3. On an owned test PBX, verify internal, incoming and outgoing calls, ringing,
   answer, media in both directions, hold/resume and a failed-provider fallback
   that does not duplicate an answered call. Use controlled test endpoints.
4. Before deployment, capture the last working files and relevant configuration.
   Compare the selected route/provider and permissions before and after. Preserve
   tenant identities, authentication IDs, passwords, QR identities and recordings.
5. Apply during a naturally idle window when calling can be affected. Verify the
   deployed file hashes and repeat controlled call checks. Restore only the
   affected code if those checks fail; do not roll back customer data merely to
   make a software check pass.

Successful service health, registration or a generated call plan is not proof
of ringing, connected audio or carrier acceptance. An unperformed check remains
open. Software tests do not stand in for physical-phone or human audio checks.

## Further automation to build

- Run the real-engine and controlled SIP/media scenarios automatically against
  every release candidate on isolated Debian and Windows installations.
- Show a prominent incident when Lua call-handling exceptions appear, and track
  failed/connected outgoing attempts without exposing credentials or dialled
  numbers in public diagnostics. Configure notification recipients explicitly;
  this work has not enabled an external notification channel.
- Add a versioned, code-only deployment health gate and tested rollback. Do not
  automatically change routes, bypass permissions or retry answered calls.
- Enable a required successful **Calling policy regression** status check in the
  repository's reviewed branch rules. The current automatic workflow alone does
  not block a direct push or manual publication.

These are separate follow-up tasks, not completed monitoring or rollback claims.
