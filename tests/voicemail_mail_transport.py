"""Actual source Lua/Database binder + isolated PostgreSQL18; no engine or SMTP."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report',type=Path)
parser.add_argument('--source-root',type=Path,default=ROOT)
parser.add_argument('--helper-overlay',type=Path)
parser.add_argument('--lua-fixture',type=Path)
args=parser.parse_args();ROOT=args.source_root.resolve()
HELPER=(args.helper_overlay or ROOT/'app/switch/resources/scripts/resources/functions/voicemail_mail_queue.lua').resolve()
EXERCISE=(args.lua_fixture or Path(__file__).with_suffix('.lua')).resolve()
PG=Path('/usr/lib/postgresql/18/bin')
if os.name=='nt' or getattr(os,'geteuid',lambda:-1)()!=0 or not (PG/'initdb').is_file():
    raise SystemExit('Requires Linux root, PostgreSQL18 and Lua; actual Windows/native-engine qualification is separate.')
import pwd
Q='00000000-0000-4000-8000-000000000001';D='00000000-0000-4000-8000-000000000002'
A='00000000-0000-4000-8000-000000000003';MSG='00000000-0000-4000-8000-000000000004'
FOREIGN='00000000-0000-4000-8000-000000000005';LOCK=1191055002
work=Path(tempfile.mkdtemp(prefix='openweb-vm-chunks-'));work.chmod(0o711)
cluster=work/'cluster';cluster.mkdir(mode=0o700);pguser=pwd.getpwnam('postgres');os.chown(cluster,pguser.pw_uid,pguser.pw_gid)
sock=work/'socket';sock.mkdir(mode=0o755);os.chown(sock,pguser.pw_uid,pguser.pw_gid)
with socket.socket() as reserve:reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1]
client=[str(PG/'psql'),'-X','-qAt','-h',str(sock),'-p',str(port),'-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1']
checks=[];cases=[];children=[];started=False;success=False
def check(ok,label):
    if not ok:raise AssertionError(label)
    checks.append(label)
def server(name,*args):
    r=subprocess.run(['runuser','-u','postgres','--',str(PG/name),*map(str,args)],cwd=cluster,capture_output=True,timeout=30)
    if r.returncode:raise AssertionError('Owned PostgreSQL operation failed: '+name)
def sql(statement):
    r=subprocess.run(client,input=statement,text=True,capture_output=True,timeout=10)
    if r.returncode:raise AssertionError('Owned SQL failed: '+r.stderr[-250:])
    return r.stdout.strip()
def wav(size):
    size=max(44,size);data=(b'\x10\x01\xf0\xfe'*((size-44+3)//4))[:size-44]
    return b'RIFF'+struct.pack('<I',36+len(data))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,1,8000,16000,2,16)+b'data'+struct.pack('<I',len(data))+data
def run_case(name,size=20000,mode='',hook='',concurrent=False):
    sql('TRUNCATE v_email_queue_attachments,v_email_queue;')
    folder=work/name;folder.mkdir();audio=wav(size);recording=folder/'owned.wav';recording.write_bytes(audio)
    cfg={'psql':str(PG/'psql'),'socket':str(sock),'port':port,'mode':mode,'hook':hook,'reached':concurrent,
         'ids':[str(uuid.uuid4()) for _ in range(180)],'audio':str(recording),
         'values':{'queue':Q,'attachment':A,'domain':D,'message':MSG,'hostname':'owned.invalid','sender':'sender@owned.invalid','recipient':'sink@owned.invalid','subject':name,'body':'Owned fictional voicemail','after':'delete'}}
    if name=='metadata_bound':cfg['values']['body']='x'*4097
    if name=='invalid_audio':recording.write_bytes(b'')
    (folder/'case.json').write_text(json.dumps(cfg))
    env={**os.environ,'PGAPPNAME':'owned_vm_'+name,'PGOPTIONS':'-c statement_timeout=5000 -c lock_timeout=5000'}
    p=subprocess.Popen(['lua',str(EXERCISE),str(ROOT),str(HELPER),str(folder)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);children.append(p)
    if concurrent:return p,folder,recording,audio
    out,err=p.communicate(timeout=45)
    if p.returncode:raise AssertionError('Lua fixture failed: '+err[-1000:])
    r=json.loads((folder/'lua.safe.json').read_text());r['case']=name;cases.append(r)
    check(r['max_sql_bytes']<=16384,name+': every actual bound SQL statement remains <=16KiB')
    check(recording.exists(),name+': caller recording retained')
    return r,folder,recording,audio
def observe(r,audio,name,queued,stages=0):
    check(bool(r.get('queued'))==queued,name+': expected acknowledgement')
    check(sql('SELECT count(*) FROM v_email_queue')==('1' if queued else '0'),name+': no partial or duplicate header')
    check(sql('SELECT count(*) FROM v_email_queue_attachments WHERE email_queue_uuid IS NULL')==str(stages),name+': exact stage cleanup/preservation')
    if queued:
        actual=sql("SELECT encode(sha256(decode(email_attachment_base64,'base64')),'hex') FROM v_email_queue_attachments WHERE email_queue_uuid='"+Q+"'")
        check(actual==hashlib.sha256(audio).hexdigest(),name+': PostgreSQL snapshot bytes match original audio')
try:
    server('initdb','-D',cluster,'--auth-local=trust','--auth-host=reject','--encoding=UTF8','--locale=C')
    server('pg_ctl','-D',cluster,'-l',cluster/'server.log','-o',f"-h '' -k {sock} -p {port}",'-w','start');started=True
    check(sql("SELECT current_setting('data_directory')||'|'||current_database()||'|'||coalesce(inet_server_addr()::text,'local')")==str(cluster)+'|postgres|local','exact owned cluster/database/Unix socket identity')
    sql('''CREATE TABLE v_email_queue(email_queue_uuid uuid PRIMARY KEY,domain_uuid uuid,hostname text,email_date timestamptz,email_from text NOT NULL,email_to text,email_subject text,email_body text,email_status text,email_uuid uuid,email_action_before text,email_action_after text,insert_date timestamptz);
CREATE TABLE v_email_queue_attachments(email_queue_attachment_uuid uuid PRIMARY KEY,email_queue_uuid uuid REFERENCES v_email_queue,domain_uuid uuid,email_attachment_mime_type text,email_attachment_type text,email_attachment_path text,email_attachment_name text,email_attachment_base64 text,email_attachment_cid text,insert_date timestamptz);''')
    for name,size in [('small',3200),('large512',524288),('large1m',1048576)]:
        r,_,_,audio=run_case(name,size);observe(r,audio,name,True)
    for mode in ('stage_schema_fail','lost_stage_ack','lost_final_ack','readback_fail','recovery_callback_false'):
        r,_,_,audio=run_case(mode,mode=mode)
        observe(r,audio,mode,mode=='lost_final_ack') if mode not in ('readback_fail','recovery_callback_false') else check(r['refused'] and sql('select count(*) from v_email_queue')=='1','lost final+readback acknowledgement retains complete committed queue and original mailbox')
        if mode=='recovery_callback_false':check(r.get('callback_received_before_false') is True,'actual lookup callback followed by false cannot acknowledge enqueue')
    changes={
      'changed_bytes':"UPDATE v_email_queue_attachments SET email_attachment_base64='FOREIGN' WHERE email_attachment_name='00000001'",
      'changed_index':"UPDATE v_email_queue_attachments SET email_attachment_name='99999999' WHERE email_attachment_name='00000001'",
      'changed_uuid':"UPDATE v_email_queue_attachments SET email_queue_attachment_uuid='"+FOREIGN+"' WHERE email_attachment_name='00000001'",
      'changed_domain':"UPDATE v_email_queue_attachments SET domain_uuid='"+FOREIGN+"' WHERE email_attachment_name='00000001'",
      'changed_cid':"UPDATE v_email_queue_attachments SET email_attachment_cid='foreign' WHERE email_attachment_name='00000001'",
      'missing_chunk':"DELETE FROM v_email_queue_attachments WHERE email_attachment_name='00000001'",
      'foreign_extra':"INSERT INTO v_email_queue_attachments SELECT '"+FOREIGN+"',NULL,domain_uuid,email_attachment_mime_type,email_attachment_type,email_attachment_path,'99999999',email_attachment_base64,email_attachment_cid,now() FROM v_email_queue_attachments WHERE email_attachment_name='00000001'",
      'other_tenant':"INSERT INTO v_email_queue_attachments SELECT '"+FOREIGN+"',NULL,'"+FOREIGN+"',email_attachment_mime_type,email_attachment_type,email_attachment_path,email_attachment_name,email_attachment_base64,email_attachment_cid,now() FROM v_email_queue_attachments WHERE email_attachment_name='00000001'"}
    for name,hook in changes.items():
        r,_,_,audio=run_case(name,hook=hook)
        observe(r,audio,name,name=='other_tenant',0 if name=='missing_chunk' else 1)
    hook="CREATE FUNCTION suppress_own_stage_delete() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF OLD.email_queue_uuid IS NULL AND OLD.email_attachment_name='00000001' THEN RETURN NULL;END IF;RETURN OLD;END$$;CREATE TRIGGER own_delete_guard BEFORE DELETE ON v_email_queue_attachments FOR EACH ROW EXECUTE FUNCTION suppress_own_stage_delete();"
    r,_,_,audio=run_case('suppressed_cleanup',hook=hook);observe(r,audio,'suppressed_cleanup',False,1)
    sql('DROP TRIGGER own_delete_guard ON v_email_queue_attachments;DROP FUNCTION suppress_own_stage_delete()')
    for name in ('metadata_bound','invalid_audio'):
        r,_,_,audio=run_case(name);observe(r,audio,name,False);check(r['queries']==0,name+': fails before database writes')
    sql(f'''CREATE FUNCTION pause_header() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN PERFORM pg_advisory_xact_lock({LOCK});RETURN NEW;END$$; CREATE TRIGGER own_pause BEFORE INSERT ON v_email_queue FOR EACH ROW EXECUTE FUNCTION pause_header();''')
    for name,cancel in [('atomic_visibility',False),('cancelled_final',True)]:
        holder=subprocess.Popen(client,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);children.append(holder)
        holder.stdin.write(f"SELECT 'READY' FROM (SELECT pg_advisory_lock({LOCK})) x;\n");holder.stdin.flush()
        check(holder.stdout.readline().strip()=='READY',name+': owned concurrency lock held')
        p,folder,recording,audio=run_case(name,concurrent=True)
        until=time.monotonic()+10
        while time.monotonic()<until:
            if sql("select count(*) from pg_stat_activity where application_name='owned_vm_"+name+"' and wait_event='advisory'")=='1':break
            time.sleep(.03)
        else:raise AssertionError('Owned final did not reach header boundary')
        check(sql("SELECT count(*) FROM v_email_queue WHERE email_status='waiting'")=='0',name+': worker cannot observe body-only waiting row')
        check(sql('SELECT count(*) FROM v_email_queue_attachments WHERE email_queue_uuid IS NULL')!='0',name+': hidden staging exists without published header')
        if cancel:sql("select pg_terminate_backend(pid) from pg_stat_activity where application_name='owned_vm_"+name+"' and wait_event='advisory'")
        holder.stdin.write(f"SELECT pg_advisory_unlock({LOCK});\n\\q\n");holder.stdin.flush();holder.communicate(timeout=5)
        out,err=p.communicate(timeout=20)
        check(p.returncode==0,name+': Lua handles native database acknowledgement result')
        r=json.loads((folder/'lua.safe.json').read_text());r['case']=name;cases.append(r);observe(r,audio,name,not cancel)
        check(recording.exists(),name+': caller recording remains intact')
    success=True
finally:
    for child in children:
        if child.poll() is None:
            try:os.killpg(child.pid,signal.SIGTERM) if child.args[0]=='lua' else child.terminate()
            except ProcessLookupError:pass
            child.wait(timeout=5)
    if started:server('pg_ctl','-D',cluster,'-m','fast','-w','stop')
    report={'passed':success,'checks':checks,'count':len(checks),'cases':cases,'scope':'actual source Lua+Database binding, private PostgreSQL18 socket only; no FreeSWITCH/SMTP/Windows/live database','workspace':str(work) if not success else None,'helper_sha256':hashlib.sha256(HELPER.read_bytes()).hexdigest(),'database_source_sha256':hashlib.sha256((ROOT/'app/switch/resources/scripts/resources/functions/database.lua').read_bytes()).hexdigest(),'lua_fixture_sha256':hashlib.sha256(EXERCISE.read_bytes()).hexdigest()}
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n')
    if success:shutil.rmtree(work)
    print(json.dumps({'passed':success,'checks':len(checks),'failure_workspace':str(work) if not success else None}))
