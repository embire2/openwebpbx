#!/usr/bin/env python3
"""Exact dedicated dispatcher with disposable PG; fixture TLS/peer only, no DNS/SMTP."""
from pathlib import Path
import base64
import hashlib
import http.client
import json
import os
import pwd
import shutil
import socket
import subprocess
import tempfile
import time
import uuid
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    os.umask(0o077)
    root = Path(__file__).resolve().parents[1]
    base = Path(tempfile.mkdtemp(prefix='openweb-wizard-http-'))
    postgres = pwd.getpwnam('postgres')
    os.chown(base, postgres.pw_uid, postgres.pw_gid)
    pg = sorted(Path('/usr/lib/postgresql').glob('*/bin/initdb'), key=lambda p: int(p.parts[-3]))[-1].parent
    pg_port, web_port = port(), port()
    while pg_port == web_port:
        web_port = port()
    state = base/'state'
    state.mkdir(mode=0o700)
    (state/'template.key').write_bytes(os.urandom(32))
    env = os.environ | {'OPENWEB_TENANT_HTTP_DSN':f'pgsql:host=127.0.0.1;port={pg_port};dbname=postgres',
                        'OPENWEB_PROVIDER_HTTP_FIXTURE':'1',
                        'OPENWEB_TENANT_HTTP_STATE':str(state)}
    cases = []
    web = None
    started = False
    def run_pg(*args):
        return subprocess.run(['runuser','-u','postgres','--',*map(str,args)], check=True, capture_output=True, timeout=45)
    def sql(value):
        return run_pg(pg/'psql','-X','-A','-t','-h','127.0.0.1','-p',pg_port,'-d','postgres','-v','ON_ERROR_STOP=1','-c',value).stdout.decode().strip()
    def check(value, text):
        if not value:
            raise AssertionError(text)
        cases.append(text)
    def request(method, path, body=None, *, token=None, headers=None, raw=None):
        h={'Host':'server.example.test'} | (headers or {})
        if token:
            h['Authorization']='Bearer '+token
        if body is not None:
            h.setdefault('Content-Type','application/json')
            raw=json.dumps(body).encode()
        c=http.client.HTTPConnection('127.0.0.1',web_port,timeout=20)
        try:
            c.request(method,'/api/v1/wizard'+path,body=raw,headers=h)
            r=c.getresponse();value=r.read(65537)
            if len(value)>65536:
                raise AssertionError('Unbounded setup response')
            return r.status,json.loads(value) if value else None,dict(r.getheaders())
        finally:
            c.close()
    try:
        run_pg(pg/'initdb','-D',base/'data','--auth=trust','--no-locale','--encoding=UTF8')
        run_pg(pg/'pg_ctl','-D',base/'data','-l',base/'pg.log','-o',f'-h 127.0.0.1 -p {pg_port} -k {base} -c fsync=off','-w','start')
        started=True
        setup=base/'setup.php'
        setup.write_text('<?php require '+json.dumps(str(root/'tests/tenant_api_http_fixture.php'))+';'
                         '$db->exec(file_get_contents('+json.dumps(str(root/'app/tenant_api/resources/onboarding.sql'))+'));'
                         '$db->exec(file_get_contents('+json.dumps(str(root/'app/tenant_api/resources/wizard.sql'))+'));'
                         '$db->exec(file_get_contents('+json.dumps(str(root/'app/tenant_api/resources/wizard-reservations.sql'))+'));')
        subprocess.run(['php',str(setup),'setup'],check=True,capture_output=True,env=env,timeout=45)
        tree=state/'http'
        (tree/'api/wizard').mkdir(parents=True)
        (tree/'resources/classes').mkdir(parents=True)
        source=root/'api/wizard/index.php'
        digest=hashlib.sha256(source.read_bytes()).hexdigest()
        shutil.copyfile(source,tree/'api/wizard/index.php')
        bootstrap='<?php require_once '+json.dumps(str(root/'tests/tenant_api_http_fixture.php'))+';'
        for name in ['pbx_installation_authority','pbx_wizard_reservations','pbx_wizard_api']:
            bootstrap+='require_once '+json.dumps(str(root/'resources/classes'/f'{name}.php'))+';'
        (tree/'resources/require.php').write_text(bootstrap)
        (tree/'resources/classes/config.php').write_text(bootstrap)
        (tree/'router.php').write_text("<?php $_SERVER['HTTPS']=isset($_SERVER['HTTP_X_FIXTURE_PLAINTEXT'])?'':'on'; $_SERVER['REMOTE_ADDR']='8.8.8.8';require __DIR__.'/api/wizard/index.php';")
        log=(state/'http.log').open('wb')
        web=subprocess.Popen(['php','-S',f'127.0.0.1:{web_port}','-t',str(tree),str(tree/'router.php')],stdout=log,stderr=log,env=env)
        for _ in range(100):
            with socket.socket() as sock:
                if sock.connect_ex(('127.0.0.1',web_port))==0:
                    break
            if web.poll() is not None:
                raise AssertionError('Owned HTTP fixture stopped')
            time.sleep(.02)
        else:
            raise AssertionError('Owned HTTP fixture did not listen')
        for route in ['/reservations','/reservations/renew','/reservations/release']:
            check(request('POST',route,{})[0]==401,'Reservation mutation requires an authenticated owner: '+route)
        check(request('POST','/subdomains/availability',{})[0]==400,'Global address check requires an exact label')
        check(request('POST','/subdomains/availability',{'label':'node-imposter'})[0]==400,'Canonical node namespace is not a selectable tenant label')
        check(request('POST','/servers/revoke',{'reservation_uuid':str(uuid.uuid4()),'control_token':'invalid','expected_server_address':'8.8.8.8'})[0]==401,'Cleanup control must have its exact format')
        check(request('POST','/servers/revoke',{'reservation_uuid':str(uuid.uuid4()),'control_token':'owpc_'+'a'*64,'expected_server_address':'8.8.8.8'})[0]==401,'An invented cleanup credential cannot revoke a server')
        check(request('GET','/servers/revoke')[0]==405,'Server cleanup is never a GET action')
        check(request('POST','/servers/revoke',{'reservation_uuid':str(uuid.uuid4()),'control_token':'owpc_'+'a'*64,'expected_server_address':'8.8.8.8'},headers={'Origin':'https://webhotel.cloud'})[0]==403,'Webhotel browser cannot send provider controls directly to custodian')
        origin={'Origin':'https://openwebpbx.com'}
        status,body,headers=request('GET','/health',headers=origin)
        check(status==200 and body['version']==1,'Dedicated wizard is available over fixture HTTPS')
        check(headers.get('Access-Control-Allow-Origin')=='https://openwebpbx.com','Only the official wizard origin is allowed')
        check(headers.get('Cache-Control')=='no-store','Wizard responses are not stored in shared caches')
        check('Access-Control-Allow-Credentials'not in headers,'Browser cookies do not authorize the wizard')
        check(request('GET','/health',headers={'Origin':'https://evil.example'})[0]==403,'Foreign web origins are refused')
        check(request('GET','/health',headers={'Origin':'null'})[0]==403,'Opaque web origins are refused')
        check(request('GET','/health',headers={'X-Fixture-Plaintext':'1','X-Forwarded-Proto':'https'})[0]==403,'Forwarded HTTPS cannot bypass the transport guard')
        check(request('GET','/health',headers={'Host':'foreign.example'})[0]==403,'Untrusted API host is refused')
        status,_,h=request('OPTIONS','/claim',headers=origin|{'Access-Control-Request-Method':'POST','Access-Control-Request-Headers':'authorization,content-type'})
        check(status==204 and h.get('Access-Control-Allow-Origin')=='https://openwebpbx.com','Official browser preflight works')
        check(request('OPTIONS','/missing',headers=origin|{'Access-Control-Request-Method':'POST'})[0]==404,'Unknown preflight endpoints are refused')
        check(request('OPTIONS','/claim',headers=origin|{'Access-Control-Request-Method':'DELETE'})[0]==405,'Unsupported preflight methods are refused')
        check(request('POST','/devices',raw=b'{}')[0]==415,'JSON media type is required')
        check(request('POST','/devices',raw=b'[]',headers={'Content-Type':'application/json'})[0]==400,'JSON arrays are refused')
        check(request('POST','/devices',raw=b'{',headers={'Content-Type':'application/json'})[0]==400,'Malformed JSON is refused')
        check(request('POST','/devices',raw=b'x'*16385,headers={'Content-Type':'application/json'})[0]==413,'Oversized setup bodies are refused')
        key=ec.generate_private_key(ec.SECP256R1())
        public=base64.b64encode(key.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)).decode()
        image={'provider':'webhotel','image_version':'1.0.21','public_key':public,'local_tenant_uuid':str(uuid.uuid4()),'domain_uuid':str(uuid.uuid4())}
        status,device,_=request('POST','/devices',image)
        check(status==201 and device['verification_uri_complete'].startswith('https://openwebpbx.com/wizard#code='),'Image receives a dedicated setup link')
        check(device['device_code']not in device['verification_uri_complete'],'Private image credential is absent from the browser link')
        import re
        check(re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00',device['expires_at'])is not None,'Actual setup dispatcher emits strict UTC RFC3339 expiry')
        check(sql('select count(*) from v_pbx_tenants')=='0','Starting an image does not create a central hosted tenant')
        status,lookup,_=request('POST','/devices/lookup',{'user_code':device['user_code']},headers=origin)
        check(status==200 and lookup['server_address']=='8.8.8.8','Browser can find the server by its setup code')
        check(lookup['expires_at']==device['expires_at'],'Browser lookup preserves the normalized UTC expiry')
        check('device_code'not in lookup and 'public_key'not in lookup,'Browser lookup does not disclose root credentials')
        register={'tenant_name':'Wizard Company','slug':'wizard-company','email':'owner@wizard.test.invalid','password':'Fictional-wizard-password-2026!','accept_terms':True}
        status,body,_=request('POST','/account/register',register,headers=origin)
        check(status==202 and body['status']=='verification_required','Official web wizard can request email registration')
        check(sql('select count(*) from v_pbx_tenants')=='0','Registration does not activate a tenant before email verification')
        mail=sql("select email_body from v_email_queue where email_to='owner@wizard.test.invalid'")
        import re
        code=re.search(r'<code>([a-f0-9]{64})</code>',mail).group(1)
        check(code not in json.dumps(body),'Registration response does not expose the email code')
        status,body,_=request('POST','/account/verify',{'token':code,'password':register['password']},headers=origin)
        check(status==201 and body['tenant']['slug']=='wizard-company','Email code and original password verify the owner')
        token=body['access_token']
        claim={'user_code':device['user_code'],'label':'wizard-company','confirm_server':True,'accept_terms':True}
        check(request('POST','/claim',claim,headers=origin|{'Cookie':'PHPSESSID=fictional'})[0]==401,'Browser cookies cannot claim a server')
        status,claimed,_=request('POST','/claim',claim,token=token,headers=origin)
        check(status==202 and claimed['state']=='claimed' and not claimed['ready'],'Verified owner can claim its image without premature activation')
        stored=sql('select row_to_json(d) from v_pbx_wizard_devices d')
        check(token not in stored and register['password']not in stored,'Image enrollment stores neither owner password nor bearer')
        status,poll,_=request('POST','/devices/poll',{'device_code':device['device_code']})
        check(status==200 and poll['label']=='wizard-company' and len(poll['nonce'])==64,'Only the private image receives its bound bootstrap challenge')
        check(request('POST','/devices/poll',{'device_code':'owpd_'+'0'*64})[0]==401,'An invented device secret is refused')
        check(request('POST','/devices/bootstrap',{'device_code':device['device_code'],'signature':base64.b64encode(b'wrong').decode()})[0]==403,'Wrong bootstrap signature is refused before network transport')
        check(request('POST','/devices/challenge',{'device_code':device['device_code']})[0]==409,'Authority is not issued before canonical DNS readiness')
        check(request('POST','/devices/complete',{'device_code':device['device_code'],'hostname':'wizard-company.openwebpbx.com','signature':'invalid'})[0]==409,'An image cannot mark itself ready before authorization')
        status,body,_=request('GET','/sessions/'+device['pairing_uuid'],token=token,headers=origin)
        check(status==200 and body['tenant_url']is None,'Browser sees progress without an unverified connection URL')
        check(sql('select count(*) from v_pbx_services')=='0','Image pairing never creates another PBX on the main server')
        check(hashlib.sha256(source.read_bytes()).hexdigest()==digest and (tree/'api/wizard/index.php').read_bytes()==source.read_bytes(),'The exact product dispatcher was tested without rewriting it')
        print(json.dumps({'passed':len(cases),'cases':cases,'scope':'isolated exact HTTP dispatcher/PostgreSQL; fixture HTTPS/peer, no DNS/SMTP network'}))
    finally:
        if web is not None:
            web.terminate()
            try:web.wait(timeout=5)
            except subprocess.TimeoutExpired:web.kill();web.wait(timeout=5)
        if started:
            run_pg(pg/'pg_ctl','-D',base/'data','-m','immediate','-w','stop')
        shutil.rmtree(base)


if __name__=='__main__':
    main()
