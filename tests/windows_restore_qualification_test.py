#!/usr/bin/env python3
"""Offline evidence/refusal controls, not a claim of Windows qualification."""
import copy
import ast
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import socket
import math
import struct
import subprocess
import tempfile
import time
import unittest
from unittest import mock
import wave
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('windows_restore_qualification', HERE / 'windows-restore-qualification.py')
q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)


class CleanupObservationControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.root = Path(self.temporary.name)
        self.fixture = q.Qualification.__new__(q.Qualification)
        self.fixture.work = self.root; self.fixture.source = self.root / 'source with spaces'
        self.fixture.path = self.root / 'input.json'; self.fixture.path.write_text('{"original":true}')
        self.fixture.refresh = mock.Mock()
        self.sidecar = Path(str(self.fixture.path) + '.cleanup.failure.json')
        self.record = dict(schema=1, action='cleanup', step='factory_guard', reason='factory_not_empty',
                           error_type='RuntimeException', source_basename='windows-restore-qualification.php', source_line=123)

    def tearDown(self): self.temporary.cleanup()

    def test_closed_fields_json_roundtrip_and_all_fixed_values(self):
        self.assertEqual(q.restore_fixture_failure_fields(json.loads(json.dumps(self.record)), 'cleanup'), self.record)
        for key, values in {
            'step': ('initialization','owned_lookup','gateway_guard','native_quiescence','native_contacts','backup_inventory',
                     'owned_rows_delete','update_commands_delete','backup_commands_delete','drafts_delete','archive_files_delete',
                     'cache_cleanup','native_reload','factory_guard','input_commit'),
            'reason': ('owned_service_lookup','enabled_gateway','active_calls','phone_identity','live_contact','missing_backup_command',
                       'backup_command_guard','backup_metadata_guard','backup_link','backup_integrity','original_command',
                       'command_ownership','backup_command_changed','original_draft','draft_ownership','archive_unlink',
                       'factory_not_empty','database_error','json_error','type_error','runtime_guard','external_error'),
            'error_type': ('RuntimeException','PDOException','JsonException','TypeError','ValueError','Error','Exception','external_error'),
            'source_basename': ('windows-restore-qualification.php','database.php','pbx_paths.php','cache.php','event_socket.php','config.php','external_component'),
        }.items():
            for value in values:
                with self.subTest(key=key,value=value):
                    self.assertEqual(q.restore_fixture_failure_fields(self.record | {key:value},'cleanup'),self.record | {key:value})

    def test_malformed_untrusted_private_fields_refused(self):
        bad = [None, [], {}, self.record | {'message':'PRIVATE SQL password path'},
               {k:v for k,v in self.record.items() if k!='step'}]
        for key in ('schema','action','step','reason','error_type','source_basename','source_line'):
            for value in (None, True, False, [], {}, 'PRIVATE SQL password C:/private', 1.5):
                bad.append(self.record | {key:value})
        bad.extend(self.record | {'source_line':value} for value in (-1,0,1000000,'123'))
        bad.extend(self.record | {'schema':value} for value in (0,2,'1'))
        for record in bad:
            with self.subTest(record=record):self.assertEqual(q.restore_fixture_failure_fields(record,'cleanup'),{})
        self.assertEqual(q.restore_fixture_failure_fields(self.record,'snapshot'),{})

    def delegate(self, output=None, action='cleanup', returncode=1):
        def child(arguments, **kwargs):
            self.assertEqual(arguments,['C:/OpenWebPBX/php/php.exe',str(self.fixture.source/'tests/windows-restore-qualification.php'),action,str(self.fixture.path)])
            self.assertEqual(kwargs,dict(cwd='C:/OpenWebPBX/web',stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120))
            if output:output()
            return subprocess.CompletedProcess(arguments,returncode,b'{"ordinary":true}',b'PRIVATE SQL password C:/private')
        with mock.patch.object(q.subprocess,'run',side_effect=child):
            if returncode:
                with self.assertRaisesRegex(RuntimeError,'^The private scoped PHP fixture failed[.]$') as caught:
                    self.fixture.php(action)
                self.fixture.refresh.assert_not_called()
                self.assertEqual((self.root/(action+'.private.err')).read_bytes(),b'PRIVATE SQL password C:/private')
                self.assertEqual((self.root/(action+'.private.out')).read_bytes(),b'{"ordinary":true}')
                self.assertEqual(self.fixture.path.read_text(),'{"original":true}')
                return caught.exception
            return self.fixture.php(action)

    def test_failed_real_delegate_consumes_only_fresh_closed_sidecar(self):
        error=self.delegate(lambda:self.sidecar.write_text(json.dumps(self.record)))
        self.assertEqual(error.fixture_failure,self.record)
        self.assertNotIn('PRIVATE',json.dumps(error.fixture_failure))

    def test_stale_missing_symlink_oversized_malformed_observation_cannot_mask_primary(self):
        for mode in ('stale','missing','symlink','oversized','malformed','duplicate','extra','foreign','directory'):
            with self.subTest(mode=mode):
                self.fixture.refresh.reset_mock()
                if self.sidecar.is_dir() and not self.sidecar.is_symlink():self.sidecar.rmdir()
                elif self.sidecar.exists() or self.sidecar.is_symlink():self.sidecar.unlink()
                if mode=='stale':self.sidecar.write_text(json.dumps(self.record))
                def write():
                    if mode=='symlink':self.sidecar.symlink_to(self.fixture.path)
                    elif mode=='oversized':self.sidecar.write_text(' '*2049)
                    elif mode=='malformed':self.sidecar.write_text('{')
                    elif mode=='duplicate':self.sidecar.write_text(json.dumps(self.record)[:-1]+',"schema":1}')
                    elif mode=='extra':self.sidecar.write_text(json.dumps(self.record | {'message':'PRIVATE'}))
                    elif mode=='foreign':self.sidecar.write_text(json.dumps(self.record | {'action':'snapshot'}))
                    elif mode=='directory':self.sidecar.mkdir()
                self.assertFalse(hasattr(self.delegate(write),'fixture_failure'))

    def test_observer_read_exception_and_wrong_action_never_replace_primary(self):
        with mock.patch.object(q,'read_json',side_effect=PermissionError('PRIVATE')):
            self.assertFalse(hasattr(self.delegate(lambda:self.sidecar.write_text(json.dumps(self.record))),'fixture_failure'))
        self.sidecar.unlink()
        self.assertFalse(hasattr(self.delegate(lambda:self.sidecar.write_text(json.dumps(self.record)),action='snapshot'),'fixture_failure'))

    def test_success_keeps_return_refresh_and_does_not_consume_failure(self):
        result=self.delegate(lambda:self.sidecar.write_text(json.dumps(self.record)),returncode=0)
        self.assertEqual(result,{'ordinary':True});self.fixture.refresh.assert_called_once_with()
        self.assertTrue(self.sidecar.exists())


class RestoreMailboxObservationControls(unittest.TestCase):
    def test_closed_boolean_observations_and_wrong_action_refusal(self):
        record={key:True for key in q.RESTORE_MAILBOX_FIELDS}
        self.assertEqual(len(record),8)
        self.assertEqual(q.restore_mailbox_failure_fields(record,'native-target'),record)
        for key in record:
            self.assertEqual(q.restore_mailbox_failure_fields({key:False},'native-target'),{key:False})
            for value in (None,0,1,'PRIVATE password/path',[],{},1.5):
                self.assertEqual(q.restore_mailbox_failure_fields(record|{key:value},'native-target'),{})
        for bad in (None,[],{},record|{'message':'PRIVATE'},record|{'mailbox_pin_sent':'true'}):
            self.assertEqual(q.restore_mailbox_failure_fields(bad,'native-target'),{})
        for action in ('native-source','cleanup','PRIVATE',None):
            self.assertEqual(q.restore_mailbox_failure_fields(record,action),{})


