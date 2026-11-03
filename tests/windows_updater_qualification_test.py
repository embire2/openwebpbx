#!/usr/bin/env python3
"""Offline signature/provenance refusal and real loopback TLS transport checks.

This is not Windows service/updater acceptance. Keys, archives and identities
below are synthetic and ephemeral. No installed machine state is accessed.
"""
import base64
import ast
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import types
import unittest

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

SPEC = importlib.util.spec_from_file_location('updater_fixture', Path(__file__).with_name('windows-updater-fixture.py'))
fixture = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(fixture)
DIAGNOSTIC_SPEC = importlib.util.spec_from_file_location('signature_diagnostic', Path(__file__).with_name('windows-private-signature-diagnostic.py'))
signature_diagnostic = importlib.util.module_from_spec(DIAGNOSTIC_SPEC); DIAGNOSTIC_SPEC.loader.exec_module(signature_diagnostic)


class PacketChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.public = self.root / 'public.pem'
        self.public.write_bytes(self.key.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
        self.now = datetime.now(timezone.utc)
        self.archives = {}
        for mode in ('fault', 'normal'):
            path = self.root / (mode + '.zip'); path.write_bytes((mode + ' synthetic complete archive').encode()); self.archives[mode] = path
        self.facts = {'schema': 1, 'run_id': '123', 'source_commit': 'a' * 40, 'state': 'partial',
                      'gates': {gate: 'passed' for gate in fixture.ESSENTIAL_GATES}}
        self.provenance = {'source_commit': 'a' * 40, 'base_archive_sha256': 'b' * 64}
        self.packet = {'schema': 1, 'repository': 'embire2/openwebpbx', 'base_suite_run_id': '123', 'canary_run_id': '124',
                       'base_source_commit': 'a' * 40, 'base_archive_sha256': 'b' * 64}
        for mode, sequence in (('fault', 114), ('normal', 115)):
            payload = {'schema': 1, 'product': 'openwebpbx', 'channel': 'stable', 'version': '1.0.14', 'sequence': sequence,
                       'published_at': (self.now - timedelta(minutes=2)).isoformat(),
                       'expires_at': (self.now + timedelta(days=1)).isoformat(),
                       'assets': [{'platform': 'windows-x64', 'name': 'openwebpbx-1.0.14-windows-x64.zip',
                           'url': 'https://github.com' + fixture.ASSET_PATH, 'minimum_version': '1.0.13',
                           'bytes': self.archives[mode].stat().st_size, 'sha256': fixture.digest(self.archives[mode])}]}
            self.packet[mode] = {'archive_sha256': payload['assets'][0]['sha256'], 'envelope': self.sign(payload)}

    def sign(self, payload):
        raw = json.dumps(payload, separators=(',', ':')).encode()
        return {'key_id': 'release-2026-a', 'payload': base64.b64encode(raw).decode(),
                'signature': base64.b64encode(self.key.sign(raw, padding.PKCS1v15(), hashes.SHA256())).decode()}

    def edit(self, mode, change):
        payload = json.loads(base64.b64decode(self.packet[mode]['envelope']['payload']))
        change(payload); self.packet[mode]['envelope'] = self.sign(payload)

    def verify(self):
        return fixture.verify_packets(self.packet, self.facts, self.provenance, self.archives, self.public, now=self.now)

    def test_real_signature_and_complete_distinct_archives(self):
        checked = self.verify()
        self.assertEqual([checked[mode]['sequence'] for mode in ('fault', 'normal')], [114, 115])
        self.assertNotEqual(checked['fault']['sha256'], checked['normal']['sha256'])

    def test_explicit_20_to_21_retains_signatures_and_exact_asset_boundary(self):
        modern=('web_readiness','tenant_domains','meeting_transport','meeting_browser',
                'phone_health','stun','native_clock','native_providers','native_call_me_back')
        self.facts['gates'].update({gate:'passed' for gate in modern})
        self.provenance.update(base_version='1.0.20', target_version='1.0.21')
        for mode in ('fault','normal'):
            def newer(payload):
                payload['version']='1.0.21'
                payload['assets'][0].update(name='openwebpbx-1.0.21-windows-x64.zip',
                    url='https://github.com/embire2/openwebpbx/releases/download/v1.0.21/openwebpbx-1.0.21-windows-x64.zip',
                    minimum_version='1.0.20')
            self.edit(mode,newer)
        checked=fixture.verify_packets(self.packet,self.facts,self.provenance,self.archives,self.public,
            now=self.now,base_version='1.0.20',target_version='1.0.21')
        self.assertEqual(len(checked),2)
        # Exercise the actual cryptographic packet verifier. No truthy, partial,
        # omitted or differently cased status may qualify any current gate.
        for gate in modern:
            for bad in (None, True, False, 0, 1, [], {}, 'Passed', 'passed ', 'partial', 'running', 'unqualified'):
                with self.subTest(gate=gate,status=bad):
                    self.facts['gates'][gate]=bad
                    with self.assertRaisesRegex(ValueError,'tenant addresses'):
                        fixture.verify_packets(self.packet,self.facts,self.provenance,self.archives,self.public,
                            now=self.now,base_version='1.0.20',target_version='1.0.21')
            del self.facts['gates'][gate]
            with self.subTest(gate=gate,status='missing'), self.assertRaises(ValueError):
                fixture.verify_packets(self.packet,self.facts,self.provenance,self.archives,self.public,
                    now=self.now,base_version='1.0.20',target_version='1.0.21')
            self.facts['gates'][gate]='passed'
        self.assertEqual(len(fixture.verify_packets(self.packet,self.facts,self.provenance,self.archives,self.public,
            now=self.now,base_version='1.0.20',target_version='1.0.21')),2)
        with self.assertRaises(ValueError):
            self.verify()
        self.provenance['target_version']='1.0.22'
        with self.assertRaises(ValueError):
            fixture.verify_packets(self.packet,self.facts,self.provenance,self.archives,self.public,
                now=self.now,base_version='1.0.20',target_version='1.0.21')

    def test_tampered_signature_is_rejected(self):
        self.packet['normal']['envelope']['signature'] = self.packet['fault']['envelope']['signature']
        with self.assertRaises(Exception): self.verify()

    def test_archive_tampering_is_rejected(self):
        self.archives['normal'].write_bytes(b'tampered same process data')
        with self.assertRaises(ValueError): self.verify()

    def test_equal_or_lower_sequence_is_rejected(self):
        for sequence in (114, 113):
            with self.subTest(sequence=sequence):
                self.edit('normal', lambda p: p.update(sequence=sequence))
                with self.assertRaises(ValueError): self.verify()

    def test_arbitrary_local_https_asset_url_is_rejected(self):
        self.edit('normal', lambda p: p['assets'][0].update(url='https://localhost/fixture.zip'))
        with self.assertRaises(ValueError): self.verify()

    def test_expired_signed_metadata_is_rejected(self):
        self.edit('normal', lambda p: p.update(expires_at=(self.now - timedelta(seconds=1)).isoformat()))
        with self.assertRaises(ValueError): self.verify()

    def test_missing_actual_baseline_gate_is_rejected(self):
        self.facts['gates']['native_sip_audio'] = 'unqualified'
        with self.assertRaises(ValueError): self.verify()

    def test_root_review_source_mismatch_is_rejected(self):
        self.provenance['source_commit'] = 'c' * 40
        with self.assertRaises(ValueError): self.verify()

    def test_metadata_only_wrong_target_is_rejected(self):
        self.edit('normal', lambda p: p.update(version='1.0.13'))
        with self.assertRaises(ValueError): self.verify()

    def test_platform_mix_is_rejected(self):
        self.edit('normal', lambda p: p['assets'].append(copy.deepcopy(p['assets'][0])))
        with self.assertRaises(ValueError): self.verify()

    def test_duplicate_private_packet_fields_are_rejected(self):
        path = self.root / 'duplicate.json'; path.write_text('{"schema":1,"schema":2}')
        with self.assertRaises(ValueError): fixture.read_json(path)


class TransportChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.settings = {'scope': 'a' * 24, 'archives': {}, 'packets': {}}
        for mode in ('fault', 'normal'):
            path = self.work / (mode + '.archive'); path.write_bytes((mode.encode() + b' actual TLS body') * 400)
            self.settings['archives'][mode] = str(path)
            self.settings['packets'][mode] = {'envelope': {'synthetic': mode}}
        fixture.prepare_pki(self.settings, self.work)
        fixture.write_json(self.work / 'mode.json', {'mode': 'fault'})
        self.server = fixture.make_server(self.settings, self.work, port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(5)

    def get(self, path, *, host='github.com', agent='OpenWebPBX-Updater/1', range_value=None):
        # A real TLS handshake verifies the independent CA and github.com SAN.
        context = ssl.create_default_context(cafile=str(self.work / 'transport-root.pem'))
        raw = socket.create_connection(('127.0.0.1', self.server.server_port), timeout=5)
        with context.wrap_socket(raw, server_hostname='github.com') as connection:
            headers = f'GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: {agent}\r\nConnection: close\r\n'
            if range_value: headers += 'Range: ' + range_value + '\r\n'
            connection.sendall((headers + '\r\n').encode())
            response = http.client.HTTPResponse(connection); response.begin(); body = response.read()
            return response.status, body

    def test_full_tls_archive_transfer_hash_and_origin_record(self):
        status, body = self.get(fixture.ASSET_PATH)
        self.assertEqual(status, 200)
        self.assertEqual(body, Path(self.settings['archives']['fault']).read_bytes())
        record = fixture.read_json(self.work / 'transport-requests.json')['requests'][0]
        self.assertEqual(record['sha256'], hashlib.sha256(body).hexdigest())
        self.assertTrue(record['complete'] and record['original_url'] and record['loopback'])

    def test_fresh_cache_resume_request_is_rejected(self):
        self.assertEqual(self.get(fixture.ASSET_PATH, range_value='bytes=10-')[0], 400)
        self.assertFalse((self.work / 'transport-requests.json').exists())

    def test_unknown_host_path_and_nonworker_request_are_rejected(self):
        self.assertEqual(self.get(fixture.ASSET_PATH, host='localhost')[0], 403)
        self.assertEqual(self.get('/wrong/path')[0], 403)
        self.assertEqual(self.get(fixture.ASSET_PATH, agent='test-client')[0], 400)

    def test_mode_switch_serves_only_selected_signed_bytes(self):
        fixture.write_json(self.work / 'mode.json', {'mode': 'normal'})
        status, body = self.get(fixture.FEED_PATH)
        self.assertEqual(status, 200); self.assertEqual(json.loads(body), {'synthetic': 'normal'})

    def test_default_hostname_validation_rejects_wrong_name(self):
        context = ssl.create_default_context(cafile=str(self.work / 'transport-root.pem'))
        raw = socket.create_connection(('127.0.0.1', self.server.server_port), timeout=5)
        with self.assertRaises(ssl.SSLCertVerificationError):
            context.wrap_socket(raw, server_hostname='wrong.example.invalid')
        raw.close()


class SignatureFailureChecks(unittest.TestCase):
    def test_actual_pair_call_normalizes_json_paths_and_rejects_malformed_values(self):
        tree = ast.parse(Path(fixture.__file__).read_text())
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Attribute) and node.func.attr == 'verify_pair']
        self.assertEqual(len(calls), 1)
        expression = compile(ast.Expression(calls[0]), str(Path(fixture.__file__)), 'eval')
        observed = []
        pair = types.SimpleNamespace(verify_pair=lambda *args: observed.append(args))
        facts, provenance = {}, {}
        for normal, fault in [('normal.zip', 'fault.zip'), (Path('normal.zip'), Path('fault.zip')),
                              ('normal.zip', Path('fault.zip'))]:
            observed.clear()
            eval(expression, {'Path': Path, 'pair': pair, 'archives': {'normal': normal, 'fault': fault},
                              'target_facts': facts, 'provenance': provenance})
            self.assertEqual(observed, [(Path('normal.zip'), Path('fault.zip'), facts, provenance)])
        for mode in ('normal', 'fault'):
            for value in (None, 1, [], {}):
                observed.clear()
                with self.assertRaises(TypeError):
                    eval(expression, {'Path': Path, 'pair': pair,
                                      'archives': {'normal': 'normal.zip', 'fault': 'fault.zip'} | {mode: value},
                                      'target_facts': facts, 'provenance': provenance})
                self.assertEqual(observed, [])

    def test_closed_exception_classification_never_exports_values(self):
        class PrivateException(Exception):
            pass
        cases = [(RuntimeError('PRIVATE_TOKEN_PATH'), 'RuntimeError', 'unknown'),
                 (ModuleNotFoundError('PRIVATE_TOKEN_PATH'), 'ModuleNotFoundError', 'dependency_import'),
                 (FileNotFoundError('PRIVATE_TOKEN_PATH'), 'FileNotFoundError', 'input_io'),
                 (AttributeError('PRIVATE_TOKEN_PATH'), 'AttributeError', 'python_shape'),
                 (ValueError('The private signed feed is not current.'), 'ValueError', 'feed_time'),
                 (PrivateException('PRIVATE_TOKEN_PATH'), 'OtherError', 'unknown')]
        for error, kind, reason in cases:
            with self.subTest(kind=kind):
                result = signature_diagnostic.signature_failure(error)
                self.assertEqual(set(result), {'schema', 'producer', 'state', 'exception_type', 'reason', 'source_basename', 'source_line'})
                self.assertEqual((result['exception_type'], result['reason']), (kind, reason))
                self.assertEqual((result['source_basename'], result['source_line']), ('external_component', 0))
                self.assertNotIn('PRIVATE_TOKEN_PATH', json.dumps(result))
        try:
            exec(compile("raise RuntimeError('PRIVATE_TOKEN_PATH')", '/PRIVATE_TOKEN_PATH/windows-updater-fixture.py', 'exec'))
        except RuntimeError as error:
            result = signature_diagnostic.signature_failure(error)
        self.assertEqual((result['source_basename'], result['source_line']), ('windows-updater-fixture.py', 1))
        self.assertNotIn('PRIVATE_TOKEN_PATH', json.dumps(result))

    def test_actual_cli_refuses_guard_with_closed_validate_only_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'input.json'
            path.write_text(json.dumps({'schema': 1, 'password': 'PRIVATE_TOKEN_PATH'}))
            for action in ('validate', 'setup'):
                result = subprocess.run([sys.executable, '-I', '-B', str(Path(signature_diagnostic.__file__)), '--input', str(path), '--action', action],
                                        capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 1)
                if action == 'validate':
                    record = json.loads(result.stdout)
                    self.assertIn(record['reason'], ('runner_guard', 'input_guard'))
                    self.assertEqual(record['exception_type'], 'RuntimeError')
                    self.assertEqual(record['source_basename'], 'windows-updater-fixture.py')
                    self.assertNotIn(b'PRIVATE_TOKEN_PATH', result.stdout)
                    self.assertLess(len(result.stdout), 4096)
                else:
                    record = json.loads(result.stdout)
                    self.assertEqual(record['exception_type'], 'ValueError')
                    self.assertEqual(record['reason'], 'unknown')

    def test_actual_powershell_caller_retains_only_closed_record_and_primary_failure(self):
        pwsh = Path('/var/lib/openwebpbx/tools/powershell/runtime/pwsh')
        if not pwsh.exists():
            self.skipTest('Private local PowerShell parser/runtime is unavailable.')
        valid = signature_diagnostic.signature_failure(ModuleNotFoundError('PRIVATE_TOKEN_PATH'))
        rows = [{'wire': json.dumps(valid), 'accepted': True},
                {'wire': json.dumps(signature_diagnostic.signature_failure(AttributeError('PRIVATE_TOKEN_PATH'))), 'accepted': True}]
        for field, value in [('schema', True), ('producer', ['windows-private-signature-validation']),
                             ('state', ['failed']), ('exception_type', ['ModuleNotFoundError']),
                             ('reason', ['dependency_import']), ('source_basename', 'PRIVATE_TOKEN_PATH'),
                             ('source_line', True), ('source_line', -1), ('source_line', 100001),
                             ('source_line', '1'), ('source_line', 1), ('reason', 'PRIVATE_TOKEN_PATH')]:
            record = valid | {field: value}
            rows.append({'wire': json.dumps(record), 'accepted': False})
        rows += [{'wire': json.dumps(valid | {'private': 'PRIVATE_TOKEN_PATH'}), 'accepted': False},
                 {'wire': '{', 'accepted': False}, {'wire': 'X' * 4097, 'accepted': False}]
        script = r'''
param([string]$Source,[string]$Work,[string]$Cases)
$ErrorActionPreference='Stop';$work=$Work;$package=$Work;$inputFile=$Cases
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual signed caller source parse refused'}
$reader=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq 'ReadQualificationSignatureFailure'},$true));if($reader.Count-ne 1){throw 'Unique closed reader required'}
. ([scriptblock]::Create($reader[0].Extent.Text))
$wrapper=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.TryStatementAst]-and $n.Body.Statements.Count-eq 1-and $n.Body.Extent.Text.Contains("'verify-private-signatures'")-and @($n.Body.FindAll({param($c)$c-is [Management.Automation.Language.CommandAst]-and $c.GetCommandName()-ceq 'CheckedProcess'},$true)).Count-eq 1},$true))
if($wrapper.Count-ne 1){throw 'Unique unchanged-call wrapper required'}
$caller=Join-Path $work 'signature-callsite.ps1';[IO.File]::WriteAllText($caller,$wrapper[0].Extent.Text)
function CheckedProcess($Executable,$Arguments,$Label){
 $script:qualificationFailedChild=@{label=$Label;completion='exit';exit_code=7}
 [IO.File]::WriteAllText((Join-Path $work ($Label+'.out')),$script:wire)
 throw [InvalidOperationException]::new('ORIGINAL_PRIVATE_CHILD_FAILURE')
}
$rows=Get-Content -LiteralPath $Cases -Raw|ConvertFrom-Json;$count=0
foreach($case in $rows){
 $facts=@{};$script:wire=$case.wire;$caught=$null
 try{. $caller}catch{$caught=$_}
 if(!$caught-or $caught.Exception.Message-cne 'ORIGINAL_PRIVATE_CHILD_FAILURE'){throw 'Original primary failure changed'}
 if($facts.ContainsKey('signature_validation')-ne $case.accepted){throw 'Closed observation admission differs'}
 if($facts.ContainsKey('signature_validation')-and ($facts|ConvertTo-Json -Depth 8 -Compress).Contains('PRIVATE_TOKEN_PATH')){throw 'Private value escaped'}
 $count++
}
@{passed=$true;cases=$count;primaryFailurePreserved=$true;noNativeOrHostAction=$true}|ConvertTo-Json -Compress
'''
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary); ps = work / 'caller.ps1'; ps.write_text(script)
            cases = work / 'cases.json'; cases.write_text(json.dumps(rows))
            result = subprocess.run([str(pwsh), '-NoProfile', '-File', str(ps),
                                     str(Path(__file__).with_name('windows-updater-qualification.ps1')), temporary, str(cases)],
                                    capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stderr, b'')
            self.assertEqual(json.loads(result.stdout)['cases'], len(rows))


