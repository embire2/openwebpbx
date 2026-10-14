#!/usr/bin/env python3
"""Windows worker logic with crypto/files and an independent loopback PostgreSQL.

Native Windows ACL/service/task controls are mocked here and need Windows tests.
This suite never connects to the production database or any carrier endpoint.
"""
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
import socket
import subprocess
import tarfile
import tempfile
import unittest
import uuid
from unittest.mock import patch

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('windows_backups', ROOT / 'packaging/windows/backups.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class WindowsBackups(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.name == 'nt':
            raise unittest.SkipTest('This isolated PostgreSQL runner is Linux-only; use the separate native Windows qualification.')
        cls.work = Path(tempfile.mkdtemp(prefix='openweb-windows-backups-'))
        cls.work.chmod(0o711)
        cls.private = cls.work / 'private'
        cls.private.mkdir(mode=0o700)
        cls.cluster = cls.work / 'cluster'
        cls.cluster.mkdir(mode=0o700)
        import pwd
        owner = pwd.getpwnam('postgres')
        os.chown(cls.cluster, owner.pw_uid, owner.pw_gid)
        cls.pg = Path('/usr/lib/postgresql/18/bin')
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0));cls.port = reserve.getsockname()[1]
        cls.pg_run('initdb', '-D', str(cls.cluster), '--auth-local=trust', '--auth-host=scram-sha-256', '--encoding=UTF8', '--locale=C')
        cls.pg_run('pg_ctl', '-D', str(cls.cluster), '-l', str(cls.cluster/'server.log'), '-o', f'-h 127.0.0.1 -p {cls.port} -k {cls.cluster}', '-w', 'start')
        cls.source_password = secrets.token_hex(24)
        cls.target_password = 'fixture-target;quoted"' + secrets.token_hex(16)
        cls.admin_sql('create role source_app login password '+b.literal(cls.source_password)+';create role target_app login password '+b.literal(cls.target_password))
        cls.admin_sql('create database source_pbx owner source_app')
        cls.source = cls.settings('source_pbx', 'source_app', cls.source_password)
        cls.schema(cls.source, source=True)
        cls.source_state = cls.private/'source'
        cls.source_state.mkdir(mode=0o700)
        cls.source_roots = cls.roots(cls.source_state)
        cls.key = os.urandom(32)
        cls.files(cls.source_roots, cls.source, source=True)
        cls.password = 'Disposable Windows Backup Password 123'
        cls.archive = cls.private/(str(uuid.uuid4())+'.owpbx')
        cls.manifest = b.create_archive(cls.source, cls.archive, cls.password, roots=cls.source_roots, version='1.0.13')

    @classmethod
    def pg_run(cls, name, *arguments):
        result = subprocess.run(['runuser','-u','postgres','--',str(cls.pg/name),*arguments], cwd=cls.cluster,
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
        if result.returncode:
            raise RuntimeError('The independent fixture PostgreSQL operation failed.')
        return result.stdout

    @classmethod
    def admin_sql(cls, sql):
        cls.pg_run('psql','-h',str(cls.cluster),'-p',str(cls.port),'-U','postgres','-d','postgres','-X','-q','-v','ON_ERROR_STOP=1','-c',sql)

    @classmethod
    def settings(cls, name, user, password):
        return {'database.0.type':'pgsql','database.0.host':'127.0.0.1','database.0.port':str(cls.port),
                'database.0.name':name,'database.0.username':user,'database.0.password':password,
                'openweb.public_host':'pbx.fixture.invalid','openweb.public_url':'https://pbx.fixture.invalid:8443',
                'openweb.public_ip':'192.0.2.10' if name=='source_pbx' else '192.0.2.20'}

    @classmethod
    def schema(cls, settings, source=False):
        b.query(settings, '''CREATE TABLE v_users(user_uuid uuid PRIMARY KEY,username text,user_enabled text);
          CREATE TABLE v_domains(domain_uuid uuid PRIMARY KEY,domain_name text);
          CREATE TABLE v_extensions(id uuid PRIMARY KEY);
          CREATE TABLE v_pbx_tenants(id uuid PRIMARY KEY);CREATE TABLE v_pbx_services(id uuid PRIMARY KEY);
          CREATE TABLE v_pbx_restore(id uuid PRIMARY KEY);CREATE TABLE v_recordings(id uuid PRIMARY KEY);
          CREATE TABLE v_voicemail_messages(id uuid PRIMARY KEY);
          CREATE TABLE v_pbx_update_commands(status text);
          CREATE TABLE fixture_objects(kind text PRIMARY KEY,payload text);
          INSERT INTO v_users VALUES(gen_random_uuid(),'factory','true');
          INSERT INTO v_domains VALUES(gen_random_uuid(),'pbx.fixture.invalid');''')
        b.query(settings,(ROOT/'app/pbx_backups/resources/install.sql').read_text().split('DO $$')[0]+'COMMIT;')
        if source:
            b.query(settings,"INSERT INTO fixture_objects VALUES('tenant','owned fixture'),('private-phone','preserved credential'),('media-key','sealed data');INSERT INTO v_extensions VALUES(gen_random_uuid());")

    @classmethod
    def roots(cls, state):
        roots = {'fusionpbx-config':state/'config','runtime-config':state,
                 'freeswitch-config':state/'switch-conf','phone-tls':state/'phone-tls',
                 'public-access':state/'public-access',
                 'mobile-notifications':state/'mobile-notifications','mobile-push':state/'mobile-push.json',
                 'mobile-push-settings':state/'mobile-push-settings.json','storage':state/'storage',
                 'recordings':state/'storage/recordings','custom-sounds':state/'sounds'}
        for label,path in roots.items():
            if label not in ('mobile-push','mobile-push-settings'):
                path.mkdir(parents=True,exist_ok=True,mode=0o700)
        return roots

    @classmethod
    def files(cls, roots, settings, source=False):
        key = cls.key if source else os.urandom(32)
        (roots['fusionpbx-config']/'config.conf').write_text('\n'.join(k+' = '+v for k,v in settings.items())+'\n')
        (roots['fusionpbx-config']/'openweb-template.key').write_bytes(key)
        (roots['runtime-config']/'runtime.json').write_text(json.dumps({'ConnectionStrings':{'Pbx':'source only' if source else 'factory only'},'Switch':{'Password':'source-switch' if source else 'factory-switch'}}))
        (roots['runtime-config']/'installation.json').write_text(json.dumps({'Version':'1.0.13','DatabasePassword':settings['database.0.password'],
            'PostgresPassword':'source-admin-only' if source else 'target-admin-only','SwitchPassword':'source-switch' if source else 'factory-switch',
            'CertificateThumbprint':'SOURCE' if source else 'TARGET','Completed':True}))
        installation=roots['runtime-config']/'installation.json'
        value=json.loads(installation.read_text());value['PublicAddress']=settings['openweb.public_ip'];installation.write_text(json.dumps(value))
        (roots['runtime-config']/'phone-tls.json').write_text(json.dumps({'CertificateThumbprint':'SOURCE' if source else 'TARGET','Hostname':'pbx.fixture.invalid','Port':5061}))
        (roots['freeswitch-config']/'source.xml').write_text('<source />' if source else '<factory />')
        (roots['phone-tls']/'agent.pem').write_text('source private fixture material' if source else 'target private fixture material')
        (roots['public-access']/'state.json').write_text(json.dumps({'certificate_thumbprint':'SOURCE' if source else 'TARGET'}))
        (roots['public-access']/'accounts').mkdir(exist_ok=True)
        (roots['public-access']/'accounts/dpapi.bin').write_bytes(b'source machine bound identity' if source else b'target machine bound identity')
        (roots['mobile-notifications']/'config.json').write_text(json.dumps({'private':'source identity' if source else 'target identity'}))
        (roots['storage']/'voicemail.wav').write_bytes(b'source voicemail' if source else b'factory voicemail')
        (roots['recordings']/'recording.wav').write_bytes(b'source recording' if source else b'factory recording')
        (roots['custom-sounds']/'welcome.wav').write_bytes(b'source prompt' if source else b'factory prompt')
        # Runtime/database/uploads must never be traversed through the runtime-config label.
        (roots['runtime-config']/'do-not-backup.txt').write_text('unrelated runtime data')

    @classmethod
    def tearDownClass(cls):
        try:cls.pg_run('pg_ctl','-D',str(cls.cluster),'-m','immediate','-w','stop')
        finally:shutil.rmtree(cls.work)

    def setUp(self):
        self.target_name = 'target_'+secrets.token_hex(6)
        self.admin_sql('create database '+self.target_name+' owner target_app')
        self.target = self.settings(self.target_name,'target_app',self.target_password)
        self.schema(self.target)
        self.target_state = self.private/self.target_name
        self.target_state.mkdir(mode=0o700)
        self.target_roots = self.roots(self.target_state)
        self.files(self.target_roots,self.target)
        self.plan = {'schema':1,'services':{'FreeSWITCH':'Manual','OpenWebPBX':'Manual','OpenWebPBXUpdater':'Auto'},
                     'running':['FreeSWITCH','OpenWebPBX','OpenWebPBXUpdater'],'backup_enabled':True,'cleanup_enabled':True,
                     'site_running':True,'pool_running':True,'site_auto':False,'pool_auto':False}
        self.native_calls = []
        self.patches = [patch.object(b,'ROOTS',{k:v for k,v in self.target_roots.items() if k not in b.MEDIA}),
                        patch.object(b,'MEDIA',{k:self.target_roots[k] for k in ('storage','recordings','custom-sounds')}),
                        patch.object(b,'STATE',self.target_state),patch.object(b,'STORE',self.target_state/'automatic-backups'),
                        patch.object(b,'RESTORE',self.target_state/'backup-restore'),patch.object(b,'UPGRADE_LOCK',self.target_state/'upgrade.lock'),
                        patch.object(b,'WEB_VERSION',self.target_state/'VERSION'),patch.object(b,'control',self.control)]
        self.patches.append(patch.object(b,'installation_layout',lambda:self.manifest['installation_layout']))
        for p in self.patches:p.start()
        b.WEB_VERSION.write_text('1.0.13\n')

    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.admin_sql('drop database '+self.target_name+' with (force)')
        shutil.rmtree(self.target_state)

    def control(self, operation, value=None):
        self.native_calls.append((operation,value))
        if operation=='plan':return json.loads(json.dumps(self.plan))
        if operation=='acl-read':return {name:'O:SYD:P(A;;FA;;;SY)' for name in value['paths']}
        return {}

    def seal(self, plain):
        nonce=os.urandom(12);derived=hashlib.sha256(self.key+b'/openwebpbx/backups/v1').digest()
        value=AESGCM(derived).encrypt(nonce,plain.encode(),b'openwebpbx-backup-settings-v1')
        return 'v1:'+base64.b64encode(nonce+value[-16:]+value[:-16]).decode()

    def test_01_crypto_roundtrip_private_keys_and_media(self):
        self.assertEqual(self.manifest['platform'],b.PLATFORM)
        self.assertNotIn(b'source private fixture material',self.archive.read_bytes())
        with b.verify_archive(self.archive,self.password) as (files,manifest):
            self.assertEqual((files/'fusionpbx-config/openweb-template.key').read_bytes(),self.key)
            self.assertEqual((files/'recordings/recording.wav').read_bytes(),b'source recording')
            self.assertNotIn('storage/recordings/recording.wav',manifest['files'])
            self.assertNotIn('runtime-config/do-not-backup.txt',manifest['files'])

    def test_02_password_tamper_and_key_envelope(self):
        with self.assertRaises(b.BackupError):
            with b.verify_archive(self.archive,'Incorrect fixture password 123'):pass
        self.assertEqual(b.unseal(self.seal(self.password),self.source_roots['fusionpbx-config']/'openweb-template.key'),self.password)
        damaged=self.target_state/'damaged.owpbx';raw=bytearray(self.archive.read_bytes());raw[60]^=1;damaged.write_bytes(raw)
        with self.assertRaises(b.BackupError):
            with b.verify_archive(damaged,self.password):pass

    def test_03_windows_names_and_case_collisions(self):
        for name in ('storage/NUL.wav','storage/a:stream','storage/a.','storage/a ','storage/../x','C:/x','storage/a\\b','runtime-config/database/file'):
            with self.assertRaises(b.BackupError):b.safe_member(name)
        payload=self.target_state/'collision.tar.gz'
        entries={'database.dump':b'', 'storage/A.wav':b'a','storage/a.wav':b'b'}
        manifest={'schema':1,'platform':b.PLATFORM,'version':'1.0.13','files':{k:{'size':len(v),'mode':0o600,'sha256':hashlib.sha256(v).hexdigest()} for k,v in entries.items()}}
        with tarfile.open(payload,'w:gz') as a:
            raw=json.dumps(manifest).encode();m=tarfile.TarInfo('manifest.json');m.size=len(raw);a.addfile(m,io.BytesIO(raw))
        output=self.target_state/'extract';output.mkdir()
        with self.assertRaisesRegex(b.BackupError,'colliding'):b.extract_verified(payload,output)

    def test_04_link_and_size_refusal(self):
        link=self.target_state/'linked';link.symlink_to(self.archive)
        with self.assertRaises(b.BackupError):b.ordinary(link)
        hard=self.target_state/'hard';os.link(self.archive,hard)
        try:
            with self.assertRaises(b.BackupError):b.ordinary(hard)
        finally:hard.unlink()
        with patch.object(b,'MAX_ARCHIVE',20):
            with self.assertRaises(b.BackupError):
                with b.verify_archive(self.archive,self.password):pass

    def test_05_restore_dry_run_and_identity(self):
        original=(self.target_roots['fusionpbx-config']/'openweb-template.key').read_bytes()
        result=b.restore(self.archive,self.password,self.target,dry_run=True)
        self.assertEqual(result['version'],'1.0.13')
        self.assertEqual((self.target_roots['fusionpbx-config']/'openweb-template.key').read_bytes(),original)
        self.assertFalse((b.RESTORE/'journal.json').exists())
        self.assertFalse(any(op in ('hold','start-web') for op,_ in self.native_calls))

    def test_06_complete_restore_keeps_database_identity_and_tls_hold(self):
        b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertEqual(b.query(self.target,'select current_database()'),self.target_name)
        self.assertEqual(b.query(self.target,'select current_user'),'target_app')
        self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'3')
        self.assertEqual((self.target_roots['fusionpbx-config']/'openweb-template.key').read_bytes(),self.key)
        self.assertEqual(b.read_settings(self.target_roots['fusionpbx-config']/'config.conf')['database.0.password'],self.target_password)
        installation=json.loads((self.target_state/'installation.json').read_text())
        self.assertEqual(installation['PostgresPassword'],'target-admin-only')
        self.assertEqual(installation['DatabasePassword'],self.target_password)
        self.assertEqual(installation['CertificateThumbprint'],'TARGET')
        self.assertEqual(installation['PublicAddress'],'192.0.2.20')
        config=b.read_settings(self.target_roots['fusionpbx-config']/'config.conf')
        self.assertEqual(config['openweb.public_ip'],'192.0.2.20');self.assertEqual(config['openweb.mobile_tls_ready'],'false')
        self.assertEqual(json.loads((self.target_roots['public-access']/'state.json').read_text())['certificate_thumbprint'],'TARGET')
        self.assertEqual((self.target_roots['public-access']/'accounts/dpapi.bin').read_bytes(),b'target machine bound identity')
        self.assertEqual((self.target_state/'restored-source/public-access/accounts/dpapi.bin').read_bytes(),b'source machine bound identity')
        self.assertEqual(b.acl_kind(self.target_state/'restored-source/public-access/accounts/dpapi.bin'),'private')
        tls=json.loads((self.target_state/'phone-tls.json').read_text())
        self.assertTrue(tls['RestorePending']);self.assertEqual(tls['CertificateThumbprint'],'')
        self.assertTrue(all(b.held(selection) for selection in b.HELD_UNITS))
        self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['state'],'restored')
        self.assertEqual(b.query(self.target,'select enabled or sftp_enabled from v_pbx_backup_settings'),'f')
        self.assertEqual([op for op,_ in self.native_calls].count('start-web'),1)

    def test_07_restore_failure_recovers_database_files_and_acl_plan(self):
        before={p:p.read_bytes() for p in self.target_state.rglob('*') if p.is_file()}
        original=b.atomic_copy;failed=False
        def once(source,target,**kwargs):
            nonlocal failed
            if not failed:failed=True;raise b.BackupError('Injected private fixture failure')
            return original(source,target,**kwargs)
        with patch.object(b,'atomic_copy',once):
            with self.assertRaisesRegex(b.BackupError,'Injected'):b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'0')
        for path,data in before.items():self.assertEqual(path.read_bytes(),data)
        self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['state'],'recovered')
        self.assertFalse(any(b.held(selection) for selection in b.HELD_UNITS))
        self.assertTrue(any(op=='acl-restore' for op,_ in self.native_calls))

    def test_08_active_target_version_url_and_confirmation_refused(self):
        b.query(self.target,'insert into v_extensions values(gen_random_uuid())')
        with self.assertRaisesRegex(b.BackupError,'fresh'):b.restore(self.archive,self.password,self.target,dry_run=True)
        b.query(self.target,'delete from v_extensions')
        with self.assertRaisesRegex(b.BackupError,'Confirm'):b.restore(self.archive,self.password,self.target,confirm_database='wrong')
        b.WEB_VERSION.write_text('1.0.12')
        with self.assertRaisesRegex(b.BackupError,'same application'):b.restore(self.archive,self.password,self.target,dry_run=True)
        b.WEB_VERSION.write_text('1.0.13')
        with self.assertRaisesRegex(b.BackupError,'HTTPS'):b.restore(self.archive,self.password,self.target|{'openweb.public_url':'https://pbx.fixture.invalid:443'},dry_run=True)
        with patch.object(b,'installation_layout',lambda:self.manifest['installation_layout']|{'state':'d:\\programdata\\openwebpbx'}):
            with self.assertRaisesRegex(b.BackupError,'layout'):b.restore(self.archive,self.password,self.target,dry_run=True)

    def test_09_exclusive_upgrade_lock_and_restore_worker_hold(self):
        with b.exclusive_guard(b.UPGRADE_LOCK):
            with self.assertRaises(b.BackupError):
                with b.exclusive_guard(b.UPGRADE_LOCK):pass
        b.RESTORE.mkdir();b.atomic_json(b.RESTORE/'hold-jobs',{'schema':1})
        with patch.object(b,'_worker') as worker:
            b.worker(self.target);worker.assert_not_called()

    def test_10_actual_worker_create_verify_and_daily_schedule(self):
        store=self.target_state/'worker-store';downloads=self.target_state/'downloads'
        b.query(self.source,'update v_pbx_backup_settings set enabled=true,schedule_hour=0,passphrase_secret='+b.literal(self.seal(self.password)))
        args={'store':store,'downloads':downloads,'roots':self.source_roots,'version':'1.0.13','key_file':self.source_roots['fusionpbx-config']/'openweb-template.key'}
        b.worker(self.source,**args)
        row=b.query(self.source,"select row_to_json(t) from v_pbx_backups t where status='ready' order by completed_at desc limit 1",json_result=True)
        self.assertIsNotNone(row);self.assertEqual(b.checksum(store/row['filename']),b.checksum(downloads/row['filename']))
        count=b.query(self.source,'select count(*) from v_pbx_backup_commands')
        b.worker(self.source,**args)
        self.assertEqual(b.query(self.source,'select count(*) from v_pbx_backup_commands'),count)
        identifier=str(uuid.uuid4())
        b.query(self.source,"insert into v_pbx_backup_commands(command_uuid,action,backup_uuid) values("+b.literal(identifier)+",'verify',"+b.literal(row['backup_uuid'])+")")
        b.worker(self.source,**args)
        self.assertEqual(b.query(self.source,'select status from v_pbx_backup_commands where command_uuid='+b.literal(identifier)),'completed')
        b.query(self.source,'delete from v_pbx_backups;delete from v_pbx_backup_commands;update v_pbx_backup_settings set enabled=false,last_scheduled_date=null')

    def test_11_retention_refuses_damaged_keeper_and_unlisted_paths(self):
        store=self.target_state/'keep';downloads=self.target_state/'keep-download';store.mkdir();downloads.mkdir()
        names=[]
        for i in range(3):
            identifier=str(uuid.uuid4());name=identifier+'.owpbx';(store/name).write_bytes(b'fixture'+bytes([i]));names.append(name)
            b.query(self.target,"insert into v_pbx_backups(backup_uuid,filename,status,include_media,app_version,size_bytes,sha256,completed_at) values("+b.literal(identifier)+','+b.literal(name)+",'ready',false,'1.0.13',8,"+b.literal(b.checksum(store/name))+",now()+interval '"+str(i)+" seconds')")
        (store/names[-1]).write_bytes(b'damaged')
        with self.assertRaises(b.BackupError):b.prune_backups(self.target,2,store=store,downloads=downloads)
        self.assertEqual(len(list(store.iterdir())),3)
        (store/names[-1]).write_bytes(b'fixture'+bytes([2]))
        b.prune_backups(self.target,2,store=store,downloads=downloads)
        self.assertEqual(b.query(self.target,"select count(*) from v_pbx_backups where status='ready'"),'2')
        self.assertEqual(sorted(path.name for path in store.iterdir()),sorted(names[1:]))

    def test_12_failed_activation_reholds_only_selected_service(self):
        b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        original=self.control
        def failed(operation,value=None):
            if operation=='activate':raise b.BackupError('Injected actual TLS readiness failure')
            return original(operation,value)
        with patch.object(b,'control',failed):
            with self.assertRaisesRegex(b.BackupError,'readiness'):b.activate(self.target,['calls'],self.target['openweb.public_host'])
        self.assertTrue(all(b.held(selection) for selection in b.HELD_UNITS))
        self.assertTrue(any(operation=='hold-selection' and value['selection']=='calls' for operation,value in self.native_calls))


if __name__=='__main__':
    unittest.main()
