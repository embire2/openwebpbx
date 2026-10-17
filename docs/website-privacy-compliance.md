# Website privacy and legal work — 17 October 2026

Scope: `https://openwebpbx.com`, its public policy pages and the disclosures for **OpenWebPBX Free Phone**. This is an implementation and outstanding-actions record, not a finding that every Open ISP cc activity complies with every applicable law. Independent PBX operators remain responsible for their own deployments.

The owner supplied **Open ISP cc**, registration **2005/156968/23**, and the business address **22 Ladlau Drive, Simbithi Eco-Estate, Ballito, 4399, South Africa**. The owner appointed **Leon Whitherall** as Information Officer, contact **hello@openwebpbx.com**, **+27 87 350 8601**. These are owner-provided details; a registry search and Information Regulator registration certificate have not been verified. Keoma Wright was identified as CEO & Founder.

## Findings and changes

| Area | Finding | Implementation / remaining requirement |
|---|---|---|
| Browser storage | No advertising, analytics or external tracking scripts were found. The old site saved appearance without a privacy choice. | Appearance storage now requires an affirmative choice. Equally styled Accept optional / Reject optional controls, an initially unticked setting, withdrawal on every page, expiry and cross-tab handling are implemented. Necessary choice storage lasts 180 days; no optional theme read/write is allowed before consent. |
| Transparency | The previous notice did not give sufficient purpose, ground, rights, recipient, retention or company/contact detail. | `/privacy` now covers website, app and OpenWeb-operated services; differentiates independent PBX operators; describes purposes, lawful grounds, sources, recipients, transfers, retention criteria and rights. Actual provider arrangements and retention must be verified against it. |
| Company disclosure | Registration number and Information Officer were absent. | `/legal`, `/terms`, `/privacy` and rights/access pages identify the supplied company and contacts. No claim of registered charity or tax exemption is made. |
| Privacy requests | Deletion instructions existed; broader rights and complaint procedures were missing. | `/privacy-rights` gives email/phone/postal routes, proportionate verification, GDPR timing, PAIA access timing and regulator links. `/delete` remains public with no login/install requirement. Actual email receipt and operational request handling still need confirmation. |
| POPIA/PAIA | Website wording alone does not complete organisational duties. | `/paia` is a public access guide. [Organisation manual draft](paia-manual-draft.md) is prepared for the head/Information Officer to verify, approve and publish. It is deliberately not represented as an approved statutory manual. |
| EU representative | The owner nominated Leon, but supplied only a South African address. | Publish him as Information Officer/privacy contact. Do not claim Article 27 appointment is complete. If Article 27 applies, confirm an establishment in a relevant EU Member State and written mandate, then publish its details. A response requesting the EU country/address is pending. |
| Accessibility | Existing pages have responsive text and keyboard controls; no independent conformity assessment exists. | `/accessibility` gives assistance/reporting contacts. Browser layout and consent-keyboard checks are functional evidence, not WCAG/EAA certification. Assess service-specific EU accessibility duties separately. |

## Applicability and limits

GDPR applicability depends on the processing, EU establishment, offering services to people in the EU, or monitoring their behaviour. A public website being reachable in Europe does not by itself decide every territorial question. The implementation adopts privacy controls without assuming a blanket territorial exemption. Assess each OpenWeb-operated service and its controller/processor roles.

EU ePrivacy rules cover storage/access on users' devices, including local storage. This site currently has no analytics/advertising category to accept. New trackers, embeds or marketing require a fresh purpose/vendor assessment and appropriately specific prior consent; the current appearance consent cannot authorise them. Do not add a blocking cookie wall or treat scrolling as agreement.

The reviewed public site distributes free software and information, with no online checkout or user-posting facility. A future paid service, consumer contract, marketplace or hosting/intermediary function needs its own EU consumer/e-commerce/DSA applicability assessment and service terms. Do not assume that being free/open source removes GDPR, POPIA or communications obligations.

