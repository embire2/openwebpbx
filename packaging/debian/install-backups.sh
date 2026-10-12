#!/usr/bin/env bash
# Install the instance-only backup worker from this reviewed Debian package.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ $EUID != 0 ]]; then echo 'Run this installer as root.' >&2; exit 1; fi
source /etc/os-release
if [[ "$ID" != debian || "$VERSION_ID" != 13 ]]; then echo 'This backup worker requires Debian 13.' >&2; exit 1; fi
if [[ ! -f /etc/fusionpbx/config.conf || ! -f /var/www/fusionpbx/app/pbx_backups/resources/install.sql ]]; then echo 'Install the corresponding OpenWeb PBX application first.' >&2; exit 1; fi
python3 -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM'
for tool in psql pg_dump pg_restore sftp ssh-keygen; do command -v "$tool" >/dev/null; done
install -d -m 755 /opt/openwebpbx/tools
install -d -o root -g root -m 700 /var/backups/openwebpbx/automatic
install -d -o root -g www-data -m 750 /var/lib/openwebpbx/backup-downloads
install -m 644 backups.py /opt/openwebpbx/tools/backups.py
install -m 644 openwebpbx-backups.service openwebpbx-backups.timer /etc/systemd/system/
php -r 'require "/var/www/fusionpbx/resources/require.php"; database::new()->db->exec(file_get_contents("/var/www/fusionpbx/app/pbx_backups/resources/install.sql"));'
systemctl daemon-reload
if [[ "${OPENWEB_BACKUP_START:-1}" == 0 ]]; then
  systemctl enable openwebpbx-backups.timer
else
  systemctl enable --now openwebpbx-backups.timer
fi
echo 'The backup worker is installed. In Backups, save a password and choose your schedule.'
