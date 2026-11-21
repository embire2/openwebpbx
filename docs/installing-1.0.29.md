# Install OpenWeb PBX 1.0.29 on Debian 13

Install 1.0.29 directly on a clean Debian 13 amd64 machine. The standalone
archive includes the PBX application, calling engine, local PostgreSQL setup,
updater and system prompts. Use a root shell and a reachable public IP address. The installer
uses the internet for Debian packages and tenant registration.

## Install a new server

1. Download the [complete archive](https://github.com/embire2/openwebpbx/releases/download/v1.0.29/openwebpbx-1.0.29-debian13-amd64.tar.gz)
   and [SHA256SUMS](https://github.com/embire2/openwebpbx/releases/download/debian-v1.0.29/SHA256SUMS)
   into the same empty private directory. Verify and extract the package.

   ```sh
   sha256sum --ignore-missing -c SHA256SUMS
   tar -xzf openwebpbx-1.0.29-debian13-amd64.tar.gz
   cd openwebpbx-1.0.29-debian13-amd64
   ./install.sh --check
   ```

   The read-only check is optional. On a minimal image that lacks Python 3,
   the normal installer installs it as part of setup.

2. Start the installation with your public address and account email.

   ```sh
   ./install.sh --bootstrap-registration --address YOUR_PUBLIC_IP --email admin@example.com --stun
   ```

3. Choose a local administrator password and open the registration link
   printed by the installer. Verify your email, enter your company details
   and choose an available `company.openwebpbx.com` address. When setup
   confirms secure access, open that address and sign in with your local
   administrator account to finish **Create my PBX**.

## Upgrade an existing server

Use **Admin → System → Updates** with installed Debian **1.0.27 or newer**
for this signed release. The updater verifies the archive, waits for idle calls
and seals a recovery checkpoint before applying it. Keep an encrypted backup
separately. For a clean machine, use the installation steps above.
[Update and recovery guide](updates.md)

On **First Calls**, record the result of each pilot call while the result is
fresh. Review the displayed blockers before moving any numbers.
[Calling guide](core-calling.md)
