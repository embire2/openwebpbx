#!/usr/bin/env python3
"""Assemble the public ordered-upgrade repair without any installed PBX data."""
import argparse
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging/updates'))
from verify_feed import KEY_ID, no_duplicate_keys, timestamp, verify


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'packaging/updates' / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


repair = module('windows_repair_signer', 'sign-windows-updater-repair.py')
path_signer = module('windows_path_signer', 'sign-windows-upgrade-path.py')
SCRIPTS = ('Start-UpgradePathRepair.ps1', 'Start-UpgradePathRepair.cmd',
           'Invoke-UpgradePath.ps1', 'UpgradePath.Download.ps1')
CATALOGUE = ('1.0.21.json', '1.0.22.json', '1.0.23.json', 'windows-upgrade-path.json')
PREFIX = 'openwebpbx-1.0.23-windows-updater-repair'
PUBLIC_KEY = ROOT / 'packaging/updates/release-public.pem'


def bounded(path, maximum=262144):
    path = repair.ordinary(path)
    if path.stat().st_size > maximum:
        raise ValueError('A public repair input exceeds its size limit.')
    return path.read_bytes()


def signed_payload(path, public_key):
    envelope = bounded(path)
    outer = json.loads(envelope, object_pairs_hook=no_duplicate_keys)
    if not isinstance(outer, dict) or set(outer) != {'key_id', 'payload', 'signature'} or outer['key_id'] != KEY_ID:
        raise ValueError('The repair metadata signing key is not trusted.')
    data = base64.b64decode(outer['payload'], validate=True)
    signature = base64.b64decode(outer['signature'], validate=True)
    if not data or not 256 <= len(signature) <= 1024:
        raise ValueError('The repair metadata signature is invalid.')
    with tempfile.TemporaryDirectory(prefix='openweb-repair-verify-') as folder:
        unsigned, signed = Path(folder) / 'payload', Path(folder) / 'signature'
        unsigned.write_bytes(data)
        signed.write_bytes(signature)
        subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public_key),
                        '-signature', str(signed), str(unsigned)], check=True, capture_output=True)
    payload = json.loads(data, object_pairs_hook=no_duplicate_keys)
    if not isinstance(payload, dict):
        raise ValueError('The signed repair metadata must be an object.')
    return payload, envelope


def valid_dates(payload, now, maximum_days):
    def utc(value):
        # Retain the already qualified component envelope's +00:00 spelling;
        # the current signer emits the equivalent Z form. Never rewrite either.
        if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|\+00:00)', value):
            raise ValueError('Signed repair dates must use UTC.')
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    published, expires = utc(payload['published_at']), utc(payload['expires_at'])
    if (published > now + dt.timedelta(minutes=5) or expires <= now or expires <= published
            or expires > published + dt.timedelta(days=maximum_days)):
        raise ValueError('Signed repair metadata is expired or has invalid dates.')
    return expires


def runner_inputs(runner, manifest, public_key, now):
    runner = repair.ordinary(runner, directory=True)
    inventory = repair.inventory(runner)
    payload, envelope = signed_payload(manifest, public_key)
    if set(payload) != {'schema', 'kind', 'product', 'repair_id', 'version',
                       'minimum_installed_version', 'maximum_installed_version',
                       'published_at', 'expires_at', 'files'}:
        raise ValueError('The updater repair contains unsupported metadata fields.')
    expected = repair.build(runner, now=now)
    for field in set(expected) - {'published_at', 'expires_at'}:
        if payload[field] != expected[field] or type(payload[field]) is not type(expected[field]):
            raise ValueError('The runner differs from its qualified signed repair inventory.')
    valid_dates(payload, now, 180)
    files, total = {}, 0
    json_names = {'appsettings.json', 'appsettings.Development.json',
                  'OpenWebPbx.Updater.runtimeconfig.json', 'OpenWebPbx.Updater.deps.json'}
    logging = {'Logging': {'LogLevel': {'Default': 'Information', 'Microsoft.Hosting.Lifetime': 'Information'}}}
    for relative, digest in inventory.items():
        path = runner / relative
        # Published runtime files only. No environment files, keys, operational
        # configuration, database archives, logs or customer media are admitted.
        if (any(part.startswith('.') for part in Path(relative).parts)
                or path.suffix.lower() not in {'.dll', '.exe', '.pdb', '.json'}
                or path.suffix.lower() == '.json' and relative not in json_names):
            raise ValueError('The runner contains a private or unsupported public file.')
        if relative.startswith('appsettings.') and json.loads(bounded(path), object_pairs_hook=no_duplicate_keys) != logging:
            raise ValueError('Only the public default logging settings may be distributed.')
        size = path.stat().st_size
        if size > 134217728:
            raise ValueError('A runner file exceeds the qualified launcher size limit.')
        total += size
        files['runner/' + relative] = (path, digest)
    if total > 256 * 1024**2:
        raise ValueError('The component repair is unexpectedly large.')
    return files, envelope


