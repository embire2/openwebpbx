#!/usr/bin/env python3
"""Sign an ordered Windows path using existing, independently signed releases."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify_feed import KEY_ID, timestamp, verify, version


def build(minimum, latest_bytes, step_bytes, public_key, sequence, *, now=None, days=180):
    now = now or dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    version(minimum)
    if type(sequence) is not int or not 1 <= sequence < 2**63 or not 1 <= days <= 366:
        raise ValueError('Choose a positive catalogue sequence and an expiry of 1–366 days.')
    latest, latest_digest = verify(latest_bytes, public_key, now=now)
    if len(latest['assets']) != 1 or latest['assets'][0]['platform'] != 'windows-x64':
        raise ValueError('Use the independent signed Windows latest envelope.')
    if not 1 <= len(step_bytes) <= 32 or step_bytes[-1] != latest_bytes:
        raise ValueError('The path must end with the exact latest Windows envelope.')
    steps, previous = [], minimum
    expires = min(now + dt.timedelta(days=days), timestamp(latest['expires_at']))
    for data in step_bytes:
        release, _ = verify(data, public_key, now=now)
        if len(release['assets']) != 1 or release['assets'][0]['platform'] != 'windows-x64':
            raise ValueError('Each step must be an independent signed Windows envelope.')
        asset = release['assets'][0]
        if version(release['version']) <= version(previous) or version(previous) < version(asset['minimum_version']):
            raise ValueError('A step does not follow its actual supported predecessor.')
        steps.append({'previous_version': previous, 'version': release['version'],
                      'envelope_sha256': hashlib.sha256(data).hexdigest()})
        previous = release['version']
        expires = min(expires, timestamp(release['expires_at']))
    if previous != latest['version'] or expires <= now:
        raise ValueError('The upgrade path is incomplete or expired.')
    return {'schema': 1, 'kind': 'windows-upgrade-path', 'product': 'openwebpbx',
            'channel': 'stable', 'platform': 'windows-x64', 'sequence': sequence,
            'published_at': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'expires_at': expires.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'minimum_installed_version': minimum, 'latest_version': latest['version'],
            'latest_payload_sha256': latest_digest, 'latest_sequence': latest['sequence'],
            'steps': steps}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-key', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, default=Path(__file__).with_name('release-public.pem'))
    parser.add_argument('--minimum-installed-version', default='1.0.20')
    parser.add_argument('--latest-envelope', type=Path, required=True)
    parser.add_argument('--step', type=Path, action='append', required=True,
                        help='Platform-tag envelope for each published Windows release, in installation order.')
    parser.add_argument('--sequence', type=int, required=True)
    parser.add_argument('--expires-days', type=int, default=180)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    key = args.private_key
    repository = Path(__file__).resolve().parents[2]
    if key.is_symlink() or key.resolve().is_relative_to(repository) or key.stat().st_uid != os.geteuid() or key.stat().st_mode & 0o077:
        parser.error('Use an account-owned mode600 signing key outside the checkout.')
    try:
        for path in [args.latest_envelope, *args.step]:
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 262144:
                raise ValueError('Use ordinary bounded signed-envelope files.')
        payload = build(args.minimum_installed_version, args.latest_envelope.read_bytes(),
                        [path.read_bytes() for path in args.step], args.public_key,
                        args.sequence, days=args.expires_days)
        data = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        with tempfile.TemporaryDirectory(prefix='openweb-windows-path-sign-') as folder:
            unsigned = Path(folder) / 'payload'
            unsigned.write_bytes(data)
            signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key), str(unsigned)],
                                       check=True, capture_output=True).stdout
            signed = Path(folder) / 'signature'
            signed.write_bytes(signature)
            subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(args.public_key),
                            '-signature', str(signed), str(unsigned)], check=True, capture_output=True)
        envelope = {'key_id': KEY_ID, 'payload': base64.b64encode(data).decode(),
                    'signature': base64.b64encode(signature).decode()}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(envelope, separators=(',', ':')) + '\n')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.error('The Windows upgrade path could not be signed: ' + type(error).__name__)
    print(json.dumps({'latest_version': payload['latest_version'], 'steps': [s['version'] for s in payload['steps']],
                      'sequence': payload['sequence'], 'envelope_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest()}))


if __name__ == '__main__':
    main()
