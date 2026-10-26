"""Actual observer entry/closed-report controls; OS task and ACL boundaries are explicit."""
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
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
REF = 'embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/qualification/windows120-https-restore-20261024'
MARKER = 'PRIVATE_OBSERVER_ENTRY_861e'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Controls(unittest.TestCase):
    def test_new_release_ref_is_exact_without_prefix_or_foreign_admission(self):
        observer = load('owned_windows121_ref_observer', ROOT/'tests/windows-backups-worker-observer.py')
        approved = 'embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/qualification/windows121-greetings-release-20261026'
        self.assertIn(approved, observer.WORKFLOW_REFS)
        self.assertIn(REF, observer.WORKFLOW_REFS)
        for value in (approved+'-other', approved+'/', approved.replace('heads/','tags/'),
                      approved.replace('embire2/openwebpbx','foreign/openwebpbx'),
                      approved.replace('windows-suite.yml','windows-native.yml'),
                      approved.replace('20261026','20261027')):
            self.assertNotIn(value, observer.WORKFLOW_REFS)
        actual=self.entry(workflow_ref=approved)
        self.assertIsNone(actual['caught'])
        self.assertTrue(actual['entered'])
        self.assertTrue(actual['report']['action_restored'])

    def setUp(self):
        if os.name != 'posix':
            self.skipTest('These POSIX-only Scheduler adapters use synthetic C: path components.')
        self.observer = load('owned_entry_observer', ROOT/'tests/windows-backups-worker-observer.py')
        self.previous_controls = load('owned_existing_controls', ROOT/'tests/windows_backup_worker_observer.py')
        self.diagnostics = load('owned_diagnostic_controls', ROOT/'tests/windows_backup_diagnostics.py')
        self.pwsh = os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh')
        self.assertTrue(self.pwsh)

    def entry(self, approved=True, body_error=None, task_change=None, workflow_ref=REF):
        if os.name != 'posix':
            raise RuntimeError('The synthetic C: path fixture requires a POSIX host.')
        with tempfile.TemporaryDirectory(prefix='openweb-observer-entry-') as temporary:
            root = Path(temporary)
            private = root/'ProgramData/OpenWebPBX/backup-qualification'
            private.mkdir(parents=True)
            installed = root/'C:/OpenWebPBX/tools/backups.py'
            installed.parent.mkdir(parents=True)
            installed.write_bytes((ROOT/'packaging/windows/backups.py').read_bytes())
            package = root/'package'
            package.mkdir()
            shutil.copyfile(installed, package/'backups.py')
            state = root/'task.json'
            original = {'execute':r'C:\OpenWebPBX\backup-runtime\python.exe',
                        'arguments':r'-I "C:\OpenWebPBX\tools\backups.py" worker',
                        'working_directory':r'C:\OpenWebPBX\tools'}
            if task_change:
                original.update(task_change)
            state.write_text(json.dumps(original))
            commands = []
            acl_calls = []
            def ps(code):
                commands.append(code)
                prefix = self.previous_controls.PS_BOUNDARY.replace('__STATE__', str(state).replace("'", "''"))
                result = subprocess.run([self.pwsh, '-NoProfile', '-Command', prefix+'\n'+code],
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, 'Owned Scheduler adapter refused')
                return result.stdout.strip()
            fake = types.SimpleNamespace(STATE=private.parent,
                reparse=lambda path:Path(path).is_symlink(), secure_acl=lambda path:acl_calls.append(path),
                atomic_json=lambda path,value:Path(path).write_text(json.dumps(value), encoding='utf-8'))
            environment = os.environ|{'GITHUB_ACTIONS':'true','OPENWEB_WINDOWS_BACKUP_TEST':'1',
                'GITHUB_RUN_ID':'40100370382','GITHUB_SHA':'b3225ed98f8c0860ac215fa462ae80e894795b0e',
                'GITHUB_REPOSITORY':'embire2/openwebpbx','GITHUB_WORKFLOW_REF':workflow_ref,
                'ProgramData':str(root/'ProgramData')}
            previous = Path.cwd()
            allowed = self.observer.WORKFLOW_REFS if approved else self.observer.WORKFLOW_REFS-{REF}
            caught = None
            entered = False
            try:
                os.chdir(root)
                with patch.object(self.observer, 'os', types.SimpleNamespace(name='nt', environ=environment)), \
                     patch.object(self.observer, 'WORKFLOW_REFS', allowed):
                    lease = self.observer.TaskActionLease(fake, ps, private, package)
                    try:
                        with lease:
                            entered = True
                            self.assertEqual(json.loads(state.read_text())['arguments'], lease.arguments)
                            if body_error is not None:
                                raise body_error
                    except BaseException as error:
                        caught = error
                    report = lease.safe_report()
                    fields = self.diagnostics.library()['backup_exception_fields'](caught, 'native SFTP', ['a','b','c']) if caught else None
                    config = json.loads(lease.config.read_text()) if lease.config.exists() else None
            finally:
                os.chdir(previous)
            self.assertEqual(json.loads(state.read_text()), original)
            if config:
                self.assertEqual(config['workflow_ref'], workflow_ref)
                self.assertEqual(config['source_sha256'], hashlib.sha256(installed.read_bytes()).hexdigest())
                self.assertEqual(config['launcher_sha256'], hashlib.sha256(lease.launcher.read_bytes()).hexdigest())
            return {'caught':caught,'entered':entered,'commands':commands,'report':report,'fields':fields,
                    'config_written':config is not None,'acl_calls':len(acl_calls)}

    def test_non_posix_adapter_refuses_before_any_fixture_or_task_access(self):
        # Use the function globals directly so importlib-loaded repeat controls
        # receive exactly the same boundary as standalone unittest execution.
        scope = self.entry.__func__.__globals__
        create = Mock(side_effect=AssertionError('A non-POSIX fixture was created'))
        task = Mock(side_effect=AssertionError('A non-POSIX task was accessed'))
        paths = Mock(side_effect=AssertionError('A non-POSIX path was accessed'))
        child = Mock(side_effect=AssertionError('A non-POSIX child was started'))
        loading = Mock(side_effect=AssertionError('A non-POSIX adapter was loaded'))
        native = types.SimpleNamespace(name='nt')
        with patch.dict(scope, {'os':native, 'Path':paths, 'load':loading}), \
             patch.object(tempfile, 'TemporaryDirectory', create), \
             patch.object(self.observer, 'TaskActionLease', task), \
             patch.object(subprocess, 'run', child):
            with self.assertRaisesRegex(RuntimeError, '^The synthetic C: path fixture requires a POSIX host\\.$'):
                self.entry()
            with self.assertRaises(unittest.SkipTest):
                self.setUp()
        create.assert_not_called()
        task.assert_not_called()
        paths.assert_not_called()
        child.assert_not_called()
        loading.assert_not_called()

    def test_actual_original_refusal_before_task_mutation_and_no_cause_inference(self):
        result = self.entry(approved=False)
        self.assertIsInstance(result['caught'], RuntimeError)
        self.assertEqual(str(result['caught']), 'Disposable worker observation binding refused.')
        self.assertFalse(result['entered'])
        self.assertTrue(result['config_written'])
        self.assertEqual(result['acl_calls'], 1)
        self.assertEqual(len(result['commands']), 1)
        self.assertFalse(any('Set-ScheduledTask' in code for code in result['commands']))
        self.assertEqual(result['report'], {'schema':1,'report_status':'unavailable','action_restored':False})
        frames = result['fields']['source_frames']
        self.assertEqual([frame['source_basename'] for frame in frames],
                         ['windows-backups-worker-observer.py','windows-backups-worker-observer.py'])
        self.assertNotIn(MARKER, json.dumps(result['fields']))

    def test_exact_ref_entry_and_original_action_restoration(self):
        result = self.entry()
        self.assertIsNone(result['caught'])
        self.assertTrue(result['entered'])
        self.assertTrue(result['report']['action_restored'])
        self.assertEqual(sum('Set-ScheduledTask' in code for code in result['commands']), 2)
        self.assertTrue(all('-Action $a' in code for code in result['commands'] if 'Set-ScheduledTask' in code))
        self.assertFalse(any('Start-ScheduledTask' in code or 'Stop-ScheduledTask' in code for code in result['commands']))

    def test_body_exception_identity_and_original_task_restoration(self):
        error = AssertionError(MARKER)
        result = self.entry(body_error=error)
        self.assertIs(result['caught'], error)
        self.assertTrue(result['report']['action_restored'])
        self.assertNotIn(MARKER, json.dumps(result['fields']))

    def test_existing_task_action_guards_remain_required(self):
        for change in ({'execute':r'C:\foreign\python.exe'}, {'arguments':'worker'},
                       {'working_directory':r'C:\foreign'}):
            with self.subTest(change=list(change)):
                result = self.entry(task_change=change)
                self.assertFalse(result['entered'])
                self.assertIsInstance(result['caught'], RuntimeError)
                self.assertFalse(result['config_written'])
                self.assertFalse(any('Set-ScheduledTask' in code for code in result['commands']))

    def test_exact_workflow_and_all_binding_negatives(self):
        with tempfile.TemporaryDirectory(prefix='openweb-entry-binding-') as temporary:
            root = Path(temporary)
            private = root/'OpenWebPBX/backup-qualification'
            private.mkdir(parents=True)
            path = private/'worker-observer-config.json'
            valid = {'schema':1,'disposable_hosted_runner':True,'hostname':socket.gethostname(),
                'run_id':'40100370382','source_commit':'b3225ed98f8c0860ac215fa462ae80e894795b0e',
                'repository':'embire2/openwebpbx','workflow_ref':REF,'source_sha256':'b'*64,
                'launcher_sha256':hashlib.sha256((ROOT/'tests/windows-backups-worker-observer.py').read_bytes()).hexdigest()}
            refs = [REF+'-foreign', REF.replace('20261024','20261025'), REF.replace('refs/heads/','refs/tags/'),
                    REF.replace('embire2/','foreign/'), REF.replace('windows-suite.yml','windows-backups-diagnostics.yml'),
                    REF.replace('qualification/',''), REF.upper(), REF+'\n', REF+'/', [REF], None]
            changes = [{'workflow_ref':ref} for ref in refs]+[
                {'schema':True},{'disposable_hosted_runner':False},{'hostname':MARKER},{'run_id':MARKER},
                {'source_commit':'a'*39},{'repository':MARKER},{'source_sha256':MARKER},{'launcher_sha256':'0'*64}]
            with patch.dict(os.environ, {'ProgramData':str(root)}):
                for approved in self.observer.WORKFLOW_REFS:
                    path.write_text(json.dumps(valid|{'workflow_ref':approved}))
                    self.assertEqual(self.observer.validated_config(path)['workflow_ref'], approved)
                for change in changes:
                    with self.subTest(change=list(change)):
                        path.write_text(json.dumps(valid|change))
                        with self.assertRaises(RuntimeError):
                            self.observer.validated_config(path)
                path.write_text(json.dumps(valid))
                other = private/'foreign-config.json'
                other.write_bytes(path.read_bytes())
                with self.assertRaises(RuntimeError):
                    self.observer.validated_config(other)

    def test_python_frames_are_closed_bounded_and_do_not_include_error_text(self):
        namespace = self.diagnostics.library()
        for filename in ('windows-backups-worker-observer.py', 'foreign.py'):
            scope = {}
            exec(compile('def fail(n):\n if n: return fail(n-1)\n raise RuntimeError("'+MARKER+'")\n',
                         str(Path('/private')/MARKER/filename), 'exec'), scope)
            try:
                scope['fail'](20)
            except RuntimeError as error:
                original = error
                fields = namespace['backup_exception_fields'](error, 'native SFTP', [])
                self.assertIs(error, original)
            self.assertEqual(len(fields['source_frames']), 8 if filename.startswith('windows-backups-') else 0)
            self.assertTrue(all(type(row['source_line']) is int and 1 <= row['source_line'] <= 20000 for row in fields['source_frames']))
            self.assertNotIn(MARKER, json.dumps(fields))
            self.assertNotIn('/private', json.dumps(fields))

    def test_actual_powershell_projection_refuses_private_names_types_and_ranges(self):
        with tempfile.TemporaryDirectory(prefix='openweb-entry-projector-') as temporary:
            root = Path(temporary)
            script = root/'check.ps1'
            script.write_text(PS_CONTROLS)
            result = subprocess.run([self.pwsh,'-NoProfile','-File',str(script),'-Suite',str(ROOT/'tests/windows-suite.ps1')],
                                    capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode, 0, 'Actual failure projector controls failed: '+result.stderr)
            value = json.loads(result.stdout)
            self.assertEqual(value['state'],'passed')
            self.assertGreaterEqual(value['checks'],20)
            self.assertNotIn(MARKER,result.stdout)


