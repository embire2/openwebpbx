"""Real child-process and PowerShell controls; no installed worker/task is loaded."""
import ast
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'tests/windows-backups-worker-observer.py'
MARKER='PRIVATE_WORKER_OBSERVER_MARKER_c92e'


def library():
    spec=importlib.util.spec_from_file_location('worker_observer_controls',SOURCE)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


def backup_module(tool='sftp'):
    source=ROOT/'packaging/windows/backups.py';tree=ast.parse(source.read_text())
    nodes=[n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='BackupError' or isinstance(n,ast.FunctionDef) and n.name=='run']
    module=types.ModuleType('controlled_backup');module.subprocess=subprocess
    exec(compile(ast.Module(nodes,type_ignores=[]),str(source),'exec'),module.__dict__)
    module.tool=lambda name:sys.executable if name==tool else str(Path('/not-a-real-tool')/name)
    module.upload_sftp=lambda *args,**kwargs:None
    return module


class Controls(unittest.TestCase):
    def setUp(self):self.observer=library()
    def query_module(self,command):
        module=backup_module('psql');module.json=json
        tree=ast.parse((ROOT/'packaging/windows/backups.py').read_text())
        definition=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='query')
        exec(compile(ast.Module([definition],type_ignores=[]),str(ROOT/'packaging/windows/backups.py'),'exec'),module.__dict__)
        module.database_command=lambda settings:command
        module.database_environment=lambda settings:os.environ.copy()
        return module
    def test_local_actual_query_failure_once_closed_class_and_wrappers_restored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);counter=root/'counter';received=root/'sql-private'
            child=root/'fake-tool.py';child.write_text('import pathlib,sys\npathlib.Path('+repr(str(counter))+').write_text("once")\npathlib.Path('+repr(str(received))+').write_bytes(sys.stdin.buffer.read())\nsys.stderr.write("connection to server at \\\"'+MARKER+'\\\" failed: private")\nsys.exit(2)\n')
            module=self.query_module([sys.executable,str(child)]);originals={key:getattr(module,key) for key in ('query','run','subprocess','upload_sftp')}
            observation=self.observer.LocalQueryObservation(module,root/'report.json')
            with self.assertRaises(module.BackupError):
                with observation:module.query({},'SELECT '+MARKER,json_result=True)
            self.assertEqual(counter.read_text(),'once');self.assertEqual(received.read_bytes(),('SET standard_conforming_strings=on;\nSELECT '+MARKER).encode())
            self.assertTrue(all(getattr(module,key) is value for key,value in originals.items()))
            safe=observation.safe_report();self.assertTrue(safe['wrappers_restored'])
            self.assertEqual(safe['events'],[{'event':'tool_failure','tool':'psql','failure_class':'database_connection','returncode':2},
                {'event':'run_failure','tool':'psql','error_type':'BackupError'},{'event':'query_failure','error_type':'BackupError'}])
            self.assertNotIn(MARKER,json.dumps(safe));self.assertNotIn(str(root),json.dumps(safe))
    def test_local_actual_query_success_exact_result_and_unrelated_failure_not_recorded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);counter=root/'count';child=root/'fake-tool.py'
            child.write_text('import pathlib,sys\npathlib.Path('+repr(str(counter))+').write_text("once")\nsys.stdout.write(\'{"value":"'+MARKER+'"}\')\n')
            module=self.query_module([sys.executable,str(child)]);observation=self.observer.LocalQueryObservation(module,root/'report.json')
            with observation:
                self.assertEqual(module.query({},'SELECT '+MARKER,json_result=True),{'value':MARKER})
                with self.assertRaises(module.BackupError):module.run([sys.executable,'-c','raise SystemExit(7)'])
            self.assertEqual(counter.read_text(),'once');self.assertEqual(observation.safe_report()['events'],[])
            self.assertTrue(observation.safe_report()['wrappers_restored']);self.assertFalse((root/'report.json').exists())
    def test_local_query_original_exception_and_failed_observation_remain_exact(self):
        module=backup_module('psql');original=module.BackupError(MARKER);calls=[]
        def query(*args,**kwargs):calls.append((args,kwargs));raise original
        module.query=query;before={key:getattr(module,key) for key in ('query','run','subprocess','upload_sftp')}
        with tempfile.TemporaryDirectory() as temporary:
            observation=self.observer.LocalQueryObservation(module,Path(temporary)/'report.json')
            with self.assertRaises(module.BackupError) as failure:
                with observation,patch.object(observation,'record',side_effect=RuntimeError(MARKER)):module.query('unchanged',mode=MARKER)
            self.assertIs(failure.exception,original);self.assertEqual(calls,[(('unchanged',),{'mode':MARKER})])
            self.assertTrue(all(getattr(module,key) is value for key,value in before.items()))
            observation.events=[{'event':'tool_failure','phase':'local_query','tool':['psql',MARKER],'returncode':True,'private':MARKER}]
            self.assertEqual(observation.safe_report()['events'],[{'event':'tool_failure'}]);self.assertNotIn(MARKER,json.dumps(observation.safe_report()))
    def test_windows_high_bit_exit_is_observed_without_changing_process_result(self):
        module=backup_module('psql');module.query=lambda:module.subprocess.run([sys.executable])
        expected=subprocess.CompletedProcess([sys.executable],0xc0000005,b'',MARKER.encode())
        with tempfile.TemporaryDirectory() as temporary:
            observation=self.observer.LocalQueryObservation(module,Path(temporary)/'report.json')
            with patch.object(subprocess,'run',return_value=expected) as delegated:
                with observation:result=module.query()
            delegated.assert_called_once_with([sys.executable]);self.assertIs(result,expected);self.assertEqual(result.returncode,0xc0000005)
            self.assertEqual(observation.safe_report()['events'],[{'event':'tool_failure','tool':'psql','failure_class':'unknown','returncode':-1073741819}])
    def test_exact_tool_classes_and_no_private_values(self):
        cases=[('psql',b'ERROR: invalid byte sequence for encoding "UTF8": 0x92','database_invalid_encoding'),
            ('psql',b'ERROR: invalid value for parameter "client_encoding": private','database_client_encoding'),
            ('psql',b'ERROR: permission denied for table private','database_permission'),
            ('psql',b'connection to server at "private" failed: private','database_connection'),
            ('psql',b'ERROR: syntax error at or near "private"','database_syntax'),
            ('ssh-keygen',b'WARNING: UNPROTECTED PRIVATE KEY FILE!','ssh_private_key_permissions'),
            ('ssh-keygen',b'Load key "private": invalid format','ssh_private_key_format'),
            ('sftp',b'Load key "private": No such file or directory','ssh_private_key_unreadable'),
            ('sftp',b'Host key verification failed.','ssh_host_key'),
            ('sftp',b'private: Permission denied (publickey,password).','ssh_authentication'),
            ('sftp',b'ssh: connect to host private port 22: Connection refused','ssh_connection'),
            ('sftp',b'dest open "private": Permission denied','ssh_remote_path')]
        for tool,message,category in cases:
            self.assertEqual(self.observer.closed_stderr(tool,message+b'\n'+MARKER.encode()),category)
        for tool,raw in [('psql',MARKER.encode()),('unknown',b'Host key verification failed.'),('powershell',b'ERROR: permission denied'),('sftp',MARKER),('sftp',b'x'*262145)]:
            self.assertEqual(self.observer.closed_stderr(tool,raw),'unknown')
    def test_actual_failed_child_and_both_original_failures_preserved(self):
        module=backup_module();original_error=module.BackupError(MARKER);calls=[]
        with tempfile.TemporaryDirectory(prefix='backup-worker-') as temporary:
            report=Path(temporary)/'report.json';count=Path(temporary)/'counter'
            command=[sys.executable,'-c','import pathlib,sys; p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text()+"x" if p.exists() else "x");sys.stderr.write("Host key verification failed. '+MARKER+'");sys.exit(7)',str(count)]
            def upload(value,*,flag):
                calls.append((value,flag))
                try:module.run(command,timeout=10)
                except module.BackupError:raise original_error
            module.upload_sftp=upload;observation=self.observer.WorkerObservation(module,report);observation.install()
            try:module.upload_sftp('unchanged',flag=MARKER)
            except module.BackupError as error:self.assertIs(error,original_error)
            else:self.fail('The original upload exception was swallowed')
            self.assertEqual(calls,[('unchanged',MARKER)]);self.assertEqual(count.read_text(),'x')
            module.tool=lambda name:sys.executable if name=='psql' else '/not-a-real-tool/'+name
            observation.tools={self.observer.ntpath.normcase(sys.executable):'psql'}
            with self.assertRaises(module.BackupError):module.run([sys.executable,'-c','import sys;sys.stderr.write(\'ERROR: invalid byte sequence for encoding "UTF8": 0x92 '+MARKER+'\');sys.exit(3)'])
            value=json.loads(report.read_text());events=self.observer.projected_events(value)
            self.assertEqual([(e['tool'],e['phase'],e['failure_class'],e['returncode']) for e in events if e['event']=='tool_failure'],[('sftp','upload','ssh_host_key',7),('psql','after_upload','database_invalid_encoding',3)])
            self.assertEqual([e['error_type'] for e in events if e['event']=='upload_failure'],['BackupError'])
            self.assertNotIn(MARKER,report.read_text());self.assertNotIn(str(count),report.read_text())
    def test_actual_success_result_identity_stdout_and_delegate_once(self):
        module=backup_module();calls=[];real=subprocess.run
        class Boundary:
            PIPE=subprocess.PIPE;TimeoutExpired=subprocess.TimeoutExpired
            @staticmethod
            def run(*args,**kwargs):calls.append((args,kwargs));return real(*args,**kwargs)
        module.subprocess=Boundary()
        with tempfile.TemporaryDirectory() as temporary:
            report=Path(temporary)/'report.json';observation=self.observer.WorkerObservation(module,report);observation.install()
            self.assertEqual(module.run([sys.executable,'-c','import sys;sys.stdout.buffer.write(b"exact\\x00bytes")'],timeout=10),b'exact\0bytes')
            self.assertEqual(len(calls),1);self.assertEqual(calls[0][1]['timeout'],10);self.assertFalse(report.exists())
            expected=subprocess.CompletedProcess(['fiction'],4,b'unchanged',b'private')
            module.subprocess.__dict__.clear()  # The proxy has no state on its own.
            with patch.object(Boundary,'run',return_value=expected) as delegated:
                result=module.subprocess.run(['fiction'])
            self.assertIs(result,expected);delegated.assert_called_once_with(['fiction'])
            with patch.object(Boundary,'run',return_value=expected),patch.object(observation,'classify',side_effect=RuntimeError(MARKER)),patch.object(observation,'record',side_effect=RuntimeError(MARKER)):
                self.assertIs(module.subprocess.run(['fiction']),expected)
    def test_process_exception_and_failed_observer_never_mask_original(self):
        module=backup_module();error=PermissionError(MARKER)
        class Boundary:
            PIPE=subprocess.PIPE;TimeoutExpired=subprocess.TimeoutExpired
            @staticmethod
            def run(*args,**kwargs):raise error
        module.subprocess=Boundary();observation=self.observer.WorkerObservation(module,Path('/nonexistent-observer-parent/result.json'));observation.install()
        try:module.subprocess.run(['fiction'])
        except PermissionError as caught:self.assertIs(caught,error)
        else:self.fail('The actual exception identity changed')
        with self.assertRaises(module.BackupError):module.run(['fiction'])
    def test_projection_bounds_types_and_private_fields(self):
        value={'schema':1,'truncated':False,'events':[{'event':'tool_failure','phase':'upload','tool':'sftp','failure_class':'ssh_authentication','returncode':1,'private':MARKER}]}
        self.assertNotIn(MARKER,json.dumps(self.observer.projected_events(value)))
        bad=copy.deepcopy(value);bad['events'][0].update(tool=[MARKER],failure_class=MARKER,returncode=True)
        self.assertEqual(self.observer.projected_events(bad),[{'event':'tool_failure','phase':'upload'}])
        for change in ({'schema':True},{'truncated':MARKER},{'events':value['events']*9},{'events':[{'event':MARKER,'phase':'upload'}]}):
            with self.assertRaises((ValueError,TypeError)):self.observer.projected_events(value|change)
    def test_task_lease_actual_powershell_restoration_and_primary_failure(self):
        pwsh=os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh');self.assertTrue(pwsh)
        with tempfile.TemporaryDirectory(prefix="backup worker's control ") as temporary:
            root=Path(temporary);private=root/'ProgramData/OpenWebPBX/backup-qualification';private.mkdir(parents=True)
            installed=root/'C:/OpenWebPBX/tools/backups.py';installed.parent.mkdir(parents=True);installed.write_text('fictional installed source')
            package=root/'package';package.mkdir();shutil.copyfile(installed,package/'backups.py')
            state=root/'task.json';original={'execute':'C:\\OpenWebPBX\\backup-runtime\\python.exe','arguments':'-I "C:\\OpenWebPBX\\tools\\backups.py" worker','working_directory':'C:\\OpenWebPBX\\tools'}
            state.write_text(json.dumps(original));calls=[]
            def ps(code):
                calls.append(code)
                prefix=PS_BOUNDARY.replace('__STATE__',str(state).replace("'","''"))
                result=subprocess.run([pwsh,'-NoProfile','-Command',prefix+'\n'+code],capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,0,'Owned PowerShell action boundary failed')
                return result.stdout.strip()
            fake=types.SimpleNamespace(STATE=private.parent,reparse=lambda path:Path(path).is_symlink(),secure_acl=lambda path:None,
                atomic_json=lambda path,value:Path(path).write_text(json.dumps(value),encoding='utf-8'))
            environment=os.environ|{'GITHUB_ACTIONS':'true','OPENWEB_WINDOWS_BACKUP_TEST':'1','GITHUB_RUN_ID':'12345','GITHUB_SHA':'a'*40,
                'GITHUB_REPOSITORY':'embire2/openwebpbx','GITHUB_WORKFLOW_REF':'embire2/openwebpbx/.github/workflows/windows-backups-diagnostics.yml@refs/heads/customization','ProgramData':str(root/'ProgramData')}
            fake_os=types.SimpleNamespace(name='nt',environ=environment)
            previous=Path.cwd()
            try:
                os.chdir(root)
                with patch.object(self.observer,'os',fake_os):
                    lease=self.observer.TaskActionLease(fake,ps,private,package)
                    original_error=AssertionError(MARKER)
                    try:
                        with lease:
                            self.assertEqual(json.loads(state.read_text())['arguments'],lease.arguments)
                            raise original_error
                    except AssertionError as error:self.assertIs(error,original_error)
                    self.assertTrue(lease.restored);self.assertEqual(json.loads(state.read_text()),original)
            finally:os.chdir(previous)
            self.assertEqual(sum('Set-ScheduledTask' in code for code in calls),2)
            self.assertTrue(all('-Action $a' in code for code in calls if 'Set-ScheduledTask' in code))
    def test_restore_refuses_foreign_metadata_and_preserves_primary_exception(self):
        lease=object.__new__(self.observer.TaskActionLease);lease.snapshot={'arguments':'original','principal':'SYSTEM'};lease.arguments='observer';lease.restored=False
        lease.task=lambda:{'arguments':'observer','principal':MARKER};lease.set_arguments=lambda value:self.fail('Foreign task metadata was rewritten')
        with self.assertRaises(RuntimeError):lease.restore()
        self.assertFalse(lease.__exit__(AssertionError,AssertionError(MARKER),None));self.assertFalse(lease.restored)
        with self.assertRaises(RuntimeError):lease.__exit__(None,None,None)
    def test_config_binding_scope_and_hash_refusals(self):
        with tempfile.TemporaryDirectory(prefix='observer-scope-') as temporary:
            root=Path(temporary);private=root/'OpenWebPBX/backup-qualification';private.mkdir(parents=True);path=private/'worker-observer-config.json'
            valid={'schema':1,'disposable_hosted_runner':True,'hostname':socket.gethostname(),'run_id':'12345','source_commit':'a'*40,
                'repository':'embire2/openwebpbx','workflow_ref':'embire2/openwebpbx/.github/workflows/windows-backups-diagnostics.yml@refs/heads/customization',
                'source_sha256':'b'*64,'launcher_sha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest()}
            with patch.dict(os.environ,{'ProgramData':str(root)}):
                path.write_text(json.dumps(valid));self.assertEqual(self.observer.validated_config(path),valid)
                for change in ({'schema':True},{'disposable_hosted_runner':False},{'hostname':MARKER},{'run_id':MARKER},{'source_commit':'a'*39},
                    {'repository':MARKER},{'workflow_ref':'embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/main'},
                    {'workflow_ref':'embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/foreign'},
                    {'source_sha256':MARKER},{'launcher_sha256':'0'*64}):
                    path.write_text(json.dumps(valid|change))
                    with self.assertRaises(RuntimeError):self.observer.validated_config(path)
                path.write_text(json.dumps(valid));other=private/'foreign-config.json';other.write_text(json.dumps(valid))
                with self.assertRaises(RuntimeError):self.observer.validated_config(other)
    def test_native_entrypoint_refuses_nonwindows_before_installed_access(self):
        if os.name=='nt':self.skipTest('This negative is specific to the portable control host')
        with self.assertRaisesRegex(RuntimeError,'Disposable native Windows'):self.observer.launch(Path('/not-an-installed-config'))
    def test_actual_launcher_imports_one_bound_module_and_preserves_cli_outcome(self):
        with tempfile.TemporaryDirectory(prefix='worker-launcher-') as temporary:
            root=Path(temporary);source=root/'controlled-backups.py';report=root/'worker-observer-report.json';sentinel=root/'one-main-call'
            original=(ROOT/'packaging/windows/backups.py').read_text();tree=ast.parse(original)
            run=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='run')
            # Use the actual product run() body and an explicit fictional module.
            source.write_text('import subprocess,sys\nfrom pathlib import Path\nclass BackupError(RuntimeError):pass\n'+ast.get_source_segment(original,run)+'\n'+
                'def tool(name):return sys.executable if name=="sftp" else "/not-a-real-tool/"+name\n'+
                'def read_settings():return {"openweb.public_url":"https://localhost"}\n'+
                'def upload_sftp():return run([sys.executable,"-c",\'import sys;sys.stderr.write("Permission denied (publickey). '+MARKER+'");sys.exit(9)\'])\n'+
                'def main():\n assert sys.argv==['+repr(str(source))+',"worker"]\n Path('+repr(str(sentinel))+').write_text("once")\n try:upload_sftp()\n except BackupError:return 23\n',encoding='utf-8')
            digest=hashlib.sha256(source.read_bytes()).hexdigest();real_ordinary=self.observer.ordinary
            def bound(path):
                self.assertEqual(str(path),'C:/OpenWebPBX/tools/backups.py');return real_ordinary(source)
            class NativeOS:
                name='nt';environ=os.environ
                def __getattr__(self,name):return getattr(os,name)
            fake_os=NativeOS()
            fake_ctypes=types.SimpleNamespace(windll=types.SimpleNamespace(shell32=types.SimpleNamespace(IsUserAnAdmin=lambda:True)))
            with patch.object(self.observer,'os',fake_os),patch.object(self.observer,'ctypes',fake_ctypes),patch.object(self.observer,'validated_config',return_value={'source_sha256':digest}),patch.object(self.observer,'ordinary',side_effect=bound),patch.object(sys,'argv',['worker-observer.py',str(root/'worker-observer-config.json'),'worker']):
                self.assertEqual(self.observer.launch(root/'worker-observer-config.json'),23)
            with patch.object(self.observer,'os',fake_os),patch.object(self.observer,'ctypes',fake_ctypes),patch.object(self.observer,'validated_config',return_value={'source_sha256':'0'*64}),patch.object(self.observer,'ordinary',side_effect=bound):
                with self.assertRaisesRegex(RuntimeError,'Installed backup source changed'):self.observer.launch(root/'worker-observer-config.json')
            self.assertEqual(sentinel.read_text(),'once')
            events=self.observer.projected_events(json.loads(report.read_text()))
            self.assertEqual(events[0],{'event':'tool_failure','phase':'upload','tool':'sftp','failure_class':'ssh_authentication','returncode':9})
            self.assertNotIn(MARKER,report.read_text())


