# Android tenant addresses — 1.0.18

OpenWebPBX Free Phone 1.0.18 / code118 requires a centrally registered HTTPS tenant address under `*.openwebpbx.com`. Existing saved accounts must each confirm their tenant address once before they can reconnect. For the hosted OpenWeb tenant, enter **https://openweb.openwebpbx.com**. Use the portal address, without `/admin` or another path.

Install over the existing app; do not uninstall first. Open the app, enter the address and choose **Confirm tenant address**. Your saved phone credentials, extension, account and personal preferences are retained. Repeat for each saved account. Accounts that have not been confirmed cannot register for calls, register incoming notifications or use their saved access tokens. You can remove an unwanted unconfirmed account locally.

The app accepts one tenant label, HTTPS and the standard HTTPS port. Other domains, IP addresses, nested names, lookalike suffixes, insecure URLs and URL credentials are refused. Before moving an existing token, it checks the address against `domains.openwebpbx.com` and verifies that it belongs to the original PBX. The tenant API then checks the account's own tenant. A wrong tenant cannot claim another account. If the address belongs to a different installation, use a new QR code from that installation after entering its tenant address.

This restriction applies to Android account connections. Existing SIP desk-phone hosts, authentication names, passwords, SIP realms, registrations and routing do not change. The PBX continues to supply the app's protected SIP/media settings; users do not edit those settings.

New QR codes use the tenant address. This release requires a ready tenant lease, trusted HTTPS, the registry lookup and the tenant-bound phone API. Those services are activated on the hosted instance. Stock Debian1.0.16 installations must prepare tenant-address support before moving their phones to this release; installing the APK alone does not create a tenant address. App-password sign-in is shown only when the server supports it; the narrow hosted16 patch continues to use QR enrollment.

## Mandatory rollout and separate feeds

The owner selected a mandatory rollout for all current and future directly installed Android phones on this instance. The minimum is set only after complete public APK and signed-feed verification. Android still controls installation permission/confirmation and reopening. Current calls finish before replacement. Google Play publication and approval remain separate.

Android retains `update-manifest.json`. Debian uses the separate `debian-update-manifest.json`, carrying the existing signed1.0.16 release unchanged. This Android release does not publish a new full Debian or Windows installer. Existing Debian16 update workers need the compatibility patch described in the release notes before the shared latest-release pointer moves; the hosted worker is patched and checked first. Other unpatched Debian workers will refuse the Android-only generic feed rather than install an incompatible package.

## Verification

Both direct and Play variants passed36/40 JVM checks and zero-error lint (84/74 release warnings remain). The unchanged release signing identity is `449740f6858cb092a0f67d9d79d2505a8d6e7e4d4c1a52a8eaed9b895e48e69d`. The actual published116 APK enrolled through its ordinary UI, then the signed118 APK replaced it with app data retained. Native Android13 checks exercised mandatory entry, rejected old/lookalike domains, no pending SDK accounts, real custodian HTTPS lookup, real tenant HTTPS rebinding and unchanged token/device/SIP credentials/preferences. A subsequent TLS/SRTP call between two owned test extensions passed packet checks and decoded independent audio in both directions; Android's received660Hz energy ratio was0.99983264 and the peer's440Hz ratio passed the0.8 threshold.

The first test setup stopped at an ungranted Bluetooth prompt. An instrumentation thread then caused a Linphone lock-order deadlock; SDK inspection moved onto its UI thread. Its abandoned owned test call was explicitly ended before repeating; no customer call was ended. A later completed call's first WAV collection was denied to the Android shell; root collection of that exact owned recording passed. These failures remain in private evidence and are not counted as successful product tests. Physical handsets, cameras, mobile networks and Google Play track acceptance are not established by these software tests.

Customer data, original media and desk-phone credentials are checked separately. Wider133/21/72/40 roadmap acceptance counts remain unchanged. Private configuration, enrollment codes, tokens, customer inventories and raw logs are excluded from public artifacts.
