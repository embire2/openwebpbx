#!/usr/bin/env python3
"""Sign the qualified upgrade-path-1 Windows updater component, never a release feed.

The component is a separately recorded 1.0.23 repair, applicable to installed
1.0.20–1.0.23. Qualification and installation are separate operator actions.
The original release archives and ordinary signed release feeds stay unchanged.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile

from verify_feed import KEY_ID

FILE_COUNT = 227
REQUIRED = frozenset(('OpenWebPbx.Updater.exe', 'OpenWebPbx.Updater.dll',
                      'OpenWebPbx.Updater.deps.json', 'OpenWebPbx.Updater.runtimeconfig.json'))
REPOSITORY = Path(__file__).resolve().parents[2]


def ordinary(path, *, directory=False):
    path = Path(path).absolute()
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError('Repair inputs must not contain symbolic links.')
    mode = path.stat().st_mode
    if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
        raise ValueError('Use ordinary repair files and directories.')
    if not directory and path.stat().st_nlink != 1:
        raise ValueError('Repair inputs must not contain hard links.')
    return path


def inventory(root):
    root = ordinary(root, directory=True)
    files, insensitive = {}, set()
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Repair inputs must not contain symbolic links.')
        name = path.relative_to(root).as_posix()
        for part in name.split('/'):
            if (not part or part in ('.', '..') or part[-1:] in ('.', ' ')
                    or re.search(r'[\x00-\x1f\x7f\\:<>"|?*]', part)
                    or re.fullmatch(r'(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', part)):
                raise ValueError('The repair contains a path unsafe on Windows.')
        if name.casefold() in insensitive:
            raise ValueError('The repair contains case-insensitive duplicate paths.')
        insensitive.add(name.casefold())
        if path.is_dir():
            ordinary(path, directory=True)
            continue
        ordinary(path)
        with path.open('rb') as stream:
            files[name] = hashlib.file_digest(stream, 'sha256').hexdigest()
    if len(files) != FILE_COUNT or not REQUIRED <= files.keys():
        raise ValueError('The qualified repair requires exactly 227 files and its complete updater entry points.')
    return files


def build(root, *, now=None, days=150):
    if type(days) is not int or not 1 <= days <= 180:
        raise ValueError('Use an expiry of 1–180 days for this component repair.')
    now = now or dt.datetime.now(dt.timezone.utc)
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError('The publication timestamp must include its timezone.')
    now = now.astimezone(dt.timezone.utc).replace(microsecond=0)
    return {'schema': 1, 'kind': 'windows-updater-repair', 'product': 'openwebpbx',
            'repair_id': 'upgrade-path-1', 'version': '1.0.23',
            'minimum_installed_version': '1.0.20', 'maximum_installed_version': '1.0.23',
            'published_at': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'expires_at': (now + dt.timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'files': inventory(root)}


def sign(root, private_key, public_key, output, *, days=150):
    root, private_key, public_key = ordinary(root, directory=True), ordinary(private_key), ordinary(public_key)
    key_stat = private_key.stat()
    if (private_key.resolve().is_relative_to(REPOSITORY) or key_stat.st_uid != os.geteuid()
            or stat.S_IMODE(key_stat.st_mode) != 0o600):
        raise ValueError('Use an account-owned mode600 signing key outside the source checkout.')
    output = Path(output).absolute()
    ordinary(output.parent, directory=True)
    if output.exists() or output.is_symlink() or output.is_relative_to(root):
        raise ValueError('Use a new output file outside the repair inventory; retained metadata is never overwritten.')
    payload = build(root, days=days)
    data = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode('utf-8')
    with tempfile.TemporaryDirectory(prefix='openweb-updater-repair-sign-') as folder:
        unsigned, signature_file = Path(folder) / 'payload', Path(folder) / 'signature'
        unsigned.write_bytes(data)
        signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(private_key), str(unsigned)],
                                   check=True, capture_output=True).stdout
        signature_file.write_bytes(signature)
        subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public_key),
                        '-signature', str(signature_file), str(unsigned)], check=True, capture_output=True)
    if inventory(root) != payload['files']:
        raise ValueError('The repair changed while its manifest was being signed.')
    envelope = json.dumps({'key_id': KEY_ID, 'payload': base64.b64encode(data).decode('ascii'),
                           'signature': base64.b64encode(signature).decode('ascii')},
                          separators=(',', ':')).encode('ascii') + b'\n'
    if len(envelope) > 262144:
        raise ValueError('The signed repair manifest exceeds the Windows verifier limit.')
    # Exclusive creation preserves historical manifests, including under races.
    with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        stream.write(envelope)
        stream.flush()
        os.fsync(stream.fileno())
    return {'repair_id': payload['repair_id'], 'version': payload['version'],
            'minimum_installed_version': payload['minimum_installed_version'],
            'maximum_installed_version': payload['maximum_installed_version'],
            'files': len(payload['files']), 'expires_at': payload['expires_at'],
            'envelope_sha256': hashlib.sha256(envelope).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repair-root', type=Path, required=True)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, default=Path(__file__).with_name('release-public.pem'))
    parser.add_argument('--expires-days', type=int, default=150)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        receipt = sign(args.repair_root, args.private_key, args.public_key, args.output, days=args.expires_days)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.error('The Windows updater repair could not be signed: ' + type(error).__name__)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
