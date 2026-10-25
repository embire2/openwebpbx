#!/usr/bin/env python3
"""Actual Lua SQL + PostgreSQL concurrency + exact PHP worker/local SMTP.

Uses a private PostgreSQL18 cluster and fictional loopback mail only. No installed
configuration, customer files, production database, relay or engine is loaded.
"""
import argparse
import base64
from email.parser import BytesParser
from email.policy import default
import hashlib
import io
import json
import math
import os
from pathlib import Path
import pwd
import select
import shutil
import socket
import socketserver
import stat
import struct
import subprocess
import tempfile
import threading
import time
import wave

ROOT=Path(__file__).resolve().parents[1]
PG=Path('/usr/lib/postgresql/18/bin')
Q='00000000-0000-4000-8000-000000000001'
D='00000000-0000-4000-8000-000000000100'
MSG='00000000-0000-4000-8000-000000000101'
VM='00000000-0000-4000-8000-000000000102'
LOCK=1191055001


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--report',type=Path)
    parser.add_argument('--native-fs',action='store_true',help='Root-reviewed opt-in: own DB-only Lua harness on the installed engine; no calls/configuration changes.')
    args=parser.parse_args()
    if os.name=='nt' or os.geteuid()!=0 or not (PG/'initdb').is_file():raise SystemExit('Requires Linux root, PostgreSQL18, PHP PDO pgsql and Lua; native Windows qualification is separate.')
    work=Path(tempfile.mkdtemp(prefix='openweb-voicemail-durable-'));work.chmod(0o711)
    cluster=work/'cluster';cluster.mkdir(mode=0o700);owner=pwd.getpwnam('postgres');os.chown(cluster,owner.pw_uid,owner.pw_gid)
    socket_path=cluster
    if args.native_fs:
        socket_path=work/'socket';socket_path.mkdir(mode=0o755);os.chown(socket_path,owner.pw_uid,owner.pw_gid)
    with socket.socket() as reserve:reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1]
    started=False;children=[];checks=[];success=False;native_evidence=None
    def check(ok,label):
        if not ok:raise AssertionError(label)
        checks.append(label)
    def server(name,*argv):
        p=subprocess.run(['runuser','-u','postgres','--',str(PG/name),*map(str,argv)],cwd=cluster,capture_output=True,timeout=40)
        if p.returncode:raise AssertionError('Owned PostgreSQL server operation refused: '+name)
    client=[str(PG/'psql'),'-X','-At','-h',str(socket_path),'-p',str(port),'-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
    def sql(value,good=True):
        p=subprocess.run(client,input=value,text=True,capture_output=True,timeout=15)
        if good and p.returncode:raise AssertionError('Owned fixture SQL refused: '+p.stderr[-300:])
        if not good:check(p.returncode!=0,'actual SQL failure refused')
        return p.stdout.strip()
    def start_sql(value,name):
        env={**os.environ,'PGAPPNAME':name};p=subprocess.Popen(client,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
        children.append(p);p.stdin.write(value);p.stdin.close();p.stdin=None;return p
    def finish(p,good=True):
        out,err=p.communicate(timeout=15)
        check((p.returncode==0)==good,'owned producer completed with expected status')
        return out,err
    def holder():
        p=subprocess.Popen(client,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1);children.append(p)
        # One output row avoids a blank void-result line being buffered ahead of
        # the readiness marker while select() sees no further kernel bytes.
        p.stdin.write(f"select 'OWNED_LOCK_READY' from (select pg_advisory_lock({LOCK})) acquired;\n");p.stdin.flush()
        until=time.monotonic()+5
        while time.monotonic()<until:
            if select.select([p.stdout],[],[],0.2)[0] and p.stdout.readline().strip()=='OWNED_LOCK_READY':return p
        raise AssertionError('Owned concurrency lock was not acquired')
    def release(p):
        p.stdin.write(f"select pg_advisory_unlock({LOCK});\n\\q\n");p.stdin.flush();p.communicate(timeout=5)
    def waiting(name):
        until=time.monotonic()+5
        while time.monotonic()<until:
            if sql(f"select count(*) from pg_stat_activity where application_name='{name}' and wait_event='advisory'")=='1':return
            time.sleep(0.05)
        raise AssertionError('Producer did not reach the controlled attachment boundary')
    def counts():return sql("select (select count(*) from v_email_queue where email_status in('waiting','trying'))||':'||(select count(*) from v_email_queue_attachments)")
    pcm=b''.join(struct.pack('<h',int(8000*math.sin(i*2*math.pi*440/8000))) for i in range(1600))
    buffer=io.BytesIO()
    with wave.open(buffer,'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(8000);w.writeframes(pcm)
    audio=buffer.getvalue();audio_hash=hashlib.sha256(audio).hexdigest()
    folder=work/'audio';folder.mkdir();recording=folder/f'msg_{MSG}.wav';recording.write_bytes(audio)
    (folder/'empty.wav').write_bytes(b'')
    with (folder/'oversized.wav').open('wb') as f:f.truncate(32*1024*1024+1)
    custom=folder/'greeting_custom.wav';custom.write_bytes(audio)
    try:
        server('initdb','-D',cluster,'--auth-local=trust','--auth-host=reject','--encoding=UTF8','--locale=C')
        server('pg_ctl','-D',cluster,'-l',cluster/'server.log','-o',f"-h '' -k {socket_path} -p {port}",'-w','start');started=True
        sql('''CREATE TABLE v_email_queue(email_queue_uuid uuid PRIMARY KEY,domain_uuid uuid,hostname text,email_date timestamptz,email_from text NOT NULL,email_to text,email_subject text,email_body text,email_status text,email_uuid uuid,email_action_before text,email_action_after text,insert_date timestamptz,update_date timestamptz,email_retry_count integer,email_response text,email_transcription text);
CREATE TABLE v_email_queue_attachments(email_queue_attachment_uuid uuid PRIMARY KEY,email_queue_uuid uuid REFERENCES v_email_queue,email_attachment_mime_type text,email_attachment_type text,email_attachment_path text,email_attachment_name text,email_attachment_base64 text,email_attachment_cid text,domain_uuid uuid,insert_date timestamptz);
CREATE TABLE v_voicemails(voicemail_uuid uuid PRIMARY KEY,domain_uuid uuid,voicemail_id text,voicemail_file text,voicemail_transcription_enabled boolean,voicemail_transcription_prompt_enabled boolean,voicemail_transcription_prompt text);
CREATE TABLE v_voicemail_messages(voicemail_message_uuid uuid PRIMARY KEY,voicemail_uuid uuid,domain_uuid uuid);
CREATE TABLE v_domains(domain_uuid uuid PRIMARY KEY,domain_name text);
CREATE TABLE v_default_settings(default_setting_category text,default_setting_subcategory text,default_setting_name text,default_setting_value text,default_setting_enabled boolean,default_setting_order integer);
CREATE FUNCTION pause_attachment() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN PERFORM pg_advisory_xact_lock(1191055001);RETURN NEW;END$$;
CREATE TRIGGER owned_attachment_boundary BEFORE INSERT ON v_email_queue_attachments FOR EACH ROW EXECUTE FUNCTION pause_attachment();''')
        cases=json.loads(subprocess.check_output(['lua',str(ROOT/'tests/voicemail_mail_durability.lua'),str(ROOT),str(folder),socket.gethostname()],timeout=15))
        check(all(cases[n]['refused'] for n in ('missing','empty','oversized','invalid_base64','query_false','query_throw')),'actual Lua producer refuses unavailable audio/database without removing mailbox files')
        check(recording.read_bytes()==audio,'Lua refusal cases preserve original recording')
        atomic=cases['atomic']['sql'][0];legacy=cases['legacy']['sql']
        # Positive control: the old real producer exposes the header while attachment blocks.
        hold=holder();sql(legacy[0]);old=start_sql(legacy[1],'owned-old-voicemail');waiting('owned-old-voicemail')
        check(counts()=='1:0','original two-insert race is reproduced');release(hold);finish(old);sql('truncate v_email_queue cascade')
        # New CTE remains invisible to another real connection until both inserts commit.
        hold=holder();producer=start_sql(atomic,'owned-new-voicemail');waiting('owned-new-voicemail')
        check(counts()=='0:0','new waiting header cannot be observed before attachment');release(hold);finish(producer)
        check(counts()=='1:1','new header and attachment become visible together')
        check(base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio,'actual PostgreSQL retains exact audio bytes before worker access')
        sql('truncate v_email_queue cascade')
        hold=holder();producer=start_sql(atomic,'owned-cancelled-voicemail');waiting('owned-cancelled-voicemail')
        sql("select pg_cancel_backend(pid) from pg_stat_activity where application_name='owned-cancelled-voicemail'");finish(producer,False);release(hold)
        check(counts()=='0:0' and recording.read_bytes()==audio,'cancelled producer leaves no partial mail and retains caller recording')
        sql('alter table v_email_queue_attachments drop column email_attachment_base64');sql(atomic,False)
        check(counts()=='0:0','missing attachment schema cannot commit header');sql('alter table v_email_queue_attachments add column email_attachment_base64 text')
        sql("alter table v_email_queue_attachments add constraint controlled_write_failure check(email_attachment_type<>'wav')");sql(atomic,False)
        check(counts()=='0:0' and recording.read_bytes()==audio,'attachment write failure atomically retains original voicemail');sql('alter table v_email_queue_attachments drop constraint controlled_write_failure')
        if args.native_fs:
            native_code=work/'native-sources/resources/functions';native_code.mkdir(parents=True)
            helper=ROOT/'app/switch/resources/scripts/resources/functions/voicemail_mail_queue.lua'
            (native_code/helper.name).write_bytes(helper.read_bytes());(native_code/helper.name).chmod(0o644)
            native=work/'native-mail.lua';native.write_bytes((ROOT/'tests/voicemail_mail_native.lua').read_bytes());native.chmod(0o644)
            native_fixture=work/'native-fixture.json';native_fixture.write_text(json.dumps({'tag':'openweb-owned-voicemail-mail-dbh-v1','socket':str(socket_path),'port':port,'audio':str(recording),'code':str(work/'native-sources')}));native_fixture.chmod(0o644)
            for parent in (work,work/'native-sources',work/'native-sources/resources',native_code,folder):
                parent.chmod(0o711 if parent==work else 0o755)
                check(parent.resolve()==parent and parent.lstat().st_uid==0 and not parent.lstat().st_mode&0o022,'native fixture parent is ordinary and root-owned')
            recording.chmod(0o644)
            bindings={}
            for label,path in [('script',native),('helper',native_code/helper.name),('fixture',native_fixture),('installed_database',Path('/usr/share/freeswitch/scripts/resources/functions/database.lua'))]:
                info=path.lstat();check(path.resolve()==path and stat.S_ISREG(info.st_mode),'native input is an ordinary nonsymlink file')
                if label!='installed_database':check(info.st_uid==0 and not info.st_mode&0o022,'native fixture input is protected root-owned source')
                bindings[label]={'bytes':info.st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'dev':info.st_dev,'ino':info.st_ino,'uid':info.st_uid,'mode':stat.S_IMODE(info.st_mode)}
            check(bindings['script']['sha256']==hashlib.sha256((ROOT/'tests/voicemail_mail_native.lua').read_bytes()).hexdigest() and bindings['helper']['sha256']==hashlib.sha256(helper.read_bytes()).hexdigest(),'native script and helper copies exactly match reviewed source')
            native_evidence={'bindings':bindings}
            command=['fs_cli','-x',f'lua {native} {native_fixture}']
            result=subprocess.run(command,capture_output=True,text=True,timeout=25)
            (work/'native.stdout.log').write_text(result.stdout);(work/'native.stderr.log').write_text(result.stderr)
            native_evidence.update(stdout_sha256=hashlib.sha256(result.stdout.encode()).hexdigest(),stderr_sha256=hashlib.sha256(result.stderr.encode()).hexdigest(),returncode=result.returncode)
            check(result.returncode==0 and result.stderr=='' and all(json.loads(result.stdout).values()),'actual FreeSWITCH native DBh success/callback/schema refusal pass')
            native_evidence['result']=json.loads(result.stdout)
            check(sql("select count(*) from v_email_queue where email_queue_uuid='00000000-0000-4000-8000-000000000200'")=='1','native committed snapshot is visible to independent PostgreSQL connection')
            sql('truncate v_email_queue cascade')
        # Copy the exact unmodified product worker; only its external bootstrap is fictional.
        runtime=work/'runtime';job=runtime/'app/email_queue/resources/jobs/email_send.php';job.parent.mkdir(parents=True)
        job.write_bytes((ROOT/'app/email_queue/resources/jobs/email_send.php').read_bytes());resources=runtime/'resources';resources.mkdir()
        (resources/'require.php').write_bytes((ROOT/'tests/voicemail_mail_durability_bootstrap.php').read_bytes())
        check(hashlib.sha256(job.read_bytes()).hexdigest()==hashlib.sha256((ROOT/'app/email_queue/resources/jobs/email_send.php').read_bytes()).hexdigest(),'executed worker is byte-identical to reviewed source')
        (runtime/'fixture.json').write_text(json.dumps({'source':str(ROOT),'dsn':f'pgsql:host={socket_path};port={port};dbname=postgres'}))
        def start_worker():
            p=subprocess.Popen(['php',str(job),f'email_queue_uuid={Q}&hostname={socket.gethostname()}'],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);children.append(p);return p
        def end_worker(p):
            out,err=p.communicate(timeout=20);check(p.returncode==0 and err=='','exact product worker exits cleanly');return out
        def setup(kind='atomic',option='attach'):
            sql('truncate v_email_queue cascade;truncate v_voicemail_messages;truncate v_voicemails;truncate v_domains')
            recording.write_bytes(audio)
            sql(f"insert into v_domains values('{D}','fixture.invalid');insert into v_voicemails values('{VM}','{D}','8103','{option}',false,false,'');insert into v_voicemail_messages values('{MSG}','{VM}','{D}')")
            for stmt in cases[kind]['sql']:sql(stmt)
        def exists():return sql(f"select count(*) from v_voicemail_messages where voicemail_message_uuid='{MSG}'")=='1'
        class SMTP(socketserver.StreamRequestHandler):
            def handle(self):
                self.request.settimeout(15);self.wfile.write(b'220 owned.invalid ESMTP\r\n')
                while line:=self.rfile.readline():
                    verb=line.split()[0].upper();self.server.commands.append(verb)
                    if verb==b'EHLO':self.wfile.write(b'250 owned.invalid\r\n')
                    elif verb in (b'MAIL',b'RCPT',b'RSET'):self.wfile.write(b'250 OK\r\n')
                    elif verb==b'DATA':
                        self.wfile.write(b'354 Continue\r\n');self.wfile.flush();data=bytearray()
                        while part:=self.rfile.readline():
                            if part==b'.\r\n':break
                            data.extend(part[1:] if part.startswith(b'..') else part)
                        self.server.messages.append(bytes(data));self.server.received.set()
                        if not self.server.ack.wait(10):raise AssertionError('Owned SMTP acknowledgement was not released')
                        self.wfile.write(b'550 Controlled rejection\r\n' if self.server.reject else b'250 Accepted durable fixture\r\n')
                    elif verb==b'QUIT':self.wfile.write(b'221 Bye\r\n');self.wfile.flush();return
                    else:raise AssertionError('Unexpected owned SMTP command')
                    self.wfile.flush()
        with socketserver.ThreadingTCPServer(('127.0.0.1',0),SMTP) as sink:
            sink.daemon_threads=True;sink.messages=[];sink.commands=[];sink.reject=False;sink.received=threading.Event();sink.ack=threading.Event()
            thread=threading.Thread(target=sink.serve_forever,daemon=True);thread.start()
            try:
                values={'smtp_global':'true','smtp_host':'127.0.0.1','smtp_port':str(sink.server_address[1]),'smtp_secure':'none','smtp_auth':'false','smtp_from':'pbx@example.invalid','smtp_reply_to':'reply@example.invalid'}
                for k,v in values.items():sql(f"insert into v_default_settings values('email','{k}','text','{v}',true,0)")
                setup();sql("update v_voicemails set voicemail_file='link'")
                recording.write_bytes(audio[:-2]+b'\x01\x01') # Cannot replace already frozen queued audio.
                process=start_worker();until=time.monotonic()+8
                while not sink.received.wait(0.05) and time.monotonic()<until:
                    if process.poll() is not None:break
                check(sink.received.is_set(),'actual SMTP receives queued audio')
                check(exists() and recording.exists(),'mailbox row and recording remain before SMTP250')
                check(base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio,'immutable audio is durably staged before SMTP250')
                message=BytesParser(policy=default).parsebytes(sink.messages[-1]);attachments=list(message.iter_attachments())
                check(len(attachments)==1 and attachments[0].get_content_disposition()=='attachment' and attachments[0].get_payload(decode=True)==audio,'SMTP receives original playable audio attachment despite later file/setting changes')
                with wave.open(io.BytesIO(attachments[0].get_payload(decode=True))) as wav:check(wav.getnframes()==1600 and wav.readframes(1600)==pcm,'independent WAV decoder confirms actual received audio')
                sink.ack.set();end_worker(process)
                check(not exists() and not recording.exists(),'mailbox row and file removed only after accepted SMTP250')
                check(sql('select email_attachment_base64 is null from v_email_queue_attachments')=='t','delete-after-email clears durable audio only after accepted SMTP and complete mailbox cleanup')
                setup();sink.reject=True;sink.received.clear();sink.ack.set();end_worker(start_worker())
                check(exists() and recording.read_bytes()==audio and sql('select email_status from v_email_queue')=='trying','SMTP550 retains mailbox recording and retryable queued audio')
                check(base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio,'SMTP550 retains the durable pending audio snapshot')
                # In-flight old producer: header exists without its attachment when worker runs.
                sql('truncate v_email_queue cascade');sql(legacy[0]);before_messages=len(sink.messages)
                end_worker(start_worker());check(exists() and recording.exists() and len(sink.messages)==before_messages,'legacy pending header cannot send body-only or delete voicemail')
                sql(legacy[1]);sink.reject=False;end_worker(start_worker())
                check(not exists() and not recording.exists() and sql("select email_attachment_base64 is null from v_email_queue_attachments")=='t','legacy attachment arriving later is staged, safely delivered and purged only after deletion')
                setup();sql("update v_email_queue set email_action_after=''");end_worker(start_worker())
                check(exists() and recording.exists() and base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio,'keep-local voicemail and its durable audio remain unchanged after delivery')
                setup();blocked=folder/f'intro_{MSG}.wav';blocked.mkdir();end_worker(start_worker())
                check(blocked.is_dir() and base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio and 'voicemail_cleanup_incomplete' in sql('select email_response from v_email_queue'),'filesystem cleanup failure retains the delivered durable snapshot and records incomplete cleanup')
                blocked.rmdir()
                variant=folder/f'MSG_{MSG.upper()}.WAV';variant.write_bytes(audio)
                case_left=json.loads(subprocess.check_output(['php',str(resources/'require.php'),'--clear',Q,D,MSG],cwd=ROOT,text=True,timeout=10))
                check(not case_left['cleared'] and base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio,'case-variant recording name cannot bypass Windows-compatible absence proof');variant.unlink()
                recording.write_bytes(audio);folder.chmod(0)
                try:
                    denied=json.loads(subprocess.check_output(['php',str(resources/'require.php'),'--clear-unprivileged',Q,D,MSG],cwd=ROOT,text=True,timeout=10))
                    check(denied['unprivileged_sender'] and not denied['cleared'] and base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio,'actual www-data identity cannot mistake inaccessible recording parent for absence')
                finally:folder.chmod(0o755)
                check(recording.read_bytes()==audio,'unsearchable-parent refusal preserves the remaining original recording');recording.unlink()
                cleared=json.loads(subprocess.check_output(['php',str(resources/'require.php'),'--clear',Q,D,MSG],cwd=ROOT,text=True,timeout=10))
                check(cleared['cleared'] and sql('select email_attachment_base64 is null from v_email_queue_attachments')=='t','completed delayed cleanup purges only its delivered snapshot without resending')
                setup();sql("create function retain_owned_vm() returns trigger language plpgsql as $$begin return null;end$$;create trigger controlled_vm_delete_refusal before delete on v_voicemail_messages for each row execute function retain_owned_vm()")
                end_worker(start_worker())
                check(exists() and base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio,'database mailbox cleanup failure retains the delivered durable snapshot')
                sql('drop trigger controlled_vm_delete_refusal on v_voicemail_messages;drop function retain_owned_vm()')
                setup();sink.received.clear();sink.ack.clear();process=start_worker()
                check(sink.received.wait(8),'metadata-race fixture reaches controlled SMTP boundary')
                sql("update v_email_queue_attachments set email_attachment_mime_type='audio/changed-after-delivery'");sink.ack.set();end_worker(process)
                check(not exists() and base64.b64decode(sql('select email_attachment_base64 from v_email_queue_attachments'))==audio,'changed attachment metadata prevents purging an unproven delivered snapshot')
                setup('link','link');sql("update v_voicemails set voicemail_file='attach'");before_messages=len(sink.messages);end_worker(start_worker())
                check(exists() and recording.exists() and len(sink.messages)==before_messages+1 and not list(BytesParser(policy=default).parsebytes(sink.messages[-1]).iter_attachments()),'legitimate queued link notice stays link-only after mailbox setting changes')
                def generic(rows):
                    path=work/'generic.json';path.write_text(json.dumps(rows));p=subprocess.run(['php',str(resources/'require.php'),'--generic',str(path)],cwd=ROOT,text=True,capture_output=True,timeout=10)
                    check(p.returncode==0 and p.stderr=='','actual generic transport exits cleanly');return json.loads(p.stdout)['sent']
                before_messages=len(sink.messages)
                check(generic([{'name':'missing.wav','path':str(folder),'base64':''}]) is False and len(sink.messages)==before_messages,'generic missing requested attachment cannot become body-only success')
                check(generic([{'name':'invalid.bin','path':'','base64':'***'}]) is False and len(sink.messages)==before_messages,'generic invalid base64 cannot become body-only success')
                check(generic([{'name':'empty.wav','path':str(folder),'base64':''}]) is True,'legitimate zero-byte generic file remains supported')
                check(generic([{'name':'empty.bin','path':'','base64':''}]) is True,'legitimate zero-byte generic string remains supported')
                setup_payload=json.dumps({'server':'https://fixture.openwebpbx.com','code':'owned-fictional-one-use-code','extension':'8103'})
                setup_path=work/'fictional.openwebpbx';setup_path.write_text(setup_payload)
                png=subprocess.check_output(['php',str(resources/'require.php'),'--qr',str(setup_path)],cwd=ROOT,text=True,timeout=10).strip()
                check(base64.b64decode(png).startswith(b'\x89PNG\r\n\x1a\n'),'actual welcome QR generator produces a PNG')
                check(generic([{'name':'qr.png','path':'','base64':png,'cid':'owned-qr','mime_type':'image/png'},
                               {'name':'OpenWebPBX-8103.openwebpbx','path':'','base64':base64.b64encode(setup_payload.encode()).decode(),'cid':None,'mime_type':'application/vnd.openwebpbx.config+json'}]) is True,'valid inline CID/base64 plus welcome setup attachment remain supported')
                final=BytesParser(policy=default).parsebytes(sink.messages[-1]);check(any(str(p.get('Content-ID'))=='<owned-qr>' and p.get_payload(decode=True)==base64.b64decode(png) for p in final.walk()),'SMTP preserves actual welcome QR bytes/content ID')
                check(any(p.get_filename()=='OpenWebPBX-8103.openwebpbx' and p.get_payload(decode=True)==setup_payload.encode() for p in final.iter_attachments()),'SMTP preserves welcome-compatible one-use setup file bytes')
                check(b'AUTH' not in sink.commands,'IP-authentication fixture never sends SMTP AUTH')
            finally:sink.ack.set();sink.shutdown();thread.join(3)
        check(custom.read_bytes()==audio,'all custom greeting bytes remain untouched')
        success=True
    finally:
        for index,p in enumerate(children):
            if p.poll() is None:
                p.terminate()
                try:p.communicate(timeout=3)
                except subprocess.TimeoutExpired:p.kill();p.communicate(timeout=3)
            # Preserve closed observations even for a child that exited before an assertion.
            try:
                output,errors=p.communicate(timeout=3)
                (work/f'child-{index}.stdout.log').write_text(output or '')
                (work/f'child-{index}.stderr.log').write_text(errors or '')
            except (ValueError,subprocess.TimeoutExpired) as error:
                (work/f'child-{index}.observer.json').write_text(json.dumps({'error':type(error).__name__,'returncode':p.poll()})+'\n')
        queue_observation=None
        if started:
            if not success:
                try:queue_observation=sql("select coalesce(json_agg(json_build_object('status',email_status,'response',email_response,'retries',email_retry_count))::text,'[]') from v_email_queue")
                except Exception:queue_observation='unavailable'
            server('pg_ctl','-D',cluster,'-m','fast','-w','stop')
        report={'passed':success,'checks':checks,'check_count':len(checks),'audio_sha256':audio_hash,'scope':'private PostgreSQL cluster, actual source Lua/PHP worker, loopback SMTP only','failure_workspace':str(work) if not success else None,
                'smtp_command_observations':[v.decode('ascii','replace') for v in sink.commands] if 'sink' in locals() else [],'failed_queue_observation':queue_observation,'native_evidence':native_evidence}
        if args.report:args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n')
        if args.report and native_evidence:
            retained=args.report.parent/(args.report.stem+'.native');retained.mkdir(mode=0o700)
            for label,path in [('script.lua',work/'native-mail.lua'),('helper.lua',work/'native-sources/resources/functions/voicemail_mail_queue.lua'),('native.stdout.log',work/'native.stdout.log'),('native.stderr.log',work/'native.stderr.log')]:
                if path.is_file():(retained/label).write_bytes(path.read_bytes())
            (retained/'bindings.json').write_text(json.dumps(native_evidence,indent=2)+'\n')
        if success:shutil.rmtree(work)
    print(json.dumps({'passed':True,'checks':len(checks),'audio_sha256':audio_hash}))


if __name__=='__main__':main()
