"""Actual one-invocation/error-record protocol; portable PS7, no Windows acceptance.

The tiny child is a control-CLI fixture. Manifest pins/native context/ACL are
explicit adapters here; the real installed Windows invocation remains pending.
"""
import ast
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import ModuleType, SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh')

def load(name, path, stdlib_only=False):
    if stdlib_only:
        # Exactly two encryption imports are irrelevant to control(); retain
        # every actual request/environment/tempfile/runner function unchanged.
        tree=ast.parse(path.read_text());removed=[node for node in tree.body if isinstance(node,ast.ImportFrom)and node.module.startswith('cryptography.')]
        if len(removed)!=2:raise AssertionError('Only the two unused crypto imports may be omitted.')
        tree.body=[node for node in tree.body if node not in removed]
        value=ModuleType(name);value.__file__=str(path);exec(compile(tree,str(path),'exec'),value.__dict__);return value
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

observer = load('control_observer_under_test', ROOT / 'tests/windows_backup_control_observer.py')

HARNESS = r'''
param([string]$Source,[string]$FieldsSource,[string]$Control,[string]$Request,[string]$ReportPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual observation source must parse.'}
foreach($name in 'BackupControlErrorType','BackupControlBasename','BackupControlFailureFields','InvokeObservedBackupControl'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($nodes.Count -ne 1){throw 'One actual definition required.'};. ([scriptblock]::Create($nodes[0].Extent.Text))
}
. $FieldsSource
try{throw 'STALE_PRIVATE_SENTINEL'}catch{}
$result=InvokeObservedBackupControl $Control 'plan' $Request
$facts=@{exit_code=$result.exit_code;original_error=($null -ne $result.error_record)}
if($result.exit_code -ne 0){
 $record=BackupControlFailureFields $result.error_record 'plan' $result.phase $result.exit_code $true
 $projected=BackupControlObservationFields ([pscustomobject]$record)
 if(!$projected){throw 'Actual closed error record was rejected.'}
 $facts.observation=$projected
 $private=[pscustomobject]$record;$private|Add-Member -NotePropertyName raw_message -NotePropertyValue 'PRIVATE_MUST_NOT_PUBLISH'
 if(BackupControlObservationFields $private){throw 'Private message was accepted.'}
 $mistyped=[pscustomobject]$record;$mistyped.hresult='1'
 if(BackupControlObservationFields $mistyped){throw 'String HResult was accepted.'}
}
[IO.File]::WriteAllText($ReportPath,($facts|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
exit $result.exit_code
'''

