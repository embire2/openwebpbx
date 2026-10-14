#!/usr/bin/env python3
"""Build the isolated Windows backup runtime from pinned upstream downloads."""
import argparse
import hashlib
import json
import pathlib
import shutil
import urllib.request
import zipfile

PINS = [
    ('python-3.13.16-embed-amd64.zip', 'https://www.python.org/ftp/python/3.13.16/python-3.13.16-embed-amd64.zip', '97dae5274cc54867065e8d5a3226e48c35017ed332a0fdb0e27d5b5821961297', 'runtime'),
    ('cryptography-50.0.2-cp311-abi3-win_amd64.whl', 'https://files.pythonhosted.org/packages/9a/4f/adfc442765721292fff86d314ce385d3249d22db42295c0dd057727b60f3/cryptography-50.0.2-cp311-abi3-win_amd64.whl', '7afa5a6602a9f29af1f3a2965f831bae7c9d5d597b7cbb716d41ab3b7d89879c', 'wheel'),
    ('cffi-2.1.1-cp313-cp313-win_amd64.whl', 'https://files.pythonhosted.org/packages/60/a6/8b149b2c3f2e11aaa1618ef64500b45f50f22c57a977a4dff1aff1f91042/cffi-2.1.1-cp313-cp313-win_amd64.whl', '1aa5645c30469b09530c4ebca77ebf8f17618293c58f8549cb1a543a50236e7d', 'wheel'),
    ('pycparser-3.11-py3-none-any.whl', 'https://files.pythonhosted.org/packages/90/11/0e6f11117525ff0eec40ebac3d313376f102df93ca44ad9e893ee85e4f89/pycparser-3.11-py3-none-any.whl', '51d5a8ba2be0bbe440b99d2112604c95bbbc3c2748a64260186c541e1729cd80', 'wheel'),
    ('Python-3.13.16.tar.xz', 'https://www.python.org/ftp/python/3.13.16/Python-3.13.16.tar.xz', 'f4b1bfb3c79b5bb11b8d228a12504163b4c0dab4d679828d8f5f26b6cb6ab35d', 'source'),
    ('cryptography-50.0.2.tar.gz', 'https://files.pythonhosted.org/packages/9d/af/182eb91b0df3fe75c4d9f26fe70684569566745f6ba7e5c9c73a862c5252/cryptography-50.0.2.tar.gz', '7b46165bb56eb4704e2eaaf86f3c940d19154535d9b0ca7d6d590b04060e00d5', 'source'),
    ('cffi-2.1.1.tar.gz', 'https://files.pythonhosted.org/packages/9e/ef/008a1939e372c06329a3fce4279c02f328488f3526744906eeec3da7ad5f/cffi-2.1.1.tar.gz', 'dd31f52ea1086513bb9df30f8fcee9b8918323ae067a3d5b78bc826a000712be', 'source'),
    ('pycparser-3.11.tar.gz', 'https://files.pythonhosted.org/packages/da/a8/c5fdbeee588bb8ada9458774f43adf1bdd30bd59157055142183e769a024/pycparser-3.11.tar.gz', 'd875f09c3507d00e1aba0eecc6dcadc1352f30fff09dc6bff2f1c2935e97c2bc', 'source'),
]

def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()

def build(cache, output, sources):
    if output.exists():
        raise ValueError('Choose a new runtime output directory.')
    cache.mkdir(parents=True, exist_ok=True)
    sources.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True)
    provenance = []
    for name, url, expected, kind in PINS:
        download = cache / name
        if not download.exists():
            temporary = download.with_suffix(download.suffix + '.part')
            try:
                with urllib.request.urlopen(url, timeout=60) as response, temporary.open('xb') as file:
                    if not response.url.startswith('https://'):
                        raise ValueError('Upstream redirected outside HTTPS.')
                    shutil.copyfileobj(response, file)
                if digest(temporary) != expected:
                    raise ValueError('Upstream download failed SHA-256 verification: ' + name)
                temporary.replace(download)
            finally:
                temporary.unlink(missing_ok=True)
        if download.is_symlink() or not download.is_file() or digest(download) != expected:
            raise ValueError('Pinned input verification failed: ' + name)
        shutil.copy2(download, sources / name)
        provenance.append(dict(name=name, url=url, sha256=expected, kind=kind))
        if kind == 'source':
            continue
        destination = output if kind == 'runtime' else output / 'Lib/site-packages'
        destination.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(download) as archive:
            for item in archive.infolist():
                path = pathlib.PurePosixPath(item.filename)
                if path.is_absolute() or any(x in ('..', '.') or ':' in x or '\\' in x for x in path.parts) or ((item.external_attr >> 16) & 0o170000) == 0o120000:
                    raise ValueError('Unsafe pinned archive path.')
                target = destination.joinpath(*path.parts)
                if item.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(item) as source, target.open('xb') as file:
                        shutil.copyfileobj(source, file)
    # _pth keeps the runtime isolated from PATH, PYTHONPATH and user packages.
    (output / 'python313._pth').write_text('python313.zip\n.\nLib/site-packages\n', encoding='utf-8')
    record = dict(schema=1, platform='windows-x64', python='3.13.16', inputs=provenance,
                  files={path.relative_to(output).as_posix(): digest(path) for path in sorted(output.rglob('*')) if path.is_file()})
    (output / 'runtime-manifest.json').write_text(json.dumps(record, indent=2) + '\n')
    (sources / 'upstream-inputs.json').write_text(json.dumps(provenance, indent=2) + '\n')
    return record

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--sources', type=pathlib.Path, required=True)
    args = parser.parse_args()
    record = build(args.cache, args.output, args.sources)
    print(json.dumps(dict(python=record['python'], files=len(record['files']), pinned_inputs=len(record['inputs']))))
