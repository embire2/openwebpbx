"""Actual fictional PowerShell delegation and private subprocess/report controls."""
import ast
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
PWSH=os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh')
MARKER='PRIVATE_TLS_PREPARATION_OBSERVER_536e'
THUMBPRINT='a'*40


@unittest.skipUnless(PWSH,'Actual PowerShell is required')
class PreparationObserver(unittest.TestCase):
    def invoke(self,body,expected,source=False):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary);product=directory/'OpenWebPBX/tools';product.mkdir(parents=True)
            (product/'Enable-PhoneTLS.ps1').write_text('param($CertificateThumbprint,[switch]$PrepareRestored)\n$global:delegateCalls++;$global:delegateArguments=@($CertificateThumbprint,[bool]$PrepareRestored)\n'+body)
            script=directory/'control.ps1'
            script.write_text(r'''
param($Source,$Owned,$Expected,$Mode)
$ErrorActionPreference='Stop';$global:delegateCalls=0
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual observer parse failed'}
foreach($name in 'Get-BackupTlsFailure','Invoke-ObservedBackupTlsPreparation'){
 $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($node.Count -ne 1){throw 'Unique actual source required'}
 $body=$node[0].Extent.Text
 if($name -ceq 'Invoke-ObservedBackupTlsPreparation'){
  $fixed="'C:/OpenWebPBX/tools/Enable-PhoneTLS.ps1'"
  if(([regex]::Matches($body,[regex]::Escape($fixed))).Count -ne 2){throw 'Two exact product mode bindings required'}
  # Only the fixed pathname is rebound to an owned fictional delegate. All
  # invocation arguments, observation and original error propagation are exact.
  $ownedHelper=(Join-Path $Owned 'OpenWebPBX/tools/Enable-PhoneTLS.ps1').Replace("'","''")
  $body=$body.Replace($fixed,("'"+$ownedHelper+"'"))
 }
 . ([ScriptBlock]::Create($body))
}
$path=Join-Path $Owned 'result.json';$preserved=$false;$returned=$false
try{$privateOutput=@(Invoke-ObservedBackupTlsPreparation ('a'*40) $path -SourceTls:($Mode -ceq 'source'));$returned=$true}catch{$preserved=$_.Exception.Message -ceq $Expected}
$record=if(Test-Path $path){Get-Content $path -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
@{calls=$global:delegateCalls;arguments=$global:delegateArguments;returned=$returned;original_error_preserved=$preserved;report=$record}|ConvertTo-Json -Depth 12 -Compress
''')
            result=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(script),str(ROOT/'tests/windows-backup-tls-observer.ps1'),str(directory),expected,'source' if source else 'restored'],capture_output=True,timeout=30)
            self.assertEqual(result.returncode,0)
            value=json.loads(result.stdout);self.assertEqual(value['calls'],1);self.assertEqual(value['arguments'],[THUMBPRINT,not source])
            if value['report'] is not None:self.assertEqual(value['report']['operation'],'source_trusted_tls' if source else 'prepare_restored_tls')
            return value

    def test_actual_delegate_success_once_and_no_failure_report(self):
        value=self.invoke('Write-Output "fictional helper success"','unused')
        self.assertTrue(value['returned']);self.assertIsNone(value['report'])

    def test_source_delegate_exact_normal_arguments_success_and_original_failure(self):
        value=self.invoke('Write-Output "fictional helper success"','unused',source=True)
        self.assertTrue(value['returned']);self.assertIsNone(value['report'])
        value=self.invoke("throw '"+MARKER+"'",MARKER,source=True)
        self.assertFalse(value['returned']);self.assertTrue(value['original_error_preserved'])
        self.assertEqual(value['report']['failure_class'],'unknown')
        self.assertNotIn(MARKER,json.dumps(value['report']))

    def test_actual_static_guard_source_and_original_failure(self):
        message='Windows could not verify the phone certificate chain.'
        value=self.invoke("throw '"+message+"'",message)
        self.assertFalse(value['returned']);self.assertTrue(value['original_error_preserved'])
        self.assertEqual(value['report']['failure_class'],'certificate_chain')
        self.assertTrue(any(x['source_basename']=='Enable-PhoneTLS.ps1' for x in value['report']['source_frames']))

    def test_unknown_message_and_private_php_fields_are_not_exported(self):
        value=self.invoke("throw '"+MARKER+"'",MARKER)
        self.assertTrue(value['original_error_preserved']);self.assertEqual(value['report']['failure_class'],'unknown')
        self.assertNotIn(MARKER,json.dumps(value['report']))
        message='Secure phone setup failed.'
        value=self.invoke("$e=[InvalidOperationException]::new('"+message+"');$e.Data['OpenWebPhoneTLSPhpFailure']=@{schema=1;error_type='RuntimeException';source_basename='phone-tls.php';source_line=86;stage='apply';private='"+MARKER+"'};throw $e",message)
        self.assertTrue(value['original_error_preserved']);self.assertEqual(value['report']['failure_class'],'native_php')
        self.assertEqual(value['report']['php_failure'],{'error_type':'RuntimeException','source_basename':'phone-tls.php','source_line':86,'stage':'apply'})
        self.assertNotIn(MARKER,json.dumps(value['report']))

    def test_win32_numeric_code_is_closed(self):
        value=self.invoke("throw [ComponentModel.Win32Exception]::new(5,'"+MARKER+"')",MARKER)
        self.assertEqual(value['report']['native_code'],5);self.assertIsInstance(value['report']['hresult'],int)
        self.assertNotIn(MARKER,json.dumps(value['report']))

    def test_exact_ps_projector_rejects_private_values_and_bad_types(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary);private=directory/'backup-qualification';private.mkdir();path=private/'report.json'
            tls={'schema':1,'operation':'prepare_restored_tls','report_status':'read','state':'failed','error_type':'RuntimeException','failure_class':'certificate_chain','returncode':1,'hresult':-1,'native_code':5,'source_frames':[{'source_basename':'Enable-PhoneTLS.ps1','source_line':29}], 'php_failure':{'error_type':'RuntimeException','source_basename':'phone-tls.php','source_line':86,'stage':'apply','private':MARKER},'private':MARKER}
            path.write_text(json.dumps({'state':'failed','failure':{'schema':1,'failed_phase':'activation','error_type':'RuntimeError','source_frames':[],'last_http':{},'tls_preparation':tls}}))
            script=directory/'project.ps1';script.write_text(r'''
param($Source,$Path,$Marker)
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'BackupFailureReport'},$true)
. ([ScriptBlock]::Create($node.Extent.Text))
$record=Get-Content $Path -Raw|ConvertFrom-Json
$first=BackupFailureReport $Path ([datetime]::MinValue)
if($first.tls_preparation.failure_class -cne 'certificate_chain' -or $first.tls_preparation.php_failure.stage -cne 'apply' -or ($first|ConvertTo-Json -Depth 15).Contains($Marker)){throw 'Closed valid report failed'}
foreach($operation in 'prepare_restored_tls','source_trusted_tls'){
 $record.failure.tls_preparation.operation=$operation
 [IO.File]::WriteAllText($Path,($record|ConvertTo-Json -Depth 15));$safe=BackupFailureReport $Path ([datetime]::MinValue)
 if($safe.tls_preparation.operation -cne $operation){throw 'Exact TLS operation lost'}
}
foreach($bad in $Marker,@('source_trusted_tls',$Marker),$true,$null){
 $record.failure.tls_preparation.operation=$bad
 [IO.File]::WriteAllText($Path,($record|ConvertTo-Json -Depth 15));$safe=BackupFailureReport $Path ([datetime]::MinValue)
 if($safe.ContainsKey('tls_preparation')){throw 'Unknown or mistyped TLS operation accepted'}
}
$record.failure.tls_preparation.operation='source_trusted_tls'
foreach($key in 'error_type','failure_class','native_code','returncode','hresult'){
 $old=$record.failure.tls_preparation.$key;$record.failure.tls_preparation.$key=@($old,$Marker)
 [IO.File]::WriteAllText($Path,($record|ConvertTo-Json -Depth 15));$safe=BackupFailureReport $Path ([datetime]::MinValue)
 if($safe.tls_preparation.ContainsKey($key) -or ($safe|ConvertTo-Json -Depth 15).Contains($Marker)){throw 'Bad typed report escaped'}
 $record.failure.tls_preparation.$key=$old
}
$record.failure.tls_preparation.source_frames=@(@{source_basename=$Marker;source_line=2},@{source_basename='Enable-PhoneTLS.ps1';source_line=$true})
$record.failure.tls_preparation.php_failure.stage=$Marker
[IO.File]::WriteAllText($Path,($record|ConvertTo-Json -Depth 15));$safe=BackupFailureReport $Path ([datetime]::MinValue)
if($safe.tls_preparation.source_frames.Count -or $safe.tls_preparation.ContainsKey('php_failure') -or ($safe|ConvertTo-Json -Depth 15).Contains($Marker)){throw 'Bad source metadata escaped'}
$record.failure.tls_preparation.schema=$true;[IO.File]::WriteAllText($Path,($record|ConvertTo-Json -Depth 15));$safe=BackupFailureReport $Path ([datetime]::MinValue)
if($safe.ContainsKey('tls_preparation')){throw 'Boolean schema accepted'}
'{"passed":true}'
''')
            result=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(script),str(ROOT/'tests/windows-suite.ps1'),str(path),MARKER],capture_output=True,timeout=30)
            self.assertEqual(result.returncode,0);self.assertTrue(json.loads(result.stdout)['passed'])

    def test_actual_writer_pipeline_order_environment_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary)
            delegate=directory/'owned-python.ps1'
            delegate.write_text(r'''
$name=[IO.Path]::GetFileName([string]$args[-1]);$global:calls+=,@{name=$name;arguments=@($args);powershell=$env:OPENWEB_TEST_PWSH}
Write-Output 'PRIVATE_PIPELINE_STDOUT';[Console]::Error.WriteLine('PRIVATE_PIPELINE_STDERR')
$global:LASTEXITCODE=if($name -ceq $global:failed){9}else{0}
''')
            script=directory/'pipeline.ps1'
            script.write_text(r'''
param($Source,$Owned)
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual wrapper must parse'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Statements[0].Extent.Text.StartsWith('$env:OPENWEB_TEST_PWSH=')},$true))
if($nodes.Count -ne 1){throw 'Unique actual native test environment block required'}
$body=$nodes[0].Extent.Text;$fixed="'C:\OpenWebPBX\backup-runtime\python.exe'"
if(([regex]::Matches($body,[regex]::Escape($fixed))).Count -ne 2){throw 'Exact two test invocations required'}
$body=$body.Replace($fixed,("'"+(Join-Path $Owned 'owned-python.ps1').Replace("'","''")+"'"))
$bodyPath=Join-Path $Owned 'actual-native-test-block.ps1';[IO.File]::WriteAllText($bodyPath,$body,[Text.UTF8Encoding]::new($false))
$priorProtocolPowerShell='ORIGINAL_PRIVATE_ENV';$env:OPENWEB_TEST_PWSH=$priorProtocolPowerShell
$private=$Owned;$env:SystemRoot=Join-Path $Owned 'owned-systemroot'
foreach($failed in 'none','windows_backup_control_protocol.py','windows_private_state.py'){
 $global:calls=@();$global:failed=$failed;$thrown=$false
 try{. $bodyPath}catch{$thrown=$true}
 if(($failed -ceq 'none') -eq $thrown -or $env:OPENWEB_TEST_PWSH -cne $priorProtocolPowerShell){throw 'Failure or environment restoration changed'}
 $expectedCount=if($failed -ceq 'windows_backup_control_protocol.py'){1}else{2}
 if($global:calls.Count -ne $expectedCount -or $global:calls[0].name -cne 'windows_backup_control_protocol.py'){throw 'Protocol must precede writer tests'}
 foreach($call in $global:calls){if($call.powershell -cne (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe')){throw 'Native PowerShell identity lost'}}
 if($expectedCount -eq 2){$call=$global:calls[1];if($call.name -cne 'windows_private_state.py' -or $call.arguments.Count -ne 3 -or $call.arguments[0] -cne '-I' -or $call.arguments[1] -cne '-B'){throw 'Exact isolated writer controls required'}}
}
'{"passed":true}'
''')
            result=subprocess.run([PWSH,'-NoProfile','-NonInteractive','-File',str(script),str(ROOT/'tests/windows-backups.ps1'),str(directory)],capture_output=True,timeout=30)
            self.assertEqual(result.returncode,0,'Actual wrapper control failed')
            self.assertTrue(json.loads(result.stdout)['passed'])


