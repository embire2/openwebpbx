"""SPDX-License-Identifier: AGPL-3.0-or-later.
Real hosted IIS multipart upload and native calling; never a full-release gate.
Only the generated Windows V20 fixture is admitted. No stored-path import.
"""
import hashlib
import html
import http.cookiejar
import ipaddress
import json
import re
import secrets
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CASES = (
    'threecx_https_multipart_csrf_preview',
    'threecx_https_import_original_credentials_media',
    'threecx_imported_sip_original_credentials',
    'threecx_imported_direct_decoded_two_way',
    'threecx_imported_ring_group_decoded_two_way',
    'threecx_imported_peer_cleanup',
)
MAX_BODY = 4 * 1024 * 1024


def require(condition):
    if not condition:
        raise AssertionError('Synthetic HTTPS import invariant refused')


class ImportWeb:
    """Trusted TLS and cookies, bounded responses, same-origin redirects only."""
    def __init__(self, address, root_ca):
        require(address == 'https://windowsqa.example.invalid:8443')
        self.base = address
        owner = self
        class Redirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                owner.url(newurl)
                return super().redirect_request(req, fp, code, msg, headers, newurl)
        context = ssl.create_default_context(cafile=str(root_ca))
        self.open = urllib.request.build_opener(urllib.request.ProxyHandler({}), Redirect(),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), urllib.request.HTTPSHandler(context=context))

    def url(self, path):
        url = urllib.parse.urljoin(self.base+'/', path)
        parts = urllib.parse.urlsplit(url)
        require(parts.scheme == 'https' and parts.netloc == 'windowsqa.example.invalid:8443'
                and parts.username is None and parts.password is None)
        return url

    def request(self, path, fields=None, *, body=None, content_type=None):
        require(not (fields is not None and body is not None))
        data = urllib.parse.urlencode(fields, doseq=True).encode() if fields is not None else body
        request = urllib.request.Request(self.url(path), data=data)
        if content_type is not None:
            request.add_header('Content-Type', content_type)
        try:
            response = self.open.open(request, timeout=25)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            self.url(response.geturl())
            raw = response.read(MAX_BODY+1)
            require(len(raw) <= MAX_BODY)
            return response.status, response.geturl(), raw.decode('utf-8')

    def upload(self, path, fields, archive):
        body, content_type = multipart(fields, archive)
        return self.request(path, body=body, content_type=content_type)


def multipart(fields, archive):
    """Build a genuine file part; is_uploaded_file is evaluated by actual PHP/IIS."""
    require(type(archive) is bytes and 0 < len(archive) <= 1048576 and archive.startswith(b'PK'))
    boundary = 'OpenWebFictional'+secrets.token_hex(24)
    require(boundary.encode() not in archive)
    chunks = []
    for name, value in fields.items():
        require(type(name) is str and re.fullmatch('[A-Za-z0-9_]{1,128}', name) is not None
                and type(value) is str and len(value) <= 4096 and boundary not in value)
        chunks.append(('--'+boundary+'\r\nContent-Disposition: form-data; name="'+name+'"\r\n\r\n'+value+'\r\n').encode())
    chunks.append(('--'+boundary+'\r\nContent-Disposition: form-data; name="backup"; filename="synthetic V20.zip"\r\nContent-Type: application/zip\r\n\r\n').encode()+archive+b'\r\n')
    chunks.append(('--'+boundary+'--\r\n').encode())
    return b''.join(chunks), 'multipart/form-data; boundary='+boundary


def selected_form(native, text, action):
    forms = [form for form in native.Forms(text).forms if form['fields'].get('action') == action]
    require(len(forms) == 1)
    return forms[0]


