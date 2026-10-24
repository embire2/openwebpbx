#!/usr/bin/env python3
"""Exercise split-platform signing, unchanged legacy discovery and full Windows manifests."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging/updates'))
from verify_feed import verify, select_asset
spec = importlib.util.spec_from_file_location('platform_feeds', ROOT / 'packaging/updates/validate-platform-feeds.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class PlatformFeedChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='openweb-platform-feeds-')
        cls.root = Path(cls.temp.name)
        cls.key, cls.public = cls.root / 'key.pem', cls.root / 'public.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(cls.key)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.key.chmod(0o600)
        subprocess.run(['openssl', 'pkey', '-in', str(cls.key), '-pubout', '-out', str(cls.public)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.debian = cls.root / 'openwebpbx-1.0.12-debian13-amd64.tar.gz'
        cls.android = cls.root / 'openwebpbx-1.0.12-android.apk'
        cls.debian.write_bytes(b'disposable Debian artifact')
        cls.android.write_bytes(b'disposable Android artifact')
        cls.generic = cls.root / 'update-manifest.json'
        result = cls.sign('1.0.12', '112', cls.generic, ['--debian', str(cls.debian), '--android', str(cls.android), '--android-version-code', '112', '--android-certificate-sha256', '4' * 64])
        if result.returncode:
            raise RuntimeError('The generic fixture signer failed.')
        cls.reference = cls.generic.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def sign(cls, version, sequence, output, options):
        return subprocess.run([sys.executable, str(ROOT / 'packaging/updates/sign-feed.py'), '--private-key', str(cls.key), '--public-key', str(cls.public), '--version', version, '--sequence', sequence, '--output', str(output)] + options, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def setUp(self):
        self.package = self.root / 'openwebpbx-1.0.13-windows-x64.zip'
        self.windows = self.root / 'windows-update-manifest.json'
        self.files = {p: b'fixture' for p in ['VERSION', 'bootstrap.php', 'Install-OpenWebPBX.ps1', 'Upgrade-OpenWebPBX.ps1', 'Install-Updater.ps1',
            'server/OpenWebPbx.Server.exe', 'updater/OpenWebPbx.Updater.exe', 'desktop/OpenWebPbx.Desktop.exe', 'web/resources/require.php',
            'web/resources/classes/pbx_phone_restore.php', 'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/auth_binding.lua',
            'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/contact_realms.lua']}
        self.files['VERSION'] = b'1.0.13\n'
        self.write_package()
        self.assertEqual(self.sign('1.0.13', '113', self.windows, ['--windows-only', '--windows', str(self.package)]).returncode, 0)
        self.payload, _ = verify(self.windows.read_bytes(), self.public)

    def write_package(self, extra=None, corrupt=None, manifest_bytes=None):
        prefix = 'openwebpbx-1.0.13-windows-x64/'
        with zipfile.ZipFile(self.package, 'w') as archive:
            for name, data in self.files.items():
                archive.writestr(prefix + name, b'changed' if name == corrupt else data)
            archive.writestr(prefix + 'release-manifest.json', manifest_bytes if manifest_bytes is not None else json.dumps({'version': '1.0.13', 'files': {k: hashlib.sha256(v).hexdigest() for k, v in self.files.items()}}))
            if extra:
                archive.writestr(prefix + extra, b'unlisted')

    def signed(self, payload):
        raw = json.dumps(payload, separators=(',', ':')).encode()
        signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(self.key)], input=raw, check=True, stdout=subprocess.PIPE).stdout
        return json.dumps({'key_id': 'release-2026-a', 'payload': base64.b64encode(raw).decode(), 'signature': base64.b64encode(signature).decode()}).encode()

    def validate(self, generic=None, windows=None):
        return validator.validate(self.reference if generic is None else generic, self.reference,
            self.windows.read_bytes() if windows is None else windows, self.public, self.package, generic_version='1.0.12', windows_version='1.0.13')

    def resigned_package(self):
        self.payload['assets'][0].update(bytes=self.package.stat().st_size, sha256=hashlib.sha256(self.package.read_bytes()).hexdigest())
        return self.signed(self.payload)

    def independent_feeds(self):
        android, _ = verify(self.reference, self.public)
        debian = json.loads(json.dumps(android))
        android['assets'] = [a for a in android['assets'] if a['platform'] == 'android-universal']
        debian.update(version='1.0.11', sequence=111)
        debian['assets'] = [a for a in debian['assets'] if a['platform'] == 'debian13-amd64']
        for asset in debian['assets']:
            asset['name'] = asset['name'].replace('1.0.12', '1.0.11')
            asset['url'] = asset['url'].replace('1.0.12', '1.0.11')
        return self.signed(android), self.signed(debian)

    def validate_independent(self, android, debian_envelope, **options):
        args = dict(generic_version='1.0.12', windows_version='1.0.13', debian=debian_envelope,
                    debian_reference=debian_envelope, debian_version='1.0.11')
        args.update(options)
        return validator.validate(android, android, self.windows.read_bytes(), self.public, self.package, **args)

    def test_real_split_signer_and_full_manifest(self):
        result = self.validate()
        self.assertTrue(result['generic_reference_byte_identical'])
        self.assertEqual(result['windows_manifest_files'], len(self.files))
        self.assertEqual(self.generic.read_bytes(), self.reference)

    def test_complete_manifest_larger_than_old_two_mib_limit(self):
        self.files.update({f'web/qualification-documents/{index:05d}/'+('x'*42)+'.txt': b'owned synthetic document'
                           for index in range(19000)})
        self.write_package()
        with zipfile.ZipFile(self.package) as archive:
            size = archive.getinfo('openwebpbx-1.0.13-windows-x64/release-manifest.json').file_size
        self.assertGreater(size, 2 * 1024**2)
        self.assertLess(size, 8 * 1024**2)
        result = self.validate(windows=self.resigned_package())
        self.assertEqual(result['windows_manifest_files'], len(self.files))

    def test_manifest_eight_mib_boundary_is_still_bounded(self):
        raw = json.dumps({'version': '1.0.13', 'files':
                         {k: hashlib.sha256(v).hexdigest() for k, v in self.files.items()}}).encode()
        self.write_package(manifest_bytes=raw+b' '*(8 * 1024**2-len(raw)))
        self.assertEqual(self.validate(windows=self.resigned_package())['windows_manifest_files'], len(self.files))
        self.write_package(manifest_bytes=raw+b' '*(8 * 1024**2+1-len(raw)))
        with self.assertRaisesRegex(ValueError, 'bounded file manifest'):
            self.validate(windows=self.resigned_package())

    def test_large_manifest_preserves_json_version_inventory_and_hash_refusals(self):
        document = {'version': '1.0.13', 'files':
                    {k: hashlib.sha256(v).hexdigest() for k, v in self.files.items()}}
        wrong_version = json.loads(json.dumps(document)); wrong_version['version'] = '1.0.12'
        wrong_hash = json.loads(json.dumps(document)); wrong_hash['files']['bootstrap.php'] = '0'*64
        missing = json.loads(json.dumps(document)); missing['files'].pop('bootstrap.php')
        valid = json.dumps(document).encode()
        cases = [(b'{invalid', 'Expecting'),
                 (valid[:-1]+b',"version":"1.0.13"}', 'duplicate fields'),
                 (json.dumps(wrong_version).encode(), 'complete file inventory'),
                 (json.dumps(missing).encode(), 'complete file inventory'),
                 (json.dumps(wrong_hash).encode(), 'manifest verification')]
        for raw, message in cases:
            with self.subTest(refusal=message):
                self.write_package(manifest_bytes=raw+b' '*(2 * 1024**2+128-len(raw)))
                with self.assertRaisesRegex(ValueError, message):
                    self.validate(windows=self.resigned_package())

    def test_legacy_generic_clients_keep_both_112_downloads(self):
        generic, _ = verify(self.reference, self.public)
        for platform in ('debian13-amd64', 'android-universal'):
            self.assertIn('/v1.0.12/', select_asset(generic, platform, '1.0.11', '1.0.12')['url'])
        self.assertEqual(select_asset(self.payload, 'windows-x64', '1.0.7', '1.0.13')['name'], self.package.name)

    def test_current_three_feeds_preserve_independent_releases(self):
        android, debian = self.independent_feeds()
        result = self.validate_independent(android, debian)
        self.assertTrue(result['generic_reference_byte_identical'])
        self.assertTrue(result['debian_reference_byte_identical'])
        self.assertEqual((result['generic_version'], result['debian_version'], result['windows_version']),
                         ('1.0.12', '1.0.11', '1.0.13'))
        linux, _ = verify(debian, self.public)
        self.assertIn('/v1.0.11/', select_asset(linux, 'debian13-amd64', '1.0.10')['url'])
        with self.assertRaisesRegex(ValueError, 'no package'):
            select_asset(verify(android, self.public)[0], 'debian13-amd64', '1.0.10')

    def test_android_only_feed_cannot_hide_missing_debian_discovery(self):
        android, debian = self.independent_feeds()
        with self.assertRaisesRegex(ValueError, 'Debian feed and reference'):
            validator.validate(android, android, self.windows.read_bytes(), self.public, self.package,
                               generic_version='1.0.12', windows_version='1.0.13')
        for missing in ('debian', 'debian_reference', 'debian_version'):
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'together'):
                self.validate_independent(android, debian, **{missing: None})

    def test_separate_debian_reference_and_version_cannot_change(self):
        android, debian = self.independent_feeds()
        altered, _ = verify(debian, self.public)
        altered['sequence'] = 112
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.validate_independent(android, debian, debian=self.signed(altered))
        with self.assertRaisesRegex(ValueError, 'published Debian'):
            self.validate_independent(android, debian, debian_version='1.0.12')

    def test_separate_debian_platform_and_signature_are_required(self):
        android, debian = self.independent_feeds()
        with self.assertRaisesRegex(ValueError, 'published Debian'):
            self.validate_independent(android, android, debian_version='1.0.12')
        invalid = debian.replace(b'release-2026-a', b'release-2026-b')
        with self.assertRaisesRegex(ValueError, 'not trusted'):
            self.validate_independent(android, invalid)

    def test_windows_sequence_advances_past_both_platforms(self):
        android, debian = self.independent_feeds()
        newer, _ = verify(debian, self.public)
        newer['sequence'] = 114
        with self.assertRaisesRegex(ValueError, 'advance'):
            self.validate_independent(android, self.signed(newer))

    def test_cli_accepts_three_immutable_feeds_and_refuses_partial_inputs(self):
        android, debian = self.independent_feeds()
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            directory = Path(directory)
            generic = directory / 'update-manifest.json'
            linux = directory / 'debian-update-manifest.json'
            generic.write_bytes(android)
            linux.write_bytes(debian)
            command = [sys.executable, str(ROOT / 'packaging/updates/validate-platform-feeds.py'),
                       '--generic', str(generic), '--generic-reference', str(generic),
                       '--windows', str(self.windows), '--windows-package', str(self.package),
                       '--public-key', str(self.public), '--generic-version', '1.0.12', '--windows-version', '1.0.13']
            full = command + ['--debian', str(linux), '--debian-reference', str(linux), '--debian-version', '1.0.11']
            result = subprocess.run(full, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertTrue(json.loads(result.stdout)['debian_reference_byte_identical'])
            result = subprocess.run(command + ['--debian', str(linux)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'together', result.stderr)
            self.assertEqual(generic.read_bytes(), android)
            self.assertEqual(linux.read_bytes(), debian)

    def test_windows_only_signer_refuses_generic_filename_without_overwriting(self):
        result = self.sign('1.0.13', '113', self.generic, ['--windows-only', '--windows', str(self.package)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.generic.read_bytes(), self.reference)

    def test_windows_only_signer_refuses_other_platforms(self):
        result = self.sign('1.0.13', '113', self.windows, ['--windows-only', '--windows', str(self.package), '--debian', str(self.debian)])
        self.assertNotEqual(result.returncode, 0)

    def test_windows_fixed_filename_requires_explicit_split(self):
        result = self.sign('1.0.13', '113', self.windows, ['--windows', str(self.package)])
        self.assertNotEqual(result.returncode, 0)

    def test_manual_legacy_envelope_keeps_automatic_feed_exact(self):
        automatic = self.windows.read_bytes()
        package = self.root / 'openwebpbx-1.0.20-windows-x64.zip'
        package.write_bytes(b'disposable manual transition artifact')
        manual = self.root / 'windows-legacy-transition-manifest.json'
        result = self.sign('1.0.20', '119', manual,
                           ['--legacy-windows-transition', '--windows', str(package)])
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        payload, _ = verify(manual.read_bytes(), self.public)
        asset = select_asset(payload, 'windows-x64', '1.0.6', '1.0.20')
        self.assertEqual(asset['minimum_version'], '1.0.3')
        self.assertEqual(asset['sha256'], hashlib.sha256(package.read_bytes()).hexdigest())
        self.assertEqual(self.windows.read_bytes(), automatic)
        self.assertEqual(self.generic.read_bytes(), self.reference)

    def test_manual_legacy_signer_cannot_overwrite_normal_feeds(self):
        package = self.root / 'openwebpbx-1.0.20-windows-x64.zip'
        package.write_bytes(b'disposable manual transition artifact')
        for output in (self.windows, self.generic, self.root / 'debian-update-manifest.json'):
            before = output.read_bytes() if output.exists() else None
            result = self.sign('1.0.20', '119', output,
                               ['--legacy-windows-transition', '--windows', str(package)])
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes() if output.exists() else None, before)

    def test_manual_legacy_signer_refuses_other_modes_versions_and_minima(self):
        manual = self.root / 'windows-legacy-transition-manifest.json'
        for version_value, extra in (
                ('1.0.13', ['--legacy-windows-transition']),
                ('1.0.20', []),
                ('1.0.20', ['--windows-only']),
                ('1.0.20', ['--legacy-windows-transition', '--windows-only']),
                ('1.0.20', ['--legacy-windows-transition', '--minimum-version', '1.0.20']),
                ('1.0.20', ['--legacy-windows-transition', '--debian', str(self.debian)])):
            package = self.root / f'openwebpbx-{version_value}-windows-x64.zip'
            package.write_bytes(b'disposable manual transition artifact')
            result = self.sign(version_value, '119', manual, extra + ['--windows', str(package)])
            self.assertNotEqual(result.returncode, 0)

    def test_current_windows_feed_requires_safe_installed_helper_floor(self):
        package = self.root / 'openwebpbx-1.0.20-windows-x64.zip'
        package.write_bytes(b'disposable current Windows artifact')
        automatic_before = self.windows.read_bytes()
        for extra in ([], ['--minimum-version', '1.0.3'], ['--minimum-version', '1.0.7'], ['--minimum-version', '1.0.19']):
            result = self.sign('1.0.20', '120', self.windows,
                               ['--windows-only', '--windows', str(package)] + extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.windows.read_bytes(), automatic_before)
        result = self.sign('1.0.20', '120', self.windows,
                           ['--windows-only', '--windows', str(package), '--minimum-version', '1.0.20'])
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        payload, _ = verify(self.windows.read_bytes(), self.public)
        self.assertEqual(payload['assets'][0]['minimum_version'], '1.0.20')
        with self.assertRaisesRegex(ValueError, 'intermediate'):
            select_asset(payload, 'windows-x64', '1.0.19', '1.0.20')

    def test_windows_only_artifact_cannot_replace_generic_without_split_flag(self):
        result = self.sign('1.0.13', '113', self.generic, ['--windows', str(self.package)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.generic.read_bytes(), self.reference)

    def test_even_valid_resigned_generic_bytes_cannot_replace_reference(self):
        generic, _ = verify(self.reference, self.public)
        generic['sequence'] = 114
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.validate(generic=self.signed(generic))

    def test_legacy_validator_rejects_mixed_version_asset_names(self):
        generic, _ = verify(self.reference, self.public)
        generic['version'] = '1.0.13'
        with self.assertRaisesRegex(ValueError, 'signed version'):
            verify(self.signed(generic), self.public)

    def test_windows_feed_cannot_drop_or_replace_generic_platforms(self):
        generic, _ = verify(self.reference, self.public)
        generic['assets'] = generic['assets'][:1]
        altered = self.signed(generic)
        with self.assertRaises(ValueError):
            validator.validate(altered, altered, self.windows.read_bytes(), self.public, self.package, generic_version='1.0.12', windows_version='1.0.13')

    def test_window_sequence_must_advance(self):
        self.payload['sequence'] = 112
        with self.assertRaisesRegex(ValueError, 'advance'):
            self.validate(windows=self.signed(self.payload))

    def test_signature_or_package_tampering_is_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(windows=self.windows.read_bytes().replace(b'release-2026-a', b'release-2026-b'))
        with self.package.open('ab') as stream:
            stream.write(b'changed')
        with self.assertRaises(ValueError):
            self.validate()

    def test_signed_archive_still_requires_exact_internal_member_hashes(self):
        self.write_package(corrupt='bootstrap.php')
        with self.assertRaisesRegex(ValueError, 'manifest verification'):
            self.validate(windows=self.resigned_package())

    def test_guarded_phone_dependencies_cannot_be_missing(self):
        self.files.pop('web/app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/auth_binding.lua')
        self.write_package()
        with self.assertRaisesRegex(ValueError, 'guarded phone'):
            self.validate(windows=self.resigned_package())

    def test_unlisted_case_colliding_or_traversing_members_are_rejected(self):
        for path in ('unlisted', 'version', '../escape'):
            with self.subTest(path=path):
                self.write_package(extra=path)
                with self.assertRaises(ValueError):
                    self.validate(windows=self.resigned_package())


if __name__ == '__main__':
    unittest.main()
