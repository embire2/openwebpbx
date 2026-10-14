#!/usr/bin/env python3
"""Copy only verified prepared public sources and codec helper provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(path, expected):
    if path.is_symlink() or not path.is_file() or digest(path) != expected:
        raise ValueError('A prepared public source or helper input differs from its expected hash.')


def bundle(source, manifest_hash, export_helper, core_hash, apr_hash, output):
    if core_hash != '8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726' or apr_hash != 'bb3adfa1b6b7e3f699b037a0429fca49482e5a9e829ad1f01cc31d447a74a56d':
        raise ValueError('The verified pinned source MSI core/APR hashes are required.')
    manifest_file = source / 'source-manifest.json'
    verify(manifest_file, manifest_hash)
    manifest = json.loads(manifest_file.read_text())
    if manifest.get('schema') != 1 or manifest.get('upstream_commit') != 'ef32e205295e29f034f1453ad245ba5efb07b94a' or manifest.get('codec_source_sha256') != 'c2731d5cf1ea076c4d0c274cb7ed85e66a06c1e401ee0e8c065c3bf90eeb8ecc' or manifest.get('links'):
        raise ValueError('The pinned prepared source inventory is required.')
    if output.exists() or export_helper.is_symlink() or not export_helper.is_file():
        raise ValueError('Use a new public-source output and an ordinary canonical export helper.')
    destination = output / 'source'
    destination.mkdir(parents=True)
    seen = set()
    for name, expected in manifest['files'].items():
        if name.startswith('/') or '\\' in name or any(part in ('', '.', '..') or ':' in part for part in name.split('/')) or name.casefold() in seen:
            raise ValueError('The prepared source inventory has an unsafe or ambiguous member.')
        seen.add(name.casefold())
        path = source / name
        verify(path, expected)
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        verify(target, expected)
    shutil.copyfile(manifest_file, destination / 'source-manifest.json')
    shutil.copyfile(export_helper, output / 'core-exports.py')
    result = {'schema': 1, 'source_manifest_sha256': manifest_hash, 'source_files': len(manifest['files']),
              'core_export_helper_sha256': digest(export_helper), 'core_sha256': core_hash, 'apr_sha256': apr_hash,
              'codec_distribution_status': 'local-source-build-only', 'generated_binary_included': False}
    (output / 'codec-source-manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'core-export-helper', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ['source-manifest-sha256', 'core-sha256', 'apr-sha256']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        result = bundle(args.source, args.source_manifest_sha256, args.core_export_helper, args.core_sha256, args.apr_sha256, args.output)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
