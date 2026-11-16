#!/usr/bin/env python3
"""Offline publication guard fixtures; no release key or real feed mutation."""
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
spec = importlib.util.spec_from_file_location('platform_release', ROOT / 'packaging/updates/platform-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class CataloguePromotionChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='openweb-catalogue-publication-')
        cls.directory = Path(cls.temporary.name)
        cls.private, cls.public = cls.directory / 'test-key.pem', cls.directory / 'test-public.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(cls.private)], check=True, capture_output=True)
        cls.private.chmod(0o600)
        subprocess.run(['openssl', 'pkey', '-in', str(cls.private), '-pubout', '-out', str(cls.public)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def signed(self, payload):
        raw = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(self.private)], input=raw, check=True, capture_output=True).stdout
        return json.dumps({'key_id': 'release-2026-a', 'payload': base64.b64encode(raw).decode(), 'signature': base64.b64encode(signature).decode()}).encode()

    def feed(self, number, minimum, platform='windows-x64'):
        version = '1.0.' + str(number)
        suffix = {'windows-x64': 'windows-x64.zip', 'debian13-amd64': 'debian13-amd64.tar.gz', 'android-universal': 'android.apk'}[platform]
        name = f'openwebpbx-{version}-{suffix}'
        asset = {'platform': platform, 'name': name, 'url': f'https://github.com/embire2/openwebpbx/releases/download/v{version}/{name}', 'bytes': 100, 'sha256': 'a' * 64}
        if platform == 'android-universal':
            asset.update(version_code=1000 + number, package_id='com.openweb.pbx', min_sdk=28, minimum_server_version='1.0.20', certificate_sha256='b' * 64)
        else:
            asset['minimum_version'] = minimum
        return self.signed({'schema': 1, 'product': 'openwebpbx', 'channel': 'stable', 'sequence': 100 + number,
                            'version': version, 'published_at': self.published, 'expires_at': self.expires, 'assets': [asset]})

    def catalogue(self, latest, versions, sequence):
        latest_payload = base64.b64decode(json.loads(latest)['payload'])
        latest_info = json.loads(latest_payload)
        steps, previous = [], '1.0.20'
        for number in versions:
            current = '1.0.' + str(number)
            steps.append({'previous_version': previous, 'version': current, 'envelope_sha256': hashlib.sha256(self.history[current]).hexdigest()})
            previous = current
        return {'schema': 1, 'kind': 'windows-upgrade-path', 'product': 'openwebpbx', 'channel': 'stable', 'platform': 'windows-x64',
                'sequence': sequence, 'published_at': self.published, 'expires_at': self.expires, 'minimum_installed_version': '1.0.20',
                'latest_version': latest_info['version'], 'latest_sequence': latest_info['sequence'],
                'latest_payload_sha256': hashlib.sha256(latest_payload).hexdigest(), 'steps': steps}

    def setUp(self):
        self.now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        self.published = (self.now - dt.timedelta(minutes=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.expires = (self.now + dt.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.history = {'1.0.' + str(n): self.feed(n, minimum) for n, minimum in ((21, '1.0.20'), (22, '1.0.21'), (23, '1.0.22'), (26, '1.0.23'))}
        self.old_latest, self.new_latest = self.history['1.0.23'], self.history['1.0.26']
        self.old_payload = self.catalogue(self.old_latest, (21, 22, 23), 501)
        self.new_payload = self.catalogue(self.new_latest, (21, 22, 23, 26), 502)
        self.before, self.after = self.signed(self.old_payload), self.signed(self.new_payload)

    def guard(self, *, before=None, after=None, payload=None, platform='windows-x64', historical=None):
        return release.validate_catalogue_promotion(self.before if before is None else before,
            (self.signed(payload) if payload is not None else self.after) if after is None else after,
            self.old_latest, self.new_latest if platform == 'windows-x64' else self.old_latest,
            platform, self.public, now=self.now, historical=historical)

    def test_correct_windows_advance_retains_chain_and_all_original_envelopes(self):
        result = self.guard(historical=self.history)
        self.assertEqual((result['sequence'], result['latest_version'], result['steps']), (502, '1.0.26', 4))
        self.assertEqual(result['available_step_envelopes_verified'], 4)
        self.assertEqual(result['full_package_qualification'], 'separate')

    def test_metadata_only_guard_still_checks_both_available_latest_envelopes(self):
        self.assertEqual(self.guard()['available_step_envelopes_verified'], 2)

    def test_nonwindows_carries_catalogue_byte_exact(self):
        for platform in ('debian13-amd64', 'android-universal'):
            with self.subTest(platform=platform):
                self.assertTrue(self.guard(after=self.before, platform=platform)['retained_byte_exact'])

    def test_missing_retained_catalogue_is_refused_for_every_platform(self):
        for platform in release.FEEDS:
            with self.subTest(platform=platform), self.assertRaisesRegex(ValueError, 'Retain'):
                release.validate_catalogue_promotion(self.before, None, self.old_latest, self.new_latest, platform, self.public, now=self.now)

    def test_even_nonwindows_wrapper_whitespace_or_valid_resigning_is_refused(self):
        resigned = copy.deepcopy(self.old_payload)
        resigned['sequence'] += 1
        for value in (self.before + b'\n', self.signed(resigned)):
            with self.subTest(value=len(value)), self.assertRaisesRegex(ValueError, 'byte-for-byte'):
                self.guard(after=value, platform='debian13-amd64')

    def test_legacy_nonwindows_snapshots_without_catalogue_keep_working(self):
        result = release.validate_catalogue_promotion(None, None, self.old_latest, self.old_latest, 'debian13-amd64', self.public, now=self.now)
        self.assertFalse(result['present'])

    def test_windows_requires_catalogue_even_for_initial_adoption(self):
        with self.assertRaisesRegex(ValueError, 'requires'):
            release.validate_catalogue_promotion(None, None, self.old_latest, self.new_latest, 'windows-x64', self.public, now=self.now)
        result = release.validate_catalogue_promotion(None, self.after, self.old_latest, self.new_latest, 'windows-x64', self.public, now=self.now)
        self.assertTrue(result['present'])

    def test_old_and_conflicting_catalogue_sequence_are_refused(self):
        for sequence in (500, 501):
            payload = copy.deepcopy(self.new_payload)
            payload['sequence'] = sequence
            with self.subTest(sequence=sequence), self.assertRaisesRegex(ValueError, 'sequence'):
                self.guard(payload=payload)

    def test_ordinary_latest_trust_floor_cannot_regress_or_conflict(self):
        for sequence in (122, 123):
            raw = json.loads(base64.b64decode(json.loads(self.new_latest)['payload']))
            raw['sequence'] = sequence
            latest = self.signed(raw)
            self.history['1.0.26'] = latest
            payload = self.catalogue(latest, (21, 22, 23, 26), 502)
            with self.subTest(sequence=sequence), self.assertRaisesRegex(ValueError, 'older or conflicting release'):
                release.validate_catalogue_promotion(self.before, self.signed(payload), self.old_latest,
                    latest, 'windows-x64', self.public, now=self.now)

    def test_original_starting_floor_cannot_raise_or_lower(self):
        for minimum in ('1.0.19', '1.0.21'):
            payload = copy.deepcopy(self.new_payload)
            payload['minimum_installed_version'] = minimum
            payload['steps'][0]['previous_version'] = minimum
            if minimum == '1.0.21':
                payload['steps'].pop(0)
            with self.subTest(minimum=minimum), self.assertRaisesRegex(ValueError, 'starting floor'):
                self.guard(payload=payload)

    def test_historical_step_hash_cannot_be_rewritten(self):
        payload = copy.deepcopy(self.new_payload)
        payload['steps'][0]['envelope_sha256'] = 'c' * 64
        with self.assertRaisesRegex(ValueError, 'retained Windows step'):
            self.guard(payload=payload)

    def test_retained_intermediate_cannot_be_removed(self):
        payload = copy.deepcopy(self.new_payload)
        payload['steps'].pop(1)
        payload['steps'][1]['previous_version'] = '1.0.21'
        with self.assertRaisesRegex(ValueError, 'retained Windows step'):
            self.guard(payload=payload)

    def test_exact_latest_version_sequence_and_payload_hash_are_required(self):
        for field, value in (('latest_version', '1.0.25'), ('latest_sequence', 125), ('latest_payload_sha256', 'c' * 64)):
            payload = copy.deepcopy(self.new_payload)
            payload[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'exact Windows latest'):
                self.guard(payload=payload)

    def test_final_envelope_hash_is_exact_not_just_same_payload(self):
        payload = copy.deepcopy(self.new_payload)
        payload['steps'][-1]['envelope_sha256'] = hashlib.sha256(self.new_latest + b'\n').hexdigest()
        with self.assertRaisesRegex(ValueError, 'exact latest envelope'):
            self.guard(payload=payload)

    def test_invalid_signature_cannot_publish_catalogue_metadata(self):
        outer = json.loads(self.after)
        outer['payload'] = base64.b64encode(b'{}').decode()
        with self.assertRaisesRegex(ValueError, 'signature'):
            self.guard(after=json.dumps(outer).encode())

    def test_wrong_namespace_or_unknown_fields_are_refused(self):
        for field, value in (('kind', 'release-feed'), ('platform', 'debian13-amd64'), ('schema', True), ('unexpected', True)):
            payload = copy.deepcopy(self.new_payload)
            payload[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'namespace or schema'):
                self.guard(payload=payload)

    def test_catalogue_expiry_and_future_time_are_enforced(self):
        for field, value in (('expires_at', self.published), ('published_at', (self.now + dt.timedelta(minutes=6)).strftime('%Y-%m-%dT%H:%M:%SZ'))):
            payload = copy.deepcopy(self.new_payload)
            payload[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'expired or has invalid'):
                self.guard(payload=payload)

    def test_available_history_tampering_is_refused(self):
        history = dict(self.history)
        history['1.0.22'] += b'\n'
        with self.assertRaisesRegex(ValueError, 'historical Windows envelope differs'):
            self.guard(historical=history)

    def test_available_history_original_minimum_is_not_lowered(self):
        history = dict(self.history)
        history['1.0.22'] = self.feed(22, '1.0.22')
        payload = copy.deepcopy(self.new_payload)
        payload['steps'][1]['envelope_sha256'] = hashlib.sha256(history['1.0.22']).hexdigest()
        with self.assertRaisesRegex(ValueError, 'original minimum'):
            release.validate_catalogue_promotion(None, self.signed(payload), self.old_latest, self.new_latest, 'windows-x64', self.public, now=self.now, historical=history)

    def test_final_original_minimum_is_not_lowered(self):
        latest = self.feed(26, '1.0.26')
        self.history['1.0.26'] = latest
        payload = self.catalogue(latest, (21, 22, 23, 26), 502)
        with self.assertRaisesRegex(ValueError, 'original minimum'):
            release.validate_catalogue_promotion(self.before, self.signed(payload), self.old_latest, latest, 'windows-x64', self.public, now=self.now)

    def snapshots(self, folder, *, platform='windows-x64'):
        before = {'update-manifest.json': self.feed(19, None, 'android-universal'),
                  'debian-update-manifest.json': self.feed(23, '1.0.22', 'debian13-amd64'),
                  'windows-update-manifest.json': self.old_latest}
        after = dict(before)
        after[release.FEEDS[platform]] = self.new_latest if platform == 'windows-x64' else self.feed(26, '1.0.23', platform)
        for label, feeds, catalogue in (('before', before, self.before), ('after', after, self.after if platform == 'windows-x64' else self.before)):
            directory = folder / label
            directory.mkdir()
            for name, raw in feeds.items():
                (directory / name).write_bytes(raw)
            (directory / release.CATALOGUE).write_bytes(catalogue)
        return [sys.executable, '-B', str(ROOT / 'packaging/updates/platform-release.py'), '--platform', platform,
                '--before', str(folder / 'before'), '--after', str(folder / 'after'), '--public-key', str(self.public)]

    def test_cli_windows_advance_verifies_optional_history_without_writing_snapshots(self):
        with tempfile.TemporaryDirectory(dir=self.directory) as folder:
            folder = Path(folder)
            command = self.snapshots(folder)
            (folder / 'after/catalogue').mkdir()
            for value, raw in self.history.items():
                (folder / 'after/catalogue' / (value + '.json')).write_bytes(raw)
            before = {str(p.relative_to(folder)): p.read_bytes() for p in folder.rglob('*') if p.is_file()}
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(json.loads(result.stdout)['windows_upgrade_path']['available_step_envelopes_verified'], 4)
            self.assertEqual(before, {str(p.relative_to(folder)): p.read_bytes() for p in folder.rglob('*') if p.is_file()})

    def test_cli_rejects_missing_retained_catalogue(self):
        with tempfile.TemporaryDirectory(dir=self.directory) as folder:
            folder = Path(folder)
            command = self.snapshots(folder, platform='debian13-amd64')
            (folder / 'after' / release.CATALOGUE).unlink()
            result = subprocess.run(command, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'Retain windows-upgrade-path.json', result.stderr)

    def test_cli_rejects_changed_retained_catalogue(self):
        with tempfile.TemporaryDirectory(dir=self.directory) as folder:
            folder = Path(folder)
            command = self.snapshots(folder, platform='android-universal')
            with (folder / 'after' / release.CATALOGUE).open('ab') as stream:
                stream.write(b'\n')
            result = subprocess.run(command, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'byte-for-byte', result.stderr)

    def test_history_snapshot_conflict_is_refused(self):
        with tempfile.TemporaryDirectory(dir=self.directory) as folder:
            folder = Path(folder)
            command = self.snapshots(folder)
            (folder / 'before/catalogue').mkdir()
            (folder / 'after/catalogue').mkdir()
            (folder / 'before/catalogue/1.0.22.json').write_bytes(self.history['1.0.22'])
            (folder / 'after/catalogue/1.0.22.json').write_bytes(self.history['1.0.22'] + b'\n')
            result = subprocess.run(command, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'snapshots disagree', result.stderr)


if __name__ == '__main__':
    unittest.main()
