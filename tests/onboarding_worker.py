#!/usr/bin/env python3
"""Exercise the privileged onboarding source using only private local fixtures.

Real file modes, root-owned P-256 keys, signatures and maintenance locks are
used. HTTP/PHP/native Windows commands are bounded adapters, never production
services. This does not qualify Windows ACLs, IIS or a fresh OS installation.
"""
import argparse
import base64
import contextlib
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import urllib.error
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT=Path(__file__).resolve().parents[1]
checks=0


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);sys.modules[name]=value;spec.loader.exec_module(value)
    return value


def check(value,message):
    global checks
    if not value:raise AssertionError(message)
    checks+=1


def refused(function,message):
    try:function()
    except (OSError,ValueError,RuntimeError,KeyError):
        check(True,message);return
    raise AssertionError(message)


class Fixture:
    def __init__(self,base,required=True):
        self.base=base;self.required=required;self.records=[];self.queued=False
        self.bmodule=module('fixture_backup_'+uuid.uuid4().hex,ROOT/'packaging/debian/backups.py')
        self.w=module('fixture_onboarding_'+uuid.uuid4().hex,ROOT/'packaging/debian/onboarding.py')
        self.d=module('fixture_domains_'+uuid.uuid4().hex,ROOT/'packaging/debian/tenant-domains.py')
        self.state=base/'state';self.state.mkdir();(self.state/'backup-restore').mkdir()
        cfg=base/'config';cfg.mkdir();self.host='node-'+uuid.uuid4().hex+'.openwebpbx.com'
        config=cfg/'config.conf';config.write_text('openweb.public_host = '+self.host+'\ndatabase.0.type = pgsql\ndatabase.0.host = 127.0.0.1\ndatabase.0.port = 5433\ndatabase.0.name = fusionpbx\ndatabase.0.username = fusionpbx\n')
        web=base/'web';web.mkdir();(web/'VERSION').write_text('1.0.21\n')
        lock=base/'upgrade.lock';lock.touch(mode=0o600)
        self.b=SimpleNamespace(CONFIG=config,STATE=self.state,WEB_VERSION=web/'VERSION',
            UPGRADE_LOCK=lock,RESTORE=self.state/'backup-restore',APP=base/'app',
            exclusive_guard=self.bmodule.exclusive_guard,
            read_settings=lambda:self.bmodule.read_settings(config),
            native_powershell_environment=lambda:{'fixture_native':'only'})
        self.w.state_root=lambda b:self.state/'tenant-domains';self.d.STATE_ROOT=self.state
        self.service={'service_uuid':str(uuid.uuid4()),'local_tenant_uuid':str(uuid.uuid4()),
                      'domain_uuid':str(uuid.uuid4()),'user_email':'fixture@example.invalid'}
        self.account=str(uuid.uuid4());self.jobid=str(uuid.uuid4());self.secret='owpa_fixture_never_write'
        self.w.ipc=self.ipc

    def ipc(self,b,operation,value=None):
        if operation=='policy':return {'required':self.required}
        if operation=='identity':return {'required':self.required,'services':[dict(self.service)]}
        if operation=='jobs':
            if not self.queued:return []
            identity=json.loads((self.state/'tenant-domains/instance-public.json').read_text())
            return [dict(self.service,server_host=self.host,public_key=identity['public_key'],key_hash=identity['key_hash'],
                         account_tenant_uuid=self.account,label='worker-fixture',access_token=self.secret,job_uuid=self.jobid,revision=7)]
        if operation=='record':self.records.append(value);return {'recorded':True}
        if operation in ('reconcile','status','store'):return {'ready':False}
        raise AssertionError('Unexpected local IPC operation '+operation)

    def snapshot(self):
        return {str(p.relative_to(self.base)):(p.stat().st_mode & 0o777,hashlib.sha256(p.read_bytes()).hexdigest())
                for p in self.base.rglob('*') if p.is_file() and not p.is_symlink()}

    def tick(self):
        original=self.w.load
        fixture=self
        class Agent:
            def __init__(self,provider):check(provider=='debian','Unexpected installed consumer provider')
            def cycle(self,metadata):
                # The consumer may acquire its own native certificate lock.
                with fixture.b.exclusive_guard(fixture.b.UPGRADE_LOCK):
                    check(metadata['server_host']==fixture.host,'Image changed the server hostname')
                return {'state':'waiting_for_owner'}
        def load(name,path):
            if name=='onboarding_image_consumer':return SimpleNamespace(run_once=lambda provider,metadata:Agent(provider).cycle(metadata))
            return original(name,path)
        with patch.object(self.w,'environment',return_value=(self.b,self.d)),patch.object(self.w,'load',side_effect=load),patch.object(sys,'argv',['onboarding.py','--tick']):
            return self.w.main()

    def command(self,action,value=None):
        stream=SimpleNamespace(buffer=io.BytesIO(json.dumps(value or {}).encode()))
        with patch.object(self.w,'environment',return_value=(self.b,self.d)),patch.object(sys,'argv',['onboarding.py','--image-'+action]),patch.object(sys,'stdin',stream):
            return self.w.main()


