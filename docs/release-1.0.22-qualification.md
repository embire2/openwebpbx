# Debian 1.0.22 qualification

Status: candidate qualification in progress on 29 October 2026. The public server
release remains 1.0.21; this document does not announce a published installer.
Windows Server remains 1.0.21 and Android remains 1.0.19.

The complete Debian 13 amd64 package uses application source
`0aaa8a0609268951c01b21d4d39ada1b001cf909`. Its 487,445,302-byte archive has SHA256
`5381cc53596e39c572b320aab85e7e8909f6c828d895bd1f1b80b5ad99649f99`.
The provider uses read-only media containing that same complete installer.

## Release scope

Fresh self-installations obtain a managed server hostname, prove control of their
public address, and complete email verification, company details and tenant
registration through the setup wizard. A registered `*.openwebpbx.com` tenant
address and valid authorization are required before new calling work starts.
Existing installations retain their existing calling policy and credentials.

Webhotel adds the image to Create Instance, checks and reserves the chosen tenant
address before provisioning, and presents the initial PBX credentials permanently
to the authenticated owner or an explicitly permitted credential viewer. These
credentials are encrypted in provider storage and separated from provider root
and account credentials. Cancellation holds the allocated IP until owned-instance
shutdown and fresh central revocation/DNS-absence checks succeed.

The signed upgrade feed requires Debian 1.0.21 or newer. This release does not
qualify a direct upgrade from 1.0.16. The Windows21 and Android19 feed envelopes
must remain byte-identical in the new latest release.

## Acceptance gates

| Gate | Current evidence |
|---|---|
| Package and source provenance | Accepted: independent audits bind all12,192 payloads,6,707 packaged Git blobs,565 native files and36 native build inputs. The separate source archive passes7,644 exact Git blob/mode checks and contains no supplied live credential. |
| Central registration authority | Accepted: source and exact deployed native registry each pass326 controls; privileged PHP128 and dispatcher46 also pass. Existing customer projections and calling processes are preserved. |
| Backup safety and scheduled contention | Accepted components: nineteen real backup/restore controls and fourteen OS/adapter controls. Bounded waiting changes only scheduled Debian lock acquisition; actual fleet backup completion is recorded. |
| Exact final-package clean installation | In progress on healthy, eligible provider nodes. An earlier package followed by a narrow correction remains a component result. |
| Genuine original21 signed rollback and upgrade | In progress for final0aaa. Earlier successful transactions and failed preservation comparisons retain their original results. |
| Independent replacement restore | Earlier candidate component acceptance is retained. Final package acceptance is tracked separately. |
| Webhotel checkout and credential access | Existing103 onboarding,34 lifecycle,61 route,12 IP-owner and39 authenticated browser/API controls pass. Final provider pairing-renewal recovery and deployment checks are in progress. |
| Per-node image availability | Staging and full node certification are separate. Nodes with storage errors, insufficient resources or no customer-IP pool remain unavailable. |

The final upgrade repeat declares an1,800-second observation bound before starting
either phase. It retains signature, resource-floor, idle-call, natural-updater,
raw database, schema, identity, role, file and late-fault witness checks. The
disposable fixture quiesces unrelated background writes for its strict snapshots;
its original timer choices must be restored and backups exercised afterwards.
Historical1,200-second results are not relabeled.

Actual software calls use SIP signaling and decoded two-way RTP. They do not
certify a new physical handset, carrier, Android device, Windows installation or
app-store submission. Existing published artifacts remain immutable.

See [installation](installing-1.0.22.md), [Webhotel onboarding](webhotel-onboarding.md)
and [updates](updates.md). Private raw evidence remains on the controlled
qualification hosts; it contains customer-shaped fixtures and access material and
is not part of the public release.
