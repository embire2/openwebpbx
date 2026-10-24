"""Closed failure-only source controls; no installed Windows or browser claim."""
import ast
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('restored_meeting_failure_source', HERE / 'windows_restored_meeting.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ORIGINAL_PY = 'beb1ecc8fa7fbc8883723624567f85b9c36a515389370f6120f673878cbb1d6a'
ORIGINAL_PS = 'ed9d0660054c6d32b649f83b61db6659da010ccac9d4e4ba4c0c49c753c3bfb4'
PRIVATE = 'PRIVATE password=not-public https://private.example.invalid/a SQL private_uuid'


def primary_at(filename, kind=ValueError, depth=0):
    namespace = {'kind': kind, 'private': PRIVATE}
    exec(compile('def site(depth):\n if depth: return site(depth-1)\n raise kind(private)\n', str(filename), 'exec'), namespace)
    try: namespace['site'](depth)
    except BaseException as error: return error
    raise AssertionError('The explicit failure adapter did not fail.')


class FailureObservation(unittest.TestCase):
    def test_whole_original_drivers_reconstruct_and_runtime_helpers_remain_exact(self):
        source = (HERE / 'windows_restored_meeting.py').read_text()
        begin = source.index('def recovery_file_digest('); end = source.index('def stable_files(q):', begin)
        source = source[:begin] + source[end:]
        addition = """    recovery, copy_count = recovery_inventory(q, root); entries = []
    for path in root.rglob('*'):
        require(len(entries) < 64 + copy_count); entries.append(path)
    result = {}
    for path in entries:
        if path.is_dir(): continue
        key = path.relative_to(root).as_posix()
        result[str(path.relative_to(root))] = recovery_file_digest(path, recovery[key][0], q.backups.MAX_ARCHIVE) if key in recovery else digest(path)
        if key in recovery: require(result[str(path.relative_to(root))] == recovery[key][1])"""
        original = "    entries = list(root.rglob('*')); require(len(entries) <= 64)\n    result = {str(p.relative_to(root)): digest(p) for p in entries if not p.is_dir()}"
        self.assertEqual(source.count(addition), 1); source = source.replace(addition, original, 1)
        begin = source.index('FAILURE_CASES = '); end = source.index('def require(value):', begin)
        source = source[:begin] + source[end:]
        addition = '    except BaseException as error:\n        primary = error\n        observe_failure_case(error, fixture)'
        self.assertEqual(source.count(addition), 1)
        source = source.replace(addition, '    except BaseException as error: primary = error', 1)
        addition = '        try: print(json.dumps(failure_record(error)))\n        except BaseException: pass'
        original = "        print(json.dumps({'schema': 1, 'state': 'failed', 'producer': 'windows_restored_meeting.py',\n                          'error_type': type(error).__name__ if type(error).__name__ in ('RuntimeError', 'ValueError', 'TimeoutExpired', 'OSError') else 'external_error',\n                          'cleanup_verified': getattr(error, 'restored_meeting_cleanup_verified', False) is True}))"
        self.assertEqual(source.count(addition), 1); source = source.replace(addition, original, 1)
        self.assertEqual(hashlib.sha256(source.encode()).hexdigest(), ORIGINAL_PY)
        parent = (HERE / 'windows-restore-qualification.ps1').read_text()
        begin = parent.index('function SafeRestoredConferenceFailure($Record){'); end = parent.index('function RestoredMeetingSupplement {', begin)
        parent = parent[:begin] + parent[end:]
        call = "CheckedProcess $python @('-I','-B',(Join-Path $PSScriptRoot 'windows_restored_meeting.py'),'--input',$inputFile,'--adapter',$adapter) 'restored-conference-supplement' $source 600000"
        addition = " try{" + call + "}\n catch{\n  try{$failure=ReadRestoredConferenceFailure;if($null -ne $failure){$facts.restored_conference_failure=$failure}}catch{}\n  throw\n }"
        self.assertEqual(parent.count(addition), 1); parent = parent.replace(addition, ' ' + call, 1)
        self.assertEqual(hashlib.sha256(parent.encode()).hexdigest(), ORIGINAL_PS)
        # All original browser checks, thresholds and owned Windows Job code are
        # unchanged; these hashes belong to the exact failed native source.
        expected = {
            'windows_meeting_owned_process.py': '9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448',
            'windows-meet-browser.py': '0bc45c9e0814e78b5a6fcf7c1f3e36f33bd70e113644b2e737fe208d46bdf7d7',
            'windows-meet-browser.cjs': '13abed3e2063039d0fb311ac75f59a4f506ba46880cb846a0912e1a82c23d2c0',
        }
        for name, digest in expected.items(): self.assertEqual(hashlib.sha256((HERE / name).read_bytes()).hexdigest(), digest)

    def test_actual_trace_has_only_four_fixed_sources_and_bounded_lines(self):
        for name in m.FAILURE_SOURCES:
            error = primary_at(HERE / name, depth=8)
            record = m.failure_record(error)
            self.assertEqual(len(record['source_frames']), 4)
            self.assertEqual({f['source_basename'] for f in record['source_frames']}, {name})
            self.assertTrue(all(set(f) == {'source_basename', 'source_line'} and type(f['source_line']) is int and 0 < f['source_line'] < 1000000 for f in record['source_frames']))
            self.assertNotIn(PRIVATE, json.dumps(record)); self.assertNotIn('private_uuid', json.dumps(record))
        for name in ('private.py', 'windows_restored_meeting.py'):
            record = m.failure_record(primary_at(Path('/not-the-trusted-source') / name))
            self.assertEqual(record['source_frames'], [])
        self.assertEqual(len(m.failure_record(primary_at(HERE / m.FAILURE_SOURCES[0], depth=80))['source_frames']), 4)

    def test_exception_messages_locals_custom_names_and_flags_stay_private(self):
        error = primary_at(HERE / m.FAILURE_SOURCES[0], type('PRIVATE_SECRET_TYPE', (ValueError,), {}))
        error.restored_meeting_active_case = PRIVATE
        error.restored_meeting_cleanup_verified = 1
        error.owned_process_cleanup_failed = PRIVATE
        error.owned_processes_closed = 1
        record = m.failure_record(error)
        self.assertEqual(record['error_type'], 'external_error'); self.assertEqual(record['active_case'], 'unavailable')
        self.assertIs(record['cleanup_verified'], False)
        self.assertIsNone(record['owned_process_cleanup_failed']); self.assertIsNone(record['owned_processes_closed'])
        self.assertEqual(set(record), {'schema', 'state', 'producer', 'error_type', 'cleanup_verified', 'source_frames', 'active_case', 'owned_process_cleanup_failed', 'owned_processes_closed'})
        self.assertNotIn('PRIVATE', json.dumps(record)); self.assertNotIn('SQL', json.dumps(record)); self.assertNotIn('https:', json.dumps(record))
        for case in m.FAILURE_CASES:
            error.restored_meeting_active_case = case
            error.restored_meeting_cleanup_verified = True
            error.owned_process_cleanup_failed = False; error.owned_processes_closed = True
            got = m.failure_record(error)
            self.assertEqual(got['active_case'], case); self.assertIs(got['cleanup_verified'], True)
            self.assertIs(got['owned_process_cleanup_failed'], False); self.assertIs(got['owned_processes_closed'], True)

    def test_failure_observer_never_opens_files_runs_children_or_reads_error_text(self):
        class PrivateError(ValueError):
            def __str__(self): raise AssertionError('Private formatting forbidden.')
            def __repr__(self): raise AssertionError('Private formatting forbidden.')
        error = primary_at(HERE / m.FAILURE_SOURCES[0], PrivateError)
        with patch('builtins.open', side_effect=AssertionError('No file access')), patch.object(Path, 'read_bytes', side_effect=AssertionError('No file access')), patch.object(m.subprocess, 'run', side_effect=AssertionError('No child access')):
            record = m.failure_record(error)
        self.assertEqual(record['error_type'], 'external_error'); self.assertTrue(record['source_frames'])

    def test_case_observation_keeps_original_exception_and_suppresses_its_own_faults(self):
        for fault in (RuntimeError, SystemExit, KeyboardInterrupt):
            class BrokenFixture:
                @property
                def active_case(self): raise fault(PRIVATE)
            error = ValueError(PRIVATE); before = error.args
            m.observe_failure_case(error, BrokenFixture())
            self.assertEqual(error.args, before); self.assertFalse(hasattr(error, 'restored_meeting_active_case'))
        for case in m.FAILURE_CASES:
            error = ValueError(PRIVATE); m.observe_failure_case(error, types.SimpleNamespace(active_case=case))
            self.assertEqual(error.restored_meeting_active_case, case)
        error = ValueError(PRIVATE); m.observe_failure_case(error, types.SimpleNamespace(active_case=PRIVATE))
        self.assertFalse(hasattr(error, 'restored_meeting_active_case'))

    def test_actual_top_level_preserves_failure_exit_even_when_observer_fails(self):
        source = (HERE / 'windows_restored_meeting.py').read_text(); tree = ast.parse(source)
        main = next(node for node in tree.body if isinstance(node, ast.If) and isinstance(node.test, ast.Compare) and isinstance(node.test.left, ast.Name) and node.test.left.id == '__name__')
        for fault in (None, RuntimeError, SystemExit, KeyboardInterrupt):
            error = primary_at(HERE / m.FAILURE_SOURCES[0]); output = io.StringIO(); calls = []
            def fail(): calls.append('original'); raise error
            def observe(value):
                self.assertIs(value, error); calls.append('observer')
                if fault is not None: raise fault(PRIVATE)
                return m.failure_record(value)
            namespace = dict(m.__dict__, __name__='__main__', main=fail, failure_record=observe)
            with contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as caught:
                exec(compile(ast.Module(body=[main], type_ignores=[]), str(HERE / 'windows_restored_meeting.py'), 'exec'), namespace)
            self.assertEqual(caught.exception.code, 1); self.assertEqual(calls, ['original', 'observer'])
            self.assertIs(caught.exception.__context__, error)
            if fault is None: self.assertEqual(json.loads(output.getvalue())['state'], 'failed')
            else: self.assertEqual(output.getvalue(), '')
            self.assertNotIn(PRIVATE, output.getvalue())

    def test_actual_child_platform_refusal_remains_closed_before_installed_input(self):
        if sys.platform == 'win32': self.skipTest('This control is an explicit POSIX refusal.')
        result = subprocess.run([sys.executable, '-I', '-B', str(HERE / 'windows_restored_meeting.py'), '--input', '/must-not-be-read', '--adapter', '/must-not-be-read'], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1); self.assertEqual(result.stderr, '')
        record = json.loads(result.stdout)
        self.assertEqual(record['state'], 'failed'); self.assertEqual(record['error_type'], 'RuntimeError')
        self.assertIs(record['cleanup_verified'], False); self.assertEqual(record['active_case'], 'unavailable')
        self.assertTrue(record['source_frames']); self.assertNotIn('must-not-be-read', result.stdout)


if __name__ == '__main__': unittest.main()
