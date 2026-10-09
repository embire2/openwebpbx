#!/usr/bin/env python3
"""Update an installed Debian PBX from a verified release; preserve private data."""
import argparse
import datetime
import fcntl
import hashlib
import json
import importlib.util
import uuid
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
UPDATES = Path('/var/lib/openwebpbx/updates')
JOURNAL = UPDATES / 'install-journal.json'
MAINTENANCE = UPDATES / 'maintenance'
TOOLS = Path('/opt/openwebpbx/tools')
BACKUPS = Path('/var/backups/openwebpbx')
UPDATER = Path('/opt/openwebpbx/updater')
PUBLIC_KEY = Path(__file__).with_name('release-public.pem')
TERMINAL = {'completed', 'rolled_back'}

class Deferred(RuntimeError):
    pass

class RecoveryRequired(RuntimeError):
    pass


def validate_manifest(package):
    manifest = json.loads((package / 'release-manifest.json').read_text())
    version = (package / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or manifest.get('version') != version:
        raise ValueError('Release version is invalid or inconsistent.')
    files = manifest.get('files', {})
    if (package/'web/VERSION').read_text().strip()!=version:
        raise ValueError('The packaged web version differs from the release version.')
    required = {'web/VERSION', 'web/resources/require.php', 'server/OpenWebPbx.Server', 'bootstrap.php',
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
                if target.exists() and not target.is_file():
                    raise ValueError('An installed release file has been replaced by a directory.')
                result[target] = package / name
    prompt = package / 'web/app/pbx_setup/resources/prompts/openweb.xml'
    if prompt.is_file():
        result[Path('/etc/freeswitch/languages/en/ivr/openweb.xml')] = prompt
    for helper in ['configure-sip-tls.py', 'configure-sip-tls.php', 'upgrade.py', 'verify_feed.py', 'release-public.pem']:
        if helper in manifest['files']:
            result[TOOLS / helper] = package / helper
    for service in ['openwebpbx-updater.service', 'openwebpbx-update-recovery.service']:
        if service in manifest['files']:
            result[Path('/etc/systemd/system') / service] = package / service
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
    channels = json.loads(engine_api(settings, 'show channels as json'))
    if int(data.get('row_count', -1)) != 0 or int(channels.get('row_count', -1)) != 0:
        raise Deferred('Calls are active. The update will wait until they finish.')


def atomic_copy(source, target, metadata=None):
    if target.is_file() and source.stat().st_size==target.stat().st_size:
        with source.open('rb') as a,target.open('rb') as b:
            identical=hashlib.file_digest(a,'sha256').digest()==hashlib.file_digest(b,'sha256').digest()
        st=target.stat()
        if identical and (metadata is None or (st.st_mode&0o777==metadata['mode'] and st.st_uid==metadata['uid'] and st.st_gid==metadata['gid'])):
            return
    absent = []
    parent = target.parent
    while not parent.exists():
        absent.append(parent)
        parent = parent.parent
    for directory in reversed(absent):
        directory.mkdir()
        directory.chmod(0o755)
        fsync_directory(directory.parent)
    previous = target.stat() if target.exists() else None
    with tempfile.NamedTemporaryFile(prefix='.openweb-update-', dir=target.parent, delete=False) as handle:
        temporary = Path(handle.name)
    try:
        shutil.copyfile(source, temporary)
        executable = target.name in {'OpenWebPbx.Server', 'OpenWebPbx.Updater'}
        temporary.chmod((previous.st_mode & 0o777) if previous else (0o755 if executable else 0o644))
        os.chown(temporary, previous.st_uid if previous else 0, previous.st_gid if previous else 0)
        if metadata:
            temporary.chmod(metadata['mode'])
            os.chown(temporary, metadata['uid'], metadata['gid'])
        with temporary.open('rb') as ready:
            os.fsync(ready.fileno())
        os.replace(temporary, target)
        fsync_directory(target.parent)
    finally:
        temporary.unlink(missing_ok=True)


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)


def durable_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.journal-', mode='w', delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(value, handle, sort_keys=True)
        handle.flush(); os.fsync(handle.fileno())
    temporary.chmod(0o600)
    os.replace(temporary, path)
    fsync_directory(path.parent)


def save_journal(journal, state, **fields):
    journal.update(state=state, updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), **fields)
    durable_json(JOURNAL, journal)


