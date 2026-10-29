"""Actual protocol/FS/TLS controls; all endpoints and certificates are owned fixtures."""
from pathlib import Path
import contextlib,datetime as dt,hashlib,importlib.util,json,os,socket,ssl,subprocess,tempfile,threading,time,unittest
from unittest.mock import patch
from types import SimpleNamespace
from cryptography import x509
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID,ExtendedKeyUsageOID
ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
w=load('tenant_worker',ROOT/'packaging/debian/tenant-domains.py')
i=load('tenant_installer',ROOT/'packaging/debian/install-tenant-domains.py')
@contextlib.contextmanager
def readiness_tls(path,names,served):
 now=dt.datetime.now(dt.timezone.utc);key=ec.generate_private_key(ec.SECP256R1());subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Owned readiness CA')]);ca=x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-dt.timedelta(minutes=1)).not_valid_after(now+dt.timedelta(days=2)).add_extension(x509.BasicConstraints(ca=True,path_length=None),True).add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()),False).add_extension(x509.KeyUsage(False,False,False,False,False,True,True,False,False),True).sign(key,hashes.SHA256());cafile=path/'readiness-ca.pem';cafile.write_bytes(ca.public_bytes(serialization.Encoding.PEM));contexts={};digests={}
 for label in ['exact','old','wrong_host','foreign_ca']:
  leafkey=ec.generate_private_key(ec.SECP256R1());leafnames=['other.openwebpbx.com']if label=='wrong_host'else names;issuer=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Foreign CA')])if label=='foreign_ca'else subject
  leaf=x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,leafnames[0])])).issuer_name(issuer).public_key(leafkey.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-dt.timedelta(minutes=1)).not_valid_after(now+dt.timedelta(days=1)).add_extension(x509.SubjectAlternativeName([x509.DNSName(name)for name in leafnames]),False).add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()),False).add_extension(x509.SubjectKeyIdentifier.from_public_key(leafkey.public_key()),False).add_extension(x509.BasicConstraints(ca=False,path_length=None),True).add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),False).sign(ec.generate_private_key(ec.SECP256R1())if label=='foreign_ca'else key,hashes.SHA256());certfile=path/(label+'.pem');keyfile=path/(label+'.key');certfile.write_bytes(leaf.public_bytes(serialization.Encoding.PEM));keyfile.write_bytes(leafkey.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()));server=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);server.load_cert_chain(certfile,keyfile);contexts[label]=server;digests[label]=hashlib.sha256(leaf.public_bytes(serialization.Encoding.DER)).hexdigest()
 client=ssl.create_default_context(cafile=str(cafile));listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(.05);port=listener.getsockname()[1];stop=threading.Event();seen=[]
 def serve():
  while not stop.is_set():
   try:raw,_=listener.accept()
   except socket.timeout:continue
   except OSError:break
   label=served[min(len(seen),len(served)-1)];seen.append(label)
   with raw:
    try:
     with contexts[label].wrap_socket(raw,server_side=True):pass
    except ssl.SSLError:pass
 thread=threading.Thread(target=serve,daemon=True);thread.start()
 try:yield client,port,digests,seen
 finally:stop.set();listener.close();thread.join(timeout=2);assert not thread.is_alive()
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
  with patch.object(w.importlib.util,'spec_from_file_location',return_value=spec),patch.object(w.importlib.util,'module_from_spec',return_value=b),patch.object(w,'STATE_ROOT',self.path/'state'),patch.object(w,'bridge',side_effect=bridge)as ipc,patch.object(w,'onboarding',return_value={}),patch.object(w.Broker,'lease',return_value={'hostname':'fictional.openwebpbx.com','serverHost':'server.example.test','enabled':True,'state':'dns_ready','revision':1})as lease,patch.object(w,'certify',return_value=expiry)as certificate:
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
  with patch.object(w,'ACME_ROOT',self.path/'acme'),patch.object(w,'certificate_info',side_effect=FileNotFoundError()),patch.object(w,'install_nginx'),patch.object(w.subprocess,'run',side_effect=issue):
   with self.assertRaises(w.Pending)as caught:w.certify(names,'a'*64,private,'operator@example.invalid',None)
  self.assertEqual((caught.exception.category,caught.exception.seconds),('rate_limited',7200));self.assertEqual(len(calls),1);self.assertIn('--renew-with-new-domains',calls[0]);self.assertNotIn('--force-renewal',calls[0]);self.assertEqual(calls[0][-2:],['--domains',','.join(sorted(names))])
 def test_managed_acme_actual_service_uid_and_http_without_legacy_changes(self):
  self.path.chmod(0o755);state=w.directory(self.path/'tenant-domains',True);acme=state/'acme';private=w.directory(state/'private');legacy=self.path/'legacy';legacy.mkdir(mode=0o700)
  legacy_challenge=legacy/'.well-known/acme-challenge';legacy_challenge.mkdir(parents=True);token='owned-challenge';body=b'owned-http01-key-authorization';(legacy_challenge/token).write_bytes(body);before=(legacy.stat().st_mode,legacy.stat().st_uid,legacy.stat().st_gid)
  names=['qa-acme.openwebpbx.com'];rendered=[];commands=[]
  def issue(args,**kwargs):
   commands.append(args);self.assertEqual(args[args.index('--webroot-path')+1],str(acme))
   for path in [acme,acme/'.well-known',acme/'.well-known/acme-challenge']:
    self.assertEqual((path.stat().st_mode&0o777,path.stat().st_uid,path.stat().st_gid),(0o750,0,33))
   w.atomic(acme/'.well-known/acme-challenge'/token,body,True);return subprocess.CompletedProcess(args,1)
  with patch.object(w,'ACME_ROOT',acme),patch.object(w,'certificate_info',side_effect=FileNotFoundError()),patch.object(w,'install_nginx',side_effect=rendered.append),patch.object(w.subprocess,'run',side_effect=issue):
   self.assertRaises(w.Pending,w.certify,names,'a'*64,private,'operator@example.invalid',None)
  self.assertEqual(len(commands),1);self.assertIn(('root '+str(acme)+';').encode(),rendered[0]);self.assertNotIn(str(legacy).encode(),rendered[0])
  read=['/usr/bin/python3','-c','import os,pathlib,sys;assert os.getuid()==33;sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes())']
  actual=subprocess.run([*read,str(acme/'.well-known/acme-challenge'/token)],user=33,group=33,extra_groups=[],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5);self.assertEqual((actual.returncode,actual.stdout),(0,body))
  denied=subprocess.run([*read,str(legacy_challenge/token)],user=33,group=33,extra_groups=[],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5);self.assertNotEqual(denied.returncode,0)
  ports=[]
  for family,host in [(socket.AF_INET,'127.0.0.1'),(socket.AF_INET6,'::1')]:
   with socket.socket(family)as listener:listener.bind((host,0));ports.append(listener.getsockname()[1])
  content=rendered[0].decode().replace('listen 80; listen [::]:80;',f'listen 127.0.0.1:{ports[0]}; listen [::1]:{ports[1]};')
  legacy_content=content.replace(names[0],'qa-legacy.openwebpbx.com').replace(str(acme),str(legacy));config=self.path/'nginx-acme.conf';config.write_text(f'user www-data; worker_processes 1; pid {self.path}/nginx-acme.pid; error_log {self.path}/nginx-acme.log; events {{}} http {{ access_log off; {content}{legacy_content} }}')
  process=subprocess.Popen(['nginx','-c',str(config),'-g','daemon off;'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  try:
   deadline=time.monotonic()+5
   while True:
    try:probe=socket.create_connection(('127.0.0.1',ports[0]),timeout=.1);probe.close();break
    except OSError:
     if time.monotonic()>deadline:raise AssertionError('Owned ACME Nginx did not start.')
     time.sleep(.05)
   children=Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split();self.assertTrue(children);self.assertTrue(all(Path('/proc') .joinpath(pid).stat().st_uid==33 for pid in children))
   for host,port in [('127.0.0.1',ports[0]),('::1',ports[1])]:
    for name,status in [(names[0],b'200'),('qa-legacy.openwebpbx.com',b'404')]:
     with socket.create_connection((host,port),timeout=3)as stream:
      stream.sendall(f'GET /.well-known/acme-challenge/{token} HTTP/1.1\r\nHost: {name}\r\nConnection: close\r\n\r\n'.encode());response=b''
      while chunk:=stream.recv(8192):response+=chunk
     self.assertIn(status,response.split(b'\r\n',1)[0]);self.assertEqual(response.split(b'\r\n\r\n',1)[1],body)if status==b'200'else self.assertNotIn(body,response)
  finally:process.terminate();process.wait(timeout=5);process.stderr.close()
  self.assertEqual((legacy.stat().st_mode,legacy.stat().st_uid,legacy.stat().st_gid),before);self.assertEqual((legacy_challenge/token).read_bytes(),body)
 def test_managed_acme_link_and_unprotected_parent_refuse_before_http_or_certbot(self):
  private=self.path/'private';private.mkdir();outside=self.path/'outside';outside.mkdir();acme=self.path/'acme';acme.symlink_to(outside,target_is_directory=True)
  for prepare in [lambda:None,lambda:(acme.unlink(),acme.mkdir(mode=0o777),acme.chmod(0o777))]:
   prepare()
   with patch.object(w,'ACME_ROOT',acme),patch.object(w,'certificate_info',side_effect=FileNotFoundError()),patch.object(w,'install_nginx')as http,patch.object(w.subprocess,'run')as certbot:
    self.assertRaises(ValueError,w.certify,['qa-acme.openwebpbx.com'],'a'*64,private,'operator@example.invalid',None);http.assert_not_called();certbot.assert_not_called()
  self.assertEqual(list(outside.iterdir()),[])
 def test_readiness_actual_tls_delayed_old_certificate_then_exact_all_names(self):
  names=['qa-ready-one.openwebpbx.com','qa-ready-two.openwebpbx.com'];connect=socket.create_connection;attempts=[]
  with readiness_tls(self.path,names,['old','exact'])as(context,port,digests,seen):
   self.assertTrue(context.check_hostname);self.assertEqual(context.verify_mode,ssl.CERT_REQUIRED)
   def local(address,timeout):
    self.assertEqual(address,('127.0.0.1',443));self.assertGreater(timeout,0);self.assertLessEqual(timeout,1);attempts.append(timeout);return connect(('127.0.0.1',port),timeout=timeout)
   with patch.object(w.socket,'create_connection',side_effect=local),patch.object(w.ssl,'create_default_context',return_value=context):w.wait_https_certificate(names,digests['exact'])
   self.assertEqual(seen,['old','exact','exact']);self.assertEqual(len(attempts),3)
 def test_readiness_actual_tls_permanent_ca_hostname_and_digest_fail_at_deadline(self):
  name='qa-ready.openwebpbx.com';connect=socket.create_connection
  for label in ['foreign_ca','wrong_host','old']:
   with self.subTest(label=label),readiness_tls(self.path,[name],[label])as(context,port,digests,seen):
    clock=[0.0];sleeps=[]
    def sleep(seconds):self.assertGreater(seconds,0);self.assertLessEqual(seconds,.2);sleeps.append(seconds);clock[0]=round(clock[0]+seconds,9)
    def local(address,timeout):self.assertEqual(address,('127.0.0.1',443));self.assertGreater(timeout,0);self.assertLessEqual(timeout,min(1,10-clock[0]));return connect(('127.0.0.1',port),timeout=timeout)
    with patch.object(w.time,'monotonic',side_effect=lambda:clock[0]),patch.object(w.time,'sleep',side_effect=sleep),patch.object(w.socket,'create_connection',side_effect=local),patch.object(w.ssl,'create_default_context',return_value=context):
     with self.assertRaises(w.Pending)as caught:w.wait_https_certificate([name],digests['exact'])
    self.assertEqual(caught.exception.category,'certificate_pending');self.assertEqual(clock[0],10);self.assertEqual(len(seen),len(sleeps));self.assertGreater(len(seen),1);self.assertTrue(context.check_hostname);self.assertEqual(context.verify_mode,ssl.CERT_REQUIRED)
 def test_readiness_connect_and_handshake_share_overall_deadline(self):
  clock=[0.0];timeouts=[];handshakes=[];sleeps=[]
  class Raw:
   def __enter__(self):return self
   def __exit__(self,*args):pass
   def settimeout(self,seconds):self.timeout=seconds;timeouts.append(seconds)
  def connect(address,timeout):self.assertEqual(address,('127.0.0.1',443));self.assertGreater(timeout,0);self.assertLessEqual(timeout,min(1,10-clock[0]));clock[0]+=min(.75,timeout);return Raw()
  def handshake(raw,server_hostname):self.assertEqual(server_hostname,'qa-ready.openwebpbx.com');self.assertLessEqual(raw.timeout,10-clock[0]);handshakes.append(raw.timeout);clock[0]+=raw.timeout;raise TimeoutError('owned handshake timeout')
  def sleep(seconds):self.assertGreater(seconds,0);self.assertLessEqual(seconds,.2);sleeps.append(seconds);clock[0]=round(clock[0]+seconds,9)
  with patch.object(w.time,'monotonic',side_effect=lambda:clock[0]),patch.object(w.time,'sleep',side_effect=sleep),patch.object(w.socket,'create_connection',side_effect=connect),patch.object(w.ssl,'create_default_context',return_value=SimpleNamespace(wrap_socket=handshake)):
   with self.assertRaises(w.Pending)as caught:w.wait_https_certificate(['qa-ready.openwebpbx.com'],'a'*64)
  self.assertEqual(caught.exception.category,'certificate_pending');self.assertEqual(clock[0],10);self.assertTrue(handshakes);self.assertEqual(timeouts,handshakes);self.assertTrue(sleeps)
 def test_certify_reuse_reloads_before_exact_readiness_and_does_not_mark_success_on_failure(self):
  names=['qa-ready.openwebpbx.com'];until=dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=60);events=[]
  def ready(actual,digest):self.assertEqual((actual,digest),(names,'a'*64));events.append('readiness');raise w.Pending('certificate_pending')
  with patch.object(w,'certificate_info',return_value=(until,'a'*64)),patch.object(w,'install_nginx',side_effect=lambda content:events.append('reload')),patch.object(w,'wait_https_certificate',side_effect=ready),patch.object(w.subprocess,'run')as certbot:
   self.assertRaises(w.Pending,w.certify,names,'a'*64,self.path,'operator@example.invalid',None);certbot.assert_not_called()
  self.assertEqual(events,['reload','readiness'])
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
 def test_actual_fresh_and_hosted_templates_directives_and_comment_refusals(self):
  site=self.path/'site';fresh=(ROOT/'packaging/debian/nginx.conf').read_text().replace('@DOMAIN@','server.example.test')
  hosted='server {\n listen 80;\n listen [::]:80;\n server_name server.example.test;\n}\nserver {\n listen [::]:443 ssl;\n listen 443 ssl;\n #listen 443 ssl http2;\n server_name server.example.test;\n root /var/www/fusionpbx/public;\n}\n'
  with patch.multiple(i,SITE=site,HOSTED=self.path/'missing'):
   for original in [fresh,hosted]:
    site.write_text(original);_,result=i.site_content();self.assertEqual(result.count(i.INCLUDE),2);self.assertEqual(result.replace('\n '+i.INCLUDE,''),original);site.write_text(result);self.assertEqual(i.site_content()[1],result)
   for bad in [fresh.replace('server_name server.example.test;','server_name foreign.example.test;',1),fresh.replace('server.example.test','*.example.test'),fresh+'server { server_name third.example.test; }',fresh.replace('root /var/www/fusionpbx;','# root /var/www/fusionpbx;'),fresh.replace('server_name server.example.test;','# server_name server.example.test;'),fresh.replace('listen 80; server_name','listen [::]:80; server_name'),fresh.replace('server_name server.example.test;','server_name server.example.test;\n '+i.INCLUDE,1)]:
    site.write_text(bad);self.assertRaises(ValueError,i.site_content);self.assertEqual(site.read_text(),bad)
 def test_installed_activation_without_package_inputs_and_closed_refusals(self):
  package=self.path/'package';package.mkdir();tools=self.path/'tools';units=self.path/'units';units.mkdir();site=self.path/'site';site.write_text('server {\n server_name server.example.test;\n root /var/www/fusionpbx;\n}\nserver {\n server_name server.example.test;\n root /var/www/fusionpbx;\n}\n');snippet=self.path/'proof.conf';calls=[]
  names=[*i.PROGRAMS,'openwebpbx-tenant-domains.service','openwebpbx-tenant-domains.timer'];manifest={}
  for name in names:data=(ROOT/'packaging/debian'/name).read_bytes();(package/name).write_bytes(data);manifest[name]=hashlib.sha256(data).hexdigest()
  (package/'release-manifest.json').write_text(json.dumps({'files':manifest}))
  def command(args,**kw):calls.append(args);return subprocess.CompletedProcess(args,0)
  with patch.multiple(i,PACKAGE=package,TOOLS=tools,STATE=self.path/'state',SITE=site,HOSTED=self.path/'missing',SNIPPET=snippet,UNIT=units/'openwebpbx-tenant-domains.service',TIMER=units/'openwebpbx-tenant-domains.timer',LINKS=[]),patch.object(i.subprocess,'run',side_effect=command):
   i.install();self.assertFalse((self.path/'state').exists());self.assertFalse((tools/'release-manifest.json').exists());self.assertFalse((tools/i.UNIT.name).exists());self.assertFalse((tools/i.TIMER.name).exists())
   protected=[site,snippet,i.UNIT,i.TIMER,*[tools/name for name in i.PROGRAMS]];before={p:p.read_bytes()for p in protected}
   with patch.object(i,'PACKAGE',tools):
    calls.clear();self.assertRaises(ValueError,i.install);self.assertEqual(calls,[]);self.assertFalse((self.path/'state').exists())
    for path in [tools/i.PROGRAMS[0],i.UNIT,snippet,site]:
     mode=path.stat().st_mode&0o777;path.chmod(0o666);calls.clear()
     try:self.assertRaises(ValueError,i.install,True);self.assertFalse((self.path/'state').exists());self.assertEqual(calls,[])
     finally:path.chmod(mode)
    for path in [i.UNIT,snippet,site]:
     original=path.read_bytes();path.write_bytes(b'foreign configuration');calls.clear()
     try:self.assertRaises(ValueError,i.install,True);self.assertEqual(calls,[]);self.assertFalse((self.path/'state').exists())
     finally:path.write_bytes(original)
    for path,old,new in [(i.UNIT,b'ExecStart=/usr/bin/python3',b'ExecStart=/usr/bin/false'),(i.TIMER,b'OnUnitActiveSec=2min',b'OnUnitActiveSec=3min')]:
     original=path.read_bytes();self.assertIn(old,original);path.write_bytes(original.replace(old,new));calls.clear()
     try:self.assertRaises(ValueError,i.install,True);self.assertEqual(calls,[]);self.assertFalse((self.path/'state').exists())
     finally:path.write_bytes(original)
    helper=tools/i.PROGRAMS[0];original=helper.read_bytes();mode=helper.stat().st_mode&0o777;external=self.path/'external-helper';external.write_bytes(original);helper.unlink();helper.symlink_to(external);calls.clear()
    try:self.assertRaises(ValueError,i.install,True);self.assertEqual(calls,[]);self.assertFalse((self.path/'state').exists())
    finally:helper.unlink();helper.write_bytes(original);helper.chmod(mode)
    os.chown(helper,33,33);calls.clear()
    try:self.assertRaises(ValueError,i.install,True);self.assertEqual(calls,[]);self.assertFalse((self.path/'state').exists())
    finally:os.chown(helper,0,0)
    calls.clear();i.install(True);self.assertTrue((self.path/'state/proofs/.well-known/openwebpbx-instance').is_dir());self.assertIn(['systemctl','restart',i.TIMER.name],calls);self.assertFalse(any(c[:2]==['systemctl','enable']for c in calls));self.assertEqual({p:p.read_bytes()for p in protected},before)
    calls.clear()
    def disabled(args,**kw):calls.append(args);return subprocess.CompletedProcess(args,1 if args[:2]==['systemctl','is-enabled']else 0)
    with patch.object(i.subprocess,'run',side_effect=disabled):i.install(True)
    self.assertFalse(any(c[:2]in(['systemctl','start'],['systemctl','restart'])for c in calls));self.assertEqual({p:p.read_bytes()for p in protected},before)
   # A missing manifest in an arbitrary directory never selects installed mode.
   (package/'release-manifest.json').unlink();calls.clear();self.assertRaises(FileNotFoundError,i.install,True);self.assertEqual(calls,[])
 def test_actual_stock_template_install_stage_and_activate_with_real_nginx_validation(self):
  package=self.path/'package';package.mkdir();site=self.path/'site';snippet=self.path/'proof.conf';meet=self.path/'meet.conf';meet.write_text('');units=self.path/'units';units.mkdir();tools=self.path/'tools';calls=[];real_run=subprocess.run
  key=ec.generate_private_key(ec.SECP256R1());now=dt.datetime.now(dt.timezone.utc);subject=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'server.example.test')]);certificate=x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-dt.timedelta(minutes=1)).not_valid_after(now+dt.timedelta(days=2)).sign(key,hashes.SHA256());certpath=self.path/'cert.pem';keypath=self.path/'key.pem';certpath.write_bytes(certificate.public_bytes(serialization.Encoding.PEM));keypath.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
  original=(ROOT/'packaging/debian/nginx.conf').read_text().replace('@DOMAIN@','server.example.test').replace('@CERT@',str(certpath)).replace('@KEY@',str(keypath)).replace('/etc/nginx/snippets/openweb-meet.conf',str(meet)).replace('include fastcgi_params;','include /etc/nginx/fastcgi_params;');site.write_text(original);conf=self.path/'nginx.conf';conf.write_text(f'pid {self.path}/nginx.pid;error_log {self.path}/error.log;events {{}}http {{include {site};}}')
  import hashlib
  names=[*i.PROGRAMS,'openwebpbx-tenant-domains.service','openwebpbx-tenant-domains.timer'];manifest={}
  for name in names:data=(ROOT/'packaging/debian'/name).read_bytes();(package/name).write_bytes(data);manifest[name]=hashlib.sha256(data).hexdigest()
  (package/'release-manifest.json').write_text(json.dumps({'files':manifest}))
  def command(args,**kw):
   calls.append(args)
   if args==['nginx','-t']:return real_run(['nginx','-t','-c',str(conf)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
   return subprocess.CompletedProcess(args,0)
  include='include '+str(snippet)+';'
  with patch.multiple(i,PACKAGE=package,TOOLS=tools,STATE=self.path/'state',SITE=site,HOSTED=self.path/'missing',SNIPPET=snippet,INCLUDE=include,UNIT=units/'openwebpbx-tenant-domains.service',TIMER=units/'openwebpbx-tenant-domains.timer',LINKS=[]),patch.object(i.subprocess,'run',side_effect=command):
   i.install();self.assertEqual(site.read_text().count(include),2);self.assertEqual(site.read_text().replace('\n '+include,''),original);self.assertFalse((self.path/'state').exists());self.assertNotIn(['systemctl','reload','nginx'],calls)
   staged=site.read_bytes();i.install();self.assertEqual(site.read_bytes(),staged);i.install(True);self.assertEqual(site.read_bytes(),staged);self.assertTrue((self.path/'state/proofs/.well-known/openwebpbx-instance').is_dir());self.assertIn(['systemctl','reload','nginx'],calls);self.assertEqual(calls.count(['nginx','-t']),3)
   # Execute the installed activation path with real nginx parsing and no
   # package manifest/templates in TOOLS, as on a natural updater restart.
   installed={p:p.read_bytes()for p in [site,snippet,*[tools/name for name in i.PROGRAMS],i.UNIT,i.TIMER]}
   with patch.object(i,'PACKAGE',tools):i.install(True)
   self.assertEqual({p:p.read_bytes()for p in installed},installed);self.assertEqual(calls.count(['nginx','-t']),4)
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
