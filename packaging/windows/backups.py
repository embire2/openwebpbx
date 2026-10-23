#!/usr/bin/env python3
"""Encrypted native Windows instance backups. Fixed paths; no secrets in output.

Archive v1: 8-byte magic, 16-byte PBKDF2 salt, 12-byte GCM nonce,
AES-256-GCM ciphertext, 16-byte tag. Header authenticated as AAD.
The encrypted payload is a bounded, manifest-verified gzip tar archive.
"""
import argparse
import base64
import contextlib
import datetime as dt
import getpass
import hashlib
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
import ntpath
if os.name == 'nt':
    import msvcrt
else:
    import fcntl  # Offline fixture locks only; the installed CLI requires Windows.

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b'OWPBXB01'
ITERATIONS = 600_000
CHUNK = 1024 * 1024
MAX_ARCHIVE = 50 * 1000 ** 3  # Keep a single GCM message below its 2^39-256-bit bound.
MAX_FILES = 500_000
APP = Path('C:/OpenWebPBX')
STATE = Path(os.environ.get('ProgramData', 'C:/ProgramData')) / 'OpenWebPBX'
CONFIG_ROOT = STATE.parent / 'fusionpbx'
SWITCH = Path('C:/Program Files/FreeSWITCH')
CONFIG = CONFIG_ROOT / 'config.conf'
KEY = CONFIG_ROOT / 'openweb-template.key'
STORE = STATE / 'automatic-backups'
DOWNLOADS = STATE / 'backup-downloads'
RESTORE = STATE / 'backup-restore'
WEB_VERSION = APP / 'web/VERSION'
UPGRADE_LOCK = STATE / 'upgrade.lock'
CONTROL = APP / 'tools/Backup-Control.ps1'
PG_BIN = APP / 'pgsql/bin'
LOCAL_DATABASE = ('5433', 'fusionpbx', 'fusionpbx')
SSH_BIN = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/OpenSSH'
HELD_UNITS = {'calls': 'FreeSWITCH', 'jobs': 'OpenWebPBX',
              'updates': 'OpenWebPBXUpdater', 'backups': 'OpenWebPBX-Backups'}
RUNTIME_FILES = {'runtime.json', 'installation.json', 'phone-tls.json', 'meet-ca.pem'}
ROOTS = {
    'fusionpbx-config': CONFIG_ROOT,
    'runtime-config': STATE,
    'freeswitch-config': SWITCH / 'conf',
    'phone-tls': STATE / 'phone-tls',
    'public-access': STATE / 'public-access',
    'mobile-notifications': STATE / 'mobile-notifications',
    'mobile-push': STATE / 'mobile-push.json',
    'mobile-push-settings': STATE / 'mobile-push-settings.json',
}
MEDIA = {
    'storage': STATE / 'storage',
    'recordings': STATE / 'storage/recordings',
    'custom-sounds': SWITCH / 'sounds/openwebpbx',
}
SERVICES = ('OpenWebPBXUpdater', 'OpenWebPBX', 'FreeSWITCH')
PLATFORM = 'windows-server2025-x64'


class BackupError(RuntimeError):
    """Only these messages may be shown to an administrator."""


class BackupBusy(BackupError):
    """A native sharing or byte-range lock is currently held elsewhere."""


def reparse(path):
    try:
        info = Path(path).lstat()
    except FileNotFoundError:
        return False
    return Path(path).is_symlink() or bool(getattr(info, 'st_file_attributes', 0) & 0x400)


def tool(name):
    if os.name != 'nt':
        return name  # Independent offline PostgreSQL fixtures only.
    if name in ('psql', 'pg_dump', 'pg_restore'):
        return str(PG_BIN / (name + '.exe'))
    if name in ('sftp', 'ssh-keygen'):
        return str(SSH_BIN / (name + '.exe'))
    raise BackupError('An unsupported server tool was requested.')


def native_powershell_environment():
    # PowerShell 7 prepends its incompatible Core modules to inherited paths.
    # Native IIS/security helpers require only trusted Windows PowerShell roots.
    modules = [Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/Modules',
               Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'WindowsPowerShell/Modules']
    # Windows environment names are case-insensitive; never send duplicate keys
    # with a differently cased inherited Core module path to CreateProcess.
    environment = {key: value for key, value in os.environ.items() if key.upper() != 'PSMODULEPATH'}
    environment['PSModulePath'] = ';'.join(str(path) for path in modules)
    return environment


def control(operation, value=None):
    work = STATE / 'backup-control'
    if reparse(work) or not work.is_dir():
        raise BackupError('The private Windows backup control directory is unavailable. Repair the backup installation.')
    with tempfile.NamedTemporaryFile(dir=work, suffix='.json', mode='w', delete=False, encoding='utf-8') as stream:
        request = Path(stream.name)
        json.dump(value or {}, stream)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        result = run([str(Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'),
                      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(CONTROL),
                      '-Operation', operation, '-Request', str(request)], env=native_powershell_environment(), timeout=180)
        return json.loads(result.decode('utf-8-sig'))
    except (ValueError, UnicodeError):
        raise BackupError('Windows backup control returned an invalid result.') from None
    finally:
        request.unlink(missing_ok=True)


def secure_acl(path, *, download=False, kind='private'):
    if os.name == 'nt':
        control('secure', {'path': str(path), 'kind': 'download' if download else kind})


def replace_file(source, target):
    if os.name != 'nt':
        os.replace(source, target)
        return
    import ctypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    move = kernel.MoveFileExW
    move.argtypes = (ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32)
    move.restype = ctypes.c_int
    if not move(str(source), str(target), 9):  # REPLACE_EXISTING | WRITE_THROUGH
        raise BackupError('Private backup state could not be committed durably.')


def lock_file(stream):
    if os.name == 'nt':
        stream.seek(0)
        msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)


def unlock_file(stream):
    if os.name == 'nt':
        stream.seek(0)
        msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        fcntl.flock(stream, fcntl.LOCK_UN)


def held(selection):
    marker = RESTORE / ('hold-' + selection)
    if reparse(marker):
        raise BackupError('A restore activation gate needs administrator review.')
    return marker.exists()


def restore_pending():
    if any(held(selection) for selection in HELD_UNITS):
        return True
    journal = RESTORE / 'journal.json'
    if journal.exists():
        try:
            return json.loads(ordinary(journal).read_text()).get('state') in ('prepared', 'restoring', 'recovery_required')
        except (ValueError, OSError):
            raise BackupError('Restore recovery state needs administrator review.') from None
    return False


