"""Reuse actual closed collectors/validators with explicit inert child adapters."""
import ast
from windows_meet_wss_child_source import pre_wss_child_source
import copy
import hashlib
import http.cookiejar
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
import urllib.request
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
PRIVATE = 'PRIVATE_RAW_URL_PASSWORD_TOKEN'
def wss_record():
    return [{'schema':1,'label':'before','reason':'report_missing','outcome':{'exit_code':1,'error_type':'Error','code_kind':'exit','errno':None,'killed':False,'signal':'none','elapsed_ms':12,'powershell_state':'closed','powershell':{'schema':1,'state':'failed','producer':'windows-meet-wss-path.ps1','error_type':'RuntimeException','source_basename':'windows-meet-wss-path.ps1','source_line':73,'hresult':-2146233087}}}]

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
m = load('restored_path_observer', 'windows_restored_meeting.py')
browser = load('original_browser_path_collector', 'windows-meet-browser.py')


def previous_producer():
    source = pre_wss_child_source('windows_restored_meeting.py')
    tree = ast.parse(source)
    helper = ast.get_source_segment(source, next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'restored_path_fields'))
    self_block = helper + '\n\n\n'; assert source.count(self_block) == 1
    source = source.replace(self_block, '', 1)
    addition = """    if record['active_case'] == 'native_windows_meeting_browser_start':
        try:
            paths = getattr(error, 'meeting_path_failure', None)
            if type(paths) is dict and set(paths) == {'meeting_path'}:
                record.update(restored_path_fields(paths['meeting_path']))
        except BaseException: pass
    return record
"""
    assert source.count(addition) == 1; source = source.replace(addition, '', 1)
    line = "    record = {'schema': 1, 'state': 'failed', 'producer': 'windows_restored_meeting.py',"
    assert source.count(line) == 1; source = source.replace(line, line.replace('record = ', 'return ', 1), 1)
    assert hashlib.sha256(source.encode()).hexdigest() == 'e84f1a60b98fc905f58d49a4f2da1d5a06f529b452bdded0c3555150c05218fc'
    old = types.ModuleType('exact_previous_failure_producer'); old.__file__ = str(HERE / 'windows_restored_meeting.py')
    exec(compile(source, old.__file__, 'exec'), old.__dict__)
    return old


