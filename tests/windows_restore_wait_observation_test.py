"""Actual timeout/source/projection controls; native task APIs are explicit doubles."""
import ast,contextlib,copy,hashlib,importlib.util,io,json,os,subprocess,sys,tempfile,types,unittest
from pathlib import Path
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
BASE='9f826eccd6cb6c792bdc949e7b6e551c5cea4f5b'
def read_original(name):
    supplied=os.environ.get('OPENWEB_RESTORE_WAIT_ORIGINALS')
    if supplied:return (Path(supplied)/'tests'/name).read_text()
    return subprocess.check_output(['git','-C',str(HERE.parent),'show',BASE+':tests/'+name],timeout=20).decode()
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);sys.modules[name]=m;spec.loader.exec_module(m);return m
ORIGINAL_PY=read_original('windows-restore-qualification.py')
ORIGINAL_PS=read_original('windows-restore-qualification.ps1')
old=types.ModuleType('old_restore_wait');old.__file__=str(HERE/'windows-restore-qualification.py');sys.modules[old.__name__]=old
exec(compile(ORIGINAL_PY,old.__file__,'exec'),old.__dict__)
new=load('new_restore_wait',HERE/'windows-restore-qualification.py')

class Clock:
    def __init__(self):self.value=-40;self.sleeps=[];self.reads=[]
    def monotonic(self):self.value+=40;self.reads.append(self.value);return self.value
    def sleep(self,value):self.sleeps.append(value)

def invoke(module,*,success=False,primary=None,observer=None,owner=None):
    calls=[];answer=object();clock=Clock()
    def finalized():
        calls.append(len(calls))
        if primary is not None and len(calls)==2:raise primary
        return answer if success and len(calls)==2 else None
    namespace={'wait_for':module.wait_for}
    exec(compile('def media(self, predicate):\n return wait_for(predicate,120)\n',str(HERE/'windows-restore-qualification.py'),'exec'),namespace)
    caught=None;value=None
    with patch.object(module,'time',types.SimpleNamespace(monotonic=clock.monotonic,sleep=clock.sleep)):
        callback=patch.object(module,'observe_restore_wait_timeout',observer) if observer is not None else contextlib.nullcontext()
        with callback:
            try:value=namespace['media'](owner,finalized)
            except BaseException as error:caught=error
    return dict(error=caught,result=value,answer=answer,calls=len(calls),sleeps=clock.sleeps,reads=clock.reads)

def record():
    return dict(schema=1,wait_kind='manual_backup_complete',timeout_seconds=600,
                source_basename='windows-restore-qualification.py',caller_function='backup_request',caller_line=1018)

