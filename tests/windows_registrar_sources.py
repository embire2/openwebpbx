#!/usr/bin/env python3
"""Verify corresponding-source packaging against an actual native build artifact."""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-build', type=Path, required=True)
    parser.add_argument('--pthread-source-archive', type=Path, required=True)
    parser.add_argument('--pthread-definition', type=Path, required=True)
    args = parser.parse_args()
    bundler = load('native_bundle', 'packaging/freeswitch/bundle-windows-native.py')
    dependencies = load('native_dependencies', 'packaging/freeswitch/windows-native-dependencies.py')
    native = json.loads((args.native_build / 'engine/native-manifest.json').read_text())
    original = args.native_build / 'codec-source/source'
    inventory = json.loads((original / 'source-manifest.json').read_text())
    lock = args.native_build / 'source/dependency-lock.json'
    assert len(inventory['files']) == 6215
    assert sha(original / 'source-manifest.json') == native['source_manifest_sha256']
    assert sha(lock) == native['dependency_lock_sha256']
    count = 0
    with tempfile.TemporaryDirectory(prefix='openweb-registrar-source-') as temporary:
        work = Path(temporary)
        source = work / 'input'
        shutil.copytree(original, source)
        dependencies.pthread_headers(args.pthread_source_archive, source / 'freeswitch/libs/pthreads-msi-2.10')
        public = work / 'public'
        result = bundler.bundle(source, native['source_manifest_sha256'], ROOT / 'packaging/freeswitch/core-exports.py',
                                native['core_sha256'], 'bb3adfa1b6b7e3f699b037a0429fca49482e5a9e829ad1f01cc31d447a74a56d', public,
                                lock, native['dependency_lock_sha256'], args.pthread_source_archive, args.pthread_definition)
        assert result['source_files'] == 6215 and result['registrar_dependency_source_files'] == 16
        assert sha(public / 'source/source-manifest.json') == native['source_manifest_sha256']
        count += 1
        supplement = public / 'registrar-source'
        record = bundler.verify_registrar_bundle(supplement, native, native['source_manifest_sha256'])
        assert len(record['files']) == 16 and len(list(p for p in supplement.rglob('*') if p.is_file())) == 17
        count += 1
        assert sha(supplement / 'upstream/pthreads4w-code-v2.10.0-rc.zip') == bundler.PTHREAD_ARCHIVE
        assert sha(supplement / 'pthread.def') == bundler.PTHREAD_DEFINITION
        count += 1

        def refused(candidate=native, base=native['source_manifest_sha256']):
            try:
                bundler.verify_registrar_bundle(supplement, candidate, base)
            except ValueError:
                return True
            return False

        header = supplement / 'headers/_ptw32.h'
        preserved = header.read_bytes()
        header.write_bytes(preserved + b'corrupted header')
        assert refused()
        header.write_bytes(preserved)
        count += 1
        pdb = supplement / 'mod_sofia.pdb'
        pdb.write_bytes(b'unlisted compiled symbols')
        assert refused()
        pdb.unlink()
        count += 1
        altered = copy.deepcopy(native)
        altered['msi_pthread_experiment']['thread_probe_source_sha256'] = '0' * 64
        assert refused(altered)
        count += 1
        altered = copy.deepcopy(native)
        altered['dependency_lock_sha256'] = '0' * 64
        assert refused(altered)
        count += 1
        assert refused(base='0' * 64)
        count += 1
        default = work / 'default'
        result = bundler.bundle(original, native['source_manifest_sha256'], ROOT / 'packaging/freeswitch/core-exports.py',
                                native['core_sha256'], 'bb3adfa1b6b7e3f699b037a0429fca49482e5a9e829ad1f01cc31d447a74a56d', default)
        assert result['source_files'] == 6215 and not (default / 'registrar-source').exists()
        count += 1
    print(json.dumps({'state': 'passed', 'checks': count, 'base_source_files': 6215,
                      'supplement_source_files': 16, 'supplement_inventory_files': 17,
                      'windows_runtime_qualification': 'separate actual native gate'}, sort_keys=True))


if __name__ == '__main__':
    main()