def trusted_file(path):
    path = Path(path)
    for item in [path, *path.parents]:
        if item.is_symlink() or item.stat().st_uid != 0 or item.stat().st_mode & 0o022:
            raise ValueError('Update inputs and parent directories must be root-owned and not writable by other accounts.')
    if not path.is_file(): raise ValueError('The update input must be an ordinary file.')
    return path


def feed_module():
    module_path = Path(__file__).with_name('verify_feed.py')
    if not module_path.is_file():
        module_path = Path(__file__).resolve().parent.parent / 'updates/verify_feed.py'
    spec = importlib.util.spec_from_file_location('openweb_verify_feed', module_path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def prepare_candidate(archive, envelope, target_version, installed_version, *, persist=False):
    verifier = feed_module()
    key = PUBLIC_KEY if PUBLIC_KEY.is_file() else Path(__file__).resolve().parent.parent / 'updates/release-public.pem'
    trusted_file(key); archive = trusted_file(archive); envelope = trusted_file(envelope)
    if envelope.stat().st_size > verifier.MAX_ENVELOPE: raise ValueError('The update feed is too large.')
    trust_file = UPDATES / 'helper-trust.json'
    previous = json.loads(trust_file.read_text()) if trust_file.exists() else None
    payload, digest = verifier.verify(envelope.read_bytes(), key, previous=previous)
    asset = verifier.select_asset(payload, 'debian13-amd64', installed_version, target_version)
    if archive.stat().st_size != asset['bytes']: raise ValueError('The downloaded update has the wrong size.')
    with archive.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != asset['sha256']:
            raise ValueError('The downloaded update checksum is invalid.')
    staging = UPDATES / 'staging'
    staging.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder = Path(tempfile.mkdtemp(prefix='verified-', dir=staging))
    prefix = 'openwebpbx-' + target_version + '-debian13-amd64'
    try:
        with tarfile.open(archive) as source:
            seen = set(); total = 0; members = []
            for member in source:
                name = PurePosixPath(member.name)
                if name.as_posix() in seen or name.is_absolute() or '..' in name.parts or '\\' in member.name or not name.parts or name.parts[0] != prefix:
                    raise ValueError('The update archive contains unsafe or duplicate paths.')
                if not member.isfile() and not member.isdir():
                    raise ValueError('Links and special files are not allowed in an update archive.')
                if member.size < 0 or member.size > 1024 ** 3: raise ValueError('An update file exceeds its size limit.')
                total += member.size; seen.add(name.as_posix()); members.append(member)
                if total > 8 * 1024 ** 3 or len(members) > 50000: raise ValueError('The extracted update exceeds its size limit.')
            for member in members:
                target = folder / member.name
                if member.isdir(): target.mkdir(parents=True, exist_ok=True, mode=0o700)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    with source.extractfile(member) as incoming, target.open('xb') as output:
                        shutil.copyfileobj(incoming, output)
                    target.chmod(0o600)
        package = folder / prefix
        manifest = validate_manifest(package)
        if manifest['version'] != target_version: raise ValueError('The archive version differs from the signed feed.')
        if 'updater/OpenWebPbx.Updater' not in manifest['files']: raise ValueError('The independent updater is missing from the release.')
        if persist: durable_json(trust_file, {'sequence':payload['sequence'], 'payload_sha256':digest})
        return package, manifest, {'sequence':payload['sequence'], 'payload_sha256':digest}
    except BaseException:
        shutil.rmtree(folder)
        raise


def database_command(settings, executable='psql'):
    return [executable, '-h', settings.get('database.0.host', '127.0.0.1'), '-p', settings.get('database.0.port', '5432'),
            '-U', settings['database.0.username'], '-d', settings['database.0.name'], '-w']


def database_environment(settings):
    return os.environ | {'PGPASSWORD':settings.get('database.0.password', ''), 'PGSSLMODE':settings.get('database.0.sslmode', 'prefer')}


def database_json(settings, query):
    response = subprocess.run(database_command(settings) + ['-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', query],
        env=database_environment(settings), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if response.returncode: raise RuntimeError('The application database could not complete an update readiness check.')
    return json.loads(response.stdout)


def database_preflight(settings):
    # This release deliberately supports the standard instance-owned application
    # database. Refuse custom owners/extensions before stopping a working PBX.
    inventory = database_json(settings, """select json_build_object(
        'database',current_database(),'database_oid',d.oid,'owner',pg_get_userbyid(d.datdba),'user',current_user,
        'superuser',(select rolsuper from pg_roles where rolname=current_user),
        'schemas',(select json_agg(json_build_object('name',nspname,'owner',pg_get_userbyid(nspowner),
            'acl',coalesce(nspacl::text,''),'comment',coalesce(obj_description(oid,'pg_namespace'),'')))
            from pg_namespace where nspname not in ('information_schema') and nspname !~ '^pg_'),
        'extensions',(select json_agg(extname) from pg_extension),
        'large_objects',(select count(*) from pg_largeobject_metadata),
        'foreign_owners',(select count(*) from (
            select relowner as owner from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
            union all select proowner from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
            union all select typowner from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public'
        ) owned where pg_get_userbyid(owner)<>current_user),
        'public_grants',(select json_agg(json_build_object('grantee',case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end,
            'privilege',a.privilege_type,'grantable',a.is_grantable)) from pg_namespace n,
            lateral aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a where n.nspname='public')
        ) from pg_database d where d.datname=current_database()""")
    schemas = inventory['schemas'] or []
    if (inventory['owner'] != inventory['user'] and not inventory['superuser']) or inventory['database'] != settings['database.0.name']:
        raise ValueError('Automatic recovery requires database ownership or an already privileged application account.')
    if len(schemas) != 1 or schemas[0]['name'] != 'public' or schemas[0]['owner'] not in (inventory['user'], 'pg_database_owner'):
        raise ValueError('This update requires the standard instance-owned public schema; custom schema layouts need administrator-managed migration.')
    if set(inventory['extensions'] or []) - {'plpgsql'} or inventory['large_objects'] or (inventory['foreign_owners'] and not inventory['superuser']):
        raise ValueError('This update cannot safely recover custom database extensions, large objects or foreign-owned application objects.')
    return inventory


def sql_identifier(value):
    return '"' + value.replace('"', '""') + '"'


def snapshot_database(settings, backup, run):
    temporary = backup / 'database.next.dump'
    run(database_command(settings, 'pg_dump') + ['-Fc', '-f', str(temporary)], env=database_environment(settings))
    run(['pg_restore', '--list', str(temporary)])
    with temporary.open('rb') as stream: os.fsync(stream.fileno())
    destination=backup/('database-final.dump' if (backup/'database.dump').exists() else 'database.dump')
    os.replace(temporary, destination); fsync_directory(backup)
    refresh_backup_integrity(backup)


def restore_database(settings, backup, journal, run):
    previous = json.loads((backup / 'database-layout.json').read_text())
    identity = database_json(settings, "select json_build_object('database',current_database(),'database_oid',d.oid,'user',current_user) from pg_database d where datname=current_database()")
    if any(identity[field] != previous[field] for field in ['database', 'database_oid', 'user']):
        raise RecoveryRequired('Recovery refused a different database identity. The private backup remains available.')
    schemas = database_json(settings, "select coalesce(json_agg(nspname),'[]'::json) from pg_namespace where nspname<>'information_schema' and nspname !~ '^pg_'")
    extensions=database_json(settings,"select coalesce(json_agg(extname),'[]'::json) from pg_extension where extname<>'plpgsql'")
    reset = 'SET standard_conforming_strings=on;\n'
    reset += ''.join('DROP EXTENSION '+sql_identifier(name)+' CASCADE;\n' for name in extensions)
    reset += ''.join('DROP SCHEMA '+sql_identifier(name)+' CASCADE;\n' for name in schemas)
    reset += 'SELECT lo_unlink(oid) FROM pg_largeobject_metadata;\n'
    schema = previous['schemas'][0]
    listing = subprocess.check_output(['pg_restore', '--list', str(database_archive(backup))], text=True)
    if not re.search(r' SCHEMA - public ', listing):
        reset += 'CREATE SCHEMA public AUTHORIZATION '+sql_identifier(schema['owner'])+';\n'
        reset += 'REVOKE ALL ON SCHEMA public FROM PUBLIC;\n'
        for grant in previous['public_grants'] or []:
            grantee = 'PUBLIC' if grant['grantee']=='PUBLIC' else sql_identifier(grant['grantee'])
            if grant['privilege'] not in {'CREATE', 'USAGE'}: raise RecoveryRequired('Unknown schema privilege in private backup.')
            reset += 'GRANT '+grant['privilege']+' ON SCHEMA public TO '+grantee+(' WITH GRANT OPTION' if grant['grantable'] else '')+';\n'
        reset += "COMMENT ON SCHEMA public IS '"+schema['comment'].replace("'","''")+"';\n"
    (backup / 'schema-reset.sql').write_text(reset)
    run(['pg_restore', '--file', str(backup / 'restore.sql'), str(database_archive(backup))])
    # One transaction covers deleting migration-created objects and restoring the
    # complete prior schema, data, ownership and grants in this same database.
    run(database_command(settings) + ['-X','-v','ON_ERROR_STOP=1','--single-transaction',
        '-f',str(backup/'schema-reset.sql'),'-f',str(backup/'restore.sql')], env=database_environment(settings))
    (backup / 'restore.sql').unlink(missing_ok=True); (backup / 'schema-reset.sql').unlink(missing_ok=True)


def refresh_backup_integrity(backup):
    files = ['files.json', 'database-layout.json', 'private-configuration.tar.gz',
             'database-final.dump' if (backup/'database-final.dump').exists() else 'database.dump']
    integrity = {}
    for name in files:
        with (backup/name).open('rb') as stream:
            integrity[name] = hashlib.file_digest(stream,'sha256').hexdigest()
    durable_json(backup/'integrity.json',integrity)


def database_archive(backup):
    integrity=json.loads((backup/'integrity.json').read_text())
    return backup/('database-final.dump' if 'database-final.dump' in integrity else 'database.dump')


def validate_backup(backup):
    integrity=json.loads(trusted_file(backup/'integrity.json').read_text())
    required={'files.json','database-layout.json','private-configuration.tar.gz','database.dump'}
    if 'database-final.dump' in integrity:required=(required-{'database.dump'})|{'database-final.dump'}
    if set(integrity)!=required: raise RecoveryRequired('The private backup inventory is incomplete.')
    for name,expected in integrity.items():
        with trusted_file(backup/name).open('rb') as stream:
            if hashlib.file_digest(stream,'sha256').hexdigest()!=expected:
                raise RecoveryRequired('A private recovery backup failed its checksum check.')
    for entry in json.loads((backup/'files.json').read_text()):
        if entry['exists']:
            with trusted_file(backup/'files'/Path(entry['path']).relative_to('/')).open('rb') as stream:
                if hashlib.file_digest(stream,'sha256').hexdigest()!=entry['sha256']:
                    raise RecoveryRequired('A private application backup failed its checksum check.')


def restore_private_configuration(backup):
    # This archive was generated locally, remains root-only, and was checked
    # against its durable digest. Preserve ownership, modes and existing links.
    archive=backup/'private-configuration.tar.gz'
    with tarfile.open(archive) as source:
        for member in source:
            path=PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or len(path.parts)<2 or path.parts[:2] not in {('etc','fusionpbx'),('etc','openwebpbx'),('etc','freeswitch')}:
                raise RecoveryRequired('The private configuration backup has an invalid path.')
        saved={Path('/')/member.name for member in source.getmembers()}
        for directory in [Path('/etc/fusionpbx'),Path('/etc/openwebpbx'),Path('/etc/freeswitch')]:
            for path in sorted(directory.rglob('*'),key=lambda p:len(p.parts),reverse=True):
                if path not in saved:
                    if path.is_dir() and not path.is_symlink():path.rmdir()
                    else:path.unlink()
        source.extractall('/',filter='fully_trusted')
        for path in saved:
            if path.is_file() and not path.is_symlink():
                with path.open('rb') as stream:os.fsync(stream.fileno())
        for path in sorted((p for p in saved if p.is_dir() and not p.is_symlink()),key=lambda p:len(p.parts),reverse=True):fsync_directory(path)
        fsync_directory(Path('/etc'))


def ensure_recovery_integration():
    stable=Path('/opt/openwebpbx/recovery')
    stable.mkdir(parents=True,exist_ok=True,mode=0o755)
    atomic_copy(Path(__file__).resolve(),stable/'upgrade.py')
    unit=Path('/etc/systemd/system/openwebpbx-update-recovery.service')
    unit.write_text('[Unit]\nDescription=Recover an interrupted OpenWeb PBX update\nAfter=network-online.target postgresql.service\nWants=network-online.target postgresql.service\nBefore=freeswitch.service php8.4-fpm.service openwebpbx.service openwebpbx-updater.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/bin/python3 /opt/openwebpbx/recovery/upgrade.py --recover --boot\nTimeoutStartSec=1800\n\n[Install]\nWantedBy=multi-user.target\n')
    unit.chmod(0o644)
    with unit.open('rb') as stream:os.fsync(stream.fileno())
    fsync_directory(unit.parent)
    service_dropins()
    subprocess.run(['systemctl','daemon-reload'],check=True)
    # The boot helper sees our exclusive lock and exits successfully: this
    # already-running updater owns recovery until it completes or is interrupted.
    subprocess.run(['systemctl','start','openwebpbx-update-recovery'],check=True)
    subprocess.run(['systemctl','enable','openwebpbx-update-recovery'],check=True,stdout=subprocess.DEVNULL)


def service_dropins():
    for service in SERVICES:
        folder = Path('/etc/systemd/system') / (service+'.service.d')
        folder.mkdir(parents=True, exist_ok=True)
        text = '[Unit]\nRequires=openwebpbx-update-recovery.service\nAfter=openwebpbx-update-recovery.service\nConditionPathExists=!'+str(MAINTENANCE)+'\n'
        path = folder/'openweb-update-recovery.conf'; path.write_text(text); path.chmod(0o644)
        with path.open('rb') as stream:os.fsync(stream.fileno())
        fsync_directory(folder);fsync_directory(folder.parent)


def set_maintenance(enabled):
    if enabled:
        durable_json(MAINTENANCE, {'maintenance':True})
    else:
        MAINTENANCE.unlink(missing_ok=True); fsync_directory(UPDATES)


def restore_files(backup):
    entries = json.loads((backup/'files.json').read_text())
    for entry in entries:
        target = Path(entry['path'])
        if entry['exists']:
            saved = backup/'files'/target.relative_to('/')
            with saved.open('rb') as stream:
                if hashlib.file_digest(stream,'sha256').hexdigest()!=entry['sha256']:
                    raise RecoveryRequired('A private application backup failed its checksum check.')
            atomic_copy(saved, target, entry)
        else:
            target.unlink(missing_ok=True)
            if target.parent.exists():fsync_directory(target.parent)


def restore_updater_slot(journal):
    link = UPDATER/'current'
    previous = journal.get('previous_updater_slot')
    if previous:
        temporary = UPDATER/('.current-'+uuid.uuid4().hex)
        temporary.symlink_to(previous); os.replace(temporary, link); fsync_directory(UPDATER)
    elif link.is_symlink():
        link.unlink();fsync_directory(UPDATER)


def clear_cache(settings):
    cache=Path(settings.get('cache.location','/var/cache/fusionpbx'))
    if cache.is_dir() and not cache.is_symlink() and cache.resolve().is_relative_to('/var/cache'):
        for item in cache.iterdir():
            if item.is_file() and not item.is_symlink():item.unlink()


def start_and_health(version, settings, run):
    set_maintenance(False)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'start', 'freeswitch', 'php8.4-fpm', 'openwebpbx'])
    for attempt in range(30):
        try:
            with urllib.request.urlopen('http://127.0.0.1:8087/health', timeout=3) as response: health=json.load(response)
            if health.get('state')=='Running' and health.get('version')==version: break
        except (OSError,ValueError): pass
        time.sleep(2)
    else: raise RuntimeError('The updated background service did not become ready.')
    for service in SERVICES: run(['systemctl','is-active','--quiet',service])
    probe='require "/var/www/fusionpbx/resources/require.php"; database::new()->db->query("select count(*) from v_domains")->fetchColumn();'
    run(['php','-r',probe],cwd=WEB)


