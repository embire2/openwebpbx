#!/usr/bin/env python3
"""Run local registration policy tests against a new disposable PostgreSQL cluster."""
from pathlib import Path
import hashlib
from html.parser import HTMLParser
import http.cookiejar
import json
import os
import pwd
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


class Forms(HTMLParser):
    def __init__(self):
        super().__init__()
        self.forms, self.current = [], None

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == 'form':
            self.current = {}
            self.forms.append(self.current)
        if self.current is not None and tag == 'input' and values.get('name'):
            self.current[values['name']] = values.get('value', '')

    def handle_endtag(self, tag):
        if tag == 'form':
            self.current = None


def http_checks(root, state, env, sql):
    """Exact copied PHP controller; isolated bootstrap, fixture HTTPS, no central requests."""
    web = state/'http'
    for folder in ['resources/classes', 'resources/keys', 'app/pbx_onboarding', 'app/pbx_setup', 'themes/default/images']:
        (web/folder).mkdir(parents=True, exist_ok=True)
    for name in ['resources/classes/pbx_onboarding.php', 'resources/classes/pbx_tenant_domains.php',
                 'resources/classes/pbx_tenant_api_domains.php', 'resources/classes/token.php',
                 'app/pbx_onboarding/index.php', 'app/pbx_onboarding/onboarding.css', 'app/pbx_onboarding/onboarding.js',
                 'app/pbx_setup/setup.css', 'themes/default/images/openweb-logo.svg']:
        shutil.copyfile(root/name, web/name)
    shutil.copyfile(state/'authority-fixture.public.pem', web/'resources/keys/installation-authority.pem')
    (web/'resources/require.php').write_text("<?php define('PROJECT_ROOT',"+json.dumps(str(web))+");require "+json.dumps(str(root/'tests/pbx_onboarding.php'))+";require_once PROJECT_ROOT.'/resources/classes/token.php';")
    (web/'resources/check_auth.php').write_text("<?php if(empty($_SESSION['authorized'])){http_response_code(403);exit('Sign in.');}")
    (web/'resources/header.php').write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="/themes/default/images/openweb-logo.svg"><style>body{margin:0;font-family:Segoe UI,system-ui,sans-serif;background:#f2f6fb;color:#25344b}body{--openweb-text:#25344b;--openweb-surface:#fff;--openweb-line:#dce5f2;--openweb-accent:#0067b8}label{display:block}input,select{font:inherit;max-width:100%;box-sizing:border-box}html[data-theme=dark] body{background:#132138;--openweb-text:#e5effb;--openweb-surface:#1d2e44;--openweb-line:#3c4e68;color:#e5effb}</style></head><body>')
    (web/'resources/footer.php').write_text('</body></html>')
    router = state/'router.php'
    router.write_text("<?php $path=parse_url($_SERVER['REQUEST_URI'],PHP_URL_PATH);if(preg_match('~\\.(css|js|svg)$~',$path)&&is_file(__DIR__.'/http'.$path))return false;$_SERVER['HTTPS']='on';require __DIR__.'/http/resources/require.php';if($path==='/__fixture/login'){$m=json_decode(file_get_contents(__DIR__.'/http-fixture.json'),true);$a=$m[$_GET['actor']??'']??null;$_SESSION=$a?['authorized'=>true,'user_uuid'=>$a['user'],'domain_uuid'=>$a['domain']]:[];echo 'Fixture login';exit;}require __DIR__.'/http/app/pbx_onboarding/index.php';")
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    http_env = env | {'OPENWEB_ONBOARDING_TEST_HTTP': '1'}
    log = (state/'http-server.original.log').open('wb')
    process = subprocess.Popen(['php', '-S', f'127.0.0.1:{port}', '-t', str(web), str(router)],
                               env=http_env, stdout=log, stderr=log)
    base = f'http://127.0.0.1:{port}'
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    fixtures = json.loads((state/'http-fixture.json').read_text())
    checks = []

    def check(value, label):
        assert value, label
        checks.append(label)

    def request(path, fields=None, headers=None):
        data = urllib.parse.urlencode(fields).encode() if fields is not None else None
        try:
            response = client.open(urllib.request.Request(base+path, data=data, headers=headers or {}), timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, response.read().decode(), response.geturl()

    try:
        for _ in range(50):
            try:
                request('/__fixture/login?actor=none')
                break
            except OSError:
                time.sleep(.05)
        path = '/app/pbx_onboarding/?service_uuid='+fixtures['charlie']['service']
        check(request(path)[0] == 403, 'anonymous owner page denied')
        request('/__fixture/login?actor=staff')
        check(request(path)[0] == 403, 'staff owner page denied')
        request('/__fixture/login?actor=bravo')
        check(request(path)[0] == 403, 'foreign tenant page denied')
        request('/__fixture/login?actor=charlie')
        status, body, _ = request(path)
        check(status == 200 and 'Create your OpenWeb account' in body, 'ordinary owner registration form')
        (web/'register.original.html').write_text(body)
        forms = Forms(); forms.feed(body)
        form = next(f for f in forms.forms if f.get('action') == 'register')
        csrf = next(k for k in form if len(k) == 64)
        check('value=' not in body.split('name="password"', 1)[1].split('>', 1)[0], 'password never redisplayed')
        no_csrf = {k: v for k, v in form.items() if k != csrf}
        check(request(path, no_csrf)[0] == 403, 'missing POST CSRF denied')
        check(request(path+'&'+csrf+'='+form[csrf], no_csrf)[0] == 403, 'query-only CSRF denied')
        check(request(path, form | {csrf: '0'*64})[0] == 403, 'wrong CSRF denied')
        check(request(path, form, {'Origin': 'https://unrelated.example.invalid'})[0] == 403, 'foreign browser origin denied')
        result = request(path, form | {'action': 'finish'})
        check(result[0] == 200 and 'Wait until' in result[1], 'finish blocked before grant and transport')
        fresh = Forms(); fresh.feed(request(path)[1])
        form = next(f for f in fresh.forms if f.get('action') == 'register')
        check(request(path, form | {'action': 'workerImport'})[0] == 200, 'worker method not remotely dispatched')
        oversized = form | {'tenant_name': 'x'*9000}
        check(request(path, oversized)[0] == 413, 'oversized form refused')
        status, state, _ = request(path+'&format=json')
        parsed = json.loads(state)
        check(status == 200 and parsed['ready'] is False and 'token_ciphertext' not in state and 'activation' not in parsed, 'safe owner-only polling state')
        check(sql('select count(*) from v_pbx_onboarding where domain_uuid=\''+fixtures['charlie']['domain']+'\'') == '0', 'denied forms did not create or link an account')
        request('/__fixture/login?actor=alpha')
        status, body, _ = request('/app/pbx_onboarding/?service_uuid='+fixtures['alpha']['service'])
        check(status == 200 and 'Open my PBX' in body and 'alpha-company.openwebpbx.com' in body, 'verified ready owner sees finish and actual tenant address')
        (web/'ready.original.html').write_text(body)
        owner = fixtures['charlie']
        sql("insert into v_pbx_onboarding(domain_uuid,tenant_uuid,service_uuid,owner_user_uuid,account_tenant_uuid,account_email,token_expires_at,state) values('"+owner['domain']+"','"+owner['tenant']+"','"+owner['service']+"','"+owner['user']+"','11111111-1111-4111-8111-111111111111','fixture@example.invalid',now()-interval '1 minute','retry')")
        request('/__fixture/login?actor=charlie')
        status, body, _ = request(path)
        check(status == 200 and 'data-needs-signin="true"' in body and 'Sign in to your OpenWeb account' in body, 'expired account uses a stable sign-in form')
        (web/'expired.original.html').write_text(body)
        (web/'expired-status.original.json').write_text(request(path+'&format=json')[1])
        return {'passed': len(checks), 'checks': checks, 'scope': 'Exact PHP controller with isolated test bootstrap and injected loopback HTTPS; no central HTTP requests'}
    finally:
        process.terminate()
        process.wait(timeout=15)
        log.close()


def main():
    os.umask(0o077)
    root = Path(__file__).resolve().parents[1]
    cluster = Path(tempfile.mkdtemp(prefix='openweb-onboarding-pg-'))
    state = Path(tempfile.mkdtemp(prefix='onboarding-test-', dir='/var/lib/openwebpbx'))
    account = pwd.getpwnam('postgres')
    os.chown(cluster, account.pw_uid, account.pw_gid)
    binaries = sorted(Path('/usr/lib/postgresql').glob('*/bin/initdb'), key=lambda p: int(p.parts[-3]))[-1].parent
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    started = False
    passed = False

    def pg(*command):
        return subprocess.run(['runuser', '-u', 'postgres', '--', *map(str, command)], check=True,
                              capture_output=True, timeout=45)
    try:
        pg(binaries/'initdb', '-D', cluster/'data', '-A', 'trust', '--no-locale', '-E', 'UTF8')
        pg(binaries/'pg_ctl', '-D', cluster/'data', '-l', cluster/'postgres.log', '-o',
           f'-h 127.0.0.1 -p {port} -k {cluster}', '-w', 'start')
        started = True
        env = os.environ | {'OPENWEB_ONBOARDING_TEST': '1',
                            'OPENWEB_ONBOARDING_TEST_DSN': f'pgsql:host=127.0.0.1;port={port};dbname=postgres',
                            'OPENWEB_ONBOARDING_TEST_STATE': str(state)}
        source = {name: hashlib.sha256((root/name).read_bytes()).hexdigest() for name in [
            'resources/classes/pbx_onboarding.php', 'app/pbx_onboarding/resources/install.sql',
            'app/pbx_onboarding/index.php', 'app/pbx_onboarding/onboarding.css', 'app/pbx_onboarding/onboarding.js',
            'tests/pbx_onboarding.php', 'tests/pbx_onboarding.py']}
        result = subprocess.run(['php', str(root/'tests/pbx_onboarding.php')], env=env, capture_output=True,
                                text=True, timeout=90)
        (state/'test.original.stdout').write_text(result.stdout)
        (state/'test.original.stderr').write_text(result.stderr)
        if result.returncode:
            print(result.stderr)
            raise RuntimeError('Local onboarding checks failed; retained evidence at '+str(state))
        report = json.loads(result.stdout)
        def sql(query):
            return pg(binaries/'psql', '-X', '-A', '-t', '-h', '127.0.0.1', '-p', port, '-d', 'postgres', '-c', query).stdout.decode().strip()
        report['http'] = http_checks(root, state, env, sql)
        for name, expected in source.items():
            assert hashlib.sha256((root/name).read_bytes()).hexdigest() == expected
        report.update(source_sha256=source, evidence_directory=str(state))
        (state/'acceptance.safe.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        passed = True
    finally:
        if started:
            pg(binaries/'pg_ctl', '-D', cluster/'data', '-m', 'fast', '-w', 'stop')
        if passed:
            shutil.rmtree(cluster)
        else:
            print('Failed attempt evidence retained:', state)


if __name__ == '__main__':
    main()
