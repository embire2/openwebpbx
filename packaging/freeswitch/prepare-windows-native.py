#!/usr/bin/env python3
"""Prepare pinned native build sources only; never access an installed PBX."""
import argparse
import hashlib
import io
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tarfile

FS_REV = 'ef32e205295e29f034f1453ad245ba5efb07b94a'
SOFIA_REV = 'ad36ac8f755308e8b87f98a505e83d4e408e5cc3'
CODEC_REV = '4203247dee4719545005ec7ab9ea536fc83df1d8'
REG_ORIGINAL = '1eed13a2ae440201bcc1bf6aa1f82899140794b96202496f2e21bf2bf070c9d9'
REG_PATCHED = '4dafe992533cbff6e57a5bb6870cb2b410fb552d781e657a55fefd9ad73f241d'
REG_PATCH = 'db4fa115b4323eb9c084ad0ffb946488a4a50ba5709886cd3fdc3812c0ad51f6'
CODEC_ORIGINAL = '4f17ed9356a922be465bda3f8fbd5b6ac5bde15b0cf7167047b36d8421510026'
CODEC_PATCHED = 'c2731d5cf1ea076c4d0c274cb7ed85e66a06c1e401ee0e8c065c3bf90eeb8ecc'
CODEC_PATCH = '39af6200772e1eb3373cbf8a75ba7b991ca4e102a0b2688de682e84ec66a62df'
BCG_ARCHIVES = {
    'bcg729_1.1.1.orig.tar.gz': '68599a850535d1b182932b3f86558ac8a76d4b899a548183b062956c5fdc916d',
    'bcg729_1.1.1-3+deb13u1.debian.tar.xz': '4674343d5150b5b60db633c1a8ee54590f0a1714928f77e74ee641e004dd14b6',
}
RECIPE = Path(__file__).resolve().parent
BCG_CASE_RENAME_PATCH = 'f4692bf01cf033f59820b8aeb49f79493d450630d02200eb692240e601bef46c'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require_hash(path, expected):
    if path.is_symlink() or not path.is_file() or digest(path) != expected:
        raise ValueError('A pinned native source input differs from its reviewed checksum.')


def export(repo, revision, destination):
    resolved = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', revision + '^{commit}'], text=True).strip()
    if resolved != revision:
        raise ValueError('The source revision differs from its fixed pin.')
    data = subprocess.check_output(['git', '-C', str(repo), 'archive', '--format=tar', revision])
    destination.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(destination, filter='data')


def patch_tree(tree, patch):
    command = None
    if os.name == 'nt':
        candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/usr/bin/patch.exe'
        if candidate.is_file():
            command = str(candidate)
    command = command or shutil.which('patch')
    if command is None:
        raise ValueError('GNU patch from Git for Windows is required.')
    version = subprocess.check_output([command, '--version'], text=True)
    match = re.search(r'patch\s+(\d+)\.(\d+)', version)
    if match is None or tuple(map(int, match.groups())) < (2, 7):
        raise ValueError('GNU patch 2.7 or newer is required; legacy Strawberry patch is unsupported.')
    data = patch.read_bytes()
    if hashlib.sha256(data).hexdigest() == BCG_CASE_RENAME_PATCH:
        # This exact Debian patch creates BCG729Config before deleting Bcg729Config.
        # Apply its unchanged deletion hunk first so case-insensitive NTFS can
        # represent the same final source tree. Keep the original patch on disk.
        sections = data.split(b'diff --git ')
        if len(sections) != 6 or not sections[1].startswith(b'a/BCG729Config.cmake.in b/BCG729Config.cmake.in\nnew file mode ') or not sections[2].startswith(b'a/Bcg729Config.cmake.in b/Bcg729Config.cmake.in\ndeleted file mode '):
            raise ValueError('The pinned case-only rename patch has an unexpected structure.')
        data = sections[0] + b'diff --git ' + sections[2] + b'diff --git ' + sections[1] + b''.join(b'diff --git ' + section for section in sections[3:])
    subprocess.run([command, '--batch', '--forward', '--binary', '--ignore-whitespace', '-p1'], input=data, check=True, cwd=tree)