def recover(journal, *, boot=False):
    backup = Path(journal['backup_path'])
    if not backup.is_relative_to(BACKUPS) or backup.is_symlink(): raise RecoveryRequired('The private recovery path is invalid.')
    trusted_file(backup/'files.json')
    validate_backup(backup)
    with (backup/'upgrade.log').open('a') as log:
        def run(command, **kwargs): subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT,**kwargs)
        try:
            interrupted=journal['state']
            set_maintenance(True)
            if not boot: run(['systemctl','stop',*SERVICES])
            save_journal(journal,'rolling_back',rollback_from=journal.get('rollback_from',interrupted))
            if journal['rollback_from'] not in {'prepared','quiescing'}:
                restore_files(backup)
                restore_private_configuration(backup)
                settings=read_settings()
                if boot:
                    for attempt in range(60):
                        try:
                            database_json(settings, 'select to_json(true)'); break
                        except (RuntimeError, OSError, subprocess.TimeoutExpired): time.sleep(2)
                    else: raise RecoveryRequired('The configured database is unavailable; recovery remains pending.')
                restore_database(settings,backup,journal,run)
            else:settings=read_settings()
            restore_updater_slot(journal)
            clear_cache(settings)
            run(['systemctl','daemon-reload'])
            if not boot: start_and_health(journal['previous_version'],settings,run)
            else: set_maintenance(False)
            save_journal(journal,'rolled_back')
        except BaseException:
            set_maintenance(True)
            save_journal(journal,'recovery_required',error='Automatic recovery needs administrator attention.')
            raise RecoveryRequired('Automatic recovery needs attention. The PBX remains in maintenance; keep the private backup.') from None


