"""Actual loopback barrier/controller controls with explicit job/DB/admin adapters.

No native Windows, production transport, PBX or database acceptance is claimed.
"""
import ast
from email.message import EmailMessage
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import smtplib
import shutil
import subprocess
import tempfile
import threading
import types
import unittest
import wave

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
m=load('delete_case_controller',ROOT/'tests/windows_voicemail_delete_native.py')
smtp=load('delete_case_wire_sink',ROOT/'tests/smtp_transport_integration.py')

class Fixture:
    def __init__(self,root,fault='none'):
        self.source=ROOT;self.evidence=root;self.fault=fault;self.phase='prepared';self.events=[]
        self.old={'smtp_host':'127.0.0.1','smtp_port':'587','smtp_secure':'none'};self.smtp=dict(self.old);self.mode='Attachment'
        self.web=types.SimpleNamespace(submit=self.submit)
        stream=io.BytesIO()
        with wave.open(stream,'wb')as audio:audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(8000);audio.writeframes(b'\0\0'*6000)
        self.audio=stream.getvalue();self.sha=hashlib.sha256(self.audio).hexdigest();self.closed=False;self.scheduled=None
    def submit(self,path,action,fields):
        assert action=='save'
        if path.startswith('/app/pbx_setup/'):
            target=fields['voicemail_email'];self.events.append('mode-'+target)
            if self.fault=='ignored_mode_restore'and target=='Attachment':return
            self.mode=target
            if self.fault=='restore_mode'and self.mode=='Attachment':raise RuntimeError('Controlled mode restore refusal')
        else:
            target=dict(fields);self.events.append('smtp-restored'if target==self.old else'smtp-new')
            if self.fault=='ignored_smtp_restore'and target==self.old:return
            self.smtp=target
            if self.fault=='smtp_save'and self.smtp!=self.old:raise RuntimeError('Controlled SMTP save refusal')
    def cli(self,action,*args):
        assert action in ('voicemail-delete-prepare','voicemail-delete-status')
        if args==('baseline',):
            assert self.mode=='Attachment';self.settings=(self.mode,dict(self.smtp));return {'schema':1,'settings_snapshot_owned':True}
        if args==('restored',):
            self.events.append('restored-readback');assert self.settings==(self.mode,self.smtp)
            return {'schema':1,'mode_and_smtp_restored':True}
        if action.endswith('prepare'):
            assert self.smtp!=self.old,'Barrier SMTP must precede the actual producer.'
            self.events.append('prepare')
        if action.endswith('prepare')and self.fault=='prepare':raise RuntimeError('Controlled preparation refusal')
        sent=self.phase=='sent'
        if action.endswith('status'):self.events.append('after'if sent else'before')
        result={'schema':1,'message_exists':not sent,'file_exists':not sent,'file_exact':not sent,
                'snapshot_exact':not sent,'snapshot_cleared':sent,'queue_state':'sent'if sent else'trying',
                'actual_admin_delete_option':True,'actual_native_atomic_producer':True,
                'original_recording_preserved':True,'consumer_released':self.phase in ('prepared','sent'),'expected_sha256':self.sha}
        if not sent and action.endswith('status')and self.fault=='early_cleanup':result['message_exists']=False
        if sent and self.fault=='snapshot_kept':result['snapshot_cleared']=False
        if sent and self.fault=='original_lost':result['original_recording_preserved']=False
        return result
    def job(self,command,directory,timeout):
        assert command==['exact-WindowsPowerShell','-NoProfile','-NonInteractive','-File','C:/OpenWebPBX/tools/Install-MailQueue.ps1','-Tick']and timeout==240
        if self.fault=='scheduled':
            self.scheduled=threading.Thread(target=self.send,daemon=True);self.scheduled.start()
        else:self.send()
        proof={name:True for name in ('created_suspended','assigned_before_resume','resumed','ordinary_exit','owned_processes_closed','handles_closed')}
        if self.fault=='job_cleanup':proof['owned_processes_closed']=False
        (directory/'process.safe.json').write_text(json.dumps(proof));self.closed=True;self.events.append('job-closed')
        count=0 if self.fault=='scheduled' else 1
        return subprocess.CompletedProcess(command,0,json.dumps({'configured':True,'selected':count,'processed':count}),'')
    def send(self):
        message=EmailMessage();message['From']='Fictional Windows PBX <pbx@example.invalid>';message['Reply-To']='Fictional Windows PBX <reply@example.invalid>';message['To']='sink@example.invalid';message.set_content('Fictional voicemail')
        message.add_attachment(self.audio,maintype='audio',subtype='wav',filename='owned.wav')
        self.phase='trying'
        with smtplib.SMTP(self.smtp['smtp_host'],int(self.smtp['smtp_port']),timeout=15)as client:
            client.mail=lambda sender,options=():client.docmd('MAIL','FROM:<'+sender+'>')
            client.send_message(message,from_addr='pbx@example.invalid',to_addrs=['sink@example.invalid'])
        self.events.append('250-received');self.phase='sent'

