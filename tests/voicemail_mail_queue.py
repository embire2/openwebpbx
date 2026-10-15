#!/usr/bin/env python3
"""Actual Lua queue SQL in disposable PostgreSQL; real PHP transport/local SMTP.

No installed configuration, production database, engine or outside relay is used.
Native Windows full-worker qualification remains a separate acceptance gate.
"""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import socketserver
import subprocess
import tempfile
import threading
from email.parser import BytesParser
from email.policy import default

ROOT = Path(__file__).resolve().parents[1]
PG = Path('/usr/lib/postgresql/18/bin')
PHP = r'''<?php
error_reporting(E_ALL);
set_error_handler(static function($severity,$message){
    throw new ErrorException($message,0,$severity);
});
function valid_email($value){return filter_var($value,FILTER_VALIDATE_EMAIL)!==false;}
require $argv[1].'/resources/classes/outgoing_mail.php';
require $argv[1].'/resources/classes/email.php';
$pdo=new PDO('pgsql:host='.$argv[2].';port='.$argv[3].';dbname=postgres','postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$database=(object)['db'=>$pdo];
$row=$pdo->query("SELECT * FROM v_email_queue WHERE email_subject='unconfigured'")->fetch(PDO::FETCH_ASSOC);
if(!$row || $row['email_from']!=='')throw new RuntimeException('Real Lua queue placeholder absent.');
$make=static function()use($database,$row){
    $email=new email(['database'=>$database,'settings'=>new stdClass]);
    $email->method='direct';$email->from_address=$row['email_from'];
    $email->recipients=$row['email_to'];$email->subject='Fictional empty-sender delivery';$email->body='Fictional voicemail body';
    return $email;
};
$email=$make();
if($email->send()!==false || !$email->delivery_deferred)throw new RuntimeException('Unconfigured transport failed to defer.');
if($pdo->query("SELECT * FROM v_email_queue WHERE email_subject='unconfigured'")->fetch(PDO::FETCH_ASSOC)!==$row)throw new RuntimeException('Deferral changed private queued data.');
$values=['smtp_global'=>'true','smtp_host'=>'127.0.0.1','smtp_port'=>$argv[4],'smtp_secure'=>'none','smtp_auth'=>'false','smtp_from'=>'pbx@example.invalid','smtp_from_name'=>'Fictional PBX','smtp_reply_to'=>'reply@example.invalid'];
$stmt=$pdo->prepare('INSERT INTO v_default_settings VALUES(?,\'email\',?,\'text\',?,true,0)');
foreach($values as $key=>$value)$stmt->execute([$key,$key,$value]);
$email=$make();
if(!$email->send() || $email->delivery_deferred || $email->from_address!=='pbx@example.invalid' || $email->from_name!=='Fictional PBX')throw new RuntimeException('Configured central sender failed.');
echo json_encode(['unconfigured_deferred'=>true,'queued_data_unchanged'=>true,'empty_sender_delivered_with_global_identity'=>true]);
'''


