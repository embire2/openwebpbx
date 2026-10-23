"""Closed observer, lifecycle and real source-placement controls; no calls/imports."""
import ast
import importlib.util
import math
from pathlib import Path
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('cdr_background', SOURCE / 'windows_cdr_background.py')
cdr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cdr)


def service():
    return dict(schema=1, producer='windows_cdr_service.ps1', state='observed', read_only=True,
                actual_localservice_identity=True, candidate_bound=True,
                no_separate_importer=True, process_id=123)


def observed(complete=True):
    return dict(schema=1, state='observed', scope='owned_call', read_only=True,
                cdr_rows=int(complete), answered_cdr_rows=int(complete),
                history_rows=2 if complete else 0, history_owner_rows=2 if complete else 0,
                spool_files_present=0, quarantined_files_present=0,
                record_scope_exact=complete, history_sources_exact=complete,
                spool_absent=complete, completed=complete)


class Fixture:
    source = SOURCE.parent
    s = {'package_root': 'C:/qualified/candidate'}

    def __init__(self, rows):
        self.rows = iter(rows)
        self.actions = []

    def cli(self, *arguments):
        self.actions.append(arguments)
        return next(self.rows)


class Clock:
    def __init__(self): self.value = 0
    def __call__(self): return self.value
    def sleep(self, seconds): self.value += seconds


