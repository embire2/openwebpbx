#!/usr/bin/env python3
"""Verified voice-pack staging and deployment mappings for the PBX installer.

This module deliberately does not stop calls or modify an installed sound tree.
The release updater must include these paths in its existing snapshot, paused
engine deployment and rollback transaction. A pack is usable offline after it
has been built; the instance never needs an ElevenLabs key for stock playback.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile

spec = importlib.util.spec_from_file_location('openweb_voicepack', Path(__file__).with_name('voicepack.py'))
voicepack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(voicepack)
PackError = voicepack.PackError


def file_digest(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def stage(archive, archive_sha256, destination, catalog):
    """Extract a pinned complete archive to a new directory, or change nothing."""
    archive, destination = Path(archive), Path(destination)
    if archive.is_symlink() or not archive.is_file():
        raise PackError('The voice archive must be an ordinary file.')
    if not voicepack.HASH.fullmatch(archive_sha256) or file_digest(archive) != archive_sha256:
        raise PackError('The voice archive checksum does not match the release pin.')
    if destination.exists() or destination.is_symlink():
        raise PackError('Choose a new ordinary voice staging directory.')
    for parent in destination.parents:
        if parent.is_symlink():
            raise PackError('The staging parent cannot be a symbolic link.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix='.voice-stage-', dir=destination.parent))
    expected = {'files/'+t['path'] for p in catalog['prompts'] for t in p['targets']}
    expected |= {'catalog.json','pack.json','LICENSE-FreeSWITCH.txt'}
    total, names = 0, set()
    try:
        with tarfile.open(archive, 'r:gz') as tar:
            for entry in tar:
                name = entry.name
                if not entry.isfile() or name not in expected or name in names or entry.size > 12_000_000:
                    raise PackError('The archive contains an unexpected voice member.')
                names.add(name); total += entry.size
                if total > 1_500_000_000:
                    raise PackError('The voice archive exceeds the installed size limit.')
                path = temp/name
                path.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(entry) as source, path.open('xb') as target:
                    shutil.copyfileobj(source,target,1024*1024)
                path.chmod(0o644)
        if names != expected:
            raise PackError('The voice archive is incomplete.')
        voicepack.verify(catalog,temp)
        os.replace(temp,destination)
        return destination
    finally:
        if temp.exists():
            shutil.rmtree(temp)


def deployment_files(pack_root, catalog, sounds_root, *, previous_manifest=None, fresh=False):
    """Return all source/destination mappings only after complete preflight.

    Existing custom replacements refuse rather than being overwritten. A prior
    voice manifest is accepted only after its enclosing installed release has
    independently been authenticated by the updater. There is no wildcard copy.
    """
    pack_root, sounds_root = Path(pack_root), Path(sounds_root)
    pack = voicepack.verify(catalog,pack_root)
    if previous_manifest is not None and (previous_manifest.get('provider') != 'ElevenLabs'
            or previous_manifest.get('voice_id') != catalog['voice_id']):
        raise PackError('The previous voice identity is not compatible.')
    result = {}
    for name, metadata in pack['files'].items():
        target = voicepack.safe_file(sounds_root,name)
        source = voicepack.safe_file(pack_root/'files',name)
        if target.exists():
            if not target.is_file():
                raise PackError('A voice destination is not an ordinary file.')
            allowed = {metadata['sha256']}
            if name in catalog['stock_original_sha256']:
                allowed.add(catalog['stock_original_sha256'][name])
            if previous_manifest:
                previous = previous_manifest.get('files',{}).get(name,{})
                if voicepack.HASH.fullmatch(previous.get('sha256','')):
                    allowed.add(previous['sha256'])
            if file_digest(target) not in allowed:
                raise PackError('An existing spoken prompt was customised. Preserve it and review before deploying this pack.')
        elif name in catalog['stock_original_sha256'] and not fresh:
            raise PackError('The installed stock inventory is incomplete. Voice activation has not started.')
        result[target] = source
    # The selected version marker participates in the same backup/recovery map.
    marker = sounds_root/'openwebpbx'/'voice-pack.json'
    for parent in [marker,*marker.parents]:
        if parent.is_symlink():
            raise PackError('The installed voice marker cannot be a symbolic link.')
        if parent == sounds_root:
            break
    if marker.exists() and not marker.is_file():
        raise PackError('The installed voice marker is not an ordinary file.')
    result[marker] = pack_root/'pack.json'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=voicepack.DEFAULT_CATALOG)
    commands = parser.add_subparsers(dest='command',required=True)
    extract = commands.add_parser('stage')
    extract.add_argument('--archive',type=Path,required=True)
    extract.add_argument('--sha256',required=True)
    extract.add_argument('--destination',type=Path,required=True)
    plan = commands.add_parser('plan')
    plan.add_argument('--pack',type=Path,required=True)
    plan.add_argument('--sounds-root',type=Path,required=True)
    plan.add_argument('--fresh',action='store_true')
    args = parser.parse_args(); catalog = voicepack.load_catalog(args.catalog)
    if args.command == 'stage':
        stage(args.archive,args.sha256,args.destination,catalog)
        print('Complete voice pack staged and verified; installed prompts were not changed.')
    else:
        mappings = deployment_files(args.pack,catalog,args.sounds_root,fresh=args.fresh)
        print(json.dumps({'version':catalog['version'],'deployment_mappings':len(mappings),'installed_prompts_changed':False}))


if __name__ == '__main__':
    try:
        main()
    except (PackError,OSError,ValueError,KeyError,tarfile.TarError) as error:
        print('Voice staging stopped: '+(str(error) if isinstance(error,PackError) else type(error).__name__))
        raise SystemExit(1)