def run(base):
    legacy=Fixture(base/'legacy',False)
    before=legacy.snapshot();result=legacy.tick()
    check(result.get('required') is False,'Legacy policy did not remain optional')
    check(legacy.snapshot()==before,'Legacy tick changed installed state')
    refused(lambda:legacy.w.metadata(legacy.b,legacy.d),'Legacy image metadata initialization was accepted')
    check(legacy.snapshot()==before,'Refused legacy image command changed installed state')

    f=Fixture(base/'fresh');w,b,d=f.w,f.b,f.d
    (b.RESTORE/'hold-fixture').touch();before=f.snapshot();result=f.tick()
    check(result.get('state')=='deferred','Restore hold did not defer setup')
    check(f.snapshot()==before,'Held setup changed configuration')
    (b.RESTORE/'hold-fixture').unlink()
    with b.exclusive_guard(b.UPGRADE_LOCK):refused(f.tick,'Concurrent setup ignored the actual maintenance lock')
    check(not (f.state/'tenant-domains').exists(),'Busy setup initialized state')

    result=f.tick();check(result['required'] is True,'Fresh worker lost its required policy')
    meta=w.metadata(b,d);key=serialization.load_pem_private_key(Path(meta['key_path']).read_bytes(),None)
    check(key.curve.name=='secp256r1','A non-P-256 installation key was created')
    check(Path(meta['key_path']).stat().st_uid==0 and Path(meta['key_path']).stat().st_mode&0o077==0,'Instance key is not root-private')
    identity=json.loads((f.state/'tenant-domains/instance-public.json').read_text())
    check(identity['key_hash']==hashlib.sha256(base64.b64decode(meta['public_key'])).hexdigest(),'Public identity does not bind the actual key')
    check((f.state/'tenant-domains/instance-public.json').stat().st_mode&0o777==0o640,'Public identity mode is incorrect')
    check(Path(meta['proof_root']).is_dir(),'Public proof directory is missing')
    first=meta['bootstrap_uuid'];check(w.metadata(b,d)['bootstrap_uuid']==first,'A retry changed the installation identity')
    oldservice=dict(f.service);f.service['domain_uuid']=str(uuid.uuid4())
    refused(lambda:w.metadata(b,d),'A saved image silently moved to another domain');f.service=oldservice

    nonce='a'*64;message='openwebpbx-installation-v1\nfixture\n'
    signature=w.image('sign',{'message':message},b,d)['signature']
    key.public_key().verify(base64.b64decode(signature),message.encode(),ec.ECDSA(hashes.SHA256()));check(True,'Protected signing bridge failed')
    for message in ('arbitrary unscoped message','openwebpbx-installation-v1\n'+'x'*8193):
        refused(lambda:w.image('sign',{'message':message},b,d),'Unbounded/unscoped signing was accepted')
    proof='openwebpbx-bootstrap-v1\n'+nonce+'\nfixture\n'
    w.image('proof',{'nonce':nonce,'body':proof},b,d)
    check((Path(meta['proof_root'])/nonce).read_text()==proof,'Proof bridge changed the signed body')
    for value in ({'nonce':'../outside','body':proof},{'nonce':nonce,'body':'openwebpbx-bootstrap-v1\n'+'b'*64+'\n'}, {'nonce':nonce,'body':'x'*1025}):
        refused(lambda:w.image('proof',value,b,d),'Unsafe proof destination/body was accepted')
    display={'user_code':'A1B2C-D3E4F','verification_uri_complete':'https://openwebpbx.com/wizard#code=A1B2C-D3E4F',
             'pairing_uuid':str(uuid.uuid4()),'expires_at':(dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=10)).astimezone(dt.timezone(dt.timedelta(hours=-4))).isoformat(' '),'device_code':f.secret}
    w.image('display',display,b,d);shown=json.loads((f.state/'tenant-domains/setup.json').read_text())
    check(set(shown)=={'user_code','verification_uri_complete','pairing_uuid','expires_at'},'A device credential escaped into public setup state')
    check(f.secret not in json.dumps(shown),'Private device credential was published')
    check(shown['expires_at'].endswith('+00:00') and 'T' in shown['expires_at'],'PostgreSQL offset timestamp was not normalized to UTC ISO')
    refused(lambda:w.image('display',dict(display,verification_uri_complete='https://foreign.example.invalid/'),b,d),'Foreign setup URL was accepted')
    for expires in ((dt.datetime.now(dt.timezone.utc)-dt.timedelta(seconds=1)).isoformat(),(dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=32)).isoformat(),dt.datetime.now().isoformat(),'not-a-timestamp'):
        refused(lambda:w.image('display',dict(display,expires_at=expires),b,d),'An expired, long-lived or invalid setup code was published')
    before=f.snapshot()
    for action in ('init','bind','store','status','sign','proof','display'):
        with b.exclusive_guard(b.UPGRADE_LOCK):refused(lambda:f.command(action),'An image CLI operation bypassed the actual maintenance lock')
    check(f.snapshot()==before,'A locked image operation modified local state')
    (b.RESTORE/'hold-cli').touch();before=f.snapshot()
    for action in ('init','bind','store','status','sign','proof','display'):
        refused(lambda:f.command(action),'An image CLI operation bypassed a restore hold')
    check(f.snapshot()==before,'A held image operation modified local state');(b.RESTORE/'hold-cli').unlink()
    check(f.command('init')['server_host']==f.host,'The CLI image identity did not match this installation')
    refused(lambda:w.bind(b,d,meta,'foreign.example.invalid'),'Image binding renamed the canonical server')
    with patch.object(w,'trusted_web',return_value=True):
        check(w.bind(b,d,meta,f.host)['bound'],'Trusted canonical certificate was not reused')
        check(f.command('bind',{'server_host':f.host})['bound'],'CLI certificate binding recursed into the shared maintenance lock')
        with b.exclusive_guard(b.UPGRADE_LOCK):refused(lambda:w.bind(b,d,meta,f.host),'Linux certificate binding ignored the maintenance lock')
        (b.RESTORE/'hold-fixture').touch();refused(lambda:w.bind(b,d,meta,f.host),'Linux certificate binding ignored a restore hold');(b.RESTORE/'hold-fixture').unlink()

    f.queued=True;posts=[]
    def post(route,body,bearer):
        check(bearer==f.secret,'Registration used another account credential');posts.append(route)
        if route=='/installations/challenge':return {'nonce':nonce,'key_hash':identity['key_hash'],'account_tenant_uuid':f.account,
            'proof_body':'openwebpbx-instance-v1\n'+nonce+'\n'+identity['key_hash']+'\n'+f.host+'\n','challenge_uuid':str(uuid.uuid4())}
        check((Path(meta['proof_root'])/nonce).is_file(),'The challenge proof was absent while authorizing')
        expected='openwebpbx-installation-v1\n'+nonce+'\n'+f.host+'\n'+identity['key_hash']+'\n'+f.account+'\n'+f.service['local_tenant_uuid']+'\n'+f.service['domain_uuid']+'\nworker-fixture\n'
        key.public_key().verify(base64.b64decode(body['signature']),expected.encode(),ec.ECDSA(hashes.SHA256()));check(True,'Job signature has incorrect bindings')
        return {'activation':{'fixture':'central-signature-is-verified-by-PHP'}}
    with patch.object(w,'post',side_effect=post):result=w.process_jobs(b,d)
    check(result['processed']==1 and posts==['/installations/challenge','/installations'],'A queued authorization did not complete once')
    check(f.records[-1]['revision']==7 and 'activation'in f.records[-1],'Authorized result lost its revision or receipt')
    check(not (Path(meta['proof_root'])/nonce).exists(),'The temporary ownership proof was retained')
    check(all(f.secret.encode() not in p.read_bytes()for p in f.base.rglob('*')if p.is_file()),'A bearer credential was written to local public/private fixture state')
    with patch.object(w,'post',return_value={'nonce':nonce,'key_hash':'0'*64,'account_tenant_uuid':f.account}):result=w.process_jobs(b,d)
    check(result['processed']==0 and f.records[-1]['error_category']=='network','A foreign challenge was accepted')
    check(not (Path(meta['proof_root'])/nonce).exists(),'Failed authorization retained a proof')

    # Exercise the real fixed-URL HTTPS request/error parser, rather than
    # replacing post(). No socket is opened: the opener supplies real HTTPError
    # objects with controlled status/body and captures the outgoing request.
    private_error='fictional-response-secret-not-for-logs'
    email_error=lambda code:json.dumps({'error':{'code':code,'message':private_error}}).encode()
    errors=[(403,email_error('verified_account_required'),'verified_account_required'),
            (403,email_error('email_verification_required'),'email_verification_required'),
            (401,email_error('verified_account_required'),'account_expired'),
            (429,email_error('verified_account_required'),'rate_limited'),
            (403,email_error('unknown_category'),'network'),
            (400,email_error('verified_account_required'),'network'),
            (503,email_error('verified_account_required'),'network'),
            (403,b'not-json '+private_error.encode(),'network'),
            (403,b'[]','network'),(403,b'','network'),
            (403,email_error('verified_account_required')+b' '*8193,'network'),
            (307,b'','network')]
    for status,error_body,expected_category in errors:
        captured=[];streams=io.StringIO();responses=[]
        class ErrorOpener:
            def open(self,request,timeout):
                captured.append(request)
                check(timeout==20 and request.full_url==w.API+'/installations/challenge',
                      'Authorization error handling changed its fixed endpoint or deadline')
                error=urllib.error.HTTPError(request.full_url,status,'Fictional refusal',{},io.BytesIO(error_body));responses.append(error)
                raise error
        with patch.object(w.urllib.request,'build_opener',return_value=ErrorOpener()),contextlib.redirect_stdout(streams),contextlib.redirect_stderr(streams):
            result=w.process_jobs(b,d)
        record=f.records[-1]
        check(result['processed']==0 and record['error_category']==expected_category,
              'HTTP error category was lost or wrongly trusted: '+str(status)+'/'+expected_category)
        check(len(captured)==1 and captured[0].get_header('Authorization')=='Bearer '+f.secret,
              'An error retry used another identity or sent its bearer to another endpoint')
        check(not streams.getvalue() and private_error not in json.dumps(record) and f.secret not in json.dumps(record),
              'An HTTP response body or bearer escaped into logs/worker status')
        if len(error_body)>8192:
            check(responses[0].fp.tell()==8193,'HTTP error parsing did not enforce its 8 KiB observation bound')

    # A late central refusal must retain the useful category and retire the
    # exact proof that was published before POST /installations.
    for status,category in [(403,'verified_account_required'),(429,'rate_limited')]:
        def late_open(request,timeout):
            if request.full_url==w.API+'/installations/challenge':
                return io.BytesIO(json.dumps({'nonce':nonce,'key_hash':identity['key_hash'],'account_tenant_uuid':f.account,
                    'proof_body':'openwebpbx-instance-v1\n'+nonce+'\n'+identity['key_hash']+'\n'+f.host+'\n','challenge_uuid':str(uuid.uuid4())}).encode())
            check(request.full_url==w.API+'/installations' and (Path(meta['proof_root'])/nonce).is_file(),
                  'Late authorization did not publish the exact owned proof')
            raise urllib.error.HTTPError(request.full_url,status,'Fictional late refusal',{},io.BytesIO(email_error(category)))
        with patch.object(w.urllib.request,'build_opener',return_value=SimpleNamespace(open=late_open)):
            result=w.process_jobs(b,d)
        check(result['processed']==0 and f.records[-1]['error_category']==category,
              'Late HTTP refusal lost its actionable category')
        check(not (Path(meta['proof_root'])/nonce).exists(),'Late HTTP refusal retained a temporary ownership proof')
    check(w.load_redirect().redirect_request(None,None,302,'Fictional redirect',{},'https://foreign.example.invalid/') is None,
          'The authorization client permits forwarding its bearer through a redirect')

    (base/'windows').mkdir();wf=Fixture(base/'windows');ww,wb,wd=wf.w,wf.b,wf.d
    def windows(backup,operation,path):
        if operation=='Prepare':check((wf.state/'tenant-domains/proofs/.well-known/openwebpbx-instance').is_dir(),'Windows Prepare ran before the public proof path existed')
        return {}
    with patch.object(ww,'IS_WINDOWS',True),patch.object(wd,'windows',side_effect=windows):
        ww.initialize(wb,wd);windows_meta=ww.metadata(wb,wd)
        captured=[]
        def native(command,**kwargs):captured.append((command,kwargs));return SimpleNamespace(returncode=0)
        with patch.object(ww,'trusted_web',side_effect=[False,True]),patch.object(ww.subprocess,'run',side_effect=native):
            check(ww.bind(wb,wd,windows_meta,wf.host)['bound'],'Windows certificate bridge did not report success')
        command,options=captured[0]
        check(command[command.index('-DomainName')+1]==wf.host and command[command.index('-Root')+1]==str(wb.APP),'Windows public certificate bridge changed installed bindings')
        check(options['env']=={'fixture_native':'only'} and options['timeout']==850,'Windows native bridge did not use its bounded native environment')
        check(command[command.index('-EmailAddress')+1]=='hello@openwebpbx.com','Windows certificate contact contract drifted')

    realipc=module('onboarding_ipc_contract',ROOT/'packaging/debian/onboarding.py')
    with patch.object(realipc.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=b'{"required":false}'))as invoke:
        check(realipc.ipc(b,'policy')=={'required':False},'Local PHP result was not decoded')
        args,kwargs=invoke.call_args
        check(args[0][0]=='/usr/bin/php' and args[0][-1]=='policy' and kwargs['timeout']==40 and kwargs['capture_output'],'Local PHP IPC arguments are unbounded or incorrect')
    for returned in (SimpleNamespace(returncode=1,stdout=b'{}'),SimpleNamespace(returncode=0,stdout=b'x'*65537),SimpleNamespace(returncode=0,stdout=b'not json')):
        with patch.object(realipc.subprocess,'run',return_value=returned):refused(lambda:realipc.ipc(b,'policy'),'Unsafe local PHP response was accepted')


def main():
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='openweb-onboarding-worker-')as temporary:
        base=Path(temporary);(base/'legacy').mkdir();(base/'fresh').mkdir();run(base)
    print(f'PASS: {checks} isolated onboarding worker controls (no native Windows/OS installation claim)')


if __name__=='__main__':main()