def setup(f, native):
    f.active_case = 'threecx_synthetic_archive'
    require(f.cli('import-archive') == {'synthetic_archive_ready': True})
    f.refresh()
    fixture = f.s['import_fixture']
    archive = Path(fixture['archive'])
    require(archive.parent == f.evidence and archive.name == 'synthetic V20.zip' and not archive.is_symlink())
    require(0 < archive.stat().st_size <= 1048576)
    raw = archive.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == fixture['archive_sha256'])
    f.web = ImportWeb(f.s['public_url'], f.evidence/'fixture-root.pem')
    web = f.web
    f.active_case = 'threecx_admin_login'
    status, _, text = web.request('/login.php'); require(status == 200)
    forms = [form for form in native.Forms(text).forms if 'username' in form['fields'] and 'password' in form['fields']]
    require(len(forms) == 1)
    fields = dict(forms[0]['fields']); fields.update(username=f.s['admin_email'], password=f.s['admin_password'])
    status, _, text = web.request(forms[0]['action'] or '/login.php', fields)
    require(status == 200 and 'name="password"' not in text)
    f.active_case = 'threecx_upload_csrf'
    status, _, _ = web.upload('/app/pbx_setup/', {'action': 'analyze_import'}, raw)
    require(status == 403)
    require(f.cli('import-empty') == {'no_upload_or_draft_created': True})
    status, _, text = web.request('/app/pbx_setup/?view=import'); require(status == 200)
    form = selected_form(native, text, 'analyze_import')
    fields = dict(form['fields']); fields.pop('backup', None)
    f.active_case = 'threecx_multipart_upload'
    status, url, text = web.upload(form['action'] or '/app/pbx_setup/?view=import', fields, raw)
    # Capture only exact generated-archive ownership before validating HTTP output.
    require(f.cli('import-upload') == {'uploaded_archive_exact': True, 'owned_draft': True})
    f.refresh(); require(status == 200)
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
    require(query.get('view') == ['import_preview'] and query.get('draft') == [f.s['import_fixture']['draft_uuid']])
    require('setup-message error' not in text)
    for user in fixture['users']:
        require(user['password'] not in html.unescape(text))
    form = selected_form(native, text, 'create_import')
    require(form['fields']['draft_id'] == f.s['import_fixture']['draft_uuid'])
    f.record(CASES[0])
    f.active_case = 'threecx_create_csrf'
    values = {'action': 'create_import', 'draft_id': form['fields']['draft_id'],
        'company_name': f.s['company_name'], 'service_name': f.s['service_name'],
        'timezone': 'UTC', 'tenant_uuid': '', 'sip_domain': '', 'acknowledge_limitations': '1'}
    require(web.request(form['action'] or url, values)[0] == 403)
    f.active_case = 'threecx_create_import'
    fields = dict(form['fields']); fields.update(values)
    status, _, text = web.request(form['action'] or url, fields)
    require(status == 200 and 'setup-message error' not in text and 'role="alert"' not in text)
    expected = {'original_credentials_exact': True, 'phone_line_exact': True, 'restored_media_exact': True,
        'provider_disabled': True, 'owned_draft_completed': True}
    require(f.cli('import-discover') == expected); f.refresh(); f.record(CASES[1])