class RecoveryControls(unittest.TestCase):
    def setUp(self):self.observer=library()
    def module(self,directory):
        module=backup_module();module.RESTORE=directory;module.control=lambda *args,**kwargs:{};module._recover=lambda *args,**kwargs:None
        return module
    def test_exact_delegation_results_and_all_module_attributes_restored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);module=self.module(root);returned=object();calls=[]
            def control(*args,**kwargs):calls.append(('control',args,kwargs));return returned
            def recover(*args,**kwargs):calls.append(('recover',args,kwargs));return returned
            module.control=control;module._recover=recover;originals={name:getattr(module,name) for name in ('run','control','_recover','subprocess','upload_sftp')}
            observation=self.observer.RecoveryObservation(module,root/'report.json',lambda:False)
            with observation:
                self.assertIs(module.control('plan',MARKER,flag=MARKER),returned)
                self.assertIs(module._recover(MARKER,flag=MARKER),returned)
                self.assertEqual(module.run([sys.executable,'-I','-c','import sys;sys.stdout.buffer.write(sys.stdin.buffer.read())'],input=b'unchanged',timeout=10),b'unchanged')
            self.assertEqual(calls,[('control',('plan',MARKER),{'flag':MARKER}),('recover',(MARKER,),{'flag':MARKER})])
            self.assertTrue(all(getattr(module,name) is value for name,value in originals.items()))
            fields=observation.safe_report();self.assertEqual(fields['journal_state'],'absent');self.assertTrue(fields['recover_called']);self.assertFalse(fields['injection_reached']);self.assertTrue(fields['wrappers_restored']);self.assertEqual(fields['events'],[])
            self.assertNotIn(MARKER,json.dumps(fields))
    def test_actual_product_swallow_handler_retains_original_and_native_recovery_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);module=self.module(root);journal={'state':'restoring'};reached=False;control_calls=[]
            native='The factory web/task snapshot is invalid.\nAt C:\\private-'+MARKER+'\\Backup-Control.ps1:61 char:4\n    + FullyQualifiedErrorId : The factory web/task snapshot is invalid.\n'
            def native_control(operation,value=None):
                control_calls.append((operation,value))
                return module.run([sys.executable,'-I','-c','import sys;sys.stderr.write('+repr(native)+');sys.exit(7)'])
            namespace={'control':lambda operation,value:module.control(operation,value)}
            exec(compile('def recover(settings):\n return control("acl-restore",settings)\n','backups.py','exec'),namespace)
            module.control=native_control;module._recover=namespace['recover'];original_error=module.BackupError(MARKER)
            def injected_copy():
                nonlocal reached
                reached=True;raise original_error
            # Execute the exact product exception handler that swallows recovery.
            source=ROOT/'packaging/windows/backups.py';tree=ast.parse(source.read_text())
            restore=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='_restore')
            original_try=next(node for node in ast.walk(restore) if isinstance(node,ast.Try) and any(isinstance(call,ast.Call) and isinstance(call.func,ast.Name) and call.func.id=='_recover' for handler in node.handlers for call in ast.walk(handler)))
            controlled=copy.deepcopy(restore);controlled.name='controlled_restore';controlled.args=ast.arguments(posonlyargs=[],args=[],kwonlyargs=[],kw_defaults=[],defaults=[])
            controlled_try=copy.deepcopy(original_try);controlled_try.body=[ast.copy_location(ast.Expr(value=ast.Call(func=ast.Name(id='injected_copy',ctx=ast.Load()),args=[],keywords=[])),original_try.body[0])]
            controlled.body=[controlled_try];ast.fix_missing_locations(controlled)
            namespace={'_recover':lambda settings:module._recover(settings),'settings':{'private':MARKER},'journal':journal,'RESTORE':root,'BackupError':module.BackupError,
                'atomic_json':lambda path,value:Path(path).write_text(json.dumps(value)),'injected_copy':injected_copy}
            exec(compile(ast.Module([controlled],type_ignores=[]),'backups.py','exec'),namespace)
            originals={name:getattr(module,name) for name in ('run','control','_recover','subprocess','upload_sftp')}
            observation=self.observer.RecoveryObservation(module,root/'report.json',lambda:reached)
            observation.tools={self.observer.ntpath.normcase(sys.executable):'powershell'}
            with observation:
                try:namespace['controlled_restore']()
                except module.BackupError as error:
                    self.assertIn('Services remain held',str(error));observation.note_reported(error)
                else:self.fail('The unchanged product handler swallowed its public failure')
            fields=observation.safe_report()
            self.assertEqual(fields['journal_state'],'recovery_required');self.assertTrue(fields['injection_reached']);self.assertTrue(fields['recover_called']);self.assertTrue(fields['wrappers_restored'])
            self.assertEqual(control_calls,[('acl-restore',{'private':MARKER})]);self.assertTrue(all(getattr(module,name) is value for name,value in originals.items()))
            self.assertEqual(fields['original_error']['error_type'],'BackupError');self.assertEqual(fields['recovery_error']['error_type'],'BackupError');self.assertEqual(fields['reported_error']['error_type'],'BackupError')
            self.assertTrue(fields['original_error']['source_frames']);self.assertTrue(fields['recovery_error']['source_frames'])
            event=fields['events'][0];self.assertEqual((event['event'],event['phase'],event['operation'],event['tool'],event['returncode'],event['failure_class']),('tool_failure','recovery','acl-restore','powershell',7,'control_startup_snapshot'))
            self.assertEqual((event['native_source_basename'],event['native_source_line']),('Backup-Control.ps1',61))
            self.assertNotIn(MARKER,json.dumps(fields));self.assertNotIn(native,json.dumps(fields));self.assertNotIn(str(root),json.dumps(fields))
    def test_original_control_and_recovery_exception_identity_never_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);module=self.module(root);error=ValueError(MARKER);calls=[]
            def failure(*args,**kwargs):calls.append((args,kwargs));raise error
            module.control=failure;module._recover=failure;observation=self.observer.RecoveryObservation(module,root/'report.json',lambda:False)
            with observation:
                for call in (lambda:module.control('hold',MARKER),lambda:module._recover(MARKER)):
                    try:call()
                    except ValueError as caught:self.assertIs(caught,error)
                    else:self.fail('The actual exception was swallowed')
            self.assertEqual(len(calls),2);self.assertFalse(observation.safe_report()['injection_reached']);self.assertTrue(observation.wrappers_restored)
            self.assertNotIn(MARKER,json.dumps(observation.safe_report()))
    def test_known_native_position_and_static_category_are_strict_and_private(self):
        raw=('At C:\\private-'+MARKER+'\\Backup-Control.ps1:145 char:5\n    + FullyQualifiedErrorId : A factory private-data permission snapshot is invalid.\n').encode()
        self.assertEqual(self.observer.recovery_position('powershell',raw),{'native_source_basename':'Backup-Control.ps1','native_source_line':145})
        self.assertEqual(self.observer.recovery_stderr('powershell',raw),'control_acl_snapshot')
        for text in ('At C:\\private\\Foreign.ps1:145 char:5','At C:\\private\\Backup-Control.ps1:0 char:5','At C:\\private\\Backup-Control.ps1:20001 char:5',
            'At C:\\private\\Backup-Control.ps1:145 char:5 private','At C:\\private\\Backup-Control.ps1:145 char:5\nAt C:\\private\\Backup-Control.ps1:146 char:5'):
            self.assertEqual(self.observer.recovery_position('powershell',text.encode()),{})
        self.assertEqual(self.observer.recovery_position('psql',raw),{})
        self.assertEqual(self.observer.recovery_stderr('powershell',b'private A factory private-data permission snapshot is invalid. private'),'unknown')
        self.assertEqual(self.observer.recovery_stderr('powershell',b'The factory startup snapshot is invalid.\nA factory private-data permission snapshot is invalid.\n'),'unknown')
        self.assertEqual(self.observer.recovery_stderr('powershell',b'FullyQualifiedErrorId : CommandNotFoundException'),'shell_command_not_found')
        messages=['A backup path is outside the owned private locations.','Backup paths must not contain links or junctions.','An unknown backup permission class was requested.',
            'The factory startup snapshot is invalid.','The factory service startup snapshot is invalid.','The factory running-service snapshot is invalid.',
            'The factory web/task snapshot is invalid.','The certificate-task snapshot is invalid.','The additional-task snapshot is invalid.',
            'The PBX application pool did not stop.','The PBX application pool did not start.','A backup control request is invalid.','A factory private-data permission snapshot is invalid.']
        product=(ROOT/'packaging/windows/Backup-Control.ps1').read_text()
        for message in messages:self.assertIn("throw '"+message+"'",product)

    def test_meet_rebind_plain_and_clixml_errors_are_closed_and_private(self):
        from xml.sax.saxutils import escape
        cases={
            'The protected restore transaction must be running.':'meet_restore_journal',
            'Restore must hold calling and background work before rebinding meetings.':'meet_restore_holds',
            'Restore must stop calling before rebinding meetings.':'meet_restore_services',
            'Restore must stop the PBX website before rebinding meetings.':'meet_restore_site',
            'The parent restore must retain its exclusive maintenance lock.':'meet_restore_lock',
            'The private meeting certificate and endpoint did not validate.':'meet_endpoint',
            'The installed meeting transport needs administrator review.':'meet_transport',
            'Restore rebind requires the unchanged owned target meeting proxy.':'meet_target_proxy',
            'The installed meeting ownership ledger needs review.':'meet_ledger',
            'An interrupted meeting installation needs recovery from its retained private snapshot before continuing.':'meet_ledger'}
        product=(ROOT/'packaging/windows/Install-Meet.ps1').read_text()
        for message,category in cases.items():
            self.assertIn("throw '"+message+"'",product)
            private='At C:\\'+MARKER+'\\Install-Meet.ps1:17 char:5\n    + FullyQualifiedErrorId : '+message+'\n'
            encoded=private.replace('\n','_x000D__x000A_')
            xml=('#< CLIXML\n<Objs xmlns="http://schemas.microsoft.com/powershell/2004/04">'
                 '<S S="Error">'+escape(encoded)+'</S></Objs>').encode()
            for raw in (private.encode(),xml):
                with self.subTest(category=category,xml=raw.startswith(b'#')):
                    fields=self.observer.recovery_position('powershell',raw)
                    self.assertEqual(fields,{'native_source_basename':'Install-Meet.ps1','native_source_line':17})
                    self.assertEqual(self.observer.recovery_stderr('powershell',raw),category)
                    self.assertNotIn(MARKER,json.dumps(fields))
                    self.assertEqual(self.observer.recovery_position('psql',raw),{})
        for name in ('Meet-Proxy.ps1','Write-PrivateState.ps1'):
            self.assertEqual(self.observer.recovery_position('powershell',('At C:\\'+MARKER+'\\'+name+':20 char:1').encode()),
                {'native_source_basename':name,'native_source_line':20})
        # XML entity declarations, unrelated stream tags, malformed XML,
        # ambiguous positions and near-match messages reveal no raw content.
        declaration=b'#< CLIXML\n<!DOCTYPE Objs [<!ENTITY x "PRIVATE">]><Objs><S>&x;</S></Objs>'
        self.assertEqual(self.observer.powershell_error_text(declaration),'')
        for raw in (b'#< CLIXML\n<not-valid',b'#<CLIXML\n<Objs><S S="Information">PRIVATE</S></Objs>',b'x'*262145):
            self.assertEqual(self.observer.recovery_position('powershell',raw),{})
            self.assertEqual(self.observer.recovery_stderr('powershell',raw),'unknown')
        self.assertEqual(self.observer.recovery_position('powershell',b'At C:\\Install-Meet.ps1:1 char:1\nAt C:\\Meet-Proxy.ps1:2 char:2'),{})
        self.assertEqual(self.observer.recovery_stderr('powershell',b'private The parent restore must retain its exclusive maintenance lock. private'),'unknown')
    def test_journal_state_is_observed_and_never_inferred_from_injection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);module=self.module(root);observation=self.observer.RecoveryObservation(module,root/'report.json',lambda:False)
            for state in ('prepared','restoring','restored','recovery_required','recovered',MARKER):
                (root/'journal.json').write_text(json.dumps({'state':state,'private':MARKER}))
                fields=observation.safe_report();self.assertEqual(fields['journal_state'],state if state!=MARKER else 'unknown');self.assertFalse(fields['injection_reached']);self.assertNotIn(MARKER,json.dumps(fields))
            (root/'journal.json').write_text('{invalid');self.assertEqual(observation.safe_report()['journal_state'],'unavailable')


