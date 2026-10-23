"""CLI/source controls only; actual PHP POST cases run after native PHP qualification."""
import ast
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
TARGET=ROOT/'tests/windows_smtp_notice.py'
spec=importlib.util.spec_from_file_location('smtp_notice_cli_subject',TARGET)
subject=importlib.util.module_from_spec(spec);spec.loader.exec_module(subject)


class SMTPCLIControls(unittest.TestCase):
    def test_explicit_unittest_selection(self):
        for selector in subject.SELECTORS:
            args=subject.parse_cli([selector]);self.assertEqual(args.selectors,[selector]);self.assertIsNone(args.php_executable)
        args=subject.parse_cli(['--php-executable',r'C:\OpenWebPBX\php\php.exe',subject.SELECTORS[1]])
        self.assertEqual(args.php_executable,r'C:\OpenWebPBX\php\php.exe');self.assertEqual(args.selectors,[subject.SELECTORS[1]])
        for values in [['wrong.test'],['--unknown'],['--php-executable']]:
            with self.subTest(values=values),contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):subject.parse_cli(values)

    def test_dom_cli_never_needs_php_or_ambient_path(self):
        env=os.environ.copy();env['PATH']='';env['PHPRC']='nonexistent-fictional-php-ini'
        result=subprocess.run([sys.executable,'-B',str(TARGET),subject.SELECTORS[0]],env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('Ran 1 test',result.stderr);self.assertNotIn('OK (skipped=',result.stderr)

    def test_missing_target_is_a_failure_not_a_skip(self):
        for selectors in [[subject.SELECTORS[1]],[]]:
            result=subprocess.run([sys.executable,'-B',str(TARGET),*selectors],capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0);self.assertNotIn('OK (skipped=',result.stderr)
            self.assertIn('--php-executable',result.stderr)

    def test_explicit_ordinary_target_refusals(self):
        for value in [None,'',1,False,'php','./php','missing-php.exe']:
            with self.subTest(value=value),self.assertRaises(ValueError):subject.required_php(value)
        with tempfile.TemporaryDirectory(prefix='openweb-smtp-cli-controls-')as directory:
            root=Path(directory);file=root/'explicit-php';file.write_bytes(b'inert target; never executed')
            with self.assertRaises(ValueError):subject.required_php(str(root))
            with self.assertRaises(ValueError):subject.required_php(str(root/'missing'))
            if os.name!='nt':
                self.assertEqual(subject.required_php(str(file)),str(file))
                link=root/'link';link.symlink_to(file)
                with self.assertRaises(ValueError):subject.required_php(str(link))
            else:
                with self.assertRaises(ValueError):subject.required_php(str(file))

    def test_only_installed_windows_target_is_recognised(self):
        for value in [r'C:\OpenWebPBX\php\php.exe','c:/openwebpbx/php/PHP.EXE']:
            self.assertTrue(subject.installed_windows_php(value))
        for value in [None,False,1,'php',r'C:OpenWebPBX\php\php.exe',r'C:\tools\php\php.exe',r'D:\OpenWebPBX\php\php.exe',r'C:\OpenWebPBX\php\..\php\php.exe',r'C:\OpenWebPBX\php\php-cgi.exe',r'\\remote\OpenWebPBX\php\php.exe']:
            with self.subTest(value=value):self.assertFalse(subject.installed_windows_php(value))

    def test_actual_version_invocation_preserves_ini_isolation_and_deadline(self):
        class Captured(Exception):pass
        with mock.patch.object(subject,'required_php',return_value='explicit-bound-php')as required, mock.patch.object(subject.subprocess,'run',side_effect=Captured)as run:
            with self.assertRaises(Captured):subject.SMTPNoticeControls('test_actual_php_post_notice_and_refusals').test_actual_php_post_notice_and_refusals()
        required.assert_called_once_with(subject.PHP_EXECUTABLE)
        self.assertEqual(run.call_args.args[0],['explicit-bound-php','-n','-r','echo PHP_VERSION;'])
        self.assertEqual(run.call_args.kwargs,{'capture_output':True,'text':True,'timeout':5})

    def test_actual_first_post_invocation_preserves_target_source_and_deadline(self):
        class Captured(Exception):pass
        version=subprocess.CompletedProcess([],0,'8.4.27','')
        with contextlib.redirect_stdout(io.StringIO()),mock.patch.object(subject,'required_php',return_value='explicit-bound-php'),mock.patch.object(subject.subprocess,'run',side_effect=[version,Captured])as run:
            with self.assertRaises(Captured):subject.SMTPNoticeControls('test_actual_php_post_notice_and_refusals').test_actual_php_post_notice_and_refusals()
        self.assertEqual(run.call_count,2)
        arguments=run.call_args.args[0]
        self.assertEqual(arguments[:2],['explicit-bound-php','-n']);self.assertEqual(Path(arguments[3]),ROOT/'app/smtp_settings/index.php')
        self.assertEqual(json.loads(arguments[4]),{'transport':'accepted'})
        self.assertEqual(run.call_args.kwargs,{'capture_output':True,'text':True,'timeout':10})

    def test_no_ambient_lookup_or_skip_decorators_remain(self):
        tree=ast.parse(TARGET.read_text())
        self.assertFalse(any(isinstance(node,ast.Call)and isinstance(node.func,ast.Attribute)and node.func.attr in {'which','skip','skipIf','skipUnless'}for node in ast.walk(tree)))


if __name__=='__main__':unittest.main()
