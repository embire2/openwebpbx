"""Actual PHP/owned-file and extracted-wrapper controls, no installed PBX access."""
import ast
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('restore_php_observation', HERE / 'windows-restore-qualification.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
PHP = shutil.which('php')
PRIVATE = 'PRIVATE_SQL_password_C:/customer/secret'


def record(action='snapshot'):
    return dict(schema=1, action=action, returncode=1, error_type='RuntimeException',
                source_basename='windows-restore-qualification.php', source_line=123)


class Observation(unittest.TestCase):
    def test_closed_types_bounds_and_privacy(self):
        good = record()
        self.assertEqual(good, mod.restore_php_failure_fields(good))
        for key in good:
            value = dict(good); del value[key]
            self.assertEqual({}, mod.restore_php_failure_fields(value))
            for bad in (None, True, [], {}, PRIVATE):
                value = good | {key: bad}
                self.assertEqual({}, mod.restore_php_failure_fields(value), (key, bad))
        self.assertEqual({}, mod.restore_php_failure_fields(good | {'message': PRIVATE}))
        for value in (0, -2147483649, 4294967296, 1.0):
            self.assertEqual({}, mod.restore_php_failure_fields(good | {'returncode': value}))
        for value in (-2147483648, -1, 1, 255, 4294967295):
            self.assertEqual(value, mod.restore_php_failure_fields(good | {'returncode': value})['returncode'])
        for action in mod.PHP_FIXTURE_ACTIONS:
            self.assertEqual(action, mod.restore_php_failure_fields(record(action))['action'])
        for field, values in [('error_type', mod.PHP_FIXTURE_TYPES), ('source_basename', mod.PHP_FIXTURE_SOURCES)]:
            for value in values:
                self.assertEqual(value, mod.restore_php_failure_fields(good | {field: value})[field])
        for line in (0, -1, 1000000, True, '1'):
            self.assertEqual({}, mod.restore_php_failure_fields(good | {'source_line': line}))
        unavailable = good | dict(error_type='unavailable', source_basename='unavailable', source_line=0)
        self.assertEqual(unavailable, mod.restore_php_failure_fields(unavailable))
        for change in ({'source_line': 1}, {'source_basename': 'external_component'}, {'error_type': 'Error'}):
            self.assertEqual({}, mod.restore_php_failure_fields(unavailable | change))
        self.assertNotIn(PRIVATE, json.dumps(mod.restore_php_failure_fields(good)))

    def instance(self, root):
        work = root / ('a' * 24); work.mkdir()
        path = work / 'input.json'; path.write_text('{"owned":true}')
        instance = mod.Qualification.__new__(mod.Qualification)
        instance.path, instance.work, instance.source = path, work, HERE.parent
        instance.s = {'owned': True}
        return instance

    def invoke(self, instance, action, callback):
        calls = []
        def child(args, **kwargs):
            calls.append((args, kwargs))
            self.assertEqual(['C:/OpenWebPBX/php/php.exe', str(HERE / 'windows-restore-qualification.php'), action, str(instance.path)], args)
            self.assertEqual(dict(cwd='C:/OpenWebPBX/web', stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120), kwargs)
            return callback()
        with patch.object(mod.subprocess, 'run', child):
            try: result = instance.php(action)
            except Exception as error: result = error
        self.assertEqual(1, len(calls))
        return result

    def assert_primary(self, error):
        self.assertIs(type(error), RuntimeError)
        self.assertEqual('The private scoped PHP fixture failed.', str(error))

    def test_real_php_failure_writer_and_original_wrapper_gap(self):
        self.assertIsNotNone(PHP)
        original_run = subprocess.run
        for action in mod.PHP_FIXTURE_ACTIONS:
            with self.subTest(action=action), tempfile.TemporaryDirectory(prefix='restore-php-observer-') as td:
                root = Path(td); instance = self.instance(root)
                script = root / 'child.php'
                script.write_text("<?php define('OPENWEB_RESTORE_FIXTURE_LIBRARY_ONLY',true);require $argv[1];"
                    "try{restore_fixture_snapshot_shape([]);}catch(Throwable $e){"
                    "restore_fixture_php_failure_record($e,$argv[2],$argv[3],$argv[4]);"
                    "fwrite(STDERR,\"Private Windows restore qualification fixture failed.\\n\");exit(1);}")
                def actual_child():
                    return original_run([PHP, str(script), str(HERE / 'windows-restore-qualification.php'),
                        str(instance.path), action, str(root)], capture_output=True, timeout=120, cwd=root)
                error = self.invoke(instance, action, actual_child); self.assert_primary(error)
                fields = error.php_failure
                self.assertEqual(action, fields['action']); self.assertEqual(1, fields['returncode'])
                self.assertEqual('RuntimeException', fields['error_type'])
                self.assertEqual('windows-restore-qualification.php', fields['source_basename'])
                self.assertGreater(fields['source_line'], 0)
                self.assertNotIn(str(root), json.dumps(fields))
                # Exact owned record cannot overwrite an earlier attempt.
                target = Path(str(instance.path) + '.' + action + '.php.failure.json')
                saved = target.read_bytes(); actual_child(); self.assertEqual(saved, target.read_bytes())
                stale = self.invoke(instance, action, actual_child); self.assert_primary(stale)
                self.assertEqual('unavailable', stale.php_failure['error_type'])
                self.assertEqual({'owned': True}, json.loads(instance.path.read_text()))

    def test_failure_records_missing_malformed_stale_and_linked(self):
        for mode in ('missing', 'valid', 'extra', 'action', 'malformed', 'duplicate', 'oversized', 'directory', 'linked', 'metadata_raises'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='restore-php-observer-') as td:
                root = Path(td); instance = self.instance(root)
                target = Path(str(instance.path) + '.snapshot.php.failure.json')
                def child():
                    r = record(); r.pop('returncode')
                    if mode == 'extra': r['message'] = PRIVATE
                    if mode == 'action': r['action'] = 'discover'
                    if mode in ('valid', 'extra', 'action'): target.write_text(json.dumps(r))
                    if mode == 'malformed': target.write_text('{')
                    if mode == 'duplicate': target.write_text('{"schema":1,"schema":1}')
                    if mode == 'oversized': target.write_text('x' * 2049)
                    if mode == 'directory': target.mkdir()
                    if mode == 'linked':
                        other = root / 'other'; other.write_text(json.dumps(r)); target.symlink_to(other)
                    return types.SimpleNamespace(returncode=23, stdout=b'', stderr=PRIVATE.encode())
                if mode == 'metadata_raises':
                    with patch.object(mod, 'observe_restore_php_failure', side_effect=OSError(PRIVATE)):
                        error = self.invoke(instance, 'snapshot', child)
                    self.assertFalse(hasattr(error, 'php_failure'))
                else:
                    error = self.invoke(instance, 'snapshot', child)
                    self.assertEqual('RuntimeException' if mode == 'valid' else 'unavailable', error.php_failure['error_type'])
                    self.assertEqual(23, error.php_failure['returncode'])
                    self.assertNotIn(PRIVATE, json.dumps(error.php_failure))
                self.assert_primary(error)

    def test_success_timeout_and_probe_failure_preserve_original_paths(self):
        with tempfile.TemporaryDirectory(prefix='restore-php-observer-') as td:
            instance = self.instance(Path(td))
            with patch.object(mod, 'observe_restore_php_failure', side_effect=AssertionError('Must not observe success')):
                result = self.invoke(instance, 'status', lambda: types.SimpleNamespace(returncode=0, stdout=b'{"ok":true}', stderr=b''))
            self.assertEqual({'ok': True}, result)
            timeout = subprocess.TimeoutExpired('private command', 120)
            def expired(): raise timeout
            self.assertIs(timeout, self.invoke(instance, 'status', expired))
            with patch.object(mod, 'prepare_restore_php_observation', side_effect=OSError(PRIVATE)):
                error = self.invoke(instance, 'status', lambda: types.SimpleNamespace(returncode=7, stdout=b'', stderr=b''))
            self.assert_primary(error); self.assertEqual('unavailable', error.php_failure['error_type'])

    def test_actual_terminal_projection_keeps_original_failure(self):
        tree = ast.parse((HERE / 'windows-restore-qualification.py').read_text())
        node = tree.body[-1]
        self.assertIsInstance(node, ast.If)
        for mode in ('valid', 'invalid', 'observer_throws'):
            error = RuntimeError(PRIVATE)
            error.php_failure = record() if mode != 'invalid' else (record() | {'message': PRIVATE})
            def main(): raise error
            namespace = dict(vars(mod), __name__='__main__', main=main)
            if mode == 'observer_throws':
                def refuse(_record): raise OSError(PRIVATE)
                namespace['restore_php_failure_fields'] = refuse
            out = io.StringIO()
            with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as ended:
                exec(compile(ast.Module(body=[node], type_ignores=[]), str(HERE / 'windows-restore-qualification.py'), 'exec'), namespace)
            self.assertEqual(1, ended.exception.code)
            value = json.loads(out.getvalue())
            self.assertEqual('RuntimeError', value['error_type'])
            self.assertEqual('failed', value['state'])
            self.assertEqual(mode == 'valid', 'php_failure' in value)
            self.assertNotIn(PRIVATE, out.getvalue())

    def test_actual_php_terminal_handler_survives_observer_throw(self):
        source = (HERE / 'windows-restore-qualification.php').read_text()
        handler = source[source.index('    set_exception_handler('):source.rindex('    restore_fixture_main($argv);')]
        with tempfile.TemporaryDirectory(prefix='restore-php-handler-') as td:
            script = Path(td) / 'handler.php'
            # Actual terminal handler; only observation functions are explicit
            # throwing/no-op adapters. Native main and installed PHP never run.
            script.write_text("<?php function restore_fixture_failure_record(...$args){return false;}"
                "function restore_fixture_php_failure_record(...$args){throw new RuntimeException('"+PRIVATE+"');}"
                + handler + "throw new RuntimeException('"+PRIVATE+"');")
            result = subprocess.run([PHP, str(script), 'snapshot', str(Path(td) / 'input.json')], capture_output=True, timeout=10)
            self.assertEqual(1, result.returncode)
            self.assertEqual(b'', result.stdout)
            self.assertEqual(b'Private Windows restore qualification fixture failed.\n', result.stderr)

    def test_php_writer_scope_types_and_original_handler(self):
        with tempfile.TemporaryDirectory(prefix='restore-php-observer-') as td:
            root = Path(td); instance = self.instance(root); script = root / 'scope.php'
            script.write_text("<?php define('OPENWEB_RESTORE_FIXTURE_LIBRARY_ONLY',true);require $argv[1];"
                "$e=new RuntimeException('"+PRIVATE+"');"
                "$ok=restore_fixture_php_failure_record($e,$argv[2],$argv[3],$argv[4]);echo json_encode(['written'=>$ok]);")
            def run(path, action, boundary=root):
                r = subprocess.run([PHP, str(script), str(HERE / 'windows-restore-qualification.php'), str(path), action, str(boundary)], capture_output=True, timeout=10)
                self.assertEqual(0, r.returncode); self.assertNotIn(PRIVATE, r.stdout.decode()+r.stderr.decode())
                return json.loads(r.stdout)['written']
            self.assertFalse(run(instance.path, '../private'))
            self.assertFalse(run(instance.path, 'snapshot', root / 'absent'))
            invalid = instance.work / 'other.json'; invalid.write_text('{}')
            self.assertFalse(run(invalid, 'snapshot'))
            link = instance.work / 'linked.json'; link.symlink_to(instance.path)
            self.assertFalse(run(link, 'snapshot'))
            self.assertTrue(run(instance.path, 'snapshot'))
            out = json.loads(Path(str(instance.path)+'.snapshot.php.failure.json').read_text())
            self.assertEqual('external_component', out['source_basename'])
            self.assertNotIn(PRIVATE, json.dumps(out)); self.assertNotIn(str(root), json.dumps(out))
        source = (HERE / 'windows-restore-qualification.php').read_text()
        handler = source[source.index('    set_exception_handler('):]
        self.assertIn('try{restore_fixture_php_failure_record(', handler)
        self.assertIn(');}catch(Throwable $ignored){}', handler)
        self.assertIn('fwrite(STDERR,"Private Windows restore qualification fixture failed.\\n");exit(1);', handler)


if __name__ == '__main__': unittest.main()
