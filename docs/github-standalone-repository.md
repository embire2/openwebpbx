# Standalone GitHub repository

Checked through the authenticated owner API on **27 October 2026**:
`embire2/openwebpbx` is public, repository ID **1406074259**, default branch
**customization**, and still belongs to the `fusionpbx/fusionpbx` fork network.
The owner has administrator access. GitHub reports **148,132 KB** and one child
fork, **freshy969/openwebpbx**; our access to that child is read-only.

[GitHub's detachment instructions](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork)
still require a public fork below 1 GB with no child forks for the self-service
option. They also warn of permanent separation and lost repository metadata.
The existing child fork blocks that option. The documented REST fork endpoints
and the authenticated GraphQL mutation schema expose no supported detach
operation or writable fork-status field.

OpenWebPBX's releases, update feeds, Actions configuration and qualification records depend on the existing repository. Keep its history, licence, copyright notices and upstream attribution. The README presents OpenWebPBX as its own project while acknowledging those origins. No repository deletion, recreation or detachment has been performed.

The owner can submit the following current request through
[GitHub's fork support form](https://support.github.com/request/fork), signed in
as **embire2**. Support availability depends on the account's plan; GitHub does
not guarantee that a preserving administrative detachment is available.

> Subject: Detach embire2/openwebpbx while preserving releases and repository identity
>
> I own and administer https://github.com/embire2/openwebpbx, repository ID 1406074259, default branch customization. Please detach it from fusionpbx/fusionpbx so that OpenWebPBX becomes a standalone repository and the "forked from" header is removed. We will preserve the full Git history, licences, copyright notices and upstream attribution.
>
> The repository is public and below 1 GB, but its child fork freshy969/openwebpbx blocks the self-service Leave fork network option. Please handle the fork-network arrangement without deleting or changing the child's owner's work.
>
> Preserve the existing repository ID and URL, all commits/branches/tags, releases, release asset IDs/bytes/download URLs, signed update feeds, Actions configuration/secrets/run history, permissions, issues, discussions, pull requests, stars and watchers. The 27 October inventory contains 113 Git refs, 21 releases and 156 assets. Latest release v1.0.21 has release ID 425443430 and eleven assets; installed Debian/Windows servers and Android apps depend on the existing download/update addresses.
>
> Do not delete/recreate, rename, transfer or rewrite the repository as a workaround. If administrative detachment can preserve these identities and assets, please perform it. If any loss or identity change is unavoidable, explain it before taking that action.

This request is prepared and **has not been sent**. No detachment or repository
recreation has occurred. The authenticated GitHub connection supports repository
operations but cannot submit a Support ticket. The current complete repository,
refs, releases and assets inventory is retained privately under
`/var/lib/openwebpbx/github-detach-20261027-03uex6ix`.

After GitHub acts, verify `fork: false`, the same repository ID, every original
ref/release/asset identity, public downloads and signed feeds before reporting
completion. The local `upstream` Git remote and legal attribution do not control
GitHub's fork header; removing either would not detach the repository.
