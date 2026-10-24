#!/usr/bin/env python3
"""Verify a Windows release while preserving the published Android/Debian feeds."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import zipfile

from verify_feed import MAX_ENVELOPE, no_duplicate_keys, verify

# Match the installed Windows PackageExtractor manifest bound.
MAX_MANIFEST_BYTES = 8 * 1024**2


def validate(generic, reference, windows, public_key, package, *, generic_version, windows_version,
             debian=None, debian_reference=None, debian_version=None, now=None):
    if generic != reference:
        raise ValueError('The generic feed differs from the immutable published reference.')
    shared, shared_digest = verify(generic, public_key, now=now)
    separate, separate_digest = verify(windows, public_key, now=now)
    shared_platforms = {a['platform'] for a in shared['assets']}
    if shared['version'] != generic_version or shared_platforms not in ({'debian13-amd64', 'android-universal'}, {'android-universal'}):
        raise ValueError('The generic feed must retain the published Android release.')
    debian_inputs = (debian is not None, debian_reference is not None, debian_version is not None)
    if any(debian_inputs) and not all(debian_inputs):
        raise ValueError('Supply the Debian feed, immutable reference and expected version together.')
    linux = None
    linux_digest = None
    if all(debian_inputs):
        if debian != debian_reference:
            raise ValueError('The Debian feed differs from the immutable published reference.')
        linux, linux_digest = verify(debian, public_key, now=now)
        if linux['version'] != debian_version or {a['platform'] for a in linux['assets']} not in (
                {'debian13-amd64'}, {'debian13-amd64', 'android-universal'}):
            raise ValueError('The Debian feed must retain the published Debian release.')
    elif shared_platforms != {'debian13-amd64', 'android-universal'}:
        raise ValueError('The separate published Debian feed and reference are required.')
    if separate['version'] != windows_version or len(separate['assets']) != 1 or separate['assets'][0]['platform'] != 'windows-x64':
        raise ValueError('The Windows feed must contain only the expected Windows server release.')
    if separate['sequence'] <= max(shared['sequence'], linux['sequence'] if linux else 0):
        raise ValueError('The Windows release sequence must advance past the retained platform feeds.')
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
        if marker is None or marker.file_size > MAX_MANIFEST_BYTES:
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
    result = {'generic_version': shared['version'], 'generic_sequence': shared['sequence'], 'generic_payload_sha256': shared_digest,
            'generic_reference_byte_identical': True, 'windows_version': separate['version'], 'windows_sequence': separate['sequence'],
            'windows_payload_sha256': separate_digest, 'windows_package_sha256': package_hash, 'windows_manifest_files': len(manifest['files'])}
    if linux is not None:
        result.update(debian_version=linux['version'], debian_sequence=linux['sequence'], debian_payload_sha256=linux_digest,
                      debian_reference_byte_identical=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--generic', type=Path, required=True)
    parser.add_argument('--generic-reference', type=Path, required=True)
    parser.add_argument('--debian', type=Path)
    parser.add_argument('--debian-reference', type=Path)
    parser.add_argument('--debian-version')
    parser.add_argument('--windows', type=Path, required=True)
    parser.add_argument('--windows-package', type=Path, required=True)
    parser.add_argument('--generic-version', required=True)
    parser.add_argument('--windows-version', required=True)
    parser.add_argument('--public-key', type=Path, default=Path(__file__).with_name('release-public.pem'))
    args = parser.parse_args()
    if args.generic.name != 'update-manifest.json' or args.windows.name != 'windows-update-manifest.json':
        parser.error('Use the fixed generic and Windows feed filenames.')
    if any((args.debian, args.debian_reference, args.debian_version)) and not all((args.debian, args.debian_reference, args.debian_version)):
        parser.error('Supply --debian, --debian-reference and --debian-version together.')
    if args.debian and args.debian.name != 'debian-update-manifest.json':
        parser.error('Use the fixed Debian feed filename.')
    for path in filter(None, (args.generic, args.generic_reference, args.debian, args.debian_reference, args.windows)):
        if not path.is_file() or path.stat().st_size > MAX_ENVELOPE:
            parser.error('Feed files must be ordinary bounded envelopes.')
    try:
        result = validate(args.generic.read_bytes(), args.generic_reference.read_bytes(), args.windows.read_bytes(), args.public_key,
                          args.windows_package, generic_version=args.generic_version, windows_version=args.windows_version,
                          debian=args.debian.read_bytes() if args.debian else None,
                          debian_reference=args.debian_reference.read_bytes() if args.debian_reference else None,
                          debian_version=args.debian_version)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, UnicodeError) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