def main():
    if os.name == 'nt' or os.geteuid() != 0 or not (PG/'initdb').is_file():
        raise SystemExit('Requires Linux root with PostgreSQL18, PHP PDO pgsql and Lua; use native Windows acceptance separately.')
    work = Path(tempfile.mkdtemp(prefix='openweb-voicemail-mail-'))
    work.chmod(0o711)
    cluster = work/'cluster'; cluster.mkdir(mode=0o700)
    user = pwd.getpwnam('postgres'); os.chown(cluster,user.pw_uid,user.pw_gid)
    started = False
    def pg(name,*args,input=None):
        result = subprocess.run(['runuser','-u','postgres','--',str(PG/name),*map(str,args)],input=input,
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=cluster,timeout=45)
        if result.returncode:
            raise AssertionError('Independent PostgreSQL operation failed: '+name)
        return result.stdout.decode()
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1',0)); port=reservation.getsockname()[1]
    def sql(value):
        return pg('psql','-h',cluster,'-p',port,'-U','postgres','-d','postgres','-X','-At','-v','ON_ERROR_STOP=1',input=value.encode())
    try:
        pg('initdb','-D',cluster,'--auth-local=trust','--auth-host=reject','--encoding=UTF8','--locale=C')
        pg('pg_ctl','-D',cluster,'-l',cluster/'server.log','-o',f"-h '' -k {cluster} -p {port}",'-w','start'); started=True
        sql('''CREATE TABLE v_default_settings(default_setting_uuid text,default_setting_category text,default_setting_subcategory text,default_setting_name text,default_setting_value text,default_setting_enabled boolean,default_setting_order integer);
CREATE TABLE v_email_queue(email_queue_uuid uuid PRIMARY KEY,domain_uuid uuid,hostname text,email_date timestamptz,email_from text NOT NULL,email_to text,email_subject text,email_body text,email_status text,email_uuid uuid,email_action_after text,insert_date timestamptz);
CREATE TABLE v_email_queue_attachments(email_queue_attachment_uuid uuid PRIMARY KEY,email_queue_uuid uuid REFERENCES v_email_queue,email_attachment_mime_type text,email_attachment_type text,email_attachment_path text,email_attachment_name text,email_attachment_base64 text,domain_uuid uuid,insert_date timestamptz);''')
        result = subprocess.run(['lua',str(ROOT/'tests/voicemail_mail_queue.lua'),str(ROOT)],capture_output=True,check=True,timeout=20)
        cases=json.loads(result.stdout)['cases']
        for case in cases:
            sql('TRUNCATE v_email_queue CASCADE;\n'+';\n'.join(case['sql'])+';')
            actual=json.loads(sql("SELECT json_build_object('count',count(*),'sender',min(email_from)) FROM v_email_queue;"))
            assert actual=={'count':1,'sender':case['expected_sender']},case['name']
            assert int(sql('SELECT count(*) FROM v_email_queue_attachments;'))==int(case['attachment']),case['name']
        # Retain the genuinely generated unconfigured row for the real PHP transport.
        case=cases[0];sql('TRUNCATE v_email_queue CASCADE;\n'+';\n'.join(case['sql'])+';')
        sql("UPDATE v_email_queue SET email_subject='unconfigured';")
        spec=importlib.util.spec_from_file_location('smtp_fixture',ROOT/'tests/smtp_transport_integration.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with socketserver.ThreadingTCPServer(('127.0.0.1',0),module.SMTPFixture) as sink:
            sink.deliveries=[];sink.connections=[];sink.envelopes=[];sink.record_lock=threading.Lock();sink.daemon_threads=True
            worker=threading.Thread(target=sink.serve_forever,daemon=True);worker.start()
            try:
                script=work/'transport.php';script.write_text(PHP);script.chmod(0o600)
                result=subprocess.run(['php',str(script),str(ROOT),str(cluster),str(port),str(sink.server_address[1])],cwd=ROOT,capture_output=True,check=True,timeout=35)
                assert all(json.loads(result.stdout).values())
                assert len(sink.deliveries)==1 and sink.connections==[(False,0)]
                message=BytesParser(policy=default).parsebytes(sink.deliveries[0][1])
                assert str(message['From'])=='Fictional PBX <pbx@example.invalid>'
                assert str(message['Reply-To'])=='Fictional PBX <reply@example.invalid>'
                assert sink.envelopes==['MAIL FROM:<pbx@example.invalid>']
            finally:
                sink.shutdown();worker.join(3)
        print('PASS: eight actual Lua queue cases persisted with exact sender/attachment and interleaved name isolation in isolated PostgreSQL; actual PHP deferral preserves empty-sender queue and local SMTP uses enforced global From/Reply-To/envelope without AUTH.')
    finally:
        if started:pg('pg_ctl','-D',cluster,'-m','fast','-w','stop')
        shutil.rmtree(work)


if __name__=='__main__':
    main()
