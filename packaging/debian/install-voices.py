#!/usr/bin/env python3
"""Install sealed offline system voices inside the existing update transaction."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import tarfile

PACKAGE = Path(__file__).resolve().parent
SOUNDS = Path('/usr/share/freeswitch/sounds')
KNOWN_ENGINE_SHA256 = '6ded7513a66899e0d9413b99a270344a5697944bc38f51c13d58952caa34cccc'

# The immutable16 updater calls candidate payload() before make_backup().
# Return this one native member through that existing transaction, not bootstrap.
NATIVE_ENGINE_SHA256 = '6ded7513a66899e0d9413b99a270344a5697944bc38f51c13d58952caa34cccc'
NATIVE_SOFIA = Path('/usr/local/lib/libsofia-sip-ua.so.0.6.0')
NATIVE_SOFIA_MEMBER = 'usr/local/lib/libsofia-sip-ua.so.0.6.0'
NATIVE_SOFIA_BYTES = 2265864
NATIVE_SOFIA_OLD_SHA256 = '7e7930be0599e5625e27e257476e83b55990dd242bddf0d2e78dd349e3942c53'
NATIVE_SOFIA_SHA256 = '32873b76e45a6a1b06c8ba39ca15f0d35b25ccc917d364a58a246d698600faca'


def native_library_hash():
    target = NATIVE_SOFIA
    if any(path.is_symlink() for path in (target, *target.parents)):
        raise ValueError('The native Sofia destination must be an ordinary installed path.')
    for parent in target.parents:
        directory = parent.lstat()
        if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != 0 or directory.st_mode & 0o022:
            raise ValueError('The native Sofia directory ancestry must be protected and root-owned.')
    node = target.lstat()
    if not stat.S_ISREG(node.st_mode) or node.st_uid != 0 or node.st_gid != 0 or node.st_nlink != 1 or stat.S_IMODE(node.st_mode) not in (0o755, 0o644) or os.listxattr(target):
        raise ValueError('The native Sofia destination has unsupported ownership, links or attributes.')
    for name in ('libsofia-sip-ua.so', 'libsofia-sip-ua.so.0'):
        link = target.with_name(name)
        link_node = link.lstat()
        if not stat.S_ISLNK(link_node.st_mode) or link_node.st_uid != 0 or link_node.st_gid != 0 or link_node.st_nlink != 1 or os.readlink(link) != target.name:
            raise ValueError('The native Sofia loader links differ from the reviewed installation.')
    return digest(target)


def native_payload(package, manifest):
    if manifest.get('files', {}).get('engine.tar.gz') != NATIVE_ENGINE_SHA256:
        return {}  # Historical packages retain their original deployment scope.
    archive = Path(package) / 'engine.tar.gz'
    if any(path.is_symlink() for path in (archive, *archive.parents)) or not archive.is_file() or digest(archive) != NATIVE_ENGINE_SHA256:
        raise ValueError('The complete pinned native engine archive is required.')
    if native_library_hash() not in (NATIVE_SOFIA_OLD_SHA256, NATIVE_SOFIA_SHA256):
        raise ValueError('The installed native Sofia library is not a reviewed preimage.')
    parent = Path(package).parent
    node = parent.stat()
    if node.st_uid != 0 or node.st_mode & 0o022:
        raise ValueError('The verified candidate needs a protected root-owned staging parent.')
    data = None
    with tarfile.open(archive, 'r|gz') as source:
        for member in source:
            if member.name != NATIVE_SOFIA_MEMBER:
                continue
            if data is not None or not member.isfile() or member.size != NATIVE_SOFIA_BYTES:
                raise ValueError('One exact ordinary native Sofia archive member is required.')
            data = source.extractfile(member).read(NATIVE_SOFIA_BYTES + 1)
            if len(data) != NATIVE_SOFIA_BYTES or hashlib.sha256(data).hexdigest() != NATIVE_SOFIA_SHA256:
                raise ValueError('The native Sofia source member differs from the reviewed build.')
    if data is None:
        raise ValueError('The reviewed native Sofia member is missing.')
    # A sibling keeps the unchanged old manifest file-set guard valid. The old
    # CLI owns this verified parent and removes it in its original finally.
    descriptor, name = tempfile.mkstemp(prefix='.openweb-sofia-', suffix='.so', dir=parent)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    return {NATIVE_SOFIA: Path(name)}


def require_native_snapshot(backup, manifest):
    if manifest.get('files', {}).get('engine.tar.gz') != NATIVE_ENGINE_SHA256:
        return
    rows = [row for row in json.loads((backup / 'files.json').read_text())
            if row.get('path') == str(NATIVE_SOFIA)]
    if len(rows) != 1 or rows[0].get('exists') is not True or rows[0].get('sha256') not in (NATIVE_SOFIA_OLD_SHA256, NATIVE_SOFIA_SHA256):
        raise ValueError('The original updater must snapshot native Sofia before deployment.')
    saved = backup / 'files' / NATIVE_SOFIA.relative_to('/')
    if not saved.is_file() or saved.is_symlink() or digest(saved) != rows[0]['sha256'] or native_library_hash() != NATIVE_SOFIA_SHA256:
        raise ValueError('The pre-deployment native snapshot and deployed library are required.')


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle,'sha256').hexdigest()


def required_stock_paths(package, manifest):
    """Only the reviewed sparse engine may relax absent sample-rate paths."""
    archive=Path(package)/'engine.tar.gz'
    if not archive.exists() and not archive.is_symlink():return None
    if archive.is_symlink() or any(p.is_symlink()for p in archive.parents) or not archive.is_file():
        raise ValueError('The native voice inventory archive must be ordinary.')
    sha=digest(archive)
    if sha!=manifest['files'].get('engine.tar.gz'):
        raise ValueError('The native voice inventory differs from the release manifest.')
    if sha!=KNOWN_ENGINE_SHA256:return None # Unfamiliar engines retain strict stock checks.
    prefix=('usr','share','freeswitch','sounds');names=set();seen=set()
    with tarfile.open(archive,'r|gz')as source:
        for entry in source:
            path=PurePosixPath(entry.name)
            if path.parts[:4]!=prefix:continue
            if path.is_absolute() or '..'in path.parts or path.as_posix()!=entry.name or entry.name in seen:
                raise ValueError('The reviewed engine sound inventory is ambiguous.')
            seen.add(entry.name)
            if entry.isdir():continue
            if not entry.isfile():raise ValueError('The reviewed engine sound inventory is linked or nonordinary.')
            if entry.name.endswith('.wav'):names.add(PurePosixPath(*path.parts[4:]).as_posix())
    if not names:raise ValueError('The reviewed native engine contains no stock sound inventory.')
    return frozenset(names)


def verify_original_snapshot(originals,new,before,required_stock_paths=None,previous_system_sha256=None):
    previous_system_sha256 = previous_system_sha256 or {}
    for name,original_sha in originals.items():
        row=before.get(str(SOUNDS/name))
        if row is not None and row.get('exists') is False and required_stock_paths is not None and name not in required_stock_paths:
            continue # Explicit absent state was captured before adding a missing historical rate.
        allowed = {original_sha, new[name]['sha256']}
        if name in previous_system_sha256: allowed.add(previous_system_sha256[name])
        if row is None or not row.get('exists') or row.get('sha256')not in allowed:
            raise ValueError('A pre-upgrade system prompt was customised or absent. Recover the original installation and review its voice choice.')


def voice_module(package):
    helper = Path(package)/'voice-tools/deployment.py'
    spec = importlib.util.spec_from_file_location('installed_voice_deployment',helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def payload(package, manifest, *, sounds_root=SOUNDS, fresh=False, include_native=True):
    package = Path(package)
    native = native_payload(package, manifest) if not fresh and include_native else {}
    base = package/'voices/1.0.2'
    if not base.exists():
        # Older immutable release archives have no voice overlay.
        if any(name.startswith('voices/') for name in manifest['files']):
            raise ValueError('The release voice directory is incomplete.')
        return native
    required = {'voice-tools/voicepack.py','voice-tools/deployment.py',
                'voices/1.0.2/catalog.json','voices/1.0.2/pack.json','voices/1.0.2/LICENSE-FreeSWITCH.txt'}
    for name in required:
        path = package/name
        if path.is_symlink() or not path.is_file() or digest(path) != manifest['files'].get(name):
            raise ValueError('The voice tools or catalogue differ from the reviewed release.')
    for path in base.rglob('*'):
        if path.is_symlink():
            raise ValueError('A release voice file is linked.')
        if path.is_file():
            if digest(path) != manifest['files'].get(path.relative_to(package).as_posix()):
                raise ValueError('The offline voice pack differs from the reviewed release.')
    module = voice_module(package)
    catalog = module.voicepack.load_catalog(base/'catalog.json')
    required=None if fresh else required_stock_paths(package,manifest)
    result = module.deployment_files(base,catalog,sounds_root,fresh=fresh,required_stock_paths=required)
    result.update(native)
    return result


def copy_files(mappings):
    for target, source in mappings.items():
        # Caller must finish complete preflight and recovery inventory before
        # entering this function. No network is used during activation.
        missing=[]
        directory=target.parent
        while not directory.exists():
            missing.append(directory)
            directory=directory.parent
        for directory in reversed(missing):
            directory.mkdir(mode=0o755)
            directory.chmod(0o755)
        for parent in [target,*target.parents]:
            if parent.is_symlink():
                raise ValueError('A voice destination became linked during activation.')
        existing = target.stat() if target.exists() else None
        fd, name = tempfile.mkstemp(prefix='.system-voice-',dir=target.parent)
        try:
            with os.fdopen(fd,'wb') as stream, source.open('rb') as audio:
                shutil.copyfileobj(audio,stream,1024*1024)
                stream.flush(); os.fsync(stream.fileno())
                os.fchmod(stream.fileno(),existing.st_mode & 0o777 if existing else 0o640)
                os.fchown(stream.fileno(),existing.st_uid if existing else 33,existing.st_gid if existing else 33)
            os.replace(name,target)
            directory = os.open(target.parent,os.O_RDONLY|os.O_DIRECTORY)
            try: os.fsync(directory)
            finally: os.close(directory)
        finally:
            if os.path.exists(name): os.unlink(name)


def main():
    if os.geteuid() != 0:
        raise PermissionError('The voice installer must run as root.')
    manifest = json.loads((PACKAGE/'release-manifest.json').read_text())
    # Fresh configure calls payload/copy_files directly before the engine starts.
    # Existing installations require the paused updater and validated snapshot.
    journal_path = Path('/var/lib/openwebpbx/updates/install-journal.json')
    if not journal_path.is_file():
        raise ValueError('Use the recoverable instance updater to activate system voices.')
    journal = json.loads(journal_path.read_text())
    if journal.get('state') != 'migrating' or journal.get('version') != manifest['version']:
        raise ValueError('The voice installer is outside its update transaction.')
    mappings = payload(PACKAGE,manifest,include_native=False)
    spec = importlib.util.spec_from_file_location('voice_support',PACKAGE/'install-support.py')
    support = importlib.util.module_from_spec(spec); spec.loader.exec_module(support)
    backup = Path(journal['backup_path'])
    if backup.parent != Path('/var/backups/openwebpbx') or backup.is_symlink() or not backup.name.startswith('upgrade-'):
        raise ValueError('Invalid private voice recovery location.')
    status = backup.stat()
    if status.st_uid != 0 or status.st_mode & 0o077:
        raise ValueError('The voice recovery snapshot is not private.')
    spec = importlib.util.spec_from_file_location('voice_upgrade',PACKAGE/'upgrade.py')
    upgrade = importlib.util.module_from_spec(spec); spec.loader.exec_module(upgrade)
    upgrade.validate_backup(backup)
    require_native_snapshot(backup,manifest)
    support.augment_snapshot(backup,list(mappings))
    upgrade.validate_backup(backup)
    # Legacy updaters already deployed their four original OpenWeb prompt
    # paths. Check the true pre-upgrade snapshot as well as the current files,
    # so an administrator's replacement is not hidden by that older copy step.
    catalog = json.loads((PACKAGE/'voices/1.0.2/catalog.json').read_text())
    originals = catalog['stock_original_sha256']
    new = json.loads((PACKAGE/'voices/1.0.2/pack.json').read_text())['files']
    before = {row['path']:row for row in json.loads((backup/'files.json').read_text())}
    verify_original_snapshot(originals,new,before,required_stock_paths(PACKAGE,manifest),catalog.get('previous_system_sha256'))
    copy_files(mappings)


if __name__ == '__main__':
    main()
