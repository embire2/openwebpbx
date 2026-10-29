#!/usr/bin/env python3
"""Real filesystem/OpenSSL checks; HTTP and installed-helper boundaries are fixtures."""
import base64
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('image_onboarding', ROOT/'packaging/debian/webhotel-onboarding.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
count = 0


def check(value, message):
    global count
    if not value:
        raise AssertionError(message)
    count += 1


def refused(fn):
    try:
        fn()
    except (ValueError, m.Pending):
        check(True, 'Refusal')
        return
    raise AssertionError('Expected protected-state refusal')


directory = Path(tempfile.mkdtemp(prefix='image-onboarding-test-', dir='/var/lib/openwebpbx'))
try:
    os.chmod(directory, 0o700)
    m.STATE = directory/'state';m.STATE.mkdir(mode=0o700)
    m.PROOFS = directory/'proofs';m.PROOFS.mkdir(mode=0o750);os.chown(m.PROOFS, 0, 33)
    m.KEY = directory/'instance.pem'
    subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', str(m.KEY)], check=True, capture_output=True)
    os.chmod(m.KEY, 0o600)
    public = subprocess.run(['openssl', 'pkey', '-in', str(m.KEY), '-pubout', '-outform', 'DER'], check=True, capture_output=True).stdout
    pem = subprocess.run(['openssl', 'pkey', '-in', str(m.KEY), '-pubout'], check=True, capture_output=True).stdout
    (directory/'public.pem').write_bytes(pem)
    uid = lambda: str(uuid.uuid4())
    metadata = {'local_tenant_uuid':uid(), 'domain_uuid':uid(), 'bootstrap_uuid':uid(), 'image_version':'1.0.21',
                'public_key':base64.b64encode(public).decode(), 'key_path':str(m.KEY), 'proof_root':str(m.PROOFS)}
    server = 'node-'+metadata['bootstrap_uuid'].replace('-', '')+'.openwebpbx.com'
    account, pairing = uid(), uid()
    key_hash = hashlib.sha256(public).hexdigest()
    tenant_host = 'fixture-tenant.openwebpbx.com'
    payload = {'expires_at':(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=365)).isoformat()}
    activation = {'payload':base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip('='), 'signature':'fixture-local-helper-validates-real-RSA'}

    class Fixture(m.Agent):
        phase = 'pending'
        bound = False
        local_ready = False
        init_changed = False
        fail_expired = False
        calls = []

        def helper(self, action, body=None):
            self.calls.append(('helper', action))
            if action == 'init':
                return dict(metadata, domain_uuid=uid()) if self.init_changed else metadata
            if action == 'bind':
                check(body == {'server_host':server}, 'Certificate setup changed canonical server')
                self.bound = True
                return {'ready':True}
            if action == 'store':
                check(body == {'activation':activation}, 'Receipt not handed to installed validator')
                return {'registration_confirmed':True}
            if action == 'status':
                return {'ready':self.local_ready, 'hostname':tenant_host}
            if action == 'display':
                check(set(body) == {'user_code','verification_uri_complete','pairing_uuid','expires_at'}, 'Public setup display received a private credential')
                return {'displayed':True}
            if action == 'sign':
                check(set(body) == {'message'}, 'Windows signing bridge received an arbitrary key path')
                value = subprocess.run(['openssl','dgst','-sha256','-sign',str(m.KEY)], input=body['message'].encode(), capture_output=True, check=True).stdout
                return {'signature':base64.b64encode(value).decode()}
            if action == 'proof':
                check(set(body) == {'nonce','body'}, 'Windows proof bridge received an arbitrary destination')
                return {'written':True}
            raise AssertionError('Unknown helper action')

        def verify_signature(self, message, signature):
            path = directory/'signature.der'
            path.write_bytes(base64.b64decode(signature, validate=True))
            result = subprocess.run(['openssl','dgst','-sha256','-verify',str(directory/'public.pem'),'-signature',str(path)],
                                    input=message.encode(), capture_output=True)
            check(result.returncode == 0, 'Consumer produced an invalid P256 signature')

        def post(self, route, body):
            self.calls.append(('post', route))
            check(not any(field in body for field in ('password','access_token','authorization')), 'Owner credential left the browser')
            if route == '/devices':
                check(body['bootstrap_uuid'] == metadata['bootstrap_uuid'] and body['public_key'] == metadata['public_key'], 'Image identity changed in registration')
                return {'pairing_uuid':pairing,'device_code':'owpd_'+'a'*64,'user_code':'ABCDE-12345','expires_at':'2099-01-01T00:00:00Z','verification_uri_complete':'https://openwebpbx.com/wizard#code=ABCDE-12345'}
            if route == '/devices/poll':
                if self.fail_expired:
                    raise m.Pending('device_expired')
                return dict(metadata, state=self.phase, key_hash=key_hash, server_address='8.8.8.8', account_tenant_uuid=account,
                            nonce='b'*64, label='fixture-tenant', server_host=server, complete_nonce='c'*64,
                            proof_body='openwebpbx-bootstrap-v1\n'+'b'*64+'\n'+key_hash+'\n8.8.8.8\n', activation=activation)
            if route == '/devices/bootstrap':
                expected=('openwebpbx-bootstrap-v1\n'+'b'*64+'\n8.8.8.8\n'+key_hash+'\n'+metadata['bootstrap_uuid']+'\n'+account+'\n'
                          +metadata['local_tenant_uuid']+'\n'+metadata['domain_uuid']+'\nfixture-tenant\n')
                self.verify_signature(expected, body['signature'])
                check((m.PROOFS/('b'*64)).read_text() == 'openwebpbx-bootstrap-v1\n'+'b'*64+'\n'+key_hash+'\n8.8.8.8\n', 'HTTP proof bytes incorrect')
                self.phase = 'dns_ready'
                return {'state':'dns_ready','server_host':server}
            if route == '/devices/challenge':
                check(self.bound, 'Authority requested before automatic canonical HTTPS')
                return {'challenge_uuid':pairing,'nonce':'d'*64,'key_hash':key_hash,'account_tenant_uuid':account,
                        'proof_body':'openwebpbx-instance-v1\n'+'d'*64+'\n'+key_hash+'\n'+server+'\n'}
            if route == '/devices/authorize':
                expected=('openwebpbx-installation-v1\n'+'d'*64+'\n'+server+'\n'+key_hash+'\n'+account+'\n'
                          +metadata['local_tenant_uuid']+'\n'+metadata['domain_uuid']+'\nfixture-tenant\n')
                self.verify_signature(expected, body['signature'])
                self.phase = 'authorized'
                return {'activation':activation}
            if route == '/devices/complete':
                expected=('openwebpbx-complete-v1\n'+'c'*64+'\n'+key_hash+'\n'+server+'\n'+tenant_host+'\n'+metadata['domain_uuid']+'\n')
                self.verify_signature(expected, body['signature'])
                check(body['hostname'] == tenant_host and self.local_ready, 'Unready tenant address marked complete')
                self.phase = 'complete'
                return {'ready':True}
            raise AssertionError('Unknown network request')

    agent = Fixture()
    check(agent.cycle()['state'] == 'waiting_for_owner', 'Image did not wait for account claim')
    session = m.STATE/'session.json'
    check(session.stat().st_mode & 0o777 == 0o600, 'Device session permissions are public')
    check('owpd_' not in (m.STATE/'setup.txt').read_text(), 'Root credential leaked in console setup link')
    check(agent.cycle()['state'] == 'waiting_for_owner', 'Reboot lost existing setup session')
    check(agent.calls.count(('post','/devices')) == 1, 'Restart created another server session')
    agent.phase = 'claimed'
    check(agent.cycle()['state'] == 'dns_ready', 'Bootstrap did not proceed after owner claim')
    proof = m.PROOFS/('b'*64)
    check(proof.stat().st_uid == 0 and proof.stat().st_gid == 33 and proof.stat().st_mode & 0o777 == 0o640, 'Published proof permissions are wrong')
    check(agent.cycle()['state'] == 'authorized', 'Canonical HTTPS did not precede receipt import')
    check(agent.cycle()['state'] == 'waiting_for_tenant_https', 'Unready tenant was advertised')
    agent.local_ready = True
    check(agent.cycle() == {'state':'ready','url':'https://'+tenant_host}, 'Final tenant URL incorrect')
    checks = agent.calls.count(('post','/devices/complete'))
    check(agent.cycle()['state'] == 'ready' and agent.calls.count(('post','/devices/complete')) == checks, 'Completed setup is not idempotent')
    agent.init_changed = True
    refused(agent.cycle)
    agent.init_changed = False
    refused(lambda: m.node('attacker.openwebpbx.com', metadata['bootstrap_uuid']))
    refused(lambda: agent.proof(metadata, '../escape', 'x'))
    link = m.STATE/'linked';link.symlink_to(session)
    refused(lambda: m.atomic(link, b'changed'))
    check(session.read_text().find('owpd_') > 0, 'Symlink refusal changed private session')
    os.chmod(m.KEY, 0o644)
    refused(lambda: agent.sign(metadata, 'test'))
    os.chmod(m.KEY, 0o600)
    # These are portable bridge contract controls, not native Windows ACL/lock qualification.
    old_windows = m.IS_WINDOWS
    try:
        m.IS_WINDOWS = True
        signature = agent.sign(metadata, 'Portable signing bridge\n')
        agent.verify_signature('Portable signing bridge\n', signature)
        agent.proof(metadata, 'e'*64, 'Fixture proof\n')
        refused(lambda: agent.proof(metadata, '../escape', 'x'))
        refused(lambda: agent.proof(metadata, 'e'*64, 'x'*1025))
        private_root = directory/'native-private';private_root.mkdir(mode=0o700)
        chosen = agent.state_directory(dict(metadata, private_root=str(private_root)))
        check(chosen == private_root/'image-onboarding', 'Windows session ignored the ACL-validated private directory')
        refused(lambda: agent.state_directory(metadata))
    finally:
        m.IS_WINDOWS = old_windows
        agent.state_directory(metadata)
    agent.fail_expired = True
    refused(agent.cycle)
    check(not session.exists(), 'Expired private setup credential was reused forever')
    original_agent = m.Agent
    m.Agent = lambda provider: agent
    try:
        result = m.run_once(metadata=metadata)
        check(result['state'] == 'pending' and (m.STATE/'retry.json').exists(), 'Scheduler did not retain retry delay')
        calls = len(agent.calls)
        result = m.run_once(metadata=metadata)
        check(result['state'] == 'pending' and result['retry_after'] > 0 and len(agent.calls) == calls, 'Scheduler bypassed its retry schedule')
        descriptor = os.open(m.STATE/'worker.lock', os.O_RDWR)
        try:
            m.fcntl.flock(descriptor, m.fcntl.LOCK_EX | m.fcntl.LOCK_NB)
            check(m.run_once(metadata=metadata) == {'state':'busy'}, 'Scheduler bypassed the consumer lock')
        finally:
            os.close(descriptor)
    finally:
        m.Agent = original_agent
    print(json.dumps({'passed':count,'scope':'real POSIX protected filesystem/OpenSSL plus Windows helper-contract controls; HTTP/helper boundaries isolated; no native Windows ACL claim'}))
finally:
    # This is a newly created private fixture containing no guest archive or symlinks to host data.
    shutil.rmtree(directory)
