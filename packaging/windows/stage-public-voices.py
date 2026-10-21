#!/usr/bin/env python3
"""Stage only the public, immutable Debian16 Nathaniel pack for Windows CI."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_SHA256 = '1d9c6f4fa481dbeb0d09938e13481c78ac32fa1a2048e9eed57507e94113b2af'
PREFIX = 'openwebpbx-1.0.16-debian13-amd64/voices/1.0.1/'


def stage(archive, destination):
    archive, destination = Path(archive), Path(destination)
    with archive.open('rb') as stream:
        checksum = hashlib.sha256()
        for block in iter(lambda: stream.read(1024*1024), b''):
            checksum.update(block)
        if checksum.hexdigest() != ARCHIVE_SHA256:
            raise ValueError('The immutable public voice source archive differs.')
    if destination.exists() or destination.is_symlink():
        raise ValueError('Choose a new voice output directory.')
    for parent in destination.parents:
        if parent.is_symlink() or getattr(parent, 'is_junction', lambda: False)():
            raise ValueError('The voice output is linked.')
    spec = importlib.util.spec_from_file_location('windows_public_voicepack', ROOT/'packaging/voices/voicepack.py')
    voices = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(voices)
    catalog = voices.load_catalog(voices.DEFAULT_CATALOG)
    expected = {'files/'+t['path'] for p in catalog['prompts'] for t in p['targets']}
    expected |= {'catalog.json', 'pack.json', 'LICENSE-FreeSWITCH.txt'}
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.windows-voices-', dir=destination.parent))
    seen, size = set(), 0
    try:
        with tarfile.open(archive, 'r|gz') as source:
            for member in source:
                if not member.name.startswith(PREFIX):
                    continue
                relative = member.name[len(PREFIX):]
                if member.isdir():
                    continue
                if not member.isfile() or relative not in expected or relative in seen or member.size > 12_000_000:
                    raise ValueError('The public voice inventory is unsafe or ambiguous.')
                seen.add(relative)
                size += member.size
                if size > 1_500_000_000:
                    raise ValueError('The voice inventory exceeds its size limit.')
                target = temporary/relative
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as incoming, target.open('xb') as output:
                    shutil.copyfileobj(incoming, output, 1024*1024)
        if seen != expected:
            raise ValueError('The immutable public voice inventory is incomplete.')
        with contextlib.redirect_stdout(io.StringIO()):
            voices.verify(catalog, temporary)
        temporary.rename(destination)
        return {'schema': 1, 'source_release': 'v1.0.16', 'source_archive_sha256': ARCHIVE_SHA256,
                'voice_version': '1.0.1', 'voice_files': len(expected)-3,
                'synthesis_requests': 0, 'private_credentials_used': False}
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    facts = stage(args.archive, args.output)
    print(json.dumps(facts))