class RestoreAdapterControls(unittest.TestCase):
    """Real source receiver/UDP traffic with an injected OS error, no PBX."""
    @classmethod
    def setUpClass(cls):
        cls.native=q.load_module('restore_adapter_windows_controls',HERE/'windows-native-acceptance.py')
        cls.original=q.load_module('restore_adapter_source_controls',HERE/'pbx_v20_restore_native.py')

    def test_peers_installs_exact_existing_adapter_only_on_windows(self):
        class Base:
            def __init__(self,*args):self.arguments=args
            def media(self,pt=0):return {'socket':object(),'pt':pt}
        for platform in ('nt','posix'):
            with self.subTest(platform=platform),tempfile.TemporaryDirectory() as temporary:
                fixture=q.Qualification.__new__(q.Qualification);fixture.source=HERE.parent;fixture.work=Path(temporary)
                fixture.s={'realm':'fictional.invalid','users':[{},{}]};fixture.php=lambda _:dict(bind='127.0.0.1')
                original=SimpleNamespace(SourcePhone=Base);loaded=[]
                def load(name,path):
                    loaded.append((name,path))
                    return original if name=='restore_qualification_native' else (self.native if name=='restore_qualification_windows_peer' else SimpleNamespace())
                probe=mock.Mock()
                with mock.patch.object(q.os,'name',platform),mock.patch.object(q,'load_module',side_effect=load),mock.patch.object(q.socket,'socket',return_value=probe):
                    _,_,peers,destination=fixture.peers()
                    self.assertEqual(destination,('127.0.0.1',5060));probe.bind.assert_called_once_with(('127.0.0.1',0));probe.close.assert_called_once_with()
                    self.assertEqual(len(peers),2)
                    if platform=='nt':
                        self.assertIs(type(peers[0].media()['socket']),self.native.WindowsRtpSocket)
                        self.assertIsNone(peers[0].receiver_failure)
                    else:self.assertIs(type(peers[0]),Base)
                self.assertEqual(any(name=='restore_qualification_windows_peer' for name,_ in loaded),platform=='nt')

    def test_actual_receiver_survives_only_windows_10054_then_ack_and_two_way_udp(self):
        for code in (10054,10053):
            with self.subTest(code=code):
                error=ConnectionResetError('PRIVATE injected OS error');error.winerror=code;faults=[]
                class FaultOnce:
                    def __init__(self,sock):self.socket=sock;self.raised=False;faults.append(self)
                    def __getattr__(self,name):return getattr(self.socket,name)
                    def recv(self,*args):
                        if not self.raised:self.raised=True;raise error
                        return self.socket.recv(*args)
                adapter=lambda sock:self.native.WindowsRtpSocket(FaultOnce(sock))
                phone=q.windows_restore_phone(self.original.SourcePhone,adapter)({'number':'8101','auth':'owned-auth','password':'fictional'},'fictional.invalid')
                signal=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);signal.bind(('127.0.0.1',0));signal.settimeout(2)
                rtp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);rtp.bind(('127.0.0.1',0));rtp.settimeout(2)
                cid='a'*24+'@localfixture';tag='owned-tag';endpoint=phone.socket.getsockname()
                body=f'v=0\r\no=fixture 1 1 IN IP4 127.0.0.1\r\ns=owned\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio {rtp.getsockname()[1]} RTP/AVP 0 101\r\na=rtpmap:0 PCMU/8000\r\n'
                def packet(method,to,cseq,content=''):
                    return (f'{method} sip:8101@fictional.invalid SIP/2.0\r\nVia: SIP/2.0/UDP 127.0.0.1:{signal.getsockname()[1]};branch=z9hG4bK-owned\r\nFrom: <sip:8100@fictional.invalid>;tag={tag}\r\nTo: {to}\r\nCall-ID: {cid}\r\nCSeq: {cseq} {method}\r\nContact: <sip:8100@127.0.0.1:{signal.getsockname()[1]}>\r\nContent-Type: application/sdp\r\nContent-Length: {len(content)}\r\n\r\n'+content).encode()
                try:
                    with mock.patch.object(self.native.os,'name','nt'):
                        signal.sendto(packet('INVITE','<sip:8101@fictional.invalid>',1,body),endpoint)
                        answer=signal.recvfrom(65535)[0].decode();self.assertTrue(answer.startswith('SIP/2.0 200'))
                        end=time.monotonic()+2
                        while not (faults and faults[0].raised) and time.monotonic()<end:time.sleep(.005)
                        self.assertTrue(faults and faults[0].raised)
                        if code==10054:
                            signal.sendto(packet('ACK',self.original.headers(answer)['to'],1),endpoint)
                            end=time.monotonic()+2
                            while not phone.dialogs[cid].get('acked') and time.monotonic()<end:time.sleep(.005)
                            self.assertTrue(phone.dialogs[cid]['acked']);self.assertTrue(phone.thread.is_alive());self.assertIsNone(phone.receiver_failure)
                            state=phone.dialogs[cid]
                            for index in range(6):
                                rtp.sendto(struct.pack('!BBHII',0x80,0,index,index*160,91)+b'\xff'*160,state['socket'].getsockname())
                                self.assertGreaterEqual(len(rtp.recvfrom(4096)[0]),172);time.sleep(.02)
                            self.assertGreaterEqual(state['sent'],6);self.assertGreaterEqual(state['received'],5)
                            signal.sendto(packet('BYE',self.original.headers(answer)['to'],2),endpoint)
                            self.assertTrue(signal.recvfrom(65535)[0].startswith(b'SIP/2.0 200'))
                            end=time.monotonic()+2
                            while not state.get('ended') and time.monotonic()<end:time.sleep(.005)
                            self.assertTrue(state.get('ended'))
                        else:
                            phone.thread.join(2);self.assertFalse(phone.thread.is_alive());self.assertIs(phone.receiver_failure,error)
                            with self.assertRaises(ConnectionResetError) as caught:phone.register(endpoint)
                            self.assertIs(caught.exception,error)
                finally:phone.close();signal.close();rtp.close()

    def test_adapter_does_not_absorb_linux_or_other_socket_errors(self):
        for platform,code,kind in [('posix',10054,ConnectionResetError),('nt',10053,ConnectionResetError),('nt',10054,OSError)]:
            error=kind('PRIVATE');error.winerror=code;raw=SimpleNamespace(recv=mock.Mock(side_effect=error))
            with mock.patch.object(self.native.os,'name',platform),self.assertRaises(kind) as caught:self.native.WindowsRtpSocket(raw).recv(1)
            self.assertIs(caught.exception,error)


