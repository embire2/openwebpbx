#!/usr/bin/env python3
"""Copy only verified prepared public sources and codec helper provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

PTHREAD_ARCHIVE = '59e80da688f45f3aba2931938e8274d9673a524078977c9087fc267cef96ccb5'
PTHREAD_DLL = '2d9d70378f13dcc06eed72005e74a12c6f7ba085e5fd31f97be49b7ef87cfdad'
PTHREAD_DEFINITION = '2ba6294e7484978343bebc535a32657be5de5cc6e1836bdbb7baff0e0661da0d'
PTHREAD_REVISION = '02fecc211d626f28e05ecbb0c10f739bd36d6442'
PTHREAD_HEADERS = ('pthread.h', 'sched.h', 'semaphore.h', '_ptw32.h', '_ptw32.h.upstream',
                   'need_errno.h', 'COPYING', 'COPYING.FSF', 'README')
PTHREAD_RECIPES = ('packaging/freeswitch/Build-WindowsNative.ps1',
                   'packaging/freeswitch/core-exports.py',
                   'packaging/freeswitch/windows-native-dependencies.py',
                   'packaging/freeswitch/windows-native-inputs.json',
                   'tests/pbx_windows_pthread.c')


def registrar_bundle(source, source_manifest_hash, dependency_lock, lock_hash, archive, definition, output):
    verify(dependency_lock, lock_hash)
    lock = json.loads(dependency_lock.read_text())
    inputs = lock.get('msi_pthread', {})
    if lock.get('schema') != 1 or inputs.get('runtime_sha256') != PTHREAD_DLL or inputs.get('runtime_version') != '2.10.0.0' or inputs.get('source_revision') != PTHREAD_REVISION or inputs.get('archive_sha256') != PTHREAD_ARCHIVE:
        raise ValueError('The reviewed matching MSI pthread dependency lock is required.')
    verify(archive, PTHREAD_ARCHIVE)
    verify(definition, PTHREAD_DEFINITION)
    if output.exists():
        raise ValueError('Use a new registrar dependency-source output.')
    output.mkdir(parents=True)
    files = {}

    def copy(path, relative, expected):
        verify(path, expected)
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        files[relative] = digest(target)

    copy(archive, 'upstream/pthreads4w-code-v2.10.0-rc.zip', PTHREAD_ARCHIVE)
    copy(definition, 'pthread.def', PTHREAD_DEFINITION)
    for name in PTHREAD_HEADERS:
        relative = 'freeswitch/libs/pthreads-msi-2.10/' + name
        expected = lock.get('files', {}).get(relative)
        if not expected:
            raise ValueError('A matching pthread header or licence is absent from the verified lock.')
        copy(source / relative, 'headers/' + name, expected)
    repository = Path(__file__).resolve().parents[2]
    for name in PTHREAD_RECIPES:
        path = repository / name
        copy(path, 'recipe/' + name, digest(path))
    manifest = {'schema': 1, 'kind': 'matching-msi-pthread-source',
                'base_source_manifest_sha256': source_manifest_hash,
                'dependency_lock_sha256': lock_hash, 'inputs': inputs, 'files': files,
                'compiled_binary_included': False, 'pdb_included': False}
    (output / 'registrar-source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def verify_registrar_bundle(folder, native, base_manifest_hash):
    path = folder / 'registrar-source-manifest.json'
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise ValueError('An ordinary bounded registrar source inventory is required.')
    manifest = json.loads(path.read_text())
    inputs = manifest.get('inputs', {})
    expected_names = {'upstream/pthreads4w-code-v2.10.0-rc.zip', 'pthread.def'}
    expected_names.update('headers/' + name for name in PTHREAD_HEADERS)
    expected_names.update('recipe/' + name for name in PTHREAD_RECIPES)
    experiment = native.get('msi_pthread_experiment', {})
    if manifest.get('schema') != 1 or manifest.get('kind') != 'matching-msi-pthread-source' or manifest.get('base_source_manifest_sha256') != base_manifest_hash or manifest.get('dependency_lock_sha256') != native.get('dependency_lock_sha256') or inputs != experiment.get('inputs') or set(manifest.get('files', {})) != expected_names or manifest.get('compiled_binary_included') is not False or manifest.get('pdb_included') is not False:
        raise ValueError('The registrar dependency sources do not match this native build.')
    if inputs.get('runtime_sha256') != PTHREAD_DLL or inputs.get('archive_sha256') != PTHREAD_ARCHIVE or inputs.get('source_revision') != PTHREAD_REVISION or inputs.get('runtime_version') != '2.10.0.0':
        raise ValueError('The matching runtime/source pins differ.')
    actual_names = set()
    for item in folder.rglob('*'):
        if item.is_symlink():
            raise ValueError('Registrar dependency sources contain a link.')
        if item.is_file():
            relative = item.relative_to(folder).as_posix()
            actual_names.add(relative)
            if relative != path.name:
                if relative not in expected_names:
                    raise ValueError('Registrar dependency sources contain an unlisted or compiled file.')
                verify(item, manifest['files'][relative])
    if actual_names != expected_names | {path.name}:
        raise ValueError('Registrar dependency source inventory is incomplete.')
    verify(folder / 'upstream/pthreads4w-code-v2.10.0-rc.zip', PTHREAD_ARCHIVE)
    verify(folder / 'pthread.def', PTHREAD_DEFINITION)
    verify(folder / 'headers/_ptw32.h', inputs['derived_import_header_sha256'])
    verify(folder / 'headers/_ptw32.h.upstream', inputs['upstream_import_header_sha256'])
    if manifest['files']['recipe/tests/pbx_windows_pthread.c'] != experiment.get('thread_probe_source_sha256'):
        raise ValueError('The source ABI probe differs from the executed native probe.')
    return manifest


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(path, expected):
    if path.is_symlink() or not path.is_file() or digest(path) != expected:
        raise ValueError('A prepared public source or helper input differs from its expected hash.')


def bundle(source, manifest_hash, export_helper, core_hash, apr_hash, output,
           dependency_lock=None, lock_hash=None, pthread_archive=None, pthread_definition=None):
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
    optional = (dependency_lock, lock_hash, pthread_archive, pthread_definition)
    if any(optional):
        if not all(optional):
            raise ValueError('Registrar dependency sources require all four explicit verified inputs.')
        registrar = registrar_bundle(source, manifest_hash, dependency_lock, lock_hash,
                                     pthread_archive, pthread_definition, output / 'registrar-source')
        result['registrar_source_manifest_sha256'] = digest(output / 'registrar-source/registrar-source-manifest.json')
        result['registrar_dependency_source_files'] = len(registrar['files'])
    (output / 'codec-source-manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'core-export-helper', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ['source-manifest-sha256', 'core-sha256', 'apr-sha256']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--registrar-dependency-lock', type=Path)
    parser.add_argument('--registrar-dependency-lock-sha256')
    parser.add_argument('--pthread-source-archive', type=Path)
    parser.add_argument('--pthread-definition', type=Path)
    args = parser.parse_args()
    try:
        result = bundle(args.source, args.source_manifest_sha256, args.core_export_helper, args.core_sha256,
                        args.apr_sha256, args.output, args.registrar_dependency_lock,
                        args.registrar_dependency_lock_sha256, args.pthread_source_archive, args.pthread_definition)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, str(error) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
