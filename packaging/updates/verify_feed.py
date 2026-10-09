#!/usr/bin/env python3
"""Verify the pinned release envelope before using release-controlled fields."""
import base64
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

KEY_ID = 'release-2026-a'
MAX_ENVELOPE = 256 * 1024
MAX_ARCHIVE = 2 * 1024 ** 3
PLATFORMS = {'debian13-amd64': 'debian13-amd64.tar.gz', 'windows-x64': 'windows-x64.zip', 'android-universal': 'android.apk'}


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ValueError('The release version is invalid.')
    parts = tuple(map(int, value.split('.')))
    if any(part > 2147483647 for part in parts):
        raise ValueError('The release version is too large.')
    return parts


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value):
        raise ValueError('Release times must use UTC.')
    return dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('The release metadata contains duplicate fields.')
        result[key] = value
    return result


def verify(envelope, public_key, *, now=None, previous=None):
    """Return a validated payload and exact signed digest; never retrieve a key."""
    if not isinstance(envelope, bytes) or len(envelope) > MAX_ENVELOPE:
        raise ValueError('The signed release feed is too large.')
    try:
        wrapper = json.loads(envelope, object_pairs_hook=no_duplicate_keys)
        if set(wrapper) != {'key_id', 'payload', 'signature'} or wrapper['key_id'] != KEY_ID:
            raise ValueError('The release signing key is not trusted.')
        payload_bytes = base64.b64decode(wrapper['payload'], validate=True)
        signature = base64.b64decode(wrapper['signature'], validate=True)
        if not payload_bytes or not 256 <= len(signature) <= 1024:
            raise ValueError('The release signature is invalid.')
        with tempfile.TemporaryDirectory(prefix='openweb-signature-') as temporary:
            folder = Path(temporary)
            (folder / 'payload').write_bytes(payload_bytes)
            (folder / 'signature').write_bytes(signature)
            checked = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public_key),
                '-signature', str(folder / 'signature'), str(folder / 'payload')],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if checked.returncode:
                raise ValueError('The release signature does not match the pinned key.')
        payload = json.loads(payload_bytes, object_pairs_hook=no_duplicate_keys)
    except (KeyError, TypeError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError('The signed release feed is malformed.') from error
    if not isinstance(payload, dict) or payload.get('schema') != 1 or isinstance(payload.get('schema'), bool) or payload.get('product') != 'openwebpbx' or payload.get('channel') != 'stable':
        raise ValueError('This release feed is not supported.')
    version(payload.get('version'))
    sequence = payload.get('sequence')
    if type(sequence) is not int or not 1 <= sequence <= 2147483647:
        raise ValueError('The release sequence is invalid.')
    now = now or dt.datetime.now(dt.timezone.utc)
    published, expires = timestamp(payload.get('published_at')), timestamp(payload.get('expires_at'))
    if published > now + dt.timedelta(minutes=5) or expires <= now or expires <= published:
        raise ValueError('The release feed is expired or has an invalid publication time.')
    digest = hashlib.sha256(payload_bytes).hexdigest()
    if previous:
        if sequence < previous['sequence'] or (sequence == previous['sequence'] and digest != previous['payload_sha256']):
            raise ValueError('An older or conflicting release feed was refused.')
    assets = payload.get('assets')
    if not isinstance(assets, list) or not 1 <= len(assets) <= len(PLATFORMS):
        raise ValueError('The release asset list is invalid.')
    seen = set()
    for asset in assets:
        if not isinstance(asset, dict) or asset.get('platform') not in PLATFORMS or asset['platform'] in seen:
            raise ValueError('The release contains an unsupported or duplicate platform.')
        platform = asset['platform']; seen.add(platform)
        expected_name = 'openwebpbx-' + payload['version'] + '-' + PLATFORMS[platform]
        expected_url = 'https://github.com/embire2/openwebpbx/releases/download/v' + payload['version'] + '/' + expected_name
        if asset.get('name') != expected_name or asset.get('url') != expected_url:
            raise ValueError('Release assets must belong to this repository and signed version.')
        if type(asset.get('bytes')) is not int or not 0 < asset['bytes'] <= MAX_ARCHIVE:
            raise ValueError('The release file size is invalid.')
        if not isinstance(asset.get('sha256'), str) or not re.fullmatch('[a-f0-9]{64}', asset['sha256']):
            raise ValueError('The release file checksum is invalid.')
        if platform == 'android-universal':
            if asset.get('package_id') != 'com.openweb.pbx' or type(asset.get('version_code')) is not int or not 0 < asset['version_code'] <= 2147483647:
                raise ValueError('The Android package identity is invalid.')
            if not re.fullmatch('[a-f0-9]{64}', str(asset.get('certificate_sha256', ''))):
                raise ValueError('The Android signing identity is invalid.')
            if type(asset.get('min_sdk')) is not int or not 28 <= asset['min_sdk'] <= 100:
                raise ValueError('The Android minimum operating system is invalid.')
            version(asset.get('minimum_server_version'))
        else:
            if version(asset.get('minimum_version')) > version(payload['version']):
                raise ValueError('The required installed version is invalid.')
    return payload, digest


def select_asset(payload, platform, installed_version, target_version=None):
    if target_version is not None and payload['version'] != target_version:
        raise ValueError('The requested version does not match the signed feed.')
    if version(payload['version']) <= version(installed_version):
        raise ValueError('Only a newer signed release may be installed.')
    asset = next((item for item in payload['assets'] if item['platform'] == platform), None)
    if asset is None:
        raise ValueError('This release has no package for the installed platform.')
    if platform != 'android-universal' and version(installed_version) < version(asset['minimum_version']):
        raise ValueError('Install the required intermediate release first.')
    return asset
