#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ $EUID != 0 ]]; then echo 'Run this installer as root.' >&2; exit 1; fi
source /etc/os-release
if [[ "$ID" != debian || "$VERSION_ID" != 13 || "$(dpkg --print-architecture)" != amd64 ]]; then echo 'This package requires Debian 13, 64-bit Intel/AMD.' >&2; exit 1; fi
if [[ -e /etc/fusionpbx/config.conf || -e /var/www/fusionpbx/resources/require.php ]]; then echo 'A PBX already exists. Back it up and use the documented upgrade procedure.' >&2; exit 1; fi
if [[ ! -f web/resources/require.php || ! -x server/OpenWebPbx.Server || ! -f engine.tar.gz ]]; then echo 'Extract the complete Debian release package first.' >&2; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
echo 'Setting up the built-in database on this server for all tenants...'
apt-get update
mapfile -t engine_packages < engine-dependencies.txt
apt-get install -y nginx postgresql php8.4-fpm php8.4-cli php8.4-pgsql php8.4-sqlite3 php8.4-curl php8.4-mbstring php8.4-xml php8.4-zip php8.4-gd php8.4-intl php8.4-opcache ca-certificates curl zip openssl python3 fail2ban libicu76 "${engine_packages[@]}"
python3 ./configure.py "$@"
echo "OpenWeb PBX $(cat VERSION) installation finished."
echo 'All tenants share this installation’s built-in database. No separate database server is required.'
