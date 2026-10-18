# OpenWeb tenant domain registry

The central service at `https://domains.openwebpbx.com` holds name ownership for OpenWeb-managed tenant connection addresses. It is separate from each PBX and its database. Installations receive their own private signing key; they never receive the central cPanel credential or a shared wildcard certificate key.

## Custodian deployment

The implementation is [OpenWebPbx.DomainRegistry](../platform/OpenWebPbx.DomainRegistry). It uses .NET10 and a dedicated PostgreSQL database. Build a self-contained Linux service:

```sh
dotnet publish platform/OpenWebPbx.DomainRegistry -c Release -r linux-x64 --self-contained true
```

Run it as the dedicated `openweb-domain-registry` system account using the [service template](../packaging/domain-registry/openwebpbx-domain-registry.service). Its private configuration is `/etc/openwebpbx-domain-registry/config.json`; use the [placeholder example](../packaging/domain-registry/domain-registry.example.json), a root-owned750 directory and root/service-group640 file. Keep this separate from the PBX configuration directory. Only this central configuration contains the DNS API credential.

Provision trusted HTTPS for `domains.openwebpbx.com`, then use the [nginx location](../packaging/domain-registry/nginx-location.conf). The application listens only on127.0.0.1:5095. The proxy overwrites forwarded client addresses; the application trusts only its loopback proxy and one forwarded hop. `/health` reports protocol1 without exposing configuration or ownership records. Database tables initialise on startup under the dedicated database owner.

## Ownership protocol

An installation requests a five-minute nonce for its P256 public key and canonical HTTPS hostname. It publishes the exact proof at `/.well-known/openwebpbx-instance/<nonce>` and signs the tenant/domain request. The registry validates the signature, nonce and public destination, pins the resolved address, validates HTTPS normally and refuses redirects, private/reserved destinations and reused nonces.

The central transaction binds each unique label to the installation key, tenant and PBX service. Reserved/existing names receive a stable suffix. DNS writes use the provider's current SOA serial and exact readback; existing unrelated records cannot be adopted or replaced. Disabled names remain reserved.

An interrupted initial creation can retry with a new nonce and revision0 only when that exact owner, tenant, service and canonical host already hold revision1. It gets the original name. Later revisions remain strict. Moving to a different canonical hostname requires an explicit signed move and matching `If-Match` revision. Ordinary background renewal never silently moves a lease or accepts a later conflicting revision.

The first implementation permits50 names per instance. Public certificate-authority limits also apply across the registered domain; a large rollout needs a verified capacity arrangement. This is not an unlimited certificate-issuance claim.

## Privacy and recovery

The registry stores public server names, installation public keys/hashes, tenant/service identifiers, requested/assigned names, ownership state, revisions and verification times. Request handling also processes public network addresses. It does not receive phone passwords, call audio, voicemail or recordings. Follow the [public privacy policy](https://openwebpbx.com/privacy) and [privacy operations](privacy-operations.md) for requests and retention review.

Back up the central database and its private operator configuration separately. PBX backups include their own instance key and local lease revisions. Loss of that key requires custodian recovery; it must not be worked around by taking over an existing name with a different key. Decommissioning or releasing names is an explicit custodian operation, not automatic reuse after tenant deletion.

## Verification

`python3 tests/domain_registry.py` launches an independent disposable PostgreSQL cluster and real loopback HTTP endpoints. It does not modify production DNS or the production database. Current115 controls cover signatures, replay, ownership/collisions, retries, moves/stale copies, provider parsing, address restrictions and privacy boundaries. Optional private provider-response fixtures never belong in Git.

The live DNS adapter was also tested with one separately owned random CNAME: actual creation, exact target readback and a second idempotent check passed with one provider write. The test name was removed. Every original DNS value remained exact; cPanel changed SOA serial/write-time and record-position/line-wrapping metadata. This provider check is distinct from complete instance installation, certificate renewal and Windows acceptance.
