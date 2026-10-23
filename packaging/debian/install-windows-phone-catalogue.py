#!/usr/bin/env python3
"""Stage verified catalogue helpers; activate only after durable PBX commit."""
import argparse
import contextlib
import fcntl
import re
import grp
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

PACKAGE = Path(__file__).resolve().parent
TOOLS = Path('/opt/openwebpbx/tools')
STATE = Path('/var/lib/openwebpbx/windows-phone-catalogue')
UNIT = Path('/etc/systemd/system/openwebpbx-windows-phone-catalogue.service')
TIMER = Path('/etc/systemd/system/openwebpbx-windows-phone-catalogue.timer')
LINKS = (Path('/etc/systemd/system/timers.target.wants') / TIMER.name,
         Path('/etc/systemd/system/openwebpbx-updater.service.wants') / TIMER.name)
PROGRAMS = ('windows-phone-catalogue.php', 'install-windows-phone-catalogue.py')
CHOICE = TOOLS / 'windows-phone-catalogue-install.json'
MAINTENANCE_LOCK = Path('/run/openwebpbx-upgrade.lock')
PENDING = Path('/var/lib/openwebpbx/updates')
PENDING_PREFIX = 'windows-phone-catalogue.pending.'
LEASE_ENV = 'OPENWEBPBX_CATALOGUE_LEASE_FD'
PENDING_NAMES = (*PROGRAMS, UNIT.name, TIMER.name, 'release-manifest.json', 'VERSION', 'receipt.json')
HEADER = b'# OpenWeb PBX managed WindowsPhone catalogue v1\n'
OWNER = b'{"schema":1,"component":"windows-free-phone","key_id":"windows-phone-release-1"}\n'


def ordinary(path, directory=False):
    for node in (path, *path.parents):
        if node.is_symlink():
            raise ValueError('Linked catalogue locations were preserved.')
        if node.exists():
            s = node.stat()
            if s.st_uid != 0 or s.st_mode & 0o022:
                raise ValueError('Writable catalogue locations were preserved.')
    if path.exists():
        s = path.stat()
        if not (stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode)) or (not directory and s.st_nlink != 1):
            raise ValueError('An ordinary single-link catalogue location is required.')


def targets():
    # No private catalogue data is changed before commit. Existing enablement
    # links are preserved, and first enablement happens only after commit.
    return [*[TOOLS / name for name in PROGRAMS], UNIT, TIMER, CHOICE]


def state_valid():
    ordinary(STATE, directory=True)
    if not STATE.exists():
        return
    if (STATE / 'owner.json').read_bytes() != OWNER:
        raise ValueError('Foreign catalogue state was preserved.')
    for item in STATE.iterdir():
        if item.name not in {'owner.json', 'refresh.lock', 'accepted.json', 'publication.json'}:
            raise ValueError('Unknown catalogue state was preserved.')
        ordinary(item)
    s = STATE.stat()
    if stat.S_IMODE(s.st_mode) != 0o2750 or s.st_gid != grp.getgrnam('www-data').gr_gid:
        raise ValueError('Existing catalogue permissions need review; none were changed.')


def atomic(path, content, mode=0o644):
    ordinary(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.catalogue-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content); stream.flush(); os.fchmod(stream.fileno(), mode); os.fsync(stream.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def provision_state():
    state_valid()
    if STATE.exists():
        return
    ordinary(STATE.parent, directory=True)
    STATE.mkdir(mode=0o750)
    os.chown(STATE, 0, grp.getgrnam('www-data').gr_gid)
    STATE.chmod(0o2750)
    atomic(STATE / 'owner.json', OWNER, 0o640)
    atomic(STATE / 'refresh.lock', b'', 0o600)
    state_valid()


def read_choice():
    ordinary(CHOICE)
    if not CHOICE.exists():
        return None
    choice = json.loads(CHOICE.read_text())
    if (set(choice) != {'schema', 'component', 'enable_on_commit', 'service_sha256', 'timer_sha256'}
            or type(choice['schema']) is not int or choice['schema'] != 1
            or choice['component'] != 'windows-free-phone' or type(choice['enable_on_commit']) is not bool):
        raise ValueError('Catalogue activation ownership needs review.')
    for field, unit in (('service_sha256', UNIT), ('timer_sha256', TIMER)):
        digest = choice[field]
        if (type(digest) is not str or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest)
                or not unit.exists() or hashlib.sha256(unit.read_bytes()).hexdigest() != digest):
            raise ValueError('Changed catalogue unit definitions were preserved.')
    return choice



