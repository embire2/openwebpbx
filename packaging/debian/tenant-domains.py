#!/usr/bin/env python3
"""Instance-owned tenant HTTPS leases. No DNS provider credential belongs here."""
import argparse
import base64
import contextlib
import datetime as dt
import email.utils
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

BROKER = 'https://domains.openwebpbx.com'
SUFFIX = '.openwebpbx.com'
MAX_NAMES = 50
STATE_ROOT = Path('/var/lib/openwebpbx')
IS_WINDOWS = os.name=='nt'
WINDOWS_ACL = None
class Pending(RuntimeError):
    def __init__(self, category, seconds=300): self.category=category; self.seconds=max(60,min(604800,int(seconds))); super().__init__(category)
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None

def ordinary(path):
    path=Path(path)
    for item in [path,*path.parents]:
        if item.is_symlink() or (item.exists() and bool(getattr(item.lstat(),'st_file_attributes',0)&0x400)): raise ValueError('Linked tenant-domain path refused.')
    return path

def directory(path, public=False):
    path=ordinary(path); path.mkdir(parents=True,exist_ok=True,mode=0o750 if public else 0o700)
    if not IS_WINDOWS:
        if path.stat().st_uid!=0 or path.stat().st_mode&0o022: raise ValueError('Protected tenant-domain directory required.')
        os.chmod(path,0o750 if public else 0o700);os.chown(path,0,33 if public else 0)
    elif WINDOWS_ACL:WINDOWS_ACL('DirectoryPublic'if public else'DirectoryPrivate',path)
    return path

def atomic(path, data, public=False):
    path=ordinary(path);ordinary(path.parent).mkdir(parents=True,exist_ok=True,mode=0o750 if public else 0o700)
    if not IS_WINDOWS and(path.parent.stat().st_uid!=0 or path.parent.stat().st_mode&0o022):raise ValueError('Protected destination parent required.')
    descriptor,name=tempfile.mkstemp(dir=path.parent,prefix='.tenant-domains-');os.close(descriptor);temporary=Path(name)
    try:
        # Close the CreateNew handle before the Windows security operation, so
        # Set-Acl can open it. Apply its ACL while it is still empty.
        if IS_WINDOWS:
            if not WINDOWS_ACL:raise ValueError('Windows ACL adapter required before private writes.')
            WINDOWS_ACL('FilePublic'if public else'FilePrivate',temporary)
        else:os.chmod(temporary,0o640 if public else 0o600);os.chown(temporary,0,33 if public else 0)
        with temporary.open('wb')as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,path)
    finally:temporary.unlink(missing_ok=True)

def retry_after(value, now=None):
    now=time.time()if now is None else now
    try: seconds=int(value)
    except (TypeError,ValueError):
        try:seconds=int(email.utils.parsedate_to_datetime(value).timestamp()-now)
        except (TypeError,ValueError,OverflowError):seconds=300
    return max(60,min(604800,seconds))

def hostname(value, tenant=False):
    if not isinstance(value,str)or value!=value.lower()or len(value)>253 or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+',value):raise ValueError('Invalid installed hostname.')
    if tenant and not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.openwebpbx\.com',value):raise ValueError('Invalid leased hostname.')
    return value

def identity(path, windows=None):
    path=ordinary(path)
    if not path.exists():
        key=ec.generate_private_key(ec.SECP256R1());atomic(path,key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    if windows:windows('KeyAcl',path)
    if path.stat().st_nlink!=1 or (not IS_WINDOWS and(path.stat().st_uid!=0 or path.stat().st_mode&0o077)):raise ValueError('Private instance key required.')
    key=serialization.load_pem_private_key(path.read_bytes(),None)
    if not isinstance(key,ec.EllipticCurvePrivateKey)or key.curve.name!='secp256r1':raise ValueError('Unexpected instance key.')
    der=key.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)
    return key,base64.b64encode(der).decode(),hashlib.sha256(der).hexdigest()

def message(request, key_hash):
    return ('openwebpbx-tenant-v1\n'+request['challenge']+'\n'+request['serverHost']+'\n'+key_hash+'\n'+request['tenantUuid']+'\n'+request['domainUuid']+'\n'+request['label']+'\n'+str(int(request['enabled']))+'\n'+str(request['revision'])+'\n'+str(int(request['move']))+'\n').encode()

