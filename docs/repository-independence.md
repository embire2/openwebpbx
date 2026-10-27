# GitHub repository independence

Latest check: **27 October 2026**. OpenWeb PBX is maintained at **[embire2/openwebpbx](https://github.com/embire2/openwebpbx)**, with repository ID **1406074259** and default branch **`customization`**. Its GitHub metadata still identifies it as a fork of `fusionpbx/fusionpbx`; the child fork still blocks self-service detachment. Use the [current request and 1.0.21 preservation inventory](github-standalone-repository.md). The detailed 24 October inventory and request below are historical and have not been submitted.

The goal is to make this an independently discoverable repository while preserving its history, attribution and every existing download/update address. Removing GitHub's fork relationship does not remove the project's FusionPBX origins or change any licence obligation.

## What has been completed

- Rewritten the main README around the product, mission, screenshot, accurate component/platform downloads, installation and useful documentation.
- Updated the GitHub About description and HTTPS homepage.
- Added relevant PBX, VoIP, SIP, FreeSWITCH, Android, Debian, self-hosting, multi-tenant, call-centre and conferencing topics.
- Enabled the previously unused Issues tracker; Discussions was already available.
- Preserved licences, copyright notices, upstream attribution, repository path, branches, tags, releases, assets and history.

## Current fork-network detachment limits

[GitHub's fork-search documentation](https://docs.github.com/en/search-github/searching-on-github/searching-in-forks) says forks are omitted from default search results. Relevant topics and a clearer README help visitors, but do not change the repository's fork flag.

GitHub documents **Settings → General → Danger Zone → Leave fork network** for public forks smaller than 1 GB with no child forks. The authenticated owner **embire2** has **ADMIN** access; this public repository reports **145,524 KB** of disk usage, but its **one child fork**, **`freshy969/openwebpbx`**, makes it ineligible. The child's parent is `embire2/openwebpbx`; our access to the child is **READ**. It has not been contacted or modified.

GitHub warns that leaving is **permanent** and loses associated issues, pull requests, wikis, stars, watchers, comments, child forks and other metadata, while preserving Git commit metadata. This does not establish the preservation required for our repository identity, release assets, signed update URLs and Actions artifacts. The documented delete/recreate/mirror alternative also puts those dependencies at risk. Neither method has been used. See [GitHub's current detachment documentation](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork).

The [public REST fork/repository APIs](https://docs.github.com/en/rest/repos/forks) and current authenticated GraphQL schema expose no supported detach operation or writable fork-status field. No undocumented endpoint has been attempted.

## Owner action: ask GitHub for a preserving detachment

1. Sign into GitHub as **embire2**.
2. Open the [GitHub Support portal](https://support.github.com/contact) and use the available repository/fork-network route for **embire2/openwebpbx**. [Support access depends on the account's plan](https://docs.github.com/en/support/learning-about-github-support/about-github-support); general repository questions on Free accounts normally use Community support.
3. Use the unsent request below to ask **whether a preserving administrative detachment is available**. Published guidance does not guarantee support eligibility, acceptance or such an operation. Do not delete or recreate the repository as a workaround.
4. Keep the current repository and downloads active. Proceed only after GitHub describes a concrete preserving method and the owner approves it, outside an active release-qualification run. If the requirements cannot be met, leave the repository unchanged.

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

Please describe the proposed method and what it preserves, and wait for my approval before performing any change.

The public **v1.0.20** release, ID **422954723**, published **24 October 2026**, is part of this preservation requirement. Its seven assets are listed below from the authenticated GitHub API inventory. Preserve their IDs, bytes, digests and linked download addresses, and recheck the inventory immediately before any approved action. This is not a replacement for the complete release inventory or signed-feed verification.

| Asset and current download URL | Asset ID | Bytes | Published SHA-256 |
|---|---|---|---|
| [debian-update-manifest.json](https://github.com/embire2/openwebpbx/releases/download/v1.0.20/debian-update-manifest.json) | 673191831 | 1816 | `444e30c483a09f6fa4dd280419d33e7e929cf4262bc2ec14476d143d9bfbb92d` |
| [installing-windows-1.0.20.md](https://github.com/embire2/openwebpbx/releases/download/v1.0.20/installing-windows-1.0.20.md) | 673191851 | 7551 | `c6bfb8f7a3962ab5a64d9490c8d5b266543b8bc90988ebb520c3cae84425cbf2` |
| [openwebpbx-1.0.20-source.tar.gz](https://github.com/embire2/openwebpbx/releases/download/v1.0.20/openwebpbx-1.0.20-source.tar.gz) | 673191827 | 47632586 | `7b5740ab7f00f283ad899e8767510ebdf96b9ef282ca8e300d2cd5cfa934fa74` |
| [openwebpbx-1.0.20-windows-x64.zip](https://github.com/embire2/openwebpbx/releases/download/v1.0.20/openwebpbx-1.0.20-windows-x64.zip) | 673191832 | 585104517 | `9a45d51c1ee1d1f985062fc16fb0cdfaea43aee6c1a7a540a7b820852e776522` |
| [SHA256SUMS](https://github.com/embire2/openwebpbx/releases/download/v1.0.20/SHA256SUMS) | 673191856 | 569 | `709db119564c07e4f4fb901169e49c2de12fc55c8679e9dca5b820e19df66ce1` |
| [update-manifest.json](https://github.com/embire2/openwebpbx/releases/download/v1.0.20/update-manifest.json) | 673191830 | 1404 | `7c43ac14cf765a7602ddcc8fa4b187fe19d61ba2b4197f96f6d5448a6ad87e54` |
| [windows-update-manifest.json](https://github.com/embire2/openwebpbx/releases/download/v1.0.20/windows-update-manifest.json) | 673191829 | 1204 | `21e2b85bacb2ad4dcfcde547a4a6ac759c2e50f9a9ea18f267e36bb3b995f880` |

Thank you.

## Verification after an approved detachment

- The repository API must still report `id: 1406074259`, the same public path/default branch and `fork: false` without an upstream parent.
- All pre-existing branch/tag commit IDs must be unchanged.
- Existing release IDs, asset IDs, sizes and checksums must match the private pre-change inventory; complete public downloads and signed-feed verification must pass.
- Permissions/settings, Actions runs/artifacts, discussions and the child-fork arrangement must match GitHub's agreed plan.
- Confirm that the repository header no longer says “forked from”. Search indexing may take time; detachment alone is not a promise of immediate search ranking.

The source project remains a derivative of FusionPBX regardless of GitHub's metadata. Preserve its legal notices and the README's origins section throughout.
