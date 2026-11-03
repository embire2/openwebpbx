#!/usr/bin/env python3
"""Offline RSA fixtures for independent platform promotion; no release key use."""
import base64
import copy
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging/updates'))
from verify_feed import PLATFORMS, select_asset, verify

spec = importlib.util.spec_from_file_location('platform_release', ROOT / 'packaging/updates/platform-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PlatformReleaseChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='openweb-platform-promotion-')
        cls.root = Path(cls.temporary.name)
        cls.key, cls.public = cls.root / 'ephemeral-key.pem', cls.root / 'public.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048',
                        '-out', str(cls.key)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.key.chmod(0o600)
        subprocess.run(['openssl', 'pkey', '-in', str(cls.key), '-pubout', '-out', str(cls.public)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.now = dt.datetime(2026, 11, 3, tzinfo=dt.timezone.utc)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def payload(self, platform, version, sequence, *, version_code=1019):
        name = 'openwebpbx-' + version + '-' + PLATFORMS[platform]
        asset = {'platform': platform, 'name': name,
                 'url': 'https://github.com/embire2/openwebpbx/releases/download/v' + version + '/' + name,
                 'bytes': 1, 'sha256': '1' * 64}
        if platform == 'android-universal':
            asset.update(version_code=version_code, package_id='com.openweb.pbx', min_sdk=28,
                         minimum_server_version='1.0.20', certificate_sha256='4' * 64)
        else:
            asset['minimum_version'] = '1.0.21'
        return {'schema': 1, 'product': 'openwebpbx', 'channel': 'stable', 'version': version,
                'sequence': sequence, 'published_at': '2026-11-03T00:00:00Z',
                'expires_at': '2027-05-01T00:00:00Z', 'assets': [asset]}

    def signed(self, payload):
        raw = json.dumps(payload, separators=(',', ':')).encode()
        signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(self.key)],
                                   input=raw, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
        return json.dumps({'key_id': 'release-2026-a', 'payload': base64.b64encode(raw).decode(),
                           'signature': base64.b64encode(signature).decode()}).encode() + b'\n'

    def setUp(self):
        self.payloads = {
            'update-manifest.json': self.payload('android-universal', '1.0.19', 900),
            'debian-update-manifest.json': self.payload('debian13-amd64', '1.0.22', 5),
            'windows-update-manifest.json': self.payload('windows-x64', '1.0.22', 800),
        }
        self.before = {name: self.signed(value) for name, value in self.payloads.items()}
        self.after = dict(self.before)
        self.platform = 'debian13-amd64'
        self.next = self.payload(self.platform, '1.0.23', 6)
        self.promote()

    def promote(self):
        self.after[release.FEEDS[self.platform]] = self.signed(self.next)

    def validate(self):
        return release.validate(self.before, self.after, self.platform, self.public, now=self.now)

    def test_debian23_windows22_android19_with_independent_sequences_and_minima(self):
        result = self.validate()
        self.assertEqual([result['feeds'][name]['version'] for name in release.FEEDS.values()],
                         ['1.0.19', '1.0.23', '1.0.22'])
        self.assertEqual(result['feeds']['debian-update-manifest.json']['sequence'], 6)
        self.assertEqual(result['feeds']['windows-update-manifest.json']['sequence'], 800)
        self.assertEqual(result['feeds']['update-manifest.json']['minimum_server_version'], '1.0.20')
        self.assertEqual(result['feeds']['windows-update-manifest.json']['minimum_version'], '1.0.21')
        for name in ('update-manifest.json', 'windows-update-manifest.json'):
            self.assertTrue(result['feeds'][name]['retained_byte_exact'])
            self.assertEqual(result['feeds'][name]['envelope_sha256'], hashlib.sha256(self.before[name]).hexdigest())

    def test_windows_catches_up_without_releasing_other_platforms(self):
        self.platform = 'windows-x64'
        self.after = dict(self.before)
        self.next = self.payload(self.platform, '1.0.24', 901)
        self.promote()
        result = self.validate()
        self.assertEqual(result['feeds']['debian-update-manifest.json']['version'], '1.0.22')
        self.assertEqual(result['feeds']['windows-update-manifest.json']['version'], '1.0.24')

    def test_android_version_and_server_minimum_are_independent(self):
        self.platform = 'android-universal'
        self.after = dict(self.before)
        self.next = self.payload(self.platform, '1.0.20', 901, version_code=1020)
        self.next['assets'][0]['minimum_server_version'] = '1.0.21'
        self.promote()
        self.assertEqual(self.validate()['feeds']['update-manifest.json']['minimum_server_version'], '1.0.21')

    def test_retained_envelope_cannot_be_resigned_even_with_valid_new_metadata(self):
        for name in ('update-manifest.json', 'windows-update-manifest.json'):
            with self.subTest(name=name):
                value = copy.deepcopy(self.payloads[name])
                value['sequence'] += 1
                self.after = dict(self.before)
                self.promote()
                self.after[name] = self.signed(value)
                with self.assertRaisesRegex(ValueError, 'Another platform'):
                    self.validate()

    def test_even_retained_wrapper_whitespace_is_immutable(self):
        self.after['windows-update-manifest.json'] += b' '
        with self.assertRaisesRegex(ValueError, 'Another platform'):
            self.validate()

    def test_target_version_must_advance(self):
        for version in ('1.0.21', '1.0.22'):
            with self.subTest(version=version):
                self.next = self.payload(self.platform, version, 6)
                self.promote()
                with self.assertRaisesRegex(ValueError, 'own version'):
                    self.validate()

    def test_target_sequence_cannot_regress_or_conflict(self):
        for sequence in (4, 5):
            with self.subTest(sequence=sequence):
                self.next['sequence'] = sequence
                self.promote()
                with self.assertRaises(ValueError):
                    self.validate()

    def test_unchanged_target_is_not_a_new_promotion(self):
        self.after = dict(self.before)
        with self.assertRaisesRegex(ValueError, 'own version'):
            self.validate()

    def test_android_code_must_advance_independently(self):
        self.platform = 'android-universal'
        self.after = dict(self.before)
        for code in (1018, 1019):
            with self.subTest(code=code):
                self.next = self.payload(self.platform, '1.0.20', 901, version_code=code)
                self.promote()
                with self.assertRaisesRegex(ValueError, 'version code'):
                    self.validate()

    def test_candidate_cannot_promote_two_platforms_in_one_envelope(self):
        self.next['assets'] += self.payload('windows-x64', '1.0.23', 6)['assets']
        self.promote()
        with self.assertRaisesRegex(ValueError, 'only the selected'):
            self.validate()

    def test_legacy_generic_combination_can_be_retained_byte_exact(self):
        mixed = copy.deepcopy(self.payloads['update-manifest.json'])
        old_debian = self.payload('debian13-amd64', '1.0.19', 900)['assets'][0]
        old_debian['minimum_version'] = '1.0.16'
        mixed['assets'].append(old_debian)
        self.before['update-manifest.json'] = self.after['update-manifest.json'] = self.signed(mixed)
        self.assertTrue(self.validate()['other_signed_envelopes_byte_exact'])

    def test_retained_feed_must_serve_its_designated_platform(self):
        wrong = self.signed(self.payloads['debian-update-manifest.json'])
        self.before['windows-update-manifest.json'] = self.after['windows-update-manifest.json'] = wrong
        with self.assertRaisesRegex(ValueError, 'designated platform'):
            self.validate()

    def test_expired_retained_feed_is_not_silently_refreshed_or_waived(self):
        expired = copy.deepcopy(self.payloads['update-manifest.json'])
        expired.update(published_at='2026-05-01T00:00:00Z', expires_at='2026-11-02T00:00:00Z')
        self.before['update-manifest.json'] = self.after['update-manifest.json'] = self.signed(expired)
        with self.assertRaisesRegex(ValueError, 'expired'):
            self.validate()

    def test_expired_promoted_feed_is_refused(self):
        self.next.update(published_at='2026-05-01T00:00:00Z', expires_at='2026-11-02T00:00:00Z')
        self.promote()
        with self.assertRaisesRegex(ValueError, 'expired'):
            self.validate()

    def test_signature_tampering_is_refused(self):
        value = json.loads(self.after['debian-update-manifest.json'])
        value['payload'] = base64.b64encode(b'{}').decode()
        self.after['debian-update-manifest.json'] = json.dumps(value).encode()
        with self.assertRaisesRegex(ValueError, 'signature'):
            self.validate()

    def test_all_three_fixed_names_are_required(self):
        for feeds in (self.before, self.after):
            removed = feeds.pop('windows-update-manifest.json')
            with self.assertRaisesRegex(ValueError, 'all three'):
                self.validate()
            feeds['windows-update-manifest.json'] = removed

    def test_existing_selection_still_enforces_own_server_upgrade_floor(self):
        value, _ = verify(self.after['debian-update-manifest.json'], self.public, now=self.now)
        self.assertEqual(select_asset(value, self.platform, '1.0.22')['minimum_version'], '1.0.21')
        with self.assertRaisesRegex(ValueError, 'intermediate'):
            select_asset(value, self.platform, '1.0.20')

    def test_cli_checks_without_writing_either_feed_set(self):
        with tempfile.TemporaryDirectory(dir=self.root) as folder:
            root = Path(folder)
            now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
            def current(payload):
                payload = copy.deepcopy(payload)
                payload.update(published_at=now.strftime('%Y-%m-%dT%H:%M:%SZ'),
                               expires_at=(now + dt.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))
                return self.signed(payload)
            before = {name: current(value) for name, value in self.payloads.items()}
            after = dict(before)
            after['debian-update-manifest.json'] = current(self.next)
            for label, feeds in (('before', before), ('after', after)):
                (root / label).mkdir()
                for name, raw in feeds.items():
                    (root / label / name).write_bytes(raw)
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'packaging/updates/platform-release.py'),
                                     '--platform', self.platform, '--before', str(root / 'before'),
                                     '--after', str(root / 'after'), '--public-key', str(self.public)],
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(json.loads(result.stdout)['platform'], self.platform)
            self.assertEqual(release.read_feeds(root / 'before'), before)
            self.assertEqual(release.read_feeds(root / 'after'), after)


if __name__ == '__main__':
    unittest.main()