def prepare(fs_repo, sofia_repo, codec_repo, archives, output):
    if output.exists():
        raise ValueError('Use a new dedicated build-source directory.')
    reg_patch = RECIPE / 'restore-registration.patch'
    codec_patch = RECIPE.parent / 'codecs/bcg729/buffer-safety.patch'
    require_hash(reg_patch, REG_PATCH)
    require_hash(codec_patch, CODEC_PATCH)
    for name, expected in BCG_ARCHIVES.items():
        require_hash(archives / name, expected)
    output.mkdir(parents=True)
    fs = output / 'freeswitch'
    export(fs_repo, FS_REV, fs)
    reg = fs / 'src/mod/endpoints/mod_sofia/sofia_reg.c'
    require_hash(reg, REG_ORIGINAL)
    shutil.copy2(reg, output / 'sofia_reg.upstream.c')
    patch_tree(fs, reg_patch)
    require_hash(reg, REG_PATCHED)
    export(sofia_repo, SOFIA_REV, fs / 'libs/sofia-sip')
    codec = output / 'mod_bcg729'
    export(codec_repo, CODEC_REV, codec)
    require_hash(codec / 'mod_bcg729.c', CODEC_ORIGINAL)
    shutil.copy2(codec / 'mod_bcg729.c', output / 'mod_bcg729.upstream.c')
    patch_tree(codec, codec_patch)
    require_hash(codec / 'mod_bcg729.c', CODEC_PATCHED)
    bcg = output / 'bcg729'
    bcg.mkdir()
    with tarfile.open(archives / 'bcg729_1.1.1.orig.tar.gz') as archive:
        entries = archive.getmembers()
        prefix = entries[0].name.split('/')[0]
        for item in entries:
            if not item.name.startswith(prefix + '/') and item.name != prefix:
                raise ValueError('The pinned codec source has an unexpected archive root.')
            item.name = item.name[len(prefix):].lstrip('/')
        archive.extractall(bcg, members=[item for item in entries if item.name], filter='data')
    with tarfile.open(archives / 'bcg729_1.1.1-3+deb13u1.debian.tar.xz') as archive:
        archive.extractall(bcg, filter='data')
    for name in (bcg / 'debian/patches/series').read_text().splitlines():
        if name and not name.startswith('#'):
            patch_tree(bcg, bcg / 'debian/patches' / name)
    require_hash(bcg / 'src/LP2LSPConversion.c', '1baa079f18eb15e9ec355ca1b9de982100b45f16b6eb1ac79eecf8e02bf850f1')
    require_hash(bcg / 'CMakeLists.txt', 'b977866a6d68bec936baa5331a00ef14dcef0048c669d001f59c284ca25170b5')
    for filename in ['BCG729-COPYRIGHT.txt', 'BCG729-GPL-3.txt', 'MODULE-LICENSE.txt', 'NOTICES.md', 'buffer-safety.patch']:
        shutil.copy2(RECIPE.parent / 'codecs/bcg729' / filename, codec / filename)
    shutil.copy2(reg_patch, output / reg_patch.name)
    shutil.copy2(RECIPE.parent.parent / 'tests/pbx_bcg729_codec.c', output / 'codec-check.c')
    files = {path.relative_to(output).as_posix(): digest(path) for path in sorted(output.rglob('*')) if path.is_file() and not path.is_symlink()}
    links = {path.relative_to(output).as_posix(): str(path.readlink()) for path in sorted(output.rglob('*')) if path.is_symlink()}
    manifest = {'schema': 1, 'upstream_commit': FS_REV, 'sofia_commit': SOFIA_REV, 'codec_module_commit': CODEC_REV,
                'patch_sha256': REG_PATCH, 'source_reg_sha256': REG_PATCHED, 'codec_patch_sha256': CODEC_PATCH,
                'codec_source_sha256': CODEC_PATCHED, 'bcg729_debian_version': '1.1.1-3+deb13u1',
                'bcg729_source_archives': BCG_ARCHIVES, 'files': files, 'links': links,
                'build_only': True, 'binary_qualification': False, 'codec_distribution_status': 'local-source-build-only'}
    (output / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['freeswitch-repository', 'sofia-repository', 'codec-repository', 'bcg729-archives', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        result = prepare(args.freeswitch_repository, args.sofia_repository, args.codec_repository, args.bcg729_archives, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError):
        parser.exit(1, 'Native build sources could not be prepared from the pinned inputs.\n')
    print(json.dumps({k: result[k] for k in ['upstream_commit', 'sofia_commit', 'codec_module_commit', 'source_reg_sha256', 'codec_source_sha256', 'binary_qualification']}))


if __name__ == '__main__':
    main()
