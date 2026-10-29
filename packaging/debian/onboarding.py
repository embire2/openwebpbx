#!/usr/bin/env python3
"""Privileged registration bridge. Provider DNS credentials stay at the custodian."""
import argparse
import base64
import contextlib
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import time
import urllib.request
import urllib.error
import uuid
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

API='https://call.openweb.co.za/api/v1'
IS_WINDOWS=os.name=='nt'
ROOT=Path(__file__).parent

class RegistrationPending(RuntimeError):
    def __init__(self,category):self.category=category;super().__init__(category)

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module

def environment():
    if not IS_WINDOWS and os.geteuid()!=0:raise PermissionError('The installed setup worker requires root.')
    if IS_WINDOWS:
        import ctypes
        if not ctypes.windll.shell32.IsUserAnAdmin():raise PermissionError('Elevated setup worker required.')
    b=load('onboarding_backup',ROOT/'backups.py');d=load('onboarding_domains',ROOT/'tenant-domains.py')
    if IS_WINDOWS:d.WINDOWS_ACL=lambda operation,path:d.windows(b,operation,path)
    return b,d

def ipc(b,operation,value=None):
    executable=str(b.APP/'php/php.exe')if IS_WINDOWS else'/usr/bin/php'
    result=subprocess.run([executable,str(ROOT/'onboarding.php'),str(b.WEB_VERSION.parent),operation],input=json.dumps(value or {}).encode(),capture_output=True,timeout=40)
    if result.returncode or len(result.stdout)>65536:raise RuntimeError('Local registration state is unavailable.')
    return json.loads(result.stdout)

def state_root(b):return (b.STATE if IS_WINDOWS else Path('/var/lib/openwebpbx'))/'tenant-domains'

def initialize(b,d):
    if not ipc(b,'policy').get('required'):return None,None,None,None,{'required':False}
    state=d.directory(state_root(b),True)
    private=d.directory(state/'private')
    # Prepare every public ancestor explicitly; intermediate mkdir defaults must
    # never leave the web server unable to read an ownership proof.
    for folder in [state/'proofs',state/'proofs/.well-known',state/'proofs/.well-known/openwebpbx-instance']:d.directory(folder,True)
    if IS_WINDOWS:d.windows(b,'Prepare',state)
    key,public,key_hash=d.identity(b.CONFIG.parent/'tenant-domains-instance-key.pem',lambda a,p:d.windows(b,a,p)if IS_WINDOWS else None)
    settings=b.read_settings() if hasattr(b,'read_settings') else None
    if settings is None:
        settings={}
        for line in b.CONFIG.read_text().splitlines():
            if '='in line and not line.lstrip().startswith(('#',';')):
                k,v=line.split('=',1);settings[k.strip()]=v.strip()
    host=d.hostname(settings.get('openweb.public_host',''))
    identity={'schema':1,'server_host':host,'key_hash':key_hash,'public_key':public}
    d.atomic(state/'instance-public.json',json.dumps(identity).encode(),True)
    local=ipc(b,'identity',identity)
    return state,private,key,identity,local

def metadata(b,d):
    state,private,key,identity,local=initialize(b,d)
    if not local.get('required'):raise ValueError('Image setup is available only for a registered-installation policy.')
    match=re.fullmatch(r'node-([a-f0-9]{32})\.openwebpbx\.com',identity['server_host'])
    if not match:raise ValueError('This image needs its own managed installation address.')
    bootstrap=str(uuid.UUID(match[1]));
    if uuid.UUID(bootstrap).version!=4:raise ValueError('A fresh installation identity is required.')
    path=private/'image-local.json'
    if path.exists():
        saved=json.loads(d.ordinary(path).read_text());service=next((s for s in local['services']if s['service_uuid']==saved['service_uuid']),None)
        if service is None or any(saved[k]!=service[k]for k in ['local_tenant_uuid','domain_uuid']):raise ValueError('The original image service changed.')
    else:
        if len(local['services'])!=1:raise ValueError('Choose the original service before preparing this image.')
        service=local['services'][0];d.atomic(path,json.dumps({k:service[k]for k in ['service_uuid','local_tenant_uuid','domain_uuid']}).encode())
    return dict(service,bootstrap_uuid=bootstrap,key_path=str(b.CONFIG.parent/'tenant-domains-instance-key.pem'),public_key=identity['public_key'],image_version=b.WEB_VERSION.read_text().strip(),private_root=str(private),proof_root=str(state/'proofs/.well-known/openwebpbx-instance'),helper_path=str(ROOT/'onboarding.py'),server_host=identity['server_host'])

