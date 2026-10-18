#!/usr/bin/env python3
"""Exercise real IPv4 SMTP STARTTLS and hostname verification on loopback."""
import json
import pathlib
import socketserver
import ssl
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
PHP = r'''
define('PROJECT_ROOT',$argv[1]);
function permission_exists($name){return true;}
require PROJECT_ROOT.'/resources/classes/outgoing_mail.php';
require PROJECT_ROOT.'/resources/phpmailer/class.phpmailer.php';
$mail=new PHPMailer();$mail->Host='original.invalid';
outgoing_mail::applyRouting($mail,['ipv4_only'=>false,'host'=>'missing.invalid']);
assert($mail->Host==='original.invalid');
outgoing_mail::applyRouting($mail,['ipv4_only'=>true,'host'=>'127.0.0.1']);assert($mail->Host==='127.0.0.1');
$denied=false;try{outgoing_mail::applyRouting($mail,['ipv4_only'=>true,'host'=>'[::1]']);}catch(outgoing_mail_configuration_required){$denied=true;}assert($denied);
$denied=false;try{outgoing_mail::applyRouting($mail,['ipv4_only'=>true,'host'=>'no-such-host.openwebpbx-fixture.invalid']);}catch(outgoing_mail_configuration_required){$denied=true;}assert($denied);
outgoing_mail::applyRouting($mail,['ipv4_only'=>true,'host'=>'localhost']);
foreach(explode(';',$mail->Host)as$ip)assert(filter_var($ip,FILTER_VALIDATE_IP,FILTER_FLAG_IPV4));
assert($mail->SMTPOptions['ssl']['peer_name']==='localhost'&&$mail->SMTPOptions['ssl']['verify_peer_name']===true);
$db=new PDO('sqlite::memory:');$db->exec('create table v_default_settings(default_setting_category text,default_setting_subcategory text,default_setting_value text,default_setting_enabled boolean,default_setting_order integer)');
$s=$db->prepare("insert into v_default_settings values('email',?,?,true,0)");
foreach(['smtp_global'=>'true','smtp_host'=>'localhost','smtp_port'=>$argv[2],'smtp_auth'=>'false','smtp_secure'=>'tls','smtp_from'=>'system@example.invalid','smtp_ipv4_only'=>'true']as$k=>$v)$s->execute([$k,$v]);
try{$ok=(new outgoing_mail($db))->checkConnection();}catch(Throwable){$ok=false;}
echo json_encode(['sender_accepted'=>$ok,'routing_controls'=>6]);
'''


class Sink(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        self.wfile.write(b'220 localhost ESMTP\r\n')
        encrypted = False
        while line := self.rfile.readline():
            verb = line.split()[0].upper()
            self.server.commands.append(verb)
            if verb == b'EHLO':
                self.wfile.write(b'250-localhost\r\n250 STARTTLS\r\n' if not encrypted else b'250 localhost\r\n')
            elif verb == b'STARTTLS':
                self.wfile.write(b'220 Ready\r\n')
                self.wfile.flush()
                try:
                    conn = self.server.context.wrap_socket(self.request, server_side=True)
                except ssl.SSLError:
                    return
                self.connection = self.request = conn
                self.rfile = conn.makefile('rb')
                self.wfile = conn.makefile('wb', buffering=0)
                encrypted = True
            elif verb in (b'MAIL', b'RSET'):
                assert encrypted
                self.wfile.write(b'250 OK\r\n')
            elif verb == b'QUIT':
                self.wfile.write(b'221 Bye\r\n')
                return
            else:
                raise AssertionError('Unexpected recipient, message or authentication operation')


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


with tempfile.TemporaryDirectory(prefix='openweb-smtp-ipv4-') as temp:
    folder = pathlib.Path(temp)
    run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=Owned SMTP test CA', '-keyout', str(folder/'ca.key'), '-out', str(folder/'ca.pem'))
    for hostname in ('localhost', 'wrong.example.invalid'):
        run('openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN='+hostname, '-keyout', str(folder/'server.key'), '-out', str(folder/'server.csr'))
        (folder/'ext').write_text('subjectAltName=DNS:'+hostname+'\nextendedKeyUsage=serverAuth\n')
        run('openssl', 'x509', '-req', '-in', str(folder/'server.csr'), '-CA', str(folder/'ca.pem'), '-CAkey', str(folder/'ca.key'), '-CAcreateserial', '-days', '1', '-extfile', str(folder/'ext'), '-out', str(folder/'server.pem'))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(folder/'server.pem', folder/'server.key')
        with socketserver.ThreadingTCPServer(('127.0.0.1', 0), Sink) as fixture:
            fixture.commands = []
            fixture.context = context
            worker = threading.Thread(target=fixture.serve_forever, daemon=True)
            worker.start()
            try:
                result = subprocess.run(['php', '-d', 'zend.assertions=1', '-d', 'assert.exception=1', '-d', 'openssl.cafile='+str(folder/'ca.pem'), '-r', PHP, str(ROOT), str(fixture.server_address[1])], capture_output=True, text=True, timeout=25, check=True)
                assert not result.stderr, 'Unexpected PHP diagnostic'
                facts = json.loads(result.stdout)
                assert facts['sender_accepted'] is (hostname == 'localhost')
                assert (b'MAIL' in fixture.commands) is (hostname == 'localhost')
                assert not any(c in fixture.commands for c in (b'RCPT', b'DATA', b'AUTH'))
            finally:
                fixture.shutdown()
                worker.join(timeout=2)
print('PASS: 6 IPv4 routing controls; real STARTTLS sender success and trusted-CA hostname mismatch refusal; no AUTH/recipient/DATA')
