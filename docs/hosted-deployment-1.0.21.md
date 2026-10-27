# OpenWeb hosted deployment — 27 October 2026

The shared Debian installation serving [OpenWeb](https://openweb.openwebpbx.com)
has received the complete published **1.0.21** server release. This deploys the
qualified release; it does not create a new release or change Android 1.0.19.

## Applied software

The previous web interface and core already reported 1.0.21, but the independent
updater still ran 1.0.16. An explicit operator reapplication synchronized the
complete installation using the original signed Debian 1.0.21 package and its
unchanged upgrade transaction. No version stamp was lowered and the updater's
normal requirement for a newer release remains intact.

The transaction checked that calls were idle, created its protected rollback
snapshot, installed the release files, ran the ordinary migrations and restarted
the application services. The 1.0.21 updater started and naturally finalized the
transaction. The install journal reports completion and the update status reports
that the server is up to date.

The package source remains `89ae4e4ad3947902ceb6332bc21030b3a6ac2dfd`;
the published Debian archive SHA256 remains
`406cab15dd5b3db7ee8c7a33b76eab6971f1957286cd061c76381be79f1c1726`.
See the [release qualification](release-1.0.21-qualification.md) for the separate
fresh-install, upgrade, rollback, restore and software-calling evidence.

## New tenants

Tenant portals use one shared installed application tree. Creating a tenant does
not copy an older application snapshot into its own directory. Provisioning reads
the deployed standard dialplan files and the selected template's current published
revision. Existing services retain their saved settings and template revision.

A test using the actual deployed PHP and PostgreSQL created services in a
temporary schema, revised a published template, and verified that the next service
used the new revision while the existing service remained unchanged. The test also
passed tenant isolation, validation, encrypted credentials, invitation replay,
service limits, idempotency and suspension checks, then removed its temporary
schema. No permanent test tenant was created.

Future published releases must still be applied to this instance through its
updater. New tenants then use those installed files automatically; creating a
tenant does not independently install an unretrieved future release.

## Preservation and live checks

- All 11,991 mapped release files and 226 updater files match the signed package.
  The running call engine maps the installed corrected Sofia library.
- All 18 captured customer tables matched exactly after the upgrade, including
  extension credentials, providers, routes, groups, tenant services and templates.
- All 1,525 original voicemail and recording files retained their exact content
  and permissions.
- Expected desk phones 1049–1051 and 1055–1058 were registered after deployment.
- The core reports Running, version 1.0.21; the call engine, PHP, core and updater
  services are active.
- Ordinary administrator login over trusted tenant HTTPS and the Desktop, Tenant
  Services, Updates and Greetings pages passed.

These checks do not represent a new answered physical-handset or carrier call.
Existing phone configuration and network-port policy were preserved.

## Recovery records

Private deployment evidence is retained under
`/var/lib/openwebpbx/hosted21-sync-69fda3e5efef46529168e3a00550b4ad`.
The transaction's database/configuration and affected-file rollback snapshot is
`/var/backups/openwebpbx/upgrade-20261027T133553Z-32c80db5`.

A separate verified encrypted database/configuration backup is retained with its
recovery password in private storage. Available disk space prevented an additional
complete media archive; original media remained in place and every captured file
was hash-verified. Do not describe this deployment as having created a second
complete media backup. Preserve these recovery records and customer recordings.
