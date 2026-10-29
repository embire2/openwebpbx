#!/usr/bin/env python3
"""Root-only outbound pairing for a generalized OpenWeb PBX Debian image.

The hosting provider's credentials and the owner's password/token never enter
this process. Local changes go through the installed onboarding helper.
"""
import argparse
import base64
import datetime as dt
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

IS_WINDOWS = os.name == 'nt'
if IS_WINDOWS:
    import ctypes
    import msvcrt
else:
    import fcntl

API = 'https://call.openweb.co.za/api/v1/wizard'
HELPER = Path(__file__).with_name('onboarding.py') if IS_WINDOWS else Path('/opt/openwebpbx/tools/onboarding.py')
STATE = Path('/var/lib/openwebpbx/image-onboarding')
PROOFS = Path('/var/lib/openwebpbx/tenant-domains/proofs/.well-known/openwebpbx-instance')
KEY = Path('/etc/fusionpbx/tenant-domains-instance-key.pem')


class Pending(RuntimeError):
    """A redacted recoverable state; private response bodies are never logged."""
    def __init__(self, message, seconds=30):
        self.seconds = max(30, min(86400, int(seconds)))
        super().__init__(message)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class IPv4HTTPSConnection(http.client.HTTPSConnection):
    """Keep peer enrollment and the installer's public IPv4 proof consistent.

    Resolve only A addresses while keeping the original hostname for TLS/SNI.
    This affects this fixed API transport, not SIP, the OS resolver or other apps.
    """
    def connect(self):
        if self._tunnel_host:
            raise OSError('An onboarding proxy tunnel is not permitted.')
        last = None
        for family, kind, protocol, _, address in socket.getaddrinfo(self.host, self.port, socket.AF_INET, socket.SOCK_STREAM):
            stream = socket.socket(family, kind, protocol)
            try:
                if self.timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                    stream.settimeout(self.timeout)
                if self.source_address:
                    stream.bind(self.source_address)
                stream.connect(address)
                self.sock = self._context.wrap_socket(stream, server_hostname=self.host)
                return
            except OSError as error:
                last = error
                stream.close()
        raise last or OSError('The registration authority has no reachable IPv4 address.')


class IPv4HTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, request):
        return self.do_open(IPv4HTTPSConnection, request, context=self._context)


def ordinary(path):
    path = Path(path)
    for part in (path, *path.parents):
        if part.is_symlink() or (part.exists() and getattr(part.lstat(), 'st_file_attributes', 0) & 0x400):
            raise ValueError('Linked onboarding paths are not supported.')
        if part.exists():
            value = part.lstat()
            if not IS_WINDOWS and (value.st_uid != 0 or value.st_mode & 0o022):
                raise ValueError('Onboarding files must be owned by root and protected against writes.')
    return path


def private(path):
    path = ordinary(path)
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or (not IS_WINDOWS and value.st_mode & 0o077):
        raise ValueError('A private regular onboarding file is required.')
    return path


def atomic(path, data, public=False):
    path = ordinary(path)
    if not path.parent.is_dir():
        raise ValueError('The installed onboarding directory is unavailable.')
    if path.exists() and (not path.is_file() or path.stat().st_nlink != 1):
        raise ValueError('An ordinary onboarding destination is required.')
    fd, temporary = tempfile.mkstemp(prefix='.onboarding-', dir=path.parent)
    try:
        if not IS_WINDOWS:
            os.fchmod(fd, 0o640 if public else 0o600)
            os.fchown(fd, 0, 33 if public else 0)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        if not IS_WINDOWS:
            folder = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(folder)
            finally:
                os.close(folder)
    finally:
        Path(temporary).unlink(missing_ok=True)


def identifier(value, version=None):
    parsed = uuid.UUID(value)
    if str(parsed) != value or parsed.int == 0 or (version and parsed.version != version):
        raise ValueError('The installed server identity is invalid.')
    return value


def nonce(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value):
        raise ValueError('The setup proof is invalid.')
    return value


def node(value, bootstrap):
    expected = 'node-' + identifier(bootstrap, 4).replace('-', '') + '.openwebpbx.com'
    if value != expected:
        raise ValueError('The assigned hostname does not belong to this server.')
    return expected


def decode_json(raw):
    if len(raw) > 65536:
        raise ValueError('An onboarding response exceeded its permitted size.')
    reply = json.loads(raw)
    if not isinstance(reply, dict):
        raise ValueError('An onboarding object was expected.')
    return reply


