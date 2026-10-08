#!/usr/bin/env python3
"""Validate private TLS setup checks using disposable certificate material."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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


if __name__ == '__main__':
    unittest.main()
