#!/usr/bin/env python3
"""Install new instance helpers during a signed upgrade, including older updaters."""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PACKAGE = Path(__file__).resolve().parent
UPDATES = Path('/var/lib/openwebpbx/updates')
BACKUPS = Path('/var/backups/openwebpbx')
SUPPORT = {'backups.py': Path('/opt/openwebpbx/tools/backups.py'),
           'install-backups.sh': Path('/opt/openwebpbx/tools/install-backups.sh'),
           'install-support.py': Path('/opt/openwebpbx/tools/install-support.py'),
           'install-mobile-notifications.py': Path('/opt/openwebpbx/tools/install-mobile-notifications.py'),
           'openwebpbx-backups.service': Path('/etc/systemd/system/openwebpbx-backups.service'),
           'openwebpbx-backups.timer': Path('/etc/systemd/system/openwebpbx-backups.timer')}
TIMER_LINKS = [Path('/etc/systemd/system/timers.target.wants/openwebpbx-backups.timer'),
               Path('/etc/systemd/system/openwebpbx-updater.service.wants/openwebpbx-backups.timer')]
NOTIFICATION_FILES = [Path('/var/lib/openwebpbx/mobile-notifications/config.json'),
                      Path('/var/lib/openwebpbx/mobile-notifications/config.json.lock')]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.support-', delete=False) as stream:
        temporary = Path(stream.name)
        stream.write((json.dumps(value, indent=2) + '\n').encode())
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    sync_dir(path.parent)


def exchange_directories(first, second):
    # One atomic Linux rename keeps files.json and integrity.json consistent
    # across an interruption. Existing updaters read the unchanged backup path.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(first), -100, os.fsencode(second), 2):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    sync_dir(first.parent)


def augment_snapshot(backup, targets):
    """Durably add previously untracked helper files before changing any of them."""
    entries = json.loads((backup / 'files.json').read_text())
    known = {item['path'] for item in entries}
    missing = [target for target in targets if str(target) not in known]
    if not missing:
        return
    clone = Path(tempfile.mkdtemp(prefix='.support-snapshot-', dir=backup.parent))
    try:
        # Existing snapshot files remain immutable. Metadata updates below use
        # replace(), so hard links never alter the original inventory.
        shutil.copytree(backup, clone, dirs_exist_ok=True, copy_function=os.link)
        for target in missing:
            if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
                raise ValueError('A helper location is a symbolic link; update needs attention.')
            if target.exists() and not target.is_file():
                raise ValueError('A helper location is not an ordinary file.')
            item = {'path': str(target), 'exists': target.is_file()}
            if item['exists']:
                status = target.stat()
                saved = clone / 'files' / target.relative_to('/')
                saved.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                shutil.copyfile(target, saved)
                saved.chmod(0o600)
                with saved.open('rb') as stream:
                    os.fsync(stream.fileno())
                item.update(sha256=digest(saved), mode=status.st_mode & 0o777,
                            uid=status.st_uid, gid=status.st_gid)
            entries.append(item)
        atomic_json(clone / 'files.json', entries)
        integrity = json.loads((clone / 'integrity.json').read_text())
        integrity['files.json'] = digest(clone / 'files.json')
        atomic_json(clone / 'integrity.json', integrity)
        for folder in sorted((p for p in clone.rglob('*') if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
            sync_dir(folder)
        sync_dir(clone)
        exchange_directories(backup, clone)
    finally:
        shutil.rmtree(clone)
        sync_dir(backup.parent)


def ensure_dependencies():
    result = subprocess.run(['python3', '-c', 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    packages = ([] if result.returncode == 0 else ['python3-cryptography'])
    if shutil.which('sox') is None:
        packages.append('sox')
    if shutil.which('sftp') is None or shutil.which('ssh-keygen') is None:
        packages.append('openssh-client')
    if packages:
        subprocess.run(['apt-get', 'update'], check=True, timeout=600)
        subprocess.run(['apt-get', 'install', '-y', '--no-install-recommends', *packages],
                       env=os.environ | {'DEBIAN_FRONTEND': 'noninteractive'}, check=True, timeout=900)


def install():
    if os.geteuid() != 0:
        raise PermissionError('The instance installer must run as root.')
    manifest = json.loads((PACKAGE / 'release-manifest.json').read_text())
    for name in SUPPORT:
        if digest(PACKAGE / name) != manifest['files'].get(name):
            raise ValueError('The backup helper differs from the reviewed release.')
    journal_path = UPDATES / 'install-journal.json'
    migrating = False
    if journal_path.is_file():
        journal = json.loads(journal_path.read_text())
        if journal.get('state') == 'migrating':
            migrating = True
            if journal.get('version') != manifest['version']:
                raise ValueError('The helper version differs from the active upgrade.')
            backup = Path(journal['backup_path'])
            if backup.parent != BACKUPS or backup.is_symlink() or not backup.name.startswith('upgrade-'):
                raise ValueError('Invalid private recovery location.')
            status = backup.stat()
            if status.st_uid != 0 or status.st_mode & 0o077:
                raise ValueError('The recovery snapshot is not private.')
            spec = importlib.util.spec_from_file_location('support_upgrade', PACKAGE / 'upgrade.py')
            upgrade = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(upgrade)
            upgrade.validate_backup(backup)
            targets = list(SUPPORT.values()) + NOTIFICATION_FILES
            # Existing systemd enablement is preserved. A newly created link is
            # included as an absent target so older rollback code removes it.
            for link in TIMER_LINKS:
                if not link.exists() and not link.is_symlink():
                    targets.append(link)
            augment_snapshot(backup, targets)
            upgrade.validate_backup(backup)
    ensure_dependencies()
    for name in ['install-backups.sh', 'install-support.py', 'install-mobile-notifications.py']:
        target = SUPPORT[name]
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.support-helper-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write((PACKAGE/name).read_bytes());stream.flush();os.fsync(stream.fileno())
            os.fchmod(stream.fileno(),0o644)
        os.replace(temporary,target);sync_dir(target.parent)
    subprocess.run(['python3', str(PACKAGE / 'install-mobile-notifications.py')],
                   check=True, cwd=PACKAGE, timeout=60)
    # A legacy updater must be able to roll back without a running new timer.
    # On success, restarting the updated independent worker starts its wanted
    # timer. On failure, the snapshot removes the never-started units and links.
    subprocess.run(['bash', str(PACKAGE / 'install-backups.sh')], check=True, cwd=PACKAGE,
                   env=os.environ | ({'OPENWEB_BACKUP_START': '0'} if migrating else {}), timeout=60)


if __name__ == '__main__':
    install()