def calls(f, native):
    sip = native.load_module('sip_trunk_live', f.source/'tests/sip_trunk_live.py')
    original = native.load_module('threecx_https_source_phone', f.source/'tests/pbx_v20_restore_native.py')
    # Relocate the peer's private failure dump; protocol/media logic is unchanged.
    original.Path = lambda path: f.evidence/'last-private-response.txt' if str(path).startswith('/var/lib/') else Path(path)
    restore = native.load_module('threecx_https_windows_phone', f.source/'tests/windows-restore-qualification.py')
    phone = restore.windows_restore_phone(original.SourcePhone, native.WindowsRtpSocket)
    bind = f.cli('status')['bind']; address = ipaddress.ip_address(bind)
    require(address.version == 4 and not address.is_unspecified and not address.is_multicast)
    with socket.socket() as probe: probe.bind((bind, 0))
    destination = (bind, 5060); peers = []; active_call = None; primary = None; cleanup = []
    try:
        for user in f.s['users']: peers.append(phone(user, f.s['realm'], bind))
        caller, called = peers
        f.active_case = 'threecx_imported_registration'
        require(caller.register(destination, password='fictional-deliberately-wrong')['code'] in (401, 403))
        for peer in peers:
            result = peer.register(destination)
            require(result['code'] == 200 and result['digest_challenge_count'] >= 1)
        foreign = native.SIPClient('udp', bind, destination, f.s['realm'], f.evidence/'fixture-root.pem', 'windowsqa.example.invalid')
        rejected = None; foreign_cleanup = None; accepted = False
        foreign_realm = 'foreign-'+f.s['scope']+'.example.invalid'
        try:
            intent = {'schema': 1, 'realm': foreign_realm, 'aor': f.s['users'][0]['number'],
                'auth': f.s['users'][0]['auth'], 'address': bind, 'port': foreign.port,
                'contact': 'sip:'+f.s['users'][0]['number']+'@'+bind+':'+str(foreign.port)+';transport=udp',
                'call_id': secrets.token_hex(16)+'@fictional', 'tag': secrets.token_hex(12)}
            key = (intent['aor'], foreign_realm, intent['aor'])
            require(key not in foreign.registrations)
            foreign.registrations[key] = {'cid': intent['call_id'], 'tag': intent['tag'], 'seq': 0}
            require(f.cli('import-foreign-intent', json.dumps(intent, separators=(',', ':'))) == {'foreign_registration_intent_saved': True})
            result = foreign.register(f.s['users'][0], realm=foreign_realm)
            accepted = result['code'] == 200
            require(result['code'] in (401, 403, 404))
        except BaseException as error: rejected = error
        finally:
            try:
                if accepted:
                    # Even an unexpected acceptance owns a synthetic contact;
                    # remove it before propagating the original refusal.
                    require(foreign.register(f.s['users'][0], realm=foreign_realm, expires=0)['code'] == 200)
                    require(foreign.register(f.s['users'][0], realm=foreign_realm, query=True)['contacts'] == [])
            except BaseException as error: foreign_cleanup = error
            finally: foreign.close()
        if rejected is not None: raise rejected
        if foreign_cleanup is not None: raise foreign_cleanup
        f.record(CASES[2])
        for number, case in (('9101', CASES[3]), ('9180', CASES[4])):
            f.active_case = case
            if number == '9180':
                # Keep the restored group untouched, leaving only its called member
                # registered so the originating peer cannot answer its own fork.
                require(caller.register(destination, expires=0)['code'] == 200)
            before = set(called.dialogs); active_call = caller.dial(number, destination)
            require(active_call['code'] == 200)
            remote = f.wait(lambda: next((state for cid, state in called.dialogs.items() if cid not in before and state.get('acked')), None))
            views = native.bridged_media_window({'caller': active_call['media'], 'destination': remote}, 3, sip.rtp_rate_check)
            original.decoded_tone_check(views['caller'], called.tone_hz)
            original.decoded_tone_check(views['destination'], caller.tone_hz)
            for peer in peers: peer.check_receiver()
            caller.hangup(active_call); active_call = None
            f.record(case)
        # Re-read the original tuples and imported media after all actual calls.
        require(f.cli('import-discover')['original_credentials_exact'] is True)
    except BaseException as error:
        primary = error
    finally:
        if active_call is not None:
            try: peers[0].hangup(active_call)
            except BaseException as error: cleanup.append(error)
        for peer in peers:
            try:
                require(peer.register(destination, expires=0)['code'] == 200)
                require(f.cli('api', 'sofia_contact '+peer.auth_user+'@'+f.s['realm'], json_result=False).strip().startswith('error/'))
            except BaseException as error: cleanup.append(error)
            finally:
                try: peer.close()
                except BaseException as error: cleanup.append(error)
    if primary is not None: raise primary
    require(not cleanup)
    f.record(CASES[5])


def run(f, native):
    require(f.s.get('threecx_import_only') is True and f.s.get('native_diagnostics_only') is True
            and not f.s.get('hold_diagnostics_only'))
    setup(f, native); calls(f, native)
    require(f.web.request('/logout.php')[0] == 200)
    require(f.checks == [{'case': name, 'passed': True} for name in CASES])