def ordinary(path):
    path = Path(path)
    for item in [path, *path.parents]:
        if reparse(item):
            raise BackupError('A configured backup path is a link or junction. Use the supported standard Windows layout.')
    if not path.is_file():
        raise BackupError('A required private backup file is unavailable.')
    if path.stat().st_nlink > 1:
        raise BackupError('A private backup file is a hard link. Use ordinary private files.')
    return path


def safe_private_directory(path, group=None):
    path = Path(path)
    for item in [path, *path.parents]:
        if reparse(item):
            raise BackupError('Private backup storage must not contain links or junctions.')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o750 if group is not None else 0o700)
    secure_acl(path, download=group is not None)
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
    replace_file(temporary, path)
    sync_directory(path.parent)


def sync_directory(path):
    if os.name == 'nt':
        # Windows durable replacement uses MoveFileEx WRITE_THROUGH below.
        return
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


@contextlib.contextmanager
def windows_exclusive_guard(path, *, existing_only=False):
    # The CRT maps both sharing conflicts and ACL failures to errno 13. Keep
    # their native Windows results distinct so scheduled work defers only for
    # real contention, while invalid paths and permissions still require review.
    import ctypes
    from ctypes import wintypes

    class Overlapped(ctypes.Structure):
        _fields_ = [('Internal', ctypes.c_size_t), ('InternalHigh', ctypes.c_size_t),
                    ('Offset', wintypes.DWORD), ('OffsetHigh', wintypes.DWORD),
                    ('hEvent', wintypes.HANDLE)]

    class FileInformation(ctypes.Structure):
        _fields_ = [('attributes', wintypes.DWORD), ('creation', wintypes.FILETIME),
                    ('access', wintypes.FILETIME), ('write', wintypes.FILETIME),
                    ('volume', wintypes.DWORD), ('size_high', wintypes.DWORD),
                    ('size_low', wintypes.DWORD), ('links', wintypes.DWORD),
                    ('index_high', wintypes.DWORD), ('index_low', wintypes.DWORD)]

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    create = kernel.CreateFileW
    create.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                       wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    create.restype = wintypes.HANDLE
    information = kernel.GetFileInformationByHandle
    information.argtypes = (wintypes.HANDLE, ctypes.POINTER(FileInformation))
    information.restype = wintypes.BOOL
    acquire = kernel.LockFileEx
    acquire.argtypes = (wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD,
                        wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(Overlapped))
    acquire.restype = wintypes.BOOL
    release = kernel.CloseHandle
    release.argtypes = (wintypes.HANDLE,)
    release.restype = wintypes.BOOL

    def refuse(code):
        if code in (32, 33):  # ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION only.
            raise BackupBusy('Another backup, restore or release update is running. Retry after it finishes.') from None
        raise BackupError('The operation lock needs administrator review.') from None

    # Deny sharing to match the .NET maintenance contract and its independent
    # parent-lock check. Keep the byte lock for legacy CRT interoperability;
    # competing old/new Python and .NET handles refuse with native 32 or 33.
    # This also prevents the held node from being replaced.
    handle = create(str(path), 0xC0000000, 0, None, 3 if existing_only else 4, 0x00200080, None)
    if handle == ctypes.c_void_p(-1).value:
        refuse(ctypes.get_last_error())
    try:
        info = FileInformation()
        if not information(handle, ctypes.byref(info)):
            refuse(ctypes.get_last_error())
        if info.attributes & (0x10 | 0x400) or info.links != 1:
            raise BackupError('The operation lock needs administrator review.')
        overlap = Overlapped()
        if not acquire(handle, 3, 0, 1, 0, ctypes.byref(overlap)):
            refuse(ctypes.get_last_error())
        yield
    finally:
        # Closing this exact handle releases its lock, including when the body
        # raises. No exception from the guarded operation is relabelled Busy.
        release(handle)


@contextlib.contextmanager
def exclusive_guard(path):
    path = Path(path)
    if any(reparse(item) for item in (path, *path.parents)):
        raise BackupError('The operation lock needs administrator review.')
    if os.name == 'nt':
        with windows_exclusive_guard(path):
            yield
        return
    try:
        lock = path.open('a+b')
    except OSError:
        raise BackupError('The operation lock needs administrator review.') from None
    with lock:
        lock_path_mode = path.stat().st_mode & 0o777
        if lock_path_mode & 0o022:
            path.chmod(0o600)
        try:
            lock_file(lock)
        except BlockingIOError:
            raise BackupBusy('Another backup, restore or release update is running. Retry after it finishes.') from None
        except OSError:
            raise BackupError('The operation lock needs administrator review.') from None
        try:
            yield
        finally:
            unlock_file(lock)


def read_settings(config=CONFIG):
    settings = {}
    for line in ordinary(config).read_text().splitlines():
        if '=' in line and not line.lstrip().startswith(('#', ';')):
            key, value = line.split('=', 1)
            settings[key.strip()] = value.strip().strip('"')
    if settings.get('database.0.type') != 'pgsql':
        raise BackupError('Instance backups require the built-in PostgreSQL database.')
    if settings.get('database.0.host', '127.0.0.1') not in ('127.0.0.1', 'localhost', '::1'):
        raise BackupError('Instance backups require this Windows server\'s own local PostgreSQL database.')
    for key in ('database.0.name', 'database.0.username'):
        if not settings.get(key):
            raise BackupError('The built-in database configuration is incomplete.')
    return settings


def database_command(settings, executable='psql'):
    return [tool(executable), '-h', settings.get('database.0.host', '127.0.0.1'),
            '-p', settings.get('database.0.port', '5432'), '-U', settings['database.0.username'],
            '-d', settings['database.0.name'], '-w']


def database_environment(settings):
    # Credentials never enter shell commands, arguments, logs or archived metadata.
    return os.environ | {'PGPASSWORD': settings.get('database.0.password', ''),
                         'PGSSLMODE': settings.get('database.0.sslmode', 'prefer'),
                         'PGCONNECT_TIMEOUT': '10', 'PGCLIENTENCODING': 'UTF8'}


