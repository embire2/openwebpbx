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


def fetch(folder):
    folder.mkdir(parents=True, exist_ok=True)
    for name, item in inputs().items():
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


def prepare(source, downloads, core, import_library):
    fs = source / 'freeswitch'
    locks = {}
    for name, item in inputs().items():
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
    for tree in [fs / 'libs', fs / 'x64/Release']:
        for path in tree.rglob('*'):
            if path.is_file() and not path.is_symlink():
                locks[path.relative_to(source).as_posix()] = digest(path)
    locks[header.relative_to(source).as_posix()] = digest(header)
    report = {'schema': 1, 'core_sha256': digest(core), 'source_msi_sha256': inputs()['FreeSWITCH-1.11.3-Release-x64.msi']['sha256'],
              'source_input_manifest_sha256': digest(RECIPE / 'windows-native-inputs.json'), 'files': locks}
    (source / 'dependency-lock.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--downloads', type=Path, required=True)
    parser.add_argument('--fetch', action='store_true')
    parser.add_argument('--source', type=Path)
    parser.add_argument('--core', type=Path)
    parser.add_argument('--import-library', type=Path)
    args = parser.parse_args()
    try:
        if args.fetch:
            fetch(args.downloads)
        if args.source:
            if args.core is None or args.import_library is None:
                parser.error('Offline preparation requires the verified core DLL and its derived import library.')
            report = prepare(args.source, args.downloads, args.core, args.import_library)
            print(json.dumps({'dependency_files': len(report['files']), 'core_sha256': report['core_sha256']}))
    except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile):
        parser.exit(1, 'Pinned Windows native dependencies could not be prepared.\n')


if __name__ == '__main__':
    main()
