"""Actual TLS/HTTP producer and isolated PostgreSQL observer controls; no PBX."""
import datetime
import http.server
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest

ROOT=Path(__file__).resolve().parents[1]


class PathDiagnostics(unittest.TestCase):
    def setUp(self):
        if not shutil.which('node'):
            self.skipTest('Node is unavailable')
        try:
            from cryptography import x509
            from cryptography.hazmat.primitives import hashes,serialization
            from cryptography.hazmat.primitives.asymmetric import rsa
            from cryptography.x509.oid import NameOID
        except ImportError:
            self.skipTest('The local fixture certificate library is unavailable')
        self.tmp=tempfile.TemporaryDirectory(prefix='openweb-meet-path-')
        self.directory=Path(self.tmp.name)
        now=datetime.datetime.now(datetime.timezone.utc)
        key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Owned path diagnostic fixture')])
        root=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1)).not_valid_after(now+datetime.timedelta(hours=1)).add_extension(x509.BasicConstraints(ca=True,path_length=0),critical=True).sign(key,hashes.SHA256())
        leafkey=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        leaf=x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'127.0.0.1')])).issuer_name(name).public_key(leafkey.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1)).not_valid_after(now+datetime.timedelta(hours=1)).add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]),critical=False).sign(key,hashes.SHA256())
        (self.directory/'root.pem').write_bytes(root.public_bytes(serialization.Encoding.PEM))
        (self.directory/'leaf.pem').write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
        (self.directory/'leaf.key').write_bytes(leafkey.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
        self.mode='valid';self.release=threading.Event();self.requests=0;test=self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):
                pass
            def do_POST(self):
                test.requests+=1
                assert self.path=='/app/pbx_meet/api.php'
                assert self.headers['Authorization']=='Bearer '+'a'*64
                assert json.loads(self.rfile.read(int(self.headers['Content-Length'])))=={'action':'status'}
                if test.mode=='stall':
                    test.release.wait(6)
                    return
                data=b'{bad json' if test.mode=='invalid' else json.dumps({'state':'admitted','ignored_private_value':'NEVER_EXPORTED'}).encode()
                self.send_response(500 if test.mode=='error' else 200)
                self.send_header('Content-Length',str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.directory/'leaf.pem',self.directory/'leaf.key')
        self.server.socket=context.wrap_socket(self.server.socket,server_side=True)
        self.thread=threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.origin='https://127.0.0.1:'+str(self.server.server_port)

    def tearDown(self):
        if hasattr(self,'server'):
            self.release.set();self.server.shutdown();self.server.server_close();self.thread.join(3)
            self.assertFalse(self.thread.is_alive())
            self.tmp.cleanup()

    def probe(self,ca=True):
        script="const fs=require('fs'),d=require(process.argv[1]);d.statusProbe(process.argv[2],process.argv[3]==='yes'?fs.readFileSync(process.argv[4]):undefined,'a'.repeat(64)).then(value=>process.stdout.write(JSON.stringify(value)));"
        result=subprocess.run(['node','-e',script,str(ROOT/'tests/windows-meet-path-diagnostics.cjs'),self.origin,'yes' if ca else 'no',str(self.directory/'root.pem')],capture_output=True,text=True,timeout=7,check=True)
        self.assertNotIn('NEVER_EXPORTED',result.stdout)
        self.assertNotIn('a'*64,result.stdout)
        self.assertNotIn(self.origin,result.stdout)
        return json.loads(result.stdout)

    def test_real_trusted_status_and_closed_errors(self):
        row=self.probe();self.assertTrue(row['observed'] and row['completed'] and row['ok']);self.assertEqual((row['http_status'],row['member_state'],row['error_kind']),(200,'admitted','none'))
        self.mode='error';row=self.probe();self.assertFalse(row['ok']);self.assertEqual((row['http_status'],row['error_kind']),(500,'http'))
        self.mode='invalid';row=self.probe();self.assertFalse(row['ok']);self.assertEqual(row['error_kind'],'invalid_json')
        count=self.requests;row=self.probe(ca=False);self.assertEqual(row['error_kind'],'tls');self.assertFalse(row['completed']);self.assertEqual(self.requests,count)

    def test_actual_stalled_http_deadline(self):
        self.mode='stall';row=self.probe();self.assertEqual(row['error_kind'],'timeout');self.assertFalse(row['completed']);self.assertGreaterEqual(row['elapsed_ms'],3900);self.assertLessEqual(row['elapsed_ms'],5000)

    def test_actual_closed_shapes_python_handoff_and_secret_scope(self):
        script=r"""const assert=require('assert/strict'),EventEmitter=require('events'),d=require(process.argv[1]);
const row=d.defaults();assert.deepEqual(d.validate(row),row);for(const name of Object.keys(row)){for(const field of Object.keys(row[name])){const bad=structuredClone(row);bad[name][field]=null;assert.equal(d.validate(bad),null);}const bad=structuredClone(row);bad[name].raw_header='secret';assert.equal(d.validate(bad),null);}
const page=new EventEmitter(),secret=d.capture(page,'https://fixture.invalid');page.emit('request',{url:()=> 'https://foreign.invalid/app/pbx_meet/api.php',method:()=> 'POST',headers:()=>({authorization:'Bearer '+'a'.repeat(64)})});assert.equal(secret(),undefined);page.emit('request',{url:()=> 'https://fixture.invalid/app/pbx_meet/api.php',method:()=> 'POST',headers:()=>({authorization:'Bearer '+'b'.repeat(64)})});assert.equal(secret(),'b'.repeat(64));process.stdout.write(JSON.stringify({before:row,after:row}));"""
        result=subprocess.run(['node','-e',script,str(ROOT/'tests/windows-meet-path-diagnostics.cjs')],check=True,capture_output=True,text=True,timeout=5)
        spec=importlib.util.spec_from_file_location('windows_meet_path_browser',ROOT/'tests/windows-meet-browser.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        row=json.loads(result.stdout);self.assertEqual(module.path_fields(row),{'meeting_path':row})
        for stage in row:
            for kind in row[stage]:
                for field in row[stage][kind]:
                    bad=json.loads(result.stdout);bad[stage][kind][field]=None;self.assertEqual(module.path_fields(bad),{})
        self.assertNotIn('b'*64,result.stdout)


class PostgreSQLObserver(unittest.TestCase):
    def test_actual_read_only_activity_and_lock_projection(self):
        dsn=os.environ.get('OPENWEB_MEET_PATH_TEST_DSN')
        if not dsn:
            self.skipTest('Explicit isolated PostgreSQL fixture DSN is required')
        self.assertTrue(dsn.startswith('pgsql:host=/'))
        php=r'''$source=file_get_contents($argv[1]);if(!preg_match('/function windows_native_meeting_pg_state\(PDO \$db\): array \{.*?\n\}\n/s',$source,$matches))exit(2);eval($matches[0]);$db=new PDO(getenv('OPENWEB_MEET_PATH_TEST_DSN'),'postgres','',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);$db->exec('create table v_pbx_meeting_members(id integer primary key,value text)');$db->exec("insert into v_pbx_meeting_members values(1,'private-observer-value')");$before=windows_native_meeting_pg_state($db);if(!$before['observed']||!$before['read_only'])exit(3);$db->beginTransaction();$refusal=windows_native_meeting_pg_state($db);if($refusal['observed']||!$db->inTransaction())exit(4);$db->rollBack();echo json_encode($before),PHP_EOL;'''
        result=subprocess.run(['php','-r',php,str(ROOT/'tests/windows-native-fixture.php')],capture_output=True,text=True,check=True,timeout=8)
        row=json.loads(result.stdout);self.assertTrue(row['observed'] and row['read_only'] and row['query_visible']);self.assertEqual(row['error_kind'],'none');self.assertFalse(row['counts_capped']);self.assertNotIn('private-observer-value',result.stdout)
        observer=r'''$source=file_get_contents($argv[1]);preg_match('/function windows_native_meeting_pg_state\(PDO \$db\): array \{.*?\n\}\n/s',$source,$matches);eval($matches[0]);$db=new PDO(getenv('OPENWEB_MEET_PATH_TEST_DSN'),'postgres','',[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);echo json_encode(windows_native_meeting_pg_state($db));'''
        lock=r'''$db=new PDO(getenv('OPENWEB_MEET_PATH_TEST_DSN'),'postgres','');$db->exec('begin');$db->exec("update v_pbx_meeting_members set value='private-lock-value' where id=1");echo "ready\n";fflush(STDOUT);fgets(STDIN);$db->rollBack();'''
        wait=r'''$db=new PDO(getenv('OPENWEB_MEET_PATH_TEST_DSN'),'postgres','');$db->exec("set statement_timeout='8000ms'");echo "ready\n";fflush(STDOUT);$db->exec("update v_pbx_meeting_members set value='private-wait-value' where id=1");'''
        locker=subprocess.Popen(['php','-r',lock],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        waiter=None
        try:
            self.assertEqual(locker.stdout.readline().strip(),'ready')
            waiter=subprocess.Popen(['php','-r',wait],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            self.assertEqual(waiter.stdout.readline().strip(),'ready')
            for _ in range(10):
                result=subprocess.run(['php','-r',observer,str(ROOT/'tests/windows-native-fixture.php')],capture_output=True,text=True,check=True,timeout=5)
                row=json.loads(result.stdout)
                if row['meeting_wait_lock']:
                    break
            self.assertTrue(row['observed'] and row['read_only']);self.assertGreaterEqual(row['idle_in_transaction'],1);self.assertGreaterEqual(row['wait_lock'],1);self.assertGreaterEqual(row['meeting_update'],1);self.assertGreaterEqual(row['meeting_wait_lock'],1)
            self.assertFalse(any(text in result.stdout for text in ('private-lock-value','private-wait-value','update v_pbx','pid','query_text')))
        finally:
            locker.communicate('\n',timeout=4)
            if waiter is not None:
                waiter.communicate(timeout=4)


if __name__=='__main__':
    unittest.main()
