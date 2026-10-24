#!/usr/bin/env python3
"""Portable controls. HTTP, SIP peers and live observation are explicit adapters.
These controls do not qualify IIS, Windows, packet transport or physical phones.
"""
import copy
import hashlib
import importlib.util
import io
import json
import math
import os
import struct
import tempfile
import types
import unittest
import urllib.error
from email.parser import BytesParser
from email.policy import default
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
def load(name, path):
    import sys
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module
    spec.loader.exec_module(module); return module

subject = load('threecx_https_subject', HERE/'windows_threecx_https_native.py')
native = load('threecx_https_native_control', HERE/'windows-native-acceptance.py')
sip = load('sip_trunk_live', HERE/'sip_trunk_live.py')
original = load('threecx_https_original_control', HERE/'pbx_v20_restore_native.py')


class MultipartControls(unittest.TestCase):
    def test_actual_mime_file_and_fields(self):
        raw = b'PK\x03\x04\x00\xff\r\nbody'; fields = {'action':'analyze_import','a'*64:'b'*64}
        body, content_type = subject.multipart(fields, raw)
        message = BytesParser(policy=default).parsebytes(('Content-Type: '+content_type+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+body)
        parts = list(message.iter_parts()); self.assertEqual(len(parts), 3)
        for part, (name,value) in zip(parts, fields.items()):
            self.assertEqual(part.get_param('name', header='content-disposition'), name)
            self.assertEqual(part.get_payload(decode=True), value.encode())
        self.assertEqual(parts[-1].get_param('name', header='content-disposition'), 'backup')
        self.assertEqual(parts[-1].get_filename(), 'synthetic V20.zip')
        self.assertEqual(parts[-1].get_content_type(), 'application/zip')
        self.assertEqual(parts[-1].get_payload(decode=True), raw)

    def test_refuse_nonfictional_bounds_and_header_injection(self):
        for archive in (b'', b'xml', b'PK'+b'x'*1048576, 'PK'):
            with self.subTest(archive_type=type(archive).__name__), self.assertRaises(AssertionError):
                subject.multipart({'action':'analyze_import'}, archive)
        for fields in ({'bad\r\nname':'x'}, {'a':'x'*4097}, {'a':1}, {'a"':'x'}):
            with self.subTest(fields=list(fields)), self.assertRaises(AssertionError): subject.multipart(fields,b'PK')

    def test_exact_origin_and_scheme(self):
        web = object.__new__(subject.ImportWeb); web.base='https://windowsqa.example.invalid:8443'
        self.assertEqual(web.url('/app/'), web.base+'/app/')
        for bad in ('http://windowsqa.example.invalid:8443/a','https://foreign.invalid/a','//foreign.invalid/a',
                    'https://user@windowsqa.example.invalid:8443/a','https://windowsqa.example.invalid/a'):
            with self.subTest(path=bad), self.assertRaises(AssertionError):web.url(bad)

    def test_response_bounds_and_error_status(self):
        web = object.__new__(subject.ImportWeb); web.base='https://windowsqa.example.invalid:8443'
        class Response(io.BytesIO):
            status=200
            def geturl(self):return web.base+'/app/'
        class Open:
            def open(self, request, timeout):
                self.request=request; self.timeout=timeout
                return Response(self.body)
        web.open=Open();web.open.body=b'allowed'
        self.assertEqual(web.request('/app/')[2], 'allowed');self.assertEqual(web.open.timeout,25)
        web.open.body=b'x'*(subject.MAX_BODY+1)
        with self.assertRaises(AssertionError):web.request('/app/')
        web.open.open=lambda request,timeout: (_ for _ in ()).throw(urllib.error.HTTPError(web.base+'/app/',403,'forbidden',{},io.BytesIO(b'no')))
        self.assertEqual(web.request('/app/')[0],403)

    def test_form_uniqueness(self):
        form='<form><input name="action" value="analyze_import"></form>'
        self.assertEqual(subject.selected_form(native,form,'analyze_import')['fields']['action'],'analyze_import')
        for value in ('',form+form):
            with self.assertRaises(AssertionError):subject.selected_form(native,value,'analyze_import')


class Fixture:
    def __init__(self, root):
        self.evidence=root;self.source=HERE.parent;self.checks=[];self.commands=[]
        archive=root/'synthetic V20.zip';archive.write_bytes(b'PK\x03\x04fictional-local-adapter')
        self.s={'scope':'a'*24,'threecx_import_only':True,'native_diagnostics_only':True,
            'public_url':'https://windowsqa.example.invalid:8443','admin_email':'fixture@example.invalid',
            'admin_password':'fictional-admin','company_name':'Fictional','service_name':'Synthetic',
            'realm':'pbx-aaaaaaaaaaaa.example.invalid','users':[
                {'number':'9100','auth':'source-login-9100','password':'  Synthetic & <source> " one  ','tone_hz':440},
                {'number':'9101','auth':'source-login-9101','password':'Second & " exact source password','tone_hz':550}]}
        self.s['import_fixture']={'archive':str(archive),'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),
            'users':copy.deepcopy(self.s['users']),'draft_uuid':'12345678-1234-1234-1234-123456789abc'}
    def refresh(self):pass
    def record(self,name):self.checks.append({'case':name,'passed':True})
    def wait(self,predicate):
        value=predicate();subject.require(value);return value
    def cli(self,action,*args,**kwargs):
        self.commands.append((action,args))
        return {'import-archive':{'synthetic_archive_ready':True},'import-empty':{'no_upload_or_draft_created':True},
            'import-foreign-intent':{'foreign_registration_intent_saved':True},
            'import-upload':{'uploaded_archive_exact':True,'owned_draft':True},'status':{'bind':'127.0.0.1'},
            'import-discover':{'original_credentials_exact':True,'phone_line_exact':True,'restored_media_exact':True,
                'provider_disabled':True,'owned_draft_completed':True},'api':'error/user_not_registered'}[action]


class WebAdapter:
    failure=None; operations=[]
    def __init__(self,*args):pass
    def request(self,path,fields=None):
        self.operations.append(('request',path,fields))
        if path=='/login.php':return (200,path,'<form><input name="username"><input name="password"></form>' if fields is None else 'signed in')
        if fields is not None:
            if 'token' not in fields:return (200 if self.failure=='create_csrf' else 403,path,'refused')
            return (200,path,'setup-message error' if self.failure=='create_error' else 'restored')
        return (200,path,'<form><input name="action" value="analyze_import"><input name="token" value="owned"><input name="backup"></form>')
    def upload(self,path,fields,archive):
        self.operations.append(('upload',path,fields))
        subject.require(archive.startswith(b'PK') and 'backup' not in fields)
        if 'token' not in fields:return (200 if self.failure=='upload_csrf' else 403,path,'refused')
        draft='12345678-1234-1234-1234-123456789abc'
        url='/app/pbx_setup/?view=import_preview&draft='+draft
        text='<form><input name="action" value="create_import"><input name="draft_id" value="'+draft+'"><input name="token" value="owned"></form>'
        if self.failure=='leaked_password':text+='Second &amp; &quot; exact source password'
        if self.failure=='wrong_draft':url=url.replace(draft,'wrong')
        return 200,url,text


class FlowControls(unittest.TestCase):
    def test_foreign_failure_intent_precedes_first_send_and_primary_is_preserved(self):
        for failure in ('unregister_refused','unregister_raises','query_survivor','initial_timeout'):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                f=Fixture(Path(directory));peers=[];events=[];foreign_closed=[];captured=[]
                ledger=Path(directory)/'durable-intent-adapter.json';original_cli=f.cli
                def cli(action,*args,**kwargs):
                    if action=='import-foreign-intent':
                        intent=json.loads(args[0]);self.assertFalse(ledger.exists())
                        with ledger.open('x') as output:json.dump(intent,output);output.flush();os.fsync(output.fileno())
                    return original_cli(action,*args,**kwargs)
                f.cli=cli
                class Phone:
                    def __init__(self,user,realm,bind):self.auth_user=user['auth'];self.closed=False;peers.append(self)
                    def register(self,destination,password=None,expires=120):return {'code':403 if password is not None else 200,'digest_challenge_count':1}
                    def close(self):self.closed=True
                original_failure=RuntimeError('fictional initial transport timeout')
                class Foreign:
                    def __init__(self,*args):self.port=43210;self.registrations={}
                    def register(self,*args,**kwargs):
                        intent=json.loads(ledger.read_text());key=(intent['aor'],intent['realm'],intent['aor'])
                        self_record=self.registrations[key]
                        if self_record['cid']!=intent['call_id'] or self_record['tag']!=intent['tag']:raise RuntimeError('Intent differs from request adapter')
                        events.append(kwargs)
                        if kwargs.get('expires')==0:
                            if failure=='unregister_raises':raise RuntimeError('fictional unregister error')
                            return {'code':403 if failure=='unregister_refused' else 200}
                        if kwargs.get('query'):return {'contacts':['sip:fictional-survivor']}
                        if failure=='initial_timeout':raise original_failure
                        return {'code':200}
                    def close(self):foreign_closed.append(True)
                def module(name,path):
                    if path.name=='sip_trunk_live.py':return sip
                    if path.name=='pbx_v20_restore_native.py':return types.SimpleNamespace(SourcePhone=Phone)
                    return types.SimpleNamespace(windows_restore_phone=lambda phone,sock:phone)
                adapter=types.SimpleNamespace(load_module=module,WindowsRtpSocket=object,SIPClient=Foreign)
                actual_require=subject.require
                def observe_require(condition):
                    try:actual_require(condition)
                    except AssertionError as error:captured.append(error);raise
                with patch.object(subject,'require',observe_require):
                    try:subject.calls(f,adapter)
                    except BaseException as error:caught=error
                    else:self.fail('The foreign admission failure disappeared')
                self.assertIs(caught,original_failure if failure=='initial_timeout' else captured[0])
                self.assertTrue(ledger.is_file());self.assertTrue(all(peer.closed for peer in peers));self.assertEqual(foreign_closed,[True])
                self.assertFalse(f.checks);self.assertGreaterEqual(len(events),1)
                self.assertEqual(json.loads(ledger.read_text())['realm'],'foreign-'+f.s['scope']+'.example.invalid')

    def test_setup_uses_real_upload_flow_contract(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(subject,'ImportWeb',WebAdapter):
            WebAdapter.failure=None;WebAdapter.operations=[];f=Fixture(Path(directory));subject.setup(f,native)
            self.assertEqual(f.checks,[{'case':x,'passed':True} for x in subject.CASES[:2]])
            uploads=[row for row in WebAdapter.operations if row[0]=='upload'];self.assertEqual(len(uploads),2)
            self.assertEqual([x[0] for x in f.commands],['import-archive','import-empty','import-upload','import-discover'])
            self.assertNotIn('analyzeStored',(HERE/'windows_threecx_https_native.py').read_text())

    def test_setup_refuses_bad_csrf_preview_or_create(self):
        for failure in ('upload_csrf','create_csrf','wrong_draft','leaked_password','create_error'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory,patch.object(subject,'ImportWeb',WebAdapter):
                WebAdapter.failure=failure;f=Fixture(Path(directory))
                with self.assertRaises(AssertionError):subject.setup(f,native)
                self.assertNotIn({'case':subject.CASES[1],'passed':True},f.checks)
        WebAdapter.failure=None

    def test_call_flow_actual_tone_checker_with_explicit_peer_and_capture_adapters(self):
        for failure in (None,'wrong_password','foreign_realm','no_challenge','direct_refused','no_callee_ack','silence','wrong_tone','bad_rate','cleanup','tuple_changed'):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as directory:
                f=Fixture(Path(directory));peers=[];dialled=[];windows=[]
                class Phone:
                    def __init__(self,user,realm,bind):
                        self.user=user;self.auth_user=user['auth'];self.tone_hz=user['tone_hz'];self.dialogs={};self.closed=False;peers.append(self)
                    def register(self,destination,password=None,expires=120):
                        if password is not None:return {'code':200 if failure=='wrong_password' else 403}
                        return {'code':403 if expires==0 and failure=='cleanup' else 200,'digest_challenge_count':0 if failure=='no_challenge' else 1}
                    def dial(self,number,destination):
                        dialled.append(number);state={'acked':failure!='no_callee_ack'};peers[1].dialogs[str(len(dialled))]=state
                        return {'code':403 if failure=='direct_refused' else 200,'media':{}}
                    def hangup(self,call):pass
                    def check_receiver(self):pass
                    def close(self):self.closed=True
                class Foreign:
                    def __init__(self,*args):self.port=43210;self.registrations={}
                    def register(self,*args,**kwargs):
                        self.assert_intent()
                        return {'code':200 if failure=='foreign_realm' else 403}
                    def assert_intent(self):
                        intents=[args for action,args in f.commands if action=='import-foreign-intent']
                        subject.require(len(intents)==1)
                        intent=json.loads(intents[0][0]);key=(intent['aor'],intent['realm'],intent['aor'])
                        subject.require(self.registrations[key]=={'cid':intent['call_id'],'tag':intent['tag'],'seq':0})
                    def close(self):pass
                def capture(states,seconds,rate_check):
                    self.assertEqual(tuple(states),('caller','destination'));self.assertIs(rate_check,sip.rtp_rate_check)
                    windows.append(seconds);out={}
                    for label,hz in (('caller',550),('destination',440)):
                        samples=[int(6500*math.sin(2*math.pi*(1000 if failure=='wrong_tone' else hz)*i/8000)) for i in range(16000)]
                        if failure=='silence':samples=[0]*len(samples)
                        row={'sent':150,'received':150,'sent_first_at':0,'sent_last_at':.1 if failure=='bad_rate' else 3,
                             'received_first_at':0,'received_last_at':3,'decoded_pcm':struct.pack('<16000h',*samples)}
                        rate_check(row);out[label]=row
                    return out
                def module(name,path):
                    if path.name=='sip_trunk_live.py':return sip
                    if path.name=='pbx_v20_restore_native.py':return types.SimpleNamespace(SourcePhone=Phone,decoded_tone_check=original.decoded_tone_check)
                    return types.SimpleNamespace(windows_restore_phone=lambda phone,sock:phone)
                adapter=types.SimpleNamespace(load_module=module,WindowsRtpSocket=object,SIPClient=Foreign,bridged_media_window=capture)
                if failure=='tuple_changed':
                    cli=f.cli
                    f.cli=lambda action,*args,**kwargs: {'original_credentials_exact':False} if action=='import-discover' else cli(action,*args,**kwargs)
                if failure:
                    with self.assertRaises(AssertionError):subject.calls(f,adapter)
                    self.assertNotIn({'case':subject.CASES[5],'passed':True},f.checks)
                else:
                    subject.calls(f,adapter)
                    self.assertEqual(dialled,['9101','9180']);self.assertEqual(windows,[3,3])
                    self.assertEqual(f.checks,[{'case':x,'passed':True} for x in subject.CASES[2:]])
                self.assertTrue(all(peer.closed for peer in peers))

    def test_mode_is_nonrelease_and_separate(self):
        for values in ({},{'threecx_import_only':True},{'threecx_import_only':True,'native_diagnostics_only':1},
                       {'threecx_import_only':True,'native_diagnostics_only':True,'hold_diagnostics_only':True}):
            with self.subTest(mode=values),self.assertRaises(AssertionError):subject.run(types.SimpleNamespace(s=values),native)
        source=(HERE/'windows-native-acceptance.py').read_text()
        self.assertIn("if f.s.get('threecx_import_only') is True:",source)
        self.assertIn("'ui_render':'unqualified'",source)
        self.assertLess(source.index(".run(f,sys.modules[__name__])"),source.index("f.web=Web(f.s['public_url']"))


if __name__=='__main__':unittest.main()
