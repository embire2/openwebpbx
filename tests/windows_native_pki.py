"""Owned PKI listeners and closed failure-only lock evidence; no OS trust changes."""
import ast
import copy
from contextlib import contextmanager
import hashlib
import http.client
import http.server
import importlib.util
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'tests/windows-native-acceptance.py'
spec=importlib.util.spec_from_file_location('actual_owned_native_pki',SOURCE)
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
lock_spec=importlib.util.spec_from_file_location('actual_backup_lock_observer',ROOT/'tests/windows-backup-lock-observer.py')
observer=importlib.util.module_from_spec(lock_spec);lock_spec.loader.exec_module(observer)


class PkiIsolation(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='owned-windows-pki-')
        self.processes=[]

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:process.terminate()
            try:process.communicate(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.communicate(timeout=5)
        self.temp.cleanup()

    def fixture(self):
        evidence=Path(self.temp.name)/uuid.uuid4().hex;evidence.mkdir()
        fixture=SimpleNamespace(evidence=evidence,s={'scope':uuid.uuid4().hex[:24]})
        native.prepare_pki(fixture)
        return fixture

    def start(self,fixture):
        code="import importlib.util,pathlib,sys,types;s=importlib.util.spec_from_file_location('actual_pki',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.serve_pki(types.SimpleNamespace(evidence=pathlib.Path(sys.argv[2])))"
        process=subprocess.Popen([sys.executable,'-I','-B','-c',code,str(SOURCE),str(fixture.evidence)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.processes.append(process)
        deadline=time.monotonic()+10
        while not (fixture.evidence/'pki-ready.json').exists() and process.poll() is None and time.monotonic()<deadline:time.sleep(.01)
        self.assertIsNone(process.poll(),'Owned PKI server must remain live')
        self.assertTrue((fixture.evidence/'pki-ready.json').exists(),'Owned PKI server must actually bind')
        return native.fixture_crl_endpoint(fixture)[1]

    @contextmanager
    def replace(self,path,data):
        before=path.read_bytes();path.write_bytes(data)
        try:yield
        finally:path.write_bytes(before)

    def test_two_live_issuers_get_distinct_exclusive_endpoints_and_matching_der(self):
        first=self.fixture();a=self.start(first)
        second=self.fixture();b=self.start(second)
        self.assertNotEqual(a.port,b.port)
        self.assertNotEqual(a.path,b.path)
        self.assertEqual(a.hostname,b.hostname,'Only exact loopback is used')
        for fixture,endpoint in [(first,a),(second,b)]:
            native.verify_pki_endpoint(fixture)
            self.assertTrue(json.loads((fixture.evidence/'pki-endpoint-proof.json').read_text())['issuer_and_der_verified'])
            with self.assertRaises(OSError):native.FixturePkiServer(('127.0.0.1',endpoint.port),http.server.BaseHTTPRequestHandler)
        connection=http.client.HTTPConnection('127.0.0.1',a.port,timeout=3)
        try:connection.request('GET',b.path);self.assertEqual(connection.getresponse().status,404)
        finally:connection.close()
        self.assertFalse(native.FixturePkiServer.allow_reuse_address)
        self.assertFalse(native.FixturePkiServer.allow_reuse_port)

    def test_wrong_issuer_with_matching_transport_digest_is_refused(self):
        first=self.fixture();self.start(first);other=self.fixture()
        path=first.evidence/'pki-private.json';pki=json.loads(path.read_text())
        wrong=(other.evidence/'fixture.crl').read_bytes();pki['crl_sha256']=hashlib.sha256(wrong).hexdigest()
        with self.replace(first.evidence/'fixture.crl',wrong),self.replace(path,json.dumps(pki).encode()):
            with self.assertRaisesRegex(AssertionError,'issuer differs'):native.verify_pki_endpoint(first)

    def test_wrong_leaf_and_wrong_crl_bytes_are_refused(self):
        first=self.fixture();self.start(first);other=self.fixture()
        with self.replace(first.evidence/'fixture-leaf.pem',(other.evidence/'fixture-leaf.pem').read_bytes()):
            with self.assertRaisesRegex(AssertionError,'issuer differs'):native.verify_pki_endpoint(first)
        with self.replace(first.evidence/'fixture.crl',(other.evidence/'fixture.crl').read_bytes()):
            with self.assertRaisesRegex(AssertionError,'bytes differ'):native.verify_pki_endpoint(first)

    def test_root_source_swap_and_old_fixed_url_are_refused(self):
        first=self.fixture();other=self.fixture()
        with self.replace(first.evidence/'fixture-root.cer',(other.evidence/'fixture-root.cer').read_bytes()):
            with self.assertRaises(AssertionError):native.fixture_crl_endpoint(first)
        path=first.evidence/'pki-private.json';pki=json.loads(path.read_text());pki['crl_url']='http://127.0.0.1:18985/fixture.crl'
        with self.replace(path,json.dumps(pki).encode()):
            with self.assertRaises(AssertionError):native.fixture_crl_endpoint(first)

    def test_nonloopback_credentials_query_fragment_and_wrong_source_paths_refuse_before_network(self):
        fixture=self.fixture();path=fixture.evidence/'pki-private.json';pki=json.loads(path.read_text())
        original=pki['crl_url']
        urls=[original.replace('127.0.0.1','0.0.0.0'),original.replace('127.0.0.1','localhost'),original.replace('127.0.0.1','192.0.2.1'),original.replace('http:','https:'),original.replace('127.0.0.1','user@127.0.0.1'),original+'?query=1',original+'#fragment',original.replace('/fixture-','/other-')]
        for url in urls:
            with self.subTest(shape=urls.index(url)):
                pki['crl_url']=url
                with self.replace(path,json.dumps(pki).encode()):
                    with self.assertRaises(AssertionError):native.fixture_crl_endpoint(fixture)

    def test_wildcard_ipv6_and_ephemeral_server_requests_are_refused(self):
        for address in [('0.0.0.0',18985),('::',18985),('127.0.0.1',0),('127.0.0.1',80)]:
            with self.subTest(address=address),self.assertRaises(AssertionError):
                native.FixturePkiServer(address,http.server.BaseHTTPRequestHandler)

    def test_native_exclusive_option_and_actual_prechain_callers_stay_wired(self):
        tree=ast.parse(SOURCE.read_text())
        server=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='FixturePkiServer')
        method=next(n for n in server.body if isinstance(n,ast.FunctionDef) and n.name=='server_bind')
        condition=next(n for n in method.body if isinstance(n,ast.If))
        self.assertEqual(ast.unparse(condition.test),"os.name == 'nt'")
        self.assertEqual(ast.unparse(condition.body[0]),'self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)')
        phone=(ROOT/'tests/windows-native-acceptance.ps1').read_text()
        self.assertLess(phone.index("Python 'verify-pki'"),phone.index("$rootCertificate=Import-Certificate"))
        recovery=(ROOT/'tests/windows-suite-pki.ps1').read_text()
        self.assertLess(recovery.index('--phase verify-pki'),recovery.index('$context.root=Import-Certificate'))
        product=(ROOT/'packaging/windows/Enable-PhoneTLS.ps1').read_text()
        self.assertIn('$chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::Online',product)
        self.assertIn("if(!$chain.Build($certificate)){throw 'Windows could not verify the phone certificate chain.'}",product)
        suite=(ROOT/'tests/windows-suite.ps1').read_text()
        self.assertIn("CheckedPython @((Join-Path $source 'tests/windows_native_pki.py'),'BackupDiagnosticRetention')",suite)
        invocation="& (Join-Path $PackageRoot 'backup-runtime/python.exe') -I -B (Join-Path $source 'tests/windows_native_pki.py') PkiIsolation"
        self.assertEqual(suite.count(invocation),1)
        self.assertLess(suite.index('$mapped=VerifyInventory $PackageRoot $release.files;'),suite.index(invocation))
        self.assertLess(suite.index(invocation),suite.index("$phase='native public-listener firewall qualification'"))


class BackupDiagnosticRetention(unittest.TestCase):
    def native(self):
        return dict(observed=True,health_observed=True,local_running=True,version_matches=True,
            iis_login_ready=True,known_recover_holder=False,holder_count=1,verified_holder_count=1,
            updater_state='Stopped',lock_metadata=dict(holder_kinds=['server'],holder_actions=['other'],
            install_journal_state='completed',worker_journal_state='checking'))

    def test_exact_closed_metadata_and_wrong_arrays_types_states_or_private_keys(self):
        good=self.native();self.assertEqual(observer.native_fields(good),good)
        self.assertEqual(observer.native_fields({k:v for k,v in good.items() if k!='lock_metadata'}),{k:v for k,v in good.items() if k!='lock_metadata'})
        for key,values in {'holder_kinds':['server',['server','server'],['PRIVATE'],[True]],
            'holder_actions':['recover',['recover','PRIVATE'],['recover','recover']],
            'install_journal_state':[True,[],['completed'],'PRIVATE'],
            'worker_journal_state':[True,[],['checking'],'PRIVATE']}.items():
            for value in values:
                bad=copy.deepcopy(good);bad['lock_metadata'][key]=value
                with self.subTest(key=key,valueType=type(value).__name__):self.assertIsNone(observer.native_fields(bad))
        bad=copy.deepcopy(good);bad['lock_metadata']['raw_command']='PRIVATE'
        self.assertIsNone(observer.native_fields(bad))

    def test_failure_only_probe_monotonic_timings_and_original_busy_are_preserved(self):
        class BackupError(RuntimeError):pass
        with tempfile.TemporaryDirectory(prefix='owned-lock-diagnostic-') as folder:
            state=Path(folder)/'OpenWebPBX';private=state/'backup-qualification';private.mkdir(parents=True)
            module=SimpleNamespace(BackupError=BackupError,UPGRADE_LOCK=state/'upgrade.lock',STORE=state/'backups',reparse=lambda p:False,native_powershell_environment=lambda:{'FIXTURE':'1'})
            original=BackupError(observer.BUSY);native_fields=self.native()
            result=SimpleNamespace(returncode=0,stdout=json.dumps(native_fields).encode(),stderr=b'PRIVATE_COMMAND')
            environment={'ProgramData':folder,'SystemRoot':folder,'GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted','GITHUB_REPOSITORY':'embire2/openwebpbx'}
            # Explicit portable boundary adapters; no hosted scope or Windows
            # product invocation is claimed by this in-memory mock.
            with patch.object(observer.os,'name','nt'),patch.dict(observer.os.environ,environment),patch.object(observer,'Path',type(state)),patch.object(observer,'probe_existing_lock',side_effect=[{'state':'busy','stream_closed':True},{'state':'available','stream_closed':True}]) as probe,patch.object(observer.subprocess,'run',return_value=result) as run,patch.object(observer.time,'monotonic',side_effect=[1,1.125,2,2.25]):
                record=observer.observe(module,private,original)
            self.assertEqual(probe.call_count,2)
            self.assertEqual(record['probe_timing'],{'clock':'monotonic','upgrade_probe_elapsed_ms':125,'worker_probe_elapsed_ms':250})
            self.assertEqual(record['observation'],'after_original_busy_error')
            self.assertEqual(record['native']['lock_metadata'],native_fields['lock_metadata'])
            self.assertEqual(run.call_count,1)
            self.assertEqual(run.call_args.kwargs['timeout'],25)
            self.assertEqual(str(original),observer.BUSY)
            self.assertNotIn('PRIVATE',json.dumps(record))
            self.assertIsNone(observer.observe(module,private,ValueError('unrelated')))

    def test_actual_outer_projector_keeps_closed_metadata_timings_and_refuses_wrong_shapes(self):
        powershell=os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('powershell.exe') or shutil.which('pwsh')
        if not powershell: self.skipTest('Set OPENWEB_TEST_PWSH for actual portable PowerShell projection')
        native_fields=self.native()
        good={'schema':1,'observation':'after_original_busy_error','upgrade':{'state':'busy','stream_closed':True},'worker':{'state':'available','stream_closed':True},'native':native_fields,'probe_timing':{'clock':'monotonic','upgrade_probe_elapsed_ms':125,'worker_probe_elapsed_ms':250}}
        cases=[dict(value=good,native=True,metadata=True,timing=True)]
        for key,value in [('holder_kinds',['server','PRIVATE']),('holder_kinds','server'),('holder_actions',['other','other']),('worker_journal_state',['checking']),('install_journal_state',True)]:
            bad=copy.deepcopy(good);bad['native']['lock_metadata'][key]=value;cases.append(dict(value=bad,native=False,metadata=False,timing=True))
        for key,value in [('clock',['monotonic']),('clock','PRIVATE'),('upgrade_probe_elapsed_ms',True),('upgrade_probe_elapsed_ms',-1),('worker_probe_elapsed_ms',30001),('worker_probe_elapsed_ms','250')]:
            bad=copy.deepcopy(good);bad['probe_timing'][key]=value;cases.append(dict(value=bad,native=True,metadata=True,timing=False))
        old=copy.deepcopy(good);del old['native']['lock_metadata'];del old['probe_timing'];cases.append(dict(value=old,native=True,metadata=False,timing=False))
        extra=copy.deepcopy(good);extra['native']['lock_metadata']['raw_command']='PRIVATE';extra['probe_timing']['raw_path']='PRIVATE';cases.append(dict(value=extra,native=True,metadata=True,timing=True))
        with tempfile.TemporaryDirectory(prefix='owned-lock-projector-') as folder:
            directory=Path(folder);(directory/'backup-qualification').mkdir()
            inputs=directory/'input.json';inputs.write_text(json.dumps(cases))
            script=directory/'project.ps1';script.write_text(LOCK_PROJECTION)
            result=subprocess.run([powershell,'-NoProfile','-NonInteractive','-File',str(script),'-Source',str(ROOT/'tests/windows-suite.ps1'),'-Inputs',str(inputs)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotIn('PRIVATE',result.stdout+result.stderr)
            self.assertEqual(json.loads(result.stdout)['cases'],len(cases))

    def test_actual_pki_native_runner_accepts_stderr_zero_refuses_nonzero_and_missing_and_restores_stop(self):
        powershell=os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('powershell.exe') or shutil.which('pwsh')
        if not powershell:self.skipTest('PowerShell is unavailable')
        suite=(ROOT/'tests/windows-suite.ps1').read_text()
        start=suite.index(' $pkiFixturePreference=$ErrorActionPreference;$pkiFixtureExit=$null')
        finish=suite.index(" if($ThreecxImportOnly){AssertThreecxImportAcceptedReplay",start)
        block=suite[start:finish]
        self.assertIn("$ErrorActionPreference='Continue';$global:LASTEXITCODE=$null",block)
        self.assertIn('$pkiFixtureExit=$global:LASTEXITCODE',block)
        with tempfile.TemporaryDirectory(prefix='owned-pki-native-exit-') as folder:
            directory=Path(folder);(directory/'tests').mkdir();work=directory/'work';work.mkdir()
            fixture=directory/'tests/windows_native_pki.py';script=directory/'run.ps1'
            prefix="param([string]$Source,[string]$NativePython,[string]$Mode)\n$ErrorActionPreference='Stop';$global:LASTEXITCODE=0;$source=$Source;$PackageRoot=$Source;$work=Join-Path $Source 'work';$caught=$false\n"
            # Only the executable path is adapted to this test-owned native
            # emitter. The current preference/reset/capture/refusal body is exact.
            adapted=block.replace("(Join-Path $PackageRoot 'backup-runtime/python.exe')",'$NativePython')
            self.assertNotEqual(adapted,block)
            script.write_text(prefix+'try{\n'+adapted+"\n}catch{$caught=$true};@{caught=$caught;stop_restored=($ErrorActionPreference -ceq 'Stop');exit_code=$pkiFixtureExit}|ConvertTo-Json -Compress\n")
            for label,exit_code,python in [('stderr_zero',0,sys.executable),('stderr_nonzero',7,sys.executable),('missing',0,str(directory/'absent-python.exe'))]:
                fixture.write_text('import sys;sys.stderr.write("OWNED_WARNING\\n");sys.exit('+str(exit_code)+')\n')
                result=subprocess.run([powershell,'-NoProfile','-NonInteractive','-File',str(script),'-Source',str(directory),'-NativePython',python,'-Mode',label],capture_output=True,text=True,timeout=30)
                self.assertEqual(result.returncode,0,result.stderr)
                answer=json.loads(result.stdout)
                self.assertTrue(answer['stop_restored'])
                self.assertEqual(answer['caught'],label!='stderr_zero')
                self.assertEqual(answer['exit_code'],None if label=='missing' else exit_code)


LOCK_PROJECTION=r'''
param([string]$Source,[string]$Inputs)
$ErrorActionPreference='Stop'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$t,[ref]$e)
if($e.Count){throw 'Actual source parse refused'}
$body=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'BackupFailureReport'},$true)
. ([scriptblock]::Create($body.Extent.Text))
$path=Join-Path $PSScriptRoot 'backup-qualification/report.json';$count=0
foreach($case in @(Get-Content -LiteralPath $Inputs -Raw|ConvertFrom-Json)){
 $raw=@{state='failed';failure=@{schema=1;failed_phase='native successful restore';error_type='BackupBusy';completed_checks=5;source_frames=@();lock_observation=$case.value}}
 [IO.File]::WriteAllText($path,($raw|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
 $safe=BackupFailureReport $path ([datetime]::MinValue)
 if($safe.report_status -cne 'read' -or $safe.error_type -cne 'BackupBusy' -or $safe.failed_phase -cne 'native successful restore'){throw 'Original failure fields changed'}
 $lock=$safe.lock_observation
 if($lock.ContainsKey('native') -cne $case.native){throw 'Native field shape was not closed'}
 if(($lock.ContainsKey('native') -and $lock.native.ContainsKey('lock_metadata')) -cne $case.metadata){throw 'Closed holder metadata mismatch'}
 if($lock.ContainsKey('probe_timing') -cne $case.timing){throw 'Monotonic probe timing mismatch'}
 if(($safe|ConvertTo-Json -Depth 15).Contains('PRIVATE')){throw 'Private marker escaped closed projection'}
 $count++
}
@{passed=$true;cases=$count}|ConvertTo-Json -Compress
'''


if __name__=='__main__':unittest.main()