class WaitSemantics(unittest.TestCase):
    def test_old_timeout_omits_new_evidence_same_actual_wait_body(self):
        a,b=invoke(old),invoke(new)
        for k in ('calls','sleeps','reads'):self.assertEqual(a[k],b[k])
        self.assertEqual(a['calls'],2);self.assertEqual(a['sleeps'],[.2,.2])
        self.assertIs(type(a['error']),TimeoutError);self.assertIs(type(b['error']),TimeoutError)
        self.assertEqual(str(a['error']),str(b['error']))
        self.assertFalse(hasattr(a['error'],'restore_wait_failure'))
        r=new.restore_wait_failure_fields(b['error'].restore_wait_failure)
        self.assertEqual((r['wait_kind'],r['timeout_seconds'],r['caller_function']),('native_media_files',120,'media'))
        self.assertEqual(r['source_basename'],'windows-restore-qualification.py');self.assertGreater(r['caller_line'],0)
    def test_success_and_predicate_exception_do_not_observe(self):
        observed=[]
        def forbidden(*args):observed.append(args);raise AssertionError('Observer executed before timeout')
        for module in (old,new):
            result=invoke(module,success=True,observer=forbidden if module is new else None)
            self.assertIs(result['result'],result['answer']);self.assertIsNone(result['error']);self.assertEqual(result['calls'],2)
            for primary in (ValueError('PRIVATE predicate'),TimeoutError('PRIVATE nested timeout')):
                result=invoke(module,primary=primary,observer=forbidden if module is new else None)
                self.assertIs(result['error'],primary);self.assertFalse(hasattr(primary,'restore_wait_failure'))
        self.assertEqual(observed,[])
    def test_observer_failure_preserves_exact_active_timeout_identity(self):
        for failure in (RuntimeError('PRIVATE observer failure'),SystemExit(99),KeyboardInterrupt()):
            seen=[]
            def broken(*args):seen.append(sys.exception());raise failure
            result=invoke(new,observer=broken)
            self.assertEqual(len(seen),1);self.assertIs(result['error'],seen[0]);self.assertIs(type(result['error']),TimeoutError)
            self.assertEqual(result['calls'],2);self.assertEqual(result['sleeps'],[.2,.2]);self.assertFalse(hasattr(result['error'],'restore_wait_failure'))
    def test_private_or_unknown_observer_values_never_project(self):
        for edit in ({'schema':True},{'caller_line':True},{'caller_line':0},{'caller_line':1000000},
                     {'wait_kind':'PRIVATE'},{'timeout_seconds':601},{'caller_function':'media'},
                     {'source_basename':'PRIVATE.pem'},{'private':'SECRET'}):
            with self.subTest(edit=edit):self.assertEqual(new.restore_wait_failure_fields(record()|edit),{})
        task=dict(state='Running',last_result=267009,expected_system_action=True,last_run_available=True)
        self.assertEqual(new.restore_wait_failure_fields(record()|{'backup_task':task})['backup_task'],task)
        for edit in ({'state':'PRIVATE'},{'last_result':True},{'last_result':-1},{'last_result':4294967296},
                     {'expected_system_action':1},{'last_run_available':'yes'},{'private':'SECRET'}):
            with self.subTest(task_edit=edit):self.assertEqual(new.restore_wait_failure_fields(record()|{'backup_task':task|edit}),{})
    def test_all_current_wait_sites_have_exact_fixed_contexts(self):
        source=ast.parse((HERE/'windows-restore-qualification.py').read_text());observed=set()
        for cls in source.body:
            if isinstance(cls,ast.ClassDef) and cls.name=='Qualification':
                for func in cls.body:
                    if not isinstance(func,ast.FunctionDef):continue
                    for node in ast.walk(func):
                        if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id=='wait_for':
                            name='<lambda>' if isinstance(node.args[0],ast.Lambda) else node.args[0].id
                            seconds=node.args[1].value if len(node.args)>1 else 120;observed.add((func.name,name,seconds))
        self.assertEqual(observed,set(new.RESTORE_WAIT_SITES));self.assertEqual(len(observed),10)
    def test_whole_originals_reconstruct_from_declared_failure_additions(self):
        candidate=(HERE/'windows-restore-qualification.py').read_text()
        begin=candidate.index('RESTORE_WAIT_SITES = {');end=candidate.index('def wait_for(predicate, seconds=120):',begin)
        candidate=candidate[:begin]+candidate[end:]
        def function(text,name):
            node=next(n for n in ast.parse(text).body if isinstance(n,ast.FunctionDef) and n.name==name)
            return ast.get_source_segment(text,node)
        old_wait=function(ORIGINAL_PY,'wait_for');new_wait=function(candidate,'wait_for')
        self.assertEqual(old_wait.rsplit("\n    raise TimeoutError(",1)[0],new_wait.rsplit("\n    try:",1)[0])
        candidate=candidate.replace(new_wait,old_wait,1)
        projection="\n        try:\n            observation = restore_wait_failure_fields(getattr(error, 'restore_wait_failure', None))\n            if observation: facts['wait_failure'] = observation\n        except BaseException: pass"
        self.assertEqual(candidate.count(projection),1);candidate=candidate.replace(projection,'',1)
        self.assertEqual(candidate,ORIGINAL_PY)
        parent=(HERE/'windows-restore-qualification.ps1').read_text()
        begin=parent.index('function SafeRestoreWaitFailure($Record){');end=parent.index('function NativeFixture([string]$Action){',begin)
        parent=parent[:begin]+parent[end:]
        begin=parent.index("  try{\n   if($Action -cin @('export-source','target-backup','native-source','native-target','job')")
        end=parent.index('  }catch{}\n',begin)+len('  }catch{}\n')
        parent=parent[:begin]+parent[end:]
        # A conference QA overlay adds one independently reviewed function,
        # switch and target invocation. Permit only its complete frozen bytes.
        if parent != ORIGINAL_PS:
            self.assertIn(hashlib.sha256(parent.encode()).hexdigest(),('2c8f94b490e2d56d3e41032e68af0a20bbfede8ef18be723370cbc3ea9f1eb70','e117d9d3d6d70dc569d70b84377f285ae4bce6e9fbcf3738615f7715b8ccd6da','76d1d1e1462d0a4ff8f44b2b91dce24fb134f46a23871b47ddc224095d44562a'))
        else:self.assertEqual(parent,ORIGINAL_PS)
    def test_actual_top_level_producer_emits_only_closed_timeout_fields(self):
        source=(HERE/'windows-restore-qualification.py').read_text();tree=ast.parse(source)
        main=next(n for n in tree.body if isinstance(n,ast.If) and isinstance(n.test,ast.Compare) and isinstance(n.test.left,ast.Name) and n.test.left.id=='__name__')
        for value,expected in ((record(),True),(record()|{'private':'SECRET'},False)):
            primary=invoke(new)['error'];primary.args=('PRIVATE exception text',);primary.restore_wait_failure=value
            def fail():raise primary
            out=io.StringIO()
            namespace=dict(new.__dict__,__name__='__main__',main=fail)
            fake_sys=types.SimpleNamespace(exit=lambda code:(_ for _ in ()).throw(SystemExit(code)))
            namespace['sys']=fake_sys
            with contextlib.redirect_stdout(out),self.assertRaises(SystemExit) as caught:
                exec(compile(ast.Module(body=[main],type_ignores=[]),str(HERE/'windows-restore-qualification.py'),'exec'),namespace)
            self.assertEqual(caught.exception.code,1);result=json.loads(out.getvalue());self.assertEqual('wait_failure' in result,expected)
            self.assertNotIn('PRIVATE',out.getvalue());self.assertNotIn('SECRET',out.getvalue())

