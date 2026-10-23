# Windows Free Phone integration

This is the PBX integration for the native **OpenWebPBX Free Phone 1.0.0**
client. The client is still under development; this document does not announce
a downloadable Windows phone or a complete Windows Server release.

Windows accounts use the existing tenant address, one-use welcome configuration
file or QR code, and extension/app-password sign-in. Each device gets its own SIP
credentials. Restored desk-phone credentials remain separate. Existing Android
devices and sign-in defaults are preserved.

The mobile schema migration admits Android and Windows devices together. It
checks the existing platform rule and database namespace before changing them,
preserves device rows and table permissions, and refuses unknown/custom rules.
Both app types share the existing limit of ten active devices per extension.
Windows connections require the account's managed tenant address; Android's
existing legacy setup transport is preserved.

Tenant owners can open **Updates → Windows phone updates** to choose whether
users are notified, downloads happen automatically, or an available update is
required. Instance administrators control the minimum accepted Windows phone
release. These settings use their own policy table and component channel;
Android and PBX server update requirements are unchanged. Microsoft Store and
direct installations retain their separate delivery mechanisms.

No client release is currently registered by this integration. The API reports
`release_available=false` with empty release/minimum versions. A verified,
data-driven release catalogue must be connected before publishing the client;
the dedicated `windows-phone-stable` channel must not depend on the repository's
generic latest PBX release.

Actual isolated PostgreSQL/PHP checks cover 51 admission/migration cases and
49 policy, permission, CSRF and API cases. The existing 51 Android password,
device, invitation and welcome checks also pass. Root independently repeats all
151 against the integrated source. Configuration, cache/ESL and test-published
metadata adapters are explicit. These checks do not prove native Windows
calling, physical audio/video, inbox delivery or Store certification.

Fresh server installation, upgrade, restore and the native client tests remain
required before release. Existing public releases remain unchanged.