class ExistingPathHandoff(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        node = shutil.which('node'); assert node, 'The actual inert CJS producer is required.'
        code = "const d=require(process.argv[1]);process.stdout.write(JSON.stringify({before:d.defaults(),after:d.defaults()}));"
        result = subprocess.run([node, '-e', code, str(HERE / 'windows-meet-path-diagnostics.cjs')], check=True, capture_output=True, text=True, timeout=10)
        cls.paths = json.loads(result.stdout)
        cls.paths['before']['backend'].update(observed=True, connected=True, status_code=200, elapsed_ms=12)
        cls.paths['before']['frontend'].update(observed=True, error_kind='tls', elapsed_ms=49)
        cls.paths['after']['database'].update(observed=True, read_only=True, total=3)
        cls.old = previous_producer()

    def error(self, paths=None, case='native_windows_meeting_browser_start'):
        error = RuntimeError(PRIVATE); error.restored_meeting_active_case = case
        error.meeting_path_failure = {'meeting_path': copy.deepcopy(self.paths if paths is None else paths)}
        return error

    def test_existing_python_path_validator_is_reused_byte_exact_and_old_producer_reconstructs(self):
        def body(source, name):
            node = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == name)
            return ast.get_source_segment(source, node).split('\n', 1)[1]
        old = (HERE / 'windows-meet-browser.py').read_text(); new = (HERE / 'windows_restored_meeting.py').read_text()
        self.assertEqual(body(old, 'path_fields'), body(new, 'restored_path_fields'))
        self.assertEqual(browser.path_fields(self.paths), m.restored_path_fields(self.paths))
        self.assertEqual(self.old.failure_record(self.error()).get('meeting_path'), None)
        self.assertEqual(m.failure_record(self.error())['meeting_path'], self.paths)

    def test_real_original_browser_nonzero_collector_survives_full_failure_handoff(self):
        with tempfile.TemporaryDirectory(prefix='restored-existing-path-') as td:
            root = Path(td); evidence = root / 'evidence'; evidence.mkdir()
            npm_cli = root / 'node_modules/npm/bin/npm-cli.js'; npm_cli.parent.mkdir(parents=True); npm_cli.write_text('inert executable marker')
            jar = http.cookiejar.CookieJar()
            jar.set_cookie(http.cookiejar.Cookie(version=0, name='fixture', value=PRIVATE, port=None, port_specified=False,
                domain='windowsqa.example.invalid', domain_specified=False, domain_initial_dot=False, path='/', path_specified=True,
                secure=True, expires=None, discard=True, comment=None, comment_url=None, rest={'HttpOnly': None}, rfc2109=False))
            opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar)); opener.addheaders = [('User-Agent', 'owned-qa-agent')]
            fixture = types.SimpleNamespace(evidence=evidence, source=HERE.parent, php=Path('C:/OpenWebPBX/php/php.exe'),
                script=HERE / 'windows-native-fixture.php', path=root / 'input.json',
                s={'scope': 'a'*24, 'public_url': 'https://windowsqa.example.invalid:8443'}, web=types.SimpleNamespace(open=opener))
            calls = []
            def child(arguments, **kwargs):
                calls.append((arguments, kwargs)); self.assertEqual(kwargs, dict(capture_output=True, text=True, timeout=240))
                self.assertEqual(arguments[0], str(root / 'node.exe'))
                if len(calls) == 1:
                    self.assertEqual(arguments[1:], [str(npm_cli), 'ci', '--prefix', str(evidence / 'meeting-browser-dependencies'), '--ignore-scripts', '--no-audit', '--fund=false', '--fetch-timeout=30000', '--fetch-retries=2'])
                    return types.SimpleNamespace(returncode=0, stdout=PRIVATE, stderr=PRIVATE)
                self.assertEqual(arguments[1:], [str(HERE / 'windows-meet-browser.cjs'), str(evidence / 'meeting-browser.private.json')])
                settings = json.loads(Path(arguments[-1]).read_text())
                Path(settings['report']).write_text(json.dumps(dict(schema=1, state='failed', phase='browser_start', meeting_path=self.paths, meeting_wss_child_failure=wss_record())))
                return types.SimpleNamespace(returncode=1, stdout=PRIVATE, stderr=PRIVATE)
            fake_os = types.SimpleNamespace(name='nt', environ={'OPENWEB_WINDOWS_NATIVE_TEST': '1', 'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_REPOSITORY': 'embire2/openwebpbx'})
            primary = None
            with patch.object(browser, 'os', fake_os), patch.object(browser.shutil, 'which', side_effect=lambda name: str(root / name)), patch.object(browser, 'subprocess', types.SimpleNamespace(run=child)):
                try: browser.run(fixture)
                except RuntimeError as error: primary = error
                else: self.fail('The original nonzero browser refusal was swallowed.')
            self.assertIsNotNone(primary); self.assertEqual(len(calls), 2)
            self.assertEqual(fixture.active_case, 'native_windows_meeting_browser_start')
            self.assertEqual(primary.meeting_path_failure, {'meeting_path': self.paths})
            self.assertEqual(primary.meeting_wss_child_failure, {'meeting_wss_child_failure': wss_record()})
            self.assertFalse((evidence / 'meeting-browser.private.json').exists())
            m.observe_failure_case(primary, fixture)
            before = self.old.failure_record(primary); after = m.failure_record(primary)
            self.assertNotIn('meeting_path', before); self.assertEqual(after['meeting_path'], self.paths)
            self.assertEqual(after['meeting_wss_child_failure'], wss_record())
            self.assertEqual({k: v for k, v in after.items() if k not in {'meeting_path','meeting_wss_child_failure'}}, before)
            self.assertNotIn(PRIVATE, json.dumps(after)); self.assertNotIn('https:', json.dumps(after)); self.assertNotIn('Bearer', json.dumps(after))
            after['meeting_path']['before']['backend']['status_code'] = 699
            self.assertEqual(primary.meeting_path_failure['meeting_path']['before']['backend']['status_code'], 200)

    def test_every_existing_closed_field_and_private_extra_refuses_without_text_or_new_io(self):
        for stage in self.paths:
            for kind in self.paths[stage]:
                for field in self.paths[stage][kind]:
                    bad = copy.deepcopy(self.paths); bad[stage][kind][field] = None
                    with self.subTest(stage=stage, kind=kind, field=field):
                        self.assertEqual(m.restored_path_fields(bad), {})
                        self.assertNotIn('meeting_path', m.failure_record(self.error(bad)))
                bad = copy.deepcopy(self.paths); bad[stage][kind]['raw_header'] = PRIVATE
                self.assertNotIn('meeting_path', m.failure_record(self.error(bad)))
        for bad in (None, [], {}, True, PRIVATE, self.paths | {'url': PRIVATE}):
            error = self.error(); error.meeting_path_failure = {'meeting_path': bad}
            record = m.failure_record(error); self.assertNotIn('meeting_path', record); self.assertNotIn(PRIVATE, json.dumps(record))
        for case in ('unavailable', 'native_windows_meeting_owner_page', 'native_windows_meeting_decoded_media'):
            self.assertNotIn('meeting_path', m.failure_record(self.error(case=case)))
        error = self.error()
        with patch('builtins.open', side_effect=AssertionError('No new file access')), patch.object(Path, 'read_bytes', side_effect=AssertionError('No new file access')):
            self.assertEqual(m.failure_record(error)['meeting_path'], self.paths)
        for kind in (RuntimeError, SystemExit, KeyboardInterrupt):
            with patch.object(m, 'restored_path_fields', side_effect=kind(PRIVATE)):
                self.assertNotIn('meeting_path', m.failure_record(error))
            self.assertEqual(error.args, (PRIVATE,))