class TaskObservation(unittest.TestCase):
    def test_native_task_admission_precedes_child_access(self):
        with patch.object(new.subprocess,'run',side_effect=AssertionError('No child allowed')):
            result=invoke(new);self.assertIs(type(result['error']),TimeoutError)
            self.assertNotIn('backup_task',result['error'].restore_wait_failure)
    def test_actual_timeout_uses_only_bounded_readonly_task_child_adapter(self):
        with tempfile.TemporaryDirectory(prefix='restore-wait-task-') as td:
            environment={'OPENWEB_WINDOWS_RESTORE_TEST':'1','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted',
                         'GITHUB_REPOSITORY':'embire2/openwebpbx','GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_RUN_ID':'1234',
                         'GITHUB_SHA':'d'*40,'ProgramData':td,'SystemRoot':'C:/Windows'}
            owner=object.__new__(new.Qualification);owner.s=dict(role='source',disposable=True,run_id='1234',source_commit='d'*40,scope='a'*24)
            owner.work=Path(td)/'OpenWebPBX/restore-qualification'/('a'*24);owner.path=owner.work/'input.json'
            owner.backups=types.SimpleNamespace(native_powershell_environment=lambda:{'explicit':'clean-native-adapter'})
            good=dict(state='Ready',last_result=2147942405,expected_system_action=True,last_run_available=True)
            for case in ('valid','invalid-json','private-field','too-large','nonzero','timeout','bad-context'):
                calls=[]
                def child(args,**kwargs):
                    calls.append((args,kwargs));self.assertEqual(kwargs,dict(env={'explicit':'clean-native-adapter'},capture_output=True,timeout=8))
                    self.assertEqual(args[:4],['C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe','-NoProfile','-NonInteractive','-Command'])
                    self.assertIn("Get-ScheduledTask -TaskName 'OpenWebPBX-Backups'",args[4])
                    for forbidden in ('Start-ScheduledTask','Stop-ScheduledTask','Set-ScheduledTask','psql','PGPASSWORD'):self.assertNotIn(forbidden,args[4])
                    if case=='timeout':raise subprocess.TimeoutExpired(args,8)
                    raw=b'bad' if case=='invalid-json' else b'x'*4097 if case=='too-large' else json.dumps(good|({'private':'SECRET'} if case=='private-field' else {})).encode()
                    return subprocess.CompletedProcess(args,1 if case=='nonzero' else 0,raw,b'')
                with patch.object(new,'os',types.SimpleNamespace(name='nt',environ=environment)),patch.object(new.subprocess,'run',side_effect=child):
                    owner.s['run_id']='foreign' if case=='bad-context' else '1234'
                    result=invoke(new,owner=owner)
                self.assertIs(type(result['error']),TimeoutError);r=result['error'].restore_wait_failure
                self.assertEqual('backup_task' in r,case=='valid');self.assertEqual(len(calls),0 if case=='bad-context' else 1)
                if case=='valid':self.assertEqual(r['backup_task'],good)

if __name__=='__main__':unittest.main()
