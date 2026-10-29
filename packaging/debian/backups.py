#!/usr/bin/env python3
"""Encrypted Debian instance backups. Fixed paths only; no secrets in output.

Archive v1: 8-byte magic, 16-byte PBKDF2 salt, 12-byte GCM nonce,
AES-256-GCM ciphertext, 16-byte tag. Header authenticated as AAD.
The encrypted payload is a bounded, manifest-verified gzip tar archive.
"""
import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import getpass
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import uuid

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b'OWPBXB01'
ITERATIONS = 600_000
CHUNK = 1024 * 1024
MAX_ARCHIVE = 50 * 1000 ** 3  # Keep a single GCM message below its 2^39-256-bit bound.
MAX_FILES = 500_000
CONFIG = Path('/etc/fusionpbx/config.conf')
KEY = Path('/etc/fusionpbx/openweb-template.key')
STORE = Path('/var/backups/openwebpbx/automatic')
DOWNLOADS = Path('/var/lib/openwebpbx/backup-downloads')
RESTORE = Path('/var/lib/openwebpbx/backup-restore')
WEB_VERSION = Path('/var/www/fusionpbx/VERSION')
UPGRADE_LOCK = Path('/run/openwebpbx-upgrade.lock')
UNIT_ROOT = Path('/etc/systemd/system')
CACHE = Path('/var/cache/fusionpbx')
REGISTRATION_STATE = Path('/var/lib/openwebpbx/tenant-domains')
REGISTRATION_FILES = ('image-local.json', 'image-onboarding/session.json')
HELD_UNITS = {'calls': 'freeswitch.service', 'jobs': 'openwebpbx.service',
              'updates': 'openwebpbx-updater.service', 'backups': 'openwebpbx-backups.timer',
              'mail': 'email_queue.service'}
ROOTS = {
    'fusionpbx-config': Path('/etc/fusionpbx'),
    'runtime-config': Path('/etc/openwebpbx'),
    'freeswitch-config': Path('/etc/freeswitch'),
    'mobile-notifications': Path('/var/lib/openwebpbx/mobile-notifications'),
    'mobile-push': Path('/var/lib/openwebpbx/mobile-push.json'),
    'mobile-push-settings': Path('/var/lib/openwebpbx/mobile-push-settings.json'),
    'registration-state': REGISTRATION_STATE / 'private',
}
MEDIA = {
    'storage': Path('/var/lib/freeswitch/storage'),
    'recordings': Path('/var/lib/freeswitch/recordings'),
    'custom-sounds': Path('/usr/share/freeswitch/sounds/openwebpbx'),
}
SERVICES = ('email_queue.service', 'openwebpbx-backups.timer', 'openwebpbx-updater', 'openwebpbx', 'freeswitch', 'php8.4-fpm')


class BackupError(RuntimeError):
    """Only these messages may be shown to an administrator."""


def ordinary(path):
    path = Path(path)
    for item in [path, *path.parents]:
        if item.is_symlink():
            raise BackupError('A configured backup path is a symbolic link. Use the supported standard Debian layout.')
    if not path.is_file():
        raise BackupError('A required private backup file is unavailable.')
    return path


def safe_private_directory(path, group=None):
    path = Path(path)
    for item in [path, *path.parents]:
        if item.is_symlink():
            raise BackupError('Private backup storage must not contain symbolic links.')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o750 if group is not None else 0o700)
    if os.geteuid() == 0:
        os.chown(path, 0, group if group is not None else 0)
    return path


def atomic_json(path, value):
    path = Path(path)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.backup-', mode='w', delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    temporary.chmod(0o600)
    os.replace(temporary, path)
    sync_directory(path.parent)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


