#!/usr/bin/env python3
"""Check an offline, single-platform promotion without changing signed feeds."""
import argparse
import base64
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from verify_feed import KEY_ID, MAX_ENVELOPE, no_duplicate_keys, timestamp, verify, version


FEEDS = {
    'android-universal': 'update-manifest.json',
    'debian13-amd64': 'debian-update-manifest.json',
    'windows-x64': 'windows-update-manifest.json',
}
CATALOGUE = 'windows-upgrade-path.json'


def validate(before, after, platform, public_key, *, now=None):
    """Validate complete feed sets; only the selected platform may advance."""
    names = set(FEEDS.values())
    if platform not in FEEDS or set(before) != names or set(after) != names:
        raise ValueError('Supply one supported platform and all three fixed feeds before and after.')
    changed = FEEDS[platform]
    for name in names - {changed}:
        if after[name] != before[name]:
            raise ValueError('Another platform signed envelope changed: ' + name)

    now = now or dt.datetime.now(dt.timezone.utc)
    previous = {}
    for owner, name in FEEDS.items():
        payload, digest = verify(before[name], public_key, now=now)
        if not any(asset['platform'] == owner for asset in payload['assets']):
            raise ValueError('A retained feed is missing its designated platform: ' + name)
        previous[name] = (payload, digest)

    old, old_digest = previous[changed]
    promoted, digest = verify(after[changed], public_key, now=now,
                              previous={'sequence': old['sequence'], 'payload_sha256': old_digest})
    if len(promoted['assets']) != 1 or promoted['assets'][0]['platform'] != platform:
        raise ValueError('Promote only the selected platform in its fixed feed.')
    if version(promoted['version']) <= version(old['version']) or promoted['sequence'] <= old['sequence']:
        raise ValueError('The selected platform must advance its own version and sequence.')
    asset = promoted['assets'][0]
    old_asset = next(item for item in old['assets'] if item['platform'] == platform)
    if platform == 'android-universal' and asset['version_code'] <= old_asset['version_code']:
        raise ValueError('The Android version code must advance past its own previous release.')

    feeds = {}
    for owner, name in FEEDS.items():
        payload, payload_digest = (promoted, digest) if name == changed else previous[name]
        selected = next(item for item in payload['assets'] if item['platform'] == owner)
        minimum = 'minimum_server_version' if owner == 'android-universal' else 'minimum_version'
        feeds[name] = {'version': payload['version'], 'sequence': payload['sequence'],
                       'envelope_sha256': hashlib.sha256(after[name]).hexdigest(),
                       'payload_sha256': payload_digest, minimum: selected[minimum],
                       'retained_byte_exact': name != changed}
    return {'platform': platform, 'promoted_feed': changed, 'previous_version': old['version'],
            'other_signed_envelopes_byte_exact': True, 'feeds': feeds}


def read_feeds(directory):
    result = {}
    for name in FEEDS.values():
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_ENVELOPE:
            raise ValueError('Feed files must be ordinary bounded signed envelopes: ' + name)
        result[name] = path.read_bytes()
    return result


def read_catalogue(directory):
    path = directory / CATALOGUE
    if path.is_symlink():
        raise ValueError('The Windows upgrade catalogue must be an ordinary file.')
    if not path.exists():
        return None
    if not path.is_file() or path.stat().st_size > MAX_ENVELOPE:
        raise ValueError('The Windows upgrade catalogue must be an ordinary bounded envelope.')
    return path.read_bytes()


