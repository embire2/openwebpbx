# Privacy operations — Open ISP cc

Prepared 17 October 2026. These are procedures and actions to adopt, not evidence that staff have completed them. Responsible owner: Information Officer Leon Whitherall, hello@openwebpbx.com, +27 87 350 8601. See [scope, sources and findings](website-privacy-compliance.md).

## Request handling

1. Monitor the published mailbox and telephone route. Confirm an actual message reaches the assigned team and that absence cover exists; a configured forwarder is insufficient proof. No live test email has been sent by the development agent.
2. Open a restricted request record: identifier, received date, requested right/records, jurisdiction, account/operator, assigned handler, acknowledgement, due date, verification status and outcome. Store request evidence outside public repos and ordinary app logs. Do not copy phone passwords, QR codes or full ID numbers into tickets.
3. Establish whether Open ISP cc controls the records, acts on a tenant's instructions, or has no access to an independent PBX. Forward/assist within the agreed lawful roles. Do not make the person reinstall an app or sign in solely to submit a request.
4. Use proportionate verification. Prefer the existing verified account/contact relationship and limited service references; do not demand unnecessary identity documents. Verify authority for representatives and protect third-party information.
5. Identify the applicable procedure. GDPR rights: respond without undue delay, normally within one month; a justified extension of up to two additional months must be communicated within the first month. PAIA formal access: generally decide within 30 days, subject to the permitted notified extension. POPIA correction/deletion must be handled as soon as reasonably practicable; do not treat PAIA timing as a universal POPIA deadline.
6. Search relevant website correspondence/logs and, where controlled, PBX databases, recordings, voicemail, account/device records, support copies and providers. Export securely; redact unrelated third-party records and explain lawful exclusions. Never disclose another tenant's records.
7. Explain action, refusals, retention grounds, fees where law permits, escalation and regulator/court remedies. GDPR requests are ordinarily free; confirmation under POPIA whether personal information is held is free. Do not charge a blanket access/deletion fee.
8. Record completion and residual retention. Deactivate access immediately where appropriate. Apply lawful erasure to active systems and propagate it to instructed processors. Keep a minimal restricted deletion/suppression record only where justified so a restored backup does not silently recreate deleted active accounts; remove it at its approved expiry. Backups age out under the approved schedule and remain restricted in the meantime.

## Retention and provider inventory to approve

| Record / provider category | What must be confirmed | Current status |
|---|---|---|
| Public-site hosting/security logs | Actual host/controller/processor, log fields, locations, default and backup retention, access, deletion and incident terms | Exact periods/provider agreements not verified |
| Contact mailbox and support copies | Mail processors/forwarding destinations, storage countries, request records, retention/deletion and authorised access | Forwarder configured; delivery and retention untested |
| GitHub releases/source support | Public versus private content, ordinary download requests, privacy terms, accidental-data removal process | External downloads linked; no customer data should be published |
| Google/optional notification relay | Actual enabled configuration, delivery metadata, encryption boundaries, provider terms and locations | Notice explains optional service; actual contracts/transfer mechanisms require verification |
| OpenWeb-operated PBXs | Tenants, database hosting, telephony providers, access roles, record/recording/voicemail periods, backups, deletion, subprocessors and transfers | Needs deployment-specific completed inventory |
| Browser appearance | `openweb-site-theme` and necessary `openweb-site-consent` | 180-day logical expiry; theme requires explicit optional choice; removed on withdrawal/next expiry check |

For each real processing activity, record controller/operator role, people and data categories, sources, purposes, lawful ground, recipients, country/location, safeguards, retention, security owner and rights route. Complete legitimate-interest balancing where used. Verify written GDPR Article 28 / POPIA operator terms where applicable, authorised subprocessors and GDPR Chapter V / POPIA section 72 transfer conditions before relying on them. Do not state that an SCC or adequacy decision exists without its actual evidence.

## Security compromise response

1. Escalate immediately to the Information Officer and relevant service/security owner. Record awareness and incident times, systems/tenants affected and evidence. Restrict evidence and preserve integrity.
2. Contain the incident, revoke exposed access and determine scope with the relevant operators/providers. Avoid destroying evidence. Operators must notify their responsible party promptly under their applicable duties/contracts.
3. Assess each applicable notification duty separately. GDPR authority notification is generally within 72 hours of awareness where required; document reasons for delay and reasons for any decision not to notify. High-risk affected-person communication is a separate assessment. POPIA section 22 notification to the Regulator and affected people is as soon as reasonably possible, subject to the Act's conditions; it is not a blanket 72-hour rule.
4. Use current official regulator channels/forms, describe the compromise, likely impact, safeguards and contact, and update incomplete facts as required. Do not send full credentials or unnecessary personal data in reports.
5. Verify recovery, track corrections and record the decision/evidence. Test the response procedure with fictional data and train staff; no completed drill is claimed here.

## Organisation actions awaiting confirmation

- [ ] Confirm the current registered/business address and maintain an approved company record.
- [ ] Retain Leon's written appointment/authority and Information Regulator registration confirmation, including the appropriate head/deputy arrangements.
- [ ] Determine GDPR territorial applicability and Article 27 applicability/exemption; obtain EU country/address and written mandate for any required representative. Keep this distinct from the Information Officer and DPO roles.
- [ ] Assess DPO appointment and DPIA requirements for actual monitoring/recording/sensitive processing; appoint/perform them when required. Assess any POPIA prior-authorisation requirements separately.
- [ ] Complete, approve and make available the organisation-wide [PAIA manual draft](paia-manual-draft.md), including verified legislation, records and procedures.
- [ ] Verify request-mail delivery, handler training, deadlines, delegated access and approved request-record retention.
- [ ] Approve actual provider contracts, transfer safeguards, retention and deletion/backup handling; amend public disclosures if actual facts differ.
- [ ] Confirm each telephone service's recording/confidentiality, marketing, emergency and accessibility obligations in its operating countries.
- [ ] Reassess the website before adding trackers, third-party embeds, paid sales, direct marketing or user-hosted content.

Do not mark these complete based solely on software tests or publication of a policy.