class NativeCleanupControls(unittest.TestCase):
    """Actual orchestration/cleanup source with controlled peers, not SIP acceptance."""
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.root=Path(self.temporary.name)
        self.fixture=q.Qualification.__new__(q.Qualification);self.fixture.work=self.root
        self.fixture.path=self.root/'input.json';self.fixture.facts_path=self.root/'facts.json'
        self.fixture.s={'realm':'fictional.invalid'};self.fixture.facts={'checks':[],'gates':{}}
        self.primary=None;self.mode='success';self.commands=[];self.status_calls=0
        owner=self
        class Peer:
            def __init__(self,index):
                self.index=index;self.auth_user='owned'+str(index);self.dialogs={};self.closed=False;self.unregisters=0;self.dials=0
                self.registration_call_ids=['a'*24+'@localfixture']
            def register(self,destination,expires=None):
                if expires==0:
                    self.unregisters+=1
                    if self.index==0 and owner.mode=='register_error':raise TimeoutError('PRIVATE password/path')
                    if self.index==0 and owner.mode=='status_error':return {'code':503}
                return {'code':200}
            def dial(self,number,destination):
                self.dials+=1
                if owner.mode=='voicemail_error' and self.dials==2:raise RuntimeError('PRIVATE deposit/password')
                owner.peers[1].dialogs['fictional']={'acked':owner.mode!='ack_missing'}
                return {'code':200,'media':{}}
            def hangup(self,call):pass
            def close(self):
                self.closed=True
                if self.index==0 and owner.mode=='close_error':raise RuntimeError('PRIVATE close/password')
        self.peers=[Peer(0),Peer(1)]
        def rate(_):
            if self.primary is not None:raise self.primary
        self.fixture.peers=lambda:(SimpleNamespace(rtp_rate_check=rate),SimpleNamespace(decoded_tone_check=lambda *_:None),self.peers,('127.0.0.1',5060))
        def php(action):
            self.assertEqual(action,'status');self.status_calls+=1
            return {'recordings':[] if self.status_calls==1 or self.mode=='recording_missing' else [{'media_uuid':'fictional-answered','media':{'exists':True,'size':40001}}]}
        self.fixture.php=php
        def es_api(command):
            self.commands.append(command)
            if command.startswith('sofia_contact'):
                return 'PRIVATE contact/password' if self.mode=='contact_error' else 'error/user_not_registered'
            if self.mode=='flush_error':raise ConnectionError('PRIVATE socket/password')
            return '+OK'
        self.fixture.es_api=es_api

    def tearDown(self):self.temporary.cleanup()
    def run_native(self):
        with mock.patch.object(q.time,'sleep',return_value=None):return self.fixture.native()

    def test_primary_only_is_original_exception_and_cleanup_still_runs(self):
        self.primary=AssertionError('PRIVATE body/password')
        with self.assertRaises(AssertionError) as caught:self.run_native()
        self.assertIs(caught.exception,self.primary);self.assertEqual(caught.exception.completed_native_cases,[])
        self.assertFalse(hasattr(caught.exception,'peer_cleanup_failure'))
        self.assertTrue(all(peer.closed and peer.unregisters==1 for peer in self.peers))
        self.assertEqual(len([c for c in self.commands if c.startswith('sofia_contact')]),2)

    def test_cleanup_only_fails_and_retains_only_genuinely_completed_cases(self):
        self.mode='status_error'
        with self.assertRaisesRegex(RuntimeError,'^Owned peer cleanup is incomplete[.]$') as caught:self.run_native()
        fields=caught.exception.peer_cleanup_failure
        self.assertEqual(len(fields),1);self.assertEqual(fields[0]['stage'],'unregister')
        self.assertEqual(fields[0]['status_code'],503);self.assertEqual(fields[0]['peer_index'],0)
        self.assertEqual(fields[0]['error_type'],'check_failed')
        self.assertEqual(fields[0]['source_basename'],'windows-restore-qualification.py')
        self.assertEqual(caught.exception.completed_native_cases,list(q.NATIVE_CASES['native-source']))
        self.assertEqual(self.fixture.facts['checks'],list(q.NATIVE_CASES['native-source']))
        self.assertTrue(all(peer.closed for peer in self.peers))
        self.assertEqual(len([c for c in self.commands if c.startswith('sofia_contact')]),2)

    def test_both_failures_preserve_primary_and_closed_secondary(self):
        self.primary=AssertionError('PRIVATE primary/password');self.mode='status_error'
        with self.assertRaises(AssertionError) as caught:self.run_native()
        self.assertIs(caught.exception,self.primary)
        self.assertEqual(caught.exception.peer_cleanup_failure[0]['status_code'],503)
        self.assertEqual(caught.exception.completed_native_cases,[])
        self.assertNotIn('PRIVATE',json.dumps(caught.exception.peer_cleanup_failure))
        self.assertTrue(all(peer.closed for peer in self.peers))

    def test_success_preserves_checks_and_exact_contact_absence(self):
        self.assertIsNone(self.run_native())
        self.assertEqual(self.fixture.facts['gates'],{name:'passed' for name in q.NATIVE_CASES['native-source']})
        self.assertTrue(all(peer.closed for peer in self.peers))
        self.assertEqual(len([c for c in self.commands if c.startswith('sofia_contact')]),2)

    def test_only_completed_first_case_survives_later_body_failure(self):
        self.mode='voicemail_error'
        with self.assertRaises(RuntimeError) as caught:self.run_native()
        self.assertEqual(caught.exception.completed_native_cases,[q.NATIVE_CASES['native-source'][0]])
        self.assertEqual(self.fixture.facts['checks'],[q.NATIVE_CASES['native-source'][0]])
        self.assertTrue(all(peer.closed for peer in self.peers))

    def test_closed_substage_distinguishes_ack_and_recording_waits_without_deadline_change(self):
        for mode,stage in [('ack_missing','internal_ack'),('recording_missing','answered_recording')]:
            self.mode=mode;self.status_calls=0;self.fixture.facts={'checks':[],'gates':{}};self.peers[1].dialogs={}
            def wait(predicate,seconds=120):
                self.assertEqual(seconds,120)
                value=predicate()
                if not value:raise TimeoutError('PRIVATE wait')
                return value
            with mock.patch.object(q,'wait_for',side_effect=wait),self.assertRaises(TimeoutError) as caught:self.run_native()
            self.assertEqual(caught.exception.native_substage,stage);self.assertEqual(caught.exception.completed_native_cases,[])

    def test_unexpected_receiver_error_is_failure_and_closed_when_body_also_fails(self):
        for body_fails in (False,True):
            self.peers[1].dialogs={}
            error=ConnectionResetError('PRIVATE receiver');error.winerror=10053
            self.peers[1].receiver_failure=error
            if body_fails:self.primary=AssertionError('PRIVATE primary')
            with self.assertRaises(AssertionError if body_fails else ConnectionResetError) as caught:self.run_native()
            self.assertIs(caught.exception,self.primary if body_fails else error)
            records=caught.exception.peer_receiver_failure
            self.assertEqual(records[0]['peer_index'],1);self.assertEqual(records[0]['stage'],'receiver')
            self.assertEqual(records[0]['winerror_kind'],'other_winerror');self.assertNotIn('PRIVATE',json.dumps(records))
            self.assertEqual(caught.exception.native_substage,'internal_media' if body_fails else 'peer_receiver')
            self.assertTrue(all(peer.closed for peer in self.peers))
        row=q.peer_failure(0,'receiver',error=error)|{'winerror_kind':'connection_reset_10054'}
        self.assertEqual(q.restore_peer_failure_fields([row],receiver=True),[row])
        for records in ([row]*3,[row|{'winerror_kind':10054}],[row|{'winerror_kind':'PRIVATE'}],[row|{'message':'PRIVATE'}]):
            self.assertEqual(q.restore_peer_failure_fields(records,receiver=True),[])

    def test_actual_main_json_preserves_primary_and_keeps_secondary_and_progress_closed(self):
        self.primary=AssertionError('PRIVATE primary/password');self.mode='status_error'
        with self.assertRaises(AssertionError) as caught:self.run_native()
        final=ast.parse((HERE/'windows-restore-qualification.py').read_text()).body[-1]
        program=compile(ast.Module(body=[final],type_ignores=[]),str(HERE/'windows-restore-qualification.py'),'exec')
        error=caught.exception
        def fail():raise error
        namespace=q.__dict__.copy()|{'__name__':'__main__','main':fail};output=io.StringIO()
        with contextlib.redirect_stdout(output),self.assertRaises(SystemExit) as stopped:exec(program,namespace)
        self.assertEqual(stopped.exception.code,1);facts=json.loads(output.getvalue())
        self.assertEqual(facts['error_type'],'AssertionError');self.assertEqual(facts['completed_native_cases'],[])
        self.assertEqual(facts['peer_cleanup_failure'][0]['status_code'],503);self.assertNotIn('PRIVATE',output.getvalue())
        error.peer_cleanup_failure[0]['message']='PRIVATE';error.completed_native_cases=['PRIVATE'];error.native_substage='PRIVATE'
        output=io.StringIO()
        with contextlib.redirect_stdout(output),self.assertRaises(SystemExit):exec(program,namespace)
        facts=json.loads(output.getvalue())
        self.assertNotIn('peer_cleanup_failure',facts);self.assertNotIn('completed_native_cases',facts)
        self.assertNotIn('native_substage',facts)
        self.assertEqual(facts['error_type'],'AssertionError');self.assertNotIn('PRIVATE',output.getvalue())

    def test_contact_exception_close_and_foreign_id_fail_closed_without_private_data(self):
        for mode,stage,kind in [('contact_error','contact_absence','check_failed'),('register_error','unregister','TimeoutError'),
                                ('close_error','peer_close','RuntimeError'),('flush_error','flush_registration','ConnectionError'),
                                ('foreign_id','registration_ids','ValueError')]:
            with self.subTest(mode=mode):
                self.mode=mode
                if mode=='foreign_id':self.peers[0].registration_call_ids=['PRIVATE foreign/password']
                with self.assertRaises(RuntimeError) as caught:self.fixture.clean_peers(self.peers,('127.0.0.1',5060))
                fields=caught.exception.peer_cleanup_failure
                self.assertEqual(fields[0]['stage'],stage);self.assertEqual(fields[0]['error_type'],kind)
                self.assertNotIn('PRIVATE',json.dumps(fields));self.assertTrue(all(peer.closed for peer in self.peers))

    def test_peer_observation_shape_bounds_and_private_fields_refused(self):
        row=q.peer_failure(0,'unregister',503)
        self.assertEqual(q.restore_peer_failure_fields([row]),[row])
        self.assertEqual(len(q.restore_peer_failure_fields([row]*12)),12)
        for records in (None,{},[],[row]*13,[row|{'message':'PRIVATE'}],[row|{'source_basename':'C:/PRIVATE.py'}]):
            self.assertEqual(q.restore_peer_failure_fields(records),[])
        for key in row:
            for value in (None,True,False,[],{},'PRIVATE password/path',1.5):
                self.assertEqual(q.restore_peer_failure_fields([row|{key:value}]),[])
        for key,values in {'peer_index':(-1,2),'status_code':(-1,1,99,700),'source_line':(-1,1000000)}.items():
            for value in values:self.assertEqual(q.restore_peer_failure_fields([row|{key:value}]),[])
        error=type('PRIVATE_PasswordError',(Exception,),{})('PRIVATE message')
        self.assertEqual(q.peer_failure(0,'unregister',0,error)['error_type'],'external_error')
        facts={'checks':[q.NATIVE_CASES['native-source'][0],'PRIVATE'],'gates':{q.NATIVE_CASES['native-source'][0]:'passed',q.NATIVE_CASES['native-source'][1]:'passed','PRIVATE':'passed'}}
        self.assertEqual(q.completed_native_cases(facts,'native-source'),[q.NATIVE_CASES['native-source'][0]])
        facts['gates'][q.NATIVE_CASES['native-source'][0]]=True
        self.assertEqual(q.completed_native_cases(facts,'native-source'),[])
        names=list(q.NATIVE_CASES['native-source'])
        self.assertEqual(q.restore_completed_native_cases(names,'native-source'),names)
        for cases,action in ((names*2,'native-source'),([names[0],names[0]],'native-source'),(names,'native-target'),
                             (names,'cleanup'),(names,None),(names,[]),(['PRIVATE'],'native-source'),([True],'native-source')):
            self.assertIsNone(q.restore_completed_native_cases(cases,action))


