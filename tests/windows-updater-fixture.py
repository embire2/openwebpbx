#!/usr/bin/env python3
"""SPDX-License-Identifier: AGPL-3.0-or-later.

Private disposable Windows updater transport and normal administrator requests.
The service retains its production URL allowlist and embedded signing key.
This server is a laboratory HTTPS endpoint, never a public release/feed server.
"""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import http.cookiejar
import http.server
from html.parser import HTMLParser
import ipaddress
import json
import os
from pathlib import Path
import re
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

FEED_PATH = '/embire2/openwebpbx/releases/latest/download/windows-update-manifest.json'
ASSET_PATH = '/embire2/openwebpbx/releases/download/v1.0.14/openwebpbx-1.0.14-windows-x64.zip'
ESSENTIAL_GATES = ('fresh', 'native_sip_audio', 'backups', 'direct_113_helper_reapply',
                   'direct_failure_rollback', 'restore_gate_startup')


def no_duplicates(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError('Duplicate qualification metadata field.')
        out[key] = value
    return out


def read_json(path, limit=262144):
    raw = Path(path).read_bytes()
    if len(raw) > limit:
        raise ValueError('Qualification metadata exceeds its bound.')
    return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=no_duplicates)


def write_json(path, data):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + '.new')
    with temporary.open('x', encoding='utf-8') as stream:
        json.dump(data, stream, separators=(',', ':'))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def date(value):
    if not isinstance(value, str):
        raise ValueError('An explicit UTC release timestamp is required.')
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('An explicit UTC release timestamp is required.')
    return result.astimezone(timezone.utc)