def make_backup(targets, settings, manifest, layout):
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8]
    backup=BACKUPS/('upgrade-'+stamp);backup.mkdir(parents=True,mode=0o700)
    entries=[]
    for target in targets:
        item={'path':str(target),'exists':target.is_file()}
        if item['exists']:
            st=target.stat();saved=backup/'files'/target.relative_to('/')
            saved.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(target,saved)
            with saved.open('rb') as stream:item['sha256']=hashlib.file_digest(stream,'sha256').hexdigest();os.fsync(stream.fileno())
            item.update(mode=st.st_mode&0o777,uid=st.st_uid,gid=st.st_gid)
        entries.append(item)
    durable_json(backup/'files.json',entries);durable_json(backup/'database-layout.json',layout)
    with tarfile.open(backup/'private-configuration.tar.gz','w:gz') as output:
        for directory in ['/etc/fusionpbx','/etc/openwebpbx','/etc/freeswitch']:
            if Path(directory).is_dir():output.add(directory,arcname=directory.lstrip('/'))
    with (backup/'private-configuration.tar.gz').open('rb') as stream:os.fsync(stream.fileno())
    with (backup/'upgrade.log').open('a') as log:
        def run(command,**kwargs):subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT,**kwargs)
        snapshot_database(settings,backup,run)
    for directory in sorted((p for p in (backup/'files').rglob('*') if p.is_dir()),key=lambda p:len(p.parts),reverse=True):fsync_directory(directory)
    fsync_directory(backup/'files');fsync_directory(backup);fsync_directory(BACKUPS)
    return backup