def post(route,body,bearer):
    if route not in ['/installations/challenge','/installations']:raise ValueError('Unknown authorization operation.')
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),load_redirect(),urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    request=urllib.request.Request(API+route,json.dumps(body).encode(),{'Content-Type':'application/json','Accept':'application/json','Authorization':'Bearer '+bearer},method='POST')
    try:
        with opener.open(request,timeout=20)as response:
            raw=response.read(32769)
            if len(raw)>32768:raise ValueError('Bounded authorization response required.')
            return json.loads(raw)
    except urllib.error.HTTPError as error:
        raw=error.read(8193);category='rate_limited'if error.code==429 else'account_expired'if error.code==401 else'network'
        if len(raw)<=8192:
            try:
                code=json.loads(raw).get('error',{}).get('code')
                if error.code==403 and code in ['verified_account_required','email_verification_required']:category=code
            except (ValueError,AttributeError):pass
        raise RegistrationPending(category)from None

def load_redirect():
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,*args,**kwargs):return None
    return NoRedirect()

def process_jobs(b,d):
    state,private,key,identity,local=initialize(b,d)
    if not local.get('required'):return {'processed':0,'required':False}
    processed=0
    for job in ipc(b,'jobs'):
        nonce=None
        try:
            challenge=post('/installations/challenge',{k:job[k]for k in ['server_host','public_key','local_tenant_uuid','domain_uuid','label']},job['access_token'])
            nonce=challenge['nonce']
            if not re.fullmatch('[a-f0-9]{64}',nonce)or challenge['key_hash']!=identity['key_hash']or challenge['account_tenant_uuid']!=job['account_tenant_uuid']:raise ValueError('Authorization binding mismatch.')
            proof='openwebpbx-instance-v1\n'+nonce+'\n'+identity['key_hash']+'\n'+identity['server_host']+'\n'
            if challenge['proof_body']!=proof:raise ValueError('Authorization proof mismatch.')
            d.atomic(state/'proofs/.well-known/openwebpbx-instance'/nonce,proof.encode(),True)
            message='openwebpbx-installation-v1\n'+nonce+'\n'+job['server_host']+'\n'+job['key_hash']+'\n'+job['account_tenant_uuid']+'\n'+job['local_tenant_uuid']+'\n'+job['domain_uuid']+'\n'+job['label']+'\n'
            result=post('/installations',{'challenge_uuid':challenge['challenge_uuid'],'signature':base64.b64encode(key.sign(message.encode(),ec.ECDSA(hashes.SHA256()))).decode()},job['access_token'])
            ipc(b,'record',{'job_uuid':job['job_uuid'],'revision':job['revision'],'activation':result['activation']});processed+=1
        except RegistrationPending as error:
            ipc(b,'record',{'job_uuid':job['job_uuid'],'revision':job['revision'],'error_category':error.category,'retry_seconds':300})
        except (OSError,ValueError,KeyError,RuntimeError):
            ipc(b,'record',{'job_uuid':job['job_uuid'],'revision':job['revision'],'error_category':'network','retry_seconds':300})
        finally:
            if isinstance(nonce,str)and re.fullmatch('[a-f0-9]{64}',nonce):(state/'proofs/.well-known/openwebpbx-instance'/nonce).unlink(missing_ok=True)
    ipc(b,'reconcile');return {'processed':processed,'required':True}

