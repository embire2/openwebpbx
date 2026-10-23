"""Actual Backup-Control AST with fictional commands; no services/IIS/ACL writes.

The legacy noise is deliberately injected. It reproduces protocol robustness,
not the still-unobserved exact stdout/decode cause from diagnostic 38709511745.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'packaging/windows/Backup-Control.ps1'
MARKER='FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1'
spec=importlib.util.spec_from_file_location('protocol_backups',ROOT/'packaging/windows/backups.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)


class Protocol(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pwsh=os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh')
        if not cls.pwsh:raise RuntimeError('Pass OPENWEB_TEST_PWSH for actual PowerShell protocol controls.')
        cls.temporary=tempfile.TemporaryDirectory(prefix='openweb-control-protocol-');cls.work=Path(cls.temporary.name)
        cls.script=cls.work/'protocol.ps1';cls.script.write_text(HARNESS,encoding='utf-8')
        cls.request=cls.work/'request.json'
        cls.plan={'schema':1,'services':{'calls':'fictional'},'running':['OpenWebPBXUpdater','OpenWebPBX','FreeSWITCH'],
            'backup_enabled':True,'cleanup_enabled':True,'certificate_tasks':{},'additional_tasks':{},
            'site_running':True,'pool_running':True,'site_auto':False,'pool_auto':False}
        cls.plan['services']={'FreeSWITCH':'Manual','OpenWebPBX':'Manual','OpenWebPBXUpdater':'Auto'}
        cls.request.write_text(json.dumps(cls.plan),encoding='utf-8')
        # Actual immutable historical restore journal: no CDR hold existed.
        (cls.work/'journal.json').write_text(json.dumps({'schema':1,'state':'recovered'}),encoding='utf-8')
    @classmethod
    def tearDownClass(cls):cls.temporary.cleanup()
    def run_source(self,operation,*,legacy=False,noise=False,failure=False):
        trace=self.work/'trace.json';trace.unlink(missing_ok=True)
        command=[self.pwsh,'-NoProfile','-NonInteractive','-File',str(self.script),'-Product',str(SOURCE),'-Operation',operation,
            '-Request',str(self.request),'-Trace',str(trace)]
        for enabled,flag in ((legacy,'-Legacy'),(noise,'-Noise'),(failure,'-Failure')):
            if enabled:command.append(flag)
        result=subprocess.run(command,capture_output=True,timeout=30,
            env=b.native_powershell_environment() if os.name=='nt' else None)
        self.assertTrue(trace.is_file(),'The owned actual-source control did not produce its private trace')
        return result,json.loads(trace.read_text(encoding='utf-8-sig'))
    def test_resume_factory_actual_source_old_noise_refused_new_json_and_calls_identical(self):
        quiet,quiet_trace=self.run_source('resume-factory',legacy=True)
        before,old_trace=self.run_source('resume-factory',legacy=True,noise=True)
        after,new_trace=self.run_source('resume-factory',noise=True)
        self.assertEqual((quiet.returncode,before.returncode,after.returncode),(0,0,0))
        self.assertEqual(json.loads(quiet.stdout),{})
        with self.assertRaises((json.JSONDecodeError,UnicodeDecodeError)):json.loads(before.stdout)
        self.assertEqual(json.loads(after.stdout),{});self.assertEqual(old_trace,new_trace);self.assertEqual(quiet_trace,new_trace)
        self.assertIn('Start-Service',[call['name'] for call in new_trace['calls']])
        self.assertEqual(set(new_trace['state']['services'].values()),{'Running'})
        self.assertEqual((new_trace['state']['site'],new_trace['state']['pool']),('Started','Started'))
        self.assertNotIn(MARKER.encode(),after.stdout);self.assertNotIn(MARKER.encode(),after.stderr)
        self.assertEqual(after.stderr,b'')
        # Feed the real captured streams through the unchanged strict decoder.
        private=self.work/'private';(private/'backup-control').mkdir(parents=True,exist_ok=True)
        with patch.object(b,'STATE',private),patch.object(b,'run',return_value=before.stdout):
            with self.assertRaises(b.BackupError):b.control('resume-factory',self.plan)
        with patch.object(b,'STATE',private),patch.object(b,'run',return_value=after.stdout):
            self.assertEqual(b.control('resume-factory',self.plan),{})
    def test_plan_actual_result_is_preserved_in_current_scope(self):
        quiet,original=self.run_source('plan',legacy=True)
        before,old_trace=self.run_source('plan',legacy=True,noise=True)
        after,new_trace=self.run_source('plan',noise=True)
        expected=json.loads(quiet.stdout)
        self.assertEqual(after.returncode,0);self.assertEqual(json.loads(after.stdout),expected)
        self.assertEqual(expected['schema'],1);self.assertIsInstance(expected['services'],dict)
        self.assertEqual(expected['services'],{'FreeSWITCH':'Manual','OpenWebPBX':'Manual','OpenWebPBXUpdater':'Auto'})
        # Plan enumerates a hashtable; its read-only service query order is unspecified.
        self.assertEqual(original['state'],old_trace['state']);self.assertEqual(old_trace['state'],new_trace['state'])
        self.assertCountEqual(original['calls'],old_trace['calls']);self.assertCountEqual(old_trace['calls'],new_trace['calls'])
        with self.assertRaises(json.JSONDecodeError):json.loads(before.stdout)
        self.assertEqual(after.stderr,b'')
    def test_start_web_and_startup_side_effects_arguments_unchanged(self):
        for operation in ('start-web','recover-startup'):
            before,old_trace=self.run_source(operation,legacy=True,noise=True)
            after,new_trace=self.run_source(operation,noise=True)
            self.assertEqual((before.returncode,after.returncode),(0,0))
            if operation=='recover-startup':
                # Startup enumerates the same hashtable to set independent service modes.
                self.assertEqual(old_trace['state'],new_trace['state']);self.assertCountEqual(old_trace['calls'],new_trace['calls'])
                self.assertEqual({call['arguments']['Name']:call['arguments']['StartupType'] for call in new_trace['calls'] if call['name']=='Set-Service'},
                    {'FreeSWITCH':'Manual','OpenWebPBX':'Manual','OpenWebPBXUpdater':'Automatic'})
            else:self.assertEqual(old_trace,new_trace)
            self.assertEqual(json.loads(after.stdout),{})
            with self.assertRaises(json.JSONDecodeError):json.loads(before.stdout)
            self.assertNotIn(MARKER.encode(),after.stdout);self.assertEqual(after.stderr,b'')
    def test_failure_exit_and_generic_stderr_are_unchanged(self):
        before,old_trace=self.run_source('resume-factory',legacy=True,noise=True,failure=True)
        after,new_trace=self.run_source('resume-factory',noise=True,failure=True)
        self.assertEqual((before.returncode,after.returncode),(1,1));self.assertEqual(old_trace,new_trace)
        self.assertEqual(before.stdout,after.stdout);self.assertEqual(after.stdout,b'')
        self.assertEqual(before.stderr,after.stderr)
        self.assertEqual(after.stderr.decode().strip(),'The Windows backup control operation failed. Review its owned services, storage and permissions.')
        self.assertEqual(set(new_trace['state']['services'].values()),{'Stopped'})


HARNESS=r'''
param([string]$Product,[ValidateSet('resume-factory','plan','start-web','recover-startup')][string]$Operation,[string]$Request,[string]$Trace,[switch]$Legacy,[switch]$Noise,[switch]$Failure)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Product,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual backup-control source did not parse'}
$functions=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})
$body=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
if($body.Count -ne 1){throw 'Expected exactly one product operation entry'}
foreach($definition in $functions){. ([scriptblock]::Create($definition.Extent.Text))}
$code=$body[0].Extent.Text
if($Legacy){
 $open=' $null = . {'+"`n";$close=' } 3>$null 4>$null 5>$null 6>$null'+"`n"
 if(!$code.Contains($open) -or !$code.Contains($close)){throw 'The exact protocol-only legacy projection is unavailable'}
 $code=$code.Replace($open,'').Replace($close,'')
}
# Only path bindings and fictional external commands differ from the product.
$root=Split-Path -Parent $Request;$private=$root;$control=$root;$restore=$root;$backupEngineRoot=$root
foreach($name in 'services','certificateTasks','additionalTasks'){
 $assignment=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq ('$'+$name)})
 if($assignment.Count -ne 1){throw 'A product constant binding is missing'}
 . ([scriptblock]::Create($assignment[0].Extent.Text))
}
$script:calls=[Collections.Generic.List[object]]::new()
$script:state=@{services=@{FreeSWITCH='Stopped';OpenWebPBX='Stopped';OpenWebPBXUpdater='Stopped'};modes=@{FreeSWITCH='Manual';OpenWebPBX='Manual';OpenWebPBXUpdater='Auto'};tasks=@{'OpenWebPBX-Backups'=$true;'OpenWebPBX-Cleanup'=$true};site='Stopped';pool='Stopped';site_auto=$false;pool_auto=$false}
function OrdinaryPath {param([string]$Path,[switch]$ControlOnly);if([IO.Path]::GetFullPath($Path) -cnotin @([IO.Path]::GetFullPath($Request),[IO.Path]::GetFullPath((Join-Path $restore 'journal.json')))){throw 'Fictional control path refused'};return $Path}
function Record([string]$Name,$Arguments){$script:calls.Add(@{name=$Name;arguments=$Arguments})}
function Emit {
 if(!$Noise){return}
 $VerbosePreference='Continue';$DebugPreference='Continue';$InformationPreference='Continue'
 Write-Output ([pscustomobject]@{fictional='FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1'})
 Write-Warning 'FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1'
 Write-Verbose 'FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1';Write-Debug 'FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1'
 Write-Information 'FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1';Write-Host 'FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1'
 Write-Progress -Activity 'FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1' -Status 'fictional' -PercentComplete 50
}
function Import-Module {param([string]$Name);if($Name -cne 'WebAdministration'){throw 'Unexpected fictional module'};Record 'Import-Module' @{Name=$Name};if($Noise){Write-Warning 'FICTIONAL_NATIVE_PIPELINE_MARKER_3cc1'}}
function Get-Service {[CmdletBinding()]param([string]$Name);Record 'Get-Service' @{Name=$Name};if(!$script:state.services.ContainsKey($Name)){throw 'Unexpected fictional service'};return [pscustomobject]@{Status=$script:state.services[$Name]}}
function Start-Service {param([string]$Name);Record 'Start-Service' @{Name=$Name};if($Failure){throw 'Fictional service failure'};$script:state.services[$Name]='Running';Emit}
function Set-Service {param([string]$Name,[string]$StartupType);Record 'Set-Service' @{Name=$Name;StartupType=$StartupType};$script:state.modes[$Name]=$StartupType;Emit}
function Get-CimInstance {param([string]$ClassName,[string]$Filter);Record 'Get-CimInstance' @{ClassName=$ClassName;Filter=$Filter};if($ClassName -cne 'Win32_Service' -or $Filter -notmatch "^Name='(FreeSWITCH|OpenWebPBX|OpenWebPBXUpdater)'$"){throw 'Unexpected fictional CIM scope'};return [pscustomobject]@{StartMode=$script:state.modes[$Matches[1]]}}
function Get-ScheduledTask {[CmdletBinding()]param([string]$TaskName);Record 'Get-ScheduledTask' @{TaskName=$TaskName};if($script:state.tasks.ContainsKey($TaskName)){return [pscustomobject]@{Settings=[pscustomobject]@{Enabled=$script:state.tasks[$TaskName]}}}}
function Enable-ScheduledTask {param([string]$TaskName);Record 'Enable-ScheduledTask' @{TaskName=$TaskName};$script:state.tasks[$TaskName]=$true;Emit}
function Disable-ScheduledTask {param([string]$TaskName);Record 'Disable-ScheduledTask' @{TaskName=$TaskName};$script:state.tasks[$TaskName]=$false;Emit}
function Get-Website {param([string]$Name);Record 'Get-Website' @{Name=$Name};if($Name -cne 'OpenWebPBX'){throw 'Unexpected fictional site'};return [pscustomobject]@{State=$script:state.site}}
function Get-WebAppPoolState {param([string]$Name);Record 'Get-WebAppPoolState' @{Name=$Name};if($Name -cne 'OpenWebPBX'){throw 'Unexpected fictional pool'};return [pscustomobject]@{Value=$script:state.pool}}
function Start-WebAppPool {param([string]$Name);Record 'Start-WebAppPool' @{Name=$Name};$script:state.pool='Started';Emit}
function Start-Website {param([string]$Name);Record 'Start-Website' @{Name=$Name};$script:state.site='Started';Emit}
function Stop-WebAppPool {param([string]$Name);Record 'Stop-WebAppPool' @{Name=$Name};$script:state.pool='Stopped';Emit}
function Stop-Website {param([string]$Name);Record 'Stop-Website' @{Name=$Name};$script:state.site='Stopped';Emit}
function Get-ItemProperty {param([string]$Path,[string]$Name);Record 'Get-ItemProperty' @{Path=$Path;Name=$Name};return [pscustomobject]@{serverAutoStart=$script:state.site_auto;autoStart=$script:state.pool_auto}}
function Set-ItemProperty {param([string]$Path,[string]$Name,$Value);Record 'Set-ItemProperty' @{Path=$Path;Name=$Name;Value=$Value};if($Name -ceq 'serverAutoStart'){$script:state.site_auto=$Value}elseif($Name -ceq 'autoStart'){$script:state.pool_auto=$Value}else{throw 'Unexpected fictional property'};Emit}
try{. ([scriptblock]::Create($code))}
finally{[IO.File]::WriteAllText($Trace,(@{calls=@($script:calls.ToArray());state=$script:state}|ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))}
'''


if __name__=='__main__':unittest.main()
