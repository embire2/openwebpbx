#!/usr/bin/env python3
"""Build a local Windows source codec with a pinned portable C compiler; never install."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(path, expected):
    if path.is_symlink() or not path.is_file() or digest(path) != expected:
        raise ValueError('A local codec source or compiler input differs from its reviewed hash.')


def run(command, *, cwd, env=None):
    subprocess.run([str(p) for p in command], check=True, cwd=cwd, env=env)


def compiler(build, cache):
    pin = json.loads((HERE / 'windows-compiler.json').read_text())
    if pin['sha256'] != '317492c456aa27ee607a5919f1d2d38dcdc1112516a24d0bf4b00d078f52d17a' or pin['name'] != 'llvm-mingw-20261006-ucrt-x86_64.zip':
        raise ValueError('The local codec compiler pin is unsupported.')
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / pin['name']
    if not path.exists():
        request = urllib.request.Request(pin['url'], headers={'User-Agent': 'OpenWebPBX-SourceCodec/1'})
        temporary = cache / (pin['name'] + '.partial')
        with urllib.request.urlopen(request, timeout=60) as source, temporary.open('xb') as output:
            if urllib.parse.urlsplit(source.url).scheme != 'https':
                raise ValueError('The codec compiler redirected away from HTTPS.')
            shutil.copyfileobj(source, output)
        verify(temporary, pin['sha256'])
        temporary.replace(path)
    verify(path, pin['sha256'])
    if path.stat().st_size != pin['bytes']:
        raise ValueError('The complete pinned compiler archive is required.')
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            name = item.filename.replace('\\', '/')
            if name.startswith('/') or any(p in ('', '.', '..') or ':' in p for p in name.rstrip('/').split('/')) or item.external_attr >> 28 == 0xa:
                raise ValueError('The pinned compiler archive contains an unsafe member.')
            target = build / 'compiler' / name
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, target.open('wb') as output:
                    shutil.copyfileobj(source, output)
    tools = list((build / 'compiler').glob('*/bin/x86_64-w64-mingw32-clang.exe'))
    if len(tools) != 1:
        raise ValueError('The pinned native compiler directory is ambiguous.')
    return tools[0].parent, pin


def windows_headers(fs, build_root):
    """Select real Windows types/packing in verified private MinGW copies."""
    expected = {
        'switch.h': 'a8f0a5723f23baffee974288b8e88df7f5be788c36e701c07ae4372caf002d03',
        'switch_platform.h': '492dc9bbf3fe6840e64dcbfe37e260e87b514c895ee2ff3b2d76a49cc8b60dad',
        'switch_types.h': 'a20b53a98c873085476c387d1454add366986cd80ce6ccce6d5cb606a15c4dc6',
    }
    original = fs / 'src/include'
    target = build_root / 'windows-headers'
    for name, sha in expected.items():
        verify(original / name, sha)
    shutil.copytree(original, target)
    changes = {
        'switch.h': [('#ifdef _MSC_VER\n#include <Winsock2.h>', '#if defined(_MSC_VER) || defined(__MINGW32__)\n#include <Winsock2.h>', 1)],
        'switch_platform.h': [
            ('#ifdef _MSC_VER\n/* disable the following warnings', '#if defined(_MSC_VER) || defined(__MINGW32__)\n/* disable the following warnings', 1),
            ('#if !defined(_STDINT) && !defined(uint32_t)', '#if defined(__MINGW32__)\n#include <stdint.h>\n#endif\n#if !defined(_STDINT) && !defined(uint32_t) && !defined(__MINGW32__)', 1),
            ('typedef int pid_t;', '#if defined(__MINGW32__)\ntypedef int openweb_freeswitch_pid_t;\n#define pid_t openweb_freeswitch_pid_t\n#else\ntypedef int pid_t;\n#endif', 1),
        ],
        'switch_types.h': [('#ifdef _MSC_VER\n#pragma pack', '#if defined(_MSC_VER) || defined(__MINGW32__)\n#pragma pack', 4)],
    }
    report = {}
    for name, replacements in changes.items():
        text = (original / name).read_text()
        for before, after, count in replacements:
            if text.count(before) != count:
                raise ValueError('The pinned Windows header adaptation no longer matches.')
            text = text.replace(before, after)
        (target / name).write_text(text, encoding='utf-8', newline='\n')
        report[name] = {'upstream_sha256': expected[name], 'private_windows_sha256': digest(target / name)}
    return target, report


def build(source, manifest_hash, core_root, core_hash, apr_hash, exports_helper, build_root, output, cache):
    if sys.platform != 'win32' or struct.calcsize('P') != 8:
        raise ValueError('The local codec recipe requires an x64 Windows process.')
    if not ctypes.windll.shell32.IsUserAnAdmin():
        raise ValueError('The protected local codec build requires the instance administrator.')
    for path in (build_root, output):
        if not path.is_absolute() or path.exists() or 'web' in [p.casefold() for p in path.parts] or path.resolve().is_relative_to(core_root.resolve()):
            raise ValueError('Use new private build/output directories outside the web and installed engine trees.')
    if 'web' in [p.casefold() for p in cache.parts]:
        raise ValueError('The compiler cache must be outside the web tree.')
    manifest_file = source / 'source-manifest.json'
    verify(manifest_file, manifest_hash)
    manifest = json.loads(manifest_file.read_text())
    if manifest['upstream_commit'] != 'ef32e205295e29f034f1453ad245ba5efb07b94a' or manifest['codec_source_sha256'] != 'c2731d5cf1ea076c4d0c274cb7ed85e66a06c1e401ee0e8c065c3bf90eeb8ecc' or manifest['bcg729_debian_version'] != '1.1.1-3+deb13u1':
        raise ValueError('The corrected source codec pins are required.')
    for name, expected in manifest['files'].items():
        if name.startswith('/') or '\\' in name or any(p in ('', '.', '..') or ':' in p for p in name.split('/')):
            raise ValueError('The local codec source manifest contains an unsafe path.')
        verify(source / name, expected)
    core = core_root / 'FreeSwitch.dll'
    verify(core, core_hash)
    verify(core_root / 'libapr.dll', apr_hash)
    build_root.mkdir(parents=True)
    output.mkdir(parents=True)
    cache.mkdir(parents=True, exist_ok=True)
    for directory in (build_root, output, cache):
        run(['icacls.exe', directory, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'], cwd=build_root)
    (output / 'mod').mkdir()
    tools, pin = compiler(build_root, cache)
    cc = tools / 'x86_64-w64-mingw32-clang.exe'
    dlltool = tools / 'llvm-dlltool.exe'
    spec = importlib.util.spec_from_file_location('core_exports', exports_helper)
    exports = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(exports)
    definition, export_report = exports.definition(core.read_bytes(), core_hash)
    export_file = build_root / 'FreeSwitch.def'
    export_file.write_text(definition, encoding='ascii')
    imports = build_root / 'libfreeswitch.a'
    run([dlltool, '-m', 'i386:x86-64', '-d', export_file, '-l', imports], cwd=build_root)
    fs, bcg = source / 'freeswitch', source / 'bcg729'
    header_root, header_report = windows_headers(fs, build_root)
    version = build_root / 'include'
    version.mkdir()
    template = (fs / 'src/include/switch_version.h.template').read_text()
    values = {'SWITCH_VERSION_MAJOR': '1', 'SWITCH_VERSION_MINOR': '11', 'SWITCH_VERSION_MICRO': '3',
              'SWITCH_VERSION_REVISION': '-release~ef32e205295e29f034f1453ad245ba5efb07b94a',
              'SWITCH_VERSION_REVISION_HUMAN': 'ef32e205295e29f034f1453ad245ba5efb07b94a', 'SWITCH_VERSION_YEAR': '2026'}
    for name, value in values.items():
        template = template.replace('@' + name + '@', value)
    (version / 'switch_version.h').write_text(template)
    # No library code relies on package-description macros; preserve the licence
    # template and explicitly choose dynamic library exports rather than static.
    config = (bcg / 'config.h.cmake').read_text()
    config = re.sub(r'^#cmakedefine ([A-Z_]+).*$', lambda m: '/* #undef ' + m[1] + ' */', config, flags=re.M)
    (version / 'config.h').write_text(config)
    flags = ['-std=c99', '-O2', '-Wall', '-Wextra', '-Wno-unused-parameter', '-DWIN32', '-D_WINDOWS', '-D_USRDLL',
             '-I' + str(version), '-I' + str(header_root), '-I' + str(fs / 'libs/libteletone/src'), '-I' + str(bcg / 'include')]
    library = output / 'libbcg729.dll'
    codec_import = build_root / 'libbcg729.a'
    sources = sorted((bcg / 'src').glob('*.c'))
    if len(sources) != 26:
        raise ValueError('The pinned codec library source inventory differs.')
    run([cc] + flags + ['-shared', '-DBCG729_EXPORTS', '-DHAVE_CONFIG_H', '-I' + str(bcg / 'src')] + sources +
        ['-Wl,--out-implib,' + str(codec_import), '-Wl,--dynamicbase,--nxcompat', '-o', library], cwd=build_root)
    wrapper = source / 'mod_bcg729/mod_bcg729.c'
    module = output / 'mod/mod_bcg729.dll'
    run([cc] + flags + ['-shared', '-DMOD_EXPORTS', wrapper, imports, codec_import, '-Wl,--dynamicbase,--nxcompat', '-o', module], cwd=build_root)
    env = os.environ.copy()
    env['PATH'] = str(output) + os.pathsep + str(core_root) + os.pathsep + str(tools) + os.pathsep + env.get('PATH', '')
    tests = [('callbacks', source / 'codec-check.c'), ('heap', HERE / 'windows-heap-check.c')]
    for name, test_source in tests:
        executable = build_root / (name + '.exe')
        definition = '-DOPENWEB_BCG729_SOURCE="' + wrapper.as_posix() + '"'
        run([cc] + flags + ['-DMOD_EXPORTS', '-UNDEBUG', definition, test_source, imports, codec_import, '-o', executable], cwd=build_root)
        run([executable], cwd=build_root, env=env)
    licences = output / 'licenses'
    licences.mkdir()
    for name in ['BCG729-COPYRIGHT.txt', 'BCG729-GPL-3.txt', 'MODULE-LICENSE.txt', 'NOTICES.md']:
        shutil.copy2(source / 'mod_bcg729' / name, licences / name)
    result = {'schema': 1, 'codec_distribution_status': 'local-source-build-only', 'source_manifest_sha256': manifest_hash,
              'core_sha256': core_hash, 'apr_sha256': apr_hash, 'core_data_exports': export_report['data_exports'], 'compiler': pin,
              'compiler_executable_sha256': digest(cc), 'core_export_helper_sha256': digest(exports_helper), 'callbacks': 'passed', 'data_imports_and_heap_ownership': 'passed',
              'windows_header_adapter': header_report,
              'native_rtp_qualified': False, 'files': {'mod/mod_bcg729.dll': digest(module), 'libbcg729.dll': digest(library)}}
    (output / 'local-codec-manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'engine-root', 'core-export-helper', 'build', 'output', 'compiler-cache']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--source-manifest-sha256', required=True)
    parser.add_argument('--core-sha256', required=True)
    parser.add_argument('--apr-sha256', required=True)
    args = parser.parse_args()
    try:
        result = build(args.source, args.source_manifest_sha256, args.engine_root, args.core_sha256, args.apr_sha256, args.core_export_helper,
                       args.build, args.output, args.compiler_cache)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile):
        parser.exit(1, 'The local source codec build did not complete; no installed engine was changed.\n')
    print(json.dumps({k: result[k] for k in ['codec_distribution_status', 'callbacks', 'data_imports_and_heap_ownership', 'native_rtp_qualified']}))


if __name__ == '__main__':
    main()
