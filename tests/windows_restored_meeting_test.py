"""Real local files/PG and explicit Windows API doubles; no native media claim."""
import copy
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
def load(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
m=load('windows_restored_meeting');process=load('windows_meeting_owned_process')
ID='11111111-1111-4111-8111-111111111111';DOMAIN='22222222-2222-4222-8222-222222222222'
OWNER='33333333-3333-4333-8333-333333333333';NEW='44444444-4444-4444-8444-444444444444'
MEMBER='55555555-5555-4555-8555-555555555555';SUBJECT='Owned Windows video '+'a'*24
IDENTITY={'domain_uuid':DOMAIN,'owner_user_uuid':OWNER}


class FilesAndContracts(unittest.TestCase):
    def test_actual_adapter_preserves_primary_and_reports_independent_cleanup_failure(self):
        for cleanup_failure in (False, True):
            with self.subTest(cleanup_failure=cleanup_failure),tempfile.TemporaryDirectory(prefix='restored-meet-primary-') as td:
                root=Path(td);work=root/'restore';work.mkdir();adapter=root/'native';adapter.mkdir()
                state=root/'state';state.mkdir();held=state/'restore';held.mkdir()
                for name in ('jobs','updates','backups'):(held/('hold-'+name)).write_text('{}')
                for name in ('runtime.json','meet-ca.pem','phone-tls.json'):(state/name).write_text('original')
                config=root/'config';config.write_text('original');inp=work/'input.json';inp.write_text('{}')
                ca=root/'ca.pem';key=root/'ca.key'
                r=subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(ca),'-days','1','-subj','/CN=owned-review.invalid'],capture_output=True,timeout=20)
                self.assertEqual(r.returncode,0)
                identity=IDENTITY|{'service_uuid':ID,'tenant_uuid':NEW,'home_domain_uuid':MEMBER,'domain_name':'pbx-abcdef123456.company-abcdef123456.windowsqa.example.invalid'}
                inventory={'v_pbx_meetings':[],'v_pbx_meeting_members':[],'bindings':[]}
                primary=ValueError('PRIVATE exact original caller failure')
                def query(sql):
                    if sql.startswith('select json_build_object'):return [{'inventory':copy.deepcopy(inventory)}]
                    if sql.startswith('select s.service_uuid'):return [identity]
                    if sql.startswith('select user_uuid'):return [{'user_uuid':OWNER,'domain_uuid':MEMBER,'username':'qa@example.invalid','user_enabled':'true'}]
                    if sql.startswith('select domain_uuid'):return [{'domain_uuid':DOMAIN,'domain_name':identity['domain_name']}]
                    raise AssertionError('Unexpected query')
                def web(source):self.assertIs(source,True);raise primary
                calls=[]
                def es(command):
                    calls.append(command)
                    if cleanup_failure:raise RuntimeError('synthetic cleanup refusal')
                    return json.dumps({'row_count':0})
                q=types.SimpleNamespace(s={'owned':identity,'admin_email':'qa@example.invalid','web_ca':str(ca),'run_id':'1234','source_commit':'d'*40,'scope':'b'*24},
                    query=query,work=work,path=inp,source=HERE.parent,web=web,es_api=es,
                    backups=types.SimpleNamespace(RESTORE=held,STATE=state,CONFIG=config))
                original=inp.read_bytes();before=dict(os.environ)
                with patch.object(m,'admit',side_effect=lambda current,path:self.assertIs(current,q)),self.assertRaises(ValueError) as caught:
                    m.qualify(q,adapter)
                self.assertIs(caught.exception,primary)
                self.assertEqual(getattr(primary,'restored_meeting_cleanup_verified'),not cleanup_failure)
                self.assertEqual(bool(getattr(primary,'restored_meeting_cleanup_failed',False)),cleanup_failure)
                self.assertEqual(inp.read_bytes(),original);self.assertEqual(dict(os.environ),before)
                self.assertFalse((work/'restored-conference.safe.json').exists())
                self.assertEqual(calls,['show channels as json'])
                self.assertEqual(adapter.exists(),cleanup_failure)

    def test_platform_refusal_precedes_installed_state(self):
        with patch.object(m,'load',side_effect=AssertionError('installed input')) as child:
            with self.assertRaises(RuntimeError):m.main()
            child.assert_not_called()
        with patch.object(process.ctypes,'WinDLL',create=True,side_effect=AssertionError('native access')) as native:
            with self.assertRaises(RuntimeError):process.run(['not-executed'],Path('/not-created'))
            native.assert_not_called()

    def test_exact_adapter_admission_and_required_original_gates(self):
        with tempfile.TemporaryDirectory(prefix='restored-meet-admission-') as td:
            root=Path(td);scope='b'*24;adapter=root/'OpenWebPBX/native-qualification'/('a'*24);adapter.mkdir(parents=True)
            work=root/'OpenWebPBX/restore-qualification'/scope;work.mkdir(parents=True);inp=work/'input.json';inp.write_text('{}')
            s={'scope':scope,'role':'target','run_id':'1234','source_commit':'d'*40,'disposable':True}
            gates={key:'passed' for key in ('explicit_restored_calls_activation','restored_original_credentials_two_way_decoded_native_audio','restored_original_native_voicemail_121_pin_free_retrieval','restored_original_native_clock_1026_Nathaniel_GMT2_audio')}
            q=types.SimpleNamespace(s=s,path=inp,work=work,source=HERE,facts={'gates':gates},backups=types.SimpleNamespace(held=lambda name:name!='calls'),es_api=lambda _:json.dumps({'row_count':0}))
            env={'ProgramData':td,'GITHUB_WORKSPACE':str(HERE),'OPENWEB_WINDOWS_RESTORE_TEST':'1','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted','GITHUB_REPOSITORY':'embire2/openwebpbx','GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_RUN_ID':'1234','GITHUB_SHA':'d'*40}
            with patch.object(m,'os',types.SimpleNamespace(name='nt',environ=env)):
                m.admit(q,adapter)
                for key,value in [('role','source'),('run_id','99'),('source_commit','e'*40),('disposable',1)]:
                    old=s[key];s[key]=value
                    with self.subTest(key=key),self.assertRaises(RuntimeError):m.admit(q,adapter)
                    s[key]=old
                for name in gates:
                    gates[name]='unqualified'
                    with self.subTest(gate=name),self.assertRaises(RuntimeError):m.admit(q,adapter)
                    gates[name]='passed'
                for names in [('calls','jobs','updates','backups'),('jobs','updates'),('jobs','backups')]:
                    q.backups.held=lambda name:name in names
                    with self.subTest(holds=names),self.assertRaises(RuntimeError):m.admit(q,adapter)
                q.backups.held=lambda name:name!='calls'
                for count in (False,1,'0',None):
                    q.es_api=lambda _,count=count:json.dumps({'row_count':count})
                    with self.subTest(channels=count),self.assertRaises(RuntimeError):m.admit(q,adapter)
                q.es_api=lambda _:json.dumps({'row_count':0})
                env['GITHUB_WORKSPACE']=str(root)
                with self.assertRaises(RuntimeError):m.admit(q,adapter)
                env['GITHUB_WORKSPACE']=str(HERE)
                (adapter/'input.json').write_text('{}')
                with self.assertRaises(RuntimeError):m.admit(q,adapter)
                (adapter/'input.json').unlink();link=root/'link';link.symlink_to(adapter,target_is_directory=True)
                with self.assertRaises(RuntimeError):m.admit(q,link)

    def test_native_environment_exact_even_when_body_fails(self):
        for original in (None,'previous-value','1'):
            environment={} if original is None else {'OPENWEB_WINDOWS_NATIVE_TEST':original}
            with patch.dict(os.environ,environment,clear=True):
                primary=ValueError('synthetic primary')
                with self.assertRaises(ValueError) as caught:
                    with m.native_environment():
                        self.assertEqual(os.environ['OPENWEB_WINDOWS_NATIVE_TEST'],'1');raise primary
                self.assertIs(caught.exception,primary);self.assertEqual(os.environ.get('OPENWEB_WINDOWS_NATIVE_TEST'),original)

    def test_closed_media_thresholds_remain_original(self):
        good={'checks':9,'wss_roundtrips':16,'host_frames':10,'guest_frames':10,'host_tone_ratio':.66,'guest_tone_ratio':.8,'physical_camera':'unqualified'}
        self.assertEqual(m.closed_summary(good),good)
        for key,value in [('checks',8),('checks',True),('wss_roundtrips',15),('host_frames',9),('guest_frames',True),('host_tone_ratio',.65),('guest_tone_ratio',float('nan')),('guest_tone_ratio',float('inf')),('physical_camera','passed'),('secret','private')]:
            with self.subTest(key=key,value=value),self.assertRaises(RuntimeError):m.closed_summary(good|{key:value})

    def test_private_json_and_path_refusals(self):
        with tempfile.TemporaryDirectory(prefix='restored-meet-files-') as td:
            root=Path(td);p=root/'input.json';p.write_text('{"a":1,"a":2}')
            with self.assertRaises(RuntimeError):m.read_json(p)
            p.write_text('{"a":NaN}')
            with self.assertRaises(RuntimeError):m.read_json(p)
            p.write_text('{}');alias=root/'alias';alias.symlink_to(p)
            with self.assertRaises(RuntimeError):m.read_json(alias)
            with self.assertRaises(RuntimeError):m.read_json(p,1)
            with self.assertRaises(FileExistsError):m.write_new(p,{'new':1})
            self.assertEqual(p.read_text(),'{}')


