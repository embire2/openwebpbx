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
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('windows_backups', ROOT / 'packaging/windows/backups.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class WindowsNativeModuleEnvironment(unittest.TestCase):
    def test_phone_recovery_restore_absence_counts_and_failed_observations_stay_closed(self):
        with patch.object(b,'query',return_value='f') as query:
            self.assertEqual(b.refuse_restored_phone_recoveries({}),0)
            self.assertEqual(query.call_count,1)
        for present in (None,True,1,[],{},'true','PRIVATE'):
            with self.subTest(present=type(present).__name__),patch.object(b,'query',return_value=present) as query:
                with self.assertRaises(b.BackupError):b.refuse_restored_phone_recoveries({})
                self.assertEqual(query.call_count,1)
        for count in (None,True,1,[],{},'-1','1.0','9223372036854775808','PRIVATE'):
            with self.subTest(count=type(count).__name__),patch.object(b,'query',side_effect=['t',count]):
                with self.assertRaises(b.BackupError):b.refuse_restored_phone_recoveries({})
        for count in ('0','2'):
            with patch.object(b,'query',side_effect=['t',count]) as query:
                self.assertEqual(b.refuse_restored_phone_recoveries({}),int(count))
                sql=query.call_args.args[1]
                self.assertIn("set status='refused' where status='pending'",sql)
                self.assertNotIn('delete',sql.lower())

    def test_native_module_roots_replace_core_paths_only_in_child(self):
        inherited = 'C:/PowerShell7/Modules;C:/Users/Fictional/Documents/PowerShell/Modules'
        with patch.dict(os.environ, {'SystemRoot': 'C:/Windows', 'ProgramFiles': 'C:/Program Files',
                                     'PSModulePath': inherited, 'PSMODULEPATH': inherited,
                                     'OPENWEB_BACKUP_TEST_ENV': 'preserved'}):
            environment = b.native_powershell_environment()
            paths = [value for key, value in environment.items() if key.upper() == 'PSMODULEPATH']
            self.assertEqual(len(paths), 1)
            self.assertEqual(paths[0], ';'.join(str(path) for path in (
                Path('C:/Windows')/'System32/WindowsPowerShell/v1.0/Modules',
                Path('C:/Program Files')/'WindowsPowerShell/Modules')))
            self.assertEqual(environment['OPENWEB_BACKUP_TEST_ENV'], 'preserved')
            self.assertEqual(os.environ['PSModulePath'], inherited)

    def test_original_admin_credentials_are_bound_before_any_privileged_connection(self):
        self.assertEqual(b.LOCAL_DATABASE, ('5433','fusionpbx','fusionpbx'))
        good={'database.0.host':'127.0.0.1','database.0.port':'5433','database.0.name':'fusionpbx',
              'database.0.username':'fusionpbx','database.0.password':'fictional-app'}
        installed={'DatabasePassword':'fictional-app','PostgresPassword':'fictional-admin'}
        cases=[]
        for key in ('database.0.port','database.0.name','database.0.username','database.0.host'):
            cases.append((good|{key:'unrelated'},installed))
        for key in ('DatabasePassword','PostgresPassword'):
            for value in (None,'',True,1,[],{}):
                cases.append((good,installed|{key:value}))
            cases.append((good,{k:v for k,v in installed.items() if k!=key}))
        for value in (None,'',True,1,[],{},'different'):
            cases.append((good|{'database.0.password':value},installed))
        cases.append(({k:v for k,v in good.items() if k!='database.0.password'},{}))
        for settings,installation in cases:
            with self.subTest(settings_keys=sorted(settings),installation_type=type(installation).__name__),patch.object(b,'query') as query:
                with self.assertRaises(b.BackupError):b.local_database_administrator(settings,installation)
                query.assert_not_called()
        for host in ('127.0.0.1','localhost','::1'):
            with patch.object(b,'query',return_value='t') as query:
                actual=b.local_database_administrator(good|{'database.0.host':host},installed)
                self.assertEqual(actual['database.0.username'],'postgres')
                self.assertEqual(actual['database.0.password'],installed['PostgresPassword'])
                self.assertEqual(actual['database.0.name'],'fusionpbx');query.assert_called_once()
        with patch.object(b,'query',return_value='f'):
            with self.assertRaises(b.BackupError):b.local_database_administrator(good,installed)

    def test_native_security_subset_contains_only_original_public_security_metadata(self):
        lines=['1; 1 1 SCHEMA - public pg_database_owner','2; 1 2 ACL - SCHEMA public postgres',
               '3; 1 3 COMMENT - SCHEMA public postgres','4; 1 4 DEFAULT ACL public DEFAULT PRIVILEGES FOR TABLES fusionpbx',
               '5; 1 5 TABLE public v_users fusionpbx','6; 1 6 TABLE DATA public v_users fusionpbx',
               '7; 1 7 ACL public TABLE v_users fusionpbx']
        with tempfile.TemporaryDirectory() as temporary:
            dump=Path(temporary)/'native.dump';dump.write_bytes(b'fictional native transport')
            with patch.object(b,'run',return_value=('\n'.join(lines)+'\n').encode()):
                self.assertEqual(b.database_security_entries(dump),lines[:4])
            for extra in ('8; 1 8 SCHEMA - foreign postgres',lines[0]):
                with patch.object(b,'run',return_value=('\n'.join(lines+[extra])+'\n').encode()):
                    with self.assertRaises(b.BackupError):b.database_security_entries(dump)
            with patch.object(b,'run',return_value=b'8; 1 8 SCHEMA - foreign postgres\n'):
                with self.assertRaises(b.BackupError):b.portable_database_entries(dump)


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
        cls.admin_sql("alter role postgres password 'target-admin-only'")
        cls.admin_sql('create role fixture_schema_owner;create role fixture_acl_reader;create role fixture_acl_delegate')
        cls.admin_sql('create database source_pbx owner source_app')
        cls.source = cls.settings('source_pbx', 'source_app', cls.source_password)
        cls.schema(cls.source, source=True)
        b.query(cls.source, "CREATE FUNCTION public.fixture_body_bytes() RETURNS text LANGUAGE sql AS $$SELECT 'fictional café';\r\n$$;")
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
          CREATE TABLE v_voicemails(voicemail_uuid uuid PRIMARY KEY,domain_uuid uuid,voicemail_id text,voicemail_password text,greeting_id integer);
          CREATE TABLE v_pbx_update_commands(status text);
          CREATE TABLE v_pbx_phone_health_recoveries(recovery_uuid uuid PRIMARY KEY,domain_uuid uuid,
            actor_uuid uuid,block_uuid uuid,source_address inet,status text NOT NULL
            CHECK(status IN ('pending','acknowledged','refused','dispatch_failed')),
            created_at timestamptz NOT NULL,acknowledged_at timestamptz,instance_id text);
          CREATE TABLE fixture_objects(kind text PRIMARY KEY,payload text);
          INSERT INTO v_users VALUES(gen_random_uuid(),'factory','true');
          INSERT INTO v_domains VALUES(gen_random_uuid(),'pbx.fixture.invalid');''')
        b.query(settings,(ROOT/'app/pbx_backups/resources/install.sql').read_text().split('DO $$')[0]+'COMMIT;')
        b.query(settings,"""INSERT INTO v_pbx_phone_health_recoveries
          SELECT gen_random_uuid(),domain_uuid,gen_random_uuid(),gen_random_uuid(),'192.0.2.77',s,now(),
            CASE WHEN s='acknowledged' THEN now() ELSE NULL END,repeat('a',64)
          FROM v_domains CROSS JOIN (VALUES('pending'),('pending'),('acknowledged'),('refused'),('dispatch_failed')) t(s)""")
        if source:
            b.query(settings,"INSERT INTO fixture_objects VALUES('tenant','owned fixture'),('private-phone','preserved credential'),('media-key','sealed data');INSERT INTO v_extensions VALUES(gen_random_uuid());")
            b.query(settings,"INSERT INTO v_voicemails SELECT gen_random_uuid(),domain_uuid,'1000','123456',7 FROM v_domains;")
        else:
            # A pre-policy factory snapshot must recover exactly, including its
            # obsolete PIN. Only a successful source import retires credentials.
            b.query(settings,"INSERT INTO v_voicemails SELECT gen_random_uuid(),domain_uuid,'factory-mailbox','246810',81 FROM v_domains;")

    @classmethod
    def roots(cls, state):
        roots = {'fusionpbx-config':state/'config','runtime-config':state,
                 'freeswitch-config':state/'switch-conf','phone-tls':state/'phone-tls',
                 'public-access':state/'public-access',
                 'registration-state':state/'tenant-domains/private',
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
        (roots['runtime-config']/'phone-health-instance.json').write_text(json.dumps({'schema':1,'instance_id':('a' if source else 'b')*64}))
        # Original source authority and a distinct factory pairing must never mix.
        private=roots['registration-state'];(private/'image-onboarding').mkdir(mode=0o700)
        identity='source-service' if source else 'factory-service'
        for name in b.REGISTRATION_FILES:
            path=private/name;path.write_text(json.dumps({'identity':identity,'opaque_private_value':'source-session' if source else 'factory-session'}));path.chmod(0o600)
        instance_key=ec.generate_private_key(ec.SECP256R1())
        (roots['fusionpbx-config']/'tenant-domains-instance-key.pem').write_bytes(instance_key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
        for path in (private.parent/'instance-public.json',private.parent/'ready.json',private.parent/'setup.json',private/'certificate-backoff.json',private/'image-onboarding/setup.txt',private/'image-onboarding/retry.json'):
            path.write_text(identity+' rebuildable cache');path.chmod(0o600)

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
                        patch.object(b,'LOCAL_DATABASE',(str(self.port),self.target_name,'target_app')),
                        patch.object(b,'WEB_VERSION',self.target_state/'VERSION'),patch.object(b,'control',self.control)]
        self.patches.append(patch.object(b,'installation_layout',lambda:self.manifest['installation_layout']))
        for p in self.patches:p.start()
        b.WEB_VERSION.write_text('1.0.13\n')
        policy = b.WEB_VERSION.parent/'app/voicemails/resources/voicemail_without_pins.sql'
        policy.parent.mkdir(parents=True)
        shutil.copyfile(ROOT/'app/voicemails/resources/voicemail_without_pins.sql',policy)

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
            self.assertNotIn('runtime-config/phone-health-instance.json',manifest['files'])
            self.assertEqual({name for name in manifest['files'] if name.startswith('registration-state/')}, {'registration-state/'+name for name in b.REGISTRATION_FILES})
            for name in b.REGISTRATION_FILES:
                self.assertEqual((files/'registration-state'/name).read_bytes(),(self.source_roots['registration-state']/name).read_bytes())
            self.assertNotIn(b'source-session',self.archive.read_bytes())

    def test_02_password_tamper_and_key_envelope(self):
        with self.assertRaises(b.BackupError):
            with b.verify_archive(self.archive,'Incorrect fixture password 123'):pass
        self.assertEqual(b.unseal(self.seal(self.password),self.source_roots['fusionpbx-config']/'openweb-template.key'),self.password)
        damaged=self.target_state/'damaged.owpbx';raw=bytearray(self.archive.read_bytes());raw[60]^=1;damaged.write_bytes(raw)
        with self.assertRaises(b.BackupError):
            with b.verify_archive(damaged,self.password):pass

    def test_03_windows_names_and_case_collisions(self):
        for name in ('storage/NUL.wav','storage/a:stream','storage/a.','storage/a ','storage/../x','C:/x','storage/a\\b','runtime-config/database/file','runtime-config/phone-health-instance.json','registration-state/ready.json','registration-state/image-onboarding/device.json','registration-state/image-onboarding/session.json/extra','runtime-config/tenant-domains/private/image-local.json'):
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
        body_sql="select encode(convert_to(prosrc,'UTF8'),'hex') from pg_proc where oid='public.fixture_body_bytes()'::regprocedure"
        self.assertTrue(b.query(self.target,body_sql)==b.query(self.source,body_sql))
        self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'3')
        self.assertEqual(b.query(self.target,"select greeting_id from v_voicemails where voicemail_id='1000' and voicemail_password is null"),'7')
        self.assertEqual(b.query(self.source,"select voicemail_password from v_voicemails where voicemail_id='1000'"),'123456')
        b.query(self.target,"update v_voicemails set voicemail_password='999999' where voicemail_id='1000'")
        self.assertEqual(b.query(self.target,"select count(*) from v_voicemails where voicemail_password is not null"),'0')
        self.assertEqual(b.query(self.target,"select greeting_id from v_voicemails where voicemail_id='1000'"),'7')
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
        for name in b.REGISTRATION_FILES:
            self.assertEqual((self.target_roots['registration-state']/name).read_bytes(),(self.source_roots['registration-state']/name).read_bytes())
            self.assertEqual(b.acl_kind(self.target_roots['registration-state']/name),'private')
        self.assertEqual((self.target_roots['fusionpbx-config']/'tenant-domains-instance-key.pem').read_bytes(),(self.source_roots['fusionpbx-config']/'tenant-domains-instance-key.pem').read_bytes())
        self.assertEqual(serialization.load_pem_private_key((self.target_roots['fusionpbx-config']/'tenant-domains-instance-key.pem').read_bytes(),None).curve.name,'secp256r1')
        for path in b.registration_restore_files():
            if path not in [self.target_roots['registration-state']/name for name in b.REGISTRATION_FILES]:self.assertFalse(path.exists(),str(path))
        journal=json.loads((b.RESTORE/'journal.json').read_text())
        self.assertEqual(journal['registration_files'],[str(path) for path in b.registration_restore_files()])
        self.assertTrue(all(str(path) in journal['files'] for path in b.registration_restore_files()))

    def test_07_restore_failure_recovers_database_files_and_acl_plan(self):
        mailbox_before=b.query(self.target,'select jsonb_agg(to_jsonb(v) order by voicemail_uuid)::text from v_voicemails v')
        before={p:p.read_bytes() for p in self.target_state.rglob('*') if p.is_file()}
        original=b.atomic_copy;failed=False
        def once(source,target,**kwargs):
            nonlocal failed
            if not failed:failed=True;raise b.BackupError('Injected private fixture failure')
            return original(source,target,**kwargs)
        with patch.object(b,'atomic_copy',once):
            with self.assertRaisesRegex(b.BackupError,'Injected'):b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'0')
        self.assertEqual(b.query(self.target,'select jsonb_agg(to_jsonb(v) order by voicemail_uuid)::text from v_voicemails v'),mailbox_before)
        self.assertEqual(b.query(self.target,"select count(*) from pg_trigger where tgrelid='v_voicemails'::regclass and tgname='openweb_voicemail_without_pin'"),'0')
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

    @contextlib.contextmanager
    def nested_media_archive(self):
        folder=self.source_roots['storage']/'new-private-media'
        (folder/'nested').mkdir(parents=True)
        (folder/'nested/late.wav').write_bytes(b'actual source nested private media')
        archive=self.target_state/'late-source.owpbx'
        try:
            b.create_archive(self.source,archive,self.password,roots=self.source_roots,version='1.0.13')
            yield archive
        finally:
            shutil.rmtree(folder)

    def test_13_late_restore_recovers_parent_permissions_and_created_directories(self):
        # The Windows security calls are modeled; file copies, encrypted
        # archive verification and both PostgreSQL restores are real.
        with self.nested_media_archive() as archive:
            before={p:p.read_bytes() for p in self.target_state.rglob('*') if p.is_file()}
            notification=self.target_roots['mobile-notifications']
            key=self.target_roots['fusionpbx-config']/'openweb-template.key'
            nested=self.target_roots['storage']/'new-private-media/nested/late.wav'
            original_copy=b.atomic_copy;witness=set();failed=False;acls={};restored=[]
            def native_control(operation,value=None):
                if operation=='acl-read':
                    self.native_calls.append((operation,value))
                    return {name:acls.setdefault(name,'O:SYD:P(A;OICI;FA;;;SY)' if Path(name).is_dir() else 'O:SYD:P(A;;FA;;;SY)') for name in value['paths']}
                if operation=='acl-restore':
                    self.native_calls.append((operation,value));restored.append(value['files'].copy());acls.update(value['files']);return {}
                return self.control(operation,value)
            def changed_acl(path,**kwargs):acls[str(path)]='O:BUD:P(A;;FA;;;BA)'
            def late(source,target,**kwargs):
                nonlocal failed
                original_copy(source,target,**kwargs)
                if target==key and target.read_bytes()==self.key:witness.add('template-key')
                if target==notification/'config.json' and json.loads(target.read_text())['private']=='source identity':witness.add('notification')
                if target==nested and target.read_bytes()==b'actual source nested private media':witness.add('new-media-directory')
                if len(witness)==3 and not failed:
                    failed=True
                    self.assertEqual(acls[str(notification)],'O:BUD:P(A;;FA;;;BA)')
                    raise b.BackupError('Injected late key notification and media failure')
            with patch.object(b,'control',native_control),patch.object(b,'secure_acl',changed_acl),patch.object(b,'atomic_copy',late):
                with self.assertRaisesRegex(b.BackupError,'Injected late'):b.restore(archive,self.password,self.target,confirm_database=self.target_name)
            self.assertEqual(witness,{'template-key','notification','new-media-directory'})
            self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'0')
            self.assertEqual(b.query(self.target,'select current_user'),'target_app')
            for path,data in before.items():self.assertEqual(path.read_bytes(),data)
            self.assertFalse(nested.parent.parent.exists())
            self.assertFalse((self.target_state/'restored-source').exists())
            journal=json.loads((b.RESTORE/'journal.json').read_text())
            self.assertEqual(journal['state'],'recovered')
            self.assertEqual(journal['directories'][str(notification)]['sddl'],acls[str(notification)])
            self.assertFalse(any(b.held(selection) for selection in b.HELD_UNITS))
            self.assertTrue(all(Path(name).is_dir() for name in restored[0]))
            self.assertEqual([len(Path(name).parts) for name in restored[0]],sorted(len(Path(name).parts) for name in restored[0]))
            self.assertTrue(all(Path(name).is_file() for name in restored[1]))
            self.assertFalse(list(self.target_state.rglob('.backup-restore-*')))

    def test_14_foreign_content_in_new_directory_keeps_recovery_held(self):
        with self.nested_media_archive() as archive:
            original=b.atomic_copy;failed=False
            nested=self.target_roots['storage']/'new-private-media/nested/late.wav';foreign=nested.parent/'keep.foreign'
            def late(source,target,**kwargs):
                nonlocal failed
                original(source,target,**kwargs)
                if target==nested and not failed:
                    failed=True;foreign.write_bytes(b'foreign content must survive')
                    raise b.BackupError('Injected nonempty late directory failure')
            with patch.object(b,'atomic_copy',late):
                with self.assertRaisesRegex(b.BackupError,'Services remain held'):b.restore(archive,self.password,self.target,confirm_database=self.target_name)
            self.assertEqual(foreign.read_bytes(),b'foreign content must survive')
            self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['state'],'recovery_required')
            self.assertTrue(all(b.held(selection) for selection in b.HELD_UNITS))
            with self.assertRaisesRegex(b.BackupError,'not empty'):b.recover(self.target)
            self.assertEqual(foreign.read_bytes(),b'foreign content must survive')
            foreign.unlink();b.recover(self.target)
            self.assertFalse(nested.parent.parent.exists())
            self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'0')
            self.assertFalse(any(b.held(selection) for selection in b.HELD_UNITS))

    def test_15_atomic_copy_late_permission_or_rename_failure_cleans_temporary(self):
        source=self.target_state/'atomic-source';source.write_bytes(b'replacement')
        target=self.target_roots['fusionpbx-config']/'openweb-template.key';before=target.read_bytes()
        for operation in ('secure_acl','replace_file'):
            with self.subTest(operation=operation),patch.object(b,operation,side_effect=b.BackupError('Injected late atomic failure')):
                with self.assertRaisesRegex(b.BackupError,'atomic'):b.atomic_copy(source,target)
            self.assertEqual(target.read_bytes(),before)
            self.assertFalse(list(target.parent.glob('.backup-restore-*')))

    def test_16_file_only_legacy_journal_still_recovers(self):
        legacy=self.target_state/'legacy-factory.dump';b.snapshot_database(self.target,legacy)
        with patch.object(b,'atomic_copy',side_effect=b.BackupError('Injected first copy')),patch.object(b,'_recover',side_effect=b.BackupError('Retain old recovery fixture')):
            with self.assertRaisesRegex(b.BackupError,'Services remain held'):b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        path=b.RESTORE/'journal.json';journal=json.loads(path.read_text());journal.pop('directories');journal.pop('factory_security_version')
        shutil.copyfile(legacy,b.RESTORE/'factory.dump');journal['factory_dump_sha256']=b.checksum(b.RESTORE/'factory.dump');b.atomic_json(path,journal)
        with patch.object(b,'local_database_administrator',side_effect=AssertionError('Legacy recovery must not invent security metadata')):
            b.recover(self.target)
        self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'0')
        self.assertEqual(json.loads(path.read_text())['state'],'recovered')
        self.assertFalse(any(b.held(selection) for selection in b.HELD_UNITS))

    def test_17_recovery_directory_inventory_refuses_unknown_missing_and_wrong_types(self):
        with patch.object(b,'atomic_copy',side_effect=b.BackupError('Injected first copy')),patch.object(b,'_recover',side_effect=b.BackupError('Retain guarded recovery fixture')):
            with self.assertRaisesRegex(b.BackupError,'Services remain held'):b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        path=b.RESTORE/'journal.json';original=json.loads(path.read_text())
        unknown=json.loads(json.dumps(original));unknown['directories'][str(self.target_state/'foreign-empty')]={'exists':False}
        missing=json.loads(json.dumps(original));missing['directories'].pop(str(self.target_roots['mobile-notifications']))
        wrong=json.loads(json.dumps(original));wrong['directories'][str(self.target_roots['mobile-notifications'])]['exists']='yes'
        for journal in (unknown,missing,wrong):
            b.atomic_json(path,journal)
            with self.assertRaisesRegex(b.BackupError,'directory'):b.recover(self.target)
            self.assertTrue(all(b.held(selection) for selection in b.HELD_UNITS))
        b.atomic_json(path,original);b.recover(self.target)

    def test_18_owned_parent_refuses_links_collisions_and_unowned_paths(self):
        source=self.target_state/'atomic-source';source.write_bytes(b'replacement')
        collision=self.target_roots['storage']/'file-parent';collision.write_bytes(b'ordinary existing file')
        link=self.target_roots['storage']/'linked-parent';link.symlink_to(self.target_roots['custom-sounds'],target_is_directory=True)
        targets=(collision/'target',link/'target',self.private/'outside-owned/target',self.target_roots['storage']/'../outside/target')
        for target in targets:
            with self.subTest(target=target),self.assertRaises(b.BackupError):b.atomic_copy(source,target)
        self.assertEqual(collision.read_bytes(),b'ordinary existing file')
        self.assertFalse((self.target_roots['custom-sounds']/'target').exists())

    def database_security_state(self):
        admin=b.local_database_administrator(self.target,json.loads((self.target_state/'installation.json').read_text()))
        program="define('OPENWEB_RESTORE_FIXTURE_LIBRARY_ONLY',true);require $argv[1];echo json_encode(restore_fixture_schema_queries(),JSON_THROW_ON_ERROR);"
        queries=json.loads(subprocess.run(['php','-r',program,str(ROOT/'tests/windows-restore-qualification.php')],
                                         capture_output=True,check=True).stdout)
        def rows(sql):
            return b.query(admin,"select coalesce(json_agg(row_to_json(t)),'[]') from ("+sql+") t",json_result=True)
        out={key:rows(sql) for key,sql in queries.items()}
        grantee="case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end"
        out['column_acls']=rows("select c.relname,t.attname,pg_get_userbyid(a.grantor) grantor,"+grantee+" grantee,a.privilege_type,a.is_grantable from pg_attribute t join pg_class c on c.oid=t.attrelid join pg_namespace n on n.oid=c.relnamespace cross join lateral aclexplode(t.attacl) a where n.nspname='public' order by c.relname,t.attname,grantor,grantee,a.privilege_type,a.is_grantable")
        out['sequence_acls']=rows("select c.relname,pg_get_userbyid(c.relowner) owner_name,pg_get_userbyid(a.grantor) grantor,"+grantee+" grantee,a.privilege_type,a.is_grantable from pg_class c join pg_namespace n on n.oid=c.relnamespace cross join lateral aclexplode(coalesce(c.relacl,acldefault('s',c.relowner))) a where n.nspname='public' and c.relkind='S' order by c.relname,grantor,grantee,a.privilege_type,a.is_grantable")
        out['default_acls']=rows("select coalesce(n.nspname,'global') namespace,pg_get_userbyid(d.defaclrole) owner_name,d.defaclobjtype,pg_get_userbyid(a.grantor) grantor,"+grantee+" grantee,a.privilege_type,a.is_grantable from pg_default_acl d left join pg_namespace n on n.oid=d.defaclnamespace cross join lateral aclexplode(d.defaclacl) a where n.nspname='public' or d.defaclnamespace=0 order by namespace,owner_name,d.defaclobjtype,grantor,grantee,a.privilege_type,a.is_grantable")
        out['roles']=b.query(admin,"select md5(coalesce(jsonb_agg(to_jsonb(r) order by oid),'[]')::text) from pg_authid r")
        out['database']=rows("select oid,datdba,datacl::text from pg_database where datname=current_database()")
        return out

    def custom_database_security(self):
        admin=self.target|{'database.0.username':'postgres','database.0.password':'target-admin-only'}
        b.query(admin,"""alter schema public owner to fixture_schema_owner;
          revoke all on schema public from public;grant usage,create on schema public to target_app;
          grant usage on schema public to fixture_acl_reader with grant option;
          set role fixture_acl_reader;grant usage on schema public to fixture_acl_delegate;reset role;
          alter table public.v_users owner to fixture_schema_owner;grant all on public.v_users to target_app;
          grant select on public.v_users to fixture_acl_reader with grant option;
          set role fixture_acl_reader;grant select on public.v_users to fixture_acl_delegate;reset role;
          grant update(username) on public.v_users to fixture_acl_reader with grant option;
          create sequence public.fixture_sequence;alter sequence public.fixture_sequence owner to fixture_schema_owner;
          grant usage on sequence public.fixture_sequence to fixture_acl_reader with grant option;
          set role fixture_acl_reader;grant usage on sequence public.fixture_sequence to fixture_acl_delegate;reset role;
          alter default privileges for role target_app in schema public grant select on tables to fixture_acl_reader with grant option;
          alter default privileges for role target_app in schema public grant usage on sequences to fixture_acl_reader;""")

    def test_19_wrong_password_refuses_before_privileged_metadata_access(self):
        before=self.database_security_state()
        with patch.object(b,'local_database_administrator',side_effect=AssertionError('Wrong password must refuse before privileged access')):
            with self.assertRaises(b.BackupError):b.restore(self.archive,self.password+'wrong',self.target,confirm_database=self.target_name)
        self.assertTrue(self.database_security_state()==before)
        self.assertFalse((b.RESTORE/'journal.json').exists())

    def test_20_late_recovery_preserves_native_owner_grantor_options_and_default_column_sequence_acls(self):
        self.custom_database_security();before=self.database_security_state()
        original=b.atomic_copy;failed=False
        def once(source,target,**kwargs):
            nonlocal failed
            original(source,target,**kwargs)
            if not failed:failed=True;raise b.BackupError('Injected native metadata recovery control')
        with patch.object(b,'atomic_copy',once):
            with self.assertRaisesRegex(b.BackupError,'Injected native metadata'):b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertTrue(self.database_security_state()==before)
        journal=json.loads((b.RESTORE/'journal.json').read_text())
        self.assertIs(type(journal['factory_security_version']),int);self.assertEqual(journal['factory_security_version'],1)
        self.assertEqual(journal['state'],'recovered')
        self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'0')
        self.assertFalse(any(b.held(selection) for selection in b.HELD_UNITS))

    def test_21_portable_restore_preserves_target_schema_and_default_privileges_using_target_credentials(self):
        self.custom_database_security();before=self.database_security_state()
        b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        after=self.database_security_state()
        for key in ('schema','default_acls','roles','database'):
            with self.subTest(key=key):self.assertTrue(after[key]==before[key])
        self.assertTrue(all(row['owner_name']=='target_app' for row in after['tables']))
        self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'3')
        self.assertEqual(json.loads((self.target_state/'installation.json').read_text())['PostgresPassword'],'target-admin-only')

    def test_22_failed_post_drop_import_rolls_back_then_recovers_exact_factory_security(self):
        before=self.database_security_state();original=b.run;original_recover=b._recover;injected=False;rollback_observed=[]
        def fail_sql(command,**kwargs):
            nonlocal injected
            if not injected and command[0]==b.tool('psql') and any(Path(str(value)).name=='native-source.sql' for value in command):
                injected=True
                with (b.RESTORE/'native-source.sql').open('a') as stream:stream.write('\nselect missing_owned_fixture_function();\n')
            return original(command,**kwargs)
        def observe_recovery(settings):
            rollback_observed.append(self.database_security_state()==before)
            self.assertTrue(rollback_observed[-1])
            return original_recover(settings)
        with patch.object(b,'run',fail_sql),patch.object(b,'_recover',observe_recovery):
            with self.assertRaises(b.BackupError):b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertTrue(injected);self.assertEqual(rollback_observed,[True]);self.assertTrue(self.database_security_state()==before)
        self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['state'],'recovered')

    def test_23_security_marker_refuses_wrong_types_before_hold_and_valid_marker_recovers(self):
        with patch.object(b,'atomic_copy',side_effect=b.BackupError('Injected copy')),patch.object(b,'_recover',side_effect=b.BackupError('Retain native recovery fixture')):
            with self.assertRaises(b.BackupError):b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        path=b.RESTORE/'journal.json';original=json.loads(path.read_text())
        for version in (None,True,False,0,1.0,'1',2,{},[]):
            b.atomic_json(path,original|{'factory_security_version':version})
            with patch.object(b,'control') as native,patch.object(b,'local_database_administrator') as admin:
                with self.subTest(version_type=type(version).__name__),self.assertRaises(b.BackupError):b.recover(self.target)
                native.assert_not_called();admin.assert_not_called()
        b.atomic_json(path,original);b.recover(self.target)
        self.assertEqual(json.loads(path.read_text())['state'],'recovered')

    def test_24_invalid_native_factory_metadata_refuses_before_service_hold_or_schema_mutation(self):
        before=self.database_security_state();original=b.snapshot_database
        def corrupt(settings,destination,**kwargs):
            original(settings,destination,**kwargs);destination.write_bytes(b'not a native dump')
        with patch.object(b,'snapshot_database',corrupt):
            with self.assertRaises(b.BackupError):b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertFalse(any(operation=='hold' for operation,_ in self.native_calls))
        self.assertFalse((b.RESTORE/'journal.json').exists());self.assertTrue(self.database_security_state()==before)

    def test_25_failure_after_voicemail_policy_recovers_exact_factory_mailbox_without_migrating_recovery(self):
        before=self.database_security_state()
        mailbox_before=b.query(self.target,'select jsonb_agg(to_jsonb(v) order by voicemail_uuid)::text from v_voicemails v')
        original=b.query;policy_applied=[]
        def fail_after_policy(settings,sql,**kwargs):
            if sql.startswith('update v_pbx_backup_commands'):
                policy_applied.append(original(settings,"select count(*) from v_voicemails where voicemail_password is null and greeting_id=7"))
                self.assertEqual(policy_applied[-1],'1')
                raise b.BackupError('Injected post-policy source import failure')
            return original(settings,sql,**kwargs)
        with patch.object(b,'query',side_effect=fail_after_policy):
            with self.assertRaisesRegex(b.BackupError,'Injected post-policy'):
                b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertEqual(policy_applied,['1'])
        self.assertEqual(b.query(self.target,'select jsonb_agg(to_jsonb(v) order by voicemail_uuid)::text from v_voicemails v'),mailbox_before)
        self.assertEqual(b.query(self.target,"select voicemail_password from v_voicemails where voicemail_id='factory-mailbox'"),'246810')
        self.assertEqual(b.query(self.target,"select count(*) from pg_trigger where tgrelid='v_voicemails'::regclass and tgname='openweb_voicemail_without_pin'"),'0')
        self.assertEqual(self.database_security_state(),before)
        self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['state'],'recovered')
        self.assertFalse(any(b.held(selection) for selection in b.HELD_UNITS))

    def health_rows(self, settings):
        return b.query(settings,'select jsonb_agg(to_jsonb(t) order by recovery_uuid) from v_pbx_phone_health_recoveries t',json_result=True)

    def test_26_same_machine_restore_refuses_only_source_pending_health_requests(self):
        identity=self.target_state/'phone-health-instance.json'
        # Same physical installation keeps its protected identity. It must not
        # make an old restored confirmation executable a second time.
        identity.write_bytes((self.source_state/'phone-health-instance.json').read_bytes())
        before=identity.read_bytes();source=self.health_rows(self.source)
        factory=self.health_rows(self.target)
        b.restore(self.archive,self.password,self.target,dry_run=True)
        self.assertEqual(self.health_rows(self.target),factory)
        self.assertEqual(identity.read_bytes(),before)
        b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        expected=[row|{'status':'refused'} if row['status']=='pending' else row for row in source]
        self.assertEqual(self.health_rows(self.target),expected)
        self.assertEqual(self.health_rows(self.source),source)
        self.assertEqual(identity.read_bytes(),before)
        self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['phone_health_recoveries_refused'],2)
        self.assertEqual(b.refuse_restored_phone_recoveries(self.target),0)
        self.assertTrue(all(b.held(selection) for selection in b.HELD_UNITS))

    def test_27_post_health_invalidation_failure_recovers_complete_factory_history(self):
        before=self.health_rows(self.target);source=self.health_rows(self.source)
        identity=self.target_state/'phone-health-instance.json';identity_before=identity.read_bytes()
        original=b.refuse_restored_phone_recoveries;reached=[]
        def fail_after_invalidation(settings):
            count=original(settings);reached.append(count)
            self.assertEqual(count,2)
            self.assertTrue(all(row['status']!='pending' for row in self.health_rows(settings)))
            raise b.BackupError('Injected post-health invalidation failure')
        with patch.object(b,'refuse_restored_phone_recoveries',side_effect=fail_after_invalidation):
            with self.assertRaisesRegex(b.BackupError,'Injected post-health'):
                b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertEqual(reached,[2])
        self.assertEqual(self.health_rows(self.target),before)
        self.assertEqual(self.health_rows(self.source),source)
        self.assertEqual(identity.read_bytes(),identity_before)
        self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['state'],'recovered')
        self.assertFalse(any(b.held(selection) for selection in b.HELD_UNITS))

    def test_28_late_registration_import_recovers_all_factory_caches_and_keeps_target_marker(self):
        marker=self.target_state/'installation-policy/onboarding-required'
        marker.parent.mkdir();marker.write_bytes(b'owned target installation requirement')
        before={path:path.read_bytes() for path in self.target_state.rglob('*') if path.is_file()}
        security=self.database_security_state();original=b.atomic_copy;injected=False
        archive_sha=b.checksum(self.archive)
        def fail_after_session(source,target,**kwargs):
            nonlocal injected
            original(source,target,**kwargs)
            if target==self.target_roots['registration-state']/'image-onboarding/session.json' and not injected:
                injected=True
                self.assertEqual(target.read_bytes(),(self.source_roots['registration-state']/'image-onboarding/session.json').read_bytes())
                self.assertEqual((self.target_roots['fusionpbx-config']/'tenant-domains-instance-key.pem').read_bytes(),(self.source_roots['fusionpbx-config']/'tenant-domains-instance-key.pem').read_bytes())
                self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'3')
                raise b.BackupError('Injected after actual source session and P256 import')
        with patch.object(b,'atomic_copy',fail_after_session):
            with self.assertRaisesRegex(b.BackupError,'Injected after actual source session'):
                b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        self.assertTrue(injected)
        for path,data in before.items():self.assertEqual(path.read_bytes(),data,str(path))
        self.assertEqual(self.database_security_state(),security)
        self.assertEqual(b.checksum(self.archive),archive_sha)
        journal_file=b.RESTORE/'journal.json';journal=json.loads(journal_file.read_text())
        self.assertEqual(journal['state'],'recovered')
        self.assertEqual(len(journal['registration_files']),8)
        self.assertFalse(any(b.held(selection) for selection in b.HELD_UNITS))
        tampered=json.loads(json.dumps(journal));tampered['registration_files'].append(str(marker));b.atomic_json(journal_file,tampered)
        with patch.object(b,'restore_database') as restore:
            with self.assertRaisesRegex(b.BackupError,'registration recovery inventory'):b._recover(self.target)
            restore.assert_not_called()
        b.atomic_json(journal_file,journal)

    def test_29_initially_absent_consumer_directory_keeps_only_persistent_coordination_after_recovery(self):
        private=self.target_roots['registration-state'];directory=private/'image-onboarding'
        shutil.rmtree(directory)
        before={path:path.read_bytes() for path in private.rglob('*') if path.is_file()}
        original=b.atomic_copy;failed=False;inode=[]
        def once(source,target,**kwargs):
            nonlocal failed
            if not failed:
                failed=True;inode.append((directory/'worker.lock').stat().st_ino)
                raise b.BackupError('Injected after persistent registration guard establishment')
            return original(source,target,**kwargs)
        with patch.object(b,'atomic_copy',once):
            with self.assertRaisesRegex(b.BackupError,'Injected after persistent registration'):
                b.restore(self.archive,self.password,self.target,confirm_database=self.target_name)
        for path,value in before.items():self.assertEqual(path.read_bytes(),value)
        self.assertEqual({path for path in private.rglob('*') if path.is_file()}-set(before),{directory/'worker.lock'})
        self.assertEqual((directory/'worker.lock').stat().st_ino,inode[0])
        self.assertEqual(json.loads((b.RESTORE/'journal.json').read_text())['state'],'recovered')
        self.assertEqual(b.query(self.target,'select count(*) from fixture_objects'),'0')


if __name__=='__main__':
    unittest.main()