class PythonTransport(unittest.TestCase):
    @unittest.skipIf(os.name=='nt','This control uses an owned executable POSIX fake tool')
    def test_actual_subprocess_once_private_output_and_original_nonzero(self):
        source=ROOT/'tests/windows_backups_native.py';tree=ast.parse(source.read_text())
        nodes=[n for n in tree.body if isinstance(n,(ast.Import,ast.ImportFrom)) or isinstance(n,ast.FunctionDef) and n.name=='prepare_restored_tls']
        ns={'__file__':str(source),'b':types.SimpleNamespace(native_powershell_environment=lambda:dict(os.environ))}
        exec(compile(ast.Module(nodes,type_ignores=[]),str(source),'exec'),ns)
        for source in (False,True):
            with self.subTest(source=source),tempfile.TemporaryDirectory() as temporary:
                directory=Path(temporary);exe=directory/'System32/WindowsPowerShell/v1.0/powershell.exe';exe.parent.mkdir(parents=True)
                exe.write_text('#!/usr/bin/env python3\nimport sys,json,os\nfrom pathlib import Path\np=Path(sys.argv[sys.argv.index("-ReportPath")+1]);w=p.parent/"delegation.private.json";assert not w.exists();w.write_text(json.dumps(sys.argv));p.write_text(json.dumps({"schema":1,"operation":"source_trusted_tls" if "-SourceTls" in sys.argv else "prepare_restored_tls","state":"failed","error_type":"RuntimeException","failure_class":"certificate_chain","source_frames":[]}));print("'+MARKER+'");print("'+MARKER+'",file=sys.stderr);raise SystemExit(7)\n');exe.chmod(0o700)
                with patch.dict(os.environ,{'SystemRoot':str(directory)}):
                    with self.assertRaisesRegex(RuntimeError,'A native Windows qualification control failed'):ns['prepare_restored_tls'](THUMBPRINT,directory,source=source)
                self.assertEqual(ns['LAST_TLS_PREPARATION']['returncode'],7)
                self.assertEqual(ns['LAST_TLS_PREPARATION']['operation'],'source_trusted_tls' if source else 'prepare_restored_tls')
                args=json.loads((directory/'delegation.private.json').read_text())
                self.assertEqual(args[args.index('-CertificateThumbprint')+1],THUMBPRINT)
                self.assertEqual(args[args.index('-File')+1],str(ROOT/'tests/windows-backup-tls-observer.ps1'))
                self.assertEqual('-SourceTls' in args,source)
                self.assertEqual(Path(args[args.index('-ReportPath')+1]).name,'tls-source-failure.json' if source else 'tls-prepare-failure.json')
                self.assertIn(MARKER,(directory/('tls-source-private.err' if source else 'tls-prepare-private.err')).read_text())
                self.assertNotIn(MARKER,json.dumps(ns['LAST_TLS_PREPARATION']))


if __name__=='__main__':unittest.main()
