#!/usr/bin/env python3
"""Owned loopback HTTPS controls for the actual laboratory offer handler."""
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import ipaddress
import json
from pathlib import Path
import ssl
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('owned_offer_fixture', ROOT/'tests/windows-updater-fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class OfferWithdrawalChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='owned-offer-withdrawal-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'owned-loopback.invalid')])
        now = datetime.now(timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(now-timedelta(minutes=1))
                .not_valid_after(now+timedelta(days=1))
                .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
                .sign(key, hashes.SHA256()))
        (self.work/'transport-chain.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        (self.work/'transport-leaf.key').write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.archives = {}
        for mode in ('fault', 'normal'):
            path = self.work/(mode+'.private.bin');path.write_bytes((mode+'-owned-bytes').encode())
            self.archives[mode] = str(path)
        settings = {'target_version':'1.0.22', 'archives':self.archives,
                    'packets':{mode:{'envelope':{'owned_fixture':mode}} for mode in ('fault', 'normal')}}
        self.server = fixture.make_server(settings, self.work, port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True);self.thread.start()
        self.addCleanup(self.stop)
        context = ssl.create_default_context(cafile=str(self.work/'transport-chain.pem'))
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
        self.asset = '/embire2/openwebpbx/releases/download/v1.0.22/openwebpbx-1.0.22-windows-x64.zip'

    def stop(self):
        self.server.shutdown();self.server.server_close();self.thread.join(timeout=2)

    def request(self, path, **headers):
        values = {'Host':'github.com', 'User-Agent':'OpenWebPBX-Updater/1', **headers}
        request = urllib.request.Request(f'https://127.0.0.1:{self.server.server_port}{path}', headers=values)
        try:
            with self.opener.open(request, timeout=3) as response:
                return response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            return error.code, error.read(), error.headers

    def rows(self, count):
        deadline = time.monotonic()+2
        while time.monotonic() < deadline:
            path = self.work/'transport-requests.json'
            rows = fixture.read_json(path)['requests'] if path.exists() else []
            if len(rows) >= count:
                return rows
            time.sleep(.01)
        self.fail('Owned transport did not retain its bounded response record.')

    def test_explicit_withdrawal_logs_empty_feed_and_archive_503(self):
        fixture.write_json(self.work/'mode.json', {'mode':'operator-rollback'})
        for path in (fixture.FEED_PATH, self.asset):
            status, body, headers = self.request(path)
            self.assertEqual((status, body), (503, b''));self.assertEqual(headers['Cache-Control'], 'no-store')
        rows = self.rows(2)
        self.assertEqual([row['kind'] for row in rows], ['feed', 'archive'])
        for row, path in zip(rows, (fixture.FEED_PATH, self.asset)):
            self.assertEqual((row['mode'], row['http_status'], row['request_path'], row['bytes']), ('operator-rollback', 503, path, 0))
            self.assertTrue(all(row[key] is True for key in ('complete','loopback','original_url','updater_user_agent')))
            self.assertIsNotNone(datetime.fromisoformat(row['at_utc']).tzinfo)

    def test_existing_request_guards_precede_withdrawal_marker(self):
        fixture.write_json(self.work/'mode.json', {'mode':'operator-rollback'})
        for headers, expected in [({'Host':'foreign.invalid'},403), ({'User-Agent':'foreign'},400), ({'Range':'bytes=0-'},400)]:
            self.assertEqual(self.request(fixture.FEED_PATH, **headers)[0], expected)
        self.assertFalse((self.work/'transport-requests.json').exists())

    def test_normal_and_fault_transfers_are_unchanged(self):
        for mode in ('fault','normal'):
            fixture.write_json(self.work/'mode.json', {'mode':mode})
            status, body, _ = self.request(fixture.FEED_PATH)
            self.assertEqual(status, 200);self.assertEqual(json.loads(body), {'owned_fixture':mode})
            status, body, _ = self.request(self.asset)
            self.assertEqual(status, 200);self.assertEqual(body, Path(self.archives[mode]).read_bytes())
        rows = self.rows(4)
        self.assertEqual([(row['mode'],row['kind']) for row in rows], [('fault','feed'),('fault','archive'),('normal','feed'),('normal','archive')])
        for row in rows:
            self.assertTrue(row['complete'])
            if row['kind']=='archive':self.assertEqual(row['sha256'], hashlib.sha256(Path(self.archives[row['mode']]).read_bytes()).hexdigest())

    def test_unknown_mode_does_not_create_a_withdrawal_witness(self):
        fixture.write_json(self.work/'mode.json', {'mode':'unknown'})
        self.assertEqual(self.request(fixture.FEED_PATH)[0], 503)
        self.assertFalse((self.work/'transport-requests.json').exists())


if __name__ == '__main__':
    unittest.main()