def verify_catalogue(envelope, latest_envelope, public_key, *, now):
    """Publication metadata guard; full step/package admission stays in the updater."""
    if not isinstance(envelope, bytes) or not 0 < len(envelope) <= MAX_ENVELOPE:
        raise ValueError('The signed Windows upgrade catalogue is missing or too large.')
    try:
        outer = json.loads(envelope, object_pairs_hook=no_duplicate_keys)
        if not isinstance(outer, dict) or set(outer) != {'key_id', 'payload', 'signature'} or outer['key_id'] != KEY_ID:
            raise ValueError('The Windows catalogue signing key is not trusted.')
        raw = base64.b64decode(outer['payload'], validate=True)
        signature = base64.b64decode(outer['signature'], validate=True)
        if not raw or not 256 <= len(signature) <= 1024:
            raise ValueError('The Windows catalogue signature is invalid.')
        with tempfile.TemporaryDirectory(prefix='openweb-catalogue-promotion-') as folder:
            payload_path, signature_path = Path(folder) / 'payload', Path(folder) / 'signature'
            payload_path.write_bytes(raw)
            signature_path.write_bytes(signature)
            checked = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public_key),
                                      '-signature', str(signature_path), str(payload_path)], capture_output=True)
            if checked.returncode:
                raise ValueError('The Windows catalogue signature does not match the pinned key.')
        payload = json.loads(raw, object_pairs_hook=no_duplicate_keys)
    except (KeyError, TypeError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError('The Windows upgrade catalogue is malformed.') from error
    fields = {'schema', 'kind', 'product', 'channel', 'platform', 'sequence', 'published_at', 'expires_at',
              'minimum_installed_version', 'latest_version', 'latest_payload_sha256', 'latest_sequence', 'steps'}
    if (not isinstance(payload, dict) or set(payload) != fields or type(payload['schema']) is not int
            or payload['schema'] != 1 or payload['kind'] != 'windows-upgrade-path'
            or payload['product'] != 'openwebpbx' or payload['channel'] != 'stable' or payload['platform'] != 'windows-x64'):
        raise ValueError('The Windows upgrade catalogue namespace or schema is unsupported.')
    if type(payload['sequence']) is not int or not 1 <= payload['sequence'] < 2**63:
        raise ValueError('The Windows catalogue sequence is invalid.')
    published, expires = timestamp(payload['published_at']), timestamp(payload['expires_at'])
    if published > now + dt.timedelta(minutes=5) or expires <= now or expires <= published:
        raise ValueError('The Windows upgrade catalogue is expired or has invalid dates.')
    latest, latest_digest = verify(latest_envelope, public_key, now=now)
    if len(latest['assets']) != 1 or latest['assets'][0]['platform'] != 'windows-x64':
        raise ValueError('The catalogue needs an independent Windows latest envelope.')
    if (payload['latest_version'] != latest['version'] or type(payload['latest_sequence']) is not int
            or payload['latest_sequence'] != latest['sequence'] or payload['latest_payload_sha256'] != latest_digest):
        raise ValueError('The catalogue does not bind the exact Windows latest payload and sequence.')
    previous = payload['minimum_installed_version']
    version(previous)
    steps = payload['steps']
    if not isinstance(steps, list) or not 1 <= len(steps) <= 32:
        raise ValueError('The Windows catalogue has an invalid step count.')
    for step in steps:
        if (not isinstance(step, dict) or set(step) != {'previous_version', 'version', 'envelope_sha256'}
                or step['previous_version'] != previous or version(step['version']) <= version(previous)
                or not isinstance(step['envelope_sha256'], str) or not re.fullmatch('[a-f0-9]{64}', step['envelope_sha256'])):
            raise ValueError('The Windows catalogue has an invalid predecessor chain or envelope hash.')
        previous = step['version']
    if previous != latest['version'] or steps[-1]['envelope_sha256'] != hashlib.sha256(latest_envelope).hexdigest():
        raise ValueError('The Windows catalogue does not end with the exact latest envelope.')
    if version(steps[-1]['previous_version']) < version(latest['assets'][0]['minimum_version']):
        raise ValueError('The final Windows step does not satisfy its original minimum.')
    return payload, hashlib.sha256(raw).hexdigest()


def validate_catalogue_promotion(before, after, before_windows, after_windows, platform, public_key,
                                 *, now=None, historical=None):
    """Keep the original three-feed validate() API independent of this CLI guard."""
    now = now or dt.datetime.now(dt.timezone.utc)
    if before is not None and after is None:
        raise ValueError('Retain windows-upgrade-path.json in every latest-release promotion.')
    if platform != 'windows-x64':
        if before != after:
            raise ValueError('A non-Windows promotion must retain its Windows catalogue byte-for-byte.')
        if before is None:
            return {'present': False, 'retained_byte_exact': True}
    elif after is None:
        raise ValueError('A Windows promotion requires a fresh signed upgrade catalogue.')
    old_latest, old_digest = verify(before_windows, public_key, now=now)
    verify(after_windows, public_key, now=now,
           previous={'sequence': old_latest['sequence'], 'payload_sha256': old_digest})
    previous = verify_catalogue(before, before_windows, public_key, now=now)[0] if before is not None else None
    proposed, digest = verify_catalogue(after, after_windows, public_key, now=now)
    if platform == 'windows-x64' and previous is not None:
        if proposed['sequence'] <= previous['sequence']:
            raise ValueError('A Windows promotion must advance its catalogue sequence without conflicts.')
        if proposed['minimum_installed_version'] != previous['minimum_installed_version']:
            raise ValueError('Preserve the original Windows catalogue starting floor.')
        if proposed['steps'][:len(previous['steps'])] != previous['steps']:
            raise ValueError('Preserve every retained Windows step and original historical envelope hash.')
    historical = dict(historical or {})
    historical.setdefault(old_latest['version'], before_windows)
    historical.setdefault(proposed['latest_version'], after_windows)
    checked = 0
    for step in proposed['steps']:
        if step['version'] not in historical:
            continue
        envelope = historical[step['version']]
        if hashlib.sha256(envelope).hexdigest() != step['envelope_sha256']:
            raise ValueError('An available historical Windows envelope differs from its catalogue hash.')
        release, _ = verify(envelope, public_key, now=now)
        if (release['version'] != step['version'] or len(release['assets']) != 1
                or release['assets'][0]['platform'] != 'windows-x64'
                or version(step['previous_version']) < version(release['assets'][0]['minimum_version'])):
            raise ValueError('An available historical Windows step has the wrong identity or original minimum.')
        checked += 1
    return {'present': True, 'retained_byte_exact': before == after,
            'sequence': proposed['sequence'], 'latest_version': proposed['latest_version'],
            'payload_sha256': digest, 'steps': len(proposed['steps']),
            'available_step_envelopes_verified': checked, 'full_package_qualification': 'separate'}


def read_history(directories, catalogues):
    """Optional fixed VERSION.json files; a promotion never retrieves history."""
    versions = set()
    for envelope in catalogues:
        if envelope is None:
            continue
        # Only enumerate names from already verified catalogue metadata.
        versions.update(step['version'] for step in envelope['steps'])
    result = {}
    for release_version in versions:
        version(release_version)
        for directory in directories:
            for path in (directory / 'catalogue' / (release_version + '.json'), directory / (release_version + '.json')):
                if path.is_symlink():
                    raise ValueError('Historical Windows envelopes must be ordinary files.')
                if not path.exists():
                    continue
                if not path.is_file() or path.stat().st_size > MAX_ENVELOPE:
                    raise ValueError('Historical Windows envelopes must be ordinary bounded files.')
                data = path.read_bytes()
                if release_version in result and data != result[release_version]:
                    raise ValueError('Historical Windows envelope snapshots disagree for ' + release_version)
                result[release_version] = data
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=FEEDS, required=True)
    parser.add_argument('--before', type=Path, required=True, help='Reviewed current three-feed snapshot.')
    parser.add_argument('--after', type=Path, required=True, help='Proposed complete latest-release feed set.')
    parser.add_argument('--public-key', type=Path, default=Path(__file__).with_name('release-public.pem'))
    args = parser.parse_args()
    try:
        before, after = read_feeds(args.before), read_feeds(args.after)
        now = dt.datetime.now(dt.timezone.utc)
        result = validate(before, after, args.platform, args.public_key, now=now)
        before_catalogue, after_catalogue = read_catalogue(args.before), read_catalogue(args.after)
        catalogues = [verify_catalogue(raw, feeds['windows-update-manifest.json'], args.public_key, now=now)[0]
                      for raw, feeds in ((before_catalogue, before), (after_catalogue, after)) if raw is not None]
        result['windows_upgrade_path'] = validate_catalogue_promotion(
            before_catalogue, after_catalogue, before['windows-update-manifest.json'], after['windows-update-manifest.json'],
            args.platform, args.public_key, now=now, historical=read_history((args.before, args.after), catalogues))
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
