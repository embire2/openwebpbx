"""Private fixture PKI and actual installed tenant-worker primitives, Windows CI only."""
import argparse
import datetime as dt
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import secrets
import sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['pki', 'identity', 'proofs', 'ready'])
    parser.add_argument('input')
    args = parser.parse_args()
    if os.name != 'nt' or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx':
        raise RuntimeError('Explicit disposable Windows runner required')
    path = Path(args.input).resolve()
    state = Path(os.environ['ProgramData'])/'OpenWebPBX'
    if path.name != 'input.json' or path.parent.parent != state/'tenant-domain-qualification' or len(path.parent.name) != 32 or any(c not in '0123456789abcdef' for c in path.parent.name):
        raise RuntimeError('Owned private fixture input required')
    settings = json.loads(path.read_text(encoding='utf-8-sig'))
    alias = settings['alias']
    if alias != 'qa-'+path.parent.name+'.openwebpbx.com':
        raise RuntimeError('Owned fictional alias required')
    if args.operation == 'pki':
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != '/fixture.crl':
                    self.send_error(404)
                    return
                body = (path.parent/'fixture.crl').read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'application/pkix-crl')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *_):
                pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        server.timeout = .25
        uri = 'http://127.0.0.1:'+str(server.server_port)+'/fixture.crl'
        now = dt.datetime.now(dt.timezone.utc)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'OpenWebPBX owned tenant QA '+path.parent.name)])
        root = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(now-dt.timedelta(days=1))
                .not_valid_after(now+dt.timedelta(days=90)).add_extension(x509.BasicConstraints(ca=True, path_length=0), True)
                .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), True)
                .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), False).sign(key, hashes.SHA256()))
        leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        leaf = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, alias)]))
                .issuer_name(name).public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now-dt.timedelta(days=1)).not_valid_after(now+dt.timedelta(days=60))
                .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
                .add_extension(x509.KeyUsage(True, False, True, False, False, False, False, False, False), True)
                .add_extension(x509.SubjectAlternativeName([x509.DNSName(alias)]), False)
                .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False)
                .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), False)
                .add_extension(x509.CRLDistributionPoints([x509.DistributionPoint(full_name=[x509.UniformResourceIdentifier(uri)], relative_name=None, reasons=None, crl_issuer=None)]), False)
                .sign(key, hashes.SHA256()))
        crl = (x509.CertificateRevocationListBuilder().issuer_name(name).last_update(now-dt.timedelta(hours=1))
               .next_update(now+dt.timedelta(days=7)).add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), False)
               .sign(key, hashes.SHA256()))
        (path.parent/'root.cer').write_bytes(root.public_bytes(serialization.Encoding.DER))
        (path.parent/'leaf.pfx').write_bytes(pkcs12.serialize_key_and_certificates(b'OpenWebPBX tenant QA', leaf_key, leaf, None, serialization.BestAvailableEncryption(settings['pfx_password'].encode())))
        (path.parent/'fixture.crl').write_bytes(crl.public_bytes(serialization.Encoding.DER))
        (path.parent/'pki.json').write_text(json.dumps({'root_thumbprint':root.fingerprint(hashes.SHA1()).hex().upper(), 'leaf_thumbprint':leaf.fingerprint(hashes.SHA1()).hex().upper(), 'not_after':leaf.not_valid_after_utc.isoformat(), 'crl_url':uri}), encoding='utf-8')
        try:
            while not (path.parent/'stop-pki').exists():
                server.handle_request()
        finally:
            server.server_close()
        return
    installed = Path('C:/OpenWebPBX/tools')
    worker = load(installed/'tenant-domains.py', 'owned_tenant_domains')
    backup = load(installed/'backups.py', 'owned_tenant_backup')
    worker.WINDOWS_ACL = lambda operation, value: worker.windows(backup, operation, value)
    public = worker.directory(state/'tenant-domains', True)
    private = worker.directory(public/'private')
    proofs = worker.directory(public/'proofs/.well-known/openwebpbx-instance', True)
    key, public_key, key_hash = worker.identity(backup.CONFIG.parent/'tenant-domains-instance-key.pem', lambda action, value: worker.windows(backup, action, value))
    if args.operation == 'identity':
        print(json.dumps({'key_hash':key_hash}))
    elif args.operation == 'proofs':
        nonce = hashlib.sha256(path.parent.name.encode()).hexdigest()
        body = ('openwebpbx-instance-v1\n'+nonce+'\n'+key_hash+'\n'+settings['server_host']+'\n').encode()
        worker.atomic(proofs/nonce, body, True)
        worker.atomic(proofs/(nonce+'-static'), b'<?php echo "THIS_MUST_NOT_EXECUTE"; ?>', True)
        print(json.dumps({'nonce':nonce,'body':body.decode()}))
    elif args.operation == 'ready':
        until = json.loads((path.parent/'pki.json').read_text())['not_after']
        worker.atomic(public/'ready.json', json.dumps({'schema':1,'server_host':settings['server_host'],'key_hash':key_hash,'aliases':{alias:until}}).encode(), True)
        print(json.dumps({'ready':True}))


if __name__ == '__main__':
    run()
