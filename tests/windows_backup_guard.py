#!/usr/bin/env python3
"""Actual Windows/portable guard tests, isolated from every installed PBX path."""
import ast
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load_guard(source=None, *, legacy=False):
    path = Path(source) if source else ROOT / 'packaging/windows/backups.py'
    tree = ast.parse(path.read_text(encoding='utf-8'))
    names = {'BackupError', 'BackupBusy', 'reparse', 'windows_exclusive_guard',
             'exclusive_guard', 'lock_file', 'unlock_file'}
    if legacy:
        names -= {'BackupBusy', 'windows_exclusive_guard'}
    selected = [node for node in tree.body if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name in names]
    if {node.name for node in selected} != names:
        raise AssertionError('The exact guarded source functions are required.')
    module = types.ModuleType('tested_actual_backup_guard')
    module.__dict__.update(Path=Path, os=os, contextlib=contextlib)
    if os.name == 'nt':
        import msvcrt
        module.msvcrt = msvcrt
    else:
        import fcntl
        module.fcntl = fcntl
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), 'exec'), module.__dict__)
    return module


class GuardControls(unittest.TestCase):
    def setUp(self):
        self.module = load_guard(os.environ.get('OPENWEB_TEST_BACKUP_SOURCE'))
        self.temporary = tempfile.TemporaryDirectory(prefix='openweb-native-guard-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.path = self.root / 'operation.lock'
        self.path.write_bytes(b'existing lock bytes are preserved')

    def test_body_exception_preserved_and_exact_bytes_reusable(self):
        original = ValueError('original guarded failure')
        with self.assertRaises(ValueError) as raised:
            with self.module.exclusive_guard(self.path):
                raise original
        self.assertIs(raised.exception, original)
        with self.module.exclusive_guard(self.path):
            # Windows byte-range locks deliberately reject a second read handle
            # over the held byte, including one opened by the same process.
            self.assertTrue(self.path.is_file())
        self.assertEqual(self.path.read_bytes(), b'existing lock bytes are preserved')

    def test_second_actual_process_is_typed_busy_and_then_released(self):
        source = os.environ.get('OPENWEB_TEST_BACKUP_SOURCE', str(ROOT / 'packaging/windows/backups.py'))
        with self.module.exclusive_guard(self.path):
            result = subprocess.run([sys.executable, '-I', '-B', str(Path(__file__).resolve()),
                                     '--child', source, str(self.path), 'busy'], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {'state': 'busy', 'type': 'BackupBusy'})
        result = subprocess.run([sys.executable, '-I', '-B', str(Path(__file__).resolve()),
                                 '--child', source, str(self.path), 'free'], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'state': 'free'})

    def test_missing_parent_and_directory_are_refused_not_busy(self):
        for path in (self.root / 'missing' / 'lock', self.root):
            with self.subTest(path=path.name):
                with self.assertRaises(self.module.BackupError) as raised:
                    with self.module.exclusive_guard(path):
                        self.fail('Invalid lock was acquired.')
                self.assertNotIsInstance(raised.exception, self.module.BackupBusy)

    def test_creates_absent_ordinary_lock_and_releases(self):
        path = self.root / 'new.lock'
        with self.module.exclusive_guard(path):
            self.assertTrue(path.is_file())
            self.assertEqual(path.stat().st_size, 0)
        with self.module.exclusive_guard(path):
            pass

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows Python/Common external maintenance contract')
    def test_actual_call_records_common_accepts_python_parent_lock(self):
        state = self.root / 'common-contract'
        state.mkdir()
        path = state / 'upgrade.lock'
        original = b'owned cross-language lock bytes'
        path.write_bytes(original)
        script = self.root / 'common-contract.ps1'
        script.write_text(r'''
param([string]$SourceRoot,[string]$StateRoot)
$ErrorActionPreference='Stop'
foreach($file in 'UpgradeRecovery.Common.ps1','CallRecords.Common.ps1'){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('packaging/windows/'+$file)),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The actual Common source must parse.'}
 $required=if($file -ceq 'UpgradeRecovery.Common.ps1'){@('Initialize-OpenWebUpgradeRecoveryNative','Assert-OpenWebRecoveryOrdinary')}else{@('Assert-OpenWebCallRecordLock')}
 foreach($name in $required){
  $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
  if($nodes.Count -ne 1){throw 'The actual Common definition must be unique.'}
  . ([scriptblock]::Create($nodes[0].Extent.Text))
 }
}
Initialize-OpenWebUpgradeRecoveryNative
$exclusive=[OpenWebPbx.UpgradeRecoveryNativeV1]::Exclusive((Join-Path $StateRoot 'upgrade.lock'))
$accepted=$false;$refusal='none'
try{Assert-OpenWebCallRecordLock -StateRoot $StateRoot -ExternalLockHeld;$accepted=$true}catch{
 if($_.Exception.Message -cne 'The call-record controller requires its parent exclusive maintenance lock.'){throw}
 $refusal='parent_not_exclusive'
}
[Console]::Out.WriteLine((@{schema=1;exclusive=[bool]$exclusive;external_assertion_accepted=[bool]$accepted;refusal=$refusal}|ConvertTo-Json -Compress))
''', encoding='utf-8')
        command = [str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'),
                   '-NoProfile', '-NonInteractive', '-File', str(script), '-SourceRoot', str(ROOT), '-StateRoot', str(state)]
        def observe():
            result = subprocess.run(command, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr.strip(), b'')
            return json.loads(result.stdout.decode('utf-8-sig'))
        with self.module.exclusive_guard(path):
            self.assertEqual(observe(), {'schema': 1, 'exclusive': True,
                                         'external_assertion_accepted': True, 'refusal': 'none'})
        self.assertEqual(observe(), {'schema': 1, 'exclusive': False,
                                     'external_assertion_accepted': False, 'refusal': 'parent_not_exclusive'})
        self.assertEqual(path.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows native sharing and ACL controls')
    def test_dotnet_fileshare_none_is_typed_busy_and_released(self):
        import base64
        source = os.environ.get('OPENWEB_TEST_BACKUP_SOURCE', str(ROOT / 'packaging/windows/backups.py'))
        ready = self.root / 'dotnet-ready';release = self.root / 'dotnet-release'
        quoted = lambda value: "'" + str(value).replace("'", "''") + "'"
        script = ("$ErrorActionPreference='Stop';$h=[IO.File]::Open("+quoted(self.path)+",'Open','ReadWrite','None');"
                  "try{[IO.File]::WriteAllText("+quoted(ready)+",'ready');$until=[DateTime]::UtcNow.AddSeconds(15);"
                  "while(!(Test-Path -LiteralPath "+quoted(release)+") -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 20}}finally{$h.Dispose()}")
        command = [str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'),
                   '-NoProfile', '-NonInteractive', '-EncodedCommand', base64.b64encode(script.encode('utf-16le')).decode()]
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            until = time.monotonic() + 10
            while not ready.exists() and child.poll() is None and time.monotonic() < until:
                time.sleep(.02)
            self.assertTrue(ready.exists(), 'The owned .NET lock holder did not become ready.')
            with self.assertRaises(self.module.BackupBusy):
                with self.module.exclusive_guard(self.path):
                    self.fail('A real .NET exclusive holder was ignored.')
            legacy_source = os.environ.get('OPENWEB_TEST_LEGACY_GUARD_SOURCE')
            if legacy_source:
                legacy = load_guard(legacy_source, legacy=True)
                with self.assertRaises(legacy.BackupError) as original:
                    with legacy.exclusive_guard(self.path):
                        self.fail('The old actual guard failed to refuse the held .NET handle.')
                self.assertIs(type(original.exception), legacy.BackupError)
                self.assertEqual(str(original.exception), 'Another backup, restore or release update is running. Retry after it finishes.')
            release.write_text('release')
            stdout, stderr = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0, stderr)
            with self.module.exclusive_guard(self.path):
                pass
        finally:
            release.write_text('release')
            if child.poll() is None:
                child.kill();child.communicate(timeout=5)

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows nonmutating observation handle')
    def test_native_existing_only_never_creates_a_missing_lock(self):
        path = self.root / 'not-created.lock'
        with self.assertRaises(self.module.BackupError) as raised:
            with self.module.windows_exclusive_guard(path, existing_only=True):
                self.fail('A missing observed lock was recreated.')
        self.assertNotIsInstance(raised.exception, self.module.BackupBusy)
        self.assertFalse(path.exists())
        with self.module.windows_exclusive_guard(self.path, existing_only=True):
            pass
        self.assertEqual(self.path.read_bytes(), b'existing lock bytes are preserved')

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows CRT byte-range interoperability')
    def test_legacy_crt_range_holder_is_typed_busy(self):
        with self.path.open('r+b') as holder:
            self.module.lock_file(holder)
            try:
                with self.assertRaises(self.module.BackupBusy):
                    with self.module.exclusive_guard(self.path):
                        self.fail('The previous native CRT lock was ignored.')
            finally:
                self.module.unlock_file(holder)
        with self.module.exclusive_guard(self.path):
            pass

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows access-control denial classification')
    def test_native_acl_denial_is_refused_not_busy(self):
        import csv
        identity = subprocess.check_output(['whoami.exe', '/user', '/fo', 'csv', '/nh'], timeout=5).decode('utf-8')
        sid = next(csv.reader([identity.strip()]))[1]
        self.assertRegex(sid, r'^S-1-5-[0-9-]+$')
        denied = subprocess.run(['icacls.exe', str(self.path), '/deny', '*'+sid+':(RD,WD,AD)'], capture_output=True, timeout=5)
        self.assertEqual(denied.returncode, 0, denied.stderr)
        try:
            with self.assertRaises(self.module.BackupError) as raised:
                with self.module.exclusive_guard(self.path):
                    self.fail('The exact native access-control denial was not refused.')
            self.assertNotIsInstance(raised.exception, self.module.BackupBusy)
            legacy_source = os.environ.get('OPENWEB_TEST_LEGACY_GUARD_SOURCE')
            if legacy_source:
                legacy = load_guard(legacy_source, legacy=True)
                with self.assertRaises(legacy.BackupError) as original:
                    with legacy.exclusive_guard(self.path):
                        self.fail('The old actual guard failed to refuse denied access.')
                self.assertIs(type(original.exception), legacy.BackupError)
                # Old code reported the same busy message for an actual ACL
                # denial; the new native guard explicitly requires review.
                self.assertEqual(str(original.exception), 'Another backup, restore or release update is running. Retry after it finishes.')
                self.assertEqual(str(raised.exception), 'The operation lock needs administrator review.')
        finally:
            restored = subprocess.run(['icacls.exe', str(self.path), '/remove:d', '*'+sid], capture_output=True, timeout=5)
            self.assertEqual(restored.returncode, 0, restored.stderr)

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows access-denied classification')
    def test_native_readonly_denial_is_refused_not_busy(self):
        import stat
        self.path.chmod(stat.S_IREAD)
        try:
            with self.assertRaises(self.module.BackupError) as raised:
                with self.module.exclusive_guard(self.path):
                    self.fail('Read-only native access was not refused.')
            self.assertNotIsInstance(raised.exception, self.module.BackupBusy)
        finally:
            self.path.chmod(stat.S_IWRITE | stat.S_IREAD)

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows single-link lock validation')
    def test_native_hardlink_refused_not_busy(self):
        alias = self.root / 'alias.lock';os.link(self.path, alias)
        try:
            with self.assertRaises(self.module.BackupError) as raised:
                with self.module.exclusive_guard(self.path):
                    self.fail('A hard-linked native lock was not refused.')
            self.assertNotIsInstance(raised.exception, self.module.BackupBusy)
        finally:
            alias.unlink()

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows reparse validation')
    def test_native_junction_parent_refused_not_busy(self):
        target = self.root / 'target';target.mkdir();link = self.root / 'junction'
        result = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), str(target)], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        try:
            with self.assertRaises(self.module.BackupError) as raised:
                with self.module.exclusive_guard(link / 'operation.lock'):
                    self.fail('A junction parent was not refused.')
            self.assertNotIsInstance(raised.exception, self.module.BackupBusy)
        finally:
            link.rmdir()


if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == '--child':
        module = load_guard(sys.argv[2]);expected = sys.argv[4]
        try:
            with module.exclusive_guard(Path(sys.argv[3])):
                assert expected == 'free', 'An actual competing lock was not refused.'
                print(json.dumps({'state': 'free'}))
        except module.BackupBusy as error:
            assert expected == 'busy'
            assert type(error) is module.BackupBusy
            print(json.dumps({'state': 'busy', 'type': type(error).__name__}))
    else:
        unittest.main()
