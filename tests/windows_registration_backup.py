#!/usr/bin/env python3
"""Private real-file registration tests; never accesses installed tasks/services/DB."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'packaging/windows/backups.py'
spec = importlib.util.spec_from_file_location('registration_backup', SOURCE)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class RegistrationFiles(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='openweb-registration-backup-')
        self.root = Path(self.temporary.name)
        self.private = self.root / 'tenant-domains/private'
        self.private.mkdir(parents=True, mode=0o700)
        self.control_calls = []
        self.control_patch = patch.object(b, 'control', self.control)
        self.control_patch.start()
        if os.name == 'nt':
            self.control('secure', {'path': str(self.private), 'kind': 'private'})
        (self.private / 'image-onboarding').mkdir(mode=0o700)
        for name in b.REGISTRATION_FILES:
            path = self.private / name
            path.write_bytes(('owned source ' + name).encode())
            path.chmod(0o600)
        if os.name == 'nt':
            # Production creates these as SYSTEM / Tenant-Domains FilePrivate.
            # An SSH user's default owner is intentionally not a trusted owner.
            for path in [self.private / 'image-onboarding', *[self.private / name for name in b.REGISTRATION_FILES]]:
                self.control('secure', {'path': str(path), 'kind': 'private'})
        self.roots_patch = patch.object(b, 'ROOTS', {
            'runtime-config': self.root, 'registration-state': self.private,
            'fusionpbx-config': self.root / 'config', 'freeswitch-config': self.root / 'switch',
            'mobile-notifications': self.root / 'notifications'})
        self.roots_patch.start()

    def tearDown(self):
        self.roots_patch.stop()
        self.control_patch.stop()
        self.temporary.cleanup()

    def control(self, operation, value):
        self.control_calls.append((operation, value))
        if os.name != 'nt':
            return {}
        self.assertEqual(operation, 'secure')
        path = Path(value['path'])
        self.assertTrue(path.is_relative_to(self.root))
        self.assertEqual(value['kind'], 'private')
        script = r"""$ErrorActionPreference='Stop';$v=[Console]::In.ReadToEnd()|ConvertFrom-Json
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($v.source,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Control source parse refused'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'PrivateAcl'},$true));if($nodes.Count -ne 1){throw 'One actual PrivateAcl source required'}
function OrdinaryPath([string]$Path){if($Path -cne $v.path){throw 'Only owned fixture path allowed'};return $Path}
$private=$v.state;$config=Join-Path $v.state 'config';. ([scriptblock]::Create($nodes[0].Extent.Text));PrivateAcl $v.path 'private'
"""
        b.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
              input=json.dumps({'path': str(path), 'state': str(self.root), 'source': str(SOURCE.with_name('Backup-Control.ps1'))}).encode(), env=b.native_powershell_environment(), timeout=30)
        return {}

    def test_exact_private_members_and_cache_exclusions(self):
        cache = self.private / 'image-onboarding/setup.txt'
        cache.write_bytes(b'not an authority recovery member')
        with b.registration_guard(b.ROOTS):
            inventory = b.file_inventory({'registration-state': self.private})
        self.assertEqual(set(inventory), {'registration-state/' + name for name in b.REGISTRATION_FILES})
        self.assertTrue(all(item['sha256'] == hashlib.sha256(item['source'].read_bytes()).hexdigest() for item in inventory.values()))
        for name in inventory:
            self.assertEqual(b.restore_targets({'files': {name: {}}})[name], self.private / name.removeprefix('registration-state/'))
        for name in ('registration-state/setup.json', 'registration-state/image-onboarding/setup.txt',
                     'registration-state/image-onboarding/retry.json', 'registration-state/../image-local.json',
                     'registration-state/image-onboarding/session.json/extra', 'runtime-config/tenant-domains/private/image-local.json'):
            with self.subTest(name=name), self.assertRaises(b.BackupError):
                b.safe_member(name)

    def test_actual_consumer_lock_conflict_is_busy_and_keeps_source_bytes(self):
        before = {name: (self.private / name).read_bytes() for name in b.REGISTRATION_FILES}
        code = """import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('b',sys.argv[1]);b=importlib.util.module_from_spec(s);s.loader.exec_module(b)
try:
 with b.registration_guard({'registration-state':pathlib.Path(sys.argv[2])}):pass
except b.BackupBusy:print('BUSY');sys.exit(0)
sys.exit(7)
"""
        lock = os.open(self.private / 'image-onboarding/worker.lock', os.O_CREAT | os.O_RDWR, 0o600)
        if os.fstat(lock).st_size == 0:
            os.write(lock, b'\0')
        os.lseek(lock, 0, os.SEEK_SET)
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(lock, msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            result = subprocess.run([sys.executable, '-I', '-B', '-c', code, str(SOURCE), str(self.private)], capture_output=True, timeout=45)
        finally:
            os.close(lock)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, b'BUSY'), result.stderr.decode(errors='replace'))
        self.assertEqual(before, {name: (self.private / name).read_bytes() for name in b.REGISTRATION_FILES})

    def test_absent_session_directory_establishes_same_persistent_consumer_lock(self):
        session = self.private / 'image-onboarding/session.json';session.unlink();session.parent.rmdir()
        with b.registration_guard(b.ROOTS):
            lock = session.parent / 'worker.lock'
            self.assertTrue(lock.is_file())
            with self.assertRaises(b.BackupBusy):
                with b.registration_guard(b.ROOTS):
                    self.fail('An already prepared consumer must contend on the same new lock')
        self.assertTrue(lock.exists())
        self.assertFalse(session.exists())

    def test_invalid_root_refuses_before_creating_absent_consumer_directory(self):
        session=self.private/'image-onboarding/session.json';session.unlink();session.parent.rmdir()
        original=(self.private/'image-local.json').read_bytes()
        if os.name == 'nt':
            code="$p=[Console]::In.ReadToEnd();$a=Get-Acl -LiteralPath $p;$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-1-0',[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $p -AclObject $a"
            b.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',code],input=str(self.private).encode(),timeout=30)
        else:
            self.private.chmod(0o755)
        with self.assertRaises(b.BackupError):
            with b.registration_guard(b.ROOTS):self.fail('Invalid source root must refuse')
        self.assertFalse(session.parent.exists())
        self.assertEqual((self.private/'image-local.json').read_bytes(),original)

    def test_restore_recover_guard_before_any_database_or_cache_mutation(self):
        with patch.object(b, 'STORE', self.root / 'store'), patch.object(b, 'UPGRADE_LOCK', self.root / 'upgrade.lock'):
            with b.exclusive_guard(self.private / 'image-onboarding/worker.lock'):
                with patch.object(b, '_restore') as restore, patch.object(b, '_recover') as recover:
                    with self.assertRaises(b.BackupBusy):
                        b.restore(self.root / 'unused.owpbx', 'unused', {})
                    with self.assertRaises(b.BackupBusy):
                        b.recover({})
                    restore.assert_not_called();recover.assert_not_called()

    def test_private_acl_validation_refuses_broad_read_without_repair(self):
        path = self.private / 'image-local.json'
        before = path.read_bytes()
        if os.name == 'nt':
            script = r"""$p=[Console]::In.ReadToEnd();$a=Get-Acl -LiteralPath $p;$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-1-0',[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $p -AclObject $a"""
            b.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script], input=str(path).encode(), timeout=30)
        else:
            path.chmod(0o644)
        with self.assertRaises(b.BackupError):
            with b.registration_guard(b.ROOTS):
                self.fail('Unsafe source permissions admitted')
        self.assertEqual(path.read_bytes(), before)
        if os.name != 'nt':
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_private_acl_precedes_first_restored_byte_and_cache_list_is_exact(self):
        source = self.root / 'source.bin';source.write_bytes(b'actual private restore payload')
        target = self.private / 'image-onboarding/session.json'
        observed = []
        original = b.secure_acl
        def secure(path, **kwargs):
            if Path(path).name.startswith('.backup-restore-'):
                observed.append(Path(path).stat().st_size)
            return original(path, **kwargs)
        with patch.object(b, 'secure_acl', secure):
            b.atomic_copy(source, target, mode=0o600)
        self.assertEqual(observed, [0, len(source.read_bytes())])
        self.assertEqual(target.read_bytes(), source.read_bytes())
        b.registration_private([self.private, target], self.private)
        self.assertEqual(b.acl_kind(target), 'private')
        expected = ('instance-public.json', 'ready.json', 'setup.json', 'private/image-local.json',
                    'private/certificate-backoff.json', 'private/image-onboarding/session.json',
                    'private/image-onboarding/setup.txt', 'private/image-onboarding/retry.json')
        self.assertEqual(b.registration_restore_files(), tuple(self.private.parent / name for name in expected))
        self.assertNotIn(self.root.parent / 'OpenWebPBX-Installation/onboarding-required', b.registration_restore_files())

    @unittest.skipUnless(os.name == 'nt', 'Actual Windows owner/SDDL fixture only')
    def test_other_private_owner_unchanged_and_exact_P256_owner_is_privileged(self):
        def owner(path):
            return b.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
                          "$p=[Console]::In.ReadToEnd();(Get-Acl -LiteralPath $p).GetOwner([Security.Principal.SecurityIdentifier]).Value"], input=str(path).encode(), timeout=30).decode().strip()
        other=self.root/'unrelated-private.bin';other.write_bytes(b'owned unrelated private caller')
        before=owner(other);self.control('secure',{'path':str(other),'kind':'private'})
        self.assertEqual(owner(other),before)
        key=self.root/'config/tenant-domains-instance-key.pem';key.parent.mkdir()
        source=self.root/'owned-key-source';source.write_bytes(b'owned P256-key transfer witness')
        b.atomic_copy(source,key,mode=0o600)
        self.assertEqual(owner(key),'S-1-5-32-544')
        self.assertEqual(key.read_bytes(),source.read_bytes())


if __name__ == '__main__':
    unittest.main()
