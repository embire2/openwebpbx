# Microsoft Store submission packet — Windows Phone 1.0.0

This is a preparation guide, checked **23 October 2026** against Microsoft's [Store policies 7.20, effective 22 October 2026](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies). It is not a certification result. The Windows client, PBX server and Android app have independent versions. No Store account, product reservation, publisher identity, signed release or submission has been verified for this client.

## 1. Owner identity and product reservation

The project uses **Open ISP cc** as its company name. That does not establish its Microsoft seller account or package identity. The authorised owner must complete Partner Center company verification and reserve **OpenWebPBX Free Phone**, subject to availability. Microsoft's [company account instructions](https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/open-a-developer-account?tabs=company) describe the identity/business steps and accept official business documents when a D‑U‑N‑S number is unavailable. Do not publish registration documents in GitHub.

The owner requested account-creation steps; no existing account identity has been supplied:

1. Open [Microsoft's developer registration](https://storedeveloper.microsoft.com/) and sign in with a Microsoft account or Microsoft Entra work account controlled by the organisation. Keep its credentials and recovery methods private; enable multifactor authentication.
2. Choose **Get started → Company account**. Microsoft currently offers this new company onboarding route free of charge. Select the real country/region carefully; Microsoft says it cannot be changed later.
3. Enter the exact registered business name and matching address/contact details. Use the authorised person's work email for verification. The product's development publisher string is not a substitute for this information.
4. Supply the company's D‑U‑N‑S number if available, or use the offered official business-document verification route. Follow the current document and domain-verification requests shown by Microsoft; do not invent a D‑U‑N‑S number.
5. Accept the agreement personally and complete the email, business, relationship and due-diligence checks shown on the Verification summary. Account creation and document upload do not mean verification has passed.
6. After the account is verified, open Apps & Games, reserve the app name, and copy the resulting product identity fields below. If blocked, use the account's private support channel. No account creation, reservation or Store action has been performed by this project work.

Record these values privately from **Partner Center → Product identity**, then give the non-secret package values to the maintainer:

| Field | Current state |
|---|---|
| Verified seller and country | Owner must confirm |
| Reserved product name and Store ID | Not obtained |
| Package/Identity/Name | Not obtained |
| Package/Identity/Publisher | Not obtained; `CN=Open ISP cc` in development source is a placeholder |
| PublisherDisplayName / package family | Must match Partner Center |
| Customer support website/email | Owner must confirm the monitored contact |
| Release visibility and publication date | Owner decision; keep unpublished until acceptance |

Copy the values exactly; do not derive a Publisher ID from the company name. See [Microsoft's identity fields](https://learn.microsoft.com/en-us/windows/apps/publish/view-app-identity-details). The development manifest is not evidence that MakeAppx or Partner Center accepts the final package.

## 2. Candidate and listing packet

Use a **Windows 11 x64 MSIX submission**. Windows Server 2025 uses the separate direct-download route in [DISTRIBUTION.md](DISTRIBUTION.md), not a promise of Store availability on Server. Microsoft's [MSIX upload guide](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/upload-app-packages) lists accepted package/upload formats; use the actual build's validated `.msixupload` or supported package output. Microsoft signs accepted MSIX submissions; local test signing is not Store certification. See [publishing steps](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/publish-first-app).

Prepare one private release record with the exact commit, client version, package SHA256/size, resolved SDK/NuGet/native-library hashes, manifest identity/capabilities, corresponding-source asset and test receipts. Upload the exact tested artifact. Keep signing keys and test passwords outside the source, package and screenshots.

The **first sentence** of the proposed description must disclose its server/account dependency:

> Requires an existing OpenWebPBX tenant, extension and administrator-issued app password. Connect to your organisation's phone service from Windows.

This is draft copy. Add only features demonstrated by the submitted build. Do not advertise complete 3CX compatibility, emergency calling, physical-camera support or background incoming calls from source presence alone. Explain any service/provider charges, required connectivity and limitations. Native desktop calling must remain native; this is not a website wrapper. Choose a category and age-rating answers that match the actual communications features, as described in [MSIX app properties](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/enter-app-properties).

Include these public links in the listing and the app's accessible Settings/About area:

- Privacy: https://openwebpbx.com/privacy
- Terms: https://openwebpbx.com/terms
- Account/data deletion: https://openwebpbx.com/delete
- Source/licences: the actual versioned corresponding-source download, once created.

These are the project's intended URLs, not a new website audit. Before submission, verify trusted HTTPS, public access without login, keyboard accessibility and that their contents cover this Windows client's actual data flows. Describe tenant/account identifiers, device enrolments, call history, directory, voicemail, microphone/camera, local protected profiles, diagnostics, server operators and retention/deletion. Removing a local profile must not be described as deleting the tenant's server records.

## 3. Capability justification and privacy behaviour

Use only capabilities required by the final build. [Microsoft's capability guide](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations) explains full-trust desktop and privacy-sensitive declarations. General capabilities must precede device capabilities in the manifest. Run the real package validator after editing it.

| Declaration currently proposed | Certification explanation to verify against the final build |
|---|---|
| `runFullTrust` | Native WinUI desktop process and bundled Liblinphone media/device integration at normal user privilege; no administrator elevation or PBX service installation |
| `microphone` | Voice calls after user action; mute and device choice; clear denied/unavailable-device behaviour |
| `webcam` | Optional video and camera setup scanning; user-controlled enable/disable and audio-only fallback |
| `internetClientServer` | Tenant HTTPS/API and native calling connectivity; justify both directions actually used |
| `privateNetworkClientServer` | Only if actual supported local-network calling requires it; remove if unused |

Explain restricted-capability use in the submission rather than claiming approval. A declaration does not prove Windows has granted access. Test Windows privacy settings with access enabled and disabled, hot-unplug, locked/background windows, camera-off indication and no unintended capture. Do not add broad file-system, contacts, startup or administrator capabilities for convenience.

## 4. Private notes for certification

Microsoft requires a usable test account and operational server for login-dependent review. Its [Notes for certification guide](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/faqs/notifications) explains the private tester channel. Put real reviewer credentials there only: never in this repository, listing, release asset or screenshots. Keep the isolated review tenant available for the entire review, with no customer data or live carrier destination.

Fill this template in Partner Center; placeholders are not working credentials:

```text
Build / package SHA256: <actual submitted build>
Review tenant HTTPS address: <isolated valid tenant address>
Account A extension and app password: <private review-only values>
Account B / second-device setup: <private review-only values>
Sign in: enter tenant address, extension, app password; no QR code required.
Audio test: <controlled internal echo/second-party steps and expected result>
Incoming call / hold / resume / voicemail: <actual build-specific steps>
Video test and audio-only fallback: <actual supported steps>
Background/tray behaviour: <precise supported behaviour and how to stop it>
Privacy and deletion: Settings/About links; <actual account deletion steps>
Permission refusal / offline recovery: <actual expected behaviour>
No PSTN/emergency/customer calls are required for review.
Support and review dates: <monitored private contact and availability>
```

Use reusable manual credentials in addition to any short-lived invitation. Do not provide only an expired one-use QR code or an app that requires a reviewer to contact sales. If two endpoints are needed for meaningful review, provide both and explain how to test them.

## 5. Acceptance and assets before upload

Every unchecked item below is pending; no item may be marked passed merely because code exists.

- [ ] Correct Partner Center identity; final schema/MakeAppx validation; exact MSIX install, launch, update and uninstall under an ordinary user on a clean supported Windows 11 machine.
- [ ] Actual responsive client window. Native SIP registration, answered two-way decoded audio, hold/music/resume, incoming calls and advertised video/device flows have separate receipts. Server-side tests do not qualify this client.
- [ ] Tenant login, safe invitation/file activation, profile isolation/removal, password change/revocation, reconnect, offline errors and normal-user protected storage tested with the actual backend build intended for review.
- [ ] Store build has no direct client/server/Android self-updater. Upgrade while idle and during an active call is tested; policies do not promise that the app can override Store or enterprise scheduling.
- [ ] Complete third-party licences, exact corresponding-source/build bundle and final Store distribution terms reviewed; [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records the remaining source-closure blocker.
- [ ] CPU/RAM/disk minimums measured on the final package. Current target is x64 and manifest OS floor `10.0.22000.0`; this is not a measured performance minimum or an ARM64/x86/Windows 10 support claim. Microphone plus audio output are needed for voice; a camera is optional for video. Internet and a functioning tenant are required.
- [ ] Keyboard-only login/dial/answer/hold/end/settings, visible focus, Narrator names/states, text scaling, high contrast and light/dark layouts verified. Follow [Microsoft's accessibility testing](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-testing); claim accessibility in the Store only after actual testing.
- [ ] Run the Windows App Certification Kit on the final submission artifact and review its report alongside manual tests. A clean WACK report does not guarantee Store approval.
- [ ] Capture real, fictional-data screenshots of the final app: sign-in, dialpad, active/held call, directory/history, settings and supported video. Microsoft requires a screenshot per supported device family and recommends 5–8; desktop images should be at least 1366×768. Follow the current [screenshot requirements](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/screenshots-and-images). Remove tokens, numbers and personal desktop information; do not use generated mockups as product evidence.

The retained probe `39957178477` proves a pinned SDK inventory and an official-template build only. Its actual calling and Store flags are false; launch was pending. Pure core checks and a template build are not an integrated-client, hardware or certification pass. Add later genuine client receipts with their own exact source/build scope.

## Owner's final steps

1. Sign into the verified company Partner Center account, reserve the product and send its identity values to the maintainer. Complete any requested business verification personally.
2. Confirm the public support contact, legal URLs, territories, rating answers and draft listing. Supply private reviewer accounts for the isolated tenant.
3. Review the maintainer's exact signed/package/source/test packet and final screenshots. Resolve every pending acceptance item above.
4. Upload that exact package, paste the private certification notes, select manual publication after certification, and submit.
5. Address actual certification findings, then authorise publication of the accepted build. No approval date or outcome is guaranteed by this guide.