class Agent:
    def __init__(self, provider='webhotel'):
        if not (bool(ctypes.windll.shell32.IsUserAnAdmin()) if IS_WINDOWS else os.geteuid() == 0):
            raise ValueError('Instance onboarding requires root or an elevated Windows administrator.')
        if provider not in ('webhotel', 'debian'):
            raise ValueError('Unknown image provider.')
        self.provider = provider
        self.transport = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
            IPv4HTTPSHandler(context=ssl.create_default_context()))

    def helper(self, action, body=None):
        ordinary(HELPER)
        if not HELPER.is_file():
            raise Pending('The installed onboarding helper is unavailable.')
        process = subprocess.run([sys.executable, '-I', '-B', str(HELPER), '--image-' + action],
                                 input=json.dumps(body or {}).encode(), capture_output=True,
                                 timeout=900 if action == 'bind' else 90, check=False)
        if process.returncode:
            raise Pending('The local server is still being prepared (' + action + ').')
        return decode_json(process.stdout)

    def post(self, route, body):
        if route not in ('/devices', '/devices/poll', '/devices/bootstrap', '/devices/challenge',
                         '/devices/authorize', '/devices/complete'):
            raise ValueError('Unknown image setup operation.')
        request = urllib.request.Request(API + route,
            json.dumps(body, separators=(',', ':')).encode(), method='POST',
            headers={'Content-Type': 'application/json', 'Accept': 'application/json',
                     'User-Agent': 'OpenWebPBX-Image-Onboarding/1'})
        try:
            with self.transport.open(request, timeout=45) as response:
                return decode_json(response.read(65537))
        except urllib.error.HTTPError as error:
            try:
                code = decode_json(error.read(65537)).get('error', {}).get('code', '')
            except (ValueError, AttributeError):
                code = ''
            if code == 'device_expired':
                raise Pending('device_expired') from None
            if not re.fullmatch(r'[a-z_]{1,64}', str(code)):
                code = 'temporarily_unavailable'
            try:
                delay = int(error.headers.get('Retry-After', '30'))
            except (ValueError, TypeError):
                delay = 30
            raise Pending('Setup is waiting for the registration service (' + code + ').', delay) from None
        except (urllib.error.URLError, TimeoutError):
            raise Pending('Setup is waiting for a secure internet connection.') from None

    def sign(self, metadata, message):
        if not isinstance(message, str) or len(message.encode()) > 8192:
            raise ValueError('The setup signature message is invalid.')
        if IS_WINDOWS:
            # The installed bridge validates its private key ACL and signs with
            # the same P256 identity; no OpenSSL executable is needed on Windows.
            reply = self.helper('sign', {'message':message})
            signature = reply.get('signature', '')
            if not isinstance(signature, str) or len(signature) > 200 or not base64.b64decode(signature, validate=True):
                raise ValueError('The installed signer returned an invalid signature.')
            return signature
        if metadata.get('key_path') != str(KEY):
            raise ValueError('Use the installed instance identity.')
        private(KEY)
        derived = subprocess.run(['openssl', 'pkey', '-in', str(KEY), '-pubout', '-outform', 'DER'],
                                 capture_output=True, timeout=15, check=True).stdout
        if base64.b64encode(derived).decode() != metadata['public_key']:
            raise ValueError('The installed public identity does not match its private key.')
        process = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(KEY)],
                                 input=message.encode(), capture_output=True, timeout=15, check=True)
        return base64.b64encode(process.stdout).decode()

    def proof(self, metadata, value, body):
        if not isinstance(body, str) or len(body.encode()) > 1024:
            raise ValueError('An onboarding proof exceeded its permitted size.')
        if IS_WINDOWS:
            self.helper('proof', {'nonce':nonce(value), 'body':body})
            return
        if metadata.get('proof_root') != str(PROOFS) or not ordinary(PROOFS).is_dir():
            raise ValueError('Use the installed proof directory.')
        atomic(PROOFS / nonce(value), body.encode(), public=True)

    def save(self, state):
        atomic(self.state_root / 'session.json', json.dumps(state, separators=(',', ':')).encode())

    def state_directory(self, metadata):
        # --image-init authenticates the installed private_root's native ACL.
        # Newly created Windows children inherit only SYSTEM/Administrators.
        root = Path(metadata['private_root']) / 'image-onboarding' if metadata.get('private_root') else STATE
        if IS_WINDOWS and not metadata.get('private_root'):
            raise ValueError('The installed private onboarding directory is required.')
        ordinary(root)
        root.mkdir(mode=0o700, parents=False, exist_ok=True)
        if not IS_WINDOWS and root.stat().st_mode & 0o077:
            raise ValueError('A private image-onboarding directory is required.')
        self.state_root = root
        return root

    def cycle(self, metadata=None):
        metadata = metadata or self.helper('init')
        self.state_directory(metadata)
        for field in ('local_tenant_uuid', 'domain_uuid'):
            identifier(metadata[field])
        identifier(metadata['bootstrap_uuid'], 4)
        expected_node = 'node-' + metadata['bootstrap_uuid'].replace('-', '') + '.openwebpbx.com'
        public = base64.b64decode(metadata['public_key'], validate=True)
        key_hash = hashlib.sha256(public).hexdigest()
        identity = {field: metadata[field] for field in ('local_tenant_uuid', 'domain_uuid', 'bootstrap_uuid', 'public_key')}
        path = self.state_root / 'session.json'
        if path.exists():
            private(path)
            state = decode_json(path.read_bytes())
            if state.get('identity') != identity:
                raise ValueError('This saved setup belongs to a different server. Do not clone live instance state.')
        else:
            created = self.post('/devices', dict(identity, provider=self.provider, image_version=metadata['image_version']))
            if not re.fullmatch(r'owpd_[a-f0-9]{64}', created.get('device_code', '')):
                raise ValueError('The setup credential is invalid.')
            identifier(created['pairing_uuid'])
            if not re.fullmatch(r'[A-F0-9]{5}-[A-F0-9]{5}', created.get('user_code', '')):
                raise ValueError('The setup code is invalid.')
            state = {'identity': identity, 'device_code': created['device_code'], 'pairing_uuid': created['pairing_uuid'],
                     'user_code': created['user_code'], 'expires_at': created['expires_at']}
            self.save(state)
            # The console link contains only the short-lived user code, never the device credential.
            link = 'https://openwebpbx.com/wizard#code=' + created['user_code']
            atomic(self.state_root / 'setup.txt', ('OpenWeb PBX setup\n' + link + '\n').encode())
            print('OpenWeb PBX setup: ' + link, flush=True)
        if not state.get('displayed'):
            self.helper('display', {'user_code':state['user_code'], 'verification_uri_complete':'https://openwebpbx.com/wizard#code=' + state['user_code'],
                                    'pairing_uuid':state['pairing_uuid'], 'expires_at':state['expires_at']})
            state['displayed'] = True
            self.save(state)
        credential = {'device_code': state['device_code']}
        try:
            poll = self.post('/devices/poll', credential)
        except Pending as error:
            if str(error) == 'device_expired':
                # Same-image rotation preserves any previously claimed owner and canonical DNS binding.
                path.unlink()
                raise Pending('The setup code expired. A fresh setup link will be created on the next check.') from None
            raise
        for field in ('local_tenant_uuid', 'domain_uuid', 'bootstrap_uuid'):
            if poll.get(field) != metadata[field]:
                raise ValueError('The setup response belongs to a different server.')
        if poll.get('key_hash') != key_hash:
            raise ValueError('The setup response has a different instance key.')
        phase = poll.get('state')
        if phase == 'pending':
            return {'state': 'waiting_for_owner', 'setup_url': 'https://openwebpbx.com/wizard#code=' + state['user_code']}
        if phase in ('claimed', 'bootstrap_pending'):
            proof_nonce = nonce(poll['nonce'])
            address = poll['server_address']
            body = 'openwebpbx-bootstrap-v1\n' + proof_nonce + '\n' + key_hash + '\n' + address + '\n'
            if poll.get('proof_body') != body:
                raise ValueError('The server proof does not match this installation.')
            self.proof(metadata, proof_nonce, body)
            account = identifier(poll['account_tenant_uuid'])
            label = poll['label']
            if not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,38}[a-z0-9]', label):
                raise ValueError('The chosen tenant name is invalid.')
            message = ('openwebpbx-bootstrap-v1\n' + proof_nonce + '\n' + address + '\n' + key_hash + '\n'
                       + metadata['bootstrap_uuid'] + '\n' + account + '\n' + metadata['local_tenant_uuid'] + '\n'
                       + metadata['domain_uuid'] + '\n' + label + '\n')
            reply = self.post('/devices/bootstrap', dict(credential, signature=self.sign(metadata, message)))
            node(reply['server_host'], metadata['bootstrap_uuid'])
            return {'state': reply['state']}
        server_host = node(poll.get('server_host'), metadata['bootstrap_uuid'])
        if phase == 'dns_ready':
            self.helper('bind', {'server_host': server_host})
            challenge = self.post('/devices/challenge', credential)
            proof_nonce = nonce(challenge['nonce'])
            expected = 'openwebpbx-instance-v1\n' + proof_nonce + '\n' + key_hash + '\n' + expected_node + '\n'
            if challenge.get('proof_body') != expected or challenge.get('key_hash') != key_hash:
                raise ValueError('The authorization proof does not match this installation.')
            self.proof(metadata, proof_nonce, expected)
            message = ('openwebpbx-installation-v1\n' + proof_nonce + '\n' + server_host + '\n' + key_hash + '\n'
                       + identifier(challenge['account_tenant_uuid']) + '\n' + metadata['local_tenant_uuid'] + '\n'
                       + metadata['domain_uuid'] + '\n' + poll['label'] + '\n')
            authorized = self.post('/devices/authorize', dict(credential, challenge_uuid=identifier(challenge['challenge_uuid']),
                                                             signature=self.sign(metadata, message)))
            self.helper('store', {'activation': authorized['activation']})
            return {'state': 'authorized'}
        if phase not in ('authorized', 'complete'):
            raise Pending('The server setup is waiting for the next registration check.')
        # The helper independently validates the pinned RSA signature and every local identity binding.
        self.helper('store', {'activation': poll['activation']})
        local = self.helper('status')
        if not local.get('ready'):
            return {'state': 'waiting_for_tenant_https'}
        hostname = local.get('hostname', '')
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.openwebpbx\.com', hostname):
            raise ValueError('The installed tenant address is invalid.')
        if phase != 'complete':
            complete_nonce = nonce(poll['complete_nonce'])
            proof_body = 'openwebpbx-instance-v1\n' + complete_nonce + '\n' + key_hash + '\n' + server_host + '\n'
            self.proof(metadata, complete_nonce, proof_body)
            message = ('openwebpbx-complete-v1\n' + complete_nonce + '\n' + key_hash + '\n' + server_host + '\n'
                       + hostname + '\n' + metadata['domain_uuid'] + '\n')
            self.post('/devices/complete', dict(credential, hostname=hostname, signature=self.sign(metadata, message)))
        # Refresh before expiry without retaining any owner login on this machine.
        activation = poll.get('activation', {})
        payload = activation.get('payload', '')
        decoded = decode_json(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        expiry = dt.datetime.fromisoformat(decoded['expires_at'].replace('Z', '+00:00'))
        if expiry - dt.datetime.now(dt.timezone.utc) < dt.timedelta(days=30):
            challenge = self.post('/devices/challenge', credential)
            proof_nonce = nonce(challenge['nonce'])
            self.proof(metadata, proof_nonce, challenge['proof_body'])
            message = ('openwebpbx-installation-v1\n' + proof_nonce + '\n' + server_host + '\n' + key_hash + '\n'
                       + identifier(challenge['account_tenant_uuid']) + '\n' + metadata['local_tenant_uuid'] + '\n'
                       + metadata['domain_uuid'] + '\n' + poll['label'] + '\n')
            authorized = self.post('/devices/authorize', dict(credential, challenge_uuid=identifier(challenge['challenge_uuid']),
                                                             signature=self.sign(metadata, message)))
            self.helper('store', {'activation': authorized['activation']})
        return {'state': 'ready', 'url': 'https://' + hostname}


def run_once(provider='debian', metadata=None):
    """One locked, retry-aware step for both the CLI and installed scheduler."""
    os.umask(0o077)
    agent = Agent(provider)
    try:
        metadata = metadata or agent.helper('init')
        directory = agent.state_directory(metadata)
    except Pending as error:
        return {'state':'pending','message':str(error)}
    lock = os.open(ordinary(directory / 'worker.lock'), os.O_CREAT | os.O_RDWR | getattr(os,'O_NOFOLLOW',0), 0o600)
    try:
        private(directory / 'worker.lock')
        try:
            if IS_WINDOWS:
                if os.fstat(lock).st_size == 0:
                    os.write(lock, b'\0')
                os.lseek(lock, 0, os.SEEK_SET)
                msvcrt.locking(lock, msvcrt.LK_NBLCK, 1)
            else:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if isinstance(error, BlockingIOError) or (IS_WINDOWS and error.errno in (13, 36)):
                return {'state':'busy'}
            raise
        try:
            retry = directory / 'retry.json'
            if retry.exists():
                private(retry)
                next_attempt = decode_json(retry.read_bytes()).get('next_attempt', 0)
                if next_attempt > time.time():
                    return {'state':'pending','retry_after':max(1,int(next_attempt-time.time()))}
            result = agent.cycle(metadata)
            retry.unlink(missing_ok=True)
            return result
        except Pending as error:
            atomic(directory / 'retry.json', json.dumps({'next_attempt':int(time.time()) + error.seconds}).encode())
            return {'state':'pending','message':str(error)}
    finally:
        os.close(lock)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=('webhotel', 'debian'), default='webhotel')
    options = parser.parse_args(argv)
    print(json.dumps(run_once(options.provider), separators=(',', ':')), flush=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        print('OpenWeb PBX image setup could not complete its protected local checks. Inspect the installed onboarding helper.', file=sys.stderr)
        raise SystemExit(1)