def trusted_web(host):
    try:
        with __import__('socket').create_connection(('127.0.0.1',443),timeout=5)as raw:
            with ssl.create_default_context().wrap_socket(raw,server_hostname=host):return True
    except OSError:return False

def bind(b,d,meta,host):
    if IS_WINDOWS:return bind_locked(b,d,meta,host)
    with b.exclusive_guard(b.UPGRADE_LOCK):
        if d.blocked(b):raise RuntimeError('A restore or update is in progress.')
        return bind_locked(b,d,meta,host)

def bind_locked(b,d,meta,host):
    if host!=meta['server_host']:raise ValueError('Preserve the installed server address.')
    if trusted_web(host):return {'bound':True,'server_host':host}
    # The canonical address never changes: no SIP realm, credential or current
    # phone is renamed. Public setup replaces the fresh setup certificate.
    if IS_WINDOWS:
        command=[str(Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(b.APP/'tools/Enable-PublicAccess.ps1'),'-DomainName',host,'-EmailAddress','hello@openwebpbx.com','-Root',str(b.APP),'-StateRoot',str(b.STATE)]
        result=subprocess.run(command,capture_output=True,timeout=850,env=b.native_powershell_environment())
        if result.returncode:raise RuntimeError('Public certificate setup is waiting.')
    else:
        # The immutable fresh canonical HTTP vhost already serves this webroot.
        webroot=Path('/var/www/letsencrypt')
        for folder in [webroot,webroot/'.well-known',webroot/'.well-known/acme-challenge']:d.directory(folder,True)
        certname='openwebpbx-node-'+meta['bootstrap_uuid'].replace('-','')
        command=['certbot','certonly','--webroot','--webroot-path',str(webroot),'--cert-name',certname,'--non-interactive','--agree-tos','--email','hello@openwebpbx.com','--preferred-challenges','http','--key-type','ecdsa','--domains',host]
        result=subprocess.run(command,capture_output=True,timeout=240)
        if result.returncode:raise RuntimeError('Public certificate setup is waiting.')
        folder=Path('/etc/letsencrypt/live')/certname;cert=folder/'fullchain.pem';key=folder/'privkey.pem';d.certificate_info(cert,key,[host])
        site=d.ordinary('/etc/nginx/sites-available/openwebpbx');original=site.read_bytes();content=original
        for directive,path in [('ssl_certificate',cert),('ssl_certificate_key',key)]:
            content,count=re.subn(rb'\b('+directive.encode()+rb'\s+)[^;\r\n]+;',lambda m:m[1]+str(path).encode()+b';',content)
            if count!=1:raise ValueError('The owned installation web configuration needs review.')
        d.atomic(site,content)
        try:
            subprocess.run(['nginx','-t'],check=True,capture_output=True,timeout=15);subprocess.run(['systemctl','reload','nginx'],check=True,capture_output=True,timeout=20)
            subprocess.run([sys.executable,str(ROOT/'configure-sip-tls.py'),'--domain',host,'--fullchain',str(cert),'--private-key',str(key)],check=True,capture_output=True,timeout=120)
        except BaseException:
            d.atomic(site,original);subprocess.run(['systemctl','reload','nginx'],capture_output=True,timeout=20);raise
    if not trusted_web(host):raise RuntimeError('The trusted installation certificate is not ready.')
    return {'bound':True,'server_host':host}

def image(action,value,b,d,meta=None):
    meta=metadata(b,d)if meta is None else meta
    if action=='init':return meta
    if action=='bind':return bind(b,d,meta,value.get('server_host'))
    if action=='store':return ipc(b,'store',{'service_uuid':meta['service_uuid'],'activation':value['activation']})
    if action=='status':return ipc(b,'status',{'domain_uuid':meta['domain_uuid']})
    if action=='sign':
        message=value.get('message','')
        if not isinstance(message,str)or len(message)>8192 or not message.startswith(('openwebpbx-bootstrap-v1\n','openwebpbx-installation-v1\n','openwebpbx-complete-v1\n')):raise ValueError('Invalid setup signature message.')
        key,_,_=d.identity(b.CONFIG.parent/'tenant-domains-instance-key.pem',lambda a,p:d.windows(b,a,p)if IS_WINDOWS else None)
        return {'signature':base64.b64encode(key.sign(message.encode(),ec.ECDSA(hashes.SHA256()))).decode()}
    if action=='proof':
        nonce=value.get('nonce','');body=value.get('body','')
        if not isinstance(nonce,str)or not re.fullmatch('[a-f0-9]{64}',nonce)or not isinstance(body,str)or len(body)>1024 or not body.startswith(('openwebpbx-bootstrap-v1\n'+nonce+'\n','openwebpbx-instance-v1\n'+nonce+'\n')):raise ValueError('Invalid setup proof.')
        d.atomic(Path(meta['proof_root'])/nonce,body.encode(),True);return {'written':True}
    if action=='display':
        code=value.get('user_code','');link=value.get('verification_uri_complete','')
        if not isinstance(code,str)or not re.fullmatch('[A-F0-9]{5}-[A-F0-9]{5}',code)or link!='https://openwebpbx.com/wizard#code='+code:raise ValueError('Invalid public setup address.')
        uuid.UUID(value['pairing_uuid']);expires=value['expires_at']
        if not isinstance(expires,str)or len(expires)>40:raise ValueError('Invalid setup expiry.')
        until=dt.datetime.fromisoformat(expires.replace('Z','+00:00'))
        if until.tzinfo is None or not dt.datetime.now(dt.timezone.utc)<until<=dt.datetime.now(dt.timezone.utc)+dt.timedelta(minutes=31):raise ValueError('An unexpired short-lived setup code is required.')
        display={k:value[k]for k in ['user_code','verification_uri_complete','pairing_uuid']};display['expires_at']=until.astimezone(dt.timezone.utc).isoformat()
        d.atomic(state_root(b)/'setup.json',json.dumps(display).encode(),True);return {'displayed':True}
    raise ValueError('Unknown image setup operation.')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    actions=['tick','image-init','image-bind','image-store','image-status','image-sign','image-proof','image-display']
    group=parser.add_mutually_exclusive_group(required=True)
    for action in actions:group.add_argument('--'+action,action='store_true')
    args=parser.parse_args();action=next(a for a in actions if getattr(args,a.replace('-','_')))
    b,d=environment()
    if action!='tick':
        raw=sys.stdin.buffer.read(65537)
        if len(raw)>65536:raise ValueError('Bounded setup input required.')
        value=json.loads(raw or b'{}')
        with b.exclusive_guard(b.UPGRADE_LOCK):
            if d.blocked(b):raise RuntimeError('A restore or update is in progress.')
            if action!='image-bind':return image(action[6:],value,b,d)
            meta=metadata(b,d)
        # Native Windows public setup and Linux bind each take the same guard
        # themselves; never recurse into it while publishing a certificate.
        return image('bind',value,b,d,meta)
    # Registration jobs hold the ordinary maintenance lock. Public certificate
    # setup has its own lock and therefore runs only after this lock is released.
    meta=None
    with b.exclusive_guard(b.UPGRADE_LOCK):
        if d.blocked(b):return {'state':'deferred','reason':'maintenance_or_restore_hold'}
        result=process_jobs(b,d)
        if result.get('required'):
            try:meta=metadata(b,d)
            except ValueError:result['image']={'state':'not_an_image'}
    if meta is not None:
        try:
            consumer=load('onboarding_image_consumer',ROOT/'webhotel-onboarding.py')
            result['image']=consumer.run_once(provider='debian',metadata=meta)
        except (ValueError,RuntimeError,OSError,subprocess.SubprocessError)as error:
            result['image']={'state':'pending','error_type':type(error).__name__}
    return result

if __name__=='__main__':
    try:print(json.dumps(main()))
    except Exception as error:
        print(json.dumps({'state':'deferred','error_type':type(error).__name__}),file=sys.stderr);raise SystemExit(1)