PS_BOUNDARY=r'''
$ErrorActionPreference='Stop'
$statePath='__STATE__';$record=Get-Content -LiteralPath $statePath -Encoding UTF8 -Raw|ConvertFrom-Json
function Get-ScheduledTask {
 param($TaskName)
 if($TaskName -cne 'OpenWebPBX-Backups'){throw 'Unexpected task scope'}
 [pscustomobject]@{Actions=@([pscustomobject]@{Execute=$record.execute;Arguments=$record.arguments;WorkingDirectory=$record.working_directory});Principal=[pscustomobject]@{UserId='SYSTEM';LogonType='ServiceAccount'}}
}
function Export-ScheduledTask {
 param($TaskName)
 if($TaskName -cne 'OpenWebPBX-Backups'){throw 'Unexpected task scope'}
 '<Task><Principals><Principal id="fixture"><UserId>S-1-5-18</UserId></Principal></Principals><Triggers><BootTrigger/></Triggers><Settings><Enabled>true</Enabled></Settings></Task>'
}
function Set-ScheduledTask {
 param($TaskName,$Action)
 if($TaskName -cne 'OpenWebPBX-Backups' -or @($Action).Count -ne 1){throw 'Unexpected task mutation scope'}
 $record.execute=$Action[0].Execute;$record.arguments=$Action[0].Arguments;$record.working_directory=$Action[0].WorkingDirectory
 [IO.File]::WriteAllText($statePath,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
'''


if __name__=='__main__':unittest.main()
