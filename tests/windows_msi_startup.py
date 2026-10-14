#!/usr/bin/env python3
"""Check exact MSI table selection for the isolated native startup control."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('extract_core', Path(__file__).resolve().parents[1] / 'packaging/freeswitch/extract-windows-core.py')
extractor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extractor)


class StartupSelection(unittest.TestCase):
    def setUp(self):
        self.components = {'core_component': 'core_directory', 'module_component': 'module_directory', 'foreign_component': 'foreign_directory'}
        self.files = [
            ['core', 'core_component', 'CORE|FreeSwitch.dll', '100'],
            ['apr', 'core_component', 'APR|libapr.dll', '100'],
            ['console', 'core_component', 'CONSOLE|FreeSwitchConsole.exe', '100'],
            ['foreign', 'foreign_component', 'unrelated.exe', '100'],
        ] + [[name, 'module_component', 'SHORT|' + name, '100'] for name in extractor.STARTUP_MODULES]

    def select(self, include=True):
        return extractor.selected_files(self.files, self.components, 'core_directory', include)

    def test_default_keeps_original_core_dependency_selection(self):
        self.assertEqual([relative for _, relative in self.select(False)], ['FreeSwitch.dll', 'libapr.dll'])

    def test_startup_adds_only_console_and_five_named_modules(self):
        self.assertEqual({relative for _, relative in self.select()},
                         {'FreeSwitch.dll', 'libapr.dll', 'FreeSwitchConsole.exe'} |
                         {'mod/' + name for name in extractor.STARTUP_MODULES})

    def test_missing_or_duplicate_required_file_is_refused(self):
        original = list(self.files)
        for name in ('FreeSwitchConsole.exe',) + extractor.STARTUP_MODULES:
            row = next(row for row in original if row[2].split('|')[-1] == name)
            for changed in ([entry for entry in original if entry is not row], original + [row]):
                self.files = changed
                with self.assertRaises(ValueError):
                    self.select()

    def test_console_cannot_come_from_an_unrelated_directory(self):
        self.files[2][1] = 'foreign_component'
        with self.assertRaises(ValueError):
            self.select()

    def test_support_modules_must_share_their_separate_directory(self):
        self.files[-1][1] = 'foreign_component'
        with self.assertRaises(ValueError):
            self.select()
        self.files[-1][1] = 'core_component'
        with self.assertRaises(ValueError):
            self.select()


if __name__ == '__main__':
    unittest.main()