class ActualPostgresRows(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.name!='posix':raise RuntimeError('This socket-only fixture refuses before native path access.')
        cls.pg=Path('/usr/lib/postgresql/18/bin');cls.root=Path(tempfile.mkdtemp(prefix='restored-meet-pg-'));cls.started=False;cls.prefix=[]
        if os.geteuid()==0:
            account=pwd.getpwnam('postgres');os.chown(cls.root,account.pw_uid,account.pw_gid);cls.prefix=['runuser','-u','postgres','--']
        cls.addClassCleanup(cls.cleanup)
        cls.command('initdb','-D',str(cls.root/'data'),'--no-locale','-E','UTF8','--auth-local=trust','--auth-host=reject')
        cls.socket=cls.root/'socket';cls.socket.mkdir(mode=0o700)
        if cls.prefix:os.chown(cls.socket,account.pw_uid,account.pw_gid)
        cls.command('pg_ctl','-D',str(cls.root/'data'),'-l',str(cls.root/'postgres.log'),'-o',f"-k {cls.socket} -p 55487 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=8 -c autovacuum=off",'-w','-t','20','start');cls.started=True
        cls.pid=int((cls.root/'data/postmaster.pid').read_text().splitlines()[0])
        cls.process_start=Path(f'/proc/{cls.pid}/stat').read_text().split()[21]
        cls.sql('create table v_pbx_meetings(meeting_uuid uuid primary key,domain_uuid uuid,owner_uuid uuid,subject text,ended_at text,invite_hash text);create table v_pbx_meeting_members(member_uuid uuid primary key,meeting_uuid uuid,state text,token_hash text);create table v_sip_profile_settings(sip_profile_uuid uuid,value text);')

    @classmethod
    def command(cls,name,*args):
        r=subprocess.run(cls.prefix+[str(cls.pg/name),*args],capture_output=True,text=True,timeout=40)
        if r.returncode:raise AssertionError(r.stderr)
        return r.stdout
    @classmethod
    def sql(cls,sql):return cls.command('psql','-X','-A','-t','-h',str(cls.socket),'-p','55487','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-c',sql).strip()
    @classmethod
    def cleanup(cls):
        if cls.started:cls.command('pg_ctl','-D',str(cls.root/'data'),'-m','fast','-w','-t','20','stop');cls.started=False
        shutil.rmtree(cls.root)
        if hasattr(cls,'pid'):
            stat=Path(f'/proc/{cls.pid}/stat');gone=not stat.exists() or stat.read_text().split()[21]!=cls.process_start
            if not gone or cls.root.exists():raise AssertionError('Owned PostgreSQL process/tree survived.')
            if os.environ.get('OPENWEB_RESTORED_MEETING_EVIDENCE'):
                Path(os.environ['OPENWEB_RESTORED_MEETING_EVIDENCE']).write_text(json.dumps({'owned_pg_pid':cls.pid,'owned_pg_start':cls.process_start,'owned_pg_data_directory':str(cls.root/'data'),'socket_only':True,'owned_process_exited':gone,'owned_tree_removed':not cls.root.exists()})+'\n')
    def setUp(self):
        self.sql("truncate v_pbx_meeting_members,v_pbx_meetings,v_sip_profile_settings;insert into v_pbx_meetings values ('"+ID+"','"+DOMAIN+"','"+OWNER+"','Existing meeting',null,'existing-invite');insert into v_sip_profile_settings values ('cfb1c835-c30c-409b-bff7-a893a7e84df1','target-private-binding');")
        self.q=types.SimpleNamespace(query=lambda sql:json.loads(self.sql("select coalesce(json_agg(row_to_json(t)),'[]'::json) from ("+sql+") t")))
        self.before=m.rows(self.q)
    def create(self):
        self.sql("insert into v_pbx_meetings values ('"+NEW+"','"+DOMAIN+"','"+OWNER+"','"+SUBJECT+"','ended','new-invite');insert into v_pbx_meeting_members values ('"+MEMBER+"','"+NEW+"','admitted','new-token');")
    def ledger(self):return {'schema':1,'meeting_uuid':NEW,'subject':SUBJECT}
    def test_actual_single_snapshot_new_meeting_and_historical_invite_preservation(self):
        self.create();after=m.rows(self.q)
        self.assertEqual(m.preserved_rows(self.before,after,IDENTITY,SUBJECT,self.ledger(),True),NEW)
        self.assertEqual(self.before['v_pbx_meetings'][0]['invite_hash'],'existing-invite')
    def test_actual_pg_existing_row_member_binding_and_foreign_owner_refusals(self):
        self.create();valid=m.rows(self.q)
        for sql in ["update v_pbx_meetings set invite_hash='changed' where meeting_uuid='"+ID+"'", "update v_pbx_meetings set subject='changed' where meeting_uuid='"+ID+"'", "update v_sip_profile_settings set value='different-target'", "update v_pbx_meetings set owner_uuid='"+ID+"' where meeting_uuid='"+NEW+"'", "update v_pbx_meetings set domain_uuid='"+ID+"' where meeting_uuid='"+NEW+"'", "insert into v_pbx_meeting_members values ('"+ID+"','"+ID+"','admitted','foreign-token')", "insert into v_pbx_meetings values ('"+MEMBER+"','"+DOMAIN+"','"+OWNER+"','"+SUBJECT+"',null,'duplicate')"]:
            # Each mutation uses its own committed state, then restores only the
            # newly owned socket fixture through the recorded valid rows.
            self.sql(sql)
            with self.subTest(sql=sql),self.assertRaises(RuntimeError):m.preserved_rows(self.before,m.rows(self.q),IDENTITY,SUBJECT,self.ledger(),True)
            self.setUp();self.create()
        self.assertEqual(m.rows(self.q),valid)
    def test_exact_ledger_and_success_requirements(self):
        self.create();after=m.rows(self.q)
        for edit in ({'meeting_uuid':ID},{'subject':'foreign'},{'schema':True},{'extra':'secret'}):
            with self.subTest(edit=edit),self.assertRaises(RuntimeError):m.preserved_rows(self.before,after,IDENTITY,SUBJECT,self.ledger()|edit,True)
        with self.assertRaises(RuntimeError):m.preserved_rows(self.before,after,IDENTITY,SUBJECT,None,True)
        self.sql("update v_pbx_meetings set ended_at=null where meeting_uuid='"+NEW+"'")
        with self.assertRaises(RuntimeError):m.preserved_rows(self.before,m.rows(self.q),IDENTITY,SUBJECT,self.ledger(),True)
        self.assertEqual(m.preserved_rows(self.before,m.rows(self.q),IDENTITY,SUBJECT,self.ledger(),False),NEW)


class NativeJobApiAdapter(unittest.TestCase):
    def test_actual_job_wrapper_order_and_owned_failure_cleanup(self):
        # Actual ctypes structures/control flow, explicit Win32 API double.
        # This does not execute Windows processes or claim native job ownership.
        class Function:
            def __init__(self,fn):self.fn=fn
            def __call__(self,*a):return self.fn(*a)
        for fault in ('none','assign','resume','timeout','survivor','close'):
            with self.subTest(fault=fault),tempfile.TemporaryDirectory(prefix='meeting-job-double-') as td:
                seen=[];active=[0];clock=[0];handles=[10];closed=[]
                def call(name,*args):
                    seen.append(name)
                    if name=='CreateJobObjectW':return 1
                    if name=='SetInformationJobObject':
                        self.assertEqual(args[2]._obj.basic.flags,0x2000);return 1
                    if name=='CreateFileW':
                        if args[0]!='NUL':Path(args[0]).write_bytes(b'')
                        handles[0]+=1;return handles[0]
                    if name=='CreateProcessW':
                        self.assertEqual(args[5],0x08000004);args[-1]._obj.process=2;args[-1]._obj.thread=3;args[-1]._obj.pid=24;active[0]=1;return 1
                    if name=='AssignProcessToJobObject':return 0 if fault=='assign' else 1
                    if name=='ResumeThread':return 0xffffffff if fault=='resume' else 1
                    if name=='WaitForSingleObject':
                        if fault=='timeout' and active[0]:return 258
                        return 0
                    if name=='GetExitCodeProcess':args[1]._obj.value=0;return 1
                    if name=='QueryInformationJobObject':
                        if fault not in ('timeout','survivor','resume'):active[0]=0
                        args[2]._obj.active=active[0];return 1
                    if name in ('TerminateJobObject','TerminateProcess'):active[0]=0;return 1
                    if name=='CloseHandle':closed.append(args[0]);return 0 if fault=='close' and args[0]==1 else 1
                    raise AssertionError(name)
                kernel=types.SimpleNamespace(**{name:Function(lambda *a,n=name:call(n,*a)) for name in ('CreateJobObjectW','SetInformationJobObject','QueryInformationJobObject','AssignProcessToJobObject','TerminateJobObject','CreateFileW','CreateProcessW','ResumeThread','WaitForSingleObject','GetExitCodeProcess','TerminateProcess','CloseHandle')})
                def now():clock[0]+=100;return clock[0]
                with patch.object(process,'os',types.SimpleNamespace(name='nt',environ={'RUNNER_ENVIRONMENT':'github-hosted','GITHUB_REPOSITORY':'embire2/openwebpbx'})),patch.object(process.ctypes,'WinDLL',create=True,return_value=kernel),patch.object(process.ctypes,'WinError',create=True,side_effect=lambda code:OSError(code,'native-double')),patch.object(process.ctypes,'get_last_error',create=True,return_value=5),patch.object(process,'time',types.SimpleNamespace(monotonic=now,sleep=lambda _:None)):
                    if fault=='none':self.assertEqual(process.run(['/explicit/node.exe'],Path(td)).returncode,0)
                    else:
                        with self.assertRaises((OSError,RuntimeError,subprocess.TimeoutExpired)):process.run(['/explicit/node.exe'],Path(td))
                self.assertLess(seen.index('CreateProcessW'),seen.index('AssignProcessToJobObject'))
                if fault=='assign':self.assertNotIn('ResumeThread',seen);self.assertIn('TerminateProcess',seen)
                else:self.assertLess(seen.index('AssignProcessToJobObject'),seen.index('ResumeThread'))
                if fault in ('resume','timeout','survivor'):self.assertIn('TerminateJobObject',seen)
                self.assertEqual(active[0],0);self.assertEqual(set(closed),{1,2,3,11,12,13})
                proof=json.loads((Path(td)/'process.safe.json').read_text())
                self.assertIs(proof['ordinary_exit'],fault=='none')
                self.assertIs(proof['handles_closed'],fault!='close')


if __name__=='__main__':unittest.main()
