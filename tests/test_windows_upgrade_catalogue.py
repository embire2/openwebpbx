#!/usr/bin/env python3
"""Exercise Windows path construction with disposable, genuinely signed feeds."""
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
spec = importlib.util.spec_from_file_location(
    'sign_windows_upgrade_path', ROOT / 'packaging/updates/sign-windows-upgrade-path.py')
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


class WindowsUpgradeCatalogueChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='openweb-windows-path-checks-')
        cls.directory = Path(cls.temp.name)
        cls.key = cls.directory / 'test-only-private.pem'
        cls.public = cls.directory / 'test-only-public.pem'
        subprocess.run(
            ['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt',
             'rsa_keygen_bits:2048', '-out', str(cls.key)], check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.key.chmod(0o600)
        subprocess.run(
            ['openssl', 'pkey', '-in', str(cls.key), '-pubout', '-out', str(cls.public)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.now = dt.datetime(2026, 11, 16, 12, 0, tzinfo=dt.timezone.utc)
        self.first_payload = self.release('1.0.22', '1.0.21', 122)
        self.latest_payload = self.release('1.0.23', '1.0.22', 123)
        self.first = self.signed(self.first_payload)
        self.latest = self.signed(self.latest_payload)

    def release(self, version, minimum, sequence, platform='windows-x64'):
        suffix = 'windows-x64.zip' if platform == 'windows-x64' else 'debian13-amd64.tar.gz'
        name = f'openwebpbx-{version}-{suffix}'
        return {
            'schema': 1, 'product': 'openwebpbx', 'channel': 'stable',
            'version': version, 'sequence': sequence,
            'published_at': '2026-11-15T12:00:00Z',
            'expires_at': '2026-12-16T12:00:00Z',
            'assets': [{'platform': platform, 'name': name,
                        'url': f'https://github.com/embire2/openwebpbx/releases/download/v{version}/{name}',
                        'bytes': 100, 'sha256': 'a' * 64, 'minimum_version': minimum}],
        }

    def signed(self, payload):
        raw = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        signature = subprocess.run(
            ['openssl', 'dgst', '-sha256', '-sign', str(self.key)],
            input=raw, check=True, capture_output=True).stdout
        return json.dumps({'key_id': 'release-2026-a', 'payload': base64.b64encode(raw).decode(),
                           'signature': base64.b64encode(signature).decode()},
                          separators=(',', ':')).encode()

    def build(self, *, latest=None, steps=None, minimum='1.0.21', sequence=501, days=180):
        return signer.build(minimum, self.latest if latest is None else latest,
                            [self.first, self.latest] if steps is None else steps,
                            self.public, sequence, now=self.now, days=days)

    def test_valid_21_to_22_to_23_binds_original_envelopes_and_latest_payload(self):
        original = (self.first, self.latest)
        result = self.build()
        self.assertEqual(result['kind'], 'windows-upgrade-path')
        self.assertEqual(result['minimum_installed_version'], '1.0.21')
        self.assertEqual(result['latest_version'], '1.0.23')
        self.assertEqual(result['latest_sequence'], 123)
        self.assertEqual(result['sequence'], 501)
        self.assertEqual(result['steps'], [
            {'previous_version': '1.0.21', 'version': '1.0.22',
             'envelope_sha256': hashlib.sha256(self.first).hexdigest()},
            {'previous_version': '1.0.22', 'version': '1.0.23',
             'envelope_sha256': hashlib.sha256(self.latest).hexdigest()},
        ])
        latest_payload = base64.b64decode(json.loads(self.latest)['payload'])
        self.assertEqual(result['latest_payload_sha256'], hashlib.sha256(latest_payload).hexdigest())
        self.assertEqual((self.first, self.latest), original)

    def test_20_can_follow_signed_21_22_23_steps(self):
        prior = self.signed(self.release('1.0.21', '1.0.20', 121))
        result = self.build(minimum='1.0.20', steps=[prior, self.first, self.latest])
        self.assertEqual([step['version'] for step in result['steps']],
                         ['1.0.21', '1.0.22', '1.0.23'])

    def test_wrong_order_and_repeated_steps_are_refused(self):
        for steps in ([self.latest, self.first, self.latest],
                      [self.first, self.first, self.latest]):
            with self.subTest(order=[hashlib.sha256(step).hexdigest() for step in steps]):
                with self.assertRaises(ValueError):
                    self.build(steps=steps)

    def test_original_minimum_is_not_lowered_for_a_historical_step(self):
        restrictive = self.signed(self.release('1.0.22', '1.0.22', 122))
        with self.assertRaisesRegex(ValueError, 'supported predecessor'):
            self.build(steps=[restrictive, self.latest])

    def test_latest_minimum_must_be_satisfied_by_actual_previous_step(self):
        restrictive = self.signed(self.release('1.0.23', '1.0.23', 123))
        with self.assertRaisesRegex(ValueError, 'supported predecessor'):
            self.build(latest=restrictive, steps=[self.first, restrictive])

    def test_other_platform_is_refused_in_latest_and_historical_steps(self):
        foreign = self.signed(self.release('1.0.22', '1.0.21', 122, 'debian13-amd64'))
        with self.assertRaisesRegex(ValueError, 'Windows'):
            self.build(steps=[foreign, self.latest])
        with self.assertRaisesRegex(ValueError, 'Windows'):
            self.build(latest=foreign, steps=[foreign])

    def test_combined_platform_feed_is_not_an_independent_windows_feed(self):
        combined = copy.deepcopy(self.first_payload)
        combined['assets'].append(self.release('1.0.22', '1.0.21', 122,
                                              'debian13-amd64')['assets'][0])
        with self.assertRaisesRegex(ValueError, 'independent signed Windows'):
            self.build(steps=[self.signed(combined), self.latest])

    def test_tampered_historical_payload_fails_its_own_signature(self):
        wrapper = json.loads(self.first)
        altered = copy.deepcopy(self.first_payload)
        altered['assets'][0]['minimum_version'] = '1.0.20'
        wrapper['payload'] = base64.b64encode(json.dumps(altered).encode()).decode()
        tampered = json.dumps(wrapper).encode()
        with self.assertRaisesRegex(ValueError, 'signature'):
            self.build(steps=[tampered, self.latest])

    def test_tampered_latest_payload_is_refused_before_path_construction(self):
        wrapper = json.loads(self.latest)
        wrapper['payload'] = base64.b64encode(b'{}').decode()
        with self.assertRaisesRegex(ValueError, 'signature'):
            self.build(latest=json.dumps(wrapper).encode())

    def test_expired_historical_or_latest_feed_is_refused(self):
        for historical in (True, False):
            with self.subTest(historical=historical):
                payload = copy.deepcopy(self.first_payload if historical else self.latest_payload)
                payload['expires_at'] = '2026-11-16T11:59:59Z'
                expired = self.signed(payload)
                with self.assertRaisesRegex(ValueError, 'expired'):
                    if historical:
                        self.build(steps=[expired, self.latest])
                    else:
                        self.build(latest=expired, steps=[self.first, expired])

    def test_last_step_requires_exact_latest_envelope_bytes(self):
        for steps in ([self.first], [self.first, self.latest + b'\n']):
            with self.subTest(end=steps[-1][-12:]):
                with self.assertRaisesRegex(ValueError, 'exact latest Windows envelope'):
                    self.build(steps=steps)

    def test_catalogue_expiry_is_capped_by_earliest_independent_release(self):
        earlier = copy.deepcopy(self.first_payload)
        earlier['expires_at'] = '2026-11-20T12:00:00Z'
        result = self.build(steps=[self.signed(earlier), self.latest])
        self.assertEqual(result['expires_at'], earlier['expires_at'])
        self.assertEqual(result['published_at'], '2026-11-16T12:00:00Z')
        self.assertEqual(self.build(days=1)['expires_at'], '2026-11-17T12:00:00Z')

    def test_empty_or_oversized_path_and_invalid_bounds_are_refused(self):
        cases = [{'steps': []}, {'steps': [self.first] * 32 + [self.latest]},
                 {'sequence': 0}, {'sequence': True}, {'sequence': 2**63},
                 {'days': 0}, {'days': 367}, {'minimum': '1.0.021'}]
        for values in cases:
            with self.subTest(arguments=values if 'steps' not in values else len(values['steps'])):
                with self.assertRaises(ValueError):
                    self.build(**values)


if __name__ == '__main__':
    unittest.main()