def verify_packets(packet, base_facts, provenance, archives, public_key, *, now=None,
                   base_version='1.0.13', target_version='1.0.14'):
    """Independent review checks; installed C# verifier still verifies both feeds."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    now = now or datetime.now(timezone.utc)
    if not isinstance(base_version, str) or not isinstance(target_version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', base_version) or not re.fullmatch(r'\d+\.\d+\.\d+', target_version) or tuple(map(int,target_version.split('.'))) <= tuple(map(int,base_version.split('.'))):
        raise ValueError('Exact baseline and genuinely newer canary versions are required.')
    if provenance.get('base_version', base_version) != base_version or provenance.get('target_version', target_version) != target_version:
        raise ValueError('Canary provenance versions differ from the explicit run.')
    if packet.get('schema') != 1 or packet.get('repository') != 'embire2/openwebpbx':
        raise ValueError('A root-reviewed private packet contract is required.')
    for field in ('base_suite_run_id', 'canary_run_id'):
        if not isinstance(packet.get(field), str) or not re.fullmatch(r'[0-9]+', packet[field]):
            raise ValueError('Reviewed workflow identities are required.')
    if packet['base_suite_run_id'] != str(base_facts.get('run_id')) or packet.get('base_source_commit') != base_facts.get('source_commit'):
        raise ValueError('The reviewed baseline identity differs.')
    if any(base_facts.get('gates', {}).get(gate) != 'passed' for gate in ESSENTIAL_GATES) or base_facts.get('state') not in ('passed', 'partial'):
        raise ValueError('The real 1.0.13 baseline has not passed its required gates.')
    if tuple(map(int,base_version.split('.'))) >= (1,0,20) and any(base_facts.get('gates',{}).get(gate) != 'passed' for gate in ('web_readiness','tenant_domains','meeting_transport','meeting_browser')):
        raise ValueError('The current Windows tenant addresses, meeting transport and actual browser media must also be qualified.')
    if provenance.get('source_commit') != base_facts['source_commit'] or provenance.get('base_archive_sha256') != packet.get('base_archive_sha256'):
        raise ValueError('Reviewed canary provenance differs from the baseline.')
    key = serialization.load_pem_public_key(Path(public_key).read_bytes())
    if not isinstance(key, rsa.RSAPublicKey) or key.key_size < 2048:
        raise ValueError('The fixed RSA release public key is required.')
    checked = {}
    previous = 0
    for mode in ('fault', 'normal'):
        record = packet.get(mode)
        if not isinstance(record, dict) or set(record) != {'archive_sha256', 'envelope'}:
            raise ValueError('Both complete reviewed signed canary packets are required.')
        envelope = record['envelope']
        if not isinstance(envelope, dict) or set(envelope) != {'key_id', 'payload', 'signature'} or envelope['key_id'] != 'release-2026-a':
            raise ValueError('The original release signing identity is required.')
        encoded = json.dumps(envelope, separators=(',', ':')).encode()
        if len(encoded) > 262144:
            raise ValueError('Signed canary metadata exceeds its bound.')
        payload_bytes = base64.b64decode(envelope['payload'], validate=True)
        signature = base64.b64decode(envelope['signature'], validate=True)
        key.verify(signature, payload_bytes, padding.PKCS1v15(), hashes.SHA256())
        payload = json.loads(payload_bytes, object_pairs_hook=no_duplicates)
        if (payload.get('schema'), payload.get('product'), payload.get('channel'), payload.get('version')) != (1, 'openwebpbx', 'stable', target_version):
            raise ValueError('A genuine matching newer Windows canary is required.')
        sequence = payload.get('sequence')
        if type(sequence) is not int or not previous < sequence <= 2147483647:
            raise ValueError('Fault then normal private feed sequences must advance.')
        previous = sequence
        published, expires = date(payload.get('published_at')), date(payload.get('expires_at'))
        if published > now + timedelta(minutes=5) or expires <= now or expires <= published:
            raise ValueError('The private signed feed is not current.')
        assets = payload.get('assets')
        if not isinstance(assets, list) or len(assets) != 1:
            raise ValueError('The laboratory envelope must contain only Windows x64.')
        asset = assets[0]
        path = Path(archives[mode])
        expected = {'platform': 'windows-x64', 'name': f'openwebpbx-{target_version}-windows-x64.zip',
                    'url': f'https://github.com/embire2/openwebpbx/releases/download/v{target_version}/openwebpbx-{target_version}-windows-x64.zip'}
        if any(asset.get(k) != value for k, value in expected.items()) or asset.get('minimum_version') != base_version:
            raise ValueError('The production asset URL/version validators must remain intact.')
        if (type(asset.get('bytes')) is not int or not 0 < asset['bytes'] <= 4 * 1024**3 or asset['bytes'] != path.stat().st_size
                or not re.fullmatch(r'[a-f0-9]{64}', record['archive_sha256']) or asset.get('sha256') != record['archive_sha256']
                or digest(path) != asset['sha256']):
            raise ValueError('The root-reviewed complete archive checksum or size differs.')
        checked[mode] = {'sequence': sequence, 'sha256': asset['sha256'], 'bytes': asset['bytes'],
                         'payload_sha256': hashlib.sha256(payload_bytes).hexdigest(), 'envelope': envelope}
    if checked['fault']['sha256'] == checked['normal']['sha256']:
        raise ValueError('Fault and normal canaries must have distinct signed bytes.')
    return checked


class Forms(HTMLParser):
    def __init__(self, text):
        super().__init__(); self.forms = []; self.form = None; self.select = None; self.feed(text)

    def handle_starttag(self, tag, attributes):
        a = dict(attributes)
        if tag == 'form':
            self.form = {'action': a.get('action', ''), 'method': a.get('method', 'get').lower(),
                         'fields': {}, 'buttons': []}; self.forms.append(self.form)
        if self.form is None:
            return
        if tag == 'input' and a.get('name') and 'disabled' not in a:
            if a.get('type') not in ('checkbox', 'radio') or 'checked' in a:
                self.form['fields'][a['name']] = a.get('value', '')
        if tag == 'button' and a.get('name') and 'disabled' not in a:
            self.form['buttons'].append({'name': a['name'], 'value': a.get('value', '')})
        if tag == 'select':
            self.select = a.get('name')
        if tag == 'option' and self.select and (self.select not in self.form['fields'] or 'selected' in a):
            self.form['fields'][self.select] = a.get('value', '')

    def handle_endtag(self, tag):
        if tag == 'form': self.form = None
        if tag == 'select': self.select = None


class Web:
    def __init__(self, settings):
        self.base = 'https://windowsqa.example.invalid:8443'
        context = ssl.create_default_context(cafile=settings['web_ca'])
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), urllib.request.HTTPSHandler(context=context))
        status, _, text = self.request('/login.php')
        forms = Forms(text).forms
        if status != 200 or not forms: raise RuntimeError('The normal HTTPS sign-in form is unavailable.')
        fields = forms[0]['fields'] | {'username': settings['admin_email'], 'password': settings['admin_password']}
        status, _, text = self.request(forms[0]['action'] or '/login.php', fields)
        if status != 200 or 'name="password"' in text: raise RuntimeError('Normal authenticated HTTPS sign-in failed.')

    def request(self, path, fields=None):
        url = urllib.parse.urljoin(self.base + '/', path)
        if urllib.parse.urlsplit(url).netloc != 'windowsqa.example.invalid:8443':
            raise RuntimeError('The normal administrator request changed origin.')
        data = None if fields is None else urllib.parse.urlencode(fields, doseq=True).encode()
        try:
            with self.opener.open(urllib.request.Request(url, data=data), timeout=30) as response:
                return response.status, response.geturl(), response.read(4 * 1024**2).decode()
        except urllib.error.HTTPError as error:
            return error.code, error.geturl(), error.read(4 * 1024**2).decode()

    def submit(self, path, action, fields):
        status, _, text = self.request(path)
        forms = [f for f in Forms(text).forms if f['fields'].get('action') == action
                 and (action is not None or 'provider' in f['fields'])]
        if status != 200 or len(forms) != 1: raise RuntimeError('The exact authenticated CSRF form is unavailable.')
        form = forms[0]
        payload = form['fields'] | fields
        status, url, text = self.request(form['action'] or path, payload)
        if status != 200 or 'setup-message error' in text or 'role="alert"' in text:
            raise RuntimeError('The normal authenticated CSRF operation was rejected.')
        return url, text

    def install(self):
        # Buttons carry the action; the form itself has no action hidden field.
        # Demonstrate CSRF rejection first, then obtain the current actual form.
        denied, _, _ = self.request('/app/pbx_updates/index.php', {'action': 'install'})
        if denied != 403: raise RuntimeError('Missing-CSRF installation was not rejected.')
        status, _, text = self.request('/app/pbx_updates/index.php')
        forms = [f for f in Forms(text).forms if f['method'] == 'post' and {'name': 'action', 'value': 'install'} in f['buttons']]
        if status != 200 or len(forms) != 1 or not re.search(r'name="action" value="install"', text):
            raise RuntimeError('The normal instance administrator installation form is unavailable.')
        fields = forms[0]['fields'] | {'action': 'install'}
        result = self.request('/app/pbx_updates/index.php', fields)
        if result[0] != 200 or 'Request queued.' not in result[2] or 'role="alert"' in result[2]:
            raise RuntimeError('The actual Admin installation request was not queued.')


def prepare_pki(settings, work):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
    now = datetime.now(timezone.utc)
    root_key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'OpenWebPBX disposable updater ' + settings['scope'])])
    root = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(root_key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=10)).not_valid_after(now + timedelta(days=2))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(root_key.public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()), critical=False)
            .sign(root_key, hashes.SHA256()))
    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'github.com')]))
            .issuer_name(name).public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=10)).not_valid_after(now + timedelta(days=1))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('github.com')]), critical=False)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .add_extension(x509.KeyUsage(True, False, True, False, False, False, False, False, False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(leaf_key.public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()), critical=False)
            .sign(root_key, hashes.SHA256()))
    (work / 'transport-root.cer').write_bytes(root.public_bytes(serialization.Encoding.DER))
    (work / 'transport-root.pem').write_bytes(root.public_bytes(serialization.Encoding.PEM))
    (work / 'transport-chain.pem').write_bytes(leaf.public_bytes(serialization.Encoding.PEM) + root.public_bytes(serialization.Encoding.PEM))
    (work / 'transport-leaf.key').write_bytes(leaf_key.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    # The CA key is deliberately neither written nor uploaded.
    write_json(work / 'pki.json', {'root_thumbprint': root.fingerprint(hashes.SHA1()).hex()})


def make_server(settings, work, port=443):
    lock = threading.Lock()
    requests = []
    target_version=settings.get('target_version','1.0.14')
    if not isinstance(target_version,str) or not re.fullmatch(r'\d+\.\d+\.\d+',target_version):
        raise ValueError('An exact numeric canary transport version is required.')
    asset_path=f'/embire2/openwebpbx/releases/download/v{target_version}/openwebpbx-{target_version}-windows-x64.zip'

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
        def do_GET(self):
            if not ipaddress.ip_address(self.client_address[0]).is_loopback or self.headers.get('Host') != 'github.com' or self.path not in (FEED_PATH, asset_path):
                self.send_error(403); return
            if self.headers.get('User-Agent') != 'OpenWebPBX-Updater/1' or self.headers.get('Range'):
                # Empty caches must produce a complete non-resumed request.
                self.send_error(400); return
            mode = read_json(work / 'mode.json').get('mode')
            if mode not in ('fault', 'normal'): self.send_error(503); return
            if self.path == FEED_PATH:
                body = json.dumps(settings['packets'][mode]['envelope'], separators=(',', ':')).encode()
                source = None; length = len(body)
            else:
                source = Path(settings['archives'][mode]); length = source.stat().st_size
            self.send_response(200); self.send_header('Content-Length', str(length)); self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Cache-Control', 'no-store'); self.send_header('Connection', 'close'); self.end_headers()
            sent = 0; h = hashlib.sha256(); complete = False
            try:
                if source is None:
                    self.wfile.write(body); sent = len(body); h.update(body)
                else:
                    with source.open('rb') as stream:
                        while chunk := stream.read(128 * 1024):
                            self.wfile.write(chunk); sent += len(chunk); h.update(chunk)
                            # Keep a real download window to observe worker progress/PID.
                            time.sleep(.002)
                self.wfile.flush(); complete = sent == length
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError): pass
            with lock:
                requests.append({'mode': mode, 'kind': 'feed' if source is None else 'archive', 'bytes': sent,
                                 'sha256': h.hexdigest(), 'complete': complete, 'loopback': True,
                                 'original_url': True, 'updater_user_agent': True})
                write_json(work / 'transport-requests.json', {'requests': requests})
            self.close_connection = True

    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(work / 'transport-chain.pem', work / 'transport-leaf.key')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    return server


def serve(settings, work):
    server = make_server(settings, work)
    write_json(work / 'transport-ready.json', {'pid': os.getpid(), 'bind': '127.0.0.1', 'port': server.server_port})
    server.serve_forever(poll_interval=.2)


def guard(settings, path):
    if (os.name != 'nt' or os.environ.get('OPENWEB_WINDOWS_UPDATER_TEST') != '1'
            or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx'):
        raise RuntimeError('Explicit disposable hosted Windows updater runner required.')
    expected = Path(os.environ['ProgramData']) / 'OpenWebPBX/updater-qualification'
    if path.name != 'input.json' or path.parent.parent.resolve() != expected.resolve() or not re.fullmatch(r'[a-f0-9]{24}', path.parent.name):
        raise RuntimeError('The private owned updater input path is required.')
    if settings.get('schema') != 1 or settings.get('scope') != path.parent.name or settings.get('run_id') != os.environ['GITHUB_RUN_ID']:
        raise RuntimeError('The exact owned qualification identity is required.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--action', choices=('prepare-pki', 'serve', 'setup', 'request', 'validate'), required=True)
    args = parser.parse_args(); settings = read_json(args.input, 1024**2); guard(settings, args.input)
    work = args.input.parent
    if args.action == 'prepare-pki': prepare_pki(settings, work)
    elif args.action == 'serve': serve(settings, work)
    elif args.action == 'validate':
        packet = read_json(settings['packet_file'])
        provenance = read_json(settings['provenance_file'], 32 * 1024**2)
        if digest(settings['provenance_file']) != packet.get('canary_provenance_sha256'):
            raise RuntimeError('Root-reviewed canary provenance bytes differ.')
        packets = verify_packets(packet, read_json(settings['base_facts']), provenance, settings['archives'], settings['public_key'],
                                 base_version=settings.get('base_version','1.0.13'),target_version=settings.get('target_version','1.0.14'))
        write_json(work / 'verified-packets.json', packets)
    elif args.action == 'request':
        Web(settings).install()
    elif args.action == 'setup':
        web = Web(settings)
        # Explicitly keep automatic installation inactive; use genuine admin CSRF.
        web.submit('/app/pbx_updates/index.php', 'save_instance', {'mode': 'notify', 'maintenance_hour': '2', 'maintenance_duration': '2'})
        values = {'company_name': settings['company_name'], 'service_name': settings['service_name'], 'timezone': 'UTC',
                  'tenant_uuid': '', 'trunk[host]': '', 'trunk[name]': 'No provider', 'trunk[authentication]': 'ip',
                  'outbound[prefix]': '', 'outbound[strip]': '0', 'outbound[prepend]': '', 'inbound_number': '', 'inbound_destination': ''}
        for i, number in enumerate(('8100', '8101')):
            values.update({f'users[{i}][number]': number, f'users[{i}][name]': 'Fictional updater ' + number,
                           f'users[{i}][email]': 'sink@example.invalid'})
        url, _ = web.submit('/app/pbx_setup/?view=wizard', 'review_setup', values)
        if 'view=review' not in url: raise RuntimeError('The real guided setup review is unavailable.')
        web.submit(url, 'create_setup', {'acknowledged': '1'})
        # Save through the ordinary IIS UI; generate a real VAPID identity without
        # sending a push. These private bytes are included in both comparisons.
        web.submit('/app/pbx_mobile/push.php', None, {'enabled': '1', 'provider': 'webpush',
            'delivery': 'direct', 'relay_url': '', 'relay_token': ''})


if __name__ == '__main__':
    try: main()
    except Exception:
        # Every stream remains private in the PowerShell caller. Avoid accidental
        # HTTP bodies, credentials or detailed exception text in workflow logs.
        import traceback
        traceback.print_exc()
        raise SystemExit(1)