PS_CONTROLS = r'''
param([string]$Suite)
$ErrorActionPreference='Stop';$count=0
function Check([bool]$Value){if(!$Value){throw 'Observer entry projection control failed'};$script:count++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Suite,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'BackupFailureReport'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$directory=Join-Path $PSScriptRoot 'backup-qualification';New-Item -ItemType Directory -Path $directory|Out-Null
$path=Join-Path $directory 'report.json';$marker='PRIVATE_OBSERVER_ENTRY_861e'
$record=@{state='failed';failure=@{schema=1;failed_phase='native SFTP';error_type='RuntimeError';completed_checks=3;last_http=@{target='backups';method='POST';status=200};source_frames=@()}}
function Run($Frames){$record.failure.source_frames=@($Frames);[IO.File]::WriteAllText($path,($record|ConvertTo-Json -Depth 12));return (BackupFailureReport $path ([datetime]::MinValue))}
$name='windows-backups-worker-observer.py'
foreach($line in 1,20000){$safe=Run @(@{source_basename=$name;source_line=$line;private=$marker});Check ($safe.source_frames.Count -eq 1 -and $safe.source_frames[0].source_line -eq $line);Check (!(($safe|ConvertTo-Json -Depth 12).Contains($marker)))}
foreach($line in -1,0,20001,2147483648,$true,'12',12.5,@(12),$null){$safe=Run @(@{source_basename=$name;source_line=$line});Check ($safe.source_frames.Count -eq 0)}
foreach($bad in 'foreign.py','Windows-backups-worker-observer.py',('C:\'+$marker+'\'+$name),@($name),$null){$safe=Run @(@{source_basename=$bad;source_line=3});Check ($safe.source_frames.Count -eq 0);Check (!(($safe|ConvertTo-Json -Depth 12).Contains($marker)))}
$safe=Run (@(@{source_basename=$name;source_line=3})*9);Check ($safe.source_frames.Count -eq 0)
foreach($old in 'windows_backups_native.py','backups.py'){$safe=Run @(@{source_basename=$old;source_line=3});Check ($safe.source_frames.Count -eq 1)}
@{state='passed';checks=$count}|ConvertTo-Json -Compress
'''


if __name__ == '__main__':
    unittest.main()
