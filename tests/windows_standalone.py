#!/usr/bin/env python3
"""Full Windows installer integrity and its read-only preflight contract."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


contract = module('windows_standalone_contract', ROOT / 'packaging/release_contract.py')
preflight = module('windows_standalone_check', ROOT / 'packaging/windows/Windows-InstallationCheck.py')


class WindowsStandalone(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='openweb-windows-full-')
        self.package = Path(self.temporary.name) / 'release package'
        self.package.mkdir()
        self.version = '1.0.27'
        for name in contract.COMMON_FILES | contract.WINDOWS_FILES:
            path = self.package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(self.version + '\n' if name in {'VERSION', 'web/VERSION'} else 'Fixture data\n')
        shutil.copyfile(ROOT / 'packaging/release_contract.py', self.package / 'release_contract.py')
        self.description = contract.contract(self.version, 'windows')
        self.save_contract()

    def tearDown(self):
        self.temporary.cleanup()

    def seal(self):
        files = {path.relative_to(self.package).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in self.package.rglob('*') if path.is_file() and path.name != 'release-manifest.json'}
        (self.package / 'release-manifest.json').write_text(json.dumps({'version': self.version, 'files': files}))

    def save_contract(self):
        (self.package / 'installation.json').write_text(json.dumps(self.description))
        self.seal()

    def test_complete_installer_without_prior_pbx_is_readonly(self):
        before = {str(p): (p.read_bytes(), p.stat().st_mode) for p in self.package.rglob('*') if p.is_file()}
        result = preflight.validate_package(self.package)
        self.assertIs(result['previous_installation_required'], False)
        self.assertEqual(result['package_type'], 'full')
        self.assertEqual(result['database'], {'engine': 'postgresql', 'location': 'local', 'setup': 'automatic'})
        self.assertEqual(before, {str(p): (p.read_bytes(), p.stat().st_mode) for p in self.package.rglob('*') if p.is_file()})
        self.assertFalse((self.package / '__pycache__').exists())

    def test_patch_or_prior_installation_dependency_refused(self):
        for key, value in [('package_type', 'patch'), ('previous_installation_required', True),
                           ('minimum_installed_version', '1.0.23'), ('schema', True),
                           ('platform', 'debian13-amd64')]:
            with self.subTest(field=key):
                self.description = contract.contract(self.version, 'windows')
                self.description[key] = value
                self.save_contract()
                with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_missing_required_windows_component_refused_even_if_resealed(self):
        for name in ['updater/OpenWebPbx.Updater.exe', 'desktop/OpenWebPbx.Desktop.exe',
                     'backup-runtime/python.exe', 'engine/native-manifest.json', 'acme/wacs.exe',
                     'Install-Reseller.ps1', 'Check-Installation.ps1', 'Windows-InstallationCheck.py']:
            with self.subTest(component=name):
                path = self.package / name
                original = path.read_bytes()
                path.unlink()
                self.seal()
                with self.assertRaises(ValueError): preflight.validate_package(self.package)
                path.write_bytes(original)
                self.seal()

    def test_modified_file_refused(self):
        (self.package / 'Install-OpenWebPBX.ps1').write_text('modified')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_unlisted_file_refused(self):
        (self.package / 'desktop/server.json').write_text('{}')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_contract_code_never_imported_before_hash_verification(self):
        sentinel = Path(self.temporary.name) / 'must-not-exist'
        (self.package / 'release_contract.py').write_text('from pathlib import Path\nPath(' + repr(str(sentinel)) + ').touch()\n')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)
        self.assertFalse(sentinel.exists())

    def test_manifest_duplicates_and_case_aliases_refused(self):
        for text in ['{"version":"1.0.27","version":"1.0.27","files":{}}',
                     '{"version":"1.0.27","VERSION":"1.0.27","files":{}}',
                     '{"version":"1.0.27","files":{"web/a":"a","web/A":"a"}}']:
            (self.package / 'release-manifest.json').write_text(text)
            with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_unsafe_windows_name_refused_even_if_resealed(self):
        for name in ['CON.txt', 'named.', 'named ', 'a:b', 'named?', 'bad\\name']:
            with self.subTest(name=name):
                target = self.package / name
                target.write_text('fixture')
                self.seal()
                with self.assertRaises(ValueError): preflight.validate_package(self.package)
                target.unlink()
        self.seal()

    def test_symlink_component_refused(self):
        target = self.package / 'updater/OpenWebPbx.Updater.exe'
        target.unlink()
        target.symlink_to(self.package / 'VERSION')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_hardlink_component_refused(self):
        target = self.package / 'updater/OpenWebPbx.Updater.exe'
        target.unlink()
        target.hardlink_to(self.package / 'VERSION')
        self.seal()
        with self.assertRaises(ValueError): preflight.validate_package(self.package)


if __name__ == '__main__': unittest.main()