def inherited_fd():
    value = os.environ.get(LEASE_ENV)
    if value is None:
        return None
    if not re.fullmatch(r'[0-9]{1,7}', value) or int(value) < 3:
        raise ValueError('The inherited catalogue lease descriptor is invalid.')
    descriptor = int(value)
    ordinary(MAINTENANCE_LOCK)
    actual = os.fstat(descriptor); expected = MAINTENANCE_LOCK.stat()
    if (not stat.S_ISREG(actual.st_mode) or actual.st_nlink != 1 or actual.st_uid != 0
            or actual.st_mode & 0o022 or (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino)):
        raise ValueError('The inherited catalogue lease identity differs.')
    # fdinfo describes THIS open file description, including a lease inherited
    # across exec. A busy different process or a journal is never authorization.
    information = Path('/proc/self/fdinfo') / str(descriptor)
    text = information.read_text()
    if len(text) > 8192:
        raise ValueError('The inherited catalogue lease observation is oversized.')
    token = f'{os.major(actual.st_dev):02x}:{os.minor(actual.st_dev):02x}:{actual.st_ino}'
    locks = [line.split() for line in text.splitlines() if line.startswith('lock:')]
    if len(locks) != 1 or len(locks[0]) != 9 or locks[0][2:5] != ['FLOCK', 'ADVISORY', 'WRITE'] or locks[0][6:] != [token, '0', 'EOF']:
        raise ValueError('An actual inherited exclusive catalogue lease is required.')
    return descriptor