class WssChildFailure(unittest.TestCase):
    def test_six_entire_original_sources_reconstruct_without_guard_or_success_changes(self):
        for name in ('windows-meet-wss-path.ps1','windows-meet-path-diagnostics.cjs','windows-meet-browser.cjs','windows-meet-browser.py','windows_restored_meeting.py','windows-restore-qualification.ps1'):
            self.assertTrue(pre_wss_child_source(name))
        def body(filename, name):
            source=(HERE/filename).read_text(); node=next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef) and n.name==name)
            return ast.get_source_segment(source,node).split('\n',1)[1]
        self.assertEqual(body('windows-meet-browser.py','wss_child_fields'),body('windows_restored_meeting.py','restored_wss_child_fields'))

    def test_stock_bootstrap_reuses_reviewed_client_source_and_exact_previous_wss_reconstructs(self):
        current=(HERE/'windows-meet-wss-path.ps1').read_text()
        start=current.index('function Assert-MeetWssPathStockOrdinary');end=current.index('function Get-MeetWssPathFailure',start)
        bootstrap=current[start:end];call=' Import-MeetWssPathDesktopModules\n'
        self.assertEqual(current.count(call),1)
        self.assertEqual(hashlib.sha256(current.replace(bootstrap,'',1).replace(call,'',1).encode()).hexdigest(),'53d31893311d158cc0375c34b66175dead78a67ebb8fdc040d43dab8203ad299')
        home_guard=" if([IO.Path]::GetFullPath($PSHOME) -ine $nativeHome){throw 'The exact native Windows PowerShell home is required.'}\n"
        self.assertEqual(bootstrap.count(home_guard),1)
        previous=bootstrap.replace(home_guard,'',1).replace('MeetWssPath','OpenWebCatalogue').replace('ConvertTo-Json','ConvertFrom-Json').replace('ConvertToJsonCommand','ConvertFromJsonCommand')
        self.assertEqual(hashlib.sha256(previous.encode()).hexdigest(),'2fde14de1323429ebfd8d7f5babd8cbcdb9c4b3ba00c65786533d114edd6ddab')

    def test_actual_node_child_exit_missing_timeout_buffer_and_original_wrapper_contract(self):
        result=subprocess.run([shutil.which('node'),str(HERE/'windows_meet_wss_child_test.cjs')], input=json.dumps({'original':pre_wss_child_source('windows-meet-path-diagnostics.cjs')}),text=True,capture_output=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr); report=json.loads(result.stdout)
        self.assertEqual(report['state'],'passed');self.assertGreaterEqual(report['checks'],60)

    def test_all_closed_fields_missing_private_wrong_type_or_outside_bound_refuse_at_both_boundaries(self):
        good=wss_record();self.assertEqual(browser.wss_child_fields(good),m.restored_wss_child_fields(good))
        bads=[None,{},[],True,PRIVATE,good*2,good*3]
        for node in ((),(0,),(0,'outcome'),(0,'outcome','powershell')):
            value=copy.deepcopy(good);target=value
            for key in node:target=target[key]
            if isinstance(target,dict):
                for key in target:
                    for edit in ('missing','private','wrong'):
                        value=copy.deepcopy(good);current=value
                        for part in node:current=current[part]
                        if edit=='missing':del current[key]
                        elif edit=='private':current['raw_private']=PRIVATE
                        else:current[key]=[PRIVATE]
                        bads.append(value)
        for key,val in [('exit_code',True),('exit_code',4294967296),('errno',-2147483649),('elapsed_ms',32001),('elapsed_ms',True),('killed',1),('powershell_state','absent')]:
            value=copy.deepcopy(good);value[0]['outcome'][key]=val;bads.append(value)
        for key,val in [('hresult',True),('hresult',2147483648),('source_line',0),('source_line',1000000),('source_basename','unavailable')]:
            value=copy.deepcopy(good);value[0]['outcome']['powershell'][key]=val;bads.append(value)
        for value in bads:
            with self.subTest(value=value):
                self.assertEqual(browser.wss_child_fields(value),{});self.assertEqual(m.restored_wss_child_fields(value),{})

    def test_failure_only_nonfatal_private_projection_and_unchanged_old_fallback(self):
        error=RuntimeError(PRIVATE);error.restored_meeting_active_case='native_windows_meeting_browser_start';error.meeting_wss_child_failure={'meeting_wss_child_failure':wss_record()}
        result=m.failure_record(error);self.assertEqual(result['meeting_wss_child_failure'],wss_record());self.assertNotIn(PRIVATE,json.dumps(result))
        for stage in ('unavailable','native_windows_meeting_owner_page','native_windows_meeting_decoded_media'):
            error.restored_meeting_active_case=stage;self.assertNotIn('meeting_wss_child_failure',m.failure_record(error))
        error.restored_meeting_active_case='native_windows_meeting_browser_start'
        with patch('builtins.open',side_effect=AssertionError('No file access')):
            self.assertEqual(m.failure_record(error)['meeting_wss_child_failure'],wss_record())
        for kind in (RuntimeError,KeyboardInterrupt,SystemExit):
            with patch.object(m,'restored_wss_child_fields',side_effect=kind(PRIVATE)):
                self.assertNotIn('meeting_wss_child_failure',m.failure_record(error))
        self.assertEqual(error.args,(PRIVATE,))


if __name__ == '__main__': unittest.main()
