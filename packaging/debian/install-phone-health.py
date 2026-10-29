#!/usr/bin/env python3
"""Stage the Debian health observer; preserve custom and disabled unit choices."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

PACKAGE = Path(__file__).resolve().parent
TOOLS = Path('/opt/openwebpbx/tools')
UNIT = Path('/etc/systemd/system/openwebpbx-phone-health.service')
TIMER = Path('/etc/systemd/system/openwebpbx-phone-health.timer')
LINKS = [Path('/etc/systemd/system/timers.target.wants/openwebpbx-phone-health.timer'),
         Path('/etc/systemd/system/openwebpbx-updater.service.wants/openwebpbx-phone-health.timer')]
MAINTENANCE = Path('/var/lib/openwebpbx/updates/maintenance')
RESTORE_HOLD = Path('/var/lib/openwebpbx/backup-restore/hold-openwebpbx.service')
PROGRAMS = ('phone-health.py', 'phone-health.php', 'install-phone-health.py')
HEADER = b'# OpenWeb PBX managed Phone Health v1\n'


def ordinary(path):
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError('Review linked Phone Health installation paths.')
    if path.exists() and not path.is_file():
        raise ValueError('Phone Health requires ordinary files.')


def targets():
    # Existing enablement links are never replaced or removed by installation.
    return [*[TOOLS / name for name in PROGRAMS], UNIT, TIMER,
            *[path for path in LINKS if not path.exists() and not path.is_symlink()]]


def protected(path):
    ordinary(path)
    for item in (path, *path.parents):
        status = item.stat()
        if status.st_uid != 0 or status.st_mode & 0o022:
            raise ValueError('Protected installed Phone Health inputs required.')
    if not stat.S_ISREG(path.stat().st_mode):
        raise ValueError('Protected installed Phone Health inputs required.')


def write(path, content):
    ordinary(path)
    for item in (path, *path.parents):
        if item.exists():
            status = item.stat()
            if status.st_uid != 0 or status.st_mode & 0o022:
                raise ValueError('Protected Phone Health installation paths required.')
    if path.exists() and path.read_bytes() == content:
        return
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.phone-health-', delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def install(activate=False):
    if os.geteuid() != 0:
        raise PermissionError('Phone Health installation requires root.')
    installed = PACKAGE == TOOLS
    if installed and not activate:
        raise ValueError('Use the verified release package to stage Phone Health.')
    contents = {}
    if not installed:
        manifest = json.loads((PACKAGE / 'release-manifest.json').read_text())
        for name in (*PROGRAMS, UNIT.name, TIMER.name):
            content = (PACKAGE / name).read_bytes()
            if hashlib.sha256(content).hexdigest() != manifest['files'].get(name):
                raise ValueError('Phone Health differs from the reviewed release.')
            contents[name] = content
    # A distro/vendor/operator unit takes precedence. Never start or enable it.
    for unit in (UNIT, TIMER):
        ordinary(unit)
        if unit.exists():
            if not unit.read_bytes().startswith(HEADER):
                return 'custom'
            if not installed and unit.read_bytes() != contents[unit.name]:
                raise ValueError('Review the changed managed Phone Health unit.')
        else:
            if installed:
                raise ValueError('Phone Health must be staged before activation.')
            loaded = subprocess.check_output(['systemctl', 'show', unit.name,
                                              '--property=LoadState', '--value'], text=True, timeout=10).strip()
            if loaded not in ('', 'not-found'):
                return 'custom'
    for link in LINKS:
        if link.is_symlink():
            if link.resolve() != TIMER:
                raise ValueError('An existing Phone Health timer link belongs to another unit.')
        elif link.exists():
            raise ValueError('Review an existing Phone Health timer link.')
    first = not TIMER.exists()
    if not installed:
        for name in PROGRAMS:
            write(TOOLS / name, contents[name])
        write(UNIT, contents[UNIT.name])
        write(TIMER, contents[TIMER.name])
    # No package-local manifest exists after a committed update. Trust only
    # protected installed files; do not copy or rewrite them during activation.
    for path in (*[TOOLS / name for name in PROGRAMS], UNIT, TIMER):
        protected(path)
    subprocess.run(['systemctl', 'daemon-reload'], check=True, timeout=20)
    if first:
        subprocess.run(['systemctl', 'enable', TIMER.name], check=True, timeout=20)
    enabled = subprocess.run(['systemctl', 'is-enabled', '--quiet', TIMER.name],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    if activate and enabled and not MAINTENANCE.exists() and not RESTORE_HOLD.exists():
        # Rearm the timer only after commit. Its worker independently owns the
        # upgrade lock, so even a simultaneous restore cannot observe half a DB.
        subprocess.run(['systemctl', 'restart', TIMER.name], check=True, timeout=20)
    return 'managed'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--activate', action='store_true')
    args = parser.parse_args()
    install(args.activate)