class Broker:
    def __init__(self, origin=BROKER, opener=None):
        self.origin=origin;self.opener=opener or urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
    def post(self, route, value, move_revision=None):
        headers={'Content-Type':'application/json','Accept':'application/json'}
        if move_revision is not None:headers['If-Match']='"'+str(move_revision)+'"'
        request=urllib.request.Request(self.origin+route,json.dumps(value,separators=(',',':')).encode(),headers=headers,method='POST')
        try:
            with self.opener.open(request,timeout=45)as response:
                raw=response.read(8193)
                if len(raw)>8192:raise Pending('network')
                return json.loads(raw)
        except urllib.error.HTTPError as error:
            if error.code==409:raise Pending('revision_conflict',3600)from None
            raise Pending('rate_limited'if error.code==429 else'network',retry_after(error.headers.get('Retry-After')))from None
        except (OSError,ValueError):raise Pending('network')from None
    def lease(self, row, key, public, key_hash, server, proofs, move=False):
        challenge=self.post('/v1/challenges',{'publicKey':public,'serverHost':server});nonce=challenge.get('challenge')
        if not isinstance(nonce,str)or not re.fullmatch('[0-9a-f]{64}',nonce):raise Pending('network')
        path=proofs/nonce;assert not path.exists();atomic(path,('openwebpbx-instance-v1\n'+nonce+'\n'+key_hash+'\n'+server+'\n').encode(),public=True)
        try:
            request={'challenge':nonce,'publicKey':public,'serverHost':server,'tenantUuid':row['tenant_uuid'],'domainUuid':row['domain_uuid'],'label':row['requested_label'],'enabled':row['desired_enabled']in(True,'t','1',1),'revision':int(row['revision']),'move':move}
            request['signature']=base64.b64encode(key.sign(message(request,key_hash),ec.ECDSA(hashes.SHA256()))).decode()
            reply=self.post('/v1/leases',request,request['revision']if move else None)
            if not isinstance(reply,dict)or set(reply)!={'hostname','serverHost','state','enabled','revision'}or reply['serverHost']!=server or type(reply['enabled'])is not bool or reply['enabled']!=request['enabled']or reply['state']not in['dns_ready','pending_dns','dns_conflict','disabled']or type(reply['revision'])is not int or reply['revision']!=(int(row['revision'])+(1 if move or not row['revision']else 0)):raise Pending('network')
            hostname(reply['hostname'],tenant=True)
            if row.get('hostname')and row['hostname']!=reply['hostname']:raise Pending('revision_conflict',3600)
            return reply
        finally:path.unlink(missing_ok=True)

def bridge(b, operation, value=None):
    php=str(b.APP/'php/php.exe')if IS_WINDOWS else'/usr/bin/php'
    helper=Path(__file__).with_name('tenant-domains.php')
    result=subprocess.run([php,str(ordinary(helper)),str(b.WEB_VERSION.parent),operation],input=None if value is None else json.dumps(value).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=35)
    if result.returncode or len(result.stdout)>256*1024:raise Pending('local_configuration')
    return json.loads(result.stdout)

def windows(b, operation, value):
    root=b.APP;program=Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'
    result=subprocess.run([str(program),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(root/'tools/Tenant-Domains.ps1'),'-Operation',operation,'-InputFile',str(value)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=b.native_powershell_environment(),timeout=240)
    if result.returncode:
        try:
            record=json.loads(result.stderr)
            if set(record)=={'error_category','retry_seconds'}and record['error_category']in['certificate_pending','rate_limited']and isinstance(record['retry_seconds'],int):raise Pending(record['error_category'],record['retry_seconds'])
        except (ValueError,TypeError):pass
        raise Pending('certificate_pending',3600)
    return json.loads(result.stdout)

def certificate_info(cert, key, names):
    cert=x509.load_pem_x509_certificate(Path(cert).read_bytes());private=serialization.load_pem_private_key(Path(key).read_bytes(),None)
    if cert.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)!=private.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo):raise ValueError('Certificate key mismatch.')
    allowed=cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
    now=dt.datetime.now(dt.timezone.utc)
    if not set(names)<=set(allowed)or cert.not_valid_before_utc>now or cert.not_valid_after_utc<=now+dt.timedelta(minutes=2):raise ValueError('Current exact SAN certificate required.')
    return cert.not_valid_after_utc,hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()

