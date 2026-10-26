"""Focused source, WAV identity and closed Job proof controls; no Windows pass."""
import argparse
import ast
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
from pathlib import PureWindowsPath
import shutil
import struct
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch
import wave

parser=argparse.ArgumentParser();parser.add_argument('-SourceRoot',type=Path,default=Path(__file__).resolve().parents[1]);options,remaining=parser.parse_known_args()
ROOT=options.SourceRoot
spec=importlib.util.spec_from_file_location('native_greeting_under_test',ROOT/'tests/windows_greetings_native.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class GreetingControls(unittest.TestCase):
    def wav(self,path,frequency=550,rate=16000,channels=1,seconds=2):
        values=[int(6500*math.sin(2*math.pi*frequency*i/rate))for i in range(int(rate*seconds))]
        with wave.open(str(path),'wb')as audio:
            audio.setnchannels(channels);audio.setsampwidth(2);audio.setframerate(rate)
            audio.writeframes(b''.join(struct.pack('<h',value)*channels for value in values))

    def test_actual_generated_pcm_wave_identity_and_refusals(self):
        with tempfile.TemporaryDirectory()as temporary:
            file=Path(temporary)/'owned.wav'
            for rate in (8000,16000,32000,48000):
                self.wav(file,rate=rate);self.assertGreaterEqual(m.wave_tone(file,550),.8)
            for config in ({'frequency':660},{'frequency':0},{'seconds':.2},{'channels':2},{'rate':22050}):
                self.wav(file,**config)
                with self.assertRaises(AssertionError):m.wave_tone(file,550)
            file.write_bytes(b'RIFF'+b'\0'*20)
            with self.assertRaises(AssertionError):m.wave_tone(file,550)
            file.unlink()
            with self.assertRaises(AssertionError):m.wave_tone(file,550)

    def test_actual_closed_job_fields(self):
        good={'schema':1,'created_suspended':True,'assigned_before_resume':True,'resumed':True,
              'owned_job_terminated':False,'owned_processes_closed':True,'handles_closed':True,'exit_code':0,'ordinary_exit':True}
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary);file=root/'process.safe.json'
            file.write_text(json.dumps(good));m.job_closed(root)
            for key in good:
                bad=dict(good);del bad[key];file.write_text(json.dumps(bad))
                with self.assertRaises(AssertionError):m.job_closed(root)

            for key in ('created_suspended','assigned_before_resume','resumed','owned_processes_closed','handles_closed','ordinary_exit'):
                for value in (False,'true',1,None):
                    bad=dict(good);bad[key]=value;file.write_text(json.dumps(bad))
                    with self.assertRaises(AssertionError):m.job_closed(root)
            for change in ({'owned_job_terminated':True},{'exit_code':True},{'exit_code':1},{'schema':True},{'private':'secret'}):
                file.write_text(json.dumps({**good,**change}))
                with self.assertRaises(AssertionError):m.job_closed(root)

    def test_owned_status_shape_path_uuid_and_typed_flags(self):
        good={'schema':1,'state':'calling','call_uuid':'12345678-1234-4234-a234-123456789abc',
              'media_uuid':None,'directory':'owned/greetings','file_exists':False,'file_sha256':None,
              'partial_absent':False,'media_exact':False,'recording_exact':False,'preserved':True}
        self.assertEqual(m.status_record(good,'owned/greetings'),good)
        for key in good:
            bad=dict(good);del bad[key]
            with self.assertRaises(AssertionError):m.status_record(bad,'owned/greetings')
        for change in ({'schema':True},{'state':'pending'},{'directory':'foreign/greetings'},
                       {'call_uuid':'-'*36},{'media_uuid':True},{'file_sha256':'a'*64},
                       {'file_exists':True},{'preserved':1},{'media_exact':'true'},{'raw':'private'}):
            with self.assertRaises(AssertionError):m.status_record({**good,**change},'owned/greetings')

    def test_actual_worker_and_wire_call_source(self):
        source=(ROOT/'tests/windows_greetings_native.py').read_text();tree=ast.parse(source)
        qualify=next(n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name=='qualify')
        text=ast.get_source_segment(source,qualify)
        self.assertIn("phone.dtmf({'media':media,'text':phone.sdp(media),'callid':callid},'#')",text)
        self.assertIn("event.get('Unique-ID')==status['call_uuid']",text)
        self.assertIn("f.cli('greetings-arm')",text)
        self.assertIn("f.cli('greetings-cleanup')",text)
        self.assertLess(text.index("f.cli('greetings-prepare')"),text.index("f.cli('greetings-arm')"))
        self.assertLess(text.index("Playback(f.cli('services-info')"),text.index("f.cli('greetings-arm')"))
        self.assertNotIn('luarun',source);self.assertNotIn('ElevenLabs:ApiKey',source)
        self.assertNotIn('freeswitch.Session',source)
        self.assertIn("assert ratio>=.8",source)
        worker=(ROOT/'platform/OpenWebPbx.Server/GreetingWorker.cs').read_text()
        self.assertIn('if (!string.IsNullOrWhiteSpace(settings["ElevenLabs:ApiKey"])) await Prepare(db,ct);\n        await Dispatch(db,ct);',worker)
        self.assertIn('luarun app/pbx_greetings/call.lua ',worker)
        self.assertIn('Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "storage", "greetings")',worker)
        self.assertIn("PHP_OS_FAMILY==='Windows'?self::state().'/storage/greetings':self::media()",(ROOT/'resources/classes/pbx_paths.php').read_text())
        caller=(ROOT/'tests/windows-native-acceptance.py').read_text()
        self.assertEqual(caller.count("greeting.qualify(f,a,original,sys.modules[__name__],NativePlayback)"),1)
        self.assertLess(caller.index("native_tls_signalling_two_way_decoded_rtp',**call_check('8101',background_cdr=True)"),caller.index('greeting.qualify('))

    def test_localservice_controller_adapter_success_and_refusals(self):
        # Deliberately an adapter: does not execute a task, modify ACLs or
        # establish native LocalService access. It checks the actual controller's
        # closed receipt/Job refusal and cleanup propagation.
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary)
            for fault in ('none','identity','job','cleanup'):
                scope=root/fault;scope.mkdir();evidence=scope/'evidence';evidence.mkdir();events=[]
                (scope/'State/storage/greetings').mkdir(parents=True)
                fixture=types.SimpleNamespace(source=ROOT,evidence=evidence,s={'private_state_root':str(scope/'State'),'domain':'12345678-1234-4234-a234-123456789abc'})
                def runner(command,directory,timeout):
                    self.assertEqual(timeout,240);events.append(command)
                    self.assertTrue(PureWindowsPath(command[0]).is_absolute(),'The unchanged native Job does not search PATH')
                    proof={'schema':1,'created_suspended':True,'assigned_before_resume':True,'resumed':True,
                           'owned_job_terminated':False,'owned_processes_closed':fault!='job','handles_closed':True,'exit_code':0,'ordinary_exit':True}
                    (directory/'process.safe.json').write_text(json.dumps(proof))
                    if command[0]==r'C:\Windows\System32\icacls.exe':
                        self.assertNotIn('storage',str(command[1]));value=None
                    else:
                        text=command[-1];operation=next(x for x in ('register','start-wait','cleanup')if "-Operation '"+x+"'" in text)
                        request=Path(text.split("-Request '",1)[1][:-1]);payload=json.loads(request.read_text());script=Path(payload['root'])/'localservice/read.ps1'
                        self.assertEqual(hashlib.sha256(script.read_bytes()).hexdigest(),payload['script_sha256'])
                        self.assertIn('$handle.Write($bytes,0,$bytes.Length)',script.read_text())
                        if operation=='register':value={'schema':1,'created':True,'task_name':payload['task_name'],'task_path':'\\','nonce':payload['nonce'],'definition_sha256':'a'*64,'script_sha256':payload['script_sha256']}
                        elif operation=='start-wait':
                            (Path(payload['root'])/'output/greetings.safe.json').write_text(json.dumps({'schema':1,'actual_localservice':fault!='identity','default_storage_create_read_delete':True,'owned_storage_removed':True}))
                            value={'schema':1,'state':'completed','last_run_advanced':True,'last_task_result':0}
                        else:value={'schema':1,'state':'removed','owned_registration_removed':fault!='cleanup'}
                    return subprocess.CompletedProcess(command,0,json.dumps(value).encode(),b'')
                with patch.dict('os.environ',{'RUNNER_TEMP':str(scope),'SystemRoot':r'C:\Windows'}):
                    if fault=='none':self.assertTrue(m.localservice_storage(fixture,types.SimpleNamespace(WINPS=r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'),runner,str(scope/'State/storage/greetings')))
                    else:
                        with self.assertRaises(AssertionError):m.localservice_storage(fixture,types.SimpleNamespace(WINPS=r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'),runner,str(scope/'State/storage/greetings'))
                if fault=='none':self.assertFalse(list(scope.glob('OpenWebPBX-BackupPublication-*')))
                if fault=='identity':self.assertTrue(any("-Operation 'cleanup'"in c[-1]for c in events))

    def test_icacls_uses_absolute_matching_native_SystemRoot(self):
        for root in (r'C:\Windows',r'D:\Windows System',r'c:\WINDOWS'):
            with patch.dict('os.environ',{'SystemRoot':root}):
                powershell=str(PureWindowsPath(root)/'System32/WindowsPowerShell/v1.0/powershell.exe')
                actual=m.icacls_path(powershell)
                self.assertTrue(PureWindowsPath(actual).is_absolute())
                self.assertEqual(PureWindowsPath(actual),PureWindowsPath(root)/'System32/icacls.exe')
                for bad in ('powershell.exe',r'C:\Tools\powershell.exe',str(PureWindowsPath(root)/'System32/icacls.exe')):
                    with self.assertRaises(AssertionError):m.icacls_path(bad)
        for root in ('Windows',r'C:Windows',r'\\server\share\Windows',r'C:\Windows\..\Other'):
            with patch.dict('os.environ',{'SystemRoot':root}):
                with self.assertRaises(AssertionError):m.icacls_path(str(PureWindowsPath(root)/'System32/WindowsPowerShell/v1.0/powershell.exe'))
        source=(ROOT/'tests/windows_greetings_native.py').read_text()
        self.assertNotIn("run(['icacls.exe'",source)
        self.assertIn('run([icacls_path(main.WINPS),',source)

    @unittest.skipUnless(os.name=='nt' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
                         and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx'
                         and os.environ.get('GITHUB_ACTIONS')=='true',
                         'Actual owned Job executable resolution requires disposable hosted Windows')
    def test_native_unchanged_Job_bare_refusal_and_absolute_icacls(self):
        self.assertEqual(struct.calcsize('P'),8)
        path=ROOT/'tests/windows_meeting_owned_process.py'
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),'9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448')
        spec=importlib.util.spec_from_file_location('actual_unchanged_greeting_job',path)
        job=importlib.util.module_from_spec(spec);spec.loader.exec_module(job)
        powershell=str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe')
        executable=m.icacls_path(powershell)
        self.assertTrue(Path(executable).is_file())
        work=Path(tempfile.mkdtemp(prefix='owned-greeting-executable-',dir=os.environ['RUNNER_TEMP']))
        previous=Path.cwd();complete=False
        try:
            os.chdir(work)
            self.assertFalse((work/'icacls.exe').exists())
            self.assertNotEqual(PureWindowsPath(work),PureWindowsPath(executable).parent)
            refused=work/'bare';refused.mkdir()
            with self.assertRaises(FileNotFoundError)as caught:job.run(['icacls.exe','/?'],refused,timeout=240)
            self.assertEqual(caught.exception.winerror,2)
            self.assertIs(caught.exception.owned_processes_closed,True)
            proof=m.exact(json.loads((refused/'process.safe.json').read_text()),
                ('schema','created_suspended','assigned_before_resume','resumed','owned_job_terminated',
                 'owned_processes_closed','handles_closed','exit_code','ordinary_exit'))
            self.assertIs(type(proof['schema']),int);self.assertEqual(proof['schema'],1);self.assertIsNone(proof['exit_code'])
            for key in ('created_suspended','assigned_before_resume','resumed','owned_job_terminated','ordinary_exit'):self.assertIs(proof[key],False)
            for key in ('owned_processes_closed','handles_closed'):self.assertIs(proof[key],True)
            accepted=work/'absolute';accepted.mkdir()
            result=job.run([executable,'/?'],accepted,timeout=240)
            result.check_returncode();m.job_closed(accepted)
            complete=True
        finally:
            os.chdir(previous)
            # Preserve any failed/uncertain native evidence. Only both proved
            # process/handle closures permit deleting this owned test scope.
            if complete:shutil.rmtree(work)

    def test_installed_physical_lua_and_owned_database_guards(self):
        php=(ROOT/'tests/windows_greetings_fixture.php').read_text()
        for text in ("['call.lua','recording.lua']","$scripts.'/app/pbx_greetings/'",'hash_file(\'sha256\',$installed)!==$sha',
                     "'ready_to_call'","state='cancelled' and call_uuid is null",'row[\'call_uuid\']',
                     "['ready','cancelled','failed']",'windows_greetings_native_snapshot','other_domain_and_custom_preserved_before_cleanup'):
            self.assertIn(text,php)
        self.assertLess(php.index('The actual installed greeting Lua is missing.'),php.index("$s['greeting_native']="))
        self.assertIn("$g['root']!==$base.'/'.$domain.'/greetings/'.$g['id']",php)
        parent=(ROOT/'tests/windows-native-fixture.php').read_text()
        self.assertLess(parent.index("$fixtureStage='admin_permissions'"),parent.index("windows_greetings_native_fixture($action"))
        self.assertIn("isset($s['greeting_native'])&&!($s['greeting_native']['cleaned']??false)",parent)

    def test_localservice_probe_cannot_grant_real_storage(self):
        source=(ROOT/'tests/windows_greetings_native.py').read_text();tree=ast.parse(source)
        node=next(n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name=='localservice_storage');text=ast.get_source_segment(source,node)
        self.assertIn("storage=Path(storage_root)/domain/'greetings'/('native-permission-'+nonce)",text)
        self.assertIn("((root,'*S-1-5-19:(RX)'),(local,'*S-1-5-19:(OI)(CI)RX'),(output,'*S-1-5-19:(OI)(CI)M'),(script,'*S-1-5-19:R'))",text)
        self.assertNotIn('storage,\'/grant\'',text)
        self.assertIn("identity.User.Value -cne 'S-1-5-19'",text)
        self.assertIn("task('start-wait')",text);self.assertIn("task('cleanup')",text)
        self.assertIn('timeout=240',text);self.assertIn('job_closed(directory)',text)
        self.assertIn("task_name':'OpenWebPBX-Backup-LocalService-'+nonce",text)
        self.assertIn("if primary is None:raise",text)


if __name__=='__main__':unittest.main(argv=[__file__,*remaining])
