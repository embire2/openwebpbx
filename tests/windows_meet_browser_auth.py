"""Actual opener/session-UA guard and closed meeting owner-page QA controls."""
import copy
import hashlib
import http.cookiejar
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tests/windows-meet-browser.py'
spec = importlib.util.spec_from_file_location('meeting_browser_auth_fixture', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
PRIVATE = 'PRIVATE_cookie_user_agent_password'


class BrowserAuthenticationControls(unittest.TestCase):
    def test_actual_opener_header_is_handed_to_only_the_owner_context(self):
        opener = urllib.request.build_opener()
        self.assertEqual(module.session_user_agent(opener), dict(opener.addheaders)['User-agent'])
        for value in ['', 'x\r\nCookie: '+PRIVATE, 'x'*513, '\x00'+PRIVATE, '\x7f'+PRIVATE, None]:
            opener.addheaders = [('User-agent', value)]
            with self.assertRaises(RuntimeError): module.session_user_agent(opener)
        for values in [[], [('User-agent', 'one'), ('user-Agent', 'two')]]:
            opener.addheaders = values
            with self.assertRaises(RuntimeError): module.session_user_agent(opener)
        python = SOURCE.read_text()
        browser = (ROOT/'tests/windows-meet-browser.cjs').read_text()
        self.assertIn('userAgent=session_user_agent(fixture.web.open)', python)
        self.assertIn('hostBrowser.newContext({ignoreHTTPSErrors:false,userAgent:settings.userAgent})', browser)
        self.assertIn('guestBrowser.newContext({ignoreHTTPSErrors:false})', browser)
        self.assertIn('await hostContext.addCookies(settings.cookies)', browser)
        self.assertNotIn('ignoreHTTPSErrors:true', browser)

    def test_closed_owner_page_projection_refuses_private_or_wrong_fields(self):
        valid = dict(http_status=200, route='meet', login_form=False, heading=True,
                     same_origin=True, user_agent_matches=True)
        result = module.owner_page_fields(valid)
        self.assertEqual(len(result), 6)
        self.assertEqual(result['meeting_owner_http_status'], 200)
        self.assertNotIn(PRIVATE, json.dumps(result))
        for route in ['meet', 'login', 'logout', 'desktop', 'other']:
            self.assertEqual(module.owner_page_fields(valid | {'route': route})['meeting_owner_route'], route)
        for key in valid:
            row = copy.deepcopy(valid); del row[key]
            self.assertEqual(module.owner_page_fields(row), {})
        for key, values in {'http_status': [-1,600,True,'200',1.5],
                            'route': [PRIVATE,'https://private.invalid/?token='+PRIVATE,True,None,[],{}],
                            **{key:[None,1,'false'] for key in ['login_form','heading','same_origin','user_agent_matches']}}.items():
            for value in values:
                self.assertEqual(module.owner_page_fields(valid | {key:value}), {})
        self.assertEqual(module.owner_page_fields(valid | {'cookie':PRIVATE}), {})
        self.assertEqual(module.owner_page_fields(None), {})

    @unittest.skipUnless(shutil.which('php'), 'A local PHP CLI is required for the actual unchanged session guard')
    def test_original_session_guard_rejects_old_UA_handoff_and_accepts_matching(self):
        source = (ROOT/'resources/check_auth.php').read_text()
        fragment = source.split('//session validate: use HTTP_USER_AGENT as a default value',1)[1].split('//if the session is not authorized',1)[0]
        self.assertIn('session_destroy();', fragment)
        self.assertIn('$_SESSION["user_hash"] !== hash', fragment)
        with tempfile.TemporaryDirectory(prefix='openweb-meet-auth-') as directory:
            work=Path(directory); sessions=work/'sessions';sessions.mkdir()
            router=work/'router.php'
            router.write_text("<?php\ndefine('PROJECT_PATH','');session_start();$path=parse_url($_SERVER['REQUEST_URI'],PHP_URL_PATH);\n"
                "if($path==='/login'){$_SESSION['authorized']=true;$_SESSION['user_hash']=hash('sha256',$_SERVER['HTTP_USER_AGENT']);echo 'signed in';exit;}\n"
                "if($path==='/logout.php'){echo '<input name=\"password\">';exit;}\n"
                +fragment+"\necho '<h1>Meet</h1>';\n")
            with socket.socket() as reserved: reserved.bind(('127.0.0.1',0));port=reserved.getsockname()[1]
            origin=f'http://127.0.0.1:{port}'
            with (work/'server.private.log').open('wb') as log:
                process=subprocess.Popen([shutil.which('php'),'-n','-d','session.save_path='+str(sessions),'-S',f'127.0.0.1:{port}',str(router)],stdout=log,stderr=log)
                try:
                    jar=http.cookiejar.CookieJar();original=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
                    for attempt in range(60):
                        try:
                            with original.open(origin+'/login',timeout=1) as response: self.assertEqual(response.status,200)
                            break
                        except OSError:
                            if process.poll() is not None: self.fail('The owned PHP guard fixture did not start')
                            time.sleep(.05)
                    else: self.fail('The owned PHP guard fixture did not become ready')
                    agent=module.session_user_agent(original)
                    browser=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar));browser.addheaders=[('User-agent','Different-Edge-'+PRIVATE)]
                    with browser.open(origin+'/meet',timeout=2) as response:
                        self.assertEqual(response.geturl(),origin+'/logout.php');self.assertIn(b'name="password"',response.read())
                    # The unchanged real product guard destroyed the original
                    # session. Sign in normally again before the fixed handoff.
                    with original.open(origin+'/login',timeout=2) as response: self.assertEqual(response.status,200)
                    browser.addheaders=[('User-agent',agent)]
                    with browser.open(origin+'/meet',timeout=2) as response:
                        self.assertEqual(response.geturl(),origin+'/meet');self.assertEqual(response.read(),b'<h1>Meet</h1>')
                finally:
                    process.terminate()
                    try:process.wait(timeout=5)
                    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
        self.assertEqual((ROOT/'resources/check_auth.php').read_text(),source)

    @unittest.skipUnless(shutil.which('node'), 'Node required for actual browser-side closed discriminator')
    def test_actual_browser_discriminator_never_exports_URL_or_UA(self):
        source=(ROOT/'tests/windows-meet-browser.cjs').read_text()
        helper=source.split('async function ownerPageFields(',1)[1].split('async function snapshot(',1)[0]
        code="const settings={origin:'https://windowsqa.example.invalid:8443',userAgent:'PRIVATE_UA'};\nasync function ownerPageFields("+helper+r'''
(async()=>{
 const rows=[];
 for(const [route,password,heading,status] of [['/app/pbx_meet/',false,true,200],['/login.php',true,false,200],['/logout.php',true,false,302],['/core/desktop/',false,false,200],['/private-route',false,false,500]]){
  const page={url:()=>settings.origin+route+'?private=PRIVATE_TOKEN',locator:()=>({count:async()=>password?1:0}),getByRole:()=>({isVisible:async()=>heading}),evaluate:async(fn,arg)=>arg===settings.userAgent};
  const row=await ownerPageFields(page,{status:()=>status});if(Object.keys(row).length!==6)throw Error('shape');rows.push(row);
 }
 console.log(JSON.stringify(rows));
})().catch(()=>process.exit(1));
'''
        child=subprocess.run([shutil.which('node'),'-e',code],capture_output=True,text=True,timeout=10)
        self.assertEqual(child.returncode,0,child.stderr)
        self.assertNotIn('PRIVATE_',child.stdout)
        rows=json.loads(child.stdout)
        self.assertEqual([r['route'] for r in rows],['meet','login','logout','desktop','other'])
        self.assertTrue(rows[0]['heading'] and rows[0]['same_origin'] and rows[0]['user_agent_matches'])
        self.assertTrue(rows[1]['login_form'])


if __name__=='__main__':unittest.main()