def maintenance_window(settings, automatic):
    if automatic:
        policy=database_json(settings,"select row_to_json(p) from v_pbx_update_policies p where scope_key='instance'")
        hour=datetime.datetime.now(datetime.timezone.utc).hour
        if not policy or policy['mode']!='automatic' or (hour-policy['maintenance_hour'])%24>=policy['maintenance_duration']:
            raise Deferred('Automatic updates are waiting for the configured maintenance window.')


def install_candidate(package,manifest,trust,settings,*,automatic=False):
    maintenance_window(settings, automatic)
    targets=deployment_files(package,manifest)
    for service in SERVICES:subprocess.run(['systemctl','is-active','--quiet',service],check=True)
    check_idle(settings);layout=database_preflight(settings)
    updater=package/'updater';slot=UPDATER/'slots'/manifest['version']
    if slot.exists():
        active=(UPDATER/'current').resolve() if (UPDATER/'current').exists() else None
        if active==slot.resolve():raise ValueError('The target updater slot is already active.')
        shutil.rmtree(slot)
    ensure_recovery_integration()
    backup=make_backup(targets,settings,manifest,layout)
    journal={'schema':1,'version':manifest['version'],'previous_version':(WEB/'VERSION').read_text().strip(),
             'backup_path':str(backup),'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'previous_updater_slot':os.readlink(UPDATER/'current') if (UPDATER/'current').is_symlink() else None}
    durable_json(UPDATES/'helper-trust.json',trust)
    save_journal(journal,'prepared')
    with (backup/'upgrade.log').open('a') as log:
        def run(command,**kwargs):subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT,**kwargs)
        stopped=False
        try:
            maintenance_window(settings, automatic)
            check_idle(settings)
            if engine_api(settings,'fsctl pause_check').strip()!='false':raise Deferred('The call engine is already in maintenance.')
            save_journal(journal,'quiescing');set_maintenance(True)
            if not engine_api(settings,'fsctl pause').startswith('+OK'):raise RuntimeError('The call engine could not enter maintenance.')
            try:check_idle(settings)
            except BaseException:
                engine_api(settings,'fsctl resume');raise
            stopped=True
            run(['systemctl','stop',*SERVICES])
            snapshot_database(settings,backup,run)
            save_journal(journal,'deploying')
            for target,source in targets.items():atomic_copy(source,target)
            slot.parent.mkdir(parents=True,exist_ok=True)
            shutil.copytree(updater,slot)
            for path in slot.rglob('*'):
                path.chmod(0o755 if path.is_dir() or path.name=='OpenWebPbx.Updater' else 0o644)
                if path.is_file():
                    with path.open('rb') as stream:os.fsync(stream.fileno())
            for folder in sorted((p for p in slot.rglob('*') if p.is_dir()),key=lambda p:len(p.parts),reverse=True):fsync_directory(folder)
            fsync_directory(slot);fsync_directory(slot.parent)
            service_dropins()
            save_journal(journal,'migrating')
            run(['php',str(package/'bootstrap.php'),str(WEB),'migrate'],cwd=WEB)
            for step in ['--defaults','--group','--menu']:run(['php','core/upgrade/upgrade.php',step],cwd=WEB)
            clear_cache(settings)
            save_journal(journal,'validating')
            start_and_health(manifest['version'],settings,run)
            link=UPDATER/('.current-'+uuid.uuid4().hex);link.symlink_to('slots/'+manifest['version'])
            os.replace(link,UPDATER/'current');fsync_directory(UPDATER)
            run(['systemctl','enable','openwebpbx-updater','openwebpbx-update-recovery'])
            save_journal(journal,'completed')
        except BaseException as failure:
            log.write('Update stage '+journal['state']+' failed ('+type(failure).__name__+').\n');log.flush()
            if not stopped:
                if journal['state']=='quiescing':engine_api(settings,'fsctl resume')
                set_maintenance(False)
                save_journal(journal,'rolled_back')
                raise failure
            recover(journal)
            if slot.exists():shutil.rmtree(slot)
            if isinstance(failure,Deferred):raise failure
            raise RuntimeError('Update failed and the previous application and database were restored. Review the private upgrade log.') from None
    print('OpenWeb PBX '+manifest['version']+' is running; the private backup is '+str(backup))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive',type=Path);parser.add_argument('--feed-envelope',type=Path);parser.add_argument('--target-version')
    parser.add_argument('--check',action='store_true');parser.add_argument('--automatic',action='store_true')
    parser.add_argument('--recover',action='store_true');parser.add_argument('--boot',action='store_true')
    parser.add_argument('--protocol-version',action='store_true')
    args=parser.parse_args()
    if args.protocol_version:print('1');return
    if os.geteuid()!=0:parser.error('Run as root.')
    os.umask(0o077);UPDATES.mkdir(parents=True,exist_ok=True,mode=0o700);UPDATES.chmod(0o700)
    lock=Path('/run/openwebpbx-upgrade.lock').open('a')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:
        if args.recover and args.boot:return
        raise Deferred('Another OpenWeb PBX update or recovery is running.') from None
    previous=json.loads(JOURNAL.read_text()) if JOURNAL.exists() else None
    if previous and previous.get('state') not in TERMINAL:
        recover(previous,boot=args.boot)
        if not args.recover:raise RuntimeError('An interrupted update was recovered. Check the previous update before trying again.')
    if args.recover:
        if not previous or previous.get('state') in TERMINAL:set_maintenance(False)
        return
    if args.boot:parser.error('--boot is only valid with --recover.')
    os_release=Path('/etc/os-release').read_text()
    if not re.search(r'^ID=debian$',os_release,re.M) or not re.search(r'^VERSION_ID="?13"?$',os_release,re.M) or subprocess.check_output(['dpkg','--print-architecture'],text=True).strip()!='amd64':
        parser.error('This update supports Debian 13 amd64 only.')
    if not all([args.archive,args.feed_envelope,args.target_version]):parser.error('Supply --archive, --feed-envelope and --target-version.')
    if not CONFIG.is_file() or not (WEB/'resources/require.php').is_file():parser.error('No installed PBX was found.')
    package,manifest,trust=prepare_candidate(args.archive,args.feed_envelope,args.target_version,(WEB/'VERSION').read_text().strip(),persist=True)
    try:
        settings=read_settings()
        if args.check:
            check_idle(settings);database_preflight(settings)
            print('Signed release '+manifest['version']+' and recovery prerequisites verified. Application services were not changed.')
        else:install_candidate(package,manifest,trust,settings,automatic=args.automatic)
    finally:shutil.rmtree(package.parent)
    if not args.check:
        fcntl.flock(lock,fcntl.LOCK_UN)
        subprocess.run(['systemctl','start','openwebpbx-updater'],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)


if __name__=='__main__':
    try:main()
    except Deferred as error:print(str(error));raise SystemExit(75)
    except RecoveryRequired as error:print(str(error));raise SystemExit(2)
    except (RuntimeError,ValueError,OSError,subprocess.SubprocessError,KeyError,TypeError) as error:
        print(str(error) if isinstance(error,(RuntimeError,ValueError)) else 'Update failed; review the private update log and service status.')
        raise SystemExit(1)