def run(command, *, env=None, timeout=7200, input=None):
    try:
        result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
                                **({'input': input} if input is not None else {}))
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
    # UTF-8 stdin avoids Windows narrow-argv code pages; keep batch atomicity.
    result = run(database_command(settings) + ['-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', '-'],
                 env=database_environment(settings), timeout=60, input=('SET standard_conforming_strings=on;\n'+sql).encode('utf-8')).decode().strip()
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
        paths = [root / name for name in sorted(RUNTIME_FILES) if (root / name).exists()] if label == 'runtime-config' and root.is_dir() else sorted(root.rglob('*')) if root.is_dir() else [root]
        for path in paths:
            if label == 'storage' and root.is_dir() and path.relative_to(root).parts[0] == 'recordings':
                continue  # The separate recordings root is inside Windows storage.
            if path.is_dir() and not reparse(path):
                continue
            ordinary(path)
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink > 1:
                raise BackupError('Backup files must be ordinary files without links.')
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


def snapshot_database(settings, destination, *, security=False):
    # Portable exports intentionally omit arbitrary source grants. Only the
    # original local factory dump retains native owner/ACL recovery metadata.
    flags = [] if security else ['--no-owner', '--no-acl']
    run(database_command(settings, 'pg_dump') + ['--format=custom', *flags,
                                                '--serializable-deferrable', '--file', str(destination)],
        env=database_environment(settings))
    destination.chmod(0o600)
    run([tool('pg_restore'), '--list', str(destination)], timeout=60)


def installation_layout():
    # SQL/native XML contain absolute data paths. Until a validated path
    # migration exists, restore may move machines but may not change layout.
    return {label: ntpath.normcase(ntpath.normpath(str(path))) for label, path in
            {'app': APP, 'state': STATE, 'config': CONFIG_ROOT, 'switch': SWITCH}.items()}


