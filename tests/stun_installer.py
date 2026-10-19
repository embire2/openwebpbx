"""Owned filesystem and process-delegate checks; never installs or starts services."""
import importlib.util,json,os,subprocess,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('stun_installer',ROOT/'packaging/debian/install-stun.py');s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
class Stun(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='openweb-stun-control-');self.root=Path(self.temp.name);self.calls=[];self.binary=True;self.foreign='';self.listener='';self.dropins=''
  self.paths={'UNIT':self.root/'etc/systemd/system/openwebpbx-stun.service','CONFIG':self.root/'etc/openwebpbx-stun.conf','LINK':self.root/'etc/systemd/system/multi-user.target.wants/openwebpbx-stun.service','STATE':self.root/'state','MASK':self.root/'etc/systemd/system/coturn.service','VENDOR_LINK':self.root/'etc/systemd/system/multi-user.target.wants/coturn.service','VENDOR_CONFIGS':[self.root/'etc/turnserver.conf',self.root/'etc/default/coturn']}
  self.mutation=patch.multiple(s,**self.paths);self.mutation.start();self.commands=patch.object(s,'command',side_effect=self.command);self.commands.start();self.which=patch.object(s.shutil,'which',side_effect=lambda name:'/usr/bin/turnserver'if self.binary else None);self.which.start()
 def tearDown(self):self.which.stop();self.commands.stop();self.mutation.stop();self.temp.cleanup()
 def command(self,*args,check=True):
  self.calls.append(args)
  if args[:2]==('systemctl','show'):
   name=args[2];exists=s.UNIT.exists()if name==s.UNIT.name else s.MASK.exists()or s.MASK.is_symlink()
   result={'LoadState':'loaded'if exists else'not-found','ActiveState':'inactive','MainPID':'0','FragmentPath':str(s.UNIT)if name==s.UNIT.name and exists else str(s.MASK)if exists else'','DropInPaths':self.dropins if name==s.UNIT.name else''};return SimpleNamespace(stdout='\n'.join(k+'='+v for k,v in result.items()))
  if args[0]=='ss':return SimpleNamespace(stdout=self.listener)
  if args[0]=='pgrep':return SimpleNamespace(stdout=self.foreign)
  if args[0]=='ip':return SimpleNamespace(stdout=json.dumps([{'addr_info':[{'local':'192.0.2.30'},{'local':'2001:db8::30'}]}]))
  # Actual systemctl disable exits0 but leaves the link while unit is masked.
  return SimpleNamespace(stdout='')
 def install(self,activate=False,package=False):return s.install(['192.0.2.30'],activate,package)
 def test_stage_then_idempotent_then_explicit_activation(self):
  self.assertEqual(self.install()['state'],'staged');paths=[s.UNIT,s.CONFIG,s.STATE/'installation.json'];before={p:(p.read_bytes(),p.stat().st_ino,p.stat().st_mtime_ns,p.stat().st_mode,p.stat().st_uid,p.stat().st_gid)for p in paths};self.calls.clear();self.install()
  self.assertEqual(before,{p:(p.read_bytes(),p.stat().st_ino,p.stat().st_mtime_ns,p.stat().st_mode,p.stat().st_uid,p.stat().st_gid)for p in paths});self.assertFalse(any('enable'in c or'start'in c for c in self.calls));self.assertEqual(self.install(True)['state'],'active');self.assertIn(('systemctl','enable','--now',s.UNIT.name),self.calls)
 def test_preserve_foreign_config_unit_links_and_vendor(self):
  for target in [s.UNIT,s.CONFIG,s.LINK,*s.VENDOR_CONFIGS]:
   with self.subTest(target=target.name):
    target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(b'owned-by-operator');before=target.stat();self.assertRaises(ValueError,self.install);self.assertEqual(target.read_bytes(),b'owned-by-operator');self.assertEqual(target.stat().st_mtime_ns,before.st_mtime_ns);target.unlink()
 def test_foreign_listener_process_dropin_and_nonlocal_ip_refuse(self):
  self.listener='UNCONN 0 0 192.0.2.30:3478 *:* users:(("foreign",pid=123,fd=1))';self.assertRaises(ValueError,self.install);self.listener='';self.foreign='123';self.assertRaises(ValueError,self.install);self.foreign='';self.dropins='/etc/custom.conf';self.assertRaises(ValueError,self.install);self.dropins='';self.assertRaises(ValueError,s.install,['192.0.2.31']);self.assertRaises(ValueError,s.install,['127.0.0.1']);self.assertFalse(s.CONFIG.exists())
 def test_existing_managed_content_changes_or_links_refuse(self):
  self.install();original=s.CONFIG.read_bytes();s.CONFIG.write_bytes(original+b'operator-edit\n');self.assertRaises(ValueError,self.install);self.assertEqual(s.CONFIG.read_bytes(),original+b'operator-edit\n');s.CONFIG.write_bytes(original);s.CONFIG.unlink();outside=self.root/'outside';outside.write_bytes(b'untouched');s.CONFIG.symlink_to(outside);self.assertRaises(ValueError,self.install);self.assertEqual(outside.read_bytes(),b'untouched')
 def test_missing_package_needs_explicit_permission(self):
  self.binary=False;self.assertRaises(ValueError,self.install);self.assertFalse(s.CONFIG.exists());self.assertFalse(s.MASK.exists());self.assertFalse(s.MASK.is_symlink())
 def apt(self,args,**kwargs):
  self.assertTrue(s.MASK.is_symlink());self.assertEqual(os.readlink(s.MASK),'/dev/null');self.assertTrue((s.STATE/'package-transaction.json').is_file())
  if args[:2]==['apt-get','install']:
   self.binary=True;s.VENDOR_LINK.parent.mkdir(parents=True,exist_ok=True);s.VENDOR_LINK.symlink_to('/usr/lib/systemd/system/coturn.service')
  return subprocess.CompletedProcess(args,0)
 def test_package_mask_wraps_apt_then_disables_vendor_and_restores_mask_absence(self):
  self.binary=False
  with patch.object(s.subprocess,'run',side_effect=self.apt)as apt:self.install(package=True)
  self.assertEqual(apt.call_count,2);self.assertFalse(s.MASK.is_symlink());self.assertFalse((s.STATE/'package-transaction.json').exists());self.assertFalse(s.VENDOR_LINK.is_symlink());self.assertIn(('systemctl','disable','coturn.service'),self.calls);self.assertFalse(any('enable'in c for c in self.calls))
 def test_package_failure_recovers_only_own_absent_vendor_mask(self):
  self.binary=False
  def fail(args,**kwargs):self.apt(args,**kwargs);raise subprocess.CalledProcessError(1,args)
  with patch.object(s.subprocess,'run',side_effect=fail):self.assertRaises(subprocess.CalledProcessError,self.install,False,True)
  self.assertFalse(s.MASK.is_symlink());self.assertFalse((s.STATE/'package-transaction.json').exists());self.assertFalse(s.UNIT.exists())
 def journal(self):
  s.STATE.mkdir();s.MASK.parent.mkdir(parents=True);s.MASK.symlink_to('/dev/null');(s.STATE/'package-transaction.json').write_text(json.dumps({'schema':1,'vendor_originally_absent':True,'mask':str(s.MASK)}))
 def test_failed_vendor_disable_retains_mask_and_recovery_record(self):
  self.journal();original=self.command
  def fail(*args,**kwargs):
   if args[:3]==('systemctl','disable','coturn.service'):raise subprocess.CalledProcessError(1,args)
   return original(*args,**kwargs)
  with patch.object(s,'command',side_effect=fail):self.assertRaises(subprocess.CalledProcessError,s.recover_package)
  self.assertTrue(s.MASK.is_symlink());self.assertTrue((s.STATE/'package-transaction.json').exists());s.recover_package();self.assertFalse(s.MASK.is_symlink())
 def test_masked_disable_preserves_foreign_enable_link_for_review(self):
  self.journal();s.VENDOR_LINK.parent.mkdir(parents=True);s.VENDOR_LINK.symlink_to('/etc/operator.service');self.assertRaises(ValueError,s.recover_package);self.assertEqual(os.readlink(s.VENDOR_LINK),'/etc/operator.service');self.assertTrue(s.MASK.is_symlink());self.assertTrue((s.STATE/'package-transaction.json').exists())
 def test_interrupted_mask_recovery_refuses_replaced_mask_or_running_vendor(self):
  self.journal();s.MASK.unlink();s.MASK.write_text('foreign');self.assertRaises(ValueError,s.recover_package);self.assertEqual(s.MASK.read_text(),'foreign');s.MASK.unlink();s.MASK.symlink_to('/dev/null')
  with patch.object(s,'service',return_value={'ActiveState':'active','MainPID':'99'}):self.assertRaises(ValueError,s.recover_package)
  self.assertTrue(s.MASK.is_symlink());self.assertRaises(ValueError,self.install)
 def test_failed_configuration_reload_restores_original_files(self):
  self.install();before={p:p.read_bytes()for p in [s.UNIT,s.CONFIG,s.STATE/'installation.json']};original=self.command
  def fail(*args,**kwargs):
   if args==('systemctl','daemon-reload')and kwargs.get('check',True):raise subprocess.CalledProcessError(1,args)
   return original(*args,**kwargs)
  with patch.object(s,'command',side_effect=fail):self.assertRaises(subprocess.CalledProcessError,s.install,['2001:db8::30'])
  self.assertEqual(before,{p:p.read_bytes()for p in before})
 def test_render_refuses_wildcard_multicast_and_injection(self):
  for address in ['0.0.0.0','::','239.1.2.3','ff02::1','192.0.2.30\nno-stun','host.invalid']:self.assertRaises(ValueError,s.render,[address])
  content=s.render(['2001:db8::30','192.0.2.30']);self.assertEqual(content.count(b'listening-ip='),2);self.assertIn(b'listening-port=3478\n',content);self.assertIn(b'stun-only\n',content)
if __name__=='__main__':unittest.main()
