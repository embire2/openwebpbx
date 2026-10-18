#!/usr/bin/env python3
"""Real PHPMailer envelope checks against loopback; never addresses a recipient."""
import json
from pathlib import Path
import socketserver
import subprocess
import threading

PHP = r'''
define('PROJECT_ROOT',$argv[1]);
function permission_exists($name){return true;}
require PROJECT_ROOT.'/resources/classes/outgoing_mail.php';
$db=new PDO('sqlite::memory:');
$db->exec('create table v_default_settings(default_setting_category text,default_setting_subcategory text,default_setting_value text,default_setting_enabled boolean,default_setting_order integer)');
$s=$db->prepare("insert into v_default_settings values('email',?,?,true,0)");
foreach(['smtp_global'=>'true','smtp_host'=>'127.0.0.1','smtp_port'=>$argv[2],'smtp_auth'=>'false','smtp_secure'=>'none','smtp_from'=>'system@example.invalid']as$k=>$v)$s->execute([$k,$v]);
try{$ok=(new outgoing_mail($db))->checkConnection();echo json_encode(['ok'=>$ok]);}
catch(RuntimeException $e){echo json_encode(['ok'=>false,'message'=>$e->getMessage()]);}
'''


class Sink(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(8)
        self.wfile.write(b'220 fixture.example ESMTP\r\n')
        while line := self.rfile.readline():
            command = line.decode().strip()
            self.server.commands.append(command)
            verb = command.split()[0].upper()
            response = '250 OK'
            if verb in ('EHLO', 'HELO'):
                response = '250 fixture.example'
            elif verb == 'MAIL' and self.server.reject:
                response = '550 Sender not allowed'
            elif verb == 'QUIT':
                response = '221 Goodbye'
            elif verb not in ('MAIL', 'RSET'):
                raise AssertionError('Unexpected SMTP operation')
            self.wfile.write((response+'\r\n').encode())
            if verb == 'QUIT':
                break


root = Path(__file__).resolve().parents[1]
for reject in (False, True):
    with socketserver.ThreadingTCPServer(('127.0.0.1', 0), Sink) as fixture:
        fixture.commands = []
        fixture.reject = reject
        thread = threading.Thread(target=fixture.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run(['php', '-r', PHP, str(root), str(fixture.server_address[1])],
                                    check=True, capture_output=True, text=True, timeout=15)
            assert not result.stderr, 'Unexpected PHP diagnostic'
            facts = json.loads(result.stdout)
            assert facts['ok'] is (not reject), 'Sender rejection was reported as a good connection'
            assert [c for c in fixture.commands if c.startswith('MAIL ')] == ['MAIL FROM:<system@example.invalid>']
            assert not any(c.startswith(('RCPT', 'DATA', 'AUTH')) for c in fixture.commands)
            if reject:
                assert '550' in facts['message'] and 'No email was sent' in facts['message']
        finally:
            fixture.shutdown()
            thread.join(timeout=2)
print('PASS: real SMTP accepted/rejected sender checks; no recipient, DATA or AUTH')
