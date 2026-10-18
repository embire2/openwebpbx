#!/usr/bin/env python3
"""Install the global queue on fresh servers without replacing local services."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

UNIT = Path('/etc/systemd/system/email_queue.service')
LINK = Path('/etc/systemd/system/multi-user.target.wants/email_queue.service')
HOLD = Path('/var/lib/openwebpbx/backup-restore/hold-email_queue.service')
CONTENT = '''# OpenWeb PBX managed global outgoing mail queue, revision 1
[Unit]
Description=OpenWeb PBX global outgoing mail
Wants=network-online.target
After=network-online.target postgresql.service
ConditionPathExists=/etc/fusionpbx/config.conf
ConditionPathExists=!/var/lib/openwebpbx/backup-restore/hold-email_queue.service
[Service]
WorkingDirectory=/var/www/fusionpbx
ExecStart=/usr/bin/php /var/www/fusionpbx/app/email_queue/resources/service/email_queue.php
User=www-data
Group=www-data
RuntimeDirectory=fusionpbx
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
Restart=always
RestartSec=10
TimeoutStopSec=55
UMask=0077
[Install]
WantedBy=multi-user.target
'''


def targets():
    # Existing units and their enabled/disabled choice belong to the installer.
    return [path for path in (UNIT, LINK) if not path.exists() and not path.is_symlink()]


def install(activate=False):
    if os.geteuid() != 0:
        raise PermissionError('The outgoing mail installer must run as root.')
    if UNIT.is_symlink() or any(parent.is_symlink() for parent in UNIT.parents):
        raise ValueError('The existing outgoing mail service needs administrator review.')
    if not UNIT.exists():
        loaded = subprocess.check_output(['systemctl', 'show', 'email_queue.service',
                                         '--property=LoadState', '--value'], text=True).strip()
        if loaded not in ('', 'not-found'):
            return  # Preserve a distro/vendor/custom service outside /etc.
        UNIT.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=UNIT.parent, prefix='.mail-unit-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(CONTENT.encode()); stream.flush(); os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, UNIT)
        descriptor = os.open(UNIT.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        subprocess.run(['systemctl', 'daemon-reload'], check=True, timeout=60)
        subprocess.run(['systemctl', 'enable', 'email_queue.service'], check=True, timeout=60)
    elif not UNIT.is_file() or UNIT.read_text() != CONTENT:
        return  # No replacement or change to an existing operator service.
    enabled = subprocess.run(['systemctl', 'is-enabled', '--quiet', 'email_queue.service'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if activate and enabled and not HOLD.exists():
        subprocess.run(['systemctl', 'start', 'email_queue.service'], check=True, timeout=60)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--activate', action='store_true')
    args = parser.parse_args()
    install(args.activate)
