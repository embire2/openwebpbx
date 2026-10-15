#!/usr/bin/env python3
"""Actual SMTP/TLS wire and strict bounded native-fixture diagnostic controls."""
import importlib.util
import json
import os
from pathlib import Path
import smtplib
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native_smtp',ROOT/'tests/windows-native-acceptance.py')
n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)
spec=importlib.util.spec_from_file_location('smtp_wire',ROOT/'tests/smtp_transport_integration.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
checks=0

def check(value):
    global checks
    assert value;checks+=1

def result(row,code=0):return subprocess.CompletedProcess([],code,json.dumps(row).encode(),b'PRIVATE_STDERR')

for row,outcome in [({'deferred':True,'reason':'maintenance'},'deferred_maintenance'),({'deferred':True,'reason':'restore'},'deferred_restore'),({'configured':False,'selected':0,'attempts_consumed':0},'unconfigured'),({'configured':True,'selected':1,'processed':1},'processed')]:
    fields=n.smtp_tick_fields(result(row));check(fields['smtp_tick_outcome']==outcome);check('PRIVATE' not in json.dumps(fields))
for row in ({'deferred':'true','reason':'maintenance'},{'deferred':True,'reason':'PRIVATE'},{'deferred':True,'reason':'maintenance','configured':True},{'configured':False,'selected':False,'attempts_consumed':0}, {'configured':True,'selected':True,'processed':0},{'configured':True,'selected':11,'processed':1},{'configured':True,'selected':1,'processed':2},[],None):
    check(n.smtp_tick_fields(result(row))['smtp_tick_outcome']=='unrecognized')
check(n.smtp_tick_fields(result({},75))['smtp_tick_outcome']=='command_failed')
for raw in (b'PRIVATE',b'{}\n{}',b'x'*4097):check(n.smtp_tick_fields(subprocess.CompletedProcess([],0,raw,b''))['smtp_tick_outcome']=='unrecognized')

with tempfile.TemporaryDirectory(prefix='ow-smtp-control-') as folder:
    root=Path(folder);f=SimpleNamespace(evidence=root,smtp_failure={})
    # The only repeatable outcome is an explicit maintenance deferral. An actual
    # processed send, restore refusal, malformed response or failure is never retried.
    for response in (result({'deferred':True,'reason':'restore'}),result({'deferred':True,'reason':'PRIVATE'}),result({},75)):
        with patch.object(n.subprocess,'run',return_value=response) as run:
            try:n.smtp_tick(f,time.monotonic()+1)
            except (AssertionError,subprocess.CalledProcessError):check(run.call_count==1)
            else:raise AssertionError('A refused tick was accepted')
    with patch.object(n.subprocess,'run',side_effect=[result({'deferred':True,'reason':'maintenance'}),result({'configured':True,'selected':1,'processed':1})]) as run:
        start=time.monotonic();n.smtp_tick(f,start+1)
        check(run.call_count==2 and time.monotonic()-start<1)
        check(f.smtp_failure['smtp_tick_maintenance_deferrals']==1 and f.smtp_failure['smtp_tick_retry_count']==1)
        check(all(0<call.kwargs['timeout']<=1 for call in run.call_args_list))
    with patch.object(n.subprocess,'run',return_value=result({'deferred':True,'reason':'maintenance'})):
        start=time.monotonic()
        try:n.smtp_tick(f,start+.06)
        except AssertionError:check(time.monotonic()-start<.2)
        else:raise AssertionError('Maintenance extended the deadline')
    for processed in (0,1):
        with patch.object(n.subprocess,'run',return_value=result({'configured':True,'selected':1,'processed':processed})) as run:
            n.smtp_tick(f,time.monotonic()+1);check(run.call_count==1)
    with patch.object(n.subprocess,'run',side_effect=subprocess.TimeoutExpired('PRIVATE',1)) as run:
        try:n.smtp_tick(f,time.monotonic()+1)
        except subprocess.TimeoutExpired:check(run.call_count==1 and f.smtp_failure['smtp_tick_outcome']=='command_timeout')
        else:raise AssertionError('A timed-out send was retried')

    # The actual product Tick's maintenance branch, with a real process-held
    # .NET sharing lock. Only its Windows paths/platform and dispatch delegate
    # are replaced; dispatch is counted, not claimed as an SMTP delivery.
    pwsh=os.environ.get('OPENWEB_TEST_PWSH')
    if pwsh:
        tools=root/'tools';tools.mkdir();state=root/'state';state.mkdir();(state/'updates').mkdir();(state/'backup-restore').mkdir()
        (state/'installation.json').write_text('{"Completed":true}')
        (tools/'Restore-Gates.ps1').write_bytes((ROOT/'packaging/windows/Restore-Gates.ps1').read_bytes())
        source=(ROOT/'packaging/windows/Install-MailQueue.ps1').read_text().replace('#Requires -RunAsAdministrator','')
        quote=lambda value:"'"+str(value).replace("'","''")+"'"
        source=source.replace("$root='C:\\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX'",'$root='+quote(root)+';$state='+quote(state))
        source=source.replace("if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows is required.'}",'')
        source=source.replace('& "$root\\php\\php.exe" (Join-Path $PSScriptRoot \'process-mail.php\') "$root\\web"','Invoke-FixtureDispatch')
        helper=tools/'Install-MailQueue.ps1';helper.write_text(source)
        counter=root/'dispatch-count';counter.write_text('0');ready=root/'lock-ready';release=root/'lock-release'
        wrapper=root/'tick.ps1';wrapper.write_text("$ErrorActionPreference='Stop'\nfunction Invoke-FixtureDispatch{[IO.File]::WriteAllText("+quote(counter)+",([int][IO.File]::ReadAllText("+quote(counter)+")+1));$global:LASTEXITCODE=0;'{\"configured\":true,\"selected\":1,\"processed\":1}'}\n& "+quote(helper)+' -Tick')
        holder=root/'hold.ps1';holder.write_text("$ErrorActionPreference='Stop';$lock=[IO.File]::Open("+quote(state/'upgrade.lock')+",'OpenOrCreate','ReadWrite','None');try{[IO.File]::WriteAllText("+quote(ready)+",'ready');$end=[DateTime]::UtcNow.AddSeconds(12);while(!(Test-Path -LiteralPath "+quote(release)+") -and [DateTime]::UtcNow -lt $end){Start-Sleep -Milliseconds 20}}finally{$lock.Dispose()}")
        original_run=subprocess.run
        owner=subprocess.Popen([pwsh,'-NoProfile','-File',str(holder)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+5
            while not ready.exists() and time.monotonic()<deadline and owner.poll() is None:time.sleep(.02)
            check(ready.exists())
            old=original_run([pwsh,'-NoProfile','-File',str(wrapper)],capture_output=True,timeout=4)
            check(old.returncode==0 and n.smtp_tick_fields(old)['smtp_tick_outcome']=='deferred_maintenance' and counter.read_text()=='0')
            def release_lock():time.sleep(.1);release.write_text('release')
            def delegate(args,**kwargs):
                response=original_run([pwsh,'-NoProfile','-File',str(wrapper)],**kwargs)
                if not release.exists() and n.smtp_tick_fields(response)['smtp_tick_outcome']=='deferred_maintenance':
                    release_lock()
                return response
            with patch.object(n.subprocess,'run',side_effect=delegate):n.smtp_tick(f,time.monotonic()+5)
            check(f.smtp_failure['smtp_tick_maintenance_deferrals']>=1 and f.smtp_failure['smtp_tick_retry_count']>=1)
            check(f.smtp_failure['smtp_tick_outcome']=='processed' and counter.read_text()=='1')
        finally:
            release.touch();owner.communicate(timeout=5)
        check(owner.returncode==0)

    # PHP's actual mailer, checked CA trust/hostname, actual AUTH and DATA. No
    # bootstrap/config/database or network endpoint outside the loopback sink.
    cert=root/'certificate.pem';key=root/'private-key.pem'
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'],check=True,capture_output=True)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key)
    with n.NativeSMTPTLSSink(('127.0.0.1',0),m.SMTPFixture) as sink:
        sink.tls_context=context;sink.accepted=0;sink.handshake_completed=0;sink.handshake_failed=0
        sink.deliveries=[];sink.connections=[];sink.envelopes=[];sink.record_lock=threading.Lock();sink.daemon_threads=True
        # Expected rejected TLS handshakes stay silent in this fictional control.
        sink.handle_error=lambda *args:None
        worker=threading.Thread(target=sink.serve_forever,daemon=True);worker.start()
        try:
            php=root/'mail.php';php.write_text('''<?php
require $argv[1].'/resources/phpmailer/class.phpmailer.php';
require $argv[1].'/resources/phpmailer/class.smtp.php';
$mail=new PHPMailer();$mail->isSMTP();$mail->Host='127.0.0.1';$mail->Port=(int)$argv[2];
$mail->SMTPSecure='ssl';$mail->SMTPAuth=true;$mail->Username='fixture-user';$mail->Password='fixture-password';$mail->Timeout=3;
if($argv[3]==='check'){if(!$mail->smtpConnect())exit(2);$mail->smtpClose();exit;}
$mail->setFrom('pbx@example.invalid','Fictional');$mail->addAddress('sink@example.invalid');$mail->Subject='Fictional local message';$mail->Body='Local only';if(!$mail->send())exit(3);
''')
            for action in ('check','send'):
                r=subprocess.run(['php','-d','openssl.cafile='+str(cert),str(php),str(ROOT),str(sink.server_address[1]),action],capture_output=True,timeout=8)
                check(r.returncode==0)
                if action=='check':check(not sink.deliveries)
            check(len(sink.deliveries)==1 and sink.deliveries[0][0])
            check(sink.handshake_completed==2 and sink.handshake_failed==0)
            for trusted,name in ((True,'wrong.example.invalid'),(False,'localhost')):
                client=ssl.create_default_context(cafile=str(cert)) if trusted else ssl.create_default_context()
                try:
                    with socket.create_connection(sink.server_address,timeout=2) as raw:client.wrap_socket(raw,server_hostname=name)
                except ssl.SSLCertVerificationError:check(True)
                else:raise AssertionError('An invalid TLS chain/name was accepted')
            deadline=time.monotonic()+2
            while sink.handshake_failed<2 and time.monotonic()<deadline:time.sleep(.01)
            check(sink.handshake_failed==2 and len(sink.deliveries)==1)
            rows=[{'email_queue_uuid':'owned-private-id','email_status':'waiting','email_retry_count':1,'response_class':'certificate','secret':'PRIVATE'}, {'email_queue_uuid':'foreign-private-id','email_status':'sent','email_retry_count':4}]
            f.cli=lambda action:{'mail':rows}
            fields=n.smtp_snapshot(f,sink,'owned-private-id')
            check(fields['smtp_seed_status']=='waiting' and fields['smtp_seed_retry_count']==1 and fields['smtp_seed_response_class']=='certificate')
            check(fields['smtp_tls_handshake_failed_count']==2 and fields['smtp_delivery_count']==1)
            check(not any(x in json.dumps(fields) for x in ('PRIVATE','private-id',str(root),'@')))
            fields=n.smtp_snapshot(f,sink,'missing-private-id');check(fields['smtp_seed_row_count']==0 and 'smtp_seed_status' not in fields)
            def broken(action):raise ValueError('PRIVATE')
            f.cli=broken;check(n.smtp_snapshot(f,sink,'owned-private-id')['smtp_queue_observed'] is False)
        finally:sink.shutdown();worker.join(3)
    # Execute the exact PHP classifier without running its guarded PBX entrypoint.
    source=(ROOT/'tests/windows-native-fixture.php').read_text();start=source.index('function windows_native_mail_response_class(');end=source.index('function windows_native_queue_table(',start)
    program=root/'response.php';program.write_text('<?php\n'+source[start:end]+'\nforeach(json_decode(stream_get_contents(STDIN),true) as $row)echo windows_native_mail_response_class($row),"\\n";')
    samples=[None,'','Configure global outgoing mail PRIVATE','certificate verify failed PRIVATE','535 Invalid PRIVATE','SMTP connect() failed PRIVATE','PRIVATE', 'certificate '+('x'*65536)]
    r=subprocess.run(['php',str(program)],input=json.dumps(samples),text=True,capture_output=True,check=True)
    check(r.stdout.splitlines()==['none','none','configuration','certificate','authentication','connection','other','other'])
    check('PRIVATE' not in r.stdout and not r.stderr)
print('PASS',checks,'actual SMTP/TLS wire, PHP mailer/classifier, bounded retry and private projection controls; real Tick sharing lock='+str(bool(os.environ.get('OPENWEB_TEST_PWSH')))+'; no PBX configured')
