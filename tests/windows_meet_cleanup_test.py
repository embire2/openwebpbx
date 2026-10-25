"""Focused ended-card cleanup/report controls; native media is never synthesized as passed."""
import ast
import copy
import hashlib
import http.cookiejar
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
import urllib.request
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
PRIVATE='PRIVATE_SECRET_DO_NOT_RETAIN'
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,HERE/file);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
browser=load('cleanup_browser','windows-meet-browser.py')
restored=load('cleanup_restored','windows_restored_meeting.py')

def result(**changes):
    return {'exit_code':31,'report_state':'failed','cleanup_error_type':'Error','cleanup_source_basename':'windows-meet-browser.cjs','cleanup_source_line':210}|changes

def body(source,name):
    node=next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef) and n.name==name)
    return ast.get_source_segment(source,node)

class Cleanup(unittest.TestCase):
    def test_exact_prior_four_sources_reconstruct_and_strict_DB_and_success_body_remain(self):
        from windows_meet_wss_child_source import CLEANUP_CHANGES,pre_wss_child_source
        for name,(expected,changes) in CLEANUP_CHANGES.items():
            source=(HERE/name).read_text()
            for new,old in reversed(changes):
                self.assertEqual(source.count(new),1);source=source.replace(new,old,1)
            self.assertEqual(hashlib.sha256(source.encode()).hexdigest(),expected)
            self.assertTrue(pre_wss_child_source(name))
            if name=='windows_restored_meeting.py':
                for function in ('preserved_rows','qualify','closed_summary','recovery_inventory','stable_files'):
                    self.assertEqual(body(source,function),body((HERE/name).read_text(),function))
            if name=='windows-meet-browser.py':
                current=(HERE/name).read_text()
                self.assertEqual(source[source.index('        facts = json.loads(report.read_text())'):],current[current.index('        facts = json.loads(report.read_text())'):])
            if name=='windows-meet-browser.cjs':
                current=(HERE/name).read_text()
                self.assertEqual(source[:source.index('  finally{')],current[:current.index('  finally{')])
                self.assertEqual(source[source.index('    await Promise.allSettled'):],current[current.index('    await Promise.allSettled'):])
                start="try{await owner.goto(settings.origin+'/app/pbx_meet/');"
                self.assertEqual(source[source.index(start):source.index('catch(error){if(!failure)failure=error;}')],current[current.index(start):current.index('catch(error){if(!failure){')])

    def test_closed_five_scalars_reject_private_missing_malformed_and_bounds(self):
        self.assertEqual(browser.browser_result_fields(result()),restored.browser_result_fields(result()))
        bads=[None,[],{},True,PRIVATE,result(raw=PRIVATE),result(exit_code=0),result(exit_code=True),result(exit_code=-2147483649),result(exit_code=4294967296),result(report_state=PRIVATE),result(cleanup_error_type=PRIVATE),result(cleanup_source_basename=PRIVATE),result(cleanup_source_line=True),result(cleanup_source_line=0),result(cleanup_source_line=1000000),result(cleanup_source_basename='unavailable'),result(report_state='passed')]
        for field in result():
            bad=result();del bad[field];bads.append(bad)
        for value in bads:
            self.assertEqual(browser.browser_result_fields(value),{});self.assertEqual(restored.browser_result_fields(value),{})
        for state in ('missing','invalid','passed','failed'):
            value=result(report_state=state,cleanup_error_type=None,cleanup_source_basename=None,cleanup_source_line=None)
            self.assertEqual(browser.browser_result_fields(value),{'meeting_browser_result':value})
        for code in (-2147483648,-1,1,4294967295):
            self.assertTrue(browser.browser_result_fields(result(exit_code=code)))

    def test_failure_only_projection_preserves_primary_and_ignores_observer_failure(self):
        error=RuntimeError(PRIVATE);error.restored_meeting_active_case='native_windows_meeting_cleanup';error.meeting_browser_result={'meeting_browser_result':result()}
        self.assertEqual(restored.failure_record(error)['meeting_browser_result'],result())
        self.assertEqual(error.args,(PRIVATE,));self.assertNotIn(PRIVATE,json.dumps(restored.failure_record(error)))
        for case in ('unavailable','native_windows_meeting_dependencies','native_windows_meeting_unknown'):
            error.restored_meeting_active_case=case;self.assertNotIn('meeting_browser_result',restored.failure_record(error))
        error.restored_meeting_active_case='native_windows_meeting_cleanup'
        for kind in (RuntimeError,SystemExit,KeyboardInterrupt):
            with patch.object(restored,'browser_result_fields',side_effect=kind(PRIVATE)):
                self.assertNotIn('meeting_browser_result',restored.failure_record(error))
            self.assertEqual(error.args,(PRIVATE,))

    def test_actual_original_runner_nonzero_retains_exit_report_states_and_cleanup(self):
        cases=[(None,'missing','unknown'),('{','invalid','unknown'),('[]','invalid','unknown'),(json.dumps({'schema':1,'state':'passed'}),'passed','unknown'),(json.dumps({'schema':1,'state':'failed','phase':'cleanup','cleanup_failure':{'error_type':'TypeError','source_basename':'windows-meet-browser.cjs','source_line':211}}),'failed','cleanup'),(' '*65537,'invalid','unknown'),(json.dumps({'schema':1,'state':{},'phase':{}}),'invalid','unknown')]
        for raw,state,stage in cases:
            with self.subTest(state=state,stage=stage),tempfile.TemporaryDirectory(prefix='owned-meet-cleanup-') as td:
                root=Path(td);evidence=root/'evidence';evidence.mkdir();npm=root/'node_modules/npm/bin/npm-cli.js';npm.parent.mkdir(parents=True);npm.write_text('inert')
                jar=http.cookiejar.CookieJar();jar.set_cookie(http.cookiejar.Cookie(0,'fixture',PRIVATE,None,False,'windowsqa.example.invalid',False,False,'/',True,True,None,True,None,None,{},False))
                opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar));opener.addheaders=[('User-Agent','owned-qa-agent')]
                fixture=types.SimpleNamespace(evidence=evidence,source=HERE.parent,php=Path('C:/OpenWebPBX/php/php.exe'),script=HERE/'windows-native-fixture.php',path=root/'input.json',s={'scope':'a'*24,'public_url':'https://windowsqa.example.invalid:8443'},web=types.SimpleNamespace(open=opener));calls=[]
                def child(arguments,**kwargs):
                    calls.append(arguments);self.assertEqual(kwargs,dict(capture_output=True,text=True,timeout=240))
                    self.assertEqual(arguments[0],str(root/'node.exe'))
                    if len(calls)==1:return types.SimpleNamespace(returncode=0,stdout=PRIVATE,stderr=PRIVATE)
                    self.assertEqual(arguments[1:],[str(HERE/'windows-meet-browser.cjs'),str(evidence/'meeting-browser.private.json')])
                    if raw is not None:(evidence/'meeting-browser.safe.json').write_text(raw)
                    return types.SimpleNamespace(returncode=31,stdout=PRIVATE,stderr=PRIVATE)
                fake=types.SimpleNamespace(name='nt',environ={'OPENWEB_WINDOWS_NATIVE_TEST':'1','RUNNER_ENVIRONMENT':'github-hosted','GITHUB_REPOSITORY':'embire2/openwebpbx'})
                with patch.object(browser,'os',fake),patch.object(browser.shutil,'which',side_effect=lambda name:str(root/name)),patch.object(browser,'subprocess',types.SimpleNamespace(run=child)):
                    with self.assertRaises(RuntimeError) as caught:browser.run(fixture)
                error=caught.exception;self.assertEqual(len(calls),2);self.assertEqual(fixture.active_case,'native_windows_meeting_'+stage)
                self.assertFalse((evidence/'meeting-browser.private.json').exists())
                restored.observe_failure_case(error,fixture);record=restored.failure_record(error)
                value=record['meeting_browser_result'];self.assertEqual(value['exit_code'],31);self.assertEqual(value['report_state'],state)
                self.assertEqual(value['cleanup_error_type'],'TypeError' if stage=='cleanup' else None)
                self.assertNotIn(PRIVATE,json.dumps(record))

    def test_actual_PS_parent_closed_projection_on_both_versions(self):
        source=(HERE/'windows-restore-qualification.ps1').read_text();a=source.index('function SafeRestoredConferenceFailure(');b=source.index('function SafeRestoredConferencePathFields',a);function=source[a:b]
        script=function+'''
$base=@{schema=1;state='failed';producer='windows_restored_meeting.py';error_type='RuntimeError';cleanup_verified=$true;source_frames=@();active_case='native_windows_meeting_cleanup';owned_process_cleanup_failed=$null;owned_processes_closed=$null}
$r=@{exit_code=31;report_state='failed';cleanup_error_type='TypeError';cleanup_source_basename='windows-meet-browser.cjs';cleanup_source_line=211};$base.meeting_browser_result=$r
if($null-eq (SafeRestoredConferenceFailure $base)){throw 'valid cleanup refused'};$checks=1
foreach($field in @('exit_code','report_state','cleanup_error_type','cleanup_source_basename','cleanup_source_line')){$copy=@{};foreach($key in $r.Keys){$copy[$key]=$r[$key]};$copy[$field]='PRIVATE_SECRET_DO_NOT_RETAIN';$base.meeting_browser_result=$copy;if($null-ne (SafeRestoredConferenceFailure $base)){throw 'invalid accepted'};$checks++}
foreach($state in @('missing','invalid','passed','failed')){$base.active_case='native_windows_meeting_unknown';$base.meeting_browser_result=@{exit_code=-1;report_state=$state;cleanup_error_type=$null;cleanup_source_basename=$null;cleanup_source_line=$null};if($null-eq (SafeRestoredConferenceFailure $base)){throw 'state refused'};$checks++}
$base.active_case='native_windows_meeting_unknown';$base.meeting_browser_result=$r;if($null-ne (SafeRestoredConferenceFailure $base)){throw 'wrong stage accepted'};$checks++
$base.Remove('meeting_browser_result');if($null-eq (SafeRestoredConferenceFailure $base)){throw 'old nine-field refused'};$checks++
@{state='passed';checks=$checks}|ConvertTo-Json -Compress
'''
        for executable in ('/var/lib/openwebpbx/tools/powershell/runtime/pwsh','/var/lib/openwebpbx/windows113-core/powershell/pwsh'):
            run=subprocess.run([executable,'-NoProfile','-NonInteractive','-Command',script],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stderr);self.assertEqual(json.loads(run.stdout),{'state':'passed','checks':12})

if __name__=='__main__':unittest.main()
