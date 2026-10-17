#!/usr/bin/env python3
"""Install sealed offline system voices inside the existing update transaction."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile

PACKAGE = Path(__file__).resolve().parent
SOUNDS = Path('/usr/share/freeswitch/sounds')


def digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle,'sha256').hexdigest()


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
    return module.deployment_files(base,catalog,sounds_root,fresh=fresh)


def copy_files(mappings):
    for target, source in mappings.items():
        # Caller must finish complete preflight and recovery inventory before
        # entering this function. No network is used during activation.
        target.parent.mkdir(parents=True,exist_ok=True)
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
    for name, original_sha in originals.items():
        row = before.get(str(SOUNDS/name))
        if row is None or not row.get('exists') or row.get('sha256') not in {original_sha,new[name]['sha256']}:
            raise ValueError('A pre-upgrade system prompt was customised or absent. Recover the original installation and review its voice choice.')
    copy_files(mappings)


if __name__ == '__main__':
    main()
