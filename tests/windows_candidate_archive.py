#!/usr/bin/env python3
"""Verify an untouched Windows release ZIP before public candidate export.

This reads package bytes only. It never reads installation state, credentials,
customer backups, generated certificates or qualification fixtures.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import zipfile

PRIVATE_NAMES = {'config.conf', 'runtime.json', 'installation.json', 'setup-secrets.json',
                 'config.json', 'mobile-push.json', 'phone-tls.json', 'native-engine.json',
                 'openweb-template.key', 'pg_version', 'postgres-password.tmp'}
RESERVED = re.compile(r'^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)', re.I)


def safe_relative(name):
    if not isinstance(name, str) or not name or name.startswith('/') or re.search(r'[\\<>:"|?*\x00-\x1f\x7f]', name):
        raise ValueError('Candidate archive has a forbidden Windows path.')
    if any(not part or part in ('.', '..') or part.endswith((' ', '.')) or RESERVED.match(part)
           for part in name.split('/')):
        raise ValueError('Candidate archive has an unsafe Windows path component.')
    return name


def verify(path, version, expected_sha256=None):
    path = Path(path)
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Candidate archive version is invalid.')
    with path.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    if expected_sha256 is not None and checksum != expected_sha256:
        raise ValueError('Candidate archive checksum changed before export.')
    root = 'openwebpbx-' + version + '-windows-x64/'
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 100000 or sum(entry.file_size for entry in entries) > 20 * 1024**3:
            raise ValueError('Candidate archive exceeds the bounded package inventory.')
        names = {}
        for entry in entries:
            if entry.filename == root and entry.is_dir():
                continue
            if not entry.filename.startswith(root):
                raise ValueError('Candidate archive has an unexpected root.')
            name = safe_relative(entry.filename[len(root):].rstrip('/'))
            folded = name.casefold()
            if folded in names or entry.flag_bits & 1 or stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('Candidate archive has colliding, encrypted or linked entries.')
            names[folded] = (name, entry)
            if entry.file_size > 256 * 1024**2:
                raise ValueError('Candidate archive member exceeds its bounded size.')
        manifest_entry = names.get('release-manifest.json')
        if manifest_entry is None or manifest_entry[1].is_dir() or manifest_entry[1].file_size > 32 * 1024**2:
            raise ValueError('Candidate archive release manifest is missing or oversized.')
        manifest = json.loads(archive.read(manifest_entry[1]))
        if manifest.get('version') != version or not isinstance(manifest.get('files'), dict):
            raise ValueError('Candidate archive release manifest is invalid.')
        actual = {name for name, entry in names.values() if not entry.is_dir()}
        if actual != set(manifest['files']) | {'release-manifest.json'}:
            raise ValueError('Candidate archive contains missing or unlisted files.')
        for name, expected in manifest['files'].items():
            safe_relative(name)
            if not isinstance(expected, str) or not re.fullmatch(r'[a-f0-9]{64}', expected):
                raise ValueError('Candidate archive member checksum is invalid.')
            entry = names[name.casefold()][1]
            # Verified public codec source contains upstream example keys/config;
            # installed runtime locations may never carry machine-private data.
            if not name.startswith('codec-source/'):
                base = name.rsplit('/', 1)[-1].casefold()
                if base in PRIVATE_NAMES or base.startswith('.env') or base.endswith(('.key', '.pfx', '.p12', '.dump', '.owpbx')):
                    raise ValueError('Candidate archive includes runtime-private material.')
                if base in ('mod_bcg729.dll', 'libbcg729.dll'):
                    raise ValueError('Candidate archive includes a locally built codec binary.')
                if base.endswith(('.pem', '.json', '.txt')) and entry.file_size <= 1024**2:
                    beginning = archive.read(entry)[:512].lstrip()
                    if re.match(rb'-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----', beginning):
                        raise ValueError('Candidate archive includes private PEM material.')
            with archive.open(entry) as stream:
                actual_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
            if actual_hash != expected:
                raise ValueError('Candidate archive member failed exact hash verification.')
    return {'version': version, 'sha256': checksum, 'files': len(manifest['files']), 'private_exclusions': 'passed'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--sha256', required=True)
    arguments = parser.parse_args()
    result = verify(arguments.archive, arguments.version, arguments.sha256)
    print('Original candidate archive verified: ' + str(result['files']) + ' files; private exclusions passed.')
