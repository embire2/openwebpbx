#!/usr/bin/env python3
"""Verify a Windows-only release and the unchanged generic feed before publication."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import zipfile

from verify_feed import MAX_ENVELOPE, no_duplicate_keys, verify


def validate(generic, reference, windows, public_key, package, *, generic_version, windows_version, now=None):
    if generic != reference:
        raise ValueError('The generic feed differs from the immutable published reference.')
    shared, shared_digest = verify(generic, public_key, now=now)
    separate, separate_digest = verify(windows, public_key, now=now)
    if shared['version'] != generic_version or {a['platform'] for a in shared['assets']} != {'debian13-amd64', 'android-universal'}:
        raise ValueError('The generic feed must retain the published Debian and Android release.')
    if separate['version'] != windows_version or len(separate['assets']) != 1 or separate['assets'][0]['platform'] != 'windows-x64':
        raise ValueError('The Windows feed must contain only the expected Windows server release.')
    if separate['sequence'] <= shared['sequence']:
        raise ValueError('The Windows release sequence must advance past the retained generic feed.')
    asset = separate['assets'][0]
    if package.name != asset['name'] or package.stat().st_size != asset['bytes']:
        raise ValueError('The Windows package name or size differs from its signed feed.')
    with package.open('rb') as stream:
        package_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
    if package_hash != asset['sha256']:
        raise ValueError('The Windows package differs from its signed checksum.')
    prefix = f'openwebpbx-{windows_version}-windows-x64/'
    with zipfile.ZipFile(package) as archive:
        members = {}
        folded = set()
        for item in archive.infolist():
            name = item.filename
            if '\\' in name or not name.startswith(prefix) or any(p in ('', '.', '..') for p in name.rstrip('/').split('/')) or stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError('The Windows archive contains an unsafe member.')
            relative = name[len(prefix):]
            if not relative:
                if not item.is_dir():
                    raise ValueError('The Windows archive root is not a directory.')
                continue
            key = relative.rstrip('/').casefold()
            if key in folded:
                raise ValueError('The Windows archive contains a duplicate or case-colliding member.')
            folded.add(key)
            if not item.is_dir():
                members[relative] = item
        marker = members.get('release-manifest.json')
        if marker is None or marker.file_size > 2 * 1024 * 1024:
            raise ValueError('The Windows archive has no bounded file manifest.')
        manifest = json.loads(archive.read(marker), object_pairs_hook=no_duplicate_keys)
        if manifest.get('version') != windows_version or not isinstance(manifest.get('files'), dict) or set(members) != set(manifest['files']) | {'release-manifest.json'}:
            raise ValueError('The Windows manifest does not match its complete file inventory.')
        required = {'VERSION', 'bootstrap.php', 'Install-OpenWebPBX.ps1', 'Upgrade-OpenWebPBX.ps1', 'Install-Updater.ps1',
                    'server/OpenWebPbx.Server.exe', 'updater/OpenWebPbx.Updater.exe', 'desktop/OpenWebPbx.Desktop.exe',
                    'web/resources/require.php', 'web/resources/classes/pbx_phone_restore.php',
                    'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/auth_binding.lua',
                    'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/contact_realms.lua'}
        if not required <= manifest['files'].keys():
            raise ValueError('The Windows suite is missing required application or guarded phone components.')
        for name, digest in manifest['files'].items():
            parts = PurePosixPath(name).parts
            if any(p == '.git' or p.startswith('.env') for p in parts) or (parts[0] == 'web' and PurePosixPath(name).suffix.lower() in {'.dump', '.key', '.pfx'}):
                raise ValueError('The Windows package contains a private runtime path.')
            with archive.open(members[name]) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                    raise ValueError('The Windows package member failed manifest verification.')
        if archive.read(members['VERSION']).decode('utf-8').strip() != windows_version:
            raise ValueError('The Windows package VERSION differs from signed metadata.')
    return {'generic_version': shared['version'], 'generic_sequence': shared['sequence'], 'generic_payload_sha256': shared_digest,
            'generic_reference_byte_identical': True, 'windows_version': separate['version'], 'windows_sequence': separate['sequence'],
            'windows_payload_sha256': separate_digest, 'windows_package_sha256': package_hash, 'windows_manifest_files': len(manifest['files'])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--generic', type=Path, required=True)
    parser.add_argument('--generic-reference', type=Path, required=True)
    parser.add_argument('--windows', type=Path, required=True)
    parser.add_argument('--windows-package', type=Path, required=True)
    parser.add_argument('--generic-version', required=True)
    parser.add_argument('--windows-version', required=True)
    parser.add_argument('--public-key', type=Path, default=Path(__file__).with_name('release-public.pem'))
    args = parser.parse_args()
    if args.generic.name != 'update-manifest.json' or args.windows.name != 'windows-update-manifest.json':
        parser.error('Use the fixed generic and Windows feed filenames.')
    for path in (args.generic, args.generic_reference, args.windows):
        if not path.is_file() or path.stat().st_size > MAX_ENVELOPE:
            parser.error('Feed files must be ordinary bounded envelopes.')
    try:
        result = validate(args.generic.read_bytes(), args.generic_reference.read_bytes(), args.windows.read_bytes(), args.public_key,
                          args.windows_package, generic_version=args.generic_version, windows_version=args.windows_version)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, UnicodeError) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
