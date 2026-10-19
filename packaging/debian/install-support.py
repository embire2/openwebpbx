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
SUPPORT = {'tenant-domains.py': Path('/opt/openwebpbx/tools/tenant-domains.py'),
           'tenant-domains.php': Path('/opt/openwebpbx/tools/tenant-domains.php'),
           'tenant-domains-nginx.conf': Path('/opt/openwebpbx/tools/tenant-domains-nginx.conf'),
           'install-tenant-domains.py': Path('/opt/openwebpbx/tools/install-tenant-domains.py'),
           'openwebpbx-tenant-domains.service': Path('/etc/systemd/system/openwebpbx-tenant-domains.service'),
           'openwebpbx-tenant-domains.timer': Path('/etc/systemd/system/openwebpbx-tenant-domains.timer'),
           'install-mail.py': Path('/opt/openwebpbx/tools/install-mail.py'),
           'install-stun.py': Path('/opt/openwebpbx/tools/install-stun.py'),
           'call-diagnostics.py': Path('/opt/openwebpbx/tools/call-diagnostics.py'),
           'openwebpbx-call-diagnostics.service': Path('/opt/openwebpbx/tools/openwebpbx-call-diagnostics.service'),
           'openwebpbx-stun.service': Path('/opt/openwebpbx/tools/openwebpbx-stun.service'),
           'openwebpbx-stun.conf': Path('/opt/openwebpbx/tools/openwebpbx-stun.conf'),
           'install-meet.py': Path('/opt/openwebpbx/tools/install-meet.py'),
           'meet-nginx.conf': Path('/opt/openwebpbx/tools/meet-nginx.conf'),
           'openwebpbx-call-records.conf': Path('/etc/systemd/system/openwebpbx.service.d/call-records.conf'),
           'openwebpbx-call-me-back.conf': Path('/etc/systemd/system/openwebpbx.service.d/call-me-back.conf'),
           'backups.py': Path('/opt/openwebpbx/tools/backups.py'),
           'install-backups.sh': Path('/opt/openwebpbx/tools/install-backups.sh'),
           'install-support.py': Path('/opt/openwebpbx/tools/install-support.py'),
           'install-mobile-notifications.py': Path('/opt/openwebpbx/tools/install-mobile-notifications.py'),
           'cpanel-acme-hook.py': Path('/opt/openwebpbx/tools/cpanel-acme-hook.py'),
           'restore-sofia.py': Path('/opt/openwebpbx/tools/restore-sofia.py'),
           'openwebpbx-backups.service': Path('/etc/systemd/system/openwebpbx-backups.service'),
           'openwebpbx-backups.timer': Path('/etc/systemd/system/openwebpbx-backups.timer')}
TIMER_LINKS = [Path('/etc/systemd/system/timers.target.wants/openwebpbx-backups.timer'),
               Path('/etc/systemd/system/openwebpbx-updater.service.wants/openwebpbx-backups.timer')]
NOTIFICATION_FILES = [Path('/var/lib/openwebpbx/mobile-notifications/config.json'),
                      Path('/var/lib/openwebpbx/mobile-notifications/config.json.lock')]
CALL_ME_BACK_ROOT = Path('/var/lib/freeswitch/storage/openwebpbx/call-me-back')


