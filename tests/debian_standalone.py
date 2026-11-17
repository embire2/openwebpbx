#!/usr/bin/env python3
"""Full new-server packages have no earlier-PBX dependency and fail before writes."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


contract = module('standalone_contract', ROOT / 'packaging/release_contract.py')
preflight = module('standalone_preflight', ROOT / 'packaging/debian/install-check.py')


class StandaloneInstallation(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='openweb-standalone-')
        self.package = Path(self.temporary.name) / 'package'
        self.package.mkdir()
        self.version = '1.0.27'
        for name in contract.COMMON_FILES | contract.DEBIAN_FILES:
            path = self.package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(self.version + '\n' if name in {'VERSION', 'web/VERSION'} else 'Fixture data\n')
        shutil.copyfile(ROOT / 'packaging/release_contract.py', self.package / 'release_contract.py')
        for name in ['install.sh', 'server/OpenWebPbx.Server', 'updater/OpenWebPbx.Updater']:
            (self.package / name).chmod(0o755)
        self.description = contract.contract(self.version, 'debian')
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

    def test_clean_full_package_has_no_previous_installation_requirement(self):
        before = {str(p): (p.read_bytes(), p.stat().st_mode) for p in self.package.rglob('*') if p.is_file()}
        description = preflight.validate_package(self.package)
        self.assertIs(description['previous_installation_required'], False)
        self.assertEqual(description['package_type'], 'full')
        self.assertEqual(description['database'], {'engine': 'postgresql', 'location': 'local', 'setup': 'automatic'})
        self.assertEqual(before, {str(p): (p.read_bytes(), p.stat().st_mode) for p in self.package.rglob('*') if p.is_file()})
        self.assertFalse((self.package / '__pycache__').exists())

    def test_both_platforms_use_full_release_contracts(self):
        for platform in ['debian', 'windows']:
            description = contract.contract(self.version, platform)
            self.assertEqual(description['version'], self.version)
            self.assertIs(description['previous_installation_required'], False)
            self.assertEqual(description['package_type'], 'full')
        self.assertEqual(contract.contract(self.version, 'windows')['entrypoint'], 'Start-OpenWebPBX.cmd')

    def test_patch_label_refused_even_if_resealed(self):
        self.description['package_type'] = 'patch'
        self.save_contract()
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_previous_pbx_requirement_refused_even_if_resealed(self):
        self.description['previous_installation_required'] = True
        self.save_contract()
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_ambiguous_boolean_or_schema_types_refused(self):
        for key, value in [('schema', True), ('previous_installation_required', 0)]:
            with self.subTest(field=key):
                self.description = contract.contract(self.version, 'debian')
                self.description[key] = value
                self.save_contract()
                with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_previous_version_field_refused_even_if_resealed(self):
        self.description['minimum_installed_version'] = '1.0.22'
        self.save_contract()
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_foreign_platform_refused_even_if_resealed(self):
        self.description['platform'] = 'windows-x64'
        self.save_contract()
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_missing_component_refused_even_if_resealed(self):
        for name in ['updater/OpenWebPbx.Updater', 'engine.tar.gz', 'install-reseller.py', 'install-onboarding.py']:
            with self.subTest(component=name):
                target = self.package / name
                original = target.read_bytes()
                target.unlink()
                self.seal()
                with self.assertRaises(ValueError): preflight.validate_package(self.package)
                target.write_bytes(original)
                if name == 'updater/OpenWebPbx.Updater': target.chmod(0o755)
                self.seal()

    def test_modified_file_refused_before_installation(self):
        (self.package / 'configure.py').write_text('altered')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_contract_code_is_not_loaded_before_hash_check(self):
        sentinel = Path(self.temporary.name) / 'must-not-exist'
        (self.package / 'release_contract.py').write_text('from pathlib import Path\nPath(' + repr(str(sentinel)) + ').touch()\n')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)
        self.assertFalse(sentinel.exists())

    def test_unlisted_private_settings_refused(self):
        (self.package / 'server/runtime.json').write_text('{}')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_symlink_component_refused(self):
        target = self.package / 'engine.tar.gz'
        target.unlink()
        target.symlink_to(self.package / 'configure.py')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_missing_executable_mode_refused(self):
        (self.package / 'updater/OpenWebPbx.Updater').chmod(0o644)
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_duplicate_manifest_fields_refused(self):
        (self.package / 'release-manifest.json').write_text('{"version":"1.0.27","version":"1.0.27","files":{}}')
        with self.assertRaises(ValueError): preflight.validate_package(self.package)

    def test_help_never_runs_package_manager(self):
        fake_bin = Path(self.temporary.name) / 'bin'
        fake_bin.mkdir()
        sentinel = Path(self.temporary.name) / 'package-manager-called'
        apt = fake_bin / 'apt-get'
        apt.write_text('#!/bin/sh\ntouch ' + str(sentinel) + '\nexit 91\n')
        apt.chmod(0o755)
        result = subprocess.run(['bash', str(ROOT / 'packaging/debian/install.sh'), '--help'],
                                capture_output=True, text=True, env=os.environ | {'PATH': str(fake_bin) + ':' + os.environ['PATH']})
        self.assertEqual(result.returncode, 0)
        self.assertIn('full standalone installer', result.stdout)
        self.assertIn('No earlier OpenWeb PBX installation is required.', result.stdout)
        self.assertFalse(sentinel.exists())

    def test_combined_check_flag_fails_before_package_manager(self):
        fake_bin = Path(self.temporary.name) / 'bin'
        fake_bin.mkdir()
        sentinel = Path(self.temporary.name) / 'package-manager-called'
        apt = fake_bin / 'apt-get'
        apt.write_text('#!/bin/sh\ntouch ' + str(sentinel) + '\nexit 91\n')
        apt.chmod(0o755)
        for flags in [['--check', '--email', 'admin@example.com'], ['--email', 'admin@example.com', '--check']]:
            result = subprocess.run(['bash', str(ROOT / 'packaging/debian/install.sh'), *flags],
                                    capture_output=True, text=True, env=os.environ | {'PATH': str(fake_bin) + ':' + os.environ['PATH']})
            self.assertEqual(result.returncode, 1)
            self.assertIn('Use --check on its own', result.stderr)
            self.assertFalse(sentinel.exists())

    def test_no_arguments_show_setup_instructions_before_package_manager(self):
        result = subprocess.run(['bash', str(ROOT / 'packaging/debian/install.sh')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('full standalone installer', result.stdout)

    def python_preparation(self, *, available=False, readonly=False, update_result=0):
        source = (ROOT / 'packaging/debian/install.sh').read_text()
        function = re.search(r'^prepare_installer_python\(\) \{\n.*?^\}', source, re.M | re.S)
        self.assertIsNotNone(function)
        log = Path(self.temporary.name) / 'apt-actions'
        script = ('set -euo pipefail\n'
                  'check_only=' + ('true' if readonly else 'false') + '\n'
                  'installer_apt_updated=false\n'
                  'python_available=' + ('true' if available else 'false') + '\n'
                  'command() { if [[ "$*" == "-v python3" ]]; then [[ "$python_available" == true ]]; else builtin command "$@"; fi; }\n'
                  'apt-get() { printf "%s\\n" "$*" >> ' + repr(str(log)) + '; '
                  'if [[ "$1" == update ]]; then return ' + str(update_result) + '; fi; python_available=true; }\n'
                  + function.group() + '\nprepare_installer_python\n'
                  'printf "BOOTSTRAP_DONE=%s\\n" "$installer_apt_updated"\n')
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        return result, log.read_text().splitlines() if log.exists() else []

    def test_missing_os_python_is_prepared_automatically(self):
        result, actions = self.python_preparation()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(actions, ['update', 'install -y python3'])
        self.assertIn('BOOTSTRAP_DONE=true', result.stdout)

    def test_missing_python_readonly_check_never_installs_it(self):
        result, actions = self.python_preparation(readonly=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(actions, [])
        self.assertIn('normal installer prepares it automatically', result.stderr)
        self.assertNotIn('BOOTSTRAP_DONE', result.stdout)

    def test_existing_python_needs_no_extra_bootstrap(self):
        result, actions = self.python_preparation(available=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(actions, [])
        self.assertIn('BOOTSTRAP_DONE=false', result.stdout)

    def test_failed_python_preparation_stops_before_pbx_setup(self):
        result, actions = self.python_preparation(update_result=17)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(actions, ['update'])
        self.assertNotIn('BOOTSTRAP_DONE', result.stdout)


if __name__ == '__main__': unittest.main()