EU accessibility requirements have applied to covered products/services since 28 June 2025, including electronic communications and e-commerce. Assess the actual service offered, national implementation and any lawful exception; the supplied approximate 200-employee count does not support assuming the microenterprise exemption. An accessibility contact page alone does not satisfy all service/product requirements. Telecom authorisation, emergency access/location, confidentiality and recording rules require a separate country/service assessment before offering regulated telephony.

South Africa's POPIA applies to covered processing, with PAIA access/manual requirements and conditional ECTA disclosures/consumer rules. This work does not establish company-wide compliance, a lawful recording basis for each tenant, overseas transfer safeguards, or a completed operator contract.

## Outstanding owner and operational work

Follow [Privacy operations](privacy-operations.md). Highest-priority unresolved items:

1. Verify Leon's written appointment/delegation and existing Information Regulator registration, or complete the required registration. Being named on the website is not registration.
2. Supply the EU country and establishment address for the proposed Article 27 representative, execute a written mandate where required, and publish verified details. If relying on an exemption, document the actual assessment.
3. Confirm the supplied business address is current; verify the complete organisation record inventory, applicable statutes, procedures, fees, contact details and PAIA manual approval/public availability.
4. Confirm mailbox delivery and assign trained people to acknowledge, verify, track and answer requests. No message was sent during technical website checks.
5. Verify hosting/mail/support/notification/telephony providers, locations, processing agreements and international-transfer safeguards. Approve actual retention periods and execute deletion, backup-expiry and restore-suppression procedures.
6. Maintain processing records, legitimate-interest assessments, access/security controls, incident handling and required DPIA/DPO assessments for the actual services. Confirm recording notices/consent and marketing permissions separately.

## Technical verification

Evidence is retained outside the repository and web roots under `/var/lib/openwebpbx/eu-popia-20261017/`; browser screenshots are under `output/playwright/eu-popia-20261017/`. The final deployment/browser outcome is recorded in [the website README](../website/README.md). Credentials, API replies, original hosting configuration and backups remain private. DNS, email settings, app/core release assets and update requirements are outside this website change.

## Primary sources reviewed

- [EU device-storage/cookie guidance](https://europa.eu/youreurope/business/growing/digitalising/online-privacy/index_en.htm) and [EDPB Cookie Banner Taskforce report](https://www.edpb.europa.eu/system/files/2023-01/edpb_20230118_report_cookie_banner_taskforce_en.pdf).
- [GDPR official text](https://eur-lex.europa.eu/legal-content/EN/TXT/?qid=1463250435964&uri=CELEX%3A32016R0679), especially Articles 3, 5–6, 12–14, 15–22, 27–30, 32–37 and 44 onwards; [Commission individual-rights information](https://commission.europa.eu/law/law-topic/data-protection/information-individuals_en).
- [EU business website guidance](https://europa.eu/youreurope/business/running-business/digitalising/setting-up-business-website/indexamp_en.htm); [EU accessibility requirements](https://europa.eu/youreurope/business/selling-in-eu/selling-goods-services/accessibility/index_en.htm); [EU electronic communications framework](https://digital-strategy.ec.europa.eu/en/policies/eu-electronic-communications-code).
- [POPIA official Act](https://www.gov.za/sites/default/files/gcis_document/201409/3706726-11act4of2013popi.pdf), notably sections 14, 18–22, 23–25, 55 and 72; [Information Officer guidance](https://inforegulator.org.za/wp-content/uploads/2020/07/InfoRegSA-GuidanceNote-IO-DIO-20210401.pdf).
- [Regulator PAIA guidance and templates](https://inforegulator.org.za/paia-guidelines/), [private-body manual template](https://inforegulator.org.za/wp-content/uploads/2020/07/PAIA-Manual-Template-Private-Body.pdf), [POPIA forms](https://inforegulator.org.za/popia-forms/) and [official eServices](https://eservices.inforegulator.org.za/services.aspx).
- [ECTA official publication and amendments](https://www.gov.za/documents/electronic-communications-and-transactions-act).
