#!/usr/bin/env python3
"""Update an installed Debian PBX from a verified release; preserve private data."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.request

WEB = Path('/var/www/fusionpbx')
ENGINE = Path('/usr/share/freeswitch/scripts')
SERVER = Path('/opt/openwebpbx/service')
CONFIG = Path('/etc/fusionpbx/config.conf')
SERVICES = ['openwebpbx', 'php8.4-fpm', 'freeswitch']


def validate_manifest(package):
    manifest = json.loads((package / 'release-manifest.json').read_text())
    version = (package / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or manifest.get('version') != version:
        raise ValueError('Release version is invalid or inconsistent.')
    files = manifest.get('files', {})
    required = {'web/resources/require.php', 'server/OpenWebPbx.Server', 'bootstrap.php',
                'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/configuration/acl.conf.lua',
                'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/dialplan/dialplan.lua'}
    if not isinstance(files, dict) or not required.issubset(files):
        raise ValueError('The complete release manifest is required.')
    actual_files = {path.relative_to(package).as_posix() for path in package.rglob('*') if path.is_file()}
    if actual_files != set(files) | {'release-manifest.json'}:
        raise ValueError('The extracted package has missing or unlisted files. Extract it into an empty folder.')
    for name, expected in files.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts or '\\' in name or not relative.parts:
            raise ValueError('Release manifest contains an unsafe path.')
        path = package / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(package.resolve()):
            raise ValueError('Release files must be ordinary files inside the extracted package.')
        with path.open('rb') as handle:
            actual = hashlib.file_digest(handle, 'sha256').hexdigest()
        if not isinstance(expected, str) or not re.fullmatch('[a-f0-9]{64}', expected) or actual != expected:
            raise ValueError(f'Release checksum failed: {name}')
    return manifest


def deployment_files(package, manifest):
    result = {}
    prefixes = [
        ('web/', WEB), ('server/', SERVER),
        ('web/app/switch/resources/scripts/', ENGINE),
        ('web/app/pbx_setup/resources/switch/scripts/', ENGINE),
        ('web/app/pbx_setup/resources/prompts/', Path('/usr/share/freeswitch/sounds/openwebpbx')),
    ]
    for name in manifest['files']:
        for prefix, destination in prefixes:
            if name.startswith(prefix):
                relative = PurePosixPath(name[len(prefix):])
                if any(part.startswith('.env') or part == '.git' for part in relative.parts):
                    raise ValueError('Private files are not deployable.')
                target = destination / relative
                for parent in [target, *target.parents]:
                    if parent.is_symlink():
                        raise ValueError(f'Installed path is a symlink and needs manual review: {target}')
                result[target] = package / name
    prompt = package / 'web/app/pbx_setup/resources/prompts/openweb.xml'
    if prompt.is_file():
        result[Path('/etc/freeswitch/languages/en/ivr/openweb.xml')] = prompt
    for helper in ['configure-sip-tls.py', 'configure-sip-tls.php', 'upgrade.py']:
        if helper in manifest['files']:
            result[Path('/opt/openwebpbx/tools') / helper] = package / helper
    return result


def read_settings():
    settings = {}
    for line in CONFIG.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith(('#', ';')):
            key, value = line.split('=', 1)
            settings[key.strip()] = value.strip().strip('"')
    if settings.get('database.0.type') != 'pgsql':
        raise ValueError('This updater requires the existing PostgreSQL configuration.')
    # Existing FusionPBX installations retain the legacy Event Socket keys.
    # Match the native PHP client's precedence without writing secrets to logs.
    for current, legacy in [('switch.event_socket.host', 'event_socket.ip_address'),
                            ('switch.event_socket.port', 'event_socket.port'),
                            ('switch.event_socket.password', 'event_socket.password')]:
        if not settings.get(current) and settings.get(legacy):
            settings[current] = settings[legacy]
    return settings


def engine_api(settings, command):
    if '\n' in command or '\r' in command:
        raise ValueError('Invalid call engine command.')
    if not settings.get('switch.event_socket.password'):
        # Legacy installs may resolve credentials through native configuration
        # defaults rather than config.conf. Use their existing authenticated
        # client; only the requested API response crosses this private pipe.
        code = 'require "/var/www/fusionpbx/resources/require.php"; $r=event_socket::api($argv[1]); if(!is_string($r)){exit(1);} echo $r;'
        result = subprocess.run(['php', '-r', code, command], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError('The existing native call engine connection is unavailable.')
        return result.stdout.decode()
    host = settings.get('switch.event_socket.host', '127.0.0.1')
    port = int(settings.get('switch.event_socket.port', '8021'))
    password = settings.get('switch.event_socket.password', '')
    if not password or '\n' in password or '\r' in password:
        raise ValueError('The private call engine connection is unavailable.')
    with socket.create_connection((host, port), timeout=5) as connection:
        stream = connection.makefile('rb')
        def frame():
            headers = {}
            while True:
                line = stream.readline()
                if not line:
                    raise RuntimeError('The call engine closed the connection.')
                if line in (b'\n', b'\r\n'):
                    break
                key, value = line.decode().split(':', 1)
                headers[key.lower()] = value.strip()
            size = int(headers.get('content-length', '0'))
            if size > 1024 * 1024:
                raise RuntimeError('Unexpected call engine response.')
            return headers, stream.read(size).decode()
        frame()
        connection.sendall(f'auth {password}\n\n'.encode())
        headers, _ = frame()
        if not headers.get('reply-text', '').startswith('+OK'):
            raise RuntimeError('The call engine connection could not be authenticated.')
        connection.sendall(('api ' + command + '\n\n').encode())
        _, body = frame()
        return body


def check_idle(settings):
    data = json.loads(engine_api(settings, 'show calls as json'))
    if int(data.get('row_count', -1)) != 0:
        raise RuntimeError('Calls are active. Run the update again after they have finished.')


def atomic_copy(source, target):
    absent = []
    parent = target.parent
    while not parent.exists():
        absent.append(parent)
        parent = parent.parent
    for directory in reversed(absent):
        directory.mkdir()
        directory.chmod(0o755)
    previous = target.stat() if target.exists() else None
    with tempfile.NamedTemporaryFile(prefix='.openweb-update-', dir=target.parent, delete=False) as handle:
        temporary = Path(handle.name)
    try:
        shutil.copyfile(source, temporary)
        executable = target.name == 'OpenWebPbx.Server'
        temporary.chmod((previous.st_mode & 0o777) if previous else (0o755 if executable else 0o644))
        os.chown(temporary, previous.st_uid if previous else 0, previous.st_gid if previous else 0)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate the release and installed PBX without changing it.')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run as root.')
    os.umask(0o077)
    lock = Path('/run/openwebpbx-upgrade.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('Another OpenWeb PBX update is already running.') from None
    package = Path(__file__).resolve().parent
    os_release = Path('/etc/os-release').read_text()
    if not re.search(r'^ID=debian$', os_release, re.M) or not re.search(r'^VERSION_ID="?13"?$', os_release, re.M):
        parser.error('This package requires Debian 13.')
    if subprocess.check_output(['dpkg', '--print-architecture'], text=True).strip() != 'amd64':
        parser.error('This package requires amd64.')
    if not CONFIG.is_file() or not (WEB / 'resources/require.php').is_file():
        parser.error('No installed PBX was found. Use install.sh for a fresh server.')
    manifest = validate_manifest(package)
    installed_version = (WEB / 'VERSION').read_text().strip() if (WEB / 'VERSION').is_file() else ''
    if re.fullmatch(r'\d+\.\d+\.\d+', installed_version):
        if tuple(map(int, installed_version.split('.'))) > tuple(map(int, manifest['version'].split('.'))):
            raise ValueError('This package is older than the installed PBX. Use the matching private backup for recovery.')
    targets = deployment_files(package, manifest)
    settings = read_settings()
    for service in SERVICES:
        subprocess.run(['systemctl', 'is-active', '--quiet', service], check=True)
    check_idle(settings)
    if args.check:
        print(f"Release {manifest['version']} verified; {len(targets)} files ready. No changes made.")
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup = Path('/var/backups/openwebpbx') / ('upgrade-' + stamp)
    backup.mkdir(parents=True, mode=0o700)
    print(f'Preparing private backup: {backup}')
    missing = []
    for target in targets:
        if target.is_file():
            saved = backup / 'files' / target.relative_to('/')
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, saved)
        else:
            missing.append(str(target))
    (backup / 'new-files.json').write_text(json.dumps(missing))
    with tarfile.open(backup / 'private-configuration.tar.gz', 'w:gz') as output:
        for directory in ['/etc/fusionpbx', '/etc/openwebpbx', '/etc/freeswitch']:
            if Path(directory).is_dir():
                output.add(directory, arcname=directory.lstrip('/'))
    environment = os.environ | {'PGPASSWORD': settings.get('database.0.password', ''),
                                'PGSSLMODE': settings.get('database.0.sslmode', 'prefer')}
    database_args = ['-h', settings.get('database.0.host', '127.0.0.1'), '-p', settings.get('database.0.port', '5432'),
                     '-U', settings['database.0.username'], '-d', settings['database.0.name'], '-w']
    stopped = False
    with (backup / 'upgrade.log').open('w') as log:
        def run(command, **kwargs):
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, **kwargs)
        try:
            # Recheck immediately before the maintenance stop. The updater never
            # intentionally disconnects an already active call.
            check_idle(settings)
            stopped = True
            run(['systemctl', 'stop', *SERVICES])
            run(['pg_dump', *database_args, '-Fc', '-f', str(backup / 'database.dump')], env=environment)
            run(['pg_restore', '--list', str(backup / 'database.dump')])
            for target, source in targets.items():
                atomic_copy(source, target)
            run(['php', str(package / 'bootstrap.php'), str(WEB), 'migrate'], cwd=WEB)
            for step in ['--defaults', '--group', '--menu']:
                run(['php', 'core/upgrade/upgrade.php', step], cwd=WEB)
            # Native XML, provider ACL and mobile directory caches may contain the
            # prior release's generated content. Cache data is safe to regenerate.
            cache = Path(settings.get('cache.location', '/var/cache/fusionpbx'))
            if cache.is_dir() and not cache.is_symlink() and cache.resolve().is_relative_to('/var/cache'):
                for item in cache.iterdir():
                    if item.is_file() and not item.is_symlink():
                        item.unlink()
            run(['systemctl', 'start', 'freeswitch', 'php8.4-fpm', 'openwebpbx'])
            for attempt in range(30):
                try:
                    with urllib.request.urlopen('http://127.0.0.1:8087/health', timeout=3) as response:
                        health = json.load(response)
                    if health.get('state') == 'Running' and health.get('version') == manifest['version']:
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(2)
            else:
                raise RuntimeError('The updated background service did not become ready.')
            for service in SERVICES:
                run(['systemctl', 'is-active', '--quiet', service])
            (backup / 'completed.json').write_text(json.dumps({'version': manifest['version'], 'completed_at': stamp}))
        except BaseException:
            if stopped:
                subprocess.run(['systemctl', 'stop', *SERVICES], stdout=log, stderr=subprocess.STDOUT)
                for target in targets:
                    saved = backup / 'files' / target.relative_to('/')
                    if saved.is_file():
                        atomic_copy(saved, target)
                    elif str(target) in missing:
                        target.unlink(missing_ok=True)
                run(['systemctl', 'start', 'freeswitch', 'php8.4-fpm', 'openwebpbx'])
            raise RuntimeError(f'Update failed; original application files restored. Review {backup}/upgrade.log. '
                               'The database backup is retained; additive schema changes are not automatically reversed.') from None
    print(f"OpenWeb PBX {manifest['version']} is running. Configuration, accounts and media were preserved.")
    print(f'Keep the private backup at {backup} with your normal media backup.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        # SQL and service output go only to the private log, never the console.
        print(str(error) if isinstance(error, (RuntimeError, ValueError)) else 'Update could not continue; check the private log and installed services.')
        raise SystemExit(1)
