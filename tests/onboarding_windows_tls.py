#!/usr/bin/env python3
"""Real loopback TLS regression for the Windows temporary-certificate boundary.

No system certificate store or service is changed. Windows' locally trusted
setup certificate is represented by an explicit private test trust store.
Actual Windows Root-store/IIS qualification remains a separate native test.
"""
import datetime as dt
import importlib.util
from pathlib import Path
import socket
import ssl
import tempfile
import threading
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('onboarding_tls_subject', ROOT / 'packaging/debian/onboarding.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
HOST = 'node-' + '1' * 32 + '.openwebpbx.com'
NOW = dt.datetime.now(dt.timezone.utc)


def certificate(name, issuer, key, signing_key, *, ca=False, expired=False):
    return (x509.CertificateBuilder().subject_name(name).issuer_name(issuer)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(NOW - dt.timedelta(days=2))
            .not_valid_after(NOW + dt.timedelta(days=-1 if expired else 1))
            .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                key_encipherment=False, data_encipherment=False, key_agreement=False,
                key_cert_sign=ca, crl_sign=ca, encipher_only=False, decipher_only=False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(signing_key.public_key()), critical=False)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(HOST)]), critical=False)
            .sign(signing_key, hashes.SHA256()))


def probe(directory, leaf, key, trusted, *, windows=True, hostname=HOST):
    cert_path, key_path, trust_path = (directory / value for value in ('server.pem', 'key.pem', 'trust.pem'))
    cert_path.write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    key_path.chmod(0o600)
    trust_path.write_bytes(trusted.public_bytes(serialization.Encoding.PEM))
    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.load_cert_chain(cert_path, key_path)
    client = ssl.create_default_context(cafile=str(trust_path))
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(6)
    endpoint = listener.getsockname()
    failures = []

    def serve():
        try:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(5)
                try:
                    with server.wrap_socket(connection, server_side=True):
                        pass
                except ssl.SSLError:
                    pass  # Expected for the negative trust/hostname/expiry cases.
        except Exception as error:
            failures.append(type(error).__name__)
        finally:
            listener.close()

    real_connect = socket.create_connection

    def local_connect(address, timeout):
        assert address == ('127.0.0.1', 443) and timeout == 5
        return real_connect(endpoint, timeout=timeout)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        with patch.object(worker, 'IS_WINDOWS', windows), patch.object(socket, 'create_connection', local_connect), patch.object(ssl, 'create_default_context', return_value=client):
            result = worker.trusted_web(hostname)
    finally:
        thread.join(7)
    assert not thread.is_alive() and not failures, 'The actual TLS fixture did not finish cleanly.'
    return result


def main():
    key, ca_key = (ec.generate_private_key(ec.SECP256R1()) for _ in range(2))
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, HOST)])
    issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Private regression CA')])
    setup = certificate(name, name, key, key)
    ca = certificate(issuer, issuer, ca_key, ca_key, ca=True)
    leaf = certificate(name, issuer, key, ca_key)
    expired = certificate(name, issuer, key, ca_key, expired=True)
    with tempfile.TemporaryDirectory(prefix='openweb-onboarding-tls-') as path:
        directory = Path(path)
        assert not probe(directory, setup, key, setup), 'A locally trusted Windows setup certificate skipped public issuance.'
        assert probe(directory, leaf, key, ca), 'A valid issued certificate was not reusable.'
        assert not probe(directory, leaf, key, setup), 'Untrusted issuer was accepted.'
        assert not probe(directory, leaf, key, ca, hostname='wrong.example.invalid'), 'Wrong hostname was accepted.'
        assert not probe(directory, expired, key, ca), 'Expired certificate was accepted.'
        assert probe(directory, setup, key, setup, windows=False), 'The existing non-Windows trust policy changed.'
    print('PASS: 6 real TLS onboarding certificate controls; native Windows store qualification is separate.')


if __name__ == '__main__':
    main()
