# GitHub repository independence

Checked on 21 October 2026. OpenWeb PBX is maintained at **[embire2/openwebpbx](https://github.com/embire2/openwebpbx)**, with repository ID **1406074259** and default branch **`customization`**. Its GitHub metadata currently identifies it as a fork of `fusionpbx/fusionpbx`.

The goal is to make this an independently discoverable repository while preserving its history, attribution and every existing download/update address. Removing GitHub's fork relationship does not remove the project's FusionPBX origins or change any licence obligation.

## What has been completed

- Rewritten the main README around the product, mission, screenshot, accurate component/platform downloads, installation and useful documentation.
- Updated the GitHub About description and HTTPS homepage.
- Added relevant PBX, VoIP, SIP, FreeSWITCH, Android, Debian, self-hosting, multi-tenant, call-centre and conferencing topics.
- Enabled the previously unused Issues tracker; Discussions was already available.
- Preserved licences, copyright notices, upstream attribution, repository path, branches, tags, releases, assets and history.

## Why the fork relationship still needs GitHub's help

[GitHub's fork-search documentation](https://docs.github.com/en/search-github/searching-on-github/searching-in-forks) says forks are omitted from default search results. Relevant topics and a clearer README help visitors, but do not change the repository's fork flag.

GitHub documents **Settings → General → Danger Zone → Leave fork network** for public forks smaller than 1 GB with no child forks. This repository is public and its reported size is below that limit, but it has one child fork, **`freshy969/openwebpbx`**. An authenticated read confirmed that child's parent is `embire2/openwebpbx`; the child has not been modified.

GitHub also warns that leaving a fork network can discard associated repository metadata. This project relies on existing release assets, signed update URLs, repository identity and Actions artifacts. The documented delete/recreate/mirror alternative would put those dependencies at risk. Neither method has been used. See [GitHub's current detachment documentation](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork).

## Owner action: ask GitHub for a preserving detachment

1. Sign into GitHub as **embire2**.
2. Open [GitHub Support](https://support.github.com/contact), choose a repository/fork-network request and select **embire2/openwebpbx**. If offered, the [fork request page](https://support.github.com/request/fork) is the specific entry point.
3. Paste the request below. Ask GitHub to confirm preservation before making any change. If the account's plan does not provide a suitable ticket option, use the support portal's available routing; do not delete or recreate the repository.
4. Keep the current repository active while GitHub reviews it. After GitHub confirms a safe plan, coordinate the change outside an active release-qualification run, then perform the verification below.

No support ticket or message has been sent by the development agent. No change to the fork relationship is claimed.

### Ready-to-send request

**Subject:** Detach `embire2/openwebpbx` from its upstream fork network while preserving repository identity and releases

Hello GitHub Support,

I own and administer the public repository https://github.com/embire2/openwebpbx (repository ID **1406074259**, default branch **customization**). It is currently a fork of https://github.com/fusionpbx/fusionpbx.

OpenWeb PBX now has its own product roadmap, server releases, Android application and community. I would like it to become a standalone repository eligible for ordinary repository discovery. We will retain the complete Git history, original licences, copyright notices and transparent upstream attribution.

The repository has a child fork, https://github.com/freshy969/openwebpbx, so it does not meet the documented no-child-forks condition for the self-service Leave fork network action.

Please advise whether you can detach our repository administratively while preserving all of the following:

- The same repository object and numeric ID **1406074259**, owner/name **embire2/openwebpbx**, visibility and URL.
- All commits, branches, tags and the default branch **customization**, without history rewriting.
- All releases and release assets, including their existing asset IDs, checksums and download URLs. Installed servers and Android apps depend on our existing signed update-feed/download addresses.
- Repository settings, permissions, Actions workflows, run/artifact history and existing links, discussions, issues, pull requests, stars/watchers and other metadata.
- Existing child forks and their owners' work, without deleting or modifying them. Please explain the resulting fork-network arrangement.

We do **not** authorize deleting/recreating, renaming, transferring, force-pushing, or changing the repository identity or existing release/download URLs as a workaround. Please explain any unavoidable losses or restrictions first, and wait for my approval if a preserving detachment is not possible. We will coordinate the execution window after any active release qualification has completed.

Please confirm the proposed method and what it preserves before proceeding.

Thank you.

## Verification after an approved detachment

- The repository API must still report `id: 1406074259`, the same public path/default branch and `fork: false` without an upstream parent.
- All pre-existing branch/tag commit IDs must be unchanged.
- Existing release IDs, asset IDs, sizes and checksums must match the private pre-change inventory; complete public downloads and signed-feed verification must pass.
- Permissions/settings, Actions runs/artifacts, discussions and the child-fork arrangement must match GitHub's agreed plan.
- Confirm that the repository header no longer says “forked from”. Search indexing may take time; detachment alone is not a promise of immediate search ranking.

The source project remains a derivative of FusionPBX regardless of GitHub's metadata. Preserve its legal notices and the README's origins section throughout.
