#!/usr/bin/env python3
"""Install sealed offline system voices inside the existing update transaction."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import tarfile

PACKAGE = Path(__file__).resolve().parent
SOUNDS = Path('/usr/share/freeswitch/sounds')
KNOWN_ENGINE_SHA256 = '321e0d3ce65399d614107968e2a3a7ff8e0650eefcee68900af000736bb5ea01'


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


def verify_original_snapshot(originals,new,before,required_stock_paths=None):
    for name,original_sha in originals.items():
        row=before.get(str(SOUNDS/name))
        if row is not None and row.get('exists') is False and required_stock_paths is not None and name not in required_stock_paths:
            continue # Explicit absent state was captured before adding a missing historical rate.
        if row is None or not row.get('exists') or row.get('sha256')not in {original_sha,new[name]['sha256']}:
            raise ValueError('A pre-upgrade system prompt was customised or absent. Recover the original installation and review its voice choice.')


def voice_module(package):
    helper = Path(package)/'voice-tools/deployment.py'
    spec = importlib.util.spec_from_file_location('installed_voice_deployment',helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def payload(package, manifest, *, sounds_root=SOUNDS, fresh=False):
    package = Path(package)
    base = package/'voices/1.0.1'
    if not base.exists():
        # Older immutable release archives have no voice overlay.
        if any(name.startswith('voices/') for name in manifest['files']):
            raise ValueError('The release voice directory is incomplete.')
        return {}
    required = {'voice-tools/voicepack.py','voice-tools/deployment.py',
                'voices/1.0.1/catalog.json','voices/1.0.1/pack.json','voices/1.0.1/LICENSE-FreeSWITCH.txt'}
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
    return module.deployment_files(base,catalog,sounds_root,fresh=fresh,required_stock_paths=required)


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
    mappings = payload(PACKAGE,manifest)
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
    support.augment_snapshot(backup,list(mappings))
    upgrade.validate_backup(backup)
    # Legacy updaters already deployed their four original OpenWeb prompt
    # paths. Check the true pre-upgrade snapshot as well as the current files,
    # so an administrator's replacement is not hidden by that older copy step.
    originals = json.loads((PACKAGE/'voices/1.0.1/catalog.json').read_text())['stock_original_sha256']
    new = json.loads((PACKAGE/'voices/1.0.1/pack.json').read_text())['files']
    before = {row['path']:row for row in json.loads((backup/'files.json').read_text())}
    verify_original_snapshot(originals,new,before,required_stock_paths(PACKAGE,manifest))
    copy_files(mappings)


if __name__ == '__main__':
    main()