def nginx(names, certificate=None, key=None):
    names=sorted(set(hostname(name,tenant=True)for name in names));chunks=['# OpenWeb PBX managed tenant domains v1\n']
    for name in names:
        chunks.append('server { listen 80; listen [::]:80; server_name '+name+'; location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; try_files $uri =404; } location / { return 404; } }\n')
        if certificate:
            for path in [certificate,key]:
                if not re.fullmatch(r'/etc/letsencrypt/live/openwebpbx-tenants-[0-9a-f]{12}/(?:fullchain|privkey)\.pem',str(path)):raise ValueError('Owned certificate path required.')
            template=Path(__file__).with_name('tenant-domains-nginx.conf').read_text();chunks.append(template.replace('@HOST@',name).replace('@CERT@',str(certificate)).replace('@KEY@',str(key)))
    return ''.join(chunks).encode()

def install_nginx(content):
    target=Path('/etc/nginx/conf.d/openwebpbx-tenant-domains.conf');old=ordinary(target).read_bytes()if target.exists()else None
    if old is not None and not old.startswith(b'# OpenWeb PBX managed tenant domains v1\n'):raise Pending('local_configuration',3600)
    atomic(target,content)
    try:
        subprocess.run(['nginx','-t'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=15);subprocess.run(['systemctl','reload','nginx'],check=True,timeout=20)
    except BaseException:
        if old is None:target.unlink(missing_ok=True)
        else:atomic(target,old)
        raise

def certify(names, key_hash, private, contact, b):
    names=sorted(set(names));assert 0<len(names)<=MAX_NAMES
    if IS_WINDOWS:
        inp=private/'certificate-input.json';atomic(inp,json.dumps({'names':names,'key_hash':key_hash,'contact':contact}).encode());return windows(b,'Certify',inp)['not_after']
    cert_name='openwebpbx-tenants-'+key_hash[:12];folder=Path('/etc/letsencrypt/live')/cert_name;cert=folder/'fullchain.pem';key=folder/'privkey.pem';reuse=False
    try:until,digest=certificate_info(cert,key,names);reuse=until>dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=30)
    except (OSError,ValueError,x509.ExtensionNotFound):pass
    if not reuse:
        # Keep existing HTTPS aliases while enabling only the new names' HTTP01.
        ready=[]
        try:
            old=private.parent/'ready.json';ready=list(json.loads(old.read_text()).get('aliases',{}));certificate_info(cert,key,ready)
        except (OSError,ValueError,x509.ExtensionNotFound):ready=[]
        install_nginx(nginx(ready,cert,key)+nginx(set(names)-set(ready)))
        if not isinstance(contact,str)or not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',contact):raise Pending('local_configuration',3600)
        command=['certbot','certonly','--webroot','--webroot-path','/var/www/letsencrypt','--cert-name',cert_name,'--renew-with-new-domains','--non-interactive','--agree-tos','--email',contact,'--preferred-challenges','http','--key-type','ecdsa','--domains',','.join(names)]
        log=private/'acme-last.private.log'
        with log.open('wb')as stream:r=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=220)
        if r.returncode:
            raw=log.read_bytes()[-65536:].decode(errors='replace');match=re.search(r'(?im)retry-after[:= ]+([0-9]+)',raw)
            raise Pending('rate_limited'if'rate limit'in raw.lower()else'certificate_pending',retry_after(match[1])if match else 3600)
        until,digest=certificate_info(cert,key,names)
    install_nginx(nginx(names,cert,key))
    for name in names:
        with socket.create_connection(('127.0.0.1',443),timeout=5)as raw:
            with ssl.create_default_context().wrap_socket(raw,server_hostname=name)as stream:
                if hashlib.sha256(stream.getpeercert(binary_form=True)).hexdigest()!=digest:raise Pending('certificate_pending')
    return until.isoformat()

def blocked(b):
    restore=b.RESTORE
    if list(restore.glob('hold-*')):return True
    journal=restore/'journal.json'
    if journal.exists()and json.loads(ordinary(journal).read_text()).get('state')not in['restored','recovered']:return True
    journal=(b.STATE if IS_WINDOWS else STATE_ROOT)/'updates/install-journal.json'
    return journal.exists()and json.loads(ordinary(journal).read_text()).get('state')not in['completed','rolled_back']