def create_archive(settings, destination, password, *, include_media=True, roots=None, version=None):
    if roots is None:
        standard = {'switch.conf.dir': str(SWITCH / 'conf'), 'switch.storage.dir': str(STATE / 'storage'),
                    'switch.voicemail.dir': str(STATE / 'storage/voicemail'),
                    'switch.recordings.dir': str(STATE / 'storage/recordings')}
        if any(ntpath.normcase(ntpath.normpath(settings.get(key, path))) != ntpath.normcase(ntpath.normpath(path)) for key, path in standard.items()):
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
        meeting_transport_files({'files': files})
        files['database.dump'] = {'source': dump, 'size': dump.stat().st_size, 'mtime_ns': dump.stat().st_mtime_ns,
                                  'mode': 0o600, 'sha256': checksum(dump)}
        manifest = {'schema': 1, 'platform': PLATFORM, 'version': version,
                    'created_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'include_media': include_media,
                    'installation_layout': installation_layout(),
                    'source_host': settings.get('openweb.public_host', ''), 'source_url': settings.get('openweb.public_url', ''), 'database': layout,
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
    for part in path.parts:
        if re.search(r'[\x00-\x1f\x7f<>:"|?*]', part) or part.endswith(('.', ' ')) or re.fullmatch(r'(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:[.].*)?', part, re.I):
            raise BackupError('The backup contains an unsafe Windows file name.')
    if name != 'database.dump':
        if len(path.parts) < 2 or path.parts[0] not in ROOTS | MEDIA:
            raise BackupError('The backup contains an unknown private-data location.')
        if path.parts[0] in ('mobile-push', 'mobile-push-settings') and name != path.parts[0] + '/file':
            raise BackupError('The backup contains an unknown private-data location.')
        if path.parts[0] == 'mobile-notifications' and name not in ('mobile-notifications/config.json', 'mobile-notifications/config.json.lock'):
            raise BackupError('The backup contains an unknown private-data location.')
        if path.parts[0] == 'runtime-config' and (len(path.parts) != 2 or path.parts[1] not in RUNTIME_FILES):
            raise BackupError('The backup contains an unknown runtime file.')
    return path


def extract_verified(payload, destination):
    with tarfile.open(payload, 'r:gz') as archive:
        first = archive.next()
        if first is None or first.name != 'manifest.json' or not first.isfile() or not 1 <= first.size <= 32 * 1024 ** 2:
            raise BackupError('The backup inventory is missing or too large.')
        manifest = json.load(archive.extractfile(first))
        if manifest.get('schema') != 1 or manifest.get('platform') != PLATFORM or not re.fullmatch(r'\d+\.\d+\.\d+', str(manifest.get('version', ''))):
            raise BackupError('The backup version or platform is unsupported.')
        files = manifest.get('files')
        if not isinstance(files, dict) or not 1 <= len(files) <= MAX_FILES or 'database.dump' not in files:
            raise BackupError('The backup inventory is incomplete.')
        expected_total = 0
        folded = set()
        for name, entry in files.items():
            safe_member(name)
            if name.casefold() in folded:
                raise BackupError('The backup contains colliding Windows file names.')
            folded.add(name.casefold())
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
        run([tool('pg_restore'), '--list', str(destination / 'database.dump')], timeout=60)
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
        secure_acl(key)
        # Validate a usable, unencrypted identity before connecting. Never output it.
        run([tool('ssh-keygen'), '-y', '-P', '', '-f', str(key)], timeout=20)
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
        empty = work / 'empty_config'
        empty.write_text('')
        path_option = lambda value: '"' + str(value.resolve()).replace('\\', '/').replace('"', '\\"') + '"'
        run([tool('sftp'), '-F', str(empty), '-oBatchMode=yes', '-oIdentitiesOnly=yes', '-oStrictHostKeyChecking=yes',
             '-oUserKnownHostsFile=' + path_option(known), '-oGlobalKnownHostsFile=' + path_option(empty),
             '-i', str(key), '-oConnectTimeout=15', '-oConnectionAttempts=1',
             '-P', str(port), '-b', str(batch), user + '@' + host], timeout=7200)


def publish_download(source, destination):
    ordinary(source)
    destination = Path(destination)
    if reparse(destination):
        raise BackupError('The backup download path needs administrator review.')
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.download-', delete=False) as stream:
        temporary = Path(stream.name)
        try:
            with source.open('rb') as incoming:
                shutil.copyfileobj(incoming, stream, CHUNK)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.chmod(0o640)
        if checksum(temporary) != checksum(source):
            raise BackupError('The encrypted download copy failed its integrity check.')
        secure_acl(temporary, download=True)
        replace_file(temporary, destination)
        sync_directory(destination.parent)
    finally:
        temporary.unlink(missing_ok=True)


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
            if reparse(file):
                raise BackupError('An old backup path is a symbolic link. Retention was stopped.')
            file.unlink(missing_ok=True)
        query(settings, 'delete from v_pbx_backups where backup_uuid=' + literal(row['backup_uuid']) + "::uuid and status='ready'")


def worker(settings, **kwargs):
    if restore_pending() or (STATE / 'updates/maintenance').exists():
        return  # Never consume pending requests during a restore or update hold.
    with exclusive_guard(UPGRADE_LOCK):
        return _worker(settings, **kwargs)


def _worker(settings, *, store=STORE, downloads=DOWNLOADS, roots=None, version=None, key_file=KEY):
    store = safe_private_directory(store)
    downloads = safe_private_directory(downloads, group=33)
    with exclusive_guard(store / 'worker.lock'):
        # A killed worker cannot hold this exclusive lock. Mark its request as failed.
        query(settings, "update v_pbx_backup_commands set status='failed',message='The backup service stopped before completion. Retry this request.',finished_at=now() where status='running'")
        query(settings, "update v_pbx_backups set status='failed',message='The backup service stopped before completion.' where status='creating'")
        for directory in store.glob('.backup-work-*'):
            if not reparse(directory) and directory.is_dir():
                shutil.rmtree(directory)
        for directory in store.glob('.verify-backup-*'):
            if not reparse(directory) and directory.is_dir():
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
    if settings.get('database.0.host', '127.0.0.1') not in ('127.0.0.1', 'localhost', '::1'):
        raise BackupError('Restore requires the replacement instance’s own local PostgreSQL database.')
    validate_database_layout(settings)
    tables = {'v_extensions': 0, 'v_pbx_tenants': 0, 'v_pbx_services': 0, 'v_pbx_restore': 0,
              'v_recordings': 0, 'v_voicemail_messages': 0, 'v_users': 1, 'v_domains': 1}
    for table, maximum in tables.items():
        exists = query(settings, 'select to_regclass(' + literal(table) + ') is not null')
        if exists == 't' and int(query(settings, 'select count(*) from ' + table)) > maximum:
            raise BackupError('Restore refused an installation containing users, phones, tenants or customer media. Use a separate fresh installation.')


def local_database_administrator(settings, installation):
    if (settings.get('database.0.host', '127.0.0.1') not in ('127.0.0.1', 'localhost', '::1')
            or tuple(settings.get(key) for key in ('database.0.port', 'database.0.name', 'database.0.username')) != LOCAL_DATABASE
            or not isinstance(installation, dict)
            or not isinstance(installation.get('DatabasePassword'), str) or not installation['DatabasePassword']
            or not isinstance(settings.get('database.0.password'), str) or not settings['database.0.password']
            or installation.get('DatabasePassword') != settings.get('database.0.password')
            or not isinstance(installation.get('PostgresPassword'), str) or not installation['PostgresPassword']):
        raise BackupError('The original local database administrator identity is incomplete.')
    administrator = settings | {'database.0.username': 'postgres', 'database.0.password': installation['PostgresPassword']}
    if query(administrator, "select current_user='postgres' and (select rolsuper from pg_roles where rolname=current_user)") != 't':
        raise BackupError('The original local database administrator identity could not be verified.')
    return administrator


def database_security_entries(factory_dump):
    ordinary(factory_dump)
    listing = run([tool('pg_restore'), '--list', str(factory_dump)]).decode('utf-8')
    public_entry = re.compile(r'^\d+; \d+ \d+ (?:SCHEMA - public |(?:ACL|COMMENT) - SCHEMA public |DEFAULT ACL public )')
    schema_entry = re.compile(r'^\d+; \d+ \d+ SCHEMA - public ')
    schema_lines = [line for line in listing.splitlines() if public_entry.match(line)]
    # The exact initdb public schema can be omitted entirely by native pg_dump.
    if (sum(bool(schema_entry.match(line)) for line in schema_lines) > 1
            or any(re.match(r'^\d+; \d+ \d+ SCHEMA - ', line) and not schema_entry.match(line) for line in listing.splitlines())
            or not any(re.match(r'^\d+; \d+ \d+ TABLE public ', line) for line in listing.splitlines())):
        raise BackupError('The original native public schema recovery metadata is incomplete.')
    return schema_lines


def portable_database_entries(dump):
    listing = run([tool('pg_restore'), '--list', str(ordinary(dump))]).decode('utf-8').splitlines()
    if any(re.match(r'^\d+; \d+ \d+ SCHEMA - ', line) and not re.match(r'^\d+; \d+ \d+ SCHEMA - public ', line) for line in listing):
        raise BackupError('The portable backup contains an unsupported schema.')
    return listing


def restore_database_security(settings, dump, workspace, factory_dump, administrator, *, recovery=False):
    if not isinstance(administrator, dict) or administrator.get('database.0.username') != 'postgres':
        raise BackupError('Native database security restoration needs the original local administrator.')
    # Preserve the connection tuple from the original application configuration.
    if any(administrator.get(key) != settings.get(key) for key in ('database.0.host', 'database.0.port', 'database.0.name')):
        raise BackupError('Native database security restoration refused a different target.')
    ordinary(dump); schema_lines = database_security_entries(factory_dump)
    public_entry = re.compile(r'^\d+; \d+ \d+ (?:SCHEMA - public |(?:ACL|COMMENT) - SCHEMA public |DEFAULT ACL public )')
    files = []
    def render(source, name, entries=None, portable=False):
        output = workspace / name
        command = [tool('pg_restore'), '--exit-on-error']
        if portable:
            command += ['--no-owner', '--no-acl']
        if entries is not None:
            selected = output.with_suffix('.list')
            selected.write_text('\n'.join(entries)+'\n', encoding='utf-8', newline='\n')
            selected.chmod(0o600); files.append(selected)
            command += ['--use-list', str(selected)]
        run(command + ['--file', str(output), str(source)])
        output.chmod(0o600); files.append(output)
        return output
    if recovery:
        if Path(dump) != Path(factory_dump):
            raise BackupError('Factory recovery refused a different native dump.')
        schema_sql = render(dump, 'native-factory.sql')
        sql_files = [schema_sql]
    else:
        source_listing = portable_database_entries(dump)
        schema_sql = render(factory_dump, 'native-schema.sql', schema_lines)
        source_sql = render(dump, 'native-source.sql', [line for line in source_listing if not public_entry.match(line)], True)
        role = settings.get('database.0.username')
        if not isinstance(role, str) or not role or '\x00' in role:
            raise BackupError('The original application database role is incomplete.')
        # Do not normalize native SQL body bytes (including function CR/LF).
        source_sql.write_bytes(('SET LOCAL ROLE "'+role.replace('"', '""')+'";\n').encode('utf-8')
                               +source_sql.read_bytes()+b'\nRESET ROLE;\n')
        sql_files = [schema_sql, source_sql]
    reset = workspace / 'native-reset.sql'
    value = 'DROP SCHEMA public CASCADE;\n'
    if not re.search(r'^CREATE SCHEMA (?:public|"public");', schema_sql.read_text(encoding='utf-8'), re.MULTILINE):
        # pg_dump omits the initdb public-schema definition/default ACL.
        # Recreate that prerequisite before native owner/custom-ACL replay.
        value += 'CREATE SCHEMA public AUTHORIZATION pg_database_owner;\nGRANT USAGE ON SCHEMA public TO PUBLIC;\n'
    reset.write_text(value, encoding='utf-8', newline='\n'); reset.chmod(0o600); files.append(reset)
    arguments = ['-X', '-v', 'ON_ERROR_STOP=1', '--single-transaction']
    for path in [reset, *sql_files]:
        arguments += ['-f', str(path)]
    run(database_command(administrator) + arguments, env=database_environment(administrator))
    for path in files:
        path.unlink(missing_ok=True)


def apply_voicemail_policy(settings):
    # Migrate only a successful source import, never the target recovery dump.
    policy = ordinary(WEB_VERSION.parent / 'app/voicemails/resources/voicemail_without_pins.sql')
    query(settings, policy.read_text(encoding='utf-8'))


def meeting_transport_files(manifest):
    pair = {'runtime-config/meet-ca.pem', 'freeswitch-config/tls/openweb-meet/wss.pem'}
    present = pair.intersection(manifest['files'])
    if present and present != pair:
        raise BackupError('The backup is missing part of its private meeting connection.')
    return bool(present)


def restore_meeting(settings):
    # Preserve the source identity, schedules and history while binding media
    # to this machine. Live guest sessions belong to the previous server.
    if query(settings, "select to_regclass('public.v_sip_profiles') is not null") != 't':
        return False
    if query(settings, "select count(*) from v_sip_profiles where sip_profile_uuid='cfb1c835-c30c-409b-bff7-a893a7e84df1' or sip_profile_name='openweb-meet'") == '0':
        return False
    conf = ROOTS['freeswitch-config']
    state = ROOTS['runtime-config']
    ordinary(conf / 'tls/openweb-meet/wss.pem')
    ordinary(state / 'meet-ca.pem')
    code = r"""require $argv[1].'/resources/classes/config.php';config::load($argv[2]);require $argv[1].'/resources/classes/auto_loader.php';new auto_loader();$db=database::new()->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
if(str_replace('\\','/',(string)config::load()->get('switch.conf.dir'))!==str_replace('\\','/',$argv[3]))throw new RuntimeException('The restored engine configuration path needs review.');
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
    php = str(APP / 'php/php.exe') if os.name == 'nt' else 'php'
    run([php, '-r', code, str(WEB_VERSION.parent), str(ROOTS['fusionpbx-config'] / 'config.conf'), str(conf), str(state)], timeout=120)
    return True


def reload_meeting_proxy():
    # The machine-bound IIS ownership ledger is deliberately not portable.
    # Rebind its owned trust after source import, or after factory recovery.
    helper = ordinary(APP / 'tools/Install-Meet.ps1')
    executable = str(Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
    run([executable, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
         '-File', str(helper), '-PackageRoot', str(helper.parent),
         '-RebindRestoredTransport', '-MaintenanceLockHeld'],
        env=native_powershell_environment(), timeout=180)


def restore_database(settings, dump, workspace, *, factory_dump=None, administrator=None, recovery=False):
    if factory_dump is not None:
        return restore_database_security(settings, dump, workspace, factory_dump, administrator, recovery=recovery)
    # Schema-one journals without the new marker retain their original recovery
    # behavior. Their dumps cannot invent ACL entries that were never recorded.
    sql = workspace / 'restore.sql'
    run([tool('pg_restore'), '--no-owner', '--no-acl', '--file', str(sql), str(ordinary(dump))])
    sql.chmod(0o600)
    reset = workspace / 'reset.sql'
    reset.write_text('DROP SCHEMA public CASCADE;\n')
    reset.chmod(0o600)
    listing = run([tool('pg_restore'), '--list', str(dump)]).decode()
    # A TOC entry for the default public schema may contain only its comment,
    # without CREATE SCHEMA. Inspect that entry's SQL, rather than its presence.
    schema_list = workspace / 'schema.list'
    schema_sql = workspace / 'schema.sql'
    schema_list.write_text('\n'.join(line for line in listing.splitlines() if re.search(r' SCHEMA - public ', line))+'\n')
    schema_list.chmod(0o600)
    run([tool('pg_restore'), '--no-owner', '--no-acl', '--use-list', str(schema_list), '--file', str(schema_sql), str(dump)])
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


def restore_targets(manifest):
    mapping = {}
    roots = ROOTS | MEDIA
    for name in manifest['files']:
        if name == 'database.dump':
            continue
        relative = safe_member(name)
        label = relative.parts[0]
        root = roots[label]
        if label == 'public-access':
            # ACME accounts/DPAPI and certificate-store references are machine
            # bound. Retain source evidence without replacing target identity.
            root = STATE / 'restored-source/public-access'
        target = root if label.startswith('mobile-push') else root / PurePosixPath(*relative.parts[1:])
        for item in [target, *target.parents]:
            if reparse(item):
                raise BackupError('Restore refused a symbolic link in the target private-data path.')
        mapping[name] = target
    return mapping


def notification_directory(directory, *, create=False):
    for path in [directory, *directory.parents]:
        if reparse(path):
            raise BackupError('Notification storage must not contain links or junctions.')
    if create:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        secure_acl(directory, kind='notifications')


def acl_kind(target):
    target = Path(target)
    if target == ROOTS['fusionpbx-config'] / 'tenant-domains-instance-key.pem':
        return 'private'
    if STATE / 'restored-source' == target or STATE / 'restored-source' in target.parents:
        return 'private'
    if target == ROOTS['runtime-config'] / 'installation.json':
        return 'private'
    if target == ROOTS.get('mobile-push') or target == ROOTS.get('mobile-push-settings') or ROOTS['mobile-notifications'] in target.parents:
        return 'notifications'
    if any(root == target or root in target.parents for root in MEDIA.values()):
        return 'media'
    return 'config'


def recovery_parent_paths(targets):
    """Only ancestors inside the fixed private/config/media roots may change."""
    roots = tuple(ROOTS[label] for label in ('fusionpbx-config', 'runtime-config',
                                            'freeswitch-config', 'mobile-notifications')) + tuple(MEDIA.values())
    result = set()
    for target in targets:
        target = Path(target)
        if '..' in target.parts or not any(root == target.parent or root in target.parents for root in roots):
            raise BackupError('Recovery refused an unknown private-data parent location.')
        for item in reversed([target, *target.parents]):
            if reparse(item):
                raise BackupError('Recovery refused a link or junction in private-data locations.')
            if item != target and item.exists() and not item.is_dir():
                raise BackupError('Recovery refused a nonordinary private-data directory.')
        directory = target.parent
        while any(directory == root or root in directory.parents for root in roots):
            if directory.exists() and not directory.is_dir():
                raise BackupError('Recovery refused a nonordinary private-data directory.')
            result.add(directory)
            if len(result) > MAX_FILES:
                raise BackupError('The private-data directory recovery inventory is too large.')
            directory = directory.parent
        # Restores must not create a ProgramData, Program Files or other
        # ancestor outside the supported application-owned locations.
        if not directory.is_dir():
            raise BackupError('A parent outside the owned restore locations is unavailable.')
    return sorted(result, key=lambda path: (len(path.parts), str(path)))


def atomic_copy(source, target, mode=0o640, group=33):
    source, target = Path(source), Path(target)
    recovery_parent_paths([target])
    notification = target.parent == ROOTS.get('mobile-notifications')
    kind = acl_kind(target)
    if notification:
        notification_directory(target.parent, create=True)
    absent = []
    directory = target.parent
    while not directory.exists():
        absent.append(directory)
        directory = directory.parent
    for directory in reversed(absent):
        directory.mkdir(mode=0o750)
        secure_acl(directory, kind=kind)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.backup-restore-', delete=False) as stream:
            temporary = Path(stream.name)
            with source.open('rb') as incoming:
                shutil.copyfileobj(incoming, stream, CHUNK)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(mode)
        secure_acl(temporary, kind=kind)
        replace_file(temporary, target)
        sync_directory(target.parent)
    finally:
        # Close the stream before removal on Windows, including failures in
        # chmod, native ACL application or the durable rename itself.
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def preserve_target_database(settings, config_file, runtime_file):
    config = read_settings(config_file)
    for key in list(config):
        if key.startswith('database.0.'):
            del config[key]
    config.update({key: value for key, value in settings.items() if key.startswith('database.0.')})
    # The replacement address belongs to its own network adapter. Tenant
    # provider/routing configuration is restored separately and stays intact.
    if 'openweb.public_ip' in settings:
        config['openweb.public_ip'] = settings['openweb.public_ip']
    else:
        config.pop('openweb.public_ip', None)
    config['openweb.mobile_tls_ready'] = 'false'
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
    return control('plan')['running']


def plan_service_holds():
    return control('plan')


def install_service_holds(gates):
    for selection in HELD_UNITS:
        atomic_json(RESTORE / ('hold-' + selection), {'schema': 1, 'selection': selection})
    control('hold', gates)


def remove_service_holds(gates):
    control('recover-startup', gates)
    for selection in HELD_UNITS:
        (RESTORE / ('hold-' + selection)).unlink(missing_ok=True)


def refuse_restored_phone_recoveries(settings):
    # A restored request is no longer the administrator's current confirmation,
    # even on the same machine with the same protected instance identity. Keep
    # the complete history; never replay a source server's pending unblock.
    present = query(settings, "select to_regclass('public.v_pbx_phone_health_recoveries') is not null")
    if present == 'f':
        return 0  # Earlier matching-version archives may predate this table.
    if present != 't':
        raise BackupError('Restored phone recovery state could not be checked.')
    count = query(settings, "with refused as (update public.v_pbx_phone_health_recoveries set status='refused' where status='pending' returning 1) select count(*) from refused")
    if not isinstance(count, str) or not re.fullmatch(r'[0-9]{1,19}', count) or int(count) > 9223372036854775807:
        raise BackupError('Restored phone recovery state could not be checked.')
    return int(count)


def restore(source, password, settings, **kwargs):
    safe_private_directory(STORE)
    with exclusive_guard(UPGRADE_LOCK), exclusive_guard(STORE/'worker.lock'):
        return _restore(source, password, settings, **kwargs)


def _restore(source, password, settings, *, dry_run=False, confirm_database=None):
    safe_private_directory(RESTORE)
    with verify_archive(source, password, workspace=RESTORE) as (extracted, manifest):
        installed = ordinary(WEB_VERSION).read_text().strip()
        if manifest['version'] != installed:
            raise BackupError('Install the same application release as this backup before restoring.')
        if manifest['source_host'] != settings.get('openweb.public_host', ''):
            raise BackupError('Install the replacement server with the original public server name before restoring.')
        if manifest.get('source_url', '') != settings.get('openweb.public_url', ''):
            raise BackupError('Install the replacement server with the original HTTPS address and port before restoring.')
        if manifest.get('installation_layout') != installation_layout():
            raise BackupError('Install the replacement server with the original application and ProgramData layout before restoring. Absolute private-data paths cannot be migrated automatically.')
        if manifest['database']['version'] // 10000 > int(query(settings, "show server_version_num")) // 10000:
            raise BackupError('The target PostgreSQL version is older than the backup source.')
        required = {'fusionpbx-config/config.conf', 'fusionpbx-config/openweb-template.key', 'runtime-config/runtime.json', 'runtime-config/installation.json'}
        if not required.issubset(manifest['files']):
            raise BackupError('The backup is missing configuration or encryption keys needed for a full restore.')
        if len((extracted / 'fusionpbx-config/openweb-template.key').read_bytes()) != 32:
            raise BackupError('The source private encryption key has an invalid size.')
        meeting_proxy = meeting_transport_files(manifest)
        preserve_target_database(settings, extracted / 'fusionpbx-config/config.conf', extracted / 'runtime-config/runtime.json')
        original_installation = json.loads(ordinary(STATE / 'installation.json').read_text(encoding='utf-8-sig'))
        source_installation_file = extracted / 'runtime-config/installation.json'
        source_installation = json.loads(source_installation_file.read_text(encoding='utf-8-sig'))
        for field in ('DatabasePassword', 'PostgresPassword'):
            if not isinstance(original_installation.get(field), str) or not original_installation[field]:
                raise BackupError('The replacement server database identity is incomplete.')
            source_installation[field] = original_installation[field]
        for field in ('CertificateThumbprint', 'HttpsCertificateThumbprint', 'PublicAddress'):
            if field in original_installation:
                source_installation[field] = original_installation[field]
            else:
                source_installation.pop(field, None)
        source_installation_file.write_text(json.dumps(source_installation), encoding='utf-8')
        if 'runtime-config/phone-tls.json' in manifest['files']:
            tls_file = extracted / 'runtime-config/phone-tls.json'
            tls = json.loads(ordinary(tls_file).read_text(encoding='utf-8-sig'))
            tls['CertificateThumbprint'] = ''
            tls['RestorePending'] = True
            tls_file.write_text(json.dumps(tls), encoding='utf-8')
        mapping = restore_targets(manifest)
        notification_root = ROOTS.get('mobile-notifications')
        notification_fallback = None
        if notification_root is not None:
            notification_directory(notification_root)
            if 'mobile-push/file' in mapping and 'mobile-notifications/config.json' not in mapping:
                notification_fallback = notification_root / 'config.json'
                for item in [notification_fallback, *notification_fallback.parents]:
                    if reparse(item):
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
        gates = plan_service_holds()
        services = gates['running']
        recovery_targets = list(mapping.values()) + ([notification_fallback] if notification_fallback is not None else [])
        parent_paths = recovery_parent_paths(recovery_targets)
        # Create durable recovery material before stopping any service or changing a file.
        administrator = local_database_administrator(settings, original_installation)
        snapshot_database(administrator, RESTORE / 'factory.dump', security=True)
        database_security_entries(RESTORE / 'factory.dump')
        portable_database_entries(extracted / 'database.dump')
        recovery_files = RESTORE / 'factory-files'
        recovery_files.mkdir(mode=0o700)
        original = {}
        directories = {str(path): {'exists': path.is_dir()} for path in parent_paths}
        for index, target in enumerate(recovery_targets):
            if target.exists() and not target.is_file():
                raise BackupError('Restore refused a nonordinary target private-data file.')
            original[str(target)] = {'exists': target.is_file()}
            if target.is_file():
                ordinary(target)
                st = target.stat()
                copy = recovery_files / str(index)
                shutil.copyfile(target, copy)
                copy.chmod(0o600)
                original[str(target)].update({'copy': str(index), 'mode': stat.S_IMODE(st.st_mode),
                                             'size': st.st_size, 'sha256': checksum(copy)})
        acls = control('acl-read', {'paths': [path for inventory in (directories, original)
                                            for path, entry in inventory.items() if entry['exists']]})
        for path, entry in list(directories.items()) + list(original.items()):
            if entry['exists']:
                if not isinstance(acls.get(path), str) or not acls[path] or len(acls[path]) > 32768:
                    raise BackupError('The factory private-data permission snapshot is incomplete.')
                entry['sddl'] = acls[path]
        journal = {'schema': 1, 'database': settings['database.0.name'], 'user': settings['database.0.username'],
                   'services': services, 'gates': gates, 'source_host': manifest['source_host'],
                   'factory_dump_sha256': checksum(RESTORE / 'factory.dump'), 'factory_security_version': 1, 'files': original,
                   'directories': directories, 'meeting_proxy': meeting_proxy,
                   'call_records_hold': {'schema': 1, 'owner': 'restore', 'transaction': uuid.uuid4().hex}, 'state': 'prepared'}
        atomic_json(RESTORE / 'journal.json', journal)
        try:
            install_service_holds(journal['gates'])
            journal['state'] = 'restoring'
            atomic_json(RESTORE / 'journal.json', journal)
            restore_database(settings, extracted / 'database.dump', RESTORE,
                             factory_dump=RESTORE / 'factory.dump', administrator=administrator)
            for name, target in mapping.items():
                mode = manifest['files'][name]['mode'] & 0o750
                if name.endswith(('config.conf', '.key', 'runtime.json')) or name.startswith('mobile-push'):
                    mode = 0o640
                if name.startswith(('mobile-push', 'mobile-notifications/')):
                    mode = 0o600
                atomic_copy(extracted / name, target, mode=mode or 0o640)
            if notification_fallback is not None:
                # Older archive labels keep their original copy and also seed
                # the current PHP/C# location with the identical VAPID bytes.
                atomic_copy(extracted / 'mobile-push/file', notification_fallback, mode=0o600)
            apply_voicemail_policy(settings)
            restore_meeting(settings)
            if meeting_proxy:
                reload_meeting_proxy()
            # Invalid source SIP contacts and XML caches must never survive a clean restore.
            cache = STATE / 'cache'
            if cache.is_dir() and not reparse(cache):
                for child in cache.iterdir():
                    if child.is_dir() and not reparse(child):
                        shutil.rmtree(child)
                    else:
                        child.unlink()
            query(settings, "update v_pbx_backup_commands set status='failed',message='Request belonged to the previous server. Retry on this server.',finished_at=now() where status in ('pending','running')")
            query(settings, "update v_pbx_backups set status='failed',message='Previous server: this encrypted backup file was not included in the restore. Keep its separately downloaded or remote copy.' where status in ('ready','creating')")
            query(settings, "update v_pbx_backup_settings set enabled=false,sftp_enabled=false where singleton=1")
            journal['phone_health_recoveries_refused'] = refuse_restored_phone_recoveries(settings)
            journal['state'] = 'restored'
            atomic_json(RESTORE / 'journal.json', journal)
            control('start-web')
            # Call/job/updater services remain stopped: source trunks must not steal registrations.
            return manifest
        except BaseException:
            try:
                _recover(settings)
            except BaseException:
                journal['state'] = 'recovery_required'
                atomic_json(RESTORE / 'journal.json', journal)
                raise BackupError('Restore recovery could not finish. Services remain held; use recover after correcting the private storage or database error.') from None
            raise


def recover(settings):
    safe_private_directory(STORE)
    with exclusive_guard(UPGRADE_LOCK), exclusive_guard(STORE/'worker.lock'):
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
    if not isinstance(mapping, dict) or len(mapping) > MAX_FILES:
        raise BackupError('The factory file recovery inventory is invalid.')
    allowed_roots = tuple(ROOTS.values()) + tuple(MEDIA.values())
    for target_name, entry in mapping.items():
        target = Path(target_name)
        if '..' in target.parts or not any(target == root or root in target.parents for root in allowed_roots):
            raise BackupError('Recovery refused an unknown file location.')
        if not isinstance(entry, dict) or not isinstance(entry.get('exists'), bool):
            raise BackupError('The factory file recovery inventory is invalid.')
        for item in [target, *target.parents]:
            if reparse(item):
                raise BackupError('Recovery refused a symbolic link in its file locations.')
        if entry.get('exists'):
            if not re.fullmatch(r'\d+', str(entry.get('copy', ''))):
                raise BackupError('Recovery file inventory is invalid.')
            original = ordinary(RESTORE / 'factory-files' / entry['copy'])
            if original.stat().st_size != entry.get('size') or checksum(original) != entry.get('sha256') or not isinstance(entry.get('sddl'), str):
                raise BackupError('A factory recovery file failed its integrity check.')
    # Schema-one journals written by earlier installations contained files
    # only. Keep those recoverable; new journals prove every mutable parent.
    directories = journal.get('directories', {})
    if 'directories' in journal:
        expected = {str(path) for path in recovery_parent_paths(mapping)}
        if not isinstance(directories, dict) or len(directories) > MAX_FILES or set(directories) != expected:
            raise BackupError('The factory directory recovery inventory is invalid.')
        for entry in directories.values():
            if not isinstance(entry, dict) or not isinstance(entry.get('exists'), bool):
                raise BackupError('The factory directory recovery inventory is invalid.')
            if entry['exists'] and (not isinstance(entry.get('sddl'), str) or not entry['sddl'] or len(entry['sddl']) > 32768):
                raise BackupError('The factory directory permission inventory is invalid.')
    if checksum(ordinary(RESTORE / 'factory.dump')) != journal.get('factory_dump_sha256'):
        raise BackupError('The factory recovery database failed its integrity check.')
    security = journal.get('factory_security_version')
    administrator = None
    if 'factory_security_version' in journal:
        if type(security) is not int or security != 1:
            raise BackupError('The factory database security inventory version is invalid.')
        installation = mapping.get(str(STATE / 'installation.json'), {})
        if installation.get('exists') is not True:
            raise BackupError('The original local database administrator recovery input is missing.')
        original = ordinary(RESTORE / 'factory-files' / installation['copy'])
        administrator = local_database_administrator(settings, json.loads(original.read_text(encoding='utf-8-sig')))
        database_security_entries(RESTORE / 'factory.dump')
    # Each database restore runs in one transaction. Files then return to the exact factory inventory.
    control('hold', journal['gates'])
    if security == 1:
        restore_database(settings, ordinary(RESTORE / 'factory.dump'), RESTORE,
                         factory_dump=RESTORE / 'factory.dump', administrator=administrator, recovery=True)
    else:
        restore_database(settings, ordinary(RESTORE / 'factory.dump'), RESTORE)
    for target_name, entry in mapping.items():
        target = Path(target_name)
        if entry['exists']:
            atomic_copy(RESTORE / 'factory-files' / entry['copy'], target, mode=entry['mode'])
        else:
            target.unlink(missing_ok=True)
    # Parent inheritance is restored before each exact file descriptor, so a
    # later parent ACL cannot overwrite the recovered child's permissions.
    present_directories = sorted((Path(name) for name, entry in directories.items() if entry['exists']),
                                 key=lambda path: (len(path.parts), str(path)))
    for directory in present_directories:
        recovery_parent_paths([directory / '.recovery-parent-validation'])
        directory.mkdir(exist_ok=True)
    control('acl-restore', {'files': {str(path): directories[str(path)]['sddl'] for path in present_directories}})
    control('acl-restore', {'files': {name: entry['sddl'] for name, entry in mapping.items() if entry['exists']}})
    for name in sorted((name for name, entry in directories.items() if not entry['exists']),
                       key=lambda name: (len(Path(name).parts), name), reverse=True):
        directory = Path(name)
        recovery_parent_paths([directory / '.recovery-parent-validation'])
        if directory.exists():
            try:
                directory.rmdir()
            except OSError:
                raise BackupError('A newly created restore directory is not empty. Preserve unrelated contents and complete recovery after administrator review.') from None
    if journal.get('meeting_proxy'):
        reload_meeting_proxy()
    journal['state'] = 'recovered'
    atomic_json(journal_file, journal)
    remove_service_holds(journal.get('gates', {}))
    control('resume-factory', journal['gates'])


def activate(settings, selections, confirm_server):
    journal_file = ordinary(RESTORE/'journal.json')
    journal = json.loads(journal_file.read_text())
    if journal.get('state') != 'restored' or journal.get('source_host') != confirm_server or confirm_server != settings.get('openweb.public_host'):
        raise BackupError('Confirm the restored server name and complete the activation checklist first.')
    if not selections:
        raise BackupError('Choose the restored call, job, update or backup service to activate.')
    for selection in selections:
        if selection not in HELD_UNITS or not held(selection):
            raise BackupError('The requested restored service is not installed.')
    with exclusive_guard(UPGRADE_LOCK):
        for selection in selections:
            (RESTORE / ('hold-' + selection)).unlink(missing_ok=True)
            try:
                control('activate', {'selections': [selection], 'gates': journal['gates']})
            except BaseException:
                atomic_json(RESTORE / ('hold-' + selection), {'schema': 1, 'selection': selection})
                control('hold-selection', {'selection': selection})
                raise


def main():
    parser = argparse.ArgumentParser(description='OpenWeb PBX encrypted backups and independent Windows restore.')
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
    if os.name != 'nt':
        parser.error('Run this server tool on the installed Windows instance as Administrator or SYSTEM.')
    import ctypes
    if not ctypes.windll.shell32.IsUserAnAdmin():
        parser.error('Run this server tool as Administrator or SYSTEM.')
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