@contextlib.contextmanager
def maintenance_lease():
    descriptor = inherited_fd()
    if descriptor is not None:
        # Never unlock/close an inherited file description owned by the updater.
        yield descriptor
        return
    ordinary(MAINTENANCE_LOCK)
    descriptor = os.open(MAINTENANCE_LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        actual = os.fstat(descriptor); expected = MAINTENANCE_LOCK.stat()
        if ((actual.st_dev,actual.st_ino) != (expected.st_dev,expected.st_ino)
                or not stat.S_ISREG(actual.st_mode) or actual.st_nlink != 1 or actual.st_uid != 0 or actual.st_mode & 0o022):
            raise ValueError('The catalogue maintenance file is not protected.')
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield descriptor
    finally:
        os.close(descriptor)


def pending_path(name):
    if name not in PENDING_NAMES:
        raise ValueError('Unknown deferred catalogue input.')
    return PENDING / (PENDING_PREFIX + name)


def pending_targets():
    return [pending_path(name) for name in PENDING_NAMES]


def pending_material(version=None):
    for path in pending_targets():
        ordinary(path)
        if not path.is_file() or path.stat().st_mode & 0o077:
            raise ValueError('Deferred catalogue inputs must be private ordinary files.')
    receipt_bytes = pending_path('receipt.json').read_bytes()
    manifest_bytes = pending_path('release-manifest.json').read_bytes()
    if len(receipt_bytes) > 2048 or len(manifest_bytes) > 4194304:
        raise ValueError('Deferred catalogue input bounds differ.')
    receipt = json.loads(receipt_bytes); manifest = json.loads(manifest_bytes)
    if (set(receipt) != {'schema','component','version','manifest_sha256'}
            or type(receipt['schema']) is not int or receipt['schema'] != 1
            or receipt['component'] != 'windows-free-phone'
            or type(receipt['version']) is not str or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', receipt['version'])
            or receipt['manifest_sha256'] != hashlib.sha256(manifest_bytes).hexdigest()
            or manifest.get('version') != receipt['version']
            or pending_path('VERSION').read_text().strip() != receipt['version']
            or (version is not None and version != receipt['version'])):
        raise ValueError('The deferred catalogue does not match the committed release.')
    contents = {}
    for name in PENDING_NAMES[:4] + ('VERSION',):
        content = pending_path(name).read_bytes()
        if len(content) > 1048576 or hashlib.sha256(content).hexdigest() != manifest['files'].get(name):
            raise ValueError('A deferred catalogue input differs from the original release manifest.')
        contents[name] = content
    return manifest, contents


def assert_first_absence():
    for path in targets() + [STATE, *LINKS]:
        if path.exists() or path.is_symlink():
            raise ValueError('An existing catalogue requires the actual inherited maintenance lease.')
    for unit in (UNIT, TIMER):
        loaded = subprocess.check_output(['systemctl','show',unit.name,'--property=LoadState','--value'], text=True, timeout=10).strip()
        if loaded not in ('', 'not-found'):
            raise ValueError('A loaded catalogue requires the actual inherited maintenance lease.')


def stage_pending():
    # Called only after the support helper added EVERY pending file to the
    # durable rollback inventory. These bytes are inert until new finalization.
    ordinary(PENDING, directory=True)
    if not PENDING.is_dir() or PENDING.stat().st_mode & 0o077:
        raise ValueError('Deferred catalogue inputs require the private updater directory.')
    existing = [path.exists() or path.is_symlink() for path in pending_targets()]
    if any(existing):
        pending_material()
    manifest_bytes = (PACKAGE/'release-manifest.json').read_bytes()
    if len(manifest_bytes) > 4194304:
        raise ValueError('The original release manifest is oversized.')
    manifest = json.loads(manifest_bytes); version = (PACKAGE/'VERSION').read_bytes()
    contents = {}
    for name in PENDING_NAMES[:4] + ('VERSION',):
        ordinary(PACKAGE/name); content = (PACKAGE/name).read_bytes()
        if len(content) > 1048576 or hashlib.sha256(content).hexdigest() != manifest['files'].get(name):
            raise ValueError('Deferred catalogue input differs from the original release.')
        contents[name] = content
    if manifest.get('version') != version.decode().strip():
        raise ValueError('The deferred catalogue version differs.')
    contents['release-manifest.json'] = manifest_bytes
    contents['receipt.json'] = (json.dumps({'schema':1,'component':'windows-free-phone','version':manifest['version'],'manifest_sha256':hashlib.sha256(manifest_bytes).hexdigest()})+'\n').encode()
    for name in PENDING_NAMES:
        atomic(pending_path(name), contents[name], 0o600)
    pending_material(manifest['version'])


def quiesce():
    # Existing units must retain their complete hash-bound ownership before any
    # stop. The exclusive shared lease prevents refresh publication throughout.
    choice = read_choice()
    if choice is None:
        assert_first_absence()
        return False
    for unit in (UNIT, TIMER):
        ordinary(unit)
        actual = subprocess.check_output(['systemctl','show',unit.name,'--property=FragmentPath','--value'], text=True, timeout=10).strip()
        if actual != str(unit):
            raise ValueError('The loaded catalogue unit origin differs.')
    active = subprocess.run(['systemctl','is-active','--quiet',TIMER.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    try:
        subprocess.run(['systemctl','stop',TIMER.name,UNIT.name], check=True, timeout=95)
        for unit in (UNIT, TIMER):
            state = subprocess.check_output(['systemctl','show',unit.name,'--property=ActiveState','--value'], text=True, timeout=10).strip()
            if state not in ('inactive','failed'):
                raise ValueError('The owned catalogue writer did not stop.')
            pid = subprocess.check_output(['systemctl','show',unit.name,'--property=MainPID','--value'], text=True, timeout=10).strip()
            if pid != '0':
                raise ValueError('The owned catalogue writer remains active.')
    except BaseException as primary:
        if active:
            try:
                subprocess.run(['systemctl','start',TIMER.name], check=True, timeout=20)
            except BaseException:
                primary.add_note('The original catalogue timer choice could not be restored after quiescence refusal.')
        raise
    return active


def install(activate=False, pending_version=None):
    with maintenance_lease():
        state_valid()
        for link in LINKS:
            if (link.is_symlink() and link.resolve() != TIMER) or (link.exists() and not link.is_symlink()):
                raise ValueError('A foreign catalogue enablement path was preserved.')
        if pending_version is not None:
            journal = PENDING/'install-journal.json'
            ordinary(journal)
            value = json.loads(journal.read_text())
            if value.get('state') != 'completed' or value.get('version') != pending_version:
                raise ValueError('Deferred catalogue activation requires its exact completed journal.')
            pending_material(pending_version)
        active = quiesce(); primary = None
        try:
            return _install(activate, pending_version)
        except BaseException as error:
            primary = error
            raise
        finally:
            if active:
                try:
                    subprocess.run(['systemctl','start',TIMER.name], check=True, timeout=20)
                except BaseException:
                    if primary is None:
                        raise
                    primary.add_note('The original catalogue timer choice could not be restored.')


def _install(activate=False, pending_version=None):
    if os.geteuid() != 0:
        raise PermissionError('Catalogue setup requires the installation owner.')
    installed = PACKAGE == TOOLS and pending_version is None
    if installed and not activate:
        raise ValueError('Stage helpers from the verified release package.')
    contents = {}
    if pending_version is not None:
        _, contents = pending_material(pending_version)
    elif not installed:
        manifest = json.loads((PACKAGE / 'release-manifest.json').read_text())
        for name in (*PROGRAMS, UNIT.name, TIMER.name):
            ordinary(PACKAGE / name)
            content = (PACKAGE / name).read_bytes()
            if hashlib.sha256(content).hexdigest() != manifest['files'].get(name):
                raise ValueError('Catalogue helpers differ from the signed release.')
            contents[name] = content
    # All ownership/collision checks precede the first target write.
    state_valid()
    for unit in (UNIT, TIMER):
        ordinary(unit)
    choice = read_choice()
    for unit in (UNIT, TIMER):
        if unit.exists():
            content = unit.read_bytes()
            if not content.startswith(HEADER) or choice is None:
                raise ValueError('Foreign or changed catalogue units were preserved.')
        else:
            if installed:
                raise ValueError('Catalogue units must be staged before activation.')
            loaded = subprocess.check_output(['systemctl', 'show', unit.name, '--property=LoadState', '--value'], text=True, timeout=10).strip()
            if loaded not in ('', 'not-found'):
                raise ValueError('A foreign catalogue unit was preserved.')
    for link in LINKS:
        if link.is_symlink():
            if link.resolve() != TIMER:
                raise ValueError('A foreign catalogue enablement link was preserved.')
        elif link.exists():
            raise ValueError('A foreign catalogue enablement path was preserved.')
    for name in PROGRAMS:
        ordinary(TOOLS / name)
    first = choice['enable_on_commit'] if choice else True
    if installed:
        if choice is None:
            raise ValueError('Catalogue activation ownership needs review.')
    if not installed:
        for name in PROGRAMS:
            atomic(TOOLS / name, contents[name])
        for unit in (UNIT, TIMER):
            atomic(unit, contents[unit.name])
        choice = {'schema': 1, 'component': 'windows-free-phone', 'enable_on_commit': first,
                  'service_sha256': hashlib.sha256(contents[UNIT.name]).hexdigest(),
                  'timer_sha256': hashlib.sha256(contents[TIMER.name]).hexdigest()}
        atomic(CHOICE, (json.dumps(choice) + '\n').encode())
    subprocess.run(['systemctl', 'daemon-reload'], check=True, timeout=20)
    if activate:
        # A missing first-run timer can be enabled only after PBX commit. An
        # existing disabled timer remains disabled across future installations.
        provision_state()
        if first:
            subprocess.run(['systemctl', 'enable', TIMER.name], check=True, timeout=20)
            choice['enable_on_commit'] = False
            atomic(CHOICE, (json.dumps(choice) + '\n').encode())
        enabled = subprocess.run(['systemctl', 'is-enabled', '--quiet', TIMER.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
        if enabled:
            subprocess.run(['systemctl', 'start', TIMER.name], check=True, timeout=20)
    return 'managed'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--activate', action='store_true')
    parser.add_argument('--pending-version')
    args = parser.parse_args()
    install(args.activate, args.pending_version)