def catalogue_inputs(directory, public_key, now):
    directory = repair.ordinary(directory, directory=True)
    if {path.name for path in directory.iterdir()} != set(CATALOGUE):
        raise ValueError('Use a clean catalogue directory containing only the four named signed envelopes.')
    envelopes = {name: bounded(directory / name) for name in CATALOGUE}
    releases = [verify(envelopes[name], public_key, now=now)[0] for name in CATALOGUE[:3]]
    if [item['version'] for item in releases] != ['1.0.21', '1.0.22', '1.0.23']:
        raise ValueError('The catalogue contains the wrong historical Windows releases.')
    payload, _ = signed_payload(directory / CATALOGUE[-1], public_key)
    expiry = valid_dates(payload, now, 366)
    expected = path_signer.build('1.0.20', envelopes['1.0.23.json'],
                                 [envelopes[name] for name in CATALOGUE[:3]], public_key,
                                 payload['sequence'], now=now, days=366)
    if set(payload) != set(expected) or any(payload[key] != expected[key] or type(payload[key]) is not type(expected[key])
                                           for key in set(expected) - {'published_at', 'expires_at'}):
        raise ValueError('The signed catalogue does not bind the exact supported release chain and latest authority.')
    if any(expiry > timestamp(item['expires_at']) for item in releases):
        raise ValueError('The catalogue outlives an independently signed release.')
    return envelopes


def committed_source(source_commit):
    if not re.fullmatch(r'[a-f0-9]{40}', source_commit):
        raise ValueError('Use the complete lowercase source commit ID.')
    subprocess.run(['git', 'cat-file', '-e', source_commit + '^{commit}'], cwd=ROOT,
                   check=True, capture_output=True)
    sources = {name: ROOT / 'packaging/windows' / name for name in SCRIPTS}
    if (ROOT / 'LICENSE').exists():
        sources['LICENSE'] = ROOT / 'LICENSE'
    for name, path in sources.items():
        data = bounded(path, 1048576)
        committed = subprocess.run(['git', 'show', source_commit + ':' + path.relative_to(ROOT).as_posix()],
                                   cwd=ROOT, check=True, capture_output=True).stdout
        if data != committed:
            raise ValueError('Public scripts and licence must match the stated source commit before packaging.')
    subprocess.run(['git', 'cat-file', '-e', source_commit + ':docs/windows-upgrade-path-repair.md'],
                   cwd=ROOT, check=True, capture_output=True)
    return sources


def build(runner, manifest, catalogue, source_commit, output, *, public_key=PUBLIC_KEY, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    public_key = repair.ordinary(public_key)
    output = Path(output).absolute()
    repair.ordinary(output.parent, directory=True)
    if output.resolve().is_relative_to(ROOT.resolve()) or output.exists() or output.is_symlink() or output.suffix.lower() != '.zip':
        raise ValueError('Use a new ZIP filename outside the source checkout; retained artifacts are never overwritten.')
    sources = committed_source(source_commit)
    files, repair_envelope = runner_inputs(runner, manifest, public_key, now)
    envelopes = catalogue_inputs(catalogue, public_key, now)
    for name, path in sources.items():
        files[name] = (path, hashlib.sha256(bounded(path, 1048576)).hexdigest())
    generated = {'repair-updater-manifest.json': repair_envelope,
                 **{'catalogue/' + name: value for name, value in envelopes.items()}}
    generated['SOURCE.txt'] = (
        'OpenWebPBX Windows ordered-upgrade repair\n'
        'Component version: 1.0.23+upgrade-path.1\n'
        'Repair ID: upgrade-path-1\n'
        f'Source commit: {source_commit}\n'
        f'Source: https://github.com/embire2/openwebpbx/tree/{source_commit}\n'
        'Guide: https://github.com/embire2/openwebpbx/blob/customization/docs/windows-upgrade-path-repair.md\n'
        '\nExtract the complete ZIP and open Start-UpgradePathRepair.cmd.\n'
        'Administrator permission is required. Full signed releases download automatically.\n'
        'This is an updater repair, not a replacement full-server installer.\n'
    ).encode('utf-8')
    # Build privately and promote without overwriting even under an output race.
    descriptor, temporary = tempfile.mkstemp(prefix='.windows-repair-', suffix='.zip', dir=output.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(descriptor, 'w+b') as stream:
            with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
                for name, (path, digest) in sorted(files.items()):
                    data = bounded(path, 134217728)
                    if hashlib.sha256(data).hexdigest() != digest:
                        raise ValueError('An allowlisted public input changed during packaging.')
                    archive.writestr(PREFIX + '/' + name, data)
                for name, data in sorted(generated.items()):
                    archive.writestr(PREFIX + '/' + name, data)
            stream.flush()
            os.fsync(stream.fileno())
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None or len(archive.infolist()) != len(files) + len(generated):
                raise ValueError('The completed repair ZIP failed independent inventory/CRC validation.')
        os.link(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    with output.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'artifact': output.name, 'bytes': output.stat().st_size, 'sha256': digest,
            'repair_id': 'upgrade-path-1', 'version': '1.0.23+upgrade-path.1',
            'source_commit': source_commit, 'files': len(files) + len(generated),
            'full_release_archives_included': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--repair-manifest', type=Path, required=True)
    parser.add_argument('--catalogue-dir', type=Path, required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        receipt = build(args.runner, args.repair_manifest, args.catalogue_dir, args.source_commit, args.output)
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.error('The public updater repair could not be assembled: ' + type(error).__name__)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