class RestoreMailboxFlowControls(unittest.TestCase):
    """Actual restore body/helper; controlled endpoints, not Windows acceptance."""
    setUp=NativeCleanupControls.setUp
    tearDown=NativeCleanupControls.tearDown

    def run_target(self, mode='fresh', snapshot_error=False):
        native=q.load_module('restore_mailbox_helper_controls',HERE/'windows-native-acceptance.py')
        self.fixture.source=HERE.parent
        self.fixture.s.update(event_socket={'host':'127.0.0.1','port':1,'password':'PRIVATE'},users=[{}, {'voicemail_pin':'12'}])
        q.write_json(self.root/'source-capsule-private.json',{'payload':{'media':{'voicemail':{'relative':'voicemail/EXACT_SOURCE_MESSAGE.wav'}}}})
        self.digits=[];self.prompts=[];self.seen=set();self.observer_closed=False
        sip,original,peers,destination=self.fixture.peers()
        original.decoded_tone_check=mock.Mock();self.tones=original.decoded_tone_check
        self.fixture.peers=lambda:(sip,original,peers,destination)
        for peer in peers:
            old=peer.dial
            def dial(number,destination,old=old):return old(number,destination)|{'callid':'a'*24+'@localfixture'}
            peer.dial=dial;peer.dtmf=lambda call,digit:self.digits.append(digit)
        paths=['vm-enter_pass.wav']+(['vm-tutorial_yes_no.wav'] if mode!='existing' else [])+['vm-listen_new.wav','EXACT_SOURCE_MESSAGE.wav']
        if mode=='wrong_pin':paths=['vm-enter_pass.wav','vm-fail_auth.wav']
        if mode=='missing_menu':paths=['vm-enter_pass.wav','vm-tutorial_yes_no.wav']
        owner=self
        class Observer:
            def prompt(self,callid,suffixes,after=-1,seconds=30):
                owner.assertEqual(callid,'a'*24+'@localfixture');owner.assertGreater(seconds,0);owner.assertLessEqual(seconds,30)
                owner.prompts.append((list(suffixes),seconds))
                for index,path in enumerate(paths):
                    if index<=after:continue
                    owner.seen.add(path)
                    if any(path.endswith(suffix) for suffix in suffixes):return index,path
                raise AssertionError('PRIVATE prompt path/PIN must remain private')
            def snapshot(self,callid,recording):
                if snapshot_error:raise PermissionError('PRIVATE observer collection')
                return {'mailbox_prompt_password_seen':'vm-enter_pass.wav' in owner.seen,
                        'mailbox_prompt_tutorial_seen':'vm-tutorial_yes_no.wav' in owner.seen,
                        'mailbox_prompt_main_menu_seen':'vm-listen_new.wav' in owner.seen,
                        'mailbox_prompt_auth_failed_seen':'vm-fail_auth.wav' in owner.seen,
                        'mailbox_prompt_recording_seen':'EXACT_SOURCE_MESSAGE.wav' in owner.seen,
                        'mailbox_observer_failed':False,'PRIVATE_MESSAGE':'PRIVATE SIP/PIN/path'}
            def close(self):owner.observer_closed=True
        observer=Observer();helper=mock.Mock(wraps=native.mailbox_menu);self.helper=helper
        wrapped=SimpleNamespace(NativePlayback=mock.Mock(return_value=observer),mailbox_menu=helper)
        with mock.patch.object(q,'load_module',return_value=wrapped),mock.patch.object(q.time,'sleep',return_value=None):
            return self.fixture.native(True)

    def test_actual_restore_body_uses_proven_helper_for_fresh_and_existing_mailbox(self):
        for mode in ('fresh','existing'):
            with self.subTest(mode=mode):
                self.fixture.facts={'checks':[],'gates':{}};self.peers[1].dialogs={}
                self.run_target(mode)
                self.assertEqual(self.digits,list('12#21' if mode=='fresh' else '12#1'));self.helper.assert_called_once()
                self.assertEqual(self.prompts[-1][0],['EXACT_SOURCE_MESSAGE.wav'])
                self.assertEqual([call.args[1] for call in self.tones.call_args_list],[550,440,440])
                self.assertEqual(self.fixture.facts['checks'],list(q.NATIVE_CASES['native-target']))
                self.assertTrue(self.observer_closed);self.assertTrue(all(peer.closed for peer in self.peers))

    def test_real_helper_failure_keeps_precise_stage_observation_and_audio_only_progress(self):
        for mode,stage in [('wrong_pin','mailbox_main_prompt'),('missing_menu','mailbox_tutorial_complete')]:
            with self.subTest(mode=mode):
                self.fixture.facts={'checks':[],'gates':{}};self.peers[1].dialogs={}
                with self.assertRaises(AssertionError) as caught:self.run_target(mode)
                error=caught.exception
                self.assertEqual(error.native_substage,stage)
                self.assertEqual(error.completed_native_cases,[q.NATIVE_CASES['native-target'][0]])
                fields=error.mailbox_observation;self.assertEqual(len(fields),8)
                self.assertTrue(fields['mailbox_pin_sent']);self.assertEqual(fields['mailbox_tutorial_skip_sent'],mode=='missing_menu')
                self.assertFalse(fields['mailbox_prompt_main_menu_seen']);self.assertEqual(fields['mailbox_prompt_auth_failed_seen'],mode=='wrong_pin')
                self.assertNotIn('PRIVATE',json.dumps(fields));self.assertNotIn('EXACT_SOURCE_MESSAGE.wav',self.seen)
                self.assertTrue(self.observer_closed);self.assertTrue(all(peer.closed for peer in self.peers))
                self.assertEqual([call.args[1] for call in self.tones.call_args_list],[550,440])

    def test_observation_failure_cannot_mask_original_and_main_json_is_closed(self):
        with self.assertRaises(AssertionError) as caught:self.run_target('missing_menu',snapshot_error=True)
        error=caught.exception
        self.assertEqual(error.native_substage,'mailbox_tutorial_complete')
        self.assertEqual(error.mailbox_observation,{'mailbox_pin_sent':True,'mailbox_tutorial_skip_sent':True})
        final=ast.parse((HERE/'windows-restore-qualification.py').read_text()).body[-1]
        program=compile(ast.Module(body=[final],type_ignores=[]),'actual_restore_main','exec')
        def fail():raise error
        namespace=q.__dict__.copy()|{'__name__':'__main__','main':fail};output=io.StringIO()
        with contextlib.redirect_stdout(output),self.assertRaises(SystemExit):exec(program,namespace)
        self.assertEqual(json.loads(output.getvalue())['mailbox_observation'],error.mailbox_observation)
        self.assertNotIn('PRIVATE',output.getvalue())
        error.mailbox_observation['message']='PRIVATE';output=io.StringIO()
        with contextlib.redirect_stdout(output),self.assertRaises(SystemExit):exec(program,namespace)
        self.assertNotIn('mailbox_observation',json.loads(output.getvalue()));self.assertNotIn('PRIVATE',output.getvalue())


