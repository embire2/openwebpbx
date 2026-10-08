#!/usr/bin/env python3
"""Package reviewed Git source and separately built binaries; never read live PBX data."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
import re

root = pathlib.Path(__file__).resolve().parents[1]

def sha256(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--target', choices=['windows', 'debian'], required=True)
parser.add_argument('--server', type=pathlib.Path, required=True)
parser.add_argument('--desktop', type=pathlib.Path)
parser.add_argument('--engine', type=pathlib.Path)
parser.add_argument('--output', type=pathlib.Path, default=root / 'artifacts')
args = parser.parse_args()
version = (root / 'VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    parser.error('VERSION must contain a numeric major.minor.patch release.')
server_executable = 'OpenWebPbx.Server.exe' if args.target == 'windows' else 'OpenWebPbx.Server'
if not (args.server / server_executable).is_file():
    parser.error('Supply the complete published service directory.')
if args.target == 'windows' and (not args.desktop or not (args.desktop / 'OpenWebPbx.Desktop.exe').is_file()):
    parser.error('Supply the complete Windows-built manager directory.')
if args.target == 'debian' and (not args.engine or not args.engine.is_file()):
    parser.error('Supply the clean engine archive built from upstream source.')

files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
excluded = {'.gitignore', '.project', '.github', 'AGENTS.md', '3CX.md', 'tests', 'platform', 'packaging', 'docs', 'website', 'android', 'mobile'}
name = f'openwebpbx-{version}-' + ('windows-x64' if args.target == 'windows' else 'debian13-amd64')
args.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='openweb-release-') as temporary:
    stage = pathlib.Path(temporary) / name
    stage.mkdir()
    for filename in files:
        if not filename or pathlib.PurePosixPath(filename).parts[0] in excluded:
            continue
        path = root / filename
        if path.is_symlink():
            raise ValueError(f'Source symlink must be reviewed before packaging: {filename}')
        if not path.is_file():
            continue
        if path.name.startswith('.env') or path.suffix in {'.zip', '.dump', '.pfx', '.key'}:
            raise ValueError(f'Private or archive-shaped source must be reviewed: {filename}')
        target = stage / 'web' / filename
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    shutil.copytree(args.server, stage / 'server')
    for path in (stage / 'server').rglob('*'):
        path.chmod(0o755 if path.is_dir() or path.name == server_executable else 0o644)
    shutil.copytree(root / 'packaging/licenses', stage / 'licenses')
    shutil.copytree(root / 'docs', stage / 'docs')
    # A local codec recipe is source, never a prebuilt combined codec binary.
    shutil.copytree(root / 'packaging/codecs', stage / 'codecs')
    shutil.copy2(root / 'LICENSE', stage / 'LICENSE')
    shutil.copy2(root / '3CX.md', stage / '3CX.md')
    shutil.copy2(root / 'packaging/windows/bootstrap.php', stage / 'bootstrap.php')
    shutil.copy2(root / 'VERSION', stage / 'VERSION')
    (stage / 'README.txt').write_text(f'OpenWeb PBX {version}\n\nStart with docs/installing-{version}.md.\nFeature coverage and remaining work: docs/feature-coverage.md.\nSource: https://github.com/embire2/openwebpbx\n')
    for path in (root / 'packaging' / args.target).iterdir():
        if path.is_file():
            shutil.copy2(path, stage / path.name)
    if args.target == 'windows':
        shutil.copytree(args.desktop, stage / 'desktop')
        # This file belongs to an installed machine, never a generic release.
        (stage / 'desktop/server.json').unlink(missing_ok=True)
    else:
        shutil.copy2(args.engine, stage / 'engine.tar.gz')
        for executable in ['install.sh', 'configure.py', 'upgrade.sh', 'upgrade.py', 'server/OpenWebPbx.Server']:
            (stage / executable).chmod(0o755)
    # The updater deploys only listed files, validates bytes before making changes,
    # and uses this same manifest to identify newly installed files on rollback.
    manifest = {'version': version, 'files': {}}
    for path in sorted(stage.rglob('*')):
        if path.is_symlink():
            raise ValueError(f'Release output symlink is not allowed: {path.relative_to(stage)}')
        if path.is_file():
            manifest['files'][path.relative_to(stage).as_posix()] = sha256(path)
    (stage / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    if args.target == 'windows':
        archive = args.output / (name + '.zip')
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as output:
            for path in sorted(stage.rglob('*')):
                if path.is_file():
                    output.write(path, path.relative_to(stage.parent))
    else:
        archive = args.output / (name + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as output:
            output.add(stage, arcname=name)
print(f'{sha256(archive)}  {archive.name}')
