#!/usr/bin/env python3
"""Download pinned public Windows build inputs or prepare an offline dependency lock."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tarfile
import urllib.parse
import urllib.request
import zipfile

RECIPE = Path(__file__).resolve().parent


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(path, expected):
    if path.is_symlink() or not path.is_file() or digest(path) != expected:
        raise ValueError('A native dependency differs from its pinned checksum.')


def inputs():
    return json.loads((RECIPE / 'windows-native-inputs.json').read_text())['inputs']


def fetch(folder, use_msi_pthread=False):
    folder.mkdir(parents=True, exist_ok=True)
    for name, item in inputs().items():
        if item['kind'] == 'pthread-experiment' and not use_msi_pthread:
            continue
        path = folder / name
        if not path.exists():
            parsed = urllib.parse.urlsplit(item['url'])
            if parsed.scheme != 'https' or parsed.username or parsed.password:
                raise ValueError('Native input URLs must use public HTTPS.')
            request = urllib.request.Request(item['url'], headers={'User-Agent': 'OpenWebPBX-NativeBuild/1'})
            temporary = path.with_suffix(path.suffix + '.partial')
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open('xb') as stream:
                if urllib.parse.urlsplit(response.url).scheme != 'https':
                    raise ValueError('A native input redirected away from HTTPS.')
                shutil.copyfileobj(response, stream)
            verify(temporary, item['sha256'])
            temporary.replace(path)
        verify(path, item['sha256'])


def unzip(path, destination):
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            # The pinned upstream zlib archive uses Windows separators.
            name = item.filename.replace('\\', '/')
            parts = name.rstrip('/').split('/')
            if any(p in ('', '.', '..') or ':' in p for p in parts) or name.startswith('/') or stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError('A pinned dependency archive has an unsafe member.')
            target = destination.joinpath(*PurePosixPath(name).parts)
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, target.open('wb') as output:
                    shutil.copyfileobj(source, output)


def pthread_headers(archive, target):
    # Exact upstream 2.10 source/tag; only an explicit build experiment uses it.
    prefix = 'pthreads4w-code-02fecc211d626f28e05ecbb0c10f739bd36d6442/'
    names = ('pthread.h', 'sched.h', 'semaphore.h', '_ptw32.h', 'need_errno.h', 'COPYING', 'COPYING.FSF', 'README')
    target.mkdir(parents=True)
    with zipfile.ZipFile(archive) as bundle:
        for name in names:
            item = bundle.getinfo(prefix + name)
            if item.file_size > 1024 * 1024 or stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError('A reviewed pthread header is not an ordinary bounded source file.')
            (target / name).write_bytes(bundle.read(item))
    original = target / '_ptw32.h'
    data = original.read_bytes()
    marker = b'# define PTW32_DLLPORT /*__declspec (dllimport)*/'
    if data.count(marker) != 1 or b'#define PTW32_VERSION_MAJOR 2' not in data or b'#define PTW32_VERSION_MINOR 10' not in data:
        raise ValueError('The exact reviewed pthread 2.10 import header changed.')
    original_hash = hashlib.sha256(data).hexdigest()
    # Import the exact MSI DLL, rather than resolving plain declarations to
    # another static implementation. Preserve the upstream bytes separately.
    (target / '_ptw32.h.upstream').write_bytes(data)
    original.write_bytes(data.replace(marker, b'# define PTW32_DLLPORT __declspec (dllimport)'))
    return {'source_revision': '02fecc211d626f28e05ecbb0c10f739bd36d6442',
            'archive_sha256': digest(archive), 'upstream_import_header_sha256': original_hash,
            'derived_import_header_sha256': digest(original)}


def prepare(source, downloads, core, import_library, use_msi_pthread=False, pthread_import_library=None):
    fs = source / 'freeswitch'
    locks = {}
    for name, item in inputs().items():
        if item['kind'] == 'pthread-experiment':
            if use_msi_pthread:
                verify(downloads / name, item['sha256'])
                pthread = pthread_headers(downloads / name, fs / 'libs/pthreads-msi-2.10')
            continue
        if item['kind'] in ('msi', 'codec-source'):
            continue
        path = downloads / name
        verify(path, item['sha256'])
        if item['kind'] == 'zip':
            unzip(path, fs / 'libs')
        elif item['kind'] == 'tar':
            with tarfile.open(path) as archive:
                archive.extractall(fs / 'libs', filter='data')
        elif item['kind'] == 'tool':
            shutil.copy2(path, fs / 'libs/sofia-sip/win32/gawk.exe')
    header = fs / 'src/include/switch_version.h'
    template = (fs / 'src/include/switch_version.h.template').read_text()
    values = dict(re.findall(r'AC_SUBST\((SWITCH_VERSION_[A-Z_]+),\s*\[([^\]]*)\]\)', (fs / 'configure.ac').read_text()))
    values['SWITCH_VERSION_MICRO'] = '3'
    values['SWITCH_VERSION_REVISION'] = '-release~ef32e205295e29f034f1453ad245ba5efb07b94a'
    values['SWITCH_VERSION_REVISION_HUMAN'] = 'ef32e205295e29f034f1453ad245ba5efb07b94a'
    values['SWITCH_VERSION_YEAR'] = '2026'
    for name, value in values.items():
        template = template.replace('@' + name + '@', value)
    if re.search(r'@SWITCH_VERSION_', template):
        raise ValueError('The generated matching engine header is incomplete.')
    header.write_text(template, newline='\n')
    library = fs / 'x64/Release/FreeSwitch.lib'
    library.parent.mkdir(parents=True, exist_ok=True)
    if import_library.resolve() != library.resolve():
        shutil.copy2(import_library, library)
    if use_msi_pthread:
        if pthread_import_library is None or pthread_import_library.is_symlink() or not pthread_import_library.is_file():
            raise ValueError('The experimental matching MSI pthread import library is required.')
        runtime = core.parent / 'pthread.dll'
        verify(runtime, '2d9d70378f13dcc06eed72005e74a12c6f7ba085e5fd31f97be49b7ef87cfdad')
        shutil.copyfile(pthread_import_library, fs / 'x64/Release/pthread-msi.lib')
    for tree in [fs / 'libs', fs / 'x64/Release']:
        for path in tree.rglob('*'):
            if path.is_file() and not path.is_symlink():
                locks[path.relative_to(source).as_posix()] = digest(path)
    locks[header.relative_to(source).as_posix()] = digest(header)
    report = {'schema': 1, 'core_sha256': digest(core), 'source_msi_sha256': inputs()['FreeSWITCH-1.11.3-Release-x64.msi']['sha256'],
              'source_input_manifest_sha256': digest(RECIPE / 'windows-native-inputs.json'), 'files': locks}
    if use_msi_pthread:
        report['msi_pthread'] = {**pthread, 'runtime_sha256': digest(runtime),
                                'import_library_sha256': digest(pthread_import_library),
                                'runtime_version': '2.10.0.0'}
    (source / 'dependency-lock.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--downloads', type=Path, required=True)
    parser.add_argument('--fetch', action='store_true')
    parser.add_argument('--source', type=Path)
    parser.add_argument('--core', type=Path)
    parser.add_argument('--import-library', type=Path)
    parser.add_argument('--use-msi-pthread', action='store_true', help='Explicit source-copy experiment; default registrar recipe remains unchanged.')
    parser.add_argument('--pthread-import-library', type=Path)
    args = parser.parse_args()
    try:
        if args.fetch:
            fetch(args.downloads, args.use_msi_pthread)
        if args.source:
            if args.core is None or args.import_library is None:
                parser.error('Offline preparation requires the verified core DLL and its derived import library.')
            report = prepare(args.source, args.downloads, args.core, args.import_library, args.use_msi_pthread, args.pthread_import_library)
            print(json.dumps({'dependency_files': len(report['files']), 'core_sha256': report['core_sha256']}))
    except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile):
        parser.exit(1, 'Pinned Windows native dependencies could not be prepared.\n')


if __name__ == '__main__':
    main()
