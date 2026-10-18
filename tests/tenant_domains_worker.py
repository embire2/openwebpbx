"""Actual protocol/FS/TLS controls; all endpoints and certificates are owned fixtures."""
from pathlib import Path
import datetime as dt,importlib.util,json,os,socket,ssl,subprocess,tempfile,time,unittest
from unittest.mock import patch
from types import SimpleNamespace
from cryptography import x509
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
w=load('tenant_worker',ROOT/'packaging/debian/tenant-domains.py')
i=load('tenant_installer',ROOT/'packaging/debian/install-tenant-domains.py')
class Worker(unittest.TestCase):
 def setUp(self):self.tmp=tempfile.TemporaryDirectory(prefix='openweb-domain-worker-');self.path=Path(self.tmp.name)
 def tearDown(self):self.tmp.cleanup()
 def test_key_exact_reuse_and_private_storage(self):
  key=self.path/'instance.pem';a=w.identity(key);original=key.read_bytes();b=w.identity(key);self.assertEqual(a[1:],b[1:]);self.assertEqual(original,key.read_bytes());self.assertEqual(key.stat().st_mode&0o777,0o600)
  os.link(key,self.path/'hardlink');self.assertRaises(ValueError,w.identity,key)
 def test_atomic_failure_and_parent_immutability(self):
  parent=self.path/'protected';parent.mkdir(mode=0o755);target=parent/'state';target.write_bytes(b'original');mode=parent.stat().st_mode
  with patch.object(w.os,'replace',side_effect=OSError('fictional')):self.assertRaises(OSError,w.atomic,target,b'new')
  self.assertEqual(target.read_bytes(),b'original');self.assertEqual(parent.stat().st_mode,mode);self.assertEqual(list(parent.glob('.tenant-domains-*')),[])
  linked=self.path/'link';linked.symlink_to(parent,target_is_directory=True);self.assertRaises(ValueError,w.atomic,linked/'state',b'bad')
 def test_windows_acl_applied_to_empty_file_before_private_write(self):
  target=self.path/'private';events=[]
  def acl(operation,path):events.append((operation,path.read_bytes()))
  with patch.object(w,'IS_WINDOWS',True),patch.object(w,'WINDOWS_ACL',acl),patch.object(w.os,'fchmod',side_effect=AssertionError('Unix API used')):w.atomic(target,b'private-value')
  self.assertEqual(events,[('FilePrivate',b'')]);self.assertEqual(target.read_bytes(),b'private-value')
  with patch.object(w,'IS_WINDOWS',True),patch.object(w,'WINDOWS_ACL',None):self.assertRaises(ValueError,w.atomic,target,b'new')
  self.assertEqual(target.read_bytes(),b'private-value');self.assertEqual(list(self.path.glob('.tenant-domains-*')),[])
 def test_existing_key_always_delegates_acl(self):
  path=self.path/'key';w.identity(path);seen=[];w.identity(path,lambda op,p:seen.append((op,p)));self.assertEqual(seen,[('KeyAcl',path)])
 def test_signed_lease_proof_and_cleanup(self):
  key,public,digest=w.identity(self.path/'key');row={'tenant_uuid':'11111111-1111-4111-a111-111111111111','domain_uuid':'22222222-2222-4222-a222-222222222222','requested_label':'fictional','desired_enabled':True,'revision':0,'hostname':None};proof=self.path/'proof';proof.mkdir();broker=w.Broker();nonce='a'*64
  def post(route,value,revision=None):
   if route=='/v1/challenges':return {'challenge':nonce}
   self.assertEqual((proof/nonce).read_bytes(),('openwebpbx-instance-v1\n'+nonce+'\n'+digest+'\nserver.example.test\n').encode());signature=__import__('base64').b64decode(value['signature']);key.public_key().verify(signature,w.message(value,digest),ec.ECDSA(hashes.SHA256()))
   return {'hostname':'fictional.openwebpbx.com','serverHost':'server.example.test','state':'dns_ready','enabled':True,'revision':1}
  broker.post=post;reply=broker.lease(row,key,public,digest,'server.example.test',proof);self.assertEqual(reply['revision'],1);self.assertEqual(list(proof.iterdir()),[])
  broker.post=lambda *a,**k:{'challenge':nonce}if a[0]=='/v1/challenges'else (_ for _ in ()).throw(w.Pending('network'))
  self.assertRaises(w.Pending,broker.lease,row,key,public,digest,'server.example.test',proof);self.assertEqual(list(proof.iterdir()),[])
 def test_retry_after_and_maintenance_holds(self):
  self.assertEqual(w.retry_after('120'),120);self.assertEqual(w.retry_after('99999999'),604800);self.assertEqual(w.retry_after('invalid'),300)
  class B:RESTORE=self.path/'restore';STATE=self.path
  B.RESTORE.mkdir();self.assertFalse(w.blocked(B));(B.RESTORE/'hold-jobs').touch();self.assertTrue(w.blocked(B));(B.RESTORE/'hold-jobs').unlink();(B.RESTORE/'journal.json').write_text('{"state":"recovery_required"}');self.assertTrue(w.blocked(B))
  (B.RESTORE/'journal.json').write_text('{"state":"unexpected"}');self.assertTrue(w.blocked(B));(B.RESTORE/'journal.json').unlink();updates=self.path/'updates';updates.mkdir();(updates/'install-journal.json').write_text('{"state":"quiescing"}')
  with patch.object(w,'STATE_ROOT',self.path):self.assertTrue(w.blocked(B))
 def test_actual_worker_sequence_and_held_restore_without_external_calls(self):
  actual=load('real_backup_guard',ROOT/'packaging/debian/backups.py');restore=self.path/'restore';restore.mkdir();config=self.path/'fusionpbx/config.conf';config.parent.mkdir();lock=self.path/'upgrade.lock';lock.touch(mode=0o600)
  b=SimpleNamespace(RESTORE=restore,CONFIG=config,WEB_VERSION=self.path/'web/VERSION',UPGRADE_LOCK=lock,exclusive_guard=actual.exclusive_guard)
  spec=SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module:self.assertIs(module,b)))
  row={'tenant_uuid':'11111111-1111-4111-a111-111111111111','domain_uuid':'22222222-2222-4222-a222-222222222222','requested_label':'fictional','desired_enabled':True,'revision':0,'hostname':None,'key_hash':'','state':'pending','certificate_not_after':None}
  records=[];initial={'server_host':'server.example.test','contact_email':'operator@example.invalid','inventory':[row.copy()],'aliases':[row.copy()]}
  def bridge(b,operation,value=None):
   if operation=='discover':return initial
   records.append(value);return {}
  expiry=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=60)).isoformat()
  with patch.object(w.importlib.util,'spec_from_file_location',return_value=spec),patch.object(w.importlib.util,'module_from_spec',return_value=b),patch.object(w,'STATE_ROOT',self.path/'state'),patch.object(w,'bridge',side_effect=bridge)as ipc,patch.object(w.Broker,'lease',return_value={'hostname':'fictional.openwebpbx.com','serverHost':'server.example.test','enabled':True,'state':'dns_ready','revision':1})as lease,patch.object(w,'certify',return_value=expiry)as certificate:
   (restore/'hold-jobs').touch();self.assertEqual(w.run()['state'],'deferred');ipc.assert_not_called();self.assertFalse((config.parent/'tenant-domains-instance-key.pem').exists());(restore/'hold-jobs').unlink()
   result=w.run();self.assertEqual(result,{'state':'complete','processed':1,'ready':1,'pending':0});lease.assert_called_once();certificate.assert_called_once();self.assertEqual(records[0]['state'],'ready');self.assertEqual(records[0]['revision'],1)
   ready=self.path/'state/tenant-domains/ready.json';self.assertEqual(ready.stat().st_mode&0o777,0o640);self.assertEqual(json.loads(ready.read_text())['aliases'],{'fictional.openwebpbx.com':expiry});self.assertEqual((config.parent/'tenant-domains-instance-key.pem').stat().st_mode&0o777,0o600)
 def test_windows_exact_once_delegate_and_closed_retry_projection(self):
  b=SimpleNamespace(APP=Path('C:/OpenWebPBX'),native_powershell_environment=lambda:{'owned':'environment'})
  with patch.object(w.subprocess,'run',return_value=subprocess.CompletedProcess([],0,b'{"prepared":true}',b''))as delegate:
   self.assertEqual(w.windows(b,'Prepare',self.path),{'prepared':True});delegate.assert_called_once();args=delegate.call_args.args[0];self.assertEqual(args[-4:],['-Operation','Prepare','-InputFile',str(self.path)]);self.assertEqual(delegate.call_args.kwargs['env'],{'owned':'environment'})
  with patch.object(w.subprocess,'run',return_value=subprocess.CompletedProcess([],1,b'',b'{"error_category":"rate_limited","retry_seconds":7200}')):
   with self.assertRaises(w.Pending)as caught:w.windows(b,'Certify',self.path)
   self.assertEqual((caught.exception.category,caught.exception.seconds),('rate_limited',7200))
 def test_windows_restore_instance_key_has_exact_private_classification(self):
  backup=load('tenant_windows_backup',ROOT/'packaging/windows/backups.py');root=backup.ROOTS['fusionpbx-config']
  self.assertEqual(backup.acl_kind(root/'tenant-domains-instance-key.pem'),'private')
  for name in ['config.conf','openweb-template.key','tenant-domains-instance-key.pem.other']:
   self.assertEqual(backup.acl_kind(root/name),'config')
 def test_certificate_san_batch_changes_and_rate_limit_have_no_retry_loop(self):
  private=self.path/'private';private.mkdir();names=['qa-two.openwebpbx.com','qa-one.openwebpbx.com'];calls=[]
  def issue(args,**kwargs):calls.append(args);kwargs['stdout'].write(b'fictional rate limit\nRetry-After: 7200\n');return subprocess.CompletedProcess(args,1)
  with patch.object(w,'certificate_info',side_effect=FileNotFoundError()),patch.object(w,'install_nginx'),patch.object(w.subprocess,'run',side_effect=issue):
   with self.assertRaises(w.Pending)as caught:w.certify(names,'a'*64,private,'operator@example.invalid',None)
  self.assertEqual((caught.exception.category,caught.exception.seconds),('rate_limited',7200));self.assertEqual(len(calls),1);self.assertIn('--renew-with-new-domains',calls[0]);self.assertNotIn('--force-renewal',calls[0]);self.assertEqual(calls[0][-2:],['--domains',','.join(sorted(names))])
 def test_installer_real_file_idempotence_failure_and_foreign_refusal(self):
  package=self.path/'package';package.mkdir();tools=self.path/'tools';units=self.path/'units';units.mkdir();site=self.path/'site';site.write_text('server {\n server_name server.example.test;\n root /var/www/fusionpbx;\n}\nserver {\n server_name server.example.test;\n root /var/www/fusionpbx;\n}\n');snippet=self.path/'snippet'
  files=[*i.PROGRAMS,'openwebpbx-tenant-domains.service','openwebpbx-tenant-domains.timer'];manifest={}
  import hashlib
  for name in files:data=(ROOT/'packaging/debian'/name).read_bytes();(package/name).write_bytes(data);manifest[name]=hashlib.sha256(data).hexdigest()
  (package/'release-manifest.json').write_text(json.dumps({'files':manifest}));calls=[]
  def command(args,**kw):calls.append(args);return subprocess.CompletedProcess(args,0)
  with patch.multiple(i,PACKAGE=package,TOOLS=tools,STATE=self.path/'state',SITE=site,HOSTED=self.path/'missing',SNIPPET=snippet,UNIT=units/'openwebpbx-tenant-domains.service',TIMER=units/'openwebpbx-tenant-domains.timer',LINKS=[]),patch.object(i.subprocess,'run',side_effect=command):
   old=site.read_bytes();i.install();once=site.read_bytes();self.assertEqual(once.count(i.INCLUDE.encode()),2);self.assertFalse((self.path/'state').exists());self.assertFalse(any(c[:2]==['systemctl','reload']for c in calls));i.install();self.assertEqual(site.read_bytes(),once);self.assertEqual(sum(c[:2]==['systemctl','enable']for c in calls),1)
   i.install(True);self.assertTrue((self.path/'state/proofs/.well-known/openwebpbx-instance').is_dir());self.assertIn(['systemctl','reload','nginx'],calls)
   state_before=(self.path/'state').stat();calls.clear();i.install();self.assertEqual((self.path/'state').stat().st_mtime_ns,state_before.st_mtime_ns);self.assertFalse(any(c[:2]==['systemctl','reload']for c in calls))
   site.write_bytes(old)
   def fail(args,**kw):
    if args==['nginx','-t']:raise subprocess.CalledProcessError(1,args)
    return subprocess.CompletedProcess(args,0)
   with patch.object(i.subprocess,'run',side_effect=fail):self.assertRaises(subprocess.CalledProcessError,i.install)
   self.assertEqual(site.read_bytes(),old);site.write_text('foreign website');self.assertRaises(ValueError,i.install)
 def test_actual_ipv4_ipv6_tls_and_exact_portal_redirects(self):
  names=['qa-worker-one.openwebpbx.com','qa-worker-two.openwebpbx.com'];key=ec.generate_private_key(ec.SECP256R1());now=dt.datetime.now(dt.timezone.utc);subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,names[0])]);cert=x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-dt.timedelta(minutes=1)).not_valid_after(now+dt.timedelta(days=2)).add_extension(x509.SubjectAlternativeName([x509.DNSName(n)for n in names]),False).sign(key,hashes.SHA256());certpath=self.path/'cert.pem';keypath=self.path/'key.pem';certpath.write_bytes(cert.public_bytes(serialization.Encoding.PEM));keypath.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()));until,_=w.certificate_info(certpath,keypath,names);self.assertGreater(until,now);self.assertRaises(ValueError,w.certificate_info,certpath,keypath,['unknown.openwebpbx.com'])
  sockets=[]
  for family,host in [(socket.AF_INET,'127.0.0.1'),(socket.AF_INET6,'::1'),(socket.AF_INET,'127.0.0.1'),(socket.AF_INET6,'::1')]:
   s=socket.socket(family);s.bind((host,0));sockets.append(s)
  port4,port6,http4,http6=[s.getsockname()[1]for s in sockets]
  for s in sockets:s.close()
  rendered=w.nginx(names,'/etc/letsencrypt/live/openwebpbx-tenants-'+'a'*12+'/fullchain.pem','/etc/letsencrypt/live/openwebpbx-tenants-'+'a'*12+'/privkey.pem').decode()
  # Isolate only ports/paths; execute the actual rendered TLS/location rules.
  rendered=rendered.replace('listen 80; listen [::]:80;',f'listen 127.0.0.1:{http4}; listen [::1]:{http6};').replace('listen 443 ssl; listen [::]:443 ssl;',f'listen 127.0.0.1:{port4} ssl; listen [::1]:{port6} ssl;').replace('/etc/letsencrypt/live/openwebpbx-tenants-'+'a'*12+'/fullchain.pem',str(certpath)).replace('/etc/letsencrypt/live/openwebpbx-tenants-'+'a'*12+'/privkey.pem',str(keypath)).replace('include /etc/nginx/snippets/openweb-meet.conf;','').replace('include fastcgi_params;',f'include /etc/nginx/fastcgi_params;')
  config=self.path/'nginx.conf';config.write_text(f'pid {self.path}/nginx.pid; error_log {self.path}/nginx.log; events {{}} http {{ access_log off; {rendered} }}');process=subprocess.Popen(['nginx','-c',str(config),'-g','daemon off;'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  try:
   context=ssl.create_default_context(cafile=str(certpath));deadline=time.monotonic()+5
   while True:
    try:probe=socket.create_connection(('127.0.0.1',port4),timeout=.1);probe.close();break
    except OSError:
     if time.monotonic()>deadline:raise AssertionError('Owned Nginx did not start: '+process.stderr.read().decode())
     time.sleep(.05)
   for host,port in [('127.0.0.1',port4),('::1',port6)]:
    for name in names:
     for route,target in [('/','/app/pbx_mobile/user.php'),('/admin','/tenantadmin/'),('/admin/','/tenantadmin/'),('/?path=%2Ftenantadmin%2F','/login.php?path=%2Ftenantadmin%2F')]:
      with socket.create_connection((host,port),timeout=3)as raw:
       with context.wrap_socket(raw,server_hostname=name)as secure:
        secure.sendall(f'GET {route} HTTP/1.1\r\nHost: {name}\r\nConnection: close\r\n\r\n'.encode());response=b''
        while chunk:=secure.recv(8192):response+=chunk
      self.assertIn(b'302',response.split(b'\r\n',1)[0]);self.assertIn(('Location: https://'+name+':'+str(port)+target).encode(),response)
  finally:
   process.terminate();process.wait(timeout=5);process.stderr.close()
if __name__=='__main__':unittest.main()
