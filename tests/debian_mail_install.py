#!/usr/bin/env python3
"""Exercise real unit files with a controlled service manager, never production."""
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mail_install', Path(__file__).resolve().parents[1]/'packaging/debian/install-mail.py')
mail = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mail)


class MailInstall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.calls = []
        self.enabled = True
        self.patches = [patch.object(mail, 'UNIT', self.root/'units/email_queue.service'),
                        patch.object(mail, 'LINK', self.root/'units/multi-user.target.wants/email_queue.service'),
                        patch.object(mail, 'HOLD', self.root/'restore/hold-email_queue.service'),
                        patch.object(mail.os, 'geteuid', return_value=0),
                        patch.object(mail.subprocess, 'check_output', return_value='not-found\n'),
                        patch.object(mail.subprocess, 'run', side_effect=self.run_command)]
        for item in self.patches:
            item.start()

    def run_command(self, args, **kwargs):
        self.calls.append(args)
        if 'is-enabled' in args:
            return SimpleNamespace(returncode=0 if self.enabled else 1)
        if 'enable' in args:
            mail.LINK.parent.mkdir(parents=True, exist_ok=True)
            mail.LINK.symlink_to(mail.UNIT)
        return SimpleNamespace(returncode=0)

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.tmp.cleanup()

    def test_stage_has_absent_recovery_targets_and_never_starts(self):
        targets = mail.targets()
        self.assertEqual(set(targets), {mail.UNIT, mail.LINK})
        mail.install()
        self.assertEqual(mail.UNIT.read_text(), mail.CONTENT)
        self.assertEqual(mail.UNIT.stat().st_mode & 0o777, 0o644)
        self.assertTrue(mail.LINK.is_symlink())
        self.assertFalse(any('start' in args for args in self.calls))
        # Older recovery can remove exactly the new unit and enablement link.
        for path in reversed(targets):
            path.unlink()
        self.assertFalse(mail.UNIT.exists())
        self.assertFalse(mail.LINK.is_symlink())

    def test_activate_is_idle_restore_gated(self):
        mail.HOLD.parent.mkdir()
        mail.HOLD.write_text('held')
        mail.install(True)
        self.assertFalse(any('start' in args for args in self.calls))
        mail.HOLD.unlink()
        mail.install(True)
        self.assertIn(['systemctl', 'start', 'email_queue.service'], self.calls)

    def test_existing_custom_unit_and_disabled_choice_preserved(self):
        mail.UNIT.parent.mkdir()
        mail.UNIT.write_text('administrator unit\n')
        before = mail.UNIT.stat()
        mail.install(True)
        self.assertEqual(mail.UNIT.read_text(), 'administrator unit\n')
        self.assertEqual(mail.UNIT.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.calls, [])

    def test_existing_managed_but_disabled_unit_stays_stopped(self):
        mail.UNIT.parent.mkdir()
        mail.UNIT.write_text(mail.CONTENT)
        self.enabled = False
        mail.install(True)
        self.assertFalse(any('enable' in args or 'start' in args for args in self.calls))

    def test_repeated_install_keeps_original_unit(self):
        mail.install()
        before = mail.UNIT.stat()
        self.calls.clear()
        mail.install()
        self.assertEqual(before.st_mtime_ns, mail.UNIT.stat().st_mtime_ns)
        self.assertFalse(any('enable' in args for args in self.calls))

    def test_vendor_unit_is_preserved(self):
        with patch.object(mail.subprocess, 'check_output', return_value='loaded\n'):
            mail.install(True)
        self.assertFalse(mail.UNIT.exists())
        self.assertEqual(self.calls, [])

    def test_linked_unit_refuses_without_mutation(self):
        mail.UNIT.parent.mkdir()
        original = self.root/'original'
        original.write_text('keep')
        mail.UNIT.symlink_to(original)
        with self.assertRaises(ValueError):
            mail.install(True)
        self.assertEqual(original.read_text(), 'keep')
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
