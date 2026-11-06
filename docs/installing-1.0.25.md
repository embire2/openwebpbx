# Debian 1.0.25 deployment status

Version 1.0.25 is deployed on the hosted Debian instance and its source is
committed. A complete signed 1.0.25 installer has not been qualified or published.
The current complete download remains [Debian 1.0.23](installing-1.0.23.md).
Do not replace a running installation's files or change only its VERSION file.

The 1.0.25 installer source includes the existing local PostgreSQL setup and managed
registration wizard, the new reseller/recovery migrations, a root recovery
timer, API v2 routing and an isolated PHP upload pool. The normal web/phone XML
worker keeps ordinary POST parsing. Large encrypted uploads have server-side
authentication and storage checks before their body is admitted.

Self-hosted installations default to no hosted resource charges. Only the
installation operator can select hosted billing and default resource packages.
Hosted Starter currently provides 10 extensions and five simultaneous calls,
with two initial extensions. Operators configure provider presets and prices;
existing tenants keep their current settings until deliberately assigned a
package. [Reseller guide](reseller-1.0.25.md) · [API](reseller-api-v2.md).

Before publishing a complete 1.0.25 package, freeze its full source and payload,
qualify affected fresh setup and signed upgrade/rollback, and verify public
delivery. Include the upload pool, worker units and their recovery targets;
preserve currently disabled/custom tasks and customer identities. Windows
remains independently versioned and its ports are tracked in the
[change ledger](debian-windows-sync.md).

Full backups require the 10 GiB safety reserve plus dump, media, verification and
recovery workspace. The current hosted server needs more working storage for
its approximately 4.8 GiB media tree. Its successful disposable-tenant recovery
test does not establish a full backup of customer data.