class Controls(unittest.TestCase):
    def setUp(self):
        if not PWSH: raise RuntimeError('Actual PowerShell is required; set OPENWEB_TEST_PWSH.')
        self.temp = tempfile.TemporaryDirectory(prefix='openweb-control-error-observer-')
        self.addCleanup(self.temp.cleanup); self.work = Path(self.temp.name)

    def actual_child(self, kind):
        control = self.work / 'Backup-Control.ps1'; request = self.work / 'request.txt'
        code = "param([string]$Operation,[string]$Request)\n[IO.File]::AppendAllText($Request,'1')\n"
        if kind == 'success': code += "[Console]::Out.WriteLine('{\"ok\":true}')\n"
        elif kind == 'operation': code += "try{throw [IO.IOException]::new('PRIMARY_PRIVATE_SENTINEL')}catch{[Console]::Error.WriteLine('GENERIC_CONTROL_FAILURE');exit 17}\n"
        else: code += ". (Join-Path $PSScriptRoot 'missing-import.ps1')\n"
        control.write_text(code); harness = self.work / 'harness.ps1'; harness.write_text(HARNESS)
        result_path = self.work / 'result.json'
        result = subprocess.run([PWSH, '-NoProfile', '-NonInteractive', '-File', str(harness),
            '-Source', str(ROOT/'tests/windows-backup-control-observer.ps1'),
            '-FieldsSource', str(ROOT/'tests/windows-backup-control-observation-fields.ps1'),
            '-Control', str(control), '-Request', str(request), '-ReportPath', str(result_path)], capture_output=True, timeout=20)
        self.assertEqual(request.read_text(), '1', 'The control script must be invoked exactly once.')
        facts = json.loads(result_path.read_text())
        self.assertEqual(facts['exit_code'], result.returncode)
        return result, facts

    def test_real_called_script_success_keeps_single_json_and_no_stale_error(self):
        result, facts = self.actual_child('success')
        self.assertEqual(result.returncode, 0); self.assertFalse(result.stderr)
        self.assertEqual(json.loads(result.stdout), {'ok': True}); self.assertFalse(facts['original_error'])

    def test_real_generic_catch_exit_retains_actual_original_record(self):
        result, facts = self.actual_child('operation')
        self.assertEqual(result.returncode, 17); self.assertFalse(result.stdout)
        self.assertEqual(result.stderr.decode().strip(), 'GENERIC_CONTROL_FAILURE')
        record = observer.closed(facts['observation'], 'plan')
        self.assertEqual(record['phase'], 'operation'); self.assertEqual(record['error_type'], 'System.IO.IOException')
        self.assertEqual(record['source_basename'], 'Backup-Control.ps1'); self.assertGreater(record['source_line'], 0)
        self.assertTrue(record['original_error_observed']); self.assertEqual(record['invocations'], 1)
        self.assertNotIn('PRIVATE_SENTINEL', json.dumps(record)); self.assertNotIn(str(self.work), json.dumps(record))

    def test_real_uncaught_import_failure_is_bootstrap_not_generic_operation(self):
        result, facts = self.actual_child('bootstrap')
        self.assertEqual(result.returncode, 1)
        record = observer.closed(facts['observation'], 'plan')
        self.assertEqual(record['phase'], 'bootstrap'); self.assertTrue(record['original_error_observed'])
        self.assertEqual(record['source_basename'], 'Backup-Control.ps1'); self.assertGreater(record['source_line'], 0)

    def bridge(self, fail=False, malformed=False):
        b = load('actual_backup_control_bridge', ROOT/'packaging/windows/backups.py', stdlib_only=True)
        b.STATE = self.work/'state'; (b.STATE/'backup-control').mkdir(parents=True)
        source = self.work/'source'; (source/'tests').mkdir(parents=True)
        (source/'tests/windows-backup-control-observer.ps1').write_text('# owned QA fixture')
        calls=[]; original_error=b.BackupError('PRIVATE_ORIGINAL_ERROR')
        def run(command, **kwargs):
            calls.append((command, kwargs))
            request=Path(command[command.index('-Request')+1]);self.assertEqual(json.loads(request.read_text()), {'original': True})
            self.assertEqual(kwargs['timeout'],180);self.assertIn('PSModulePath',kwargs['env'])
            self.assertEqual(Path(command[6]),source/'tests/windows-backup-control-observer.ps1')
            if fail:
                record={'schema':1,'producer':'windows-backup-control-observer.ps1','operation':'plan','phase':'operation','exit_code':17,'source_pins_verified':True,'invocations':1,'original_error_observed':True,'error_type':'System.IO.IOException','inner_error_type':'System.IO.IOException','hresult':2148734496,'source_basename':'Backup-Control.ps1','source_line':3,'caller_basename':'Backup-Control.ps1','caller_line':3}
                if malformed: record['raw_message']='PRIVATE_MUST_NOT_PUBLISH'
                Path(command[command.index('-DiagnosticPath')+1]).write_text(json.dumps(record))
                raise original_error
            return b'{"ok":true}'
        b.run=run;observer.install(b,source,self.work/'package',self.work)
        if fail:
            with self.assertRaises(b.BackupError)as caught:b.control('plan',{'original':True})
            self.assertIs(caught.exception,original_error)
        else:self.assertEqual(b.control('plan',{'original':True}),{'ok':True})
        self.assertEqual(len(calls),1);self.assertEqual(list((b.STATE/'backup-control').iterdir()),[])
        return b

    def test_actual_control_request_environment_timeout_and_unlink_are_unchanged(self):
        self.assertIsNone(self.bridge().qa_backup_control_failure)

    def test_one_failed_control_preserves_original_python_error_and_closed_observation(self):
        b=self.bridge(fail=True);self.assertEqual(b.qa_backup_control_failure['operation'],'plan')

    def test_private_or_malformed_observation_cannot_replace_original_failure(self):
        self.assertIsNone(self.bridge(fail=True,malformed=True).qa_backup_control_failure)

    def test_foreign_executable_with_otherwise_identical_arguments_is_not_redirected(self):
        source=self.work/'source';(source/'tests').mkdir(parents=True)
        (source/'tests/windows-backup-control-observer.ps1').write_text('# owned QA fixture')
        calls=[];b=SimpleNamespace(CONTROL=Path('C:/OpenWebPBX/tools/Backup-Control.ps1'),run=lambda command,**kw:calls.append((command,kw))or b'ORIGINAL')
        observer.install(b,source,self.work/'package',self.work)
        command=['FOREIGN-pwsh.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(b.CONTROL),'-Operation','plan','-Request','request.json']
        self.assertEqual(b.run(command,timeout=180),b'ORIGINAL');self.assertEqual(calls,[(command,{'timeout':180})])
        self.assertEqual(list(self.work.glob('backup-control-*.json')),[])

    def test_actual_embedded_probe_and_launcher_require_owned_context_only_for_controls(self):
        text=(ROOT/'tests/windows-upgrade-acceptance.ps1').read_text();embedded=text.split("$code=@'\n",1)[1].split("\n'@",1)[0]
        tree=ast.parse(embedded)
        controls=[n for n in tree.body if isinstance(n,ast.If)and"action in ('holds', 'release')"in ast.unparse(n.test)]
        self.assertEqual(len(controls),1);self.assertIn('observer.install',ast.unparse(controls[0]))
        self.assertIn("Path('C:/OpenWebPBX') / 'tools' / 'backups.py'",ast.unparse(controls[0]))
        self.assertIn("$Arguments[1] -cin 'holds','release'",text)
        self.assertIn('$Arguments+=@((Split-Path $PSScriptRoot -Parent),$PackageRoot,$controlEvidence)',text)
        self.assertIn('$script:controlEvidence=NewBackupControlObservationDirectory $work',text)

if __name__=='__main__':unittest.main()
