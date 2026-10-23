#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Read-only provenance for the already published, complete SDK source archive.

This does not build the SDK or establish vendor binary correspondence. Run it
against the original clean SDK checkout used for the pinned Android source.
"""
import argparse
import concurrent.futures
import configparser
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
from urllib.parse import urljoin, urlsplit

COMMIT = '348e8de32fb2ac56b7b0a7167968fc1ac707f7b2'
SEED = {
    'url': 'https://github.com/embire2/openwebpbx/releases/download/v1.0.11/openwebpbx-1.0.11-android-source.tar.gz',
    'bytes': 364437897,
    'sha256': '61784eaae91db82d79ada014dae931f01af3e2ad2f5bbcd641b288d92bf89449',
    'sdk_prefix': 'openwebpbx-android/linphone-sdk-5.5.23/',
}


def relative(value):
    if not value or value.startswith('/') or re.search(r'[\\:<>"|?*\x00-\x1f\x7f]', value):
        raise ValueError('Unsafe source path.')
    for part in value.split('/'):
        if part in ('', '.', '..', '.git') or part.endswith(('.', ' ')) or re.match(r'(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)', part):
            raise ValueError('Unsafe source path component.')
    return value


def source_url(value):
    uri = urlsplit(value)
    if (uri.scheme != 'https' or uri.hostname not in ('github.com', 'gitlab.linphone.org')
            or uri.port not in (None, 443) or uri.username or uri.password or uri.query or uri.fragment):
        raise ValueError('A canonical public source URL is required.')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.sdk_source.resolve(strict=True)
    if args.output.exists() or args.output.is_symlink():
        raise ValueError('Use a new manifest output.')
    lock = json.loads((Path(__file__).parents[1] / 'native/source-lock.json').read_text())
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')

    def git(repo, *arguments):
        return subprocess.check_output(['git', '-C', str(root / repo), *arguments], env=env, timeout=60)

    def clean():
        if git('', 'rev-parse', 'HEAD').decode().strip() != COMMIT:
            raise ValueError('The exact original SDK checkout is required.')
        if git('', 'status', '--porcelain', '--untracked-files=no', '--ignore-submodules=untracked'):
            raise ValueError('Tracked SDK or submodule source differs.')

    clean()
    repositories = [{'path': '', 'commit': COMMIT, 'url': lock['source']['url'], 'depth': 0,
                     'tree_sha1': git('', 'rev-parse', 'HEAD^{tree}').decode().strip()}]
    for line in git('', 'submodule', 'status', '--recursive').decode().splitlines():
        match = re.fullmatch(r' ([a-f0-9]{40}) ([^ ]+)(?: \([^\r\n]*\))?', line)
        if not match:
            raise ValueError('A submodule does not match its committed version.')
        commit, path = match.groups()
        relative(path)
        if git(path, 'rev-parse', 'HEAD').decode().strip() != commit:
            raise ValueError('The actual submodule commit differs.')
        parent = max((row for row in repositories if not row['path'] or path.startswith(row['path'] + '/')),
                     key=lambda row: len(row['path']))
        local = path[len(parent['path']) + 1:] if parent['path'] else path
        modules = configparser.RawConfigParser(strict=True)
        modules.read_string(git(parent['path'], 'show', parent['commit'] + ':.gitmodules').decode())
        matches = [section for section in modules.sections() if modules.get(section, 'path', fallback='') == local]
        if len(matches) != 1:
            raise ValueError('A literal source module mapping is ambiguous.')
        origin = lock['source']['canonical_upstream_url'] if not parent['path'] else parent['url']
        url = source_url(urljoin(origin.rstrip('/') + '/', modules.get(matches[0], 'url')))
        if not parent['path']:
            expected = [row for row in lock['source']['direct_gitlinks'] if row['path'] == path]
            if len(expected) != 1 or expected[0]['commit'] != commit or expected[0]['url'] != url:
                raise ValueError('The pinned direct SDK source graph differs.')
        repositories.append({'path': path, 'commit': commit, 'url': url, 'depth': parent['depth'] + 1,
                             'tree_sha1': git(path, 'rev-parse', 'HEAD^{tree}').decode().strip()})
    if len(repositories) != 33 or any(row['depth'] > 8 for row in repositories):
        raise ValueError('The complete original source graph differs.')

    index = []
    for item in git('', 'ls-files', '--recurse-submodules', '--stage', '-z').split(b'\0'):
        if not item:
            continue
        metadata, path = item.split(b'\t', 1)
        mode, blob, stage = metadata.decode().split()
        path = relative(path.decode('utf-8', errors='strict'))
        if mode not in ('100644', '100755', '120000') or stage != '0' or not re.fullmatch('[a-f0-9]{40}', blob):
            raise ValueError('An exact ordinary source index is required.')
        index.append((path, mode, blob))
    if len(index) != 38406 or len({row[0].casefold() for row in index}) != len(index):
        raise ValueError('The complete case-safe original source inventory differs.')

    def inspect(item):
        name, mode, blob = item
        path = root / name
        before = path.lstat()
        if mode == '120000':
            seed = os.readlink(path).encode('utf-8')
            # Some tracked links name build-generated targets. Export their
            # exact descriptions without requiring the target to exist.
            if not path.resolve(strict=False).is_relative_to(root):
                raise ValueError('An original source link escaped the SDK.')
        else:
            if path.is_symlink() or not path.is_file() or before.st_size > 268435456:
                raise ValueError('An original source file changed type or exceeded its bound.')
            seed = path.read_bytes()
        after = path.lstat()
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError('An original source file changed during inspection.')

        def object_hash(data):
            return hashlib.sha1(('blob ' + str(len(data))).encode() + b'\0' + data).hexdigest()

        source, transform = seed, 'none'
        if object_hash(source) != blob:
            candidates = {'lf': seed.replace(b'\r\n', b'\n'),
                          'git_ident_unexpand': re.sub(br'\$Id:[^\r\n$]*\$', b'$Id$', seed)}
            matches = [(kind, data) for kind, data in candidates.items() if object_hash(data) == blob]
            if len(matches) != 1:
                raise ValueError('An original checkout filter cannot be mapped to its exact Git blob.')
            transform, source = matches[0]
        if len(source) <= 2048 and source.startswith(b'version https://git-lfs.github.com/spec/v1'):
            raise ValueError('Unresolved LFS pointers cannot supply complete source.')
        return {'path': name, 'mode': mode, 'seed_bytes': len(seed), 'seed_sha256': hashlib.sha256(seed).hexdigest(),
                'source_bytes': len(source), 'source_sha256': hashlib.sha256(source).hexdigest(),
                'git_blob_sha1': blob, 'transform': transform}

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        files = sorted(pool.map(inspect, index), key=lambda row: row['path'])
    clean()
    result = {'schema': 1, 'purpose': 'exact-sdk-source-seed', 'root_commit': COMMIT,
              'archive': SEED, 'repositories': repositories, 'files': files,
              'binary_source_mapping_verified': False, 'source_sdk_rebuild_qualified': False}
    encoded = (json.dumps(result, ensure_ascii=True, separators=(',', ':')) + '\n').encode()
    if len(encoded) > 32 * 1024 * 1024:
        raise ValueError('The source seed manifest exceeds its bound.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('xb') as output:
        with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0, compresslevel=9) as compressor:
            compressor.write(encoded)
    print(json.dumps({'schema': 1, 'files': len(files), 'repositories': len(repositories),
                      'canonical_source_bytes': sum(row['source_bytes'] for row in files),
                      'checkout_transforms': sum(row['transform'] != 'none' for row in files),
                      'manifest_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
                      'archive_downloaded': False, 'SDK_modified': False, 'candidate_qualified': False}))


if __name__ == '__main__':
    main()
