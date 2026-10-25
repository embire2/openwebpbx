#!/usr/bin/env python3
"""Apply only sealed system prompts while the Windows engine is stopped.

The caller owns the installation lock and, for upgrades, its complete sealed
sound-tree rollback. User greetings, messages, recordings and music are never
selected. Existing custom replacements at a system-prompt path refuse before
the first write instead of silently discarding them.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def ordinary(path):
    path = Path(path)
    for item in [path, *path.parents]:
        if item.is_symlink() or getattr(item, 'is_junction', lambda: False)():
            raise ValueError('A system-voice path is a link or junction.')
    if path.exists() and not path.is_file():
        raise ValueError('A system-voice file is not ordinary.')
    return path


def payload(package, sounds):
    package, sounds = Path(package), Path(sounds)
    manifest = json.loads(ordinary(package/'release-manifest.json').read_text(encoding='utf-8'))
    files = manifest['files']
    required = ['voice-tools/voicepack.py', 'voice-tools/deployment.py',
                'voices/1.0.2/catalog.json', 'voices/1.0.2/pack.json',
                'voices/1.0.2/LICENSE-FreeSWITCH.txt']
    base = package/'voices/1.0.2'
    if not base.is_dir():
        raise ValueError('The complete offline Keoma voice pack is required.')
    for name in required:
        if digest(ordinary(package/name)) != files.get(name):
            raise ValueError('A system-voice tool or catalogue differs from its release.')
    # Authenticate the complete tree before loading the sealed helper module.
    for path in base.rglob('*'):
        if path.is_symlink() or getattr(path, 'is_junction', lambda: False)():
            raise ValueError('A release voice path is linked.')
        if path.is_file() and digest(path) != files.get(path.relative_to(package).as_posix()):
            raise ValueError('The offline voice bytes differ from their release.')
    spec = importlib.util.spec_from_file_location('windows_voice_deployment', package/'voice-tools/deployment.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    catalog = module.voicepack.load_catalog(base/'catalog.json')
    # The pinned Windows MSI has a sparse stock sound inventory. Missing stock
    # rates are populated, while every existing owned path must match stock or
    # this exact verified pack. No custom replacement is accepted for overwrite.
    mappings = module.deployment_files(base, catalog, sounds, fresh=True)
    result = []
    for target, source in mappings.items():
        ordinary(target)
        result.append((target, source, digest(target) if target.exists() else None))
    return result


def copy_files(mappings):
    # Full preflight is complete. In-place stream replacement preserves the
    # original Windows file owner/DACL/SACL; the enclosing stopped-engine
    # transaction restores the sealed tree after any interruption or failure.
    for target, source, before in mappings:
        ordinary(target)
        if (digest(target) if target.exists() else None) != before:
            raise ValueError('A system prompt changed after voice preflight.')
        if before == digest(source):
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        ordinary(target)
        with source.open('rb') as incoming, target.open('wb') as outgoing:
            shutil.copyfileobj(incoming, outgoing, 1024*1024)
            outgoing.flush()
            os.fsync(outgoing.fileno())
        if digest(target) != digest(source):
            raise ValueError('A system prompt failed installed-byte verification.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--sounds', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    mappings = payload(args.package, args.sounds)
    if not args.check:
        copy_files(mappings)
    print(json.dumps({'voice_version': '1.0.2', 'mapped_files': len(mappings),
                      'activated': not args.check, 'customer_media_selected': False}))


if __name__ == '__main__':
    main()
