#!/usr/bin/env python3
"""Check an offline, single-platform promotion without changing signed feeds."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path

from verify_feed import MAX_ENVELOPE, verify, version


FEEDS = {
    'android-universal': 'update-manifest.json',
    'debian13-amd64': 'debian-update-manifest.json',
    'windows-x64': 'windows-update-manifest.json',
}


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=FEEDS, required=True)
    parser.add_argument('--before', type=Path, required=True, help='Reviewed current three-feed snapshot.')
    parser.add_argument('--after', type=Path, required=True, help='Proposed complete latest-release feed set.')
    parser.add_argument('--public-key', type=Path, default=Path(__file__).with_name('release-public.pem'))
    args = parser.parse_args()
    try:
        result = validate(read_feeds(args.before), read_feeds(args.after), args.platform, args.public_key)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