class TaskNormalizationChecks(unittest.TestCase):
    def test_real_powershell_normal_task_contract_and_refusals(self):
        """Run the actual XML normalizer; fake only IO/comparison, never native gates."""
        pwsh = Path('/var/lib/openwebpbx/tools/powershell/runtime/pwsh')
        if not pwsh.exists():
            self.skipTest('Private local PowerShell parser/runtime is unavailable.')
        source = Path(__file__).with_name('windows-updater-qualification.ps1')
        script = r'''
param([string]$Source,[string]$Work,[string]$SupportSource)
$ErrorActionPreference='Stop';$work=$Work
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function WriteJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 32))}
function Equal($Before,$After,[string]$Label){
 $a=Join-Path $work 'a.json';$b=Join-Path $work 'b.json';WriteJson $a $Before;WriteJson $b $After
 & python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))==json.load(open(sys.argv[2]))' $a $b *> $null
 if($LASTEXITCODE){throw 'Task contract/security difference'}
}
$errors=$null;$tokens=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Source parse failed'}
foreach($name in 'EqualTaskSnapshots','NormalTaskPreservation'){
 $functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($functions.Count -ne 1){throw 'Unique actual task comparator/normalizer required'}
 . ([ScriptBlock]::Create($functions[0].Extent.Text))
}
$support=[Management.Automation.Language.Parser]::ParseFile($SupportSource,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Support source parse failed'}
$functions=@($support.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-OpenWebTaskSecurityEquivalent'},$true))
if($functions.Count -ne 1){throw 'Unique actual Scheduler security comparator required'}
. ([ScriptBlock]::Create($functions[0].Extent.Text))
$started=[DateTime]::UtcNow.AddSeconds(-5);$afterBoundary=[DateTime]::UtcNow.AddMinutes(1).ToString('o')
$original='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Date>2026-01-01T00:00:00</Date><Author>Administrator</Author></RegistrationInfo><Triggers><TimeTrigger><StartBoundary>2026-01-01T00:00:00</StartBoundary><Repetition><Interval>PT1M</Interval></Repetition></TimeTrigger></Triggers><Actions><Exec><Command>owned.exe</Command></Exec></Actions><Principals><Principal><UserId>S-1-5-18</UserId></Principal></Principals><Settings><Enabled>true</Enabled></Settings></Task>'
$changed=$original.Replace('2026-01-01T00:00:00',$afterBoundary).Replace('Administrator','SYSTEM')
function Record([string]$Xml){return @{exists=$true;enabled=$true;xml=$Xml;acl='original-file-sddl';security='original-com-sddl'}}
$before=@{'OpenWebPBX-Backups'=(Record $original)};$after=@{'OpenWebPBX-Backups'=(Record $changed)}
NormalTaskPreservation $before $after $started
foreach($case in 'action','file_acl','com_acl','enabled','future_schedule','extra_trigger'){
 $record=Record $changed
 switch($case){
  'action'{$record.xml=$record.xml.Replace('owned.exe','foreign.exe')}
  'file_acl'{$record.acl='widened-file-sddl'}
  'com_acl'{$record.security='widened-com-sddl'}
  'enabled'{$record.enabled=$false}
  'future_schedule'{$record.xml=$record.xml.Replace($afterBoundary,[DateTime]::UtcNow.AddDays(1).ToString('o'))}
  'extra_trigger'{$record.xml=$record.xml.Replace('</Triggers>','<TimeTrigger><StartBoundary>'+ $afterBoundary+'</StartBoundary></TimeTrigger></Triggers>')}
 }
 $refused=$false;try{NormalTaskPreservation $before @{'OpenWebPBX-Backups'=$record} $started}catch{$refused=$true}
 if(!$refused){throw 'A changed task contract was accepted'}
}
'Seven actual PowerShell XML/schedule/security cases passed.'
'''
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'task-checks.ps1'; path.write_text(script)
            support = source.parents[1] / 'packaging/windows/Support-Recovery.ps1'
            result = subprocess.run([str(pwsh), '-NoProfile', '-File', str(path), str(source), temporary, str(support)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Seven actual PowerShell', result.stdout)


class AdminFormChecks(unittest.TestCase):
    def test_install_selects_post_button_form_with_tenant_selector_present(self):
        class OriginFixture(fixture.Web):
            def __init__(self): self.calls = []
            def request(self, path, fields=None):
                self.calls.append((path, fields))
                if fields == {'action': 'install'}: return 403, path, 'Denied'
                if fields is None:
                    return 200, path, ('<form method="get"><select name="tenant"><option value="owned" selected>Tenant</option></select></form>'
                        '<form method="post"><input type="hidden" name="csrf_owned" value="current"><button name="action" value="check">Check</button><button name="action" value="download">Download</button><button name="action" value="install">Install</button></form>')
                return 200, path, 'Request queued.'
        web = OriginFixture(); web.install()
        self.assertEqual(web.calls[-1][1], {'csrf_owned': 'current', 'action': 'install'})
        self.assertEqual(len(web.calls), 3)

    def test_failed_csrf_guard_never_submits_real_installation(self):
        class OriginFixture(fixture.Web):
            def __init__(self): self.calls = []
            def request(self, path, fields=None):
                self.calls.append((path, fields)); return 200, path, 'unexpected permission'
        web = OriginFixture()
        with self.assertRaises(RuntimeError): web.install()
        self.assertEqual(len(web.calls), 1)


if __name__ == '__main__':
    unittest.main()
