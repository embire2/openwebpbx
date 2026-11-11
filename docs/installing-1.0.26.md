# Debian 1.0.26 bundle

This bundle contains administration/personal API 2.1, matching native Core/updater
1.0.26 and the existing complete Debian server components, including offline Keoma
prompts. [Feature and verification record](api-1.0.26.md).

The hosted installation is live. This bundle is a **local release candidate**;
fresh install, signed upgrade and rollback require separate package qualification.
It is not advertised as a qualified public upgrade. Public downloads and signed
feeds continue to point to 1.0.23. Do not run the fresh installer over an existing PBX.

For controlled fresh-install qualification only, use a clean Debian 13 amd64
machine with its own reachable address. Verify the operator-supplied checksum,
extract into a private directory, then as root:

```sh
cd openwebpbx-1.0.26-debian13-amd64
./install.sh --bootstrap-registration --address YOUR_PUBLIC_IP --email admin@example.com --stun
```

Choose a local administrator password and follow the printed setup link to the
normal [registration wizard](https://openwebpbx.com/wizard), verify email, and
register the tenant address. The local PBX/database stay on that machine.
`--stun` provides UDP 3478 STUN, not TURN. Test internal and provider calls before
moving live service. Preserve current phone credentials, QR codes, media and routes
during any separately qualified upgrade.

After setup, Tenant Admin and PBX Administration link to **API Keys** and
**API Documentation**. The installation API uses `https://YOUR_HOST/api/v2`.
The public `openwebpbx.com` gateway manages the hosted installation, not an
arbitrary self-hosted server. Personal access requires an enabled Staff Access
assignment linked to the extension.