class Controls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.root = Path(self.temporary.name)
        self.secret = 'Fictional-only-A9!' + 'a' * 40; self.key = q.derive(self.secret, 'capsule')
        self.archive = self.root / 'fixture.owpbx'; self.archive.write_bytes(b'OWPBXB01' + bytes(range(128)))
        self.binding = {'run_id': '123', 'source_commit': 'a' * 40, 'candidate_sha256': 'b' * 64,
                        'scope': 'c' * 24, 'service_name': 'Fictional cccccccccccccccccccccccc', 'base_suite_run_id': '122'}
        self.payload = {'schema': 1, **self.binding, 'cipher_bytes': self.archive.stat().st_size,
                        'cipher_sha256': q.digest(self.archive)}

    def tearDown(self): self.temporary.cleanup()
    def envelope(self, payload=None): return q.seal_capsule(payload or self.payload, self.key)
    def open(self, envelope=None, binding=None):
        return q.open_capsule(envelope or self.envelope(), self.key, binding or self.binding, self.archive)

    def test_authenticated_exact_ciphertext(self): self.assertEqual(self.open(), self.payload)
    def export_fixture(self):
        # Exercise the actual exporter with a real Path/stat/copy/HMAC. Only
        # acquisition from Windows/PG/native peers is replaced by fictional data.
        fixture=q.Qualification.__new__(q.Qualification)
        fixture.work=self.root;fixture.facts_path=self.root/'facts.json'
        fixture.facts={'state':'running','checks':[],'gates':{}}
        fixture.s=self.binding | {'owned':{'domain_uuid':'fictional-owned'},'owned_job_uuid':'fictional-job',
            'owned_backup_commands':['fictional-backup'],'owned_scheduled_backup_commands':['fictional-schedule'],
            'owned_draft_ids':['fictional-draft'],'transfer_directory':str(self.root/'transfer'),'passphrase':self.secret}
        calls=[]
        def acquisition(name,value):
            calls.append(name);return value
        fixture.media=lambda:acquisition('media',{'recording':{'sha256':'c'*64}})
        fixture.backup_request=lambda:acquisition('backup',self.archive)
        fixture.snapshot=lambda label:acquisition(label,self.snapshot())
        fixture.identity=lambda:acquisition('identity',{'hosted_job_id':'12345','certificate_sha256':'d'*64})
        return fixture,calls

    def test_actual_exporter_real_path_size_copy_and_authenticated_capsule(self):
        fixture,calls=self.export_fixture();fixture.export_source()
        target=Path(fixture.s['transfer_directory']);transferred=target/'fixture.owpbx'
        self.assertEqual(calls,['media','backup','source','identity'])
        self.assertEqual({p.name for p in target.iterdir()},{'fixture.owpbx','capsule.json'})
        self.assertEqual(transferred.read_bytes(),self.archive.read_bytes())
        envelope=q.read_json(target/'capsule.json')
        actual=q.open_capsule(envelope,self.key,self.binding,transferred)
        self.assertIs(type(actual['cipher_bytes']),int)
        self.assertEqual(actual['cipher_bytes'],self.archive.stat().st_size)
        self.assertEqual(actual['cipher_sha256'],q.digest(self.archive))
        self.assertEqual(actual['owned_backup_commands'],fixture.s['owned_backup_commands'])
        self.assertEqual(actual['owned_scheduled_backup_commands'],fixture.s['owned_scheduled_backup_commands'])
        self.assertEqual(actual['owned_draft_ids'],fixture.s['owned_draft_ids'])
        self.assertEqual(actual['hosted_job_id'],'12345')
        self.assertNotIn(self.secret,(target/'capsule.json').read_text())
        facts=q.read_json(fixture.facts_path)
        self.assertEqual(facts['state'],'passed')
        self.assertEqual(facts['gates'],{'authenticated_ciphertext_only_distinct_job_transfer':'passed'})
        transferred.write_bytes(transferred.read_bytes()+b'changed')
        with self.assertRaises(ValueError):q.open_capsule(envelope,self.key,self.binding,transferred)

    def test_actual_exporter_missing_ciphertext_never_exports_or_passes(self):
        fixture,_=self.export_fixture();self.archive.unlink()
        with self.assertRaises(FileNotFoundError):fixture.export_source()
        self.assertFalse(Path(fixture.s['transfer_directory']).exists())
        self.assertEqual(fixture.facts,{'state':'running','checks':[],'gates':{}})
    def test_canonical_object_order(self):
        self.assertEqual(q.canonical({'b': 2, 'a': [1, True]}), q.canonical({'a': [1, True], 'b': 2}))
    def test_shared_key_labels_independent(self):
        self.assertNotEqual(q.derive(self.secret, 'audit'), self.key)
        self.assertNotEqual(q.derive(self.secret, 'administrator/source/x'), q.derive(self.secret, 'administrator/target/x'))
    def test_short_passphrase_refused(self):
        with self.assertRaises(ValueError): q.derive('short', 'capsule')
    def test_capsule_hmac_corruption_refused(self):
        envelope = self.envelope(); envelope['mac'] = '0' * 64
        with self.assertRaises(ValueError): self.open(envelope)
    def test_authenticated_other_run_refused(self):
        envelope = self.envelope(self.payload | {'run_id': '124'})
        with self.assertRaises(ValueError): self.open(envelope)
    def test_authenticated_other_package_refused(self):
        envelope = self.envelope(self.payload | {'candidate_sha256': 'd' * 64})
        with self.assertRaises(ValueError): self.open(envelope)
    def test_other_source_binding_refused(self):
        with self.assertRaises(ValueError): self.open(binding=self.binding | {'source_commit': 'd' * 40})
    def test_unexpected_envelope_field_refused(self):
        with self.assertRaises(ValueError): self.open(self.envelope() | {'logs': []})
    def test_nested_plaintext_secret_field_refused(self):
        for secret in ('password', 'passphrase', 'private_key', 'event_socket', 'users', 'admin_password', 'logs'):
            with self.subTest(secret=secret), self.assertRaises(ValueError):
                self.open(self.envelope(self.payload | {'nested': [{'nested': {secret: 'private'}}]}))
    def test_complete_cipher_corruption_refused(self):
        envelope = self.envelope(); self.archive.write_bytes(self.archive.read_bytes()[:-1] + b'x')
        with self.assertRaises(ValueError): self.open(envelope)
    def test_plaintext_archive_refused_even_authenticated(self):
        self.archive.write_bytes(b'NOTCRYPT' + b'x' * 128)
        payload = self.payload | {'cipher_sha256': q.digest(self.archive)}
        with self.assertRaises(ValueError): self.open(self.envelope(payload))
    def test_duplicate_evidence_keys_refused(self):
        path = self.root / 'data.json'; path.write_text('{"schema":1,"schema":2}')
        with self.assertRaises(ValueError): q.read_json(path)
    def test_bounded_evidence_and_nan_refused(self):
        path = self.root / 'data.json'; path.write_text('{"x":NaN}')
        with self.assertRaises(ValueError): q.read_json(path)
        path.write_text(' ' * 40)
        with self.assertRaises(ValueError): q.read_json(path, 16)
    def test_linked_cipher_refused(self):
        original = self.archive.with_suffix('.original'); self.archive.rename(original)
        try: self.archive.symlink_to(original)
        except OSError: self.skipTest('Symlink creation unavailable.')
        with self.assertRaises(ValueError): self.open()

    def identities(self):
        source = {'target_owned': {'cluster': 'a', 'database_credentials': 'b'}, 'machine_sid_hmac': 'c',
                  'certificate_sha256': 'd', 'template_key_sha256': 'e','hardware_uuid_hmac':'source-hardware',
                  'hostname_hmac':'source-host','runner_name_hmac':'source-runner','hosted_job_id':'12345'}
        target = {'target_owned': {'cluster': 'f', 'database_credentials': 'g'}, 'machine_sid_hmac': 'h',
                  'certificate_sha256': 'i', 'template_key_sha256': 'j','hardware_uuid_hmac':'target-hardware',
                  'hostname_hmac':'target-host','runner_name_hmac':'target-runner','hosted_job_id':'12346'}
        return source, target
    def test_different_machine_and_cluster_accepted(self): q.distinct_installations(*self.identities())
    def test_same_db_or_credentials_refused(self):
        for key in ('cluster', 'database_credentials'):
            source, target = self.identities(); target['hostname_hmac']=source['hostname_hmac']; target['target_owned'][key] = source['target_owned'][key]
            with self.subTest(key=key), self.assertRaises(ValueError): q.distinct_installations(source, target)
    def test_same_machine_or_private_material_refused(self):
        for key in ('hardware_uuid_hmac','certificate_sha256', 'template_key_sha256'):
            source, target = self.identities(); target['hostname_hmac']=source['hostname_hmac']; target[key] = source[key]
            with self.subTest(key=key), self.assertRaises(ValueError) as caught: q.distinct_installations(source, target)
            self.assertEqual(q.restore_identity_failure_fields(caught.exception),
                             {'failure_kind':'non_distinct_installation_identity','identity_field':key})

    def test_identity_observation_refuses_arbitrary_types_values_and_private_messages(self):
        for kind in (ValueError,RuntimeError,type('FictionalValueError',(ValueError,),{})):
            for field in ('PRIVATE C:/secret password',True,None,[],{},'HARDWARE_UUID_HMAC'):
                error=kind('PRIVATE SQL/password C:/secret');error.failure_kind='non_distinct_installation_identity';error.identity_field=field
                self.assertEqual(q.restore_identity_failure_fields(error),{})
        error=ValueError('PRIVATE SQL/password C:/secret');error.identity_field='hostname_hmac'
        for kind in (None,True,[],{},'PRIVATE','NON_DISTINCT_INSTALLATION_IDENTITY'):
            error.failure_kind=kind;self.assertEqual(q.restore_identity_failure_fields(error),{})
        error.failure_kind='non_distinct_installation_identity'
        self.assertEqual(q.restore_identity_failure_fields(error),{'failure_kind':error.failure_kind,'identity_field':'hostname_hmac'})
        self.assertNotIn('PRIVATE',json.dumps(q.restore_identity_failure_fields(error)))

    def test_actual_main_failure_json_preserves_error_source_and_projects_only_fixed_identity(self):
        source,target=self.identities();target['hardware_uuid_hmac']=source['hardware_uuid_hmac']
        try:q.distinct_installations(source,target)
        except ValueError as error:actual=error
        actual.private='PRIVATE SQL/password C:/secret'
        final=ast.parse((HERE/'windows-restore-qualification.py').read_text()).body[-1]
        program=compile(ast.Module(body=[final],type_ignores=[]),str(HERE/'windows-restore-qualification.py'),'exec')
        def fail():raise actual
        namespace=q.__dict__.copy() | {'__name__':'__main__','main':fail}
        output=io.StringIO()
        with contextlib.redirect_stdout(output),self.assertRaises(SystemExit) as stopped:exec(program,namespace)
        self.assertEqual(stopped.exception.code,1)
        facts=json.loads(output.getvalue())
        self.assertEqual(facts['state'],'failed');self.assertEqual(facts['error_type'],'ValueError')
        self.assertEqual(facts['source_basename'],'windows-restore-qualification.py')
        self.assertGreater(facts['source_line'],0);self.assertEqual(facts['active_case'],'restore_qualification')
        self.assertEqual(facts['failure_kind'],'non_distinct_installation_identity');self.assertEqual(facts['identity_field'],'hardware_uuid_hmac')
        self.assertEqual(set(facts),{'state','error_type','active_case','source_basename','source_line','failure_kind','identity_field'})
        self.assertNotIn('PRIVATE',output.getvalue());self.assertNotIn(source['hardware_uuid_hmac'],output.getvalue())
        namespace['main']=lambda:None;output=io.StringIO()
        with contextlib.redirect_stdout(output):exec(program,namespace)
        self.assertEqual(output.getvalue(),'')

    def test_pg_and_hosted_job_refusals_do_not_claim_an_identity_field(self):
        for key in ('cluster','database_credentials','hosted_job_id'):
            source,target=self.identities()
            if key=='hosted_job_id':target[key]=source[key]
            else:target['target_owned'][key]=source['target_owned'][key]
            with self.assertRaises(ValueError) as caught:q.distinct_installations(source,target)
            self.assertEqual(q.restore_identity_failure_fields(caught.exception),{})

    def test_same_image_sid_with_distinct_actual_vm_and_jobs_accepted(self):
        source,target=self.identities();target['machine_sid_hmac']=source['machine_sid_hmac']
        q.distinct_installations(source,target)
    def test_reused_hostname_and_image_sid_with_distinct_hardware_jobs_and_private_state_accepted(self):
        source,target=self.identities()
        for key in ('hostname_hmac','machine_sid_hmac'):target[key]=source[key]
        q.distinct_installations(source,target)
    def test_same_hardware_or_reforged_hosted_job_refused(self):
        for key in ('hardware_uuid_hmac','hosted_job_id'):
            source,target=self.identities();target['hostname_hmac']=source['hostname_hmac'];target[key]=source[key]
            with self.subTest(key=key),self.assertRaises(ValueError):q.distinct_installations(source,target)
        payload=self.payload|{'hosted_job_id':'12346'}
        with self.assertRaises(ValueError):self.open(self.envelope(payload),self.binding|{'hosted_job_id':'12345'})
    def test_actual_target_sid_and_machine_evidence_preserved(self):
        _,target=self.identities();q.preserve_machine_identity(target,copy.deepcopy(target))
        for key in ('machine_sid_hmac','hardware_uuid_hmac','hostname_hmac','runner_name_hmac','hosted_job_id'):
            altered=copy.deepcopy(target);altered[key]='changed'
            with self.subTest(key=key),self.assertRaises(ValueError):q.preserve_machine_identity(altered,target)

    def restored_identity_fixture(self):
        # Execute the complete actual restore orchestration with controlled
        # external boundaries; these controls do not restore a PBX or authenticate jobs.
        source,target=self.identities();target['hostname_hmac']=source['hostname_hmac']
        source['notification_sha256']='source-notification'
        snapshot=self.snapshot();payload=source|{'source_snapshot':copy.deepcopy(snapshot),'owned':{},'owned_job_uuid':'owned-job',
            'owned_backup_commands':[],'owned_draft_ids':[],'owned_scheduled_backup_commands':[],'media':{}}
        media=self.root/'storage/voicemail/message.wav';media.parent.mkdir(parents=True,exist_ok=True);media.write_bytes(b'owned original native bytes')
        payload['media']['voicemail']={'relative':'voicemail/message.wav','sha256':q.digest(media),'bytes':media.stat().st_size}
        fixture=q.Qualification.__new__(q.Qualification);fixture.work=self.root;fixture.s={'passphrase':self.secret}
        fixture.settings={'database.0.name':'fictional'};fixture.target_source=lambda:(payload,self.archive)
        fixture.backups=SimpleNamespace(STATE=self.root,HELD_UNITS=('calls','jobs','updates','backups'),held=lambda _:True)
        fixture.cli=mock.Mock();fixture.save=mock.Mock();fixture.web=mock.Mock();fixture.record=mock.Mock()
        fixture.php=lambda action:{'state':'waiting','attempts':0} if action=='seed-job' else {}
        fixture.snapshot=lambda _:copy.deepcopy(snapshot)
        fixture.observed_identity=target|{'template_key_sha256':source['template_key_sha256'],'notification_sha256':source['notification_sha256']}
        def identity():
            q.preserve_machine_identity(fixture.observed_identity,target)
            return copy.deepcopy(fixture.observed_identity)
        fixture.identity=identity
        q.write_json(self.root/'target-before-database.json',snapshot)
        q.write_json(self.root/'phone-tls.json',{'RestorePending':True})
        return fixture,payload,media

    def test_actual_restore_accepts_reused_hostname_and_preserves_target_with_source_private_state(self):
        fixture,payload,media=self.restored_identity_fixture();fixture.restore()
        fixture.cli.assert_called_once_with(['restore',str(self.archive),'--confirm-database','fictional'],password=self.secret)
        fixture.web.assert_called_once_with(True)
        fixture.record.assert_called_once_with('supported_private_cli_clean_server_restore_target_identity_all_holds_admin_https')
        self.assertEqual(fixture.observed_identity['hostname_hmac'],payload['hostname_hmac'])
        self.assertEqual(q.digest(media),payload['media']['voicemail']['sha256'])

    def test_actual_restore_still_refuses_adopted_machine_changed_target_or_wrong_private_state(self):
        for key in ('certificate_sha256','hardware_uuid_hmac','hosted_job_id','machine_sid_hmac','hostname_hmac','runner_name_hmac',
                    'template_key_sha256','notification_sha256'):
            fixture,payload,_=self.restored_identity_fixture()
            fixture.observed_identity[key]=payload[key] if key in ('certificate_sha256','hardware_uuid_hmac','hosted_job_id') else 'changed'
            with self.subTest(key=key),self.assertRaises((ValueError,RuntimeError)):fixture.restore()
            fixture.web.assert_not_called();fixture.record.assert_not_called()

    def test_actual_restore_still_refuses_missing_holds_and_changed_native_media(self):
        for fault in ('hold','media'):
            fixture,_,media=self.restored_identity_fixture()
            if fault=='hold':fixture.backups.held=lambda selection:selection!='calls'
            else:media.write_bytes(b'changed owned bytes')
            with self.subTest(fault=fault),self.assertRaises(RuntimeError):fixture.restore()
            fixture.web.assert_not_called();fixture.record.assert_not_called()

    def snapshot(self):
        tables = {'v_extensions': {'rows': 2, 'hmac': 'exact-credentials'}, 'v_pbx_jobs': {'rows': 1, 'hmac': 'future'},
                  'v_pbx_backup_status': {'rows': 1, 'hmac': 'heartbeat'}}
        return {'target_owned': {'cluster': 'exact'}, 'schema_metadata': {'columns': 'exact-defaults'},
                'all_table_values': tables, 'scoped_values': copy.deepcopy(tables),
                'restore_projections': {table:{'rows':0,'hmac':'exact'} for table in q.RESTORE_TRANSFORMED_TABLES},
                'source_phone_tuples': 'actual-native-tuples'}
    def test_exact_factory_and_restored_snapshots(self):
        before = self.snapshot(); q.compare_snapshots(before, copy.deepcopy(before), 'factory-recovery')
        after = copy.deepcopy(before); after['target_owned']['cluster'] = 'different-target'
        q.compare_snapshots(before, after, 'source-restored')
    def test_exact_schema_failure_reports_only_closed_label_and_three_actual_group_differences(self):
        for label in ('target-wrongpass','target-recovered','target-restored'):
            for mask in range(1,8):
                before=self.snapshot();before['schema_metadata']={name:'original' for name in ('schema','tables','columns')}
                after=copy.deepcopy(before);after['label']=label
                expected={name:bool(mask&(1<<index)) for index,name in enumerate(('schema','tables','columns'))}
                for name,changed in expected.items():
                    if changed:after['schema_metadata'][name]='PRIVATE raw SQL/schema/owner'
                with self.assertRaises(ValueError) as caught:q.compare_snapshots(before,after,'factory-recovery')
                self.assertEqual(q.restore_schema_failure_fields(caught.exception),{'comparison_label':label,'schema_groups_differ':expected})
                self.assertNotIn('PRIVATE',json.dumps(q.restore_schema_failure_fields(caught.exception)))
        for label in (None,True,[],{},'PRIVATE','TARGET-RECOVERED'):
            error=ValueError('PRIVATE');error.comparison_label=label;error.schema_groups_differ={'schema':True,'tables':False,'columns':False}
            self.assertEqual(q.restore_schema_failure_fields(error),{})
        for groups in (None,[],{}, {'schema':1,'tables':False,'columns':False},
                       {'schema':True,'tables':False,'columns':False,'message':'PRIVATE'},
                       {'schema':False,'tables':False,'columns':False}):
            error=ValueError('PRIVATE');error.comparison_label='target-recovered';error.schema_groups_differ=groups
            self.assertEqual(q.restore_schema_failure_fields(error),{})
    def test_operational_heartbeat_only_allowed(self):
        before = self.snapshot(); after = copy.deepcopy(before)
        after['all_table_values']['v_pbx_backup_status']['hmac'] = 'new-heartbeat'
        q.compare_snapshots(before, after, 'factory-recovery')
    def test_credential_job_or_schema_changes_refused(self):
        for key in ('v_extensions', 'v_pbx_jobs'):
            before = self.snapshot(); after = copy.deepcopy(before)
            after['all_table_values'][key]['hmac'] = 'changed'
            with self.subTest(key=key), self.assertRaises(ValueError): q.compare_snapshots(before, after, 'source-restored')
        before = self.snapshot(); after = copy.deepcopy(before); after['schema_metadata']['columns'] = 'changed'
        with self.assertRaises(ValueError): q.compare_snapshots(before, after, 'factory-recovery')
    def test_factory_identity_and_actual_phone_changes_refused(self):
        before = self.snapshot(); after = copy.deepcopy(before); after['target_owned']['cluster'] = 'changed'
        with self.assertRaises(ValueError): q.compare_snapshots(before, after, 'factory-recovery')
        after = copy.deepcopy(before); after['source_phone_tuples'] = 'changed'
        with self.assertRaises(ValueError): q.compare_snapshots(before, after, 'source-restored')

    def test_unscoped_smtp_profiles_defaults_admin_memberships_refused(self):
        for table in ('v_smtp_settings','v_default_settings','v_sip_profile_settings','v_user_groups'):
            before=self.snapshot();before['all_table_values'][table]={'rows':1,'hmac':'original-global'}
            after=copy.deepcopy(before);after['all_table_values'][table]['hmac']='changed-global'
            with self.subTest(table=table),self.assertRaises(ValueError):q.compare_snapshots(before,after,'source-restored')

    def test_factory_backup_settings_secret_changes_refused(self):
        before=self.snapshot();before['all_table_values']['v_pbx_backup_settings']={'rows':1,'hmac':'original-secret-settings'}
        after=copy.deepcopy(before);after['all_table_values']['v_pbx_backup_settings']['hmac']='changed-password'
        with self.assertRaises(ValueError):q.compare_snapshots(before,after,'factory-recovery')

    def test_restore_only_explicit_lifecycle_fields_may_change(self):
        before=self.snapshot();before['all_table_values']['v_pbx_backup_settings']={'rows':1,'hmac':'enabled-source'}
        after=copy.deepcopy(before);after['all_table_values']['v_pbx_backup_settings']['hmac']='disabled-target'
        q.compare_snapshots(before,after,'source-restored')
        for table in q.RESTORE_TRANSFORMED_TABLES:
            changed=copy.deepcopy(after);changed['restore_projections'][table]['hmac']='changed-secret-or-identity'
            with self.subTest(table=table),self.assertRaises(ValueError):q.compare_snapshots(before,changed,'source-restored')

    def test_real_cli_adapter_keeps_password_out_of_arguments_and_restores_prompt(self):
        fixture=q.Qualification.__new__(q.Qualification);fixture.work=self.root;fixture.facts={}
        old_prompt=lambda _: 'untouched';prompt=SimpleNamespace(getpass=old_prompt);observed={}
        def main():
            observed['args']=q.sys.argv[:];observed['passphrase']=prompt.getpass('Original backup password: ')
        fixture.backups=SimpleNamespace(getpass=prompt,main=main)
        before=q.sys.argv
        fixture.cli(['restore','fixture.owpbx','--confirm-database','fusionpbx'],password=self.secret)
        self.assertNotIn(self.secret,observed['args']);self.assertEqual(observed['passphrase'],self.secret)
        self.assertIs(q.sys.argv,before);self.assertIs(prompt.getpass,old_prompt)
        self.assertEqual(fixture.facts['actual_console_keyboard_input'],'unqualified')

    def test_late_fault_actual_three_copies_then_recovery_continues(self):
        targets = {'key': self.root / 'openweb-template.key', 'notification': self.root / 'notification.json',
                   'media': self.root / 'media/source.wav'}; targets['media'].parent.mkdir()
        sources = {}
        for key in targets:
            source = self.root / (key + '.source'); source.write_bytes(('real ' + key).encode()); sources[key] = source
        witness = {}; copy_file = q.late_copy_fault(shutil.copyfile, targets['key'], targets['notification'],
                                                   [targets['media'].parent], witness)
        copy_file(sources['key'], targets['key']); self.assertFalse(witness['injected'])
        copy_file(sources['notification'], targets['notification']); self.assertFalse(witness['injected'])
        with self.assertRaises(RuntimeError): copy_file(sources['media'], targets['media'])
        self.assertTrue(witness['injected']); self.assertEqual(witness['categories'], ['key', 'media', 'notification'])
        self.assertEqual(targets['media'].read_bytes(), sources['media'].read_bytes())
        recovered = self.root / 'recovered.source'; recovered.write_bytes(b'original factory')
        copy_file(recovered, targets['key']); self.assertEqual(targets['key'].read_bytes(), b'original factory')
    def test_first_or_incomplete_categories_never_qualify_late(self):
        key = self.root / 'key'; notification = self.root / 'noti'; media = self.root / 'media'; media.mkdir()
        source = self.root / 'source'; source.write_bytes(b'real')
        witness = {}; copy_file = q.late_copy_fault(shutil.copyfile, key, notification, [media], witness)
        for target in (key, key, self.root / 'unrelated', notification): copy_file(source, target)
        self.assertFalse(witness['injected']); self.assertNotIn('media', witness['categories'])
    def test_copy_failure_is_not_false_success(self):
        witness = {}
        def broken(source, target): raise OSError('actual copy failed')
        copy_file = q.late_copy_fault(broken, self.root/'key', self.root/'noti', [self.root/'media'], witness)
        with self.assertRaises(OSError): copy_file(self.root/'missing', self.root/'key')
        self.assertEqual(witness['copied'], []); self.assertFalse(witness['injected'])

    def test_late_exact_native_media_neighbours_do_not_satisfy_witness(self):
        key, noti = self.root/'key', self.root/'noti'; media = self.root/'media'; media.mkdir()
        selected, neighbour = media/'answered.wav', media/'deposit.wav'
        source = self.root/'source'; source.write_bytes(b'complete actual native fixture')
        witness = {}; copy_file = q.late_copy_fault(shutil.copyfile, key, noti, [media], witness, media_paths=[selected])
        for target in (key, noti, neighbour): copy_file(source, target)
        self.assertFalse(witness['injected']); self.assertEqual(witness['categories'], ['key', 'notification'])
        with self.assertRaises(RuntimeError): copy_file(source, selected)
        self.assertTrue(witness['injected']); self.assertEqual(selected.read_bytes(), source.read_bytes())

    def test_media_selects_captured_answered_uuid_not_deposit_uuid_order(self):
        storage = self.root/'storage'; storage.mkdir()
        def wav_file(name, frequencies):
            path = storage/name; raw = bytearray()
            for i in range(8000*5):
                for frequency in frequencies: raw.extend(struct.pack('<h', int(12000*math.sin(2*math.pi*frequency*i/8000))))
            with wave.open(str(path), 'wb') as stream:
                stream.setparams((len(frequencies), 2, 8000, 0, 'NONE', 'not compressed')); stream.writeframes(raw)
            return {'exists': True, 'path': str(path), 'size': path.stat().st_size, 'sha256': q.digest(path)}
        vm = wav_file('message.wav', [440]); answered = wav_file('answered.wav', [440, 550]); deposit = wav_file('deposit.wav', [440, 220])
        fixture = q.Qualification.__new__(q.Qualification); fixture.s = {'answered_recording_uuid': 'ffff'}; fixture.work = self.root
        fixture.php = lambda action: {'voicemail': [{'voicemail_id': '8101', 'media': vm}],
            'recordings': [{'media_uuid': 'aaaa', 'media': deposit}, {'media_uuid': 'ffff', 'media': answered}]}
        fixture.record = lambda _: None
        actual_path = Path
        with mock.patch.object(q, 'Path', side_effect=lambda value: storage if str(value) == 'C:/ProgramData/OpenWebPBX/storage' else actual_path(value)):
            result = fixture.media()
        self.assertEqual(result['recording']['relative'], 'answered.wav')
        self.assertGreater(min(result['recording']['decoded_ratios']), .99)

    def test_workflow_distinct_jobs_cipher_only_and_no_reboot(self):
        workflow = (HERE.parent / '.github/workflows/windows-restore-qualification.yml').read_text()
        self.assertEqual(workflow.count('runs-on: windows-2025'), 2)
        self.assertIn('needs: source', workflow); self.assertIn('/fixture.owpbx', workflow); self.assertIn('/capsule.json', workflow)
        self.assertNotIn('windows113/', workflow); self.assertNotIn('SIGNING', workflow)
        self.assertNotIn('Restart-Computer', (HERE/'windows-restore-qualification.ps1').read_text())


if __name__ == '__main__': unittest.main()