def ensure_call_me_back_storage():
    for parent in [CALL_ME_BACK_ROOT,*CALL_ME_BACK_ROOT.parents]:
        if parent.is_symlink():
            raise ValueError('The private callback storage cannot be linked.')
    absent=[];parent=CALL_ME_BACK_ROOT
    while not parent.exists():
        absent.append(parent);parent=parent.parent
    if not parent.is_dir():
        raise ValueError('The private callback storage parent is not a directory.')
    for directory in reversed(absent):
        directory.mkdir(mode=0o750);os.chown(directory,33,33);sync_dir(directory.parent)
    status=CALL_ME_BACK_ROOT.stat()
    if not CALL_ME_BACK_ROOT.is_dir() or status.st_uid!=33 or status.st_mode & 0o007:
        raise ValueError('The private callback storage needs its existing owner to review permissions.')


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
    if shutil.which('certbot') is None:
        packages.append('certbot')
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
    spec = importlib.util.spec_from_file_location('restore_sofia', PACKAGE / 'restore-sofia.py')
    registrar = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(registrar)
    native_content = registrar.payload(PACKAGE, manifest)
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
            meet_spec=importlib.util.spec_from_file_location('candidate_meeting',PACKAGE/'install-meet.py')
            meeting=importlib.util.module_from_spec(meet_spec);meet_spec.loader.exec_module(meeting)
            mail_spec=importlib.util.spec_from_file_location('candidate_mail',PACKAGE/'install-mail.py')
            mail=importlib.util.module_from_spec(mail_spec);mail_spec.loader.exec_module(mail)
            domain_spec=importlib.util.spec_from_file_location('candidate_domains',PACKAGE/'install-tenant-domains.py')
            domain_helper=importlib.util.module_from_spec(domain_spec);domain_spec.loader.exec_module(domain_helper)
            targets = list(SUPPORT.values()) + NOTIFICATION_FILES + [registrar.TARGET] + meeting.targets() + mail.targets() + domain_helper.targets()
            # Existing systemd enablement is preserved. A newly created link is
            # included as an absent target so older rollback code removes it.
            for link in TIMER_LINKS:
                if not link.exists() and not link.is_symlink():
                    targets.append(link)
            augment_snapshot(backup, targets)
            upgrade.validate_backup(backup)
    if native_content is not None and not migrating:
        raise ValueError('An existing registrar must be updated through the recoverable instance updater.')
    registrar.install(native_content)
    ensure_dependencies()
    for name in ['install-mail.py','call-diagnostics.py','openwebpbx-call-diagnostics.service','install-stun.py','openwebpbx-stun.service','openwebpbx-stun.conf','install-meet.py','meet-nginx.conf','install-backups.sh', 'install-support.py', 'install-mobile-notifications.py','cpanel-acme-hook.py','restore-sofia.py']:
        target = SUPPORT[name]
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.support-helper-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write((PACKAGE/name).read_bytes());stream.flush();os.fsync(stream.fileno())
            os.fchmod(stream.fileno(),0o644)
        os.replace(temporary,target);sync_dir(target.parent)
    ensure_call_me_back_storage()
    for name in ['openwebpbx-call-records.conf','openwebpbx-call-me-back.conf']:
        target=SUPPORT[name]
        target.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
        with tempfile.NamedTemporaryFile(dir=target.parent,prefix='.call-service-',delete=False) as stream:
            temporary=Path(stream.name);stream.write((PACKAGE/name).read_bytes());stream.flush();os.fsync(stream.fileno());os.fchmod(stream.fileno(),0o644)
        os.replace(temporary,target);sync_dir(target.parent)
    subprocess.run(['systemctl','daemon-reload'],check=True)
    subprocess.run(['python3', str(PACKAGE / 'install-mobile-notifications.py')],
                   check=True, cwd=PACKAGE, timeout=60)
    # A legacy updater must be able to roll back without a running new timer.
    # On success, restarting the updated independent worker starts its wanted
    # timer. On failure, the snapshot removes the never-started units and links.
    subprocess.run(['bash', str(PACKAGE / 'install-backups.sh')], check=True, cwd=PACKAGE,
                   env=os.environ | ({'OPENWEB_BACKUP_START': '0'} if migrating else {}), timeout=60)
    subprocess.run(['python3',str(PACKAGE/'install-mail.py')],check=True,cwd=PACKAGE,timeout=60)
    subprocess.run(['python3',str(PACKAGE/'install-tenant-domains.py')],check=True,cwd=PACKAGE,timeout=60)
    # Older installed updaters do not know the newly bundled spoken targets.
    # The candidate helper augments their verified recovery inventory before
    # changing any voice, while the engine remains in the same stopped phase.
    if (PACKAGE/'voices/1.0.1').is_dir():
        if not migrating and os.environ.get('OPENWEB_FRESH_INSTALL') != '1':
            raise ValueError('Use the recoverable instance updater for existing system voices.')
        if digest(PACKAGE/'install-voices.py') != manifest['files'].get('install-voices.py'):
            raise ValueError('The voice installer differs from the reviewed release.')
        if migrating:
            subprocess.run(['python3',str(PACKAGE/'install-voices.py')],check=True,cwd=PACKAGE,timeout=600)
        # Fresh configure installs the overlay after copying stock engine/config
        # defaults and before the first service start; no recovery is needed.


if __name__ == '__main__':
    install()
