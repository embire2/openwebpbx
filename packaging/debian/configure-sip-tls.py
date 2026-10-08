#!/usr/bin/env python3
"""Install trusted phone TLS certificates; never log private certificate material."""
import argparse,fcntl,grp,hashlib,json,os,re,shutil,socket,ssl,subprocess,tempfile,time
from pathlib import Path
from upgrade import engine_api,read_settings,check_idle
ROOT=Path(__file__).resolve().parent
TLS=Path('/etc/freeswitch/tls')
STATE=Path('/etc/openwebpbx/sip-tls.json')
CA=Path('/etc/ssl/certs/ca-certificates.crt')

def openssl(*arguments,input=None):
 result=subprocess.run(['openssl',*map(str,arguments)],input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if result.returncode:raise ValueError('Certificate validation failed. Check the trusted chain, hostname, validity and matching private key.')
 return result.stdout

def certificates(content):
 return re.findall(b'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',content,re.S)

def chain_store(fullchain,roots):
 # Sofia builds its sent chain from the trust store. Keep the administrator's
 # supplied cross-signing path instead of substituting a same-key self-signed
 # root which older Android versions may not trust.
 intermediates=certificates(fullchain)[1:]
 def identity(certificate):return openssl('x509','-noout','-subject','-pubkey',input=certificate)
 supplied={identity(certificate) for certificate in intermediates}
 retained=[certificate for certificate in certificates(roots) if identity(certificate) not in supplied]
 return b'\n'.join(intermediates+retained)+b'\n'

def chain_fingerprints(content):
 return [hashlib.sha256(openssl('x509','-outform','DER',input=certificate)).digest() for certificate in certificates(content)]

def validate(domain,fullchain,key):
 if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?',domain):raise ValueError('Use the public DNS hostname of this PBX.')
 if not fullchain.is_file() or not key.is_file() or key.stat().st_uid!=0 or key.stat().st_mode&0o007:raise ValueError('The certificate and a root-owned private key without public access are required.')
 if fullchain.stat().st_size>1024*1024 or key.stat().st_size>65536:raise ValueError('Certificate files exceed the expected size.')
 openssl('x509','-in',fullchain,'-noout','-checkhost',domain)
 openssl('x509','-in',fullchain,'-noout','-checkend','86400')
 if openssl('x509','-in',fullchain,'-pubkey','-noout')!=openssl('pkey','-in',key,'-passin','pass:','-pubout'):raise ValueError('The certificate does not match the private key.')
 with tempfile.TemporaryDirectory(prefix='openweb-cert-') as folder:
  leaf=Path(folder)/'leaf.pem';leaf.write_bytes(openssl('x509','-in',fullchain))
  openssl('verify','-purpose','sslserver','-verify_hostname',domain,'-CAfile',CA,'-untrusted',fullchain,leaf)
 return hashlib.sha256(openssl('x509','-in',fullchain,'-outform','DER')).digest()

def atomic(path,content,gid=0,mode=0o600):
 with tempfile.NamedTemporaryFile(prefix='.openweb-tls-',dir=path.parent,delete=False) as handle:
  temporary=Path(handle.name);handle.write(content)
 try:temporary.chmod(mode);os.chown(temporary,0,gid);os.replace(temporary,path)
 finally:temporary.unlink(missing_ok=True)

def profiles(action):
 result=subprocess.run(['php',str(ROOT/'configure-sip-tls.php'),action],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if result.returncode:raise RuntimeError('The phone profile settings could not be read or updated.')
 return json.loads(result.stdout)

def ready_flag(ready):
 path=Path('/etc/fusionpbx/config.conf');lines=path.read_text().splitlines()
 lines=[line for line in lines if not re.match(r'^\s*openweb\.mobile_tls_ready\s*=',line)]
 lines.append('openweb.mobile_tls_ready = '+('true' if ready else 'false'))
 atomic(path,('\n'.join(lines)+'\n').encode(),path.stat().st_gid,path.stat().st_mode&0o777)

def verify_listener(settings,profile,domain,fingerprint,expected_chain=None):
 status=engine_api(settings,'sofia status profile '+profile)
 match=re.search(r'^SIP-IP\s+(\S+)',status,re.M)
 if not match:return False
 address=match.group(1).strip('[]')
 try:
  with socket.create_connection((address,5061),timeout=3) as transport:
   with ssl.create_default_context().wrap_socket(transport,server_hostname=domain) as secure:
    if hashlib.sha256(secure.getpeercert(binary_form=True)).digest()!=fingerprint:return False
  if expected_chain:
   endpoint=('['+address+']' if ':' in address else address)+':5061'
   response=subprocess.run(['openssl','s_client','-connect',endpoint,'-servername',domain,
       '-showcerts','-verify_return_error','-verify_hostname',domain,'-CAfile',str(CA)],
       input=b'',stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=6)
   if response.returncode or chain_fingerprints(response.stdout)[:len(expected_chain)]!=expected_chain:return False
  return True
 except (OSError,ssl.SSLError,subprocess.TimeoutExpired,ValueError):return False

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--domain');parser.add_argument('--fullchain',type=Path);parser.add_argument('--private-key',type=Path)
 parser.add_argument('--renew',action='store_true');parser.add_argument('--check',action='store_true')
 args=parser.parse_args()
 if os.geteuid()!=0:parser.error('Run as root.')
 os.umask(0o077)
 lock=Path('/run/openwebpbx-sip-tls.lock').open('a')
 try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:raise RuntimeError('A phone certificate update is already running.') from None
 if args.renew:
  saved=json.loads(STATE.read_text());args.domain=saved['domain'];args.fullchain=Path(saved['fullchain']);args.private_key=Path(saved['private_key'])
 if not all([args.domain,args.fullchain,args.private_key]):parser.error('Supply --domain, --fullchain and --private-key, or use --renew after configuration.')
 fingerprint=validate(args.domain,args.fullchain,args.private_key)
 expected_chain=chain_fingerprints(args.fullchain.read_bytes())
 trust_store=chain_store(args.fullchain.read_bytes(),CA.read_bytes())
 settings=read_settings();names=profiles('profiles')
 if args.check:
  print('Trusted certificate, matching key and enabled phone profiles verified. No changes made.');return
 existing=(TLS/'cafile.pem').is_file() and (TLS/'cafile.pem').read_bytes()==trust_store and all(verify_listener(settings,name,args.domain,fingerprint,expected_chain) for name in names)
 if args.renew and existing:return
 # A first TLS listener requires a profile restart. Certificate renewal uses the
 # native reloadcert event first and verifies its actual presented fingerprint.
 if not args.renew:check_idle(settings)
 group=subprocess.check_output(['systemctl','show','freeswitch','--property=Group','--value'],text=True).strip() or 'www-data'
 gid=grp.getgrnam(group).gr_gid
 if TLS.is_symlink():raise ValueError('The phone certificate directory must not be a symbolic link.')
 TLS.mkdir(parents=True,exist_ok=True);TLS.chmod(0o750);os.chown(TLS,0,gid)
 previous=(TLS/'agent.pem').read_bytes() if (TLS/'agent.pem').is_file() else None
 previous_ca=(TLS/'cafile.pem').read_bytes() if (TLS/'cafile.pem').is_file() else None
 atomic(TLS/'agent.pem',args.private_key.read_bytes().rstrip()+b'\n'+args.fullchain.read_bytes(),gid,0o640)
 # This Sofia build loads the leaf using SSL_CTX_use_certificate_file, then
 # builds its sent chain from the trust store. Retain the system roots and add
 # the supplied intermediate certificates so Android receives the full chain.
 atomic(TLS/'cafile.pem',trust_store,gid,0o640)
 try:
  names=profiles('configure');engine_api(settings,'reloadxml')
  if args.renew:engine_api(settings,'reloadcert')
  for attempt in range(8):
   if all(verify_listener(settings,name,args.domain,fingerprint,expected_chain) for name in names):break
   if not args.renew:break
   time.sleep(1)
  if not all(verify_listener(settings,name,args.domain,fingerprint,expected_chain) for name in names):
   check_idle(settings)
   for name in names:
    response=engine_api(settings,'sofia profile '+name+' restart')
    if '-ERR' in response:raise RuntimeError('The phone profile could not restart; retry during an idle maintenance window.')
   for attempt in range(30):
    if all(verify_listener(settings,name,args.domain,fingerprint,expected_chain) for name in names):break
    time.sleep(1)
   else:raise RuntimeError('The phone TLS listeners did not present the trusted certificate.')
 except BaseException:
  # Preserve the last known certificate if an idle restart is not possible.
  if previous is not None:atomic(TLS/'agent.pem',previous,gid,0o640)
  if previous_ca is not None:atomic(TLS/'cafile.pem',previous_ca,gid,0o640)
  if not args.renew:ready_flag(False)
  raise
 ready_flag(True)
 STATE.parent.mkdir(parents=True,exist_ok=True)
 atomic(STATE,json.dumps({'domain':args.domain,'fullchain':str(args.fullchain.absolute()),'private_key':str(args.private_key.absolute())}).encode())
 installed=Path('/opt/openwebpbx/tools');installed.mkdir(parents=True,exist_ok=True);installed.chmod(0o755)
 for name in ['configure-sip-tls.py','configure-sip-tls.php','upgrade.py']:
  source=ROOT/name;target=installed/name
  if source.resolve()!=target.resolve():atomic(target,source.read_bytes(),0,0o755 if name.endswith('.py') else 0o644)
 # Retry renewal daily. reloadcert changes only certificate contexts when the
 # compiled engine supports it; the verified fallback restarts idle profiles.
 atomic(Path('/etc/cron.d/openwebpbx-sip-tls'),b'23 4 * * * root /usr/bin/python3 /opt/openwebpbx/tools/configure-sip-tls.py --renew 2>&1 | /usr/bin/logger -t openwebpbx-sip-tls\n',0,0o644)
 subprocess.run(['systemctl','reload','php8.4-fpm'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 print('Trusted phone connections are ready on TCP 5061. Certificate renewal retry is installed.')
 print('Allow TCP 5061 and the configured audio ports in the server/provider firewall for your users.')

if __name__=='__main__':
 try:main()
 except (ValueError,RuntimeError) as error:
  print(str(error));raise SystemExit(1)
 except (OSError,subprocess.CalledProcessError):
  print('Phone TLS setup did not complete. Check certificate paths, private key permissions, enabled profiles and the idle call state.')
  raise SystemExit(1)
