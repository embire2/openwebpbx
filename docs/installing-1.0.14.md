# OpenWeb PBX 1.0.14 candidate

This candidate adds automatic user extensions and department-routing controls. The Android app is named **OpenWebPBX Free Phone**, version **1.0.14 / code 114**. Existing application identity and release signing identity are retained.

The published Debian/Android baseline is **1.0.12**. Candidate builds are not yet advertised through the public update feed. Installation, installed-upgrade, recovery and exact-artifact checks must finish before publication or deployment.

The supported release target is **Debian 13 amd64**, with local PostgreSQL shared by the instance's tenants. The installation and update workflow is described in the [1.0.12 installation guide](installing-1.0.12.md); use matching qualified downloads when 1.0.14 is published. Do not substitute a private test feed or label an earlier archive as 1.0.14.

See [Users, departments and call routing](users-and-departments.md) for the new controls and their limits. Android setup still uses the extension's one-use QR code under **Users → Phone Provisioning**; its application ID remains `com.openweb.pbx`, allowing an ordinary account-preserving upgrade.

The separate Windows 1.0.13 package remains frozen at its recorded qualified source. Its original-server migration/upgrade and public release remain open under the [Windows release plan](../3CX.md#windows-1013-release-plan). This candidate does not qualify a new Windows package.
