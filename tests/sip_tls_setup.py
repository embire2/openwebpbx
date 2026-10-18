#!/usr/bin/env python3
"""Validate private TLS setup checks using disposable certificate material."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

DIRECTORY = Path(__file__).resolve().parents[1] / 'packaging/debian'
sys.path.insert(0, str(DIRECTORY))
spec = importlib.util.spec_from_file_location('sip_tls_setup', DIRECTORY / 'configure-sip-tls.py')
tls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tls)


@unittest.skipUnless(os.geteuid() == 0, 'Private-key ownership checks require root.')
class CertificateChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='openweb-tls-test-')
        cls.root = Path(cls.temporary.name)
        cls.key = cls.root / 'private.key'
        cls.cert = cls.root / 'certificate.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3',
                        '-subj', '/CN=phone.example.test', '-addext', 'subjectAltName=DNS:phone.example.test',
                        '-keyout', str(cls.key), '-out', str(cls.cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.key.chmod(0o600)
        cls.system_ca = tls.CA
        tls.CA = cls.cert

    @classmethod
    def tearDownClass(cls):
        tls.CA = cls.system_ca
        cls.temporary.cleanup()

    def test_matching_trusted_hostname_and_key(self):
        self.assertEqual(len(tls.validate('phone.example.test', self.cert, self.key)), 32)

    def test_wrong_hostname_refused(self):
        with self.assertRaises(ValueError):
            tls.validate('other.example.test', self.cert, self.key)

    def test_wrong_key_refused(self):
        other = self.root / 'other.key'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(other)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        other.chmod(0o600)
        with self.assertRaises(ValueError):
            tls.validate('phone.example.test', self.cert, other)

    def test_untrusted_certificate_refused(self):
        tls.CA = self.system_ca
        try:
            with self.assertRaises(ValueError):
                tls.validate('phone.example.test', self.cert, self.key)
        finally:
            tls.CA = self.cert

    def test_publicly_readable_private_key_refused(self):
        self.key.chmod(0o644)
        try:
            with self.assertRaises(ValueError):
                tls.validate('phone.example.test', self.cert, self.key)
        finally:
            self.key.chmod(0o600)

    def test_supplied_cross_signed_path_replaces_same_key_system_root(self):
        key = self.root / 'new-root.key'
        request = self.root / 'new-root.csr'
        self_signed = self.root / 'new-root-self.pem'
        cross_signed = self.root / 'new-root-cross.pem'
        commands = [
            ['openssl', 'req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
             '-nodes', '-subj', '/CN=New root', '-keyout', str(key), '-out', str(request)],
            ['openssl', 'x509', '-req', '-in', str(request), '-signkey', str(key), '-days', '3', '-out', str(self_signed)],
            ['openssl', 'x509', '-req', '-in', str(request), '-CA', str(self.cert), '-CAkey', str(self.key),
             '-set_serial', '100', '-days', '3', '-out', str(cross_signed)],
        ]
        for command in commands:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        chain = self.cert.read_bytes() + cross_signed.read_bytes()
        roots = self_signed.read_bytes() + self.cert.read_bytes()
        selected = tls.chain_fingerprints(tls.chain_store(chain, roots))
        self.assertEqual(selected, tls.chain_fingerprints(cross_signed.read_bytes() + self.cert.read_bytes()))
        self.assertNotIn(tls.chain_fingerprints(self_signed.read_bytes())[0], selected)


class ProfileRestartChecks(unittest.TestCase):
    def exercise(self, replies, *, name='internal', busy_at=None, idle_delay=0):
        self.elapsed = 0.0
        self.events = []
        responses = iter(replies)

        def idle(settings):
            self.events.append('idle')
            self.elapsed += idle_delay
            if busy_at == self.events.count('idle'):
                raise RuntimeError('Calls became active')

        def api(settings, command):
            self.events.append(command)
            return next(responses)

        def sleep(seconds):
            self.elapsed += seconds

        with mock.patch.object(tls, 'check_idle', idle), \
             mock.patch.object(tls, 'engine_api', api), \
             mock.patch.object(tls.time, 'monotonic', lambda: self.elapsed), \
             mock.patch.object(tls.time, 'sleep', sleep):
            tls.restart_profile({}, name)

    def test_native_success_after_idle_check(self):
        for name in ['internal', 'internal-ipv6']:
            with self.subTest(name=name):
                self.exercise(['Reload XML [Success]\nrestarting: '+name], name=name)
                self.assertEqual(self.events, ['idle', 'sofia profile '+name+' restart'])

    def test_exact_native_cooldown_retries_with_fresh_idle_check(self):
        for seconds in [1, 10]:
            with self.subTest(seconds=seconds):
                suffix = '' if seconds == 1 else 's'
                self.exercise([f'Profile internal must be up for at least 10 seconds to stop/restart.\nPlease wait {seconds} second{suffix}\n',
                               'Reload XML [Success]\nrestarting: internal'])
                self.assertGreaterEqual(self.elapsed, seconds)
                self.assertEqual(self.events, ['idle', 'sofia profile internal restart'] * 2)

    def test_call_arriving_during_cooldown_prevents_second_restart(self):
        with self.assertRaisesRegex(RuntimeError, 'Calls became active'):
            self.exercise(['Profile internal must be up for at least 10 seconds to stop/restart.\nPlease wait 1 second'], busy_at=2)
        self.assertEqual(self.events, ['idle', 'sofia profile internal restart', 'idle'])

    def test_unknown_failure_or_wrong_profile_never_retried(self):
        for response in ['+OK', '-ERR unavailable', 'Invalid Profile!', '',
                         'Reload XML [Failure]\nrestarting: internal',
                         'Reload XML [Success]\nrestarting: internal-ipv6',
                         'Profile internal-ipv6 must be up for at least 10 seconds to stop/restart.\nPlease wait 1 second',
                         'Profile internal must be up for at least 10 seconds to stop/restart.\nPlease wait 1 seconds',
                         'Profile internal must be up for at least 10 seconds to stop/restart.\nPlease wait 0 seconds',
                         'Profile internal must be up for at least 10 seconds to stop/restart.\nPlease wait 100 seconds']:
            with self.subTest(response=response), self.assertRaises(RuntimeError):
                self.exercise([response])
            self.assertEqual(self.events, ['idle', 'sofia profile internal restart'])
            self.assertEqual(self.elapsed, 0)

    def test_repeated_cooldown_has_bounded_total_wait(self):
        response = 'Profile internal must be up for at least 10 seconds to stop/restart.\nPlease wait 10 seconds'
        with self.assertRaisesRegex(RuntimeError, 'cooldown did not finish'):
            self.exercise([response] * 20)
        self.assertLessEqual(self.elapsed, 20)
        self.assertEqual(self.events.count('idle'), 2)

    def test_repeated_short_cooldown_has_bounded_attempts(self):
        response = 'Profile internal must be up for at least 10 seconds to stop/restart.\nPlease wait 1 second'
        with self.assertRaisesRegex(RuntimeError, 'cooldown did not finish'):
            self.exercise([response] * 20)
        self.assertLessEqual(self.elapsed, 20)
        self.assertEqual(self.events.count('idle'), 4)

    def test_expired_idle_check_cannot_issue_restart(self):
        with self.assertRaisesRegex(RuntimeError, 'cooldown did not finish'):
            self.exercise([], idle_delay=21)
        self.assertEqual(self.events, ['idle'])

    def test_profile_name_is_restricted_before_engine_access(self):
        with self.assertRaises(RuntimeError):
            self.exercise([], name='internal restart')
        self.assertEqual(self.events, [])


if __name__ == '__main__':
    unittest.main()