class Checks(unittest.TestCase):
    def test_actual_closed_service_contract(self):
        self.assertEqual(cdr.service_record(service()), service())
        for name in service():
            row = service(); del row[name]
            with self.subTest(missing=name), self.assertRaises(AssertionError): cdr.service_record(row)
        for name in ('read_only', 'actual_localservice_identity', 'candidate_bound', 'no_separate_importer'):
            for value in (False, 'true', 1, [True], None):
                row = service(); row[name] = value
                with self.subTest(name=name, value=value), self.assertRaises(AssertionError): cdr.service_record(row)
        for value in (True, '123', 0, -1, 4294967296, 1.0, [123], None):
            row = service(); row['process_id'] = value
            with self.subTest(pid=value), self.assertRaises(AssertionError): cdr.service_record(row)
        for name, value in (('producer', 'foreign.ps1'), ('state', 'passed'), ('schema', True), ('raw_log', 'private')):
            row = service(); row[name] = value
            with self.subTest(name=name), self.assertRaises(AssertionError): cdr.service_record(row)

    def test_exact_answered_and_both_history_scope(self):
        for complete in (False, True): self.assertEqual(cdr.observation(observed(complete)), observed(complete))
        for name in observed():
            row = observed(); del row[name]
            with self.subTest(missing=name), self.assertRaises(AssertionError): cdr.observation(row)
        for name in ('cdr_rows', 'answered_cdr_rows', 'history_rows', 'history_owner_rows', 'spool_files_present', 'quarantined_files_present'):
            for value in (True, '1', -1, 5, 1.0, [1], None):
                row = observed(); row[name] = value
                with self.subTest(name=name, value=value), self.assertRaises(AssertionError): cdr.observation(row)
        for name in ('read_only', 'record_scope_exact', 'history_sources_exact', 'spool_absent', 'completed'):
            for value in ('true', 1, [True], None):
                row = observed(); row[name] = value
                with self.subTest(name=name, value=value), self.assertRaises(AssertionError): cdr.observation(row)
        for name in ('record_scope_exact', 'history_sources_exact', 'spool_absent'):
            row = observed(); row[name] = False
            with self.subTest(flag=name), self.assertRaises(AssertionError): cdr.observation(row)
        for name, value in (('scope', 'foreign_call'), ('state', 'passed'), ('schema', True), ('raw_path', 'private')):
            row = observed(); row[name] = value
            with self.subTest(name=name), self.assertRaises(AssertionError): cdr.observation(row)

    def test_pending_then_real_completion_only_read_operations(self):
        fixture = Fixture([observed(False), observed()]); clock = Clock(); reads = []
        result = cdr.qualify(fixture, 'a' * 24 + '@localfixture', service(),
                             lambda: reads.append('identity') or service(), clock, clock.sleep)
        self.assertEqual(result['polls'], 2); self.assertEqual(result['elapsed_seconds'], 1)
        self.assertEqual(reads, ['identity'])
        self.assertEqual(fixture.actions, [('cdr-status', 'a' * 24 + '@localfixture')] * 2)
        self.assertEqual(len(result), 15)
        self.assertEqual(result['matched_cdr_rows'], 1); self.assertEqual(result['history_owner_rows'], 2)
        self.assertTrue(all(value is True for name, value in result.items() if name not in
                            {'matched_cdr_rows', 'answered_cdr_rows', 'history_rows', 'history_owner_rows', 'polls', 'elapsed_seconds'}))

    def test_deadline_and_restart_cannot_pass(self):
        fixture = Fixture([observed(False)] * 26); clock = Clock()
        with self.assertRaises(AssertionError): cdr.qualify(fixture, 'a' * 24 + '@localfixture', service(), service, clock, clock.sleep)
        self.assertEqual(clock.value, 25); self.assertEqual(len(fixture.actions), 26)
        after = service(); after['process_id'] += 1
        with self.assertRaises(AssertionError): cdr.qualify(Fixture([observed()]), 'a' * 24 + '@localfixture', service(), lambda: after)
        for value in (math.nan, math.inf, -1, 31):
            times = iter((0, value))
            with self.subTest(value=value), self.assertRaises(AssertionError):
                cdr.qualify(Fixture([observed()]), 'a' * 24 + '@localfixture', service(), service, lambda: next(times))
        for value in ('foreign', 'A' * 24 + '@localfixture', 'a' * 24 + '@foreign', ['a']):
            fixture = Fixture([])
            with self.subTest(value=value), self.assertRaises(AssertionError): cdr.qualify(fixture, value, service(), service)
            self.assertEqual(fixture.actions, [])

    def test_native_service_child_is_closed_and_bounded(self):
        import json
        from types import SimpleNamespace
        good = SimpleNamespace(returncode=0, stdout=json.dumps(service()), stderr='')
        with patch.object(cdr.subprocess, 'run', return_value=good) as child:
            self.assertEqual(cdr.observe_service(Fixture([]), 'powershell.exe'), service())
            argv = child.call_args.args[0]
            self.assertEqual(argv[-2:], ['-PackageRoot', 'C:/qualified/candidate'])
            self.assertEqual(child.call_args.kwargs['timeout'], 20)
            self.assertTrue(child.call_args.kwargs['capture_output'])
        for result in (SimpleNamespace(returncode=1, stdout='private', stderr=''),
                       SimpleNamespace(returncode=0, stdout=good.stdout, stderr='private'),
                       SimpleNamespace(returncode=0, stdout='x' * 8193, stderr='')):
            with patch.object(cdr.subprocess, 'run', return_value=result), self.assertRaises(AssertionError):
                cdr.observe_service(Fixture([]), 'powershell.exe')

    def test_actual_native_flow_correlates_first_decoded_call_before_any_drain(self):
        tree = ast.parse((SOURCE / 'windows-native-acceptance.py').read_text())
        native = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'native_calls')
        call_check = next(node for node in native.body if isinstance(node, ast.FunctionDef) and node.name == 'call_check')
        text = ast.get_source_segment((SOURCE / 'windows-native-acceptance.py').read_text(), call_check)
        self.assertLess(text.index('service_before=cdr.observe_service'), text.index('call=caller.dial'))
        self.assertLess(text.index('result=media(call,remote);caller.hangup(call)'), text.index('proof=cdr.qualify'))
        self.assertIn("cdr.qualify(f,call['callid'],service_before", text)
        self.assertIn("target=='8101' and expected is a and digit is None", text)
        refresh = [node for node in ast.walk(native) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                   and node.func.id == 'call_check' and any(key.arg == 'background_cdr' for key in node.keywords)]
        self.assertEqual(len(refresh), 1); self.assertEqual(ast.literal_eval(refresh[0].args[0]), '8101')
        self.assertTrue(ast.literal_eval(refresh[0].keywords[0].value))
        cdr_tree = ast.parse((SOURCE / 'windows_cdr_background.py').read_text())
        verbs = [node.args[0].value for node in ast.walk(cdr_tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Attribute) and node.func.attr == 'cli']
        self.assertEqual(verbs, ['cdr-status'])
        values = {node.value for node in ast.walk(tree) if isinstance(node, ast.Constant) and isinstance(node.value, str)}
        self.assertIn('windows_cdr_observation.php', values)
        self.assertIn('cdr_background_import', values)


if __name__ == '__main__': unittest.main()
