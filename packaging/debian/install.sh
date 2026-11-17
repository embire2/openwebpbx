#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
usage() {
  cat <<'HELP'
OpenWeb PBX — full standalone installer for Debian 13 amd64

No earlier OpenWeb PBX installation is required. This complete release sets up
the calling engine, local PostgreSQL database, administration and updater.
It needs root access, a clean Debian 13 server and an Internet connection.

Install:
  ./install.sh --bootstrap-registration --address YOUR_PUBLIC_IP --email admin@example.com --stun

Check the complete package and new-server requirements without installing:
  ./install.sh --check

Show this help without changing the server:
  ./install.sh --help

Existing PBXs use their Updates page so their accounts, phones and recordings
are preserved. The fresh installer will not overwrite an existing server.
HELP
}
prepare_installer_python() {
  if command -v python3 >/dev/null 2>&1; then return 0; fi
  if "$check_only"; then
    echo 'Python 3 is not available for the full check. The normal installer prepares it automatically; --check has not installed or changed anything.' >&2
    return 1
  fi
  echo 'Preparing the Debian Python component for this full installer...'
  apt-get update
  apt-get install -y python3
  installer_apt_updated=true
  if ! command -v python3 >/dev/null 2>&1; then
    echo 'Debian Python setup did not complete. No PBX services or data have been installed.' >&2
    return 1
  fi
}
check_requested=false
for argument in "$@"; do
  if [[ "$argument" == --help || "$argument" == -h ]]; then usage; exit 0; fi
  if [[ "$argument" == --check ]]; then check_requested=true; fi
done
if [[ $# == 0 ]]; then usage; exit 2; fi
check_only=false
if "$check_requested"; then
  if [[ $# != 1 ]]; then echo 'Use --check on its own; it does not install or change anything.' >&2; exit 1; fi
  check_only=true
fi
if [[ $EUID != 0 ]]; then echo 'Run this installer as root.' >&2; exit 1; fi
source /etc/os-release
if [[ "${ID:-}" != debian || "${VERSION_ID:-}" != 13 || "$(dpkg --print-architecture)" != amd64 ]]; then echo 'This full installer requires Debian 13, 64-bit Intel/AMD. No earlier PBX is required.' >&2; exit 1; fi
for installed in /etc/fusionpbx/config.conf /var/www/fusionpbx/resources/require.php /etc/openwebpbx/runtime.json /opt/openwebpbx/service/OpenWebPbx.Server /opt/openwebpbx/updater/current /var/lib/openwebpbx/updates/install-journal.json; do
  if [[ -e "$installed" || -L "$installed" ]]; then echo 'An existing PBX or recovery state is present. This fresh installer will not overwrite it. Use that server’s Updates page to preserve accounts, phones and recordings.' >&2; exit 1; fi
done
if [[ ! -f install-check.py ]]; then echo 'Extract the complete standalone Debian release package first.' >&2; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
installer_apt_updated=false
prepare_installer_python
python3 -B ./install-check.py
if "$check_only"; then
  echo 'New-server checks passed. Nothing was installed or changed.'
  exit 0
fi
echo 'Setting up the built-in database on this server for all tenants...'
if [[ "$installer_apt_updated" != true ]]; then apt-get update; fi
mapfile -t engine_packages < engine-dependencies.txt
apt-get install -y nginx postgresql php8.4-fpm php8.4-cli php8.4-pgsql php8.4-sqlite3 php8.4-curl php8.4-mbstring php8.4-xml php8.4-zip php8.4-gd php8.4-intl php8.4-opcache ca-certificates curl zip openssl python3 python3-cryptography openssh-client sox certbot fail2ban libicu76 "${engine_packages[@]}"
python3 ./configure.py "$@"
echo "OpenWeb PBX $(cat VERSION) installation finished."
echo 'All tenants share this installation’s built-in database. No separate database server is required.'
echo 'Finish the registration wizard to activate this server. Phones and calling stay unavailable until registration and its secure tenant address are ready.'