class Controls(unittest.TestCase):
    def run_case(self,fault='none'):
        with tempfile.TemporaryDirectory(prefix='openweb-native-delete-source-')as temp:
            f=Fixture(Path(temp),fault)
            original=types.SimpleNamespace(WINPS='exact-WindowsPowerShell',load_module=lambda name,path:types.SimpleNamespace(run=f.job),smtp_tick_fields=lambda result:{'smtp_tick_outcome':'processed'})
            saved=m.os;m.os=types.SimpleNamespace(name='nt')
            try:
                if fault in ('none','scheduled'):result=m.run(f,original,smtp,f.old)
                else:
                    with self.assertRaises((AssertionError,RuntimeError)):m.run(f,original,smtp,f.old)
                    result=None
            finally:
                m.os=saved
                if f.scheduled:f.scheduled.join(3);self.assertFalse(f.scheduled.is_alive())
            self.assertEqual(f.mode,'AttachmentAndDelete'if fault=='ignored_mode_restore'else'Attachment')
            if fault=='ignored_smtp_restore':self.assertNotEqual(f.smtp,f.old)
            else:self.assertEqual(f.smtp,f.old)
            if fault not in ('prepare','smtp_save'):
                self.assertTrue(f.closed);self.assertLess(f.events.index('job-closed'),f.events.index('mode-Attachment'))
            return f,result
    def test_actual_loopback250_waits_for_retention_and_cleanup_then_restores(self):
        f,result=self.run_case();self.assertTrue(all(result[name]is True for name in m.FLAGS));self.assertEqual(result['attachment_sha256'],f.sha)
        self.assertLess(f.events.index('before'),f.events.index('250-received'));self.assertLess(f.events.index('250-received'),f.events.index('after'))
        self.assertLess(f.events.index('smtp-new'),f.events.index('prepare'))
        f,result=self.run_case('scheduled');self.assertTrue(result['consumer_attribution_nonexclusive']);self.assertLess(f.events.index('job-closed'),f.events.index('250-received'))
    def test_early_cleanup_snapshot_original_and_job_refusals_never_pass(self):
        for fault in ('early_cleanup','snapshot_kept','original_lost','job_cleanup'):
            with self.subTest(fault=fault):self.run_case(fault)
    def test_prepare_save_and_restore_failures_remain_failures(self):
        for fault in ('prepare','smtp_save','restore_mode','ignored_mode_restore','ignored_smtp_restore'):
            with self.subTest(fault=fault):self.run_case(fault)
    def test_native_guard_and_additive_actual_entrypoint(self):
        saved=m.os;m.os=types.SimpleNamespace(name='posix')
        try:
            with self.assertRaises(RuntimeError):m.run(None,None,None,None)
        finally:m.os=saved
        text=(ROOT/'tests/windows-native-acceptance.py').read_text();tree=ast.parse(text)
        fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef)and n.name=='smtp_and_queued_voicemail')
        calls=[n for n in ast.walk(fn)if isinstance(n,ast.Call)and isinstance(n.func,ast.Attribute)and n.func.attr=='record'and n.args and isinstance(n.args[0],ast.Constant)and n.args[0].value==m.CASE]
        self.assertEqual(len(calls),1)
        prefix=text.index("f.record('native_queued_voicemail_global_smtp_ip_auth_actual_loopback_attachment'")
        new=text.index("deletion=load_module('windows_voicemail_delete_native'")
        record=text.index("f.record('"+m.CASE+"'")
        next_case=text.index("f.active_case='global_smtp_password_auth'",new)
        self.assertLess(prefix,new);self.assertLess(new,record);self.assertLess(record,next_case)
        parent=(ROOT/'tests/windows-native-acceptance.ps1').read_text()
        self.assertIn('AssertVoicemailDeleteNativeCase $native.checks',parent)
        self.assertIn("try{AssertVoicemailDeleteNativeCase $Checks}catch{break}",parent)
        for source in ('windows-native-acceptance.ps1','windows-suite.ps1'):self.assertIn("'"+m.CASE+"'",(ROOT/'tests'/source).read_text())
        fixture=(ROOT/'tests/windows-native-fixture.php').read_text()
        self.assertLess(fixture.index("$fixtureStage='admin_permissions'"),fixture.index("windows_voicemail_delete_fixture($action"))
        php=(ROOT/'tests/windows_voicemail_delete_fixture.php').read_text()
        self.assertLess(php.index("$s['delete_mail']="),php.index("fopen($file,'xb')"))
        self.assertLess(php.index("hash_file('sha256',$installed)!==hash_file('sha256',$reviewed)"),php.index("event_socket::api('lua '"))
        self.assertIn("event_socket::api('lua '.$script.' '.$producer)",php)
        self.assertIn("preg_match('/[\\x00\\r\\n\"\\s]/',$producer)",php)
        self.assertNotIn('insert into v_email_queue',php.lower())
        self.assertIn("$key='openwebpbx-mail:'.$owned['queue']",php)
        self.assertIn("$key = 'openwebpbx-mail:'.$queue",(ROOT/'resources/classes/pbx_mail_dispatch.php').read_text())
    @unittest.skipUnless(shutil.which('lua'),'Local Lua-adapter control; actual native Dbh case remains required.')
    def test_actual_lua_entrypoint_with_explicit_owned_native_adapters(self):
        # Executes the shipped QA producer guards; database/module adapters are
        # explicit. Actual installed Windows Dbh remains a required CI case.
        harness=r'''
local path='C:/ProgramData/OpenWebPBX/native-qualification/'..string.rep('a',24)..'/delete-mail-44444444-4444-4444-4444-444444444444.private.json'
local f={tag='openweb-native-windows-voicemail-delete-v1',scope=string.rep('a',24),domain='11111111-1111-1111-1111-111111111111',mailbox='22222222-2222-2222-2222-222222222222',message='33333333-3333-3333-3333-333333333333',queue='44444444-4444-4444-4444-444444444444',attachment='55555555-5555-5555-5555-555555555555',realm='pbx-aaaaaaaaaaaa.native.invalid',hostname='owned-host',helper='C:/OpenWebPBX/scripts/resources/functions/voicemail_mail_queue.lua'}
f.service_name='Fictional Native '..f.scope
f.audio='C:/ProgramData/OpenWebPBX/storage/voicemail/default/'..f.realm..'/8103/msg_'..f.message..'.wav'
local db={}
function db:connected()return true end
function db:backend_name()return 'native' end
function db:first_row(sql,params)
 if sql:match('current_database')then assert(sql:find('host(inet_server_addr()) as address',1,true));return{name='fusionpbx',address='127.0.0.1',port='5433'}end
 assert(params==f and sql:match('v_voicemail_messages'))
 return{domain_name=f.realm,service_name=f.service_name,voicemail_id='8103',keep='false',voicemail_file='attach'}
end
function db:first_value(sql,params)assert(params.queue==f.queue and sql:match('v_email_queue'));return '0'end
local released,queued=false,false
function db:release()released=true end
package.preload['resources.functions.database']=function()return{new=function(which)assert(which=='system');return db end}end
package.preload['resources.functions.lunajson']=function()return{decode=function(raw)assert(raw=='OWNED');return f end,encode=function(out)assert(out.actual_native_dbh and out.installed_atomic_helper and queued and released);return 'QUEUED'end}end
package.preload['resources.functions.voicemail_mail_queue']=function()return{enqueue=function(actual,values,audio)assert(actual==db and values.queue==f.queue and values.attachment==f.attachment and values.domain==f.domain and values.message==f.message and values.after=='delete' and values.recipient=='sink@example.invalid' and audio==f.audio);queued=true;return f.queue end}end
package.searchpath=function(name)assert(name=='resources.functions.voicemail_mail_queue');return f.helper end
io.open=function(request,mode)assert(request==path and mode=='rb');return{read=function(_,limit)assert(limit==16385);return'OWNED'end,close=function()end}end
os.getenv=function(name)assert(name=='ProgramData');return'C:/ProgramData'end
freeswitch={getGlobalVariable=function(name)return({hostname=f.hostname,storage_dir='C:/Program Files/FreeSWITCH/storage'})[name]end}
stream={write=function(_,out)assert(out=='QUEUED');io.write('owned Lua guards PASS\n')end}
argv={path};package.config='\\\n/\n;\n?\n!\n-\n'
assert(loadfile(arg[1]))()
'''
        result=subprocess.run(['lua','-',str(ROOT/'tests/windows_voicemail_delete_producer.lua')],input=harness,text=True,capture_output=True,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,'owned Lua guards PASS\n')
        # Exact loopback/port/database and copied-WAV ownership remain strict.
        # The native engine's own storage root deliberately differs from the
        # supported installer's ProgramData PBX storage root in the baseline.
        for label,changed in [
            ('foreign_address',harness.replace("address='127.0.0.1'","address='127.0.0.2'")),
            ('ipv6_address',harness.replace("address='127.0.0.1'","address='::1'")),
            ('wrong_port',harness.replace("port='5433'","port='5432'")),
            ('wrong_database',harness.replace("name='fusionpbx'","name='foreign'")),
            ('engine_audio_root',harness.replace("f.audio='C:/ProgramData/OpenWebPBX/storage/voicemail/default/'","f.audio='C:/Program Files/FreeSWITCH/storage/voicemail/default/'")),
            ('foreign_mailbox_path',harness.replace("..'/8103/msg_'..f.message..'.wav'","..'/8104/msg_'..f.message..'.wav'")),
            ('wrong_copied_audio',harness.replace("..f.message..'.wav'","..f.queue..'.wav'")),
        ]:
            with self.subTest(refusal=label):
                self.assertNotEqual(changed,harness)
                rejected=subprocess.run(['lua','-',str(ROOT/'tests/windows_voicemail_delete_producer.lua')],input=changed,text=True,capture_output=True,timeout=5)
                self.assertNotEqual(rejected.returncode,0)
                self.assertEqual(rejected.stdout,'')


if __name__=='__main__':unittest.main()
