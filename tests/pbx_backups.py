#!/usr/bin/env python3
"""Real PostgreSQL/crypto/SFTP backup checks using only independent disposable fixtures."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import tarfile
import tempfile
import time
import unittest
import uuid

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

spec = importlib.util.spec_from_file_location('backups', Path(__file__).resolve().parents[1] / 'packaging/debian/backups.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


def postgres(sql):
    r = subprocess.run(['runuser', '-u', 'postgres', '--', 'psql', '-h', '/var/run/postgresql', '-d', 'postgres',
                        '-X', '-w', '-v', 'ON_ERROR_STOP=1', '-q', '-c', sql], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode:
        raise RuntimeError('Fixture database administration failed.')


class Backups(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = Path(tempfile.mkdtemp(prefix='openweb-backup-checks-', dir='/var/lib/openwebpbx'))
        cls.workspace.chmod(0o700)
        suffix = secrets.token_hex(6)
        cls.role = 'openweb_backup_fixture_' + suffix
        cls.source_name = 'openweb_backup_source_' + suffix
        cls.target_name = 'openweb_backup_target_' + suffix
        cls.password = secrets.token_hex(32)
        cls.archive_password = 'DisposableBackupPasswordOnly123'
        postgres('CREATE ROLE "' + cls.role + '" LOGIN PASSWORD ' + b.literal(cls.password))
        for name in (cls.source_name, cls.target_name):
            postgres('CREATE DATABASE "' + name + '" OWNER "' + cls.role + '"')
        cls.source = {'database.0.type': 'pgsql', 'database.0.host': '127.0.0.1', 'database.0.port': os.environ.get('PGPORT', '5432'),
                      'database.0.username': cls.role, 'database.0.password': cls.password, 'database.0.name': cls.source_name,
                      'openweb.public_host': 'pbx.fixture.invalid', 'openweb.public_ip': '192.0.2.10'}
        cls.target = cls.source | {'database.0.name': cls.target_name, 'openweb.public_ip': '198.51.100.22'}
        cls.key = cls.workspace / 'source.key'
        cls.key.write_bytes(os.urandom(32))
        cls.key.chmod(0o600)
        cls.source_roots = {}
        for label in ('fusionpbx-config', 'runtime-config', 'freeswitch-config', 'storage', 'recordings', 'custom-sounds'):
            p = cls.workspace / 'source' / label
            p.mkdir(parents=True, mode=0o700)
            cls.source_roots[label] = p
        config = '\n'.join(key + ' = ' + value for key, value in cls.source.items()) + '\n'
        (cls.source_roots['fusionpbx-config'] / 'config.conf').write_text(config)
        (cls.source_roots['fusionpbx-config'] / 'openweb-template.key').write_bytes(cls.key.read_bytes())
        (cls.source_roots['runtime-config'] / 'runtime.json').write_text(json.dumps({'ConnectionStrings': {'Pbx': 'source-private-connection'}, 'Switch': {'Password': 'fixture-switch-only'}}))
        (cls.source_roots['freeswitch-config'] / 'fixture.xml').write_text('<settings>fixture only</settings>')
        (cls.source_roots['storage'] / 'voicemail.wav').write_bytes(os.urandom(1500))
        (cls.source_roots['recordings'] / 'recording.wav').write_bytes(os.urandom(2100))
        (cls.source_roots['custom-sounds'] / 'welcome.wav').write_bytes(os.urandom(400))
        ddl = """
         CREATE TABLE v_users(user_uuid uuid PRIMARY KEY,username text,user_enabled text);
         CREATE TABLE v_domains(domain_uuid uuid PRIMARY KEY,domain_name text);
         CREATE TABLE v_extensions(id uuid PRIMARY KEY);
         CREATE TABLE v_pbx_tenants(id uuid PRIMARY KEY);
         CREATE TABLE v_pbx_services(id uuid PRIMARY KEY);
         CREATE TABLE v_pbx_restore(id uuid PRIMARY KEY);
         CREATE TABLE v_recordings(id uuid PRIMARY KEY);
         CREATE TABLE v_voicemail_messages(id uuid PRIMARY KEY);
         CREATE TABLE v_voicemails(voicemail_uuid uuid PRIMARY KEY,voicemail_id text,voicemail_password text,greeting_id text);
         CREATE TABLE fixture_objects(kind text PRIMARY KEY,payload text NOT NULL);
         INSERT INTO v_users VALUES(gen_random_uuid(),'factory','true');
         INSERT INTO v_domains VALUES(gen_random_uuid(),'pbx.fixture.invalid');
        """
        for settings in (cls.source, cls.target):
            b.query(settings, ddl)
            # Only the backup-owned tables; permissions are covered by the separate real-PG PHP suite.
            sql = (Path(__file__).resolve().parents[1] / 'app/pbx_backups/resources/install.sql').read_text().split('DO $$')[0]
            b.query(settings, sql + 'COMMIT;')
            b.query(settings, "CREATE TABLE v_pbx_update_commands(status text);")
        b.query(cls.source, "INSERT INTO fixture_objects VALUES('tenant','isolated tenant'),('template','encrypted fixture data'),('job','pending wakeup fixture'),('trunk','disabled fixture provider');")
        b.query(cls.source, 'INSERT INTO v_extensions VALUES(gen_random_uuid());')
        b.query(cls.source, "INSERT INTO v_voicemails VALUES(gen_random_uuid(),'1000','123456','7');")
        cls.archive = cls.workspace / (str(uuid.uuid4()) + '.owpbx')
        cls.original_lock = b.UPGRADE_LOCK
        b.UPGRADE_LOCK = cls.workspace / 'upgrade.lock'
        cls.manifest = b.create_archive(cls.source, cls.archive, cls.archive_password, roots=cls.source_roots, version='1.0.9')
        cls.original_roots, cls.original_media = b.ROOTS, b.MEDIA

    @classmethod
    def tearDownClass(cls):
        b.UPGRADE_LOCK = cls.original_lock
        b.ROOTS, b.MEDIA = cls.original_roots, cls.original_media
        for name in (cls.source_name, cls.target_name):
            postgres('DROP DATABASE IF EXISTS "' + name + '" WITH (FORCE)')
        postgres('DROP ROLE IF EXISTS "' + cls.role + '"')
        shutil.rmtree(cls.workspace)

    def seal(self, text):
        nonce = os.urandom(12)
        key = hashlib.sha256(self.key.read_bytes() + b'/openwebpbx/backups/v1').digest()
        encrypted = AESGCM(key).encrypt(nonce, text.encode(), b'openwebpbx-backup-settings-v1')
        return 'v1:' + base64.b64encode(nonce + encrypted[-16:] + encrypted[:-16]).decode()

    @staticmethod
    def install_voicemail_policy(version):
        source = Path(__file__).resolve().parents[1] / 'app/voicemails/resources/voicemail_without_pins.sql'
        target = version.parent / 'app/voicemails/resources/voicemail_without_pins.sql'
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)

    def test_01_encrypted_archive_and_private_media(self):
        self.assertTrue(self.archive.read_bytes().startswith(b.MAGIC))
        self.assertNotIn(b'fixture-switch-only', self.archive.read_bytes())
        self.assertEqual(self.archive.stat().st_mode & 0o777, 0o600)
        with b.verify_archive(self.archive, self.archive_password) as (files, manifest):
            self.assertEqual(manifest['version'], '1.0.9')
            self.assertEqual((files / 'storage/voicemail.wav').read_bytes(), (self.source_roots['storage'] / 'voicemail.wav').read_bytes())
            self.assertEqual((files / 'fusionpbx-config/openweb-template.key').read_bytes(), self.key.read_bytes())

    def test_02_bad_password_and_tampering(self):
        with self.assertRaisesRegex(b.BackupError, 'wrong|damaged'):
            with b.verify_archive(self.archive, 'WrongFixturePasswordOnly'):
                pass
        damaged = self.workspace / 'damaged.owpbx'
        raw = bytearray(self.archive.read_bytes())
        raw[100] ^= 1
        damaged.write_bytes(raw)
        with self.assertRaisesRegex(b.BackupError, 'wrong|damaged'):
            with b.verify_archive(damaged, self.archive_password):
                pass
        damaged.unlink()

    def test_03_settings_envelope(self):
        self.assertEqual(b.unseal(self.seal('fixture passphrase'), self.key), 'fixture passphrase')
        with self.assertRaises(b.BackupError):
            b.unseal('v1:' + base64.b64encode(os.urandom(70)).decode(), self.key)

    def test_04_archive_path_and_link_refusal(self):
        for name in ('/etc/shadow', '../unsafe', 'storage/../unsafe', 'unknown/file', 'storage/a\\b'):
            with self.assertRaises(b.BackupError):
                b.safe_member(name)
        payload = self.workspace / 'linked.tar.gz'
        manifest = json.dumps({'schema': 1, 'platform': 'debian13', 'version': '1.0.9',
            'files': {'database.dump': {'size': 0, 'mode': 0o600, 'sha256': hashlib.sha256(b'').hexdigest()}}}).encode()
        with tarfile.open(payload, 'w:gz') as archive:
            m = tarfile.TarInfo('manifest.json');m.size = len(manifest);archive.addfile(m, io.BytesIO(manifest))
            m = tarfile.TarInfo('database.dump');m.type = tarfile.SYMTYPE;m.linkname = '/etc/shadow';archive.addfile(m)
        output = self.workspace / 'linked-output';output.mkdir()
        with self.assertRaises(b.BackupError):
            b.extract_verified(payload, output)
        shutil.rmtree(output);payload.unlink()

    def test_05_inventory_symlink_and_size_refusal(self):
        root = self.workspace / 'unsafe-root';root.mkdir()
        (root / 'link').symlink_to(self.key)
        with self.assertRaises(b.BackupError):
            b.file_inventory({'fusionpbx-config': root})
        (root / 'link').unlink();root.rmdir()
        old = b.MAX_ARCHIVE
        b.MAX_ARCHIVE = 10
        try:
            with self.assertRaises(b.BackupError):
                with b.verify_archive(self.archive, self.archive_password):
                    pass
        finally:
            b.MAX_ARCHIVE = old

    def test_06_real_database_restore_and_identity(self):
        with b.verify_archive(self.archive, self.archive_password) as (files, _):
            work = self.workspace / 'database-restore';work.mkdir()
            b.restore_database(self.target, files / 'database.dump', work)
            self.assertEqual(b.query(self.target, 'select count(*) from fixture_objects'), '4')
            self.assertEqual(b.query(self.target, 'select current_database()'), self.target_name)
            self.assertEqual(b.query(self.target, 'select current_user'), self.role)
            self.assertEqual(b.query(self.target, 'select count(*) from v_extensions'), '1')
            shutil.rmtree(work)
        # Return target to factory state for the guarded full-restore tests.
        b.query(self.target, 'delete from v_extensions;delete from fixture_objects;')

    def test_07_populated_target_refused(self):
        b.target_is_factory(self.target)
        with self.assertRaisesRegex(b.BackupError, 'local PostgreSQL'):
            b.target_is_factory(self.target | {'database.0.host': 'remote-database.example.invalid'})
        b.query(self.target, 'insert into v_pbx_tenants values(gen_random_uuid());')
        try:
            with self.assertRaisesRegex(b.BackupError, 'fresh installation'):
                b.target_is_factory(self.target)
        finally:
            b.query(self.target, 'delete from v_pbx_tenants;')
        # A sole initial owner can use Meet before adding any phone/tenant.
        # Missing legacy tables remain supported; empty new tables are factory.
        for table in ('v_pbx_meetings','v_pbx_meeting_members'):
            b.query(self.target,'create table '+table+'(id uuid primary key)')
            try:
                b.target_is_factory(self.target)
                b.query(self.target,'insert into '+table+' values(gen_random_uuid())')
                with self.assertRaisesRegex(b.BackupError,'fresh installation'):
                    b.target_is_factory(self.target)
            finally:
                b.query(self.target,'drop table '+table)
        b.target_is_factory(self.target)

    def test_08_worker_requests_and_retention(self):
        store = self.workspace / 'worker-store';downloads = self.workspace / 'worker-downloads'
        b.query(self.source, "update v_pbx_backup_settings set passphrase_secret=" + b.literal(self.seal(self.archive_password)) + ',retention=2,include_media=true;')
        for _ in range(3):
            b.query(self.source, "insert into v_pbx_backup_commands(command_uuid,action) values(gen_random_uuid(),'create')")
            b.worker(self.source, store=store, downloads=downloads, roots=self.source_roots, version='1.0.9', key_file=self.key)
        self.assertEqual(b.query(self.source, "select count(*) from v_pbx_backups where status='ready'"), '2')
        self.assertEqual(len(list(store.glob('*.owpbx'))), 2)
        self.assertEqual(len(list(downloads.glob('*.owpbx'))), 2)
        self.assertEqual(b.query(self.source, "select count(*) from v_pbx_backup_commands where status='completed'"), '3')
        latest = b.query(self.source, "select backup_uuid from v_pbx_backups order by completed_at desc limit 1")
        b.query(self.source, "insert into v_pbx_backup_commands(command_uuid,action,backup_uuid) values(gen_random_uuid(),'verify'," + b.literal(latest) + '::uuid)')
        b.worker(self.source, store=store, downloads=downloads, roots=self.source_roots, version='1.0.9', key_file=self.key)
        self.assertEqual(b.query(self.source, "select count(*) from v_pbx_backup_commands where action='verify' and status='completed'"), '1')

    def test_09_worker_crash_recovery_and_daily_schedule(self):
        store = self.workspace / 'worker-store';downloads = self.workspace / 'worker-downloads'
        b.query(self.source, "insert into v_pbx_backup_commands(command_uuid,action,status) values(gen_random_uuid(),'create','running')")
        b.query(self.source, "update v_pbx_backup_settings set enabled=true,schedule_hour=0,last_scheduled_date=null")
        b.worker(self.source, store=store, downloads=downloads, roots=self.source_roots, version='1.0.9', key_file=self.key)
        self.assertEqual(b.query(self.source, "select count(*) from v_pbx_backup_commands where status='running'"), '0')
        self.assertEqual(b.query(self.source, "select count(*) from v_pbx_backup_commands where status='failed'"), '1')
        count = b.query(self.source, 'select count(*) from v_pbx_backup_commands')
        b.worker(self.source, store=store, downloads=downloads, roots=self.source_roots, version='1.0.9', key_file=self.key)
        self.assertEqual(b.query(self.source, 'select count(*) from v_pbx_backup_commands'), count)
        b.query(self.source, 'update v_pbx_backup_settings set enabled=false')

    def test_10_guarded_full_restore_and_interruption_recovery(self):
        target_root = self.workspace / 'full-target'
        roots = {}
        for label in self.source_roots:
            p = target_root / label;p.mkdir(parents=True)
            roots[label] = p
        config = roots['fusionpbx-config'] / 'config.conf'
        config.write_text('\n'.join(key + ' = ' + value for key, value in self.target.items()) + '\n')
        (roots['fusionpbx-config'] / 'openweb-template.key').write_bytes(os.urandom(32))
        runtime = roots['runtime-config'] / 'runtime.json';runtime.write_text(json.dumps({'ConnectionStrings': {'Pbx': 'target'}}))
        old = {key: getattr(b, key) for key in ('ROOTS', 'MEDIA', 'RESTORE', 'WEB_VERSION', 'running_services', 'UNIT_ROOT', 'STORE', 'CACHE')}
        try:
            b.ROOTS = {key: value for key, value in roots.items() if key not in self.original_media}
            b.MEDIA = {key: value for key, value in roots.items() if key in self.original_media}
            b.RESTORE = self.workspace / 'restore-journal'
            b.STORE = self.workspace / 'restore-lock-store'
            b.UNIT_ROOT = self.workspace / 'fixture-units';b.UNIT_ROOT.mkdir()
            b.WEB_VERSION = self.workspace / 'target-version';b.WEB_VERSION.write_text('1.0.9')
            self.install_voicemail_policy(b.WEB_VERSION)
            b.running_services = lambda: []  # Never touch any host production service.
            b.CACHE = self.workspace / 'restore-fixture-cache'
            dry = b.restore(self.archive, self.archive_password, self.target, dry_run=True)
            self.assertEqual(dry['version'], '1.0.9')
            self.assertFalse((b.RESTORE / 'journal.json').exists())
            with self.assertRaises(b.BackupError):
                b.restore(self.archive, self.archive_password, self.target, confirm_database='wrong-target')
            b.restore(self.archive, self.archive_password, self.target, confirm_database=self.target_name)
            self.assertEqual(b.read_settings(config)['database.0.name'], self.target_name)
            self.assertEqual(b.read_settings(config)['database.0.password'], self.password)
            self.assertEqual(b.read_settings(config)['openweb.public_ip'], '198.51.100.22')
            self.assertEqual((roots['fusionpbx-config'] / 'openweb-template.key').read_bytes(), self.key.read_bytes())
            self.assertEqual((roots['recordings'] / 'recording.wav').read_bytes(), (self.source_roots['recordings'] / 'recording.wav').read_bytes())
            self.assertEqual(b.query(self.target, "select payload from fixture_objects where kind='tenant'"), 'isolated tenant')
            self.assertEqual(b.query(self.target, "select greeting_id from v_voicemails where voicemail_id='1000' and voicemail_password is null"), '7')
            b.query(self.target, "update v_voicemails set voicemail_password='999999' where voicemail_id='1000'")
            self.assertEqual(b.query(self.target, "select count(*) from v_voicemails where voicemail_password is not null"), '0')
            self.assertIn('Database="' + self.target_name + '"', json.loads(runtime.read_text())['ConnectionStrings']['Pbx'])
            with self.assertRaises(b.BackupError):
                b.recover(self.target)  # A completed restore must not be silently undone.
            # Simulate an interrupted database/file restore and prove exact factory rollback.
            journal = json.loads((b.RESTORE / 'journal.json').read_text())
            journal['state'] = 'restoring';b.atomic_json(b.RESTORE / 'journal.json', journal)
            b.recover(self.target)
            self.assertEqual(b.query(self.target, 'select count(*) from fixture_objects'), '0')
            self.assertEqual(b.query(self.target, 'select count(*) from v_extensions'), '0')
            self.assertFalse((roots['recordings'] / 'recording.wav').exists())
            self.assertEqual(json.loads((b.RESTORE / 'journal.json').read_text())['state'], 'recovered')
        finally:
            for key, value in old.items():
                setattr(b, key, value)

    def test_11_sftp_roundtrip_host_pin_and_failure(self):
        if not shutil.which('sshd'):
            self.skipTest('OpenSSH server is not installed for an isolated loopback SFTP fixture.')
        work = self.workspace / 'ssh-fixture';work.mkdir()
        for name in ('server', 'client', 'wrong-server'):
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(work / name)], check=True)
        server_key = (work / 'server.pub').read_text().split()
        wrong_key = (work / 'wrong-server.pub').read_text().split()
        (work / 'authorized_keys').write_text((work / 'client.pub').read_text());(work / 'authorized_keys').chmod(0o600)
        remote = work / 'remote';remote.mkdir()
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0));port = s.getsockname()[1]
        (work / 'sshd_config').write_text('\n'.join([
            'ListenAddress 127.0.0.1', 'Port ' + str(port), 'HostKey ' + str(work / 'server'),
            'PidFile ' + str(work / 'sshd.pid'), 'AuthorizedKeysFile ' + str(work / 'authorized_keys'),
            'StrictModes no', 'PermitRootLogin prohibit-password', 'PasswordAuthentication no',
            'KbdInteractiveAuthentication no', 'UsePAM no', 'Subsystem sftp internal-sftp', 'LogLevel QUIET']))
        process = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(work / 'sshd_config')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(30):
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.2):
                        break
                except OSError:
                    time.sleep(.1)
            cfg = {'sftp_host': '127.0.0.1', 'sftp_port': port, 'sftp_user': 'root', 'sftp_directory': str(remote),
                   'sftp_host_key': ' '.join(server_key[:2])}
            identity = (work / 'client').read_text()
            b.upload_sftp(self.archive, cfg, identity)
            self.assertEqual(b.checksum(remote / self.archive.name), b.checksum(self.archive))
            self.assertFalse(list(remote.glob('*.uploading')))
            with self.assertRaises(b.BackupError):
                b.upload_sftp(self.archive, cfg | {'sftp_host_key': ' '.join(wrong_key[:2])}, identity)
            with self.assertRaises(b.BackupError):
                b.upload_sftp(self.archive, cfg | {'sftp_directory': '/does/not/exist/fixture'}, identity)
            with self.assertRaises(b.BackupError):
                b.upload_sftp(self.archive, cfg | {'sftp_user': 'root;uname'}, identity)
        finally:
            process.terminate()
            process.wait(timeout=10)
            shutil.rmtree(work)

    def test_12_restore_hold_survives_reboot_and_requires_explicit_activation(self):
        old = {key: getattr(b, key) for key in ('RESTORE', 'UNIT_ROOT', 'run')}
        commands = []
        try:
            b.RESTORE = self.workspace/'hold-restore';b.RESTORE.mkdir()
            b.UNIT_ROOT = self.workspace/'hold-units';b.UNIT_ROOT.mkdir()
            for unit in b.HELD_UNITS.values():
                (b.UNIT_ROOT/unit).write_text('[Unit]\nDescription=Isolated restore fixture\n')
            original_run = b.run
            def fixture_run(command, **kwargs):
                if command[0] == 'systemctl':
                    commands.append(command)
                    return b''  # No shared host service is changed by this fixture.
                return original_run(command, **kwargs)
            b.run = fixture_run
            gates = b.plan_service_holds();b.install_service_holds(gates)
            marker = b.RESTORE/'hold-freeswitch.service'
            self.assertTrue(marker.is_file())
            condition = 'ConditionPathExists=!'+str(marker)
            self.assertIn(condition, (b.UNIT_ROOT/'freeswitch.service.d/99-openwebpbx-restore.conf').read_text())
            # Actual systemd condition evaluation proves a persisted marker blocks restart/boot.
            result = subprocess.run(['systemd-analyze', 'condition', condition], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            journal = {'state':'restored','source_host':'pbx.fixture.invalid','gates':gates}
            b.atomic_json(b.RESTORE/'journal.json', journal)
            with self.assertRaises(b.BackupError):
                b.activate(self.target, ['calls'], 'wrong.fixture.invalid')
            b.activate(self.target, ['calls'], 'pbx.fixture.invalid')
            self.assertFalse(marker.exists())
            self.assertTrue((b.RESTORE/'hold-openwebpbx.service').exists())
            result = subprocess.run(['systemd-analyze', 'condition', condition], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0)
            b.remove_service_holds(gates)
            self.assertFalse(list(b.RESTORE.glob('hold-*')))
        finally:
            for key, value in old.items():
                setattr(b, key, value)

    def test_13_worker_keeps_local_backup_when_sftp_connection_fails(self):
        key = self.workspace/'failed-remote-key'
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True)
        public = ' '.join((self.workspace/'failed-remote-key.pub').read_text().split()[:2])
        b.query(self.source,"update v_pbx_backup_settings set sftp_enabled=true,sftp_host='127.0.0.1',sftp_port=1,sftp_user='root',sftp_directory='/fixture-backup-folder',sftp_host_key="+b.literal(public)+',sftp_identity_secret='+b.literal(self.seal(key.read_text())))
        request=str(uuid.uuid4())
        b.query(self.source,"insert into v_pbx_backup_commands(command_uuid,action) values("+b.literal(request)+",'create')")
        store=self.workspace/'worker-store';downloads=self.workspace/'worker-downloads'
        b.worker(self.source,store=store,downloads=downloads,roots=self.source_roots,version='1.0.9',key_file=self.key)
        self.assertEqual(b.query(self.source,'select status from v_pbx_backup_commands where command_uuid='+b.literal(request)),'completed')
        row=b.query(self.source,'select row_to_json(t) from v_pbx_backups t where command_uuid='+b.literal(request),json_result=True)
        self.assertEqual(row['status'],'ready');self.assertEqual(row['remote_status'],'failed')
        self.assertTrue((store/row['filename']).is_file());self.assertTrue((downloads/row['filename']).is_file())
        self.assertEqual(b.checksum(store/row['filename']),row['sha256'])
        b.query(self.source,'update v_pbx_backup_settings set sftp_enabled=false')

    def test_14_notification_archive_restore_and_legacy_migration_recover(self):
        old = {key:getattr(b,key) for key in ('ROOTS','MEDIA','RESTORE','WEB_VERSION','running_services','UNIT_ROOT','STORE','CACHE')}
        try:
            for current_layout in (False, True):
                with self.subTest(current_layout=current_layout):
                    work=self.workspace/('notification-current' if current_layout else 'notification-legacy');work.mkdir(mode=0o700)
                    source_push=work/'source-push';source_push.mkdir(mode=0o700)
                    legacy=source_push/'mobile-push.json';legacy.write_bytes(b'{"vapid_private_key":"legacy fixture identity"}\n');legacy.chmod(0o600)
                    source_roots=self.source_roots|{'mobile-push':legacy}
                    source_current=source_push/'mobile-notifications';source_current.mkdir(mode=0o700)
                    if current_layout:
                        (source_current/'config.json').write_bytes(b'{"vapid_private_key":"current fixture identity"}\n')
                        (source_current/'config.json.lock').write_bytes(b'')
                        source_roots['mobile-notifications']=source_current
                    archive=work/'notifications.owpbx'
                    b.ROOTS=self.original_roots;b.MEDIA=self.original_media
                    b.create_archive(self.source,archive,self.archive_password,roots=source_roots,version='1.0.9')
                    target=work/'target';target.mkdir(mode=0o700)
                    roots={}
                    for label in ('fusionpbx-config','runtime-config','freeswitch-config'):
                        roots[label]=target/label;roots[label].mkdir(mode=0o700)
                    roots['mobile-push']=target/'mobile-push.json'
                    roots['mobile-notifications']=target/'mobile-notifications';roots['mobile-notifications'].mkdir(mode=0o700)
                    os.chown(roots['mobile-notifications'],33,33)
                    current=roots['mobile-notifications']/'config.json';current.write_bytes(b'factory configuration');current.chmod(0o640)
                    (roots['fusionpbx-config']/'config.conf').write_text('\n'.join(k+' = '+v for k,v in self.target.items())+'\n')
                    (roots['fusionpbx-config']/'openweb-template.key').write_bytes(os.urandom(32))
                    (roots['runtime-config']/'runtime.json').write_text('{}')
                    b.ROOTS=roots;b.MEDIA={label:target/label for label in self.original_media}
                    b.RESTORE=work/'restore';b.STORE=work/'store';b.UNIT_ROOT=work/'units';b.UNIT_ROOT.mkdir()
                    b.WEB_VERSION=work/'VERSION';b.WEB_VERSION.write_text('1.0.9');b.running_services=lambda:[];b.CACHE=work/'cache'
                    self.install_voicemail_policy(b.WEB_VERSION)
                    b.restore(archive,self.archive_password,self.target,confirm_database=self.target_name)
                    expected=(source_current/'config.json').read_bytes() if current_layout else legacy.read_bytes()
                    self.assertEqual(current.read_bytes(),expected)
                    self.assertEqual(roots['mobile-push'].read_bytes(),legacy.read_bytes())
                    st=current.stat();self.assertEqual((st.st_mode&0o777,st.st_uid,st.st_gid),(0o600,33,33))
                    if current_layout:
                        lock=roots['mobile-notifications']/'config.json.lock';self.assertTrue(lock.is_file())
                        self.assertEqual((lock.stat().st_mode&0o777,lock.stat().st_uid,lock.stat().st_gid),(0o600,33,33))
                    journal=json.loads((b.RESTORE/'journal.json').read_text());journal['state']='restoring';b.atomic_json(b.RESTORE/'journal.json',journal)
                    b.recover(self.target)
                    self.assertEqual(current.read_bytes(),b'factory configuration')
                    self.assertEqual((current.stat().st_mode&0o777,current.stat().st_uid,current.stat().st_gid),(0o640,0,0))
                    self.assertFalse(roots['mobile-push'].exists())
                    self.assertFalse((roots['mobile-notifications']/'config.json.lock').exists())
        finally:
            for key,value in old.items():setattr(b,key,value)

    def test_15_notification_inventory_refuses_unknown_or_symlink_paths(self):
        for name in ('mobile-notifications/another.json','mobile-notifications/nested/config.json'):
            with self.assertRaises(b.BackupError):b.safe_member(name)
        work=self.workspace/'notification-unsafe';work.mkdir(mode=0o700)
        destination=work/'mobile-notifications';destination.symlink_to(work)
        with self.assertRaises(b.BackupError):b.notification_directory(destination)
        destination.unlink();destination.mkdir(mode=0o755)
        with self.assertRaises(b.BackupError):b.notification_directory(destination)

    def test_16_meeting_trust_reload_and_exact_factory_recovery(self):
        # Real encrypted archive/database/file recovery; the service boundary
        # is recorded. Actual PHP/key rebind is checked by pbx_meet_backup.py.
        old={key:getattr(b,key)for key in ('ROOTS','MEDIA','RESTORE','WEB_VERSION','running_services','UNIT_ROOT','STORE','CACHE','restore_meeting','reload_meeting_proxy')}
        work=self.workspace/'meeting-restore';work.mkdir(mode=0o700)
        try:
            source_roots={}
            for label,path in self.source_roots.items():
                copy=work/'source'/label;shutil.copytree(path,copy);source_roots[label]=copy
            source_ca=source_roots['runtime-config']/'meet-ca.pem';source_ca.write_bytes(b'source private CA fixture')
            source_pem=source_roots['freeswitch-config']/'tls/openweb-meet/wss.pem';source_pem.parent.mkdir(parents=True);source_pem.write_bytes(b'source private key fixture')
            archive=work/'meeting.owpbx';b.create_archive(self.source,archive,self.archive_password,roots=source_roots,version='1.0.9')
            roots={label:work/'target'/label for label in self.source_roots}
            for path in roots.values():path.mkdir(parents=True)
            config=roots['fusionpbx-config']/'config.conf';config.write_text(''.join(k+' = '+v+'\n'for k,v in self.target.items()))
            (roots['fusionpbx-config']/'openweb-template.key').write_bytes(os.urandom(32))
            (roots['runtime-config']/'runtime.json').write_text('{}')
            ca=roots['runtime-config']/'meet-ca.pem';ca.write_bytes(b'factory private CA fixture');ca.chmod(0o600)
            pem=roots['freeswitch-config']/'tls/openweb-meet/wss.pem';pem.parent.mkdir(parents=True);pem.write_bytes(b'factory private key fixture');pem.chmod(0o600)
            b.ROOTS={k:v for k,v in roots.items()if k not in self.original_media};b.MEDIA={k:v for k,v in roots.items()if k in self.original_media}
            b.RESTORE=work/'journal';b.STORE=work/'store';b.UNIT_ROOT=work/'units';b.UNIT_ROOT.mkdir();b.running_services=lambda:[];b.CACHE=work/'cache'
            b.WEB_VERSION=work/'VERSION';b.WEB_VERSION.write_text('1.0.9');self.install_voicemail_policy(b.WEB_VERSION)
            observed=[];rebound=[]
            b.restore_meeting=lambda settings:rebound.append((settings['database.0.name'],ca.read_bytes()))or True
            b.reload_meeting_proxy=lambda:observed.append(ca.read_bytes())
            b.restore(archive,self.archive_password,self.target,confirm_database=self.target_name)
            self.assertEqual(rebound,[(self.target_name,b'source private CA fixture')]);self.assertEqual(observed,[b'source private CA fixture'])
            self.assertEqual(pem.read_bytes(),b'source private key fixture')
            journal=json.loads((b.RESTORE/'journal.json').read_text());self.assertTrue(journal['meeting_proxy']);journal['state']='restoring';b.atomic_json(b.RESTORE/'journal.json',journal)
            b.recover(self.target)
            self.assertEqual(observed,[b'source private CA fixture',b'factory private CA fixture'])
            self.assertEqual(pem.read_bytes(),b'factory private key fixture');self.assertEqual(pem.stat().st_mode&0o777,0o600);self.assertEqual(ca.stat().st_mode&0o777,0o600)
            self.assertEqual(len(rebound),1,'Exact factory recovery must never apply source address/schema policies')
            self.assertEqual(b.query(self.target,'select count(*)from fixture_objects'),'0')
            self.assertEqual(b.read_settings(config)['openweb.public_ip'],'198.51.100.22')
            # Failure after copying a new CA must restore/reload the factory pin.
            shutil.rmtree(b.RESTORE);observed.clear();rebound.clear()
            def fail_first():
                observed.append(ca.read_bytes())
                if len(observed)==1:raise b.BackupError('Intentional isolated web reload failure')
            b.reload_meeting_proxy=fail_first
            with self.assertRaisesRegex(b.BackupError,'Intentional isolated'):
                b.restore(archive,self.archive_password,self.target,confirm_database=self.target_name)
            self.assertEqual(observed,[b'source private CA fixture',b'factory private CA fixture'])
            self.assertEqual(pem.read_bytes(),b'factory private key fixture')
            self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['state'],'recovered')
            self.assertEqual(b.query(self.target,'select count(*)from fixture_objects'),'0')
        finally:
            for key,value in old.items():setattr(b,key,value)


    def test_17_registration_session_encrypted_restore_and_exact_recovery(self):
        work=self.workspace/'registration-recovery';work.mkdir(mode=0o700)
        source=work/'source-private';source.mkdir(mode=0o700)
        (source/'image-onboarding').mkdir(mode=0o700)
        session=b'{"device_code":"owpd_1111111111111111111111111111111111111111111111111111111111111111","identity":{"domain_uuid":"fixture"}}'
        image=b'{"service_uuid":"source-service","domain_uuid":"source-domain"}'
        for name,data in [('image-local.json',image),('image-onboarding/session.json',session),('image-onboarding/setup.txt',b'not recovery data'),('unrelated-private.key',b'never included')]:
            path=source/name;path.write_bytes(data);path.chmod(0o600)
        lock=source/'image-onboarding/worker.lock';lock.touch(mode=0o600)
        roots=self.source_roots|{'registration-state':source};archive=work/'registration.owpbx'
        descriptor=os.open(lock,os.O_RDWR)
        try:
            b.fcntl.flock(descriptor,b.fcntl.LOCK_EX|b.fcntl.LOCK_NB)
            with self.assertRaisesRegex(b.BackupError,'registration is being refreshed'):
                b.create_archive(self.source,archive,self.archive_password,roots=roots,version='1.0.9')
            self.assertFalse(archive.exists())
        finally:os.close(descriptor)
        manifest=b.create_archive(self.source,archive,self.archive_password,roots=roots,version='1.0.9')
        self.assertEqual(sorted(n for n in manifest['files']if n.startswith('registration-state/')),
                         ['registration-state/image-local.json','registration-state/image-onboarding/session.json'])
        self.assertNotIn(session,archive.read_bytes())
        for name in ['registration-state/setup.json','registration-state/../private.key','registration-state/image-onboarding/setup.txt']:
            with self.assertRaises(b.BackupError):b.safe_member(name)
        old={key:getattr(b,key)for key in ('ROOTS','MEDIA','RESTORE','WEB_VERSION','running_services','UNIT_ROOT','STORE','CACHE')}
        try:
            target=work/'target';target.mkdir(mode=0o700)
            target_roots={label:target/label for label in self.source_roots}
            for path in target_roots.values():path.mkdir(mode=0o700)
            private=target/'transport/private';private.mkdir(parents=True,mode=0o700)
            (private/'image-onboarding').mkdir(mode=0o700)
            target_roots['registration-state']=private
            config=target_roots['fusionpbx-config']/'config.conf'
            config.write_text(''.join(k+' = '+v+'\n'for k,v in self.target.items()))
            (target_roots['fusionpbx-config']/'openweb-template.key').write_bytes(os.urandom(32))
            (target_roots['runtime-config']/'runtime.json').write_text('{}')
            b.ROOTS={k:v for k,v in target_roots.items()if k not in self.original_media}
            b.MEDIA={k:v for k,v in target_roots.items()if k in self.original_media}
            b.RESTORE=work/'journal';b.STORE=work/'store';b.UNIT_ROOT=work/'units';b.UNIT_ROOT.mkdir()
            b.running_services=lambda:[];b.CACHE=work/'cache';b.WEB_VERSION=work/'VERSION';b.WEB_VERSION.write_text('1.0.9')
            self.install_voicemail_policy(b.WEB_VERSION)
            baseline={}
            for path in b.registration_restore_files():
                path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
                data=b'target-only '+path.name.encode();path.write_bytes(data);path.chmod(0o600)
                baseline[str(path)]=(data,path.stat().st_mode&0o777,path.stat().st_uid,path.stat().st_gid)
            untouched=private/'unrelated-owned-secret';untouched.write_bytes(b'exact untouched target')
            b.restore(archive,self.archive_password,self.target,confirm_database=self.target_name)
            self.assertEqual((private/'image-local.json').read_bytes(),image)
            restored=private/'image-onboarding/session.json';self.assertEqual(restored.read_bytes(),session)
            self.assertEqual((restored.stat().st_mode&0o777,restored.stat().st_uid,restored.stat().st_gid),(0o600,0,0))
            for path in b.registration_restore_files():
                if path not in (private/'image-local.json',restored):self.assertFalse(path.exists())
            self.assertEqual(untouched.read_bytes(),b'exact untouched target')
            journal=json.loads((b.RESTORE/'journal.json').read_text());journal['state']='restoring';b.atomic_json(b.RESTORE/'journal.json',journal)
            b.recover(self.target)
            for name,expected in baseline.items():
                path=Path(name);self.assertEqual((path.read_bytes(),path.stat().st_mode&0o777,path.stat().st_uid,path.stat().st_gid),expected)
            self.assertEqual(untouched.read_bytes(),b'exact untouched target')
            self.assertEqual(b.query(self.target,'select count(*)from fixture_objects'),'0')
        finally:
            for key,value in old.items():setattr(b,key,value)


if __name__ == '__main__':
    if os.geteuid() != 0:
        raise SystemExit('Run fixture checks as root; only independent databases and loopback services are used.')
    unittest.main(verbosity=2)
