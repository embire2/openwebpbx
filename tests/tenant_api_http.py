#!/usr/bin/env python3
"""Independent HTTP dispatcher + real disposable PostgreSQL tenant API checks.

Copies the exact dispatcher into a private HTTP tree. Its bootstrap connects only
to this test's new PostgreSQL cluster. HTTPS is fixture-injected; these checks do
not qualify public TLS, DNS, SMTP delivery, installed permissions or calling.
"""
from pathlib import Path
import argparse
import http.client
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import tempfile
import time
import uuid


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('--keep-failed', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    base = Path(tempfile.mkdtemp(prefix='openweb-tenant-api-http-'))
    postgres = pwd.getpwnam('postgres')
    os.chown(base, postgres.pw_uid, postgres.pw_gid)
    pg = sorted(Path('/usr/lib/postgresql').glob('*/bin/initdb'), key=lambda p: int(p.parts[-3]))[-1].parent
    pg_port, web_port = free_port(), free_port()
    while web_port == pg_port:
        web_port = free_port()
    state = base/'state'
    state.mkdir(mode=0o700)
    (state/'template.key').write_bytes(os.urandom(32))
    env = os.environ.copy()
    env.update(OPENWEB_TENANT_HTTP_DSN=f'pgsql:host=127.0.0.1;port={pg_port};dbname=postgres',
               OPENWEB_TENANT_HTTP_STATE=str(state))
    web_process = None
    started = False
    passed = False
    cases = []

    def pg_run(*command):
        return subprocess.run(['runuser','-u','postgres','--',*map(str,command)],
                              capture_output=True, check=True, timeout=45)

    def sql(query):
        return pg_run(pg/'psql','-X','-A','-t','-h','127.0.0.1','-p',pg_port,
                      '-d','postgres','-v','ON_ERROR_STOP=1','-c',query).stdout.decode().strip()

    def check(condition, label):
        if not condition:
            raise AssertionError(label)
        cases.append(label)

    def request(method, route, data=None, token=None, extra=None, *, raw=None):
        connection = http.client.HTTPConnection('127.0.0.1', web_port, timeout=15)
        headers = {'Host':'server.example.test'}
        if token is not None:
            headers['Authorization'] = 'Bearer '+token
        headers.update(extra or {})
        if data is not None:
            headers.setdefault('Content-Type','application/json')
            raw = json.dumps(data).encode()
        try:
            connection.request(method, '/api/v1'+route, body=raw, headers=headers)
            response = connection.getresponse()
            value = response.read(1048577)
            if len(value) > 1048576:
                raise AssertionError('HTTP response is unbounded')
            return response.status, json.loads(value) if value else None, dict(response.getheaders())
        finally:
            connection.close()

    try:
        pg_run(pg/'initdb','-D',base/'data','--auth=trust','--no-locale','--encoding=UTF8')
        pg_run(pg/'pg_ctl','-D',base/'data','-l',base/'postgres.fixture.log','-o',
               f'-h 127.0.0.1 -p {pg_port} -k {base} -c fsync=off','-w','start')
        started = True
        setup = subprocess.run(['php',str(root/'tests/tenant_api_http_fixture.php'),'setup'],
                               capture_output=True,text=True,env=env,check=True,timeout=45)
        fixture = json.loads(setup.stdout)
        tree = state/'http'
        (tree/'api/v1').mkdir(parents=True)
        (tree/'resources/classes').mkdir(parents=True)
        source = root/'api/v1/index.php'
        shutil.copyfile(source,tree/'api/v1/index.php')
        bootstrap = '<?php require_once '+json.dumps(str(root/'tests/tenant_api_http_fixture.php'))+';'
        (tree/'resources/require.php').write_text(bootstrap)
        (tree/'resources/classes/config.php').write_text(bootstrap)
        (tree/'router.php').write_text('''<?php
$_SERVER['HTTPS'] = isset($_SERVER['HTTP_X_FIXTURE_PLAINTEXT']) ? '' : 'on';
$_GET['route'] = substr(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), strlen('/api/v1'));
require __DIR__.'/api/v1/index.php';
''')
        with (state/'http.fixture.log').open('wb') as log:
            web_process = subprocess.Popen(['php','-S',f'127.0.0.1:{web_port}','-t',str(tree),str(tree/'router.php')],
                                           stdout=log,stderr=log,env=env)
        for _ in range(100):
            with socket.socket() as sock:
                if sock.connect_ex(('127.0.0.1',web_port)) == 0:
                    break
            if web_process.poll() is not None:
                raise AssertionError('Private HTTP server exited')
            time.sleep(.02)
        else:
            raise AssertionError('Private HTTP server did not listen')
        # Actual operation cases are intentionally kept here, independent of the
        # backend's direct-method tests and of any production installation.
        status, value, headers = request('GET','/me')
        check(status == 401, 'Unauthenticated request is refused')
        check(headers.get('Cache-Control','').lower().find('no-store') >= 0, 'No-store response policy')
        status, _, _ = request('GET','/me',extra={'Cookie':'PHPSESSID=fictional-owner-session'})
        check(status == 401, 'A browser session cookie cannot authorize the API')
        status, _, _ = request('GET','/me',extra={'X-Fixture-Plaintext':'1','X-Forwarded-Proto':'https'})
        check(status == 403, 'Forwarded HTTPS cannot authorize a plain request')
        status, _, _ = request('GET','/me',extra={'Host':'foreign.example.test','X-Forwarded-Host':'server.example.test'})
        check(status == 403, 'Forwarded host cannot authorize a foreign HTTP Host')
        status, value, _ = request('GET','/health')
        check(status == 200 and value['version'] == '1', 'Public health reports API version without tenant details')
        check('tenant_uuid' not in value and 'password' not in json.dumps(value), 'Public health contains no tenant credentials')
        status, _, _ = request('POST','/registrations',raw=b'{}',extra={'Content-Type':'text/plain'})
        check(status == 415, 'Non-JSON registration is refused')
        status, _, _ = request('POST','/registrations',raw=b'[]',extra={'Content-Type':'application/json'})
        check(status == 400, 'JSON arrays cannot replace request objects')
        status, _, _ = request('POST','/registrations',raw=b'{',extra={'Content-Type':'application/json'})
        check(status == 400, 'Malformed JSON is refused')
        status, _, _ = request('POST','/registrations',raw=b'x'*32769,extra={'Content-Type':'application/json'})
        check(status == 413, 'Bodies beyond 32 KiB are refused')
        status, _, _ = request('GET','/health',extra={'Origin':'https://malicious.example.invalid'})
        check(status == 403, 'Cross-origin browser API requests are refused')

        def quote(value):
            return "'"+str(value).replace("'", "''")+"'"

        def register(label):
            data = {'tenant_name':label.title()+' Company','slug':label,'email':label+'@fixture.invalid',
                    'password':'Synthetic account 2026!','accept_terms':True}
            status, value, _ = request('POST','/registrations',data)
            check(status == 202 and value['status'] == 'verification_required', 'Registration accepts '+label+' without an active tenant')
            body = sql('select email_body from v_email_queue where email_to='+quote(data['email'])+' order by email_date desc limit 1')
            tokens = re.findall(r'<code>([a-f0-9]{64})</code>',body)
            check(len(tokens) == 1, 'Only queued recipient mail contains the verification code for '+label)
            check(not re.search(r'[a-f0-9]{64}',json.dumps(value)), 'Registration response does not reveal '+label+' verification token')
            return data,tokens[0],value

        invalid = {'tenant_name':'Invalid','slug':'invalid-company','email':'invalid@fixture.invalid','password':'short','accept_terms':True}
        status, _, _ = request('POST','/registrations',invalid)
        check(status == 400, 'Short registration password is refused')
        invalid.update(password='Synthetic account 2026!',accept_terms=False)
        status, _, _ = request('POST','/registrations',invalid)
        check(status == 400, 'Registration requires explicit terms acceptance')
        invalid.update(accept_terms=True,role='superadmin')
        status, _, _ = request('POST','/registrations',invalid)
        check(status == 400, 'Registration cannot request a platform role')
        alpha,code_a,generic = register('alpha-company')
        check(sql('select count(*) from v_pbx_tenants') == '0', 'Unverified signup creates no tenant account')
        check(sql('select count(*) from v_users') == '1', 'Unverified signup creates no login identity')
        check(sql('select count(*) from v_pbx_api_tokens') == '0', 'Unverified signup creates no API key')
        check(sql("select password_hash like '$2%' from v_pbx_api_registrations") == 't', 'Pending password is hashed')
        status, _, _ = request('POST','/auth/token',{'email':alpha['email'],'password':alpha['password']})
        check(status == 401, 'Unverified owner cannot log into the API')
        status, _, _ = request('POST','/registrations/verify',{'token':'0'*64,'password':alpha['password']})
        check(status == 400, 'Unknown verification code is refused')
        status, _, _ = request('POST','/registrations/verify',{'token':code_a,'password':'Wrong original request 2026!'})
        check(status == 400, 'A mailbox code cannot verify another client signup password')
        status, verified, _ = request('POST','/registrations/verify',{'token':code_a,'password':alpha['password']})
        check(status == 201, 'Correct email code creates the verified tenant')
        key_a = verified['access_token']; tenant_a = verified['tenant']['tenant_uuid']
        check(re.fullmatch(r'owta_[a-f0-9]{64}',key_a) is not None, 'Initial API key contains 256 bits of random material')
        check(sql('select verification_hash is null and password_hash=\'\' from v_pbx_api_registrations') == 't', 'Verified pending secrets are erased')
        check(key_a not in sql('select row_to_json(t)::text from v_pbx_api_tokens t'), 'Database does not store raw API keys')
        status, _, _ = request('POST','/registrations/verify',{'token':code_a,'password':alpha['password']})
        check(status == 400, 'Verification code cannot be replayed')
        status, value, _ = request('GET','/me',token=key_a)
        check(status == 200 and value['tenant']['tenant_uuid'] == tenant_a, 'Bearer key selects only its verified tenant')
        status, value, _ = request('POST','/registrations',alpha)
        check(status == 202 and value == generic, 'Existing registration receives the same generic signup response')
        beta,code_b,_ = register('beta-company')
        status, verified_b, _ = request('POST','/registrations/verify',{'token':code_b,'password':beta['password']})
        check(status == 201, 'Second independent tenant verifies')
        key_b = verified_b['access_token']; tenant_b = verified_b['tenant']['tenant_uuid']
        check(tenant_a != tenant_b, 'Verified companies receive distinct tenant identities')
        status, login, _ = request('POST','/auth/token',{'email':alpha['email'],'password':alpha['password']})
        check(status == 200 and login['tenant']['tenant_uuid'] == tenant_a, 'Verified owner can obtain another key by password login')
        status, _, _ = request('POST','/auth/token',{'email':alpha['email'],'password':'Wrong account 2026!'})
        check(status == 401, 'Wrong password cannot obtain a key')
        status, catalog, _ = request('GET','/templates',token=key_a)
        check(status == 200 and fixture['safe_template'] in [v['template_uuid'] for v in catalog['templates']], 'Eligible published templates are discoverable')
        check(fixture['unsafe_template'] not in [v['template_uuid'] for v in catalog['templates']], 'Shared carrier credentials are excluded from the public catalog')
        check(fixture['not_opted_template'] not in [v['template_uuid'] for v in catalog['templates']], 'Legacy shared templates require explicit API opt-in')
        check('SHARED_PROVIDER_MUST_NOT_LEAK' not in json.dumps(catalog) and 'password' not in json.dumps(catalog), 'Template catalog contains no provider or phone secrets')
        status, _, _ = request('POST','/services',{'template_uuid':fixture['unsafe_template'],'service_name':'Unsafe','slug':'unsafe'},key_a,{'Idempotency-Key':str(uuid.uuid4())})
        check(status == 403, 'Direct unsafe template identifier cannot activate shared carrier credentials')
        check(sql('select count(*) from v_pbx_services') == '0' and sql('select count(*) from v_gateways') == '0', 'Unsafe template attempt creates no service or provider')
        status, _, _ = request('POST','/services',{'template_uuid':fixture['not_opted_template'],'service_name':'Legacy bypass','slug':'legacy-bypass'},key_a,{'Idempotency-Key':str(uuid.uuid4())})
        check(status == 404, 'Direct legacy template UUID cannot bypass public opt-in')
        foreign_home = sql('select home_domain_uuid from v_pbx_tenants where tenant_uuid='+quote(tenant_b))
        gui = subprocess.run(['php',str(root/'tests/tenant_api_http_fixture.php'),'gui-check',tenant_a,fixture['not_opted_template'],fixture['unsafe_template'],foreign_home],env=env,capture_output=True,text=True,check=True,timeout=20)
        gui = json.loads(gui.stdout)
        check(fixture['not_opted_template'] not in gui['templates'] and gui['template_blocked'] and gui['provision_blocked'], 'Public owner cannot bypass template opt-in through the real GUI model')
        check(gui['unsafe_template_blocked'], 'Explicit opt-in cannot expose provider secrets through the GUI model')
        check(not gui['foreign_domain_allowed'], 'Public owner GUI model cannot select another tenant domain')
        check(not gui['smtp_manage'] and gui['smtp_view_blocked'] and gui['smtp_save_blocked'], 'Tenant role cannot read or change instance SMTP settings')
        check(not gui['global_grants'], 'Tenant role receives no global-settings or cross-domain role grants')
        service_input = {'template_uuid':fixture['safe_template'],'service_name':'Main Office','slug':'main-office','subdomain':'alpha-company'}
        status, _, _ = request('POST','/services',service_input,key_a)
        check(status == 400, 'Service creation requires an idempotency UUID')
        create_key = str(uuid.uuid4())
        status, created, _ = request('POST','/services',service_input,key_a,{'Idempotency-Key':create_key})
        check(status == 201, 'Verified tenant creates its isolated PBX service')
        service_a = created['service']['service_uuid']; domain_a = created['service']['domain_uuid']
        check(created['service']['tenant_uuid'] == tenant_a, 'Created PBX is bound to bearer owner')
        check(created['subdomain']['requested_hostname'] == 'alpha-company.openwebpbx.com' and not created['subdomain']['ready'], 'New hostname remains pending until actual DNS and TLS readiness')
        check(sql('select count(*) from v_extensions where domain_uuid='+quote(domain_a)) == '2', 'Template provisions its initial extensions')
        check(sql('select count(distinct password) from v_extensions where domain_uuid='+quote(domain_a)) == '2', 'New extensions have independent generated phone passwords')
        policy = json.loads(sql('select config from v_pbx_restore where domain_uuid='+quote(domain_a)))
        native = json.loads(sql('select json_agg(t) from (select extension_uuid,extension,password from v_extensions where domain_uuid='+quote(domain_a)+' order by extension)t'))
        check(set(policy['users']) == {v['extension'] for v in native}, 'Desktop lists every provisioned PBX user')
        check({v['extension_uuid'] for v in policy['users'].values()} == {v['extension_uuid'] for v in native}, 'Desktop policy uses exact native extension identities')
        check(all(v['profile'] == 'Available' for v in policy['users'].values()), 'New user profiles have the current safe availability defaults')
        check(not any(v['password'] in json.dumps(created) for v in native), 'Provisioning response reveals no native phone passwords')
        check(policy['trunks'] == {} and not policy['outbound_rules'], 'New API PBX has no enabled or inherited provider')
        check(sql('select count(*) from v_dialplans where domain_uuid='+quote(domain_a)+" and dialplan_xml like '%app.lua pbx_setup user%'") == '2', 'Each new user has its actual PBX Lua route')
        for path in ['/core/desktop/','/core/desktop/admin.php','/app/tenant_services/','/app/pbx_setup/','/app/pbx_greetings/',
                     '/app/pbx_mobile/','/app/pbx_phone_health/','/app/pbx_meet/','/logout.php']:
            probe = subprocess.run(['php',str(root/'tests/tenant_api_http_fixture.php'),'gui-path',tenant_a,service_a,path],env=env,capture_output=True,text=True,check=True,timeout=10)
            check(probe.stdout == 'FIXTURE_PATH_ALLOWED', 'Public tenant retains current app path '+path)
        for path in ['/core/users/user_edit.php','/core/users/user_profile.php','/core/default_settings/','/core/groups/','/app/smtp_settings/',
                     '/app/email_queue/','/app/sofia_global_settings/','/app/switch/','/app/tenant_services/../smtp_settings/',
                     '/app/tenant_services/%2e%2e/smtp_settings/','/core/desktop\\..\\users/user_edit.php','//core/desktop/']:
            probe = subprocess.run(['php',str(root/'tests/tenant_api_http_fixture.php'),'gui-path',tenant_a,service_a,path],env=env,capture_output=True,text=True,check=True,timeout=10)
            check('FIXTURE_PATH_ALLOWED' not in probe.stdout, 'Public tenant cannot reach legacy or ambiguous app path '+path)
        status, replay, replay_headers = request('POST','/services',dict(reversed(list(service_input.items()))),key_a,{'Idempotency-Key':create_key})
        check(status == 201 and replay == created and replay_headers.get('Idempotent-Replayed') == 'true', 'Identical reordered JSON request replays the original service response')
        check(sql('select count(*) from v_pbx_services') == '1', 'A retry cannot create a duplicate PBX')
        changed = service_input | {'service_name':'Changed name'}
        status, _, _ = request('POST','/services',changed,key_a,{'Idempotency-Key':create_key})
        check(status == 409, 'Reused idempotency key with changed body is refused')
        status, _, _ = request('POST','/services',service_input | {'slug':'another-office','subdomain':'another-office'},key_a,{'Idempotency-Key':str(uuid.uuid4())})
        check(status == 409, 'One-service public account quota is enforced')
        status, listing, _ = request('GET','/services',token=key_b)
        check(status == 200 and listing['services'] == [], 'Another tenant cannot list the new PBX')
        for suffix in ['', '/subdomain']:
            status, _, _ = request('GET','/services/'+service_a+suffix,token=key_b)
            check(status == 404, 'Foreign service '+(suffix or 'details')+' remains unavailable')
        status, _, _ = request('POST','/services/'+service_a+'/subdomain',{'label':'taken-by-foreign'},key_b,{'Idempotency-Key':str(uuid.uuid4())})
        check(status == 404, 'Another tenant cannot change a PBX hostname')
        status, owned, _ = request('GET','/services/'+service_a,token=key_a)
        check(status == 200 and owned['service']['service_uuid'] == service_a, 'Owner can inspect its PBX')
        status, availability, _ = request('GET','/subdomains/availability?label=alpha-company',token=key_b)
        check(status == 200 and not availability['available'] and not availability['reservation_confirmed'], 'Availability respects reserved local names without claiming global ownership')
        for bad in ['admin','https://bad.openwebpbx.com','UPPERCASE','xn--example','-invalid']:
            from urllib.parse import quote as urlquote
            status, _, _ = request('GET','/subdomains/availability?label='+urlquote(bad,safe=''),token=key_a)
            check(status == 400, 'Invalid or reserved subdomain is refused: '+bad)
        status, _, _ = request('POST','/services/'+service_a+'/subdomain',{'label':'different-label'},key_a,{'Idempotency-Key':str(uuid.uuid4())})
        check(status == 409, 'Existing hostname cannot be renamed through the API')
        status, _, _ = request('POST','/services/'+service_a+'/subdomain',{'label':'alpha-company'},key_a,{'Idempotency-Key':str(uuid.uuid4())})
        check(status == 200, 'Owner can safely repeat its exact hostname request')
        status, child, _ = request('POST','/tokens',{'name':'CI integration','expires_in_days':2},key_a)
        check(status == 201, 'Owner creates a separately revocable API key')
        child_key = child['access_token']; child_id = child['token']['token_uuid']
        status, keys, _ = request('GET','/tokens',token=key_a)
        check(status == 200 and child_key not in json.dumps(keys) and 'token_hash' not in json.dumps(keys), 'Key inventory exposes metadata only')
        status, _, _ = request('DELETE','/tokens/'+child_id,token=key_b)
        check(status == 404, 'Foreign tenant cannot revoke another tenant key')
        status, rotated, _ = request('POST','/tokens/'+child_id+'/rotate',{},key_a)
        check(status == 201 and rotated['access_token'] != child_key, 'Key rotation issues a fresh secret')
        status, _, _ = request('GET','/me',token=child_key)
        check(status == 401, 'Rotated old secret is immediately refused')
        status, _, _ = request('GET','/me',token=rotated['access_token'])
        check(status == 200, 'Rotated replacement secret works')
        status, empty, _ = request('DELETE','/tokens/'+rotated['token']['token_uuid'],token=key_a)
        check(status == 204 and empty is None, 'Revocation returns an empty 204 response')
        status, _, _ = request('GET','/me',token=rotated['access_token'])
        check(status == 401, 'Revoked replacement key cannot authenticate')
        status, expired, _ = request('POST','/tokens',{'name':'Expiry check','expires_in_days':1},key_a)
        check(status == 201, 'Expiry fixture obtains an ordinary tenant key')
        sql('update v_pbx_api_tokens set expires_at=now()-interval \'1 second\' where token_uuid='+quote(expired['token']['token_uuid']))
        status, _, _ = request('GET','/me',token=expired['access_token'])
        check(status == 401, 'Expired bearer key is refused')
        sql('update v_pbx_tenants set enabled=false where tenant_uuid='+quote(tenant_a))
        status, _, _ = request('GET','/me',token=key_a)
        check(status == 401, 'Suspended tenant invalidates existing API credentials')
        sql('update v_pbx_tenants set enabled=true where tenant_uuid='+quote(tenant_a))
        status, _, _ = request('GET','/me',token=key_a)
        check(status == 200, 'Re-enabled tenant retains its original account identity')
        sql("update v_group_permissions set permission_assigned='false' where permission_name='pbx_service_create'")
        status, _, _ = request('POST','/services',{'template_uuid':fixture['safe_template'],'service_name':'Denied','slug':'denied'},key_b,{'Idempotency-Key':str(uuid.uuid4())})
        check(status == 403, 'Removing service-creation permission prevents new PBX creation')
        check(sql('select count(*) from v_pbx_services') == '1', 'Denied requests leave existing service inventory unchanged')
        sql("update v_group_permissions set permission_assigned='true' where permission_name='pbx_service_create'")
        before_collision = {table:sql('select count(*) from '+table) for table in ['v_domains','v_extensions','v_voicemails','v_dialplans','v_dialplan_details','v_pbx_services','v_pbx_restore','v_pbx_api_idempotency']}
        status, _, _ = request('POST','/services',service_input,key_b,{'Idempotency-Key':str(uuid.uuid4())})
        check(status == 409, 'Another owner cannot claim an existing managed subdomain')
        check(all(sql('select count(*) from '+table) == count for table,count in before_collision.items()), 'Alias collision rolls back every new service, user, route, policy and idempotency row')
        status, created_b, _ = request('POST','/services',service_input | {'subdomain':'beta-company'},key_b,{'Idempotency-Key':create_key})
        check(status == 201 and created_b['service']['tenant_uuid'] == tenant_b, 'Same idempotency UUID is independently scoped to its tenant')
        check(created_b['service']['service_uuid'] != service_a, 'Independent tenant never receives another tenant replay result')
        status, _, response_headers = request('PUT','/me',token=key_a)
        check(status == 405 and response_headers.get('Allow') == 'GET', 'Unsupported method advertises only its supported method')
        status, _, _ = request('GET','/me?access_token='+key_a)
        check(status == 400, 'Query-string credentials are refused')
        status, _, _ = request('GET','/me',extra={'Authorization':'Basic ZmljdGlvbmFsOmZpY3Rpb25hbA=='})
        check(status == 401, 'Basic credentials cannot replace the API Bearer scheme')
        status, _, _ = request('GET','/me',extra={'Authorization':'Bearer '+key_a+' extra'})
        check(status == 401, 'Extra bearer fragments cannot authorize a request')
        unknown_password = {'email':'rate-limit@fixture.invalid','password':'Unknown account 2026!'}
        for _ in range(8):
            status, _, _ = request('POST','/auth/token',unknown_password)
            check(status == 401, 'Bounded unknown-identity password attempt is refused')
        status, _, retry = request('POST','/auth/token',unknown_password,extra={'X-Forwarded-For':'203.0.113.25'})
        check(status == 429 and retry.get('Retry-After') == '600', 'Password retry limit cannot be bypassed by forwarded client addresses')
        gamma,code_g,_ = register('expired-company')
        sql('update v_pbx_api_registrations set expires_at=now()-interval \'1 second\' where email='+quote(gamma['email']))
        status, _, _ = request('POST','/registrations/verify',{'token':code_g,'password':gamma['password']})
        check(status == 400, 'Expired emailed verification code is refused')
        check(sql('select count(*) from v_pbx_tenants where invite_email='+quote(gamma['email'])) == '0', 'Expired verification creates no tenant')
        register('fifth-company')
        status, _, retry = request('POST','/registrations',alpha | {'email':'sixth@fixture.invalid','slug':'sixth-company'},extra={'X-Forwarded-For':'203.0.113.26'})
        check(status == 429 and retry.get('Retry-After') == '3600', 'Public signup rate limit uses actual peer rather than a forwarded address')
        legacy = subprocess.run(['php',str(root/'tests/tenant_api_http_fixture.php'),'legacy-check'],env=env,capture_output=True,text=True,check=True,timeout=20)
        legacy = json.loads(legacy.stdout)
        check(fixture['not_opted_template'] in legacy['templates'], 'Existing invitation-based tenant template behavior is preserved')
        phones_before = sql('select json_agg(t order by extension_uuid)::text from v_extensions t')
        status, _, _ = request('POST','/me/password',{'current_password':'Wrong current password 2026!','new_password':'Updated synthetic password 2027!'},key_a)
        check(status == 401, 'Changing an account password requires its correct current password')
        status, _, _ = request('POST','/me/password',{'current_password':alpha['password'],'new_password':'short'},key_a)
        check(status == 400, 'Weak replacement account password is refused')
        status, changed_password, _ = request('POST','/me/password',{'current_password':alpha['password'],'new_password':'Updated synthetic password 2027!'},key_a)
        check(status == 200 and changed_password['access_token'] != key_a, 'Password change issues a replacement API credential')
        replacement = changed_password['access_token']
        for old_key in [key_a,login['access_token']]:
            status, _, _ = request('GET','/me',token=old_key)
            check(status == 401, 'Password change immediately revokes every previous owner API key')
        status, _, _ = request('GET','/me',token=replacement)
        check(status == 200, 'Password replacement key remains usable')
        status, _, _ = request('GET','/me',token=key_b)
        check(status == 200, 'Changing one owner password preserves other tenant API keys')
        status, _, _ = request('POST','/auth/token',{'email':alpha['email'],'password':alpha['password']})
        check(status == 401, 'The previous account password no longer logs in')
        status, _, _ = request('POST','/auth/token',{'email':alpha['email'],'password':'Updated synthetic password 2027!'})
        check(status == 200, 'The updated account password logs in normally')
        check(sql('select json_agg(t order by extension_uuid)::text from v_extensions t') == phones_before, 'Account password changes preserve every native phone row and SIP password')
        check(sql('select count(*) from v_users where username=\'platform@fixture.invalid\'') == '1', 'Synthetic platform account is preserved')
        passed = True
        print(json.dumps({'passed':len(cases),'cases':cases,'scope':'isolated HTTP dispatcher/PostgreSQL; fixture HTTPS only'}))
    except Exception:
        if args.keep_failed:
            print('Retained failed fixture:',base)
        raise
    finally:
        if web_process is not None:
            web_process.terminate()
            try:
                web_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                web_process.kill(); web_process.wait(timeout=5)
        if started:
            pg_run(pg/'pg_ctl','-D',base/'data','-m','immediate','-w','stop')
        if passed or not args.keep_failed:
            shutil.rmtree(base)


if __name__ == '__main__':
    main()
