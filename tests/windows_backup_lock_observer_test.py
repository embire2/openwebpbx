"""Actual portable lock behavior and closed observation type/privacy controls."""
import fcntl
import importlib.util
import json
import copy
import os
import subprocess
from unittest.mock import patch
from pathlib import Path
import tempfile
import types
import unittest

spec = importlib.util.spec_from_file_location('lock_observer', Path(__file__).with_name('windows-backup-lock-observer.py'))
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class LockObservation(unittest.TestCase):
    def test_exact_existing_primitive_refuses_content_or_path_changes(self):
        with tempfile.TemporaryDirectory(prefix='backup-lock-observe-') as folder:
            path = Path(folder) / 'lock'
            original = b'PRIVATE_UNPUBLISHED_LOCK_BYTES'
            path.write_bytes(original)
            path.chmod(0o600)
            module = types.SimpleNamespace(reparse=lambda p: p.is_symlink(), ordinary=lambda p: p,
                lock_file=lambda f: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB),
                unlock_file=lambda f: fcntl.flock(f, fcntl.LOCK_UN))
            before = (path.read_bytes(), path.stat().st_mode)
            self.assertEqual(observer.probe_existing_lock(module, path), {'state': 'available', 'stream_closed': True})
            with path.open('r+b') as holder:
                fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(observer.probe_existing_lock(module, path), {'state': 'busy', 'stream_closed': True})
                fcntl.flock(holder, fcntl.LOCK_UN)
            self.assertEqual((path.read_bytes(), path.stat().st_mode), before)
            missing = path.with_name('missing')
            self.assertEqual(observer.probe_existing_lock(module, missing)['state'], 'missing')
            self.assertFalse(missing.exists())
            link = path.with_name('link'); link.symlink_to(path)
            self.assertEqual(observer.probe_existing_lock(module, link)['state'], 'not_ordinary')
            self.assertNotIn(original.decode(), json.dumps(observer.probe_existing_lock(module, path)))

    def test_shape_type_bounds_and_private_fields_refuse(self):
        good = dict(observed=True, health_observed=True, local_running=True, version_matches=True,
                    iis_login_ready=True, known_recover_holder=True, holder_count=1,
                    verified_holder_count=1, updater_state='Running')
        self.assertEqual(observer.native_fields(good), good)
        for name in good:
            for bad in (None, [], [good[name]]):
                with self.subTest(name=name, bad=type(bad).__name__):
                    self.assertIsNone(observer.native_fields(good | {name: bad}))
            missing = dict(good); del missing[name]
            self.assertIsNone(observer.native_fields(missing))
        for bad in (good | {'private': 'PRIVATE'}, good | {'holder_count': True},
                    good | {'holder_count': 33}, good | {'verified_holder_count': 2},
                    good | {'updater_state': 'PRIVATE'}):
            self.assertIsNone(observer.native_fields(bad))

    def test_observe_preserves_original_error_and_uses_only_existing_exact_locks(self):
        class BackupError(RuntimeError): pass
        with tempfile.TemporaryDirectory(prefix='backup-lock-native-boundary-') as folder:
            state=Path(folder)/'OpenWebPBX';private=state/'backup-qualification';store=state/'backups'
            private.mkdir(parents=True);store.mkdir()
            upgrade=state/'upgrade.lock';worker=store/'worker.lock'
            for file in (upgrade,worker):file.write_bytes(b'PRIVATE_LOCK_BODY')
            module=types.SimpleNamespace(BackupError=BackupError,UPGRADE_LOCK=upgrade,STORE=store,
                reparse=lambda p:p.is_symlink(),ordinary=lambda p:p,
                lock_file=lambda f:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB),
                unlock_file=lambda f:fcntl.flock(f,fcntl.LOCK_UN),native_powershell_environment=lambda:{'SAFE':'1'})
            original=BackupError(observer.BUSY)
            native=dict(observed=True,health_observed=False,local_running=False,version_matches=False,
                iis_login_ready=False,known_recover_holder=False,holder_count=0,verified_holder_count=0,updater_state='unknown')
            completed=types.SimpleNamespace(returncode=0,stdout=json.dumps(native).encode(),stderr=b'PRIVATE_CHILD_ERROR')
            environment={'ProgramData':folder,'SystemRoot':folder,'GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted','GITHUB_REPOSITORY':'embire2/openwebpbx'}
            # PosixPath is explicit only for this portable boundary mock; production
            # executes the exact platform Path and product msvcrt primitive.
            with patch.object(observer.os,'name','nt'),patch.dict(observer.os.environ,environment),patch.object(observer,'Path',type(state)),patch.object(observer.subprocess,'run',return_value=completed) as run:
                record=observer.observe(module,private,original)
                self.assertEqual(record['upgrade']['state'],'available');self.assertEqual(record['worker']['state'],'available')
                self.assertEqual(record['native'],native);self.assertEqual(run.call_args.kwargs['timeout'],25)
                self.assertEqual(run.call_args.kwargs['env'],{'SAFE':'1'})
                self.assertNotIn('PRIVATE',json.dumps(record));self.assertEqual(str(original),observer.BUSY)
                completed.stdout=json.dumps(native|{'private':'PRIVATE_CHILD'}).encode()
                self.assertNotIn('native',observer.observe(module,private,original))
                with patch.object(observer.subprocess,'run',side_effect=subprocess.TimeoutExpired('PRIVATE_COMMAND',25)):
                    self.assertEqual(observer.observe(module,private,original)['worker']['state'],'available')
            for file in (upgrade,worker):self.assertEqual(file.read_bytes(),b'PRIVATE_LOCK_BODY')
            self.assertTrue((private/'backup-lock-private.err').exists())

    def test_actual_powershell_projection_refuses_shapes_types_and_private_values(self):
        powershell=os.environ.get('POWERSHELL_EXE','/var/lib/openwebpbx/windows113-core/powershell/pwsh')
        if not Path(powershell).is_file():self.skipTest('Portable PowerShell is unavailable')
        native=dict(observed=True,health_observed=True,local_running=True,version_matches=True,iis_login_ready=True,
                    known_recover_holder=True,holder_count=1,verified_holder_count=1,updater_state='Running')
        good={'schema':1,'observation':'after_original_busy_error','upgrade':{'state':'busy','stream_closed':True},
              'worker':{'state':'available','stream_closed':True},'native':native}
        cases=[]
        def case(value,lock=True,native_present=True):cases.append({'value':value,'lock':lock,'native':native_present})
        case(good)
        for state in sorted(observer.LOCK_STATES):
            value=copy.deepcopy(good);value['upgrade']['state']=state;case(value)
        for value in (None,[],[good],True,'PRIVATE_VALUE'):case(value,False,False)
        for key in ('schema','observation','upgrade','worker'):
            for bad in (None,[],[good.get(key)],True,'PRIVATE_VALUE'):
                value=copy.deepcopy(good);value[key]=bad;case(value,False,False)
        for branch in ('upgrade','worker'):
            for key in ('state','stream_closed'):
                for bad in (None,[],[good[branch][key]],'PRIVATE_VALUE',1):
                    value=copy.deepcopy(good);value[branch][key]=bad;case(value,False,False)
        for key in native:
            for bad in (None,[],[native[key]],'PRIVATE_VALUE'):
                value=copy.deepcopy(good);value['native'][key]=bad;case(value,True,False)
        for updates in ({'holder_count':True},{'holder_count':33},{'verified_holder_count':2},{'holder_count':-1}):
            value=copy.deepcopy(good);value['native'].update(updates);case(value,True,False)
        for bad in (None,[],[native],True):
            value=copy.deepcopy(good);value['native']=bad;case(value,True,False)
        value=copy.deepcopy(good);value['private']='PRIVATE_VALUE';value['native']['private']='PRIVATE_VALUE';value['upgrade']['private']='PRIVATE_VALUE';case(value)
        with tempfile.TemporaryDirectory(prefix='backup-lock-projector-') as folder:
            directory=Path(folder);(directory/'backup-qualification').mkdir()
            inputs=directory/'inputs.json';inputs.write_text(json.dumps(cases),encoding='utf-8')
            script=directory/'controls.ps1';script.write_text(PS_CONTROLS,encoding='utf-8')
            result=subprocess.run([powershell,'-NoProfile','-NonInteractive','-File',str(script),'-Suite',str(Path(__file__).with_name('windows-suite.ps1')),'-Inputs',str(inputs)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,'Actual closed lock projector controls failed: '+result.stderr)
            self.assertNotIn('PRIVATE_VALUE',result.stdout);self.assertNotIn('PRIVATE_VALUE',result.stderr)
            self.assertGreaterEqual(json.loads(result.stdout)['checks'],len(cases)*4)

    def test_unrelated_failure_and_non_native_use_do_not_probe(self):
        module = types.SimpleNamespace(BackupError=RuntimeError)
        self.assertIsNone(observer.observe(module, Path('/not-an-install'), ValueError('PRIVATE')))
        self.assertIsNone(observer.observe(module, Path('/not-an-install'), RuntimeError(observer.BUSY)))


PS_CONTROLS=r'''
param([string]$Suite,[string]$Inputs)
$ErrorActionPreference='Stop';$count=0
function Check([bool]$Value){if(!$Value){throw 'A closed lock diagnostic assertion failed.'};$script:count++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Suite,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'BackupFailureReport'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$path=Join-Path (Join-Path $PSScriptRoot 'backup-qualification') 'report.json'
foreach($case in @(Get-Content -LiteralPath $Inputs -Raw|ConvertFrom-Json)){
 $record=@{state='failed';failure=@{schema=1;failed_phase='native successful restore';error_type='BackupError';completed_checks=5;source_frames=@();lock_observation=$case.value}}
 [IO.File]::WriteAllText($path,($record|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
 $safe=BackupFailureReport $path ([datetime]::MinValue)
 Check ($safe.report_status -ceq 'read' -and $safe.error_type -ceq 'BackupError' -and $safe.failed_phase -ceq 'native successful restore' -and $safe.completed_checks -eq 5)
 Check ($safe.ContainsKey('lock_observation') -ceq $case.lock)
 Check (($safe.ContainsKey('lock_observation') -and $safe.lock_observation.ContainsKey('native')) -ceq $case.native)
 Check (!(($safe|ConvertTo-Json -Depth 15).Contains('PRIVATE_VALUE')))
}
@{state='passed';checks=$count}|ConvertTo-Json -Compress
'''

if __name__ == '__main__':
    unittest.main()
