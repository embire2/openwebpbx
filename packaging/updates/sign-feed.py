#!/usr/bin/env python3
"""Create a release feed from finished artifacts using an external private key."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from verify_feed import KEY_ID, PLATFORMS, verify, version

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--private-key', type=Path, required=True)
parser.add_argument('--public-key', type=Path, default=Path(__file__).with_name('release-public.pem'))
parser.add_argument('--version', required=True)
parser.add_argument('--sequence', type=int, required=True)
parser.add_argument('--debian', type=Path)
parser.add_argument('--windows', type=Path)
parser.add_argument('--android', type=Path)
parser.add_argument('--android-version-code', type=int)
parser.add_argument('--android-certificate-sha256')
parser.add_argument('--android-min-sdk', type=int, default=28)
parser.add_argument('--minimum-version', default='1.0.3')
parser.add_argument('--minimum-server-version')
parser.add_argument('--published-at')
parser.add_argument('--expires-days', type=int, default=180)
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
version(a.version)
if not any([a.debian, a.windows, a.android]):parser.error('Supply at least one completed platform artifact.')
if not 1 <= a.expires_days <= 366:parser.error('Use an expiry between 1 and 366 days.')
if a.private_key.stat().st_uid != os.geteuid() or a.private_key.stat().st_mode & 0o077:
    parser.error('Use a private signing key owned by this account with mode 600.')
repository = Path(__file__).resolve().parents[2]
if a.private_key.resolve().is_relative_to(repository):parser.error('Keep the signing key outside the source checkout.')
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
published = a.published_at or now.strftime('%Y-%m-%dT%H:%M:%SZ')
assets = []
for platform, path in [('debian13-amd64', a.debian), ('windows-x64', a.windows), ('android-universal', a.android)]:
    if path is None:continue
    name = 'openwebpbx-' + a.version + '-' + PLATFORMS[platform]
    if path.name != name:parser.error('Artifact name does not match version/platform: ' + path.name)
    with path.open('rb') as stream:digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    item = {'platform':platform, 'name':name, 'url':'https://github.com/embire2/openwebpbx/releases/download/v'+a.version+'/'+name,
            'bytes':path.stat().st_size, 'sha256':digest}
    if platform == 'android-universal':
        if not a.android_version_code or not a.android_certificate_sha256:parser.error('Supply the verified Android version code and signing certificate SHA-256.')
        item.update(version_code=a.android_version_code, package_id='com.openweb.pbx', minimum_server_version=a.minimum_server_version or a.version,
                    certificate_sha256=a.android_certificate_sha256, min_sdk=a.android_min_sdk)
    else:item['minimum_version'] = a.minimum_version
    assets.append(item)
payload = {'schema':1, 'product':'openwebpbx', 'channel':'stable', 'sequence':a.sequence, 'version':a.version,
           'published_at':published, 'expires_at':(now+dt.timedelta(days=a.expires_days)).strftime('%Y-%m-%dT%H:%M:%SZ'), 'assets':assets}
data = json.dumps(payload, separators=(',', ':'), sort_keys=True).encode()
with tempfile.TemporaryDirectory(prefix='openweb-sign-') as folder:
    unsigned = Path(folder)/'payload';unsigned.write_bytes(data)
    signed = subprocess.run(['openssl','dgst','-sha256','-sign',str(a.private_key),str(unsigned)],
                            stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if signed.returncode:raise RuntimeError('The private release key could not sign this feed.')
envelope = json.dumps({'key_id':KEY_ID, 'payload':base64.b64encode(data).decode(), 'signature':base64.b64encode(signed.stdout).decode()}, separators=(',', ':')).encode()+b'\n'
verify(envelope, a.public_key)
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_bytes(envelope)
print('Signed and verified release', a.version, 'with', len(assets), 'platform assets:', a.output)