@contextlib.contextmanager
def exclusive_guard(path):
    path = Path(path)
    if path.is_symlink():
        raise BackupError('The operation lock needs administrator review.')
    with path.open('a') as lock:
        lock_path_mode = path.stat().st_mode & 0o777
        if lock_path_mode & 0o022:
            path.chmod(0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BackupError('Another backup, restore or release update is running. Retry after it finishes.') from None
        yield


def read_settings(config=CONFIG):
    settings = {}
    for line in ordinary(config).read_text().splitlines():
        if '=' in line and not line.lstrip().startswith(('#', ';')):
            key, value = line.split('=', 1)
            settings[key.strip()] = value.strip().strip('"')
    if settings.get('database.0.type') != 'pgsql':
        raise BackupError('Instance backups require the built-in PostgreSQL database.')
    for key in ('database.0.name', 'database.0.username'):
        if not settings.get(key):
            raise BackupError('The built-in database configuration is incomplete.')
    return settings


def database_command(settings, executable='psql'):
    return [executable, '-h', settings.get('database.0.host', '127.0.0.1'),
            '-p', settings.get('database.0.port', '5432'), '-U', settings['database.0.username'],
            '-d', settings['database.0.name'], '-w']


def database_environment(settings):
    # Credentials never enter shell commands, arguments, logs or archived metadata.
    return os.environ | {'PGPASSWORD': settings.get('database.0.password', ''),
                         'PGSSLMODE': settings.get('database.0.sslmode', 'prefer'),
                         'PGCONNECT_TIMEOUT': '10'}


def run(command, *, env=None, timeout=7200):
    try:
        result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise BackupError('A required backup operation could not finish. Check the server tools and free disk space.') from None
    if result.returncode:
        raise BackupError('A required backup operation failed. Check the server tools, permissions and free disk space.')
    return result.stdout


def literal(value):
    if value is None:
        return 'NULL'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def query(settings, sql, *, json_result=False):
    # All callers supply application-owned SQL. DB strings are quoted with literal().
    result = run(database_command(settings) + ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', 'SET standard_conforming_strings=on;\n'+sql],
                 env=database_environment(settings), timeout=60).decode().strip()
    return json.loads(result) if json_result else result


def unseal(value, key_file=KEY):
    try:
        if not isinstance(value, str) or not value.startswith('v1:'):
            raise ValueError()
        raw = base64.b64decode(value[3:], validate=True)
        key = ordinary(key_file).read_bytes()
        if len(key) != 32 or len(raw) < 29:
            raise ValueError()
        derived = hashlib.sha256(key + b'/openwebpbx/backups/v1').digest()
        return AESGCM(derived).decrypt(raw[:12], raw[28:] + raw[12:28],
                                      b'openwebpbx-backup-settings-v1').decode()
    except Exception:
        raise BackupError('The saved backup password or SSH key cannot be read. Save it again in Backups.') from None


def password_key(password, salt):
    if not isinstance(password, str) or not 12 <= len(password) <= 256:
        raise BackupError('Enter the original backup password, with at least 12 characters.')
    return hashlib.pbkdf2_hmac('sha256', password.encode(), salt, ITERATIONS, 32)


def encrypt_file(source, destination, password):
    ordinary(source)
    salt, nonce = os.urandom(16), os.urandom(12)
    header = MAGIC + salt + nonce
    cipher = Cipher(algorithms.AES(password_key(password, salt)), modes.GCM(nonce)).encryptor()
    cipher.authenticate_additional_data(header)
    with source.open('rb') as incoming, destination.open('xb') as outgoing:
        outgoing.write(header)
        while data := incoming.read(CHUNK):
            outgoing.write(cipher.update(data))
        outgoing.write(cipher.finalize())
        outgoing.write(cipher.tag)
        outgoing.flush()
        os.fsync(outgoing.fileno())
    destination.chmod(0o600)


def decrypt_file(source, destination, password):
    ordinary(source)
    size = source.stat().st_size
    if not len(MAGIC) + 44 <= size <= MAX_ARCHIVE:
        raise BackupError('The encrypted backup has an invalid size.')
    try:
        with source.open('rb') as incoming:
            header = incoming.read(36)
            if len(header) != 36 or header[:8] != MAGIC:
                raise BackupError('This file is not a supported OpenWeb PBX backup.')
            incoming.seek(-16, os.SEEK_END)
            tag = incoming.read(16)
            incoming.seek(36)
            cipher = Cipher(algorithms.AES(password_key(password, header[8:24])),
                            modes.GCM(header[24:36], tag)).decryptor()
            cipher.authenticate_additional_data(header)
            remaining = size - 52
            with destination.open('xb') as outgoing:
                while remaining:
                    data = incoming.read(min(CHUNK, remaining))
                    if not data:
                        raise ValueError()
                    remaining -= len(data)
                    outgoing.write(cipher.update(data))
                outgoing.write(cipher.finalize())
                outgoing.flush()
                os.fsync(outgoing.fileno())
        destination.chmod(0o600)
    except BackupError:
        destination.unlink(missing_ok=True)
        raise
    except Exception:
        destination.unlink(missing_ok=True)
        raise BackupError('The backup password is wrong or the encrypted file is damaged. No restore was made.') from None


def checksum(path):
    with ordinary(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def file_inventory(roots):
    files = {}
    total = 0
    for label, root in roots.items():
        root = Path(root)
        if not root.exists():
            continue
        paths = ([root / name for name in REGISTRATION_FILES if (root / name).exists() or (root / name).is_symlink()]
                 if label == 'registration-state' else sorted(root.rglob('*')) if root.is_dir() else [root])
        for path in paths:
            if path.is_dir() and not path.is_symlink():
                continue
            ordinary(path)
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink > 1:
                raise BackupError('Backup files must be ordinary files without links.')
            if label == 'registration-state' and (info.st_uid != 0 or info.st_mode & 0o077):
                raise BackupError('Registration recovery files must remain root-private.')
            relative = path.relative_to(root).as_posix() if root.is_dir() else 'file'
            name = label + '/' + relative
            total += info.st_size
            if len(files) >= MAX_FILES or total > MAX_ARCHIVE:
                raise BackupError('This backup exceeds the supported 50 GB or 500,000-file limit.')
            files[name] = {'source': path, 'size': info.st_size, 'mtime_ns': info.st_mtime_ns,
                           'mode': stat.S_IMODE(info.st_mode), 'sha256': checksum(path)}
    return files


def validate_database_layout(settings):
    info = query(settings, """select json_build_object(
      'database',current_database(),'user',current_user,
      'version',current_setting('server_version_num')::integer,
      'schemas',(select coalesce(json_agg(nspname),'[]') from pg_namespace where nspname<>'information_schema' and nspname !~ '^pg_'),
      'extensions',(select coalesce(json_agg(extname),'[]') from pg_extension where extname<>'plpgsql'),
      'large_objects',(select count(*) from pg_largeobject_metadata))""", json_result=True)
    if info['schemas'] != ['public'] or info['extensions'] or info['large_objects']:
        raise BackupError('This backup tool supports the standard application database. Custom schemas, extensions or large objects need an administrator-managed backup.')
    return info


def snapshot_database(settings, destination):
    run(database_command(settings, 'pg_dump') + ['--format=custom', '--no-owner', '--no-acl',
                                                '--serializable-deferrable', '--file', str(destination)],
        env=database_environment(settings))
    destination.chmod(0o600)
    run(['pg_restore', '--list', str(destination)], timeout=60)


@contextlib.contextmanager
def registration_guard(roots):
    root = roots.get('registration-state')
    if root is not None and any(part.is_symlink() for part in [Path(root), *Path(root).parents]):
        raise BackupError('Linked registration recovery directory refused.')
    directory = Path(root) / 'image-onboarding' if root is not None else None
    if directory is None or not directory.exists():
        yield
        return
    if any(part.is_symlink() for part in [directory, *directory.parents]):
        raise BackupError('Linked registration recovery directory refused.')
    info = directory.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise BackupError('The registration recovery directory must remain root-private.')
    lock = directory / 'worker.lock'
    if lock.exists() or lock.is_symlink():ordinary(lock)
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != 0 or info.st_mode & 0o077:
            raise BackupError('The registration recovery lock needs administrator review.')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BackupError('Server registration is being refreshed. Retry the backup shortly.') from None
        yield
    finally:
        os.close(descriptor)


def create_archive(settings, destination, password, *, include_media=True, roots=None, version=None):
    selected = roots if roots is not None else ROOTS | (MEDIA if include_media else {})
    with registration_guard(selected):
        return _create_archive(settings, destination, password, include_media=include_media, roots=roots, version=version)


def _create_archive(settings, destination, password, *, include_media=True, roots=None, version=None):
    if roots is None:
        standard = {'switch.conf.dir': '/etc/freeswitch', 'switch.storage.dir': '/var/lib/freeswitch/storage',
                    'switch.voicemail.dir': '/var/lib/freeswitch/storage/voicemail',
                    'switch.recordings.dir': '/var/lib/freeswitch/recordings'}
        if any(settings.get(key, path).rstrip('/') != path for key, path in standard.items()):
            raise BackupError('This instance uses nonstandard private-data paths. Use an administrator-managed backup rather than omitting its data.')
    roots = roots if roots is not None else ROOTS | (MEDIA if include_media else {})
    if version is None:
        version = ordinary(WEB_VERSION).read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise BackupError('The installed application version is unavailable.')
    layout = validate_database_layout(settings)
    with tempfile.TemporaryDirectory(prefix='.backup-work-', dir=destination.parent) as temporary:
        work = Path(temporary)
        work.chmod(0o700)
        dump = work / 'database.dump'
        snapshot_database(settings, dump)
        files = file_inventory(roots)
        files['database.dump'] = {'source': dump, 'size': dump.stat().st_size, 'mtime_ns': dump.stat().st_mtime_ns,
                                  'mode': 0o600, 'sha256': checksum(dump)}
        manifest = {'schema': 1, 'platform': 'debian13', 'version': version,
                    'created_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'include_media': include_media,
                    'source_host': settings.get('openweb.public_host', ''), 'database': layout,
                    'files': {name: {key: data[key] for key in ('size', 'mode', 'sha256')} for name, data in files.items()}}
        packed = work / 'payload.tar.gz'
        with tarfile.open(packed, 'w:gz', format=tarfile.PAX_FORMAT) as archive:
            data = json.dumps(manifest, sort_keys=True).encode()
            member = tarfile.TarInfo('manifest.json')
            member.size, member.mode = len(data), 0o600
            archive.addfile(member, io.BytesIO(data))
            for name, entry in files.items():
                path = ordinary(entry['source'])
                before = path.stat()
                if before.st_size != entry['size'] or before.st_mtime_ns != entry['mtime_ns']:
                    raise BackupError('A private file changed during the backup. No completed copy was published. Retry at a quiet time.')
                member = tarfile.TarInfo(name)
                member.size, member.mode = entry['size'], 0o600
                with path.open('rb') as stream:
                    archive.addfile(member, stream)
                after = path.stat()
                if (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns) or checksum(path) != entry['sha256']:
                    raise BackupError('A private file changed during the backup. No completed copy was published. Retry at a quiet time.')
        encrypt_file(packed, destination, password)
        # Authenticate and validate the exact copy before calling it completed.
        with verify_archive(destination, password) as (_, verified):
            if verified['files'] != manifest['files']:
                raise BackupError('Backup verification did not match the original inventory.')
    return manifest


def safe_member(name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '.' in path.parts or '\\' in name or not name or str(path) != name:
        raise BackupError('The backup contains an unsafe file name.')
    if name != 'database.dump':
        if len(path.parts) < 2 or path.parts[0] not in ROOTS | MEDIA:
            raise BackupError('The backup contains an unknown private-data location.')
        if path.parts[0] in ('mobile-push', 'mobile-push-settings') and name != path.parts[0] + '/file':
            raise BackupError('The backup contains an unknown private-data location.')
        if path.parts[0] == 'mobile-notifications' and name not in ('mobile-notifications/config.json', 'mobile-notifications/config.json.lock'):
            raise BackupError('The backup contains an unknown private-data location.')
        if path.parts[0] == 'registration-state' and name not in tuple('registration-state/' + item for item in REGISTRATION_FILES):
            raise BackupError('The backup contains an unknown registration recovery file.')
    return path


def extract_verified(payload, destination):
    with tarfile.open(payload, 'r:gz') as archive:
        first = archive.next()
        if first is None or first.name != 'manifest.json' or not first.isfile() or not 1 <= first.size <= 32 * 1024 ** 2:
            raise BackupError('The backup inventory is missing or too large.')
        manifest = json.load(archive.extractfile(first))
        if manifest.get('schema') != 1 or manifest.get('platform') != 'debian13' or not re.fullmatch(r'\d+\.\d+\.\d+', str(manifest.get('version', ''))):
            raise BackupError('The backup version or platform is unsupported.')
        files = manifest.get('files')
        if not isinstance(files, dict) or not 1 <= len(files) <= MAX_FILES or 'database.dump' not in files:
            raise BackupError('The backup inventory is incomplete.')
        expected_total = 0
        for name, entry in files.items():
            safe_member(name)
            if not isinstance(entry, dict) or not isinstance(entry.get('size'), int) or not 0 <= entry['size'] <= MAX_ARCHIVE or not re.fullmatch('[a-f0-9]{64}', str(entry.get('sha256', ''))):
                raise BackupError('The backup inventory is invalid.')
            if not isinstance(entry.get('mode'), int) or not 0 <= entry['mode'] <= 0o777:
                raise BackupError('The backup permissions are invalid.')
            expected_total += entry['size']
        if expected_total > MAX_ARCHIVE:
            raise BackupError('The expanded backup exceeds the supported 50 GB limit.')
        seen = set()
        while member := archive.next():
            if member.name == 'manifest.json':
                raise BackupError('The backup contains duplicate files.')
            relative = safe_member(member.name)
            entry = files.get(member.name)
            if member.name in seen or not member.isfile() or entry is None or member.size != entry['size'] or member.sparse:
                raise BackupError('The backup has duplicate, linked, unlisted or damaged files.')
            seen.add(member.name)
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with archive.extractfile(member) as incoming, target.open('xb') as outgoing:
                shutil.copyfileobj(incoming, outgoing, CHUNK)
            target.chmod(0o600)
            if checksum(target) != entry['sha256']:
                raise BackupError('A private backup file failed its integrity check.')
        if seen != set(files):
            raise BackupError('The backup is missing files listed in its inventory.')
        run(['pg_restore', '--list', str(destination / 'database.dump')], timeout=60)
        return manifest


@contextlib.contextmanager
def verify_archive(source, password, *, workspace=None):
    ordinary(source)
    with tempfile.TemporaryDirectory(prefix='.verify-backup-', dir=workspace or source.parent) as temporary:
        work = Path(temporary)
        work.chmod(0o700)
        payload = work / 'payload.tar.gz'
        decrypt_file(source, payload, password)
        extracted = work / 'extracted'
        extracted.mkdir(mode=0o700)
        try:
            manifest = extract_verified(payload, extracted)
        except BackupError:
            raise
        except Exception:
            raise BackupError('The backup archive or inventory is damaged. No restore was made.') from None
        yield extracted, manifest


def validate_remote(config):
    host, user, directory = (config.get(key, '') for key in ('sftp_host', 'sftp_user', 'sftp_directory'))
    port = config.get('sftp_port', 22)
    host_key = config.get('sftp_host_key', '')
    if (not isinstance(host, str) or not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?', host)
            or not isinstance(user, str) or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}', user)
            or not isinstance(directory, str) or not re.fullmatch(r'(/[a-zA-Z0-9_.-]+)+/?', directory)
            or any(part in ('.', '..') for part in directory.split('/'))
            or not isinstance(port, int) or not 1 <= port <= 65535
            or not isinstance(host_key, str) or not re.fullmatch(r'(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/]+={0,2}', host_key)):
        raise BackupError('The SFTP settings are invalid. Save the connection again.')
    return host, port, user, directory.rstrip('/'), host_key


def upload_sftp(source, config, identity, *, workspace=None):
    ordinary(source)
    if not re.fullmatch('[0-9a-f-]{36}[.]owpbx', source.name):
        raise BackupError('The remote backup file name is invalid.')
    host, port, user, directory, host_key = validate_remote(config)
    with tempfile.TemporaryDirectory(prefix='.sftp-backup-', dir=workspace or source.parent) as temporary:
        work = Path(temporary)
        work.chmod(0o700)
        key = work / 'identity'
        key.write_text(identity)
        key.chmod(0o600)
        # Validate a usable, unencrypted identity before connecting. Never output it.
        run(['ssh-keygen', '-y', '-P', '', '-f', str(key)], timeout=20)
        known = work / 'known_hosts'
        known.write_text((host if port == 22 else f'[{host}]:{port}') + ' ' + host_key + '\n')
        known.chmod(0o600)
        temporary_name = directory + '/.' + source.name + '.uploading'
        final_name = directory + '/' + source.name
        batch = work / 'batch'
        # Paths have restricted characters; local generated path is quoted/escaped.
        escaped = str(source.resolve()).replace('\\', '\\\\').replace('"', '\\"')
        batch.write_text(f'put "{escaped}" "{temporary_name}"\nrename "{temporary_name}" "{final_name}"\n')
        batch.chmod(0o600)
        run(['sftp', '-F', '/dev/null', '-oBatchMode=yes', '-oIdentitiesOnly=yes', '-oStrictHostKeyChecking=yes',
             '-oUserKnownHostsFile=' + str(known), '-oGlobalKnownHostsFile=/dev/null',
             '-oIdentityFile=' + str(key), '-oConnectTimeout=15', '-oConnectionAttempts=1',
             '-P', str(port), '-b', str(batch), user + '@' + host], timeout=7200)


def publish_download(source, destination):
    ordinary(source)
    destination = Path(destination)
    destination.unlink(missing_ok=True)
    try:
        os.link(source, destination)
    except OSError:
        shutil.copyfile(source, destination)
    destination.chmod(0o640)
    if os.geteuid() == 0:
        os.chown(destination, 0, 33)
    sync_directory(destination.parent)


def set_status(settings, state, message):
    query(settings, 'update v_pbx_backup_status set state=' + literal(state) + ',message=' + literal(message) + ',updated_at=now() where singleton=1')


def prune_backups(settings, retention, *, store=STORE, downloads=DOWNLOADS):
    if not isinstance(retention, int) or not 2 <= retention <= 90:
        raise BackupError('The backup retention setting is invalid.')
    keep = query(settings, "select coalesce(json_agg(t),'[]') from (select backup_uuid,filename,size_bytes,sha256 from v_pbx_backups where status='ready' order by completed_at desc,backup_uuid desc limit " + str(retention) + ') t', json_result=True)
    for row in keep:
        name = str(uuid.UUID(row['backup_uuid']))+'.owpbx'
        file = Path(store)/name
        if row['filename'] != name or ordinary(file).stat().st_size != row['size_bytes'] or checksum(file) != row['sha256']:
            raise BackupError('A retained local backup is missing or damaged. Older copies were kept; review backup storage before cleanup.')
    rows = query(settings, "select coalesce(json_agg(t),'[]') from (select backup_uuid,filename from v_pbx_backups where status='ready' order by completed_at desc,backup_uuid desc offset " + str(retention) + ') t', json_result=True)
    for row in rows:
        name = str(uuid.UUID(row['backup_uuid'])) + '.owpbx'
        if row['filename'] != name:
            raise BackupError('An old backup inventory needs administrator review.')
        for folder in (Path(store), Path(downloads)):
            file = folder / name
            if file.is_symlink():
                raise BackupError('An old backup path is a symbolic link. Retention was stopped.')
            file.unlink(missing_ok=True)
        query(settings, 'delete from v_pbx_backups where backup_uuid=' + literal(row['backup_uuid']) + "::uuid and status='ready'")


def worker(settings, **kwargs):
    with exclusive_guard(UPGRADE_LOCK):
        return _worker(settings, **kwargs)


def _worker(settings, *, store=STORE, downloads=DOWNLOADS, roots=None, version=None, key_file=KEY):
    store = safe_private_directory(store)
    downloads = safe_private_directory(downloads, group=33)
    with (store / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        # A killed worker cannot hold this exclusive lock. Mark its request as failed.
        query(settings, "update v_pbx_backup_commands set status='failed',message='The backup service stopped before completion. Retry this request.',finished_at=now() where status='running'")
        query(settings, "update v_pbx_backups set status='failed',message='The backup service stopped before completion.' where status='creating'")
        for directory in store.glob('.backup-work-*'):
            if not directory.is_symlink() and directory.is_dir():
                shutil.rmtree(directory)
        for directory in store.glob('.verify-backup-*'):
            if not directory.is_symlink() and directory.is_dir():
                shutil.rmtree(directory)
        config = query(settings, 'select row_to_json(t) from v_pbx_backup_settings t where singleton=1', json_result=True)
        if config['enabled'] and config['passphrase_secret']:
            # One scheduled request per UTC day, caught up after downtime.
            query(settings, """with scheduled as (update v_pbx_backup_settings set last_scheduled_date=(now() at time zone 'UTC')::date
                where singleton=1 and enabled and extract(hour from now() at time zone 'UTC')>=schedule_hour
                and (last_scheduled_date is null or last_scheduled_date<(now() at time zone 'UTC')::date)
                and not exists(select 1 from v_pbx_backup_commands where status in ('pending','running')) returning 1)
                insert into v_pbx_backup_commands(command_uuid,action) select gen_random_uuid(),'create' from scheduled""")
        command = query(settings, """with next as (select command_uuid from v_pbx_backup_commands where status='pending' order by created_at limit 1 for update skip locked)
            update v_pbx_backup_commands c set status='running',started_at=now(),message='Backup request is running.' from next
            where c.command_uuid=next.command_uuid returning row_to_json(c)""", json_result=False)
        if not command:
            set_status(settings, 'ready', 'Backup service is ready.')
            return
        command = json.loads(command)
        command_id = str(uuid.UUID(command['command_uuid']))
        file = None
        backup_id = None
        try:
            password = unseal(config['passphrase_secret'], key_file)
            if command['action'] == 'create':
                set_status(settings, 'creating', 'Creating and checking an encrypted backup.')
                backup_id = str(uuid.uuid4())
                file = store / (backup_id + '.owpbx')
                installed = version or ordinary(WEB_VERSION).read_text().strip()
                query(settings, 'insert into v_pbx_backups(backup_uuid,command_uuid,filename,status,include_media,app_version,remote_status) values('
                      + ','.join(literal(v) for v in (backup_id, command_id, file.name, 'creating', config['include_media'], installed, 'pending' if config['sftp_enabled'] else 'disabled')) + ')')
                manifest = create_archive(settings, file, password, include_media=config['include_media'], roots=roots, version=installed)
                digest = checksum(file)
                publish_download(file, downloads / file.name)
                query(settings, "update v_pbx_backups set status='ready',size_bytes=" + str(file.stat().st_size) + ',sha256=' + literal(digest)
                      + ",completed_at=now(),verified_at=now(),message='Encrypted local backup completed and checked.' where backup_uuid=" + literal(backup_id))
                if config['sftp_enabled']:
                    set_status(settings, 'sending', 'Local backup completed. Sending the additional remote copy.')
                    try:
                        upload_sftp(file, config, unseal(config['sftp_identity_secret'], key_file))
                        query(settings, "update v_pbx_backups set remote_status='uploaded' where backup_uuid=" + literal(backup_id))
                    except BackupError:
                        query(settings, "update v_pbx_backups set remote_status='failed',message='Local backup is safe. The SFTP copy failed; check connection, trusted host key, account key and folder.' where backup_uuid=" + literal(backup_id))
                prune_backups(settings, int(config['retention']), store=store, downloads=downloads)
                message = 'Encrypted local backup completed and checked.'
                if config['sftp_enabled']:
                    remote_state = query(settings, 'select remote_status from v_pbx_backups where backup_uuid=' + literal(backup_id))
                    message = 'Local and SFTP backups completed.' if remote_state == 'uploaded' else 'Local backup completed. The SFTP copy failed; see this backup’s status.'
            elif command['action'] == 'verify':
                backup_id = str(uuid.UUID(command['backup_uuid']))
                row = query(settings, 'select row_to_json(t) from v_pbx_backups t where backup_uuid=' + literal(backup_id), json_result=True)
                if not row or row['status'] != 'ready' or row['filename'] != backup_id + '.owpbx':
                    raise BackupError('This backup is unavailable.')
                file = store / row['filename']
                set_status(settings, 'checking', 'Checking the encrypted backup and every private file.')
                if checksum(file) != row['sha256']:
                    raise BackupError('The encrypted backup checksum has changed. Keep another copy and investigate storage.')
                with verify_archive(file, password):
                    pass
                query(settings, "update v_pbx_backups set verified_at=now(),message='Every encrypted backup file passed its integrity check.' where backup_uuid=" + literal(backup_id))
                message = 'Every encrypted backup file passed its integrity check.'
            else:
                raise BackupError('Unsupported backup request.')
            query(settings, "update v_pbx_backup_commands set status='completed',message=" + literal(message) + ',finished_at=now() where command_uuid=' + literal(command_id))
            set_status(settings, 'ready', message)
        except Exception as error:
            message = str(error) if isinstance(error, BackupError) else 'The backup could not finish. Check private storage, database access and installed backup tools.'
            if backup_id and command['action'] == 'create':
                row_state = query(settings, 'select status from v_pbx_backups where backup_uuid=' + literal(backup_id))
                if row_state != 'ready':
                    if file:
                        file.unlink(missing_ok=True)
                        (downloads / file.name).unlink(missing_ok=True)
                    query(settings, "update v_pbx_backups set status='failed',message=" + literal(message) + ' where backup_uuid=' + literal(backup_id))
            query(settings, "update v_pbx_backup_commands set status='failed',message=" + literal(message) + ',finished_at=now() where command_uuid=' + literal(command_id))
            set_status(settings, 'failed', message)


def target_is_factory(settings):
    if settings.get('database.0.host', '127.0.0.1') not in ('127.0.0.1', 'localhost', '::1', '/var/run/postgresql'):
        raise BackupError('Restore requires the replacement instance’s own local PostgreSQL database.')
    validate_database_layout(settings)
    tables = {'v_extensions': 0, 'v_pbx_tenants': 0, 'v_pbx_services': 0, 'v_pbx_restore': 0,
              'v_recordings': 0, 'v_voicemail_messages': 0, 'v_pbx_meetings': 0,
              'v_pbx_meeting_members': 0, 'v_users': 1, 'v_domains': 1}
    for table, maximum in tables.items():
        exists = query(settings, 'select to_regclass(' + literal(table) + ') is not null')
        if exists == 't' and int(query(settings, 'select count(*) from ' + table)) > maximum:
            raise BackupError('Restore refused an installation containing users, phones, tenants or customer media. Use a separate fresh installation.')


def restore_database(settings, dump, workspace):
    sql = workspace / 'restore.sql'
    run(['pg_restore', '--no-owner', '--no-acl', '--file', str(sql), str(ordinary(dump))])
    sql.chmod(0o600)
    reset = workspace / 'reset.sql'
    reset.write_text('DROP SCHEMA public CASCADE;\n')
    reset.chmod(0o600)
    listing = run(['pg_restore', '--list', str(dump)]).decode()
    # A TOC entry for the default public schema may contain only its comment,
    # without CREATE SCHEMA. Inspect that entry's SQL, rather than its presence.
    schema_list = workspace / 'schema.list'
    schema_sql = workspace / 'schema.sql'
    schema_list.write_text('\n'.join(line for line in listing.splitlines() if re.search(r' SCHEMA - public ', line))+'\n')
    schema_list.chmod(0o600)
    run(['pg_restore', '--no-owner', '--no-acl', '--use-list', str(schema_list), '--file', str(schema_sql), str(dump)])
    schema_sql.chmod(0o600)
    if not re.search(r'^CREATE SCHEMA (?:public|"public");', schema_sql.read_text(), re.MULTILINE):
        with reset.open('a') as stream:
            stream.write('CREATE SCHEMA public;\n')
    run(database_command(settings) + ['-X', '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', str(reset), '-f', str(sql)],
        env=database_environment(settings))
    sql.unlink(missing_ok=True)
    reset.unlink(missing_ok=True)
    schema_list.unlink(missing_ok=True)
    schema_sql.unlink(missing_ok=True)


def apply_voicemail_policy(settings):
    # Successful imports may come from a pre-policy backup. Do not apply this
    # transform during exact factory/disaster recovery of the target itself.
    policy = ordinary(WEB_VERSION.parent / 'app/voicemails/resources/voicemail_without_pins.sql')
    query(settings, policy.read_text(encoding='utf-8'))


def meeting_transport_files(manifest):
    pair={'runtime-config/meet-ca.pem','freeswitch-config/tls/openweb-meet/wss.pem'}
    present=pair.intersection(manifest['files'])
    if present and present!=pair:
        raise BackupError('The backup is missing part of its private meeting connection.')
    return bool(present)


def restore_meeting(settings):
    # Older backups need no Meet schema transform. A source with a meeting
    # profile must carry its complete private TLS identity; never rotate keys
    # silently or revive the source machine's public media IP.
    if query(settings,"select to_regclass('public.v_sip_profiles') is not null")!='t':return False
    if query(settings,"select count(*) from v_sip_profiles where sip_profile_uuid='cfb1c835-c30c-409b-bff7-a893a7e84df1' or sip_profile_name='openweb-meet'")=='0':return False
    conf=ROOTS['freeswitch-config'];state=ROOTS['runtime-config']
    ordinary(conf/'tls/openweb-meet/wss.pem');ordinary(state/'meet-ca.pem')
    code=r"""require $argv[1].'/resources/classes/config.php';config::load($argv[2]);require $argv[1].'/resources/classes/auto_loader.php';new auto_loader();$db=database::new()->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
if((string)config::load()->get('switch.conf.dir')!==$argv[3])throw new RuntimeException('The restored engine configuration path needs review.');
pbx_meet_install::tls($argv[3],$argv[4]);
$db->beginTransaction();try{
 pbx_meet_install::rebind($db,null,$argv[3]);pbx_video::configure($db);
 if($db->query("select to_regclass('v_pbx_meeting_members') is not null")->fetchColumn()){
  $rows=$db->query("select member_uuid from v_pbx_meeting_members where state in ('waiting','admitted') or call_uuid is not null for update")->fetchAll(PDO::FETCH_COLUMN);
  $q=$db->prepare("update v_pbx_meeting_members set state=case when state in ('waiting','admitted') then 'left' else state end,call_uuid=null,token_hash=?,sip_a1_hash=? where member_uuid=?");
  foreach($rows as$id)$q->execute([hash('sha256',random_bytes(32)),bin2hex(random_bytes(16)),$id]);
 }
 $db->commit();
}catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw $e;}"""
    run(['php','-r',code,str(WEB_VERSION.parent),str(ROOTS['fusionpbx-config']/'config.conf'),str(conf),str(state)],timeout=120)
    return True


def reload_meeting_proxy():
    # Source CA files replace the clean target pin. Nginx must read that pin
    # again before activation; exact factory recovery must reread its old pin.
    helper=ordinary(Path(__file__).with_name('install-meet.py'))
    spec=importlib.util.spec_from_file_location('backup_meeting_proxy',helper)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    try:module.reload_proxy()
    except (OSError,ValueError,subprocess.SubprocessError):
        raise BackupError('The restored meeting web connection could not be loaded. Recovery is required.') from None


def restore_targets(manifest):
    mapping = {}
    roots = ROOTS | MEDIA
    for name in manifest['files']:
        if name == 'database.dump':
            continue
        relative = safe_member(name)
        label = relative.parts[0]
        root = roots[label]
        target = root if label.startswith('mobile-push') else root / PurePosixPath(*relative.parts[1:])
        for item in [target, *target.parents]:
            if item.is_symlink():
                raise BackupError('Restore refused a symbolic link in the target private-data path.')
        mapping[name] = target
    return mapping


def registration_restore_files():
    """Fixed machine-local caches; authority/key material is restored separately."""
    private = ROOTS.get('registration-state')
    if private is None:return ()
    root = Path(private).parent
    return tuple(root / name for name in (
        'instance-public.json', 'ready.json', 'setup.json',
        'private/image-local.json', 'private/certificate-backoff.json',
        'private/image-onboarding/session.json', 'private/image-onboarding/setup.txt',
        'private/image-onboarding/retry.json'))


def notification_directory(directory, *, create=False):
    spec = importlib.util.spec_from_file_location('backup_notification_storage', Path(__file__).with_name('install-mobile-notifications.py'))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    try:
        (helper.ensure_directory if create else helper.validate_directory)(directory)
    except ValueError as error:
        raise BackupError(str(error)) from None


def atomic_copy(source, target, mode=0o640, group=33):
    notification = target.parent == ROOTS.get('mobile-notifications')
    legacy_push = target in (ROOTS.get('mobile-push'), ROOTS.get('mobile-push-settings'))
    owner = 33 if notification or legacy_push or str(target).startswith(('/var/lib/freeswitch/', '/etc/freeswitch/', '/usr/share/freeswitch/')) else 0
    if notification:
        notification_directory(target.parent, create=True)
    absent = []
    directory = target.parent
    while not directory.exists():
        absent.append(directory)
        directory = directory.parent
    for directory in reversed(absent):
        directory.mkdir(mode=0o750)
        if os.geteuid() == 0:
            os.chown(directory, owner, group)
    with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.backup-restore-', delete=False) as stream:
        temporary = Path(stream.name)
        try:
            with source.open('rb') as incoming:
                shutil.copyfileobj(incoming, stream, CHUNK)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    temporary.chmod(mode)
    if os.geteuid() == 0:
        os.chown(temporary, owner, group)
    os.replace(temporary, target)
    sync_directory(target.parent)


def preserve_target_database(settings, config_file, runtime_file):
    config = read_settings(config_file)
    for key in list(config):
        if key.startswith('database.0.'):
            del config[key]
    config.update({key: value for key, value in settings.items() if key.startswith('database.0.')})
    # Keep the replacement machine's media address; the public hostname still
    # must match the source under the existing same-host restore guard.
    config.pop('openweb.public_ip', None)
    if 'openweb.public_ip' in settings:
        config['openweb.public_ip'] = settings['openweb.public_ip']
    config_file.write_text('\n'.join(key + ' = ' + value for key, value in config.items()) + '\n')
    runtime = json.loads(ordinary(runtime_file).read_text())
    # Npgsql quoting follows its connection-string builder syntax, including semicolons in passwords.
    def quote(value):
        return '"' + str(value).replace('"', '""') + '"'
    fields = [('Host', settings.get('database.0.host', '127.0.0.1')), ('Port', settings.get('database.0.port', '5432')),
              ('Database', settings['database.0.name']), ('Username', settings['database.0.username']),
              ('Password', settings.get('database.0.password', '')), ('SSL Mode', settings.get('database.0.sslmode', 'Prefer'))]
    runtime.setdefault('ConnectionStrings', {})['Pbx'] = ';'.join(key + '=' + quote(value) for key, value in fields)
    runtime_file.write_text(json.dumps(runtime))


def running_services():
    return [service for service in SERVICES if subprocess.run(['systemctl', 'is-active', '--quiet', service],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0]


def plan_service_holds():
    gates = {}
    for unit in HELD_UNITS.values():
        if (UNIT_ROOT / unit).is_file():
            dropin = UNIT_ROOT / (unit+'.d') / '99-openwebpbx-restore.conf'
            if dropin.is_symlink() or dropin.parent.is_symlink():
                raise BackupError('An existing restore service gate needs administrator review.')
            gates[unit] = dropin.read_text() if dropin.is_file() else None
    return gates


def install_service_holds(gates):
    for unit in gates:
        if unit not in HELD_UNITS.values():
            raise BackupError('Restore service inventory is invalid.')
        marker = RESTORE / ('hold-'+unit)
        marker.write_text('Restore awaits the instance administrator activation checklist.\n')
        marker.chmod(0o600)
        dropin = UNIT_ROOT / (unit+'.d') / '99-openwebpbx-restore.conf'
        dropin.parent.mkdir(mode=0o755, exist_ok=True)
        dropin.write_text('[Unit]\nConditionPathExists=!'+str(marker)+'\n')
        dropin.chmod(0o644)
    if gates:
        run(['systemctl', 'daemon-reload'], timeout=60)


def remove_service_holds(gates):
    for unit, previous in gates.items():
        if unit not in HELD_UNITS.values() or (previous is not None and not isinstance(previous, str)):
            raise BackupError('Recovery service gate inventory is invalid.')
        dropin = UNIT_ROOT / (unit+'.d') / '99-openwebpbx-restore.conf'
        if dropin.is_symlink() or dropin.parent.is_symlink():
            raise BackupError('Recovery refused a symbolic link in its service gates.')
        if previous is None:
            dropin.unlink(missing_ok=True)
        else:
            dropin.write_text(previous)
            dropin.chmod(0o644)
        (RESTORE / ('hold-'+unit)).unlink(missing_ok=True)
    if gates:
        run(['systemctl', 'daemon-reload'], timeout=60)


def restore(source, password, settings, **kwargs):
    safe_private_directory(STORE)
    with exclusive_guard(UPGRADE_LOCK), exclusive_guard(STORE/'worker.lock'), registration_guard(ROOTS):
        return _restore(source, password, settings, **kwargs)


def _restore(source, password, settings, *, dry_run=False, confirm_database=None):
    safe_private_directory(RESTORE)
    with verify_archive(source, password, workspace=RESTORE) as (extracted, manifest):
        installed = ordinary(WEB_VERSION).read_text().strip()
        if manifest['version'] != installed:
            raise BackupError('Install the same application release as this backup before restoring.')
        if manifest['source_host'] != settings.get('openweb.public_host', ''):
            raise BackupError('Install the replacement server with the original public server name before restoring.')
        if manifest['database']['version'] // 10000 > int(query(settings, "show server_version_num")) // 10000:
            raise BackupError('The target PostgreSQL version is older than the backup source.')
        required = {'fusionpbx-config/config.conf', 'fusionpbx-config/openweb-template.key', 'runtime-config/runtime.json'}
        if not required.issubset(manifest['files']):
            raise BackupError('The backup is missing configuration or encryption keys needed for a full restore.')
        if len((extracted / 'fusionpbx-config/openweb-template.key').read_bytes()) != 32:
            raise BackupError('The source private encryption key has an invalid size.')
        preserve_target_database(settings, extracted / 'fusionpbx-config/config.conf', extracted / 'runtime-config/runtime.json')
        meeting_proxy = meeting_transport_files(manifest)
        mapping = restore_targets(manifest)
        notification_root = ROOTS.get('mobile-notifications')
        notification_fallback = None
        if notification_root is not None:
            notification_directory(notification_root)
            if 'mobile-push/file' in mapping and 'mobile-notifications/config.json' not in mapping:
                notification_fallback = notification_root / 'config.json'
                for item in [notification_fallback, *notification_fallback.parents]:
                    if item.is_symlink():
                        raise BackupError('Restore refused a symbolic link in the target private-data path.')
        target_is_factory(settings)
        if dry_run:
            return manifest
        if confirm_database != settings['database.0.name']:
            raise BackupError('Confirm the fresh target database name before performing a restore.')
        if (RESTORE / 'journal.json').exists():
            raise BackupError('A previous restore journal exists. Complete recovery before starting another restore.')
        if int(query(settings, "select count(*) from v_pbx_update_commands where status='running'")):
            raise BackupError('An application update is running. Finish it before restoring.')
        services = running_services()
        # Create durable recovery material before stopping any service or changing a file.
        snapshot_database(settings, RESTORE / 'factory.dump')
        recovery_files = RESTORE / 'factory-files'
        recovery_files.mkdir(mode=0o700)
        original = {}
        registration_files = registration_restore_files()
        recovery_targets = list(dict.fromkeys(list(mapping.values()) +
            ([notification_fallback] if notification_fallback is not None else []) + list(registration_files)))
        for index, target in enumerate(recovery_targets):
            if any(part.is_symlink() for part in [target, *target.parents]):
                raise BackupError('Restore refused a linked target recovery path.')
            if target.exists() and not target.is_file():
                raise BackupError('Restore refused a nonordinary target private-data file.')
            original[str(target)] = {'exists': target.is_file()}
            if target.is_file():
                ordinary(target)
                st = target.stat()
                copy = recovery_files / str(index)
                shutil.copyfile(target, copy)
                copy.chmod(0o600)
                original[str(target)].update({'copy': str(index), 'mode': stat.S_IMODE(st.st_mode), 'uid': st.st_uid, 'gid': st.st_gid})
        journal = {'schema': 1, 'database': settings['database.0.name'], 'user': settings['database.0.username'],
                   'services': services, 'gates': plan_service_holds(), 'source_host': manifest['source_host'],
                   'registration_files': [str(path) for path in registration_files],
                   'files': original, 'meeting_proxy': meeting_proxy, 'state': 'prepared'}
        atomic_json(RESTORE / 'journal.json', journal)
        try:
            install_service_holds(journal['gates'])
            for service in services:
                run(['systemctl', 'stop', service], timeout=60)
            journal['state'] = 'restoring'
            atomic_json(RESTORE / 'journal.json', journal)
            restore_database(settings, extracted / 'database.dump', RESTORE)
            # A replacement machine's pairing session and readiness must never
            # authenticate the restored customer identities. Only the original
            # encrypted source session is restored below; proof/readiness are
            # rebuilt by the root worker after explicit service activation.
            for path in registration_files:path.unlink(missing_ok=True)
            for name, target in mapping.items():
                mode = manifest['files'][name]['mode'] & 0o750
                if name.endswith(('config.conf', '.key', 'runtime.json')) or name.startswith('mobile-push'):
                    mode = 0o640
                if name.startswith(('mobile-push', 'mobile-notifications/')):
                    mode = 0o600
                if name.startswith('registration-state/'):
                    mode = 0o600
                atomic_copy(extracted / name, target, mode=mode or 0o640,
                            group=0 if name.startswith('registration-state/') else 33)
            if notification_fallback is not None:
                # Older archive labels keep their original copy and also seed
                # the current PHP/C# location with the identical VAPID bytes.
                atomic_copy(extracted / 'mobile-push/file', notification_fallback, mode=0o600)
            apply_voicemail_policy(settings)
            restore_meeting(settings)
            if meeting_proxy:
                reload_meeting_proxy()
            # Invalid source SIP contacts and XML caches must never survive a clean restore.
            cache = CACHE
            if cache.is_dir() and not cache.is_symlink():
                for child in cache.iterdir():
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child)
                    else:
                        child.unlink()
            query(settings, "update v_pbx_backup_commands set status='failed',message='Request belonged to the previous server. Retry on this server.',finished_at=now() where status in ('pending','running')")
            query(settings, "update v_pbx_backups set status='failed',message='Previous server: this encrypted backup file was not included in the restore. Keep its separately downloaded or remote copy.' where status in ('ready','creating')")
            query(settings, "update v_pbx_backup_settings set enabled=false,sftp_enabled=false where singleton=1")
            if 'php8.4-fpm' in services:
                run(['systemctl', 'start', 'php8.4-fpm'], timeout=60)
            journal['state'] = 'restored'
            atomic_json(RESTORE / 'journal.json', journal)
            # Call/job/updater services remain stopped: source trunks must not steal registrations.
            return manifest
        except BaseException:
            _recover(settings)
            raise


def recover(settings):
    safe_private_directory(STORE)
    with exclusive_guard(UPGRADE_LOCK), exclusive_guard(STORE/'worker.lock'), registration_guard(ROOTS):
        return _recover(settings)


def _recover(settings):
    journal_file = ordinary(RESTORE / 'journal.json')
    journal = json.loads(journal_file.read_text())
    if journal.get('schema') != 1 or journal.get('database') != settings['database.0.name'] or journal.get('user') != settings['database.0.username']:
        raise BackupError('Recovery refused a different target database identity.')
    if journal.get('state') == 'restored':
        raise BackupError('The restore completed. Use the activation checklist; recovery must not overwrite it.')
    if any(service not in SERVICES for service in journal.get('services', [])):
        raise BackupError('Recovery service inventory is invalid.')
    mapping = journal.get('files', {})
    allowed_roots = tuple(str(root) for root in ROOTS.values()) + tuple(str(root) for root in MEDIA.values())
    registration_files = journal.get('registration_files', [])
    if registration_files and registration_files != [str(path) for path in registration_restore_files()]:
        raise BackupError('Recovery registration cache inventory is invalid.')
    for target_name, entry in mapping.items():
        if target_name not in registration_files and not any(target_name == root or target_name.startswith(root + '/') for root in allowed_roots):
            raise BackupError('Recovery refused an unknown file location.')
        target = Path(target_name)
        for item in [target, *target.parents]:
            if item.is_symlink():
                raise BackupError('Recovery refused a symbolic link in its file locations.')
        if entry.get('exists'):
            if not re.fullmatch(r'\d+', str(entry.get('copy', ''))):
                raise BackupError('Recovery file inventory is invalid.')
            ordinary(RESTORE / 'factory-files' / entry['copy'])
    # Each database restore runs in one transaction. Files then return to the exact factory inventory.
    for service in journal['services']:
        run(['systemctl', 'stop', service], timeout=60)
    restore_database(settings, ordinary(RESTORE / 'factory.dump'), RESTORE)
    for target_name, entry in mapping.items():
        target = Path(target_name)
        if entry['exists']:
            atomic_copy(RESTORE / 'factory-files' / entry['copy'], target, mode=entry['mode'], group=entry['gid'])
            os.chown(target, entry['uid'], entry['gid'])
        else:
            target.unlink(missing_ok=True)
    if journal.get('meeting_proxy'):
        reload_meeting_proxy()
    remove_service_holds(journal.get('gates', {}))
    for service in journal['services']:
        run(['systemctl', 'start', service], timeout=60)
    journal['state'] = 'recovered'
    atomic_json(journal_file, journal)


def activate(settings, selections, confirm_server):
    journal_file = ordinary(RESTORE/'journal.json')
    journal = json.loads(journal_file.read_text())
    if journal.get('state') != 'restored' or journal.get('source_host') != confirm_server or confirm_server != settings.get('openweb.public_host'):
        raise BackupError('Confirm the restored server name and complete the activation checklist first.')
    if not selections:
        raise BackupError('Choose the restored call, job, update or backup service to activate.')
    for selection in selections:
        if selection not in HELD_UNITS or HELD_UNITS[selection] not in journal.get('gates', {}):
            raise BackupError('The requested restored service is not installed.')
    with exclusive_guard(UPGRADE_LOCK):
        for selection in selections:
            unit = HELD_UNITS[selection]
            (RESTORE/('hold-'+unit)).unlink(missing_ok=True)
            run(['systemctl', 'start', unit], timeout=60)


def main():
    parser = argparse.ArgumentParser(description='OpenWeb PBX encrypted backups and independent Debian restore.')
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('worker', help='Process scheduled and administrator backup requests.')
    verify = sub.add_parser('verify', help='Authenticate a downloaded backup and check every archived file.')
    verify.add_argument('backup', type=Path)
    command = sub.add_parser('restore', help='Restore only onto a separate factory installation.')
    command.add_argument('backup', type=Path)
    command.add_argument('--dry-run', action='store_true')
    command.add_argument('--confirm-database')
    sub.add_parser('recover', help='Recover an interrupted restore to the factory installation.')
    activation = sub.add_parser('activate', help='Explicitly release a completed restore service hold after its checklist.')
    activation.add_argument('--confirm-server', required=True)
    for selection in HELD_UNITS:
        activation.add_argument('--'+selection, action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Run this server tool as root.')
    os.umask(0o077)
    try:
        if args.action == 'verify':
            password = getpass.getpass('Original backup password: ')
            with verify_archive(args.backup, password, workspace=safe_private_directory(STORE)) as (_, manifest):
                print('Backup verified: OpenWeb PBX ' + manifest['version'] + ', ' + str(len(manifest['files'])) + ' private files.')
        else:
            settings = read_settings()
            if args.action == 'worker':
                worker(settings)
            elif args.action == 'activate':
                activate(settings, [selection for selection in HELD_UNITS if getattr(args, selection)], args.confirm_server)
                print('The selected restored services were activated.')
            elif args.action == 'recover':
                recover(settings)
                print('Interrupted restore recovered. The factory installation is running again.')
            else:
                password = getpass.getpass('Original backup password: ')
                manifest = restore(args.backup, password, settings, dry_run=args.dry_run, confirm_database=args.confirm_database)
                if args.dry_run:
                    print('Restore dry run passed for OpenWeb PBX ' + manifest['version'] + '. No services, files or data changed.')
                else:
                    print('Restore completed. Web administration is available. Call, job and updater services remain stopped; follow the activation checklist before switching servers.')
    except BackupError as error:
        parser.exit(1, str(error) + '\n')
    except Exception:
        parser.exit(1, 'Backup operation failed. Private recovery material was retained. Check server tools, disk space and permissions.\n')


if __name__ == '__main__':
    main()
