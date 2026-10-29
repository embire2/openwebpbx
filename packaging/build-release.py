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
import sys
import importlib.util

root = pathlib.Path(__file__).resolve().parents[1]

def sha256(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--target', choices=['windows', 'debian'], required=True)
parser.add_argument('--server', type=pathlib.Path, required=True)
parser.add_argument('--updater', type=pathlib.Path, required=True)
parser.add_argument('--desktop', type=pathlib.Path)
parser.add_argument('--engine', type=pathlib.Path)
parser.add_argument('--backup-runtime', type=pathlib.Path)
parser.add_argument('--acme', type=pathlib.Path)
parser.add_argument('--music', type=pathlib.Path)
parser.add_argument('--codec-source', type=pathlib.Path)
parser.add_argument('--registrar-source', type=pathlib.Path, help='Explicit matching MSI pthread source supplement; 6,215 reviewed codec inputs, including the Windows WebSocket patch, remain separate.')
parser.add_argument('--voices', type=pathlib.Path, help='Complete, verified Keoma South African English voice pack 1.0.2 directory (offline audio, no API key).')
parser.add_argument('--output', type=pathlib.Path, default=root / 'artifacts')
args = parser.parse_args()
version = (root / 'VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    parser.error('VERSION must contain a numeric major.minor.patch release.')
server_executable = 'OpenWebPbx.Server.exe' if args.target == 'windows' else 'OpenWebPbx.Server'
if not (args.server / server_executable).is_file():
    parser.error('Supply the complete published service directory.')
updater_executable = 'OpenWebPbx.Updater.exe' if args.target == 'windows' else 'OpenWebPbx.Updater'
if not (args.updater / updater_executable).is_file():
    parser.error('Supply the complete published independent updater directory.')
if args.target == 'windows' and (not args.desktop or not (args.desktop / 'OpenWebPbx.Desktop.exe').is_file()):
    parser.error('Supply the complete Windows-built manager directory.')
if args.target == 'debian' and (not args.engine or not args.engine.is_file()):
    parser.error('Supply the clean engine archive built from upstream source.')
voice_catalog_path = root / 'app/pbx_setup/resources/voicepacks/1.0.2/catalog.json'
if voice_catalog_path.is_file() and not args.voices:
    parser.error('Supply --voices with the complete generated Keoma 1.0.2 pack; partial prompt releases are refused.')
if args.voices:
    voice_spec = importlib.util.spec_from_file_location('release_voicepack', root / 'packaging/voices/voicepack.py')
    voice_module = importlib.util.module_from_spec(voice_spec)
    voice_spec.loader.exec_module(voice_module)
    voice_catalog = voice_module.load_catalog(voice_catalog_path)
    voice_module.verify(voice_catalog,args.voices)
if args.target != 'windows' and args.registrar_source:
    parser.error('Registrar dependency sources apply only to the Windows native build.')
if args.target == 'windows':
    if not args.engine or not (args.engine / 'native-manifest.json').is_file():
        parser.error('Supply the verified native Windows engine directory.')
    if not args.backup_runtime or not (args.backup_runtime / 'python.exe').is_file():
        parser.error('Supply the pinned isolated Windows backup runtime.')
    if not args.acme or not (args.acme / 'wacs.exe').is_file():
        parser.error('Supply the pinned Windows certificate runtime and licences.')
    if not args.codec_source or not (args.codec_source / 'source-manifest.json').is_file():
        parser.error('Supply the verified source for the local Windows call codec.')
    codec_source = json.loads((args.codec_source / 'source-manifest.json').read_text())
    if codec_source.get('upstream_commit') != 'ef32e205295e29f034f1453ad245ba5efb07b94a' or codec_source.get('bcg729_debian_version') != '1.1.1-3+deb13u1' or codec_source.get('links') or len(codec_source.get('files', {})) != 6215:
        parser.error('The corrected Windows source codec inputs are required.')
    websocket_patch = '7d2a3147d67537f47f57a316044fe4b61f47e060df33fa1f4b16c917958b120b'
    websocket_sources = {'ws.c': '7e7d6a14f5426b6a18054107a4f3353cfb1569838ec88625beaa2b1d42296d55', 'ws.h': '98898e83103f7f7f499c58a2d702c5cd8f5dd35291827c6aa4881bb6289791bb'}
    if codec_source.get('websocket_patch_sha256') != websocket_patch or codec_source.get('websocket_sources') != websocket_sources or codec_source['files'].get('windows-websocket-fragments.patch') != websocket_patch or any(codec_source['files'].get('freeswitch/libs/sofia-sip/libsofia-sip-ua/tport/' + name) != expected for name, expected in websocket_sources.items()):
        parser.error('The pinned fragmented SIP WebSocket sources and their public patch are required.')
    expected_codec_files = set(codec_source.get('files', {})) | {'source-manifest.json'}
    actual_codec_files = set()
    for path in args.codec_source.rglob('*'):
        if path.is_symlink():
            parser.error('The source codec bundle contains a link.')
        if path.is_file():
            relative = path.relative_to(args.codec_source).as_posix()
            actual_codec_files.add(relative)
            if relative != 'source-manifest.json' and (relative not in codec_source['files'] or sha256(path) != codec_source['files'][relative]):
                parser.error('The source codec bundle failed exact byte verification.')
    if expected_codec_files != actual_codec_files:
        parser.error('The source codec bundle inventory is incomplete.')
    for directory, manifest_name in [(args.engine, 'native-manifest.json'), (args.backup_runtime, 'runtime-manifest.json'), (args.acme, 'bundle-manifest.json')]:
        metadata = json.loads((directory / manifest_name).read_text())
        if metadata.get('schema') != 1 or not metadata.get('files'):
            parser.error('An input runtime inventory is missing.')
        if directory == args.engine:
            pins = {
                'upstream_commit': 'ef32e205295e29f034f1453ad245ba5efb07b94a',
                'patch_sha256': '1191411f00efb2ca763a41721207923ffc92f8777aa2ebfa23b342a5e801c26f',
                'source_reg_sha256': '8cee43d5f88b7e1cd158f125b2780409b0c52c7cbac37fd3039a2a8981ddc317',
                'core_sha256': '8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726',
                'source_msi_sha256': 'f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d',
                'core_version': '1.11.3',
                'websocket_patch_sha256': websocket_patch,
                'websocket_sources': websocket_sources,
            }
            if set(metadata['files']) != {'mod/mod_sofia.dll'} or any(metadata.get(key) != expected for key, expected in pins.items()) or not metadata.get('runtime_dependencies') or metadata.get('source_manifest_sha256') != sha256(args.codec_source / 'source-manifest.json'):
                parser.error('Supply only the pinned patched Windows registrar and its verified provenance.')
            if metadata.get('msi_pthread_experiment'):
                if not args.registrar_source:
                    parser.error('Supply the exact matching MSI pthread sources used by this registrar.')
                helper = root / 'packaging/freeswitch/bundle-windows-native.py'
                spec = importlib.util.spec_from_file_location('registrar_sources', helper)
                source_bundle = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(source_bundle)
                try:
                    source_bundle.verify_registrar_bundle(args.registrar_source, metadata, sha256(args.codec_source / 'source-manifest.json'))
                except (ValueError, KeyError, OSError) as error:
                    parser.error(str(error))
            elif args.registrar_source:
                parser.error('Registrar dependency sources were supplied for a native build that did not use them.')
        for relative, expected in metadata['files'].items():
            path = directory / relative
            if '\\' in relative or ':' in relative or pathlib.PurePosixPath(relative).is_absolute() or any(part in ('', '.', '..') for part in relative.split('/')) or path.is_symlink() or not path.is_file() or sha256(path) != expected:
                parser.error('An input runtime failed exact file verification.')
        expected_files = set(metadata['files']) | {manifest_name}
        actual_files = {path.relative_to(directory).as_posix() for path in directory.rglob('*') if path.is_file()}
        if actual_files != expected_files:
            parser.error('An input runtime contains missing or unlisted files.')

files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
def copy_tracked_tree(source, destination):
    prefix=source.relative_to(root).as_posix()+'/'
    for filename in files:
        if not filename.startswith(prefix):
            continue
        path=root/filename
        if path.is_symlink() or not path.is_file():
            raise ValueError('A reviewed package source is missing or linked: '+filename)
        target=destination/path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path,target)

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
    (stage / 'server').chmod(0o755)
    for path in (stage / 'server').rglob('*'):
        path.chmod(0o755 if path.is_dir() or path.name == server_executable else 0o644)
    shutil.copytree(args.updater, stage / 'updater')
    (stage / 'updater').chmod(0o755)
    for path in (stage / 'updater').rglob('*'):
        path.chmod(0o755 if path.is_dir() or path.name == updater_executable else 0o644)
    # Only public verification material belongs in a release, never a signer key.
    for filename in ['verify_feed.py', 'release-public.pem']:
        shutil.copy2(root / 'packaging/updates' / filename, stage / filename)
    copy_tracked_tree(root / 'packaging/licenses', stage / 'licenses')
    copy_tracked_tree(root / 'docs', stage / 'docs')
    # A local codec recipe is source, never a prebuilt combined codec binary.
    copy_tracked_tree(root / 'packaging/codecs', stage / 'codecs')
    if args.voices:
        # The final signed release manifest seals every offline spoken WAV.
        # API credentials and the private generation cache are never copied.
        shutil.copytree(args.voices,stage/'voices'/voice_catalog['version'])
        copy_tracked_tree(root/'packaging/voices',stage/'voice-tools')
    shutil.copy2(root / 'LICENSE', stage / 'LICENSE')
    shutil.copy2(root / '3CX.md', stage / '3CX.md')
    shutil.copy2(root / 'packaging/windows/bootstrap.php', stage / 'bootstrap.php')
    shutil.copy2(root / 'VERSION', stage / 'VERSION')
    (stage / 'README.txt').write_text(f'OpenWeb PBX {version}\n\nStart with docs/installing-{version}.md.\nFeature coverage and remaining work: docs/feature-coverage.md.\nSource: https://github.com/embire2/openwebpbx\n')
    installer_prefix='packaging/'+args.target+'/'
    for filename in files:
        if filename.startswith(installer_prefix) and len(pathlib.PurePosixPath(filename).parts)==3:
            path=root/filename
            if path.is_symlink() or not path.is_file():
                raise ValueError('A reviewed installer source is missing or linked: '+filename)
            shutil.copy2(path, stage / path.name)
    if args.target == 'windows':
        # One portable instance protocol implementation; provider credentials
        # and the central registry configuration never belong in an installer.
        for shared_name in ('tenant-domains.py','tenant-domains.php','onboarding.py','onboarding.php','webhotel-onboarding.py'):
            shared=root/'packaging/debian'/shared_name
            if shared.is_symlink() or not shared.is_file() or shared.relative_to(root).as_posix() not in files:
                raise ValueError('The reviewed portable tenant-domain source is missing.')
            shutil.copy2(shared,stage/shared_name)
        shutil.copytree(args.desktop, stage / 'desktop')
        shutil.copytree(args.engine, stage / 'engine')
        shutil.copytree(args.backup_runtime, stage / 'backup-runtime')
        shutil.copytree(args.acme, stage / 'acme')
        shutil.copytree(args.codec_source, stage / 'codec-source')
        if args.registrar_source:
            shutil.copytree(args.registrar_source, stage / 'registrar-source')
        shutil.copy2(root / 'packaging/freeswitch/core-exports.py', stage / 'codecs/bcg729/core-exports.py')
        codec_recipe = {
            'schema': 1,
            'source_manifest_sha256': sha256(args.codec_source / 'source-manifest.json'),
            'core_export_helper_sha256': sha256(root / 'packaging/freeswitch/core-exports.py'),
            'build_helper_sha256': sha256(root / 'packaging/codecs/bcg729/build-windows-local.py'),
            'compiler_pin_sha256': sha256(root / 'packaging/codecs/bcg729/windows-compiler.json'),
            'heap_check_sha256': sha256(root / 'packaging/codecs/bcg729/windows-heap-check.c'),
            'core_sha256': '8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726',
            'apr_sha256': 'bb3adfa1b6b7e3f699b037a0429fca49482e5a9e829ad1f01cc31d447a74a56d',
            'distribution': 'local-source-build-only',
        }
        (stage / 'codecs/bcg729/windows-recipe.json').write_text(json.dumps(codec_recipe, indent=2) + '\n')
        if args.music:
            music = json.loads((args.music / 'bundle-manifest.json').read_text())
            for rate, entry in music['rates'].items():
                path = args.music / entry['path']
                if entry['path'] != f'{rate}/lofi-beat-loop-schmoop.wav' or path.is_symlink() or not path.is_file() or sha256(path) != entry['sha256']:
                    parser.error('The prebuilt hold music failed verification.')
            if set(music['rates']) != {'8000', '16000', '32000', '48000'}:
                parser.error('The prebuilt hold music must contain all four verified rates.')
            shutil.copytree(args.music, stage / 'music')
        else:
            subprocess.run([sys.executable, str(root / 'packaging/windows/build-hold-music.py'),
                            '--source-root', str(root / 'resources/music-on-hold'), '--output', str(stage / 'music')], check=True)
        # This file belongs to an installed machine, never a generic release.
        (stage / 'desktop/server.json').unlink(missing_ok=True)
    else:
        shutil.copy2(args.engine, stage / 'engine.tar.gz')
        for executable in ['install.sh', 'configure.py', 'upgrade.sh', 'upgrade.py', 'backups.py', 'install-backups.sh', 'server/OpenWebPbx.Server']:
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