def run(move=False, confirm=None):
    global WINDOWS_ACL
    spec=importlib.util.spec_from_file_location('tenant_local_backup',Path(__file__).with_name('backups.py'));b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
    if not IS_WINDOWS and os.geteuid()!=0:raise PermissionError('Run the installed tenant domain worker as root.')
    if IS_WINDOWS:WINDOWS_ACL=lambda operation,path:windows(b,operation,path)
    with b.exclusive_guard(b.UPGRADE_LOCK):
        if blocked(b):return {'state':'deferred','reason':'maintenance_or_restore_hold'}
        initial=bridge(b,'discover');server=hostname(initial['server_host'])
        if move and confirm!=server:raise ValueError('Confirm the new installed server hostname for an explicit lease move.')
        state=directory((b.STATE if IS_WINDOWS else STATE_ROOT)/'tenant-domains',True);private=directory(state/'private');proofs=directory(state/'proofs/.well-known/openwebpbx-instance',True)
        if IS_WINDOWS:windows(b,'Prepare',state)
        key,public,key_hash=identity(b.CONFIG.parent/'tenant-domains-instance-key.pem',lambda action,value:windows(b,action,value)if IS_WINDOWS else None)
        pending={row['domain_uuid']:row for row in initial['inventory']};changed=[]
        try:
            marker=json.loads(ordinary(state/'ready.json').read_text());old_ready=marker['aliases']if marker['schema']==1 and marker['server_host']==server and marker['key_hash']==key_hash else {}
        except (OSError,ValueError,KeyError):old_ready={}
        for row in initial['aliases'][:10]:
            delay=300;old_state=row['state']
            try:
                if row['key_hash']not in('',key_hash):raise Pending('revision_conflict',3600)
                reply=Broker().lease(row,key,public,key_hash,server,proofs,move)
                row.update({'hostname':reply['hostname'],'server_host':server,'key_hash':key_hash,'revision':reply['revision'],'state':{'dns_ready':'pending_tls','pending_dns':'pending_dns','dns_conflict':'conflict','disabled':'disabled'}[reply['state']]});error='dns_conflict'if reply['state']=='dns_conflict'else''
                if reply['state']=='disabled':row['certificate_not_after']=None
            except Pending as problem:
                row.update({'server_host':server,'key_hash':key_hash,'state':'conflict'if problem.category=='revision_conflict'else('ready'if old_state=='ready'and row.get('hostname')in old_ready and dt.datetime.fromisoformat(old_ready[row['hostname']]).timestamp()>time.time()else'retry')});error=problem.category;delay=problem.seconds
            pending[row['domain_uuid']]=row;changed.append((row,error,delay))
        active=[row for row in pending.values()if row['desired_enabled']in(True,'t','1',1)and row['state']in['ready','pending_tls']and row['hostname']]
        until=None;cert_error=None
        if active:
            try:
                backoff=private/'certificate-backoff.json'
                if backoff.exists()and json.loads(ordinary(backoff).read_text()).get('until',0)>time.time():raise Pending('certificate_pending',int(json.loads(backoff.read_text())['until']-time.time()))
                until=certify([row['hostname']for row in active],key_hash,private,initial['contact_email'],b);backoff.unlink(missing_ok=True)
                atomic(state/'ready.json',json.dumps({'schema':1,'server_host':server,'key_hash':key_hash,'aliases':{row['hostname']:until for row in active}}).encode(),True)
            except (Pending,OSError,ValueError,subprocess.SubprocessError)as error:
                cert_error=error if isinstance(error,Pending)else Pending('certificate_pending',3600);atomic(private/'certificate-backoff.json',json.dumps({'until':time.time()+cert_error.seconds,'category':cert_error.category}).encode())
        else:atomic(state/'ready.json',json.dumps({'schema':1,'server_host':server,'key_hash':key_hash,'aliases':{}}).encode(),True)
        for row,error,delay in changed:
            if until and row in active:row['state']='ready';row['certificate_not_after']=until;error='';delay=86400
            elif cert_error and row in active:
                row['state']='ready'if row['hostname']in old_ready and dt.datetime.fromisoformat(old_ready[row['hostname']]).timestamp()>time.time()else'pending_tls';error=cert_error.category;delay=cert_error.seconds
            bridge(b,'record',{k:row[k]for k in ['domain_uuid','hostname','server_host','key_hash','revision','state','certificate_not_after']}|{'error_category':error,'retry_seconds':delay})
        return {'state':'complete','processed':len(changed),'ready':len(active)if until else 0,'pending':sum(row['state']!='ready'for row,_,_ in changed)}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--move-host',action='store_true');parser.add_argument('--confirm-server');args=parser.parse_args()
    try:print(json.dumps(run(args.move_host,args.confirm_server)))
    except Exception as error:
        # Never print provider replies, paths, key material or certificate logs.
        print(json.dumps({'state':'deferred','error_type':type(error).__name__}),file=sys.stderr);raise SystemExit(1)
