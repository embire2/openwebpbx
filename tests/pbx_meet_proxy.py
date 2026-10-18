#!/usr/bin/env python3
"""Real temporary filesystem controls for supported/unsupported Debian proxy upgrades."""
import importlib.util
import os
from pathlib import Path
import tempfile

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('meet_proxy',root/'packaging/debian/install-meet.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
n=0
def check(value,message):
 global n
 assert value,message;n+=1

def refuses(action):
 try:action()
 except ValueError:return True
 return False

with tempfile.TemporaryDirectory(prefix='openweb-meet-proxy-')as tmp:
 directory=Path(tmp);site=directory/'site';old=(root/'packaging/debian/nginx.conf').read_text().replace(m.INCLUDE+'\n','')
 site.write_text(old);site.chmod(0o640)
 upgraded=m.site_content(site)
 check(upgraded.count(m.INCLUDE)==1,'Old standard site receives exactly one proxy include')
 check(upgraded.replace(m.INCLUDE+'\n','')==old,'Every unrelated old site byte is preserved')
 m.write(site,upgraded.encode(),0o644);st=site.stat()
 check(st.st_mode&0o777==0o640,'Existing site mode preserved')
 check(st.st_uid==os.geteuid(),'Existing site owner preserved')
 check(m.site_content(site)==upgraded,'Repeated migration is idempotent')
 m.write(site,upgraded.encode(),0o644);check(site.stat().st_ino==st.st_ino,'Equal bytes do not rewrite site')
 for text in [old.replace('root /var/www/fusionpbx;','root /custom;'),old.replace('listen 443 ssl;','listen 8443 ssl;'),old.replace(m.MARKER,''),old+'\nlocation = /meet-sip/ {}',upgraded+'\n'+m.INCLUDE,old+'\n'+m.MARKER]:
  site.write_text(text);before=site.read_bytes();check(refuses(lambda:m.site_content(site)),'Unsupported or ambiguous site refused');check(site.read_bytes()==before,'Refusal retained original site bytes')
 site.write_text(old);linked=directory/'linked';linked.symlink_to(site)
 check(refuses(lambda:m.site_content(linked)),'Linked site refused')
 check(refuses(lambda:m.write(linked,b'replace',0o644)),'Linked write refused')
 parent=directory/'linked-parent';parent.symlink_to(directory,target_is_directory=True)
 check(refuses(lambda:m.write(parent/'elsewhere',b'replace',0o644)),'Linked ancestor refused')
 absent=directory/'new'/'proxy.conf';m.write(absent,b'owned fixture\n',0o644)
 check(absent.read_bytes()==b'owned fixture\n' and absent.stat().st_mode&0o777==0o644,'New file installed atomically with prescribed mode')
 check(not list(directory.rglob('.meeting-*')),'No temporary writes remain')
 check(refuses(lambda:m.site_content(directory/'absent')),'Missing existing site refused')
print(f'PASS {n} temporary-filesystem meeting proxy migration controls')

# Exercise the actual installer writers and its validation/reload branches.
from unittest.mock import patch
import subprocess
with tempfile.TemporaryDirectory(prefix='openweb-meet-proxy-transaction-')as tmp:
 d=Path(tmp);m.SITE=d/'site';m.HOSTED=d/'hosted';m.SNIPPET=d/'snippets/proxy.conf';m.TRUST=d/'ca.pem';m.PRIVATE=d/'private.pem';m.JOURNAL=d/'journal.json'
 m.SITE.write_text(old);m.SITE.chmod(0o640)
 subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-subj','/CN=openweb-meet.internal','-keyout',str(d/'key'),'-days','3','-out',str(m.TRUST)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 m.PRIVATE.write_bytes((d/'key').read_bytes()+m.TRUST.read_bytes());m.PRIVATE.chmod(0o640)
 m.transport();check(True,'Real certificate and private key validate without replacing bytes')
 original_private=m.PRIVATE.read_bytes();original_ca=m.TRUST.read_bytes()
 commands=[]
 def command(args,**kwargs):
  commands.append(args)
  return subprocess.CompletedProcess(args,0)
 with patch.object(m.subprocess,'run',side_effect=command):
  m.JOURNAL.write_text('{"state":"migrating","version":"1.0.16"}')
  m.install();check(commands==[['nginx','-t']],'Old-helper migration validates without changing running Nginx')
  check(m.SITE.read_text()==upgraded,'Migrating files contain proxy for later committed activation')
  commands.clear();m.JOURNAL.write_text('{"state":"completed","version":"1.0.16"}')
  m.install();check(commands==[['nginx','-t'],['systemctl','is-active','--quiet','nginx'],['systemctl','reload','nginx']],'Committed standalone install validates and reloads only active Nginx')
  check(m.PRIVATE.read_bytes()==original_private and m.TRUST.read_bytes()==original_ca,'Installation preserves private transport identity exactly')
 # An ambiguous/dead journal cannot mutate configuration.
 m.SITE.write_text(old);m.SNIPPET.unlink();m.JOURNAL.write_text('not-json');before=m.SITE.read_bytes()
 try:m.install();raise AssertionError('Invalid journal accepted')
 except ValueError:pass
 check(m.SITE.read_bytes()==before and not m.SNIPPET.exists(),'Malformed journal refuses before any file mutation')
 m.JOURNAL.unlink();m.SNIPPET.parent.rmdir()
 # nginx -t refusal restores both absent-file state and original site metadata.
 count=[0]
 def invalid(args,**kwargs):
  if args==['nginx','-t']:
   count[0]+=1
   if count[0]==1:raise subprocess.CalledProcessError(1,args)
  return subprocess.CompletedProcess(args,0)
 with patch.object(m.subprocess,'run',side_effect=invalid):
  try:m.install();raise AssertionError('Invalid web configuration accepted')
  except subprocess.CalledProcessError:pass
 check(m.SITE.read_text()==old and m.SITE.stat().st_mode&0o777==0o640,'Validation failure restores exact old site bytes/mode')
 check(not m.SNIPPET.exists()and not m.SNIPPET.parent.exists(),'Validation failure restores absent snippet and new parent directory')
 # A reload can fail after taking effect: reload the restored old configuration.
 m.SNIPPET.parent.mkdir();m.SNIPPET.write_bytes(b'original owned proxy\n');m.SNIPPET.chmod(0o600);original=m.SNIPPET.stat();commands=[];count=[0]
 def reload_failure(args,**kwargs):
  commands.append(args)
  if args==['systemctl','reload','nginx']:
   count[0]+=1
   if count[0]==1:raise subprocess.CalledProcessError(1,args)
  return subprocess.CompletedProcess(args,0)
 with patch.object(m.subprocess,'run',side_effect=reload_failure):
  try:m.install();raise AssertionError('Failed reload accepted')
  except subprocess.CalledProcessError:pass
 check(count[0]==2,'Failed reload revalidates and reloads restored old runtime')
 st=m.SNIPPET.stat();check((m.SNIPPET.read_bytes(),st.st_mode&0o777,st.st_uid,st.st_gid)==(b'original owned proxy\n',0o600,original.st_uid,original.st_gid),'Rollback preserves pre-existing snippet bytes/mode/owner/group')
 # Keep an inactive service stopped.
 commands=[]
 def inactive(args,**kwargs):
  commands.append(args);return subprocess.CompletedProcess(args,3 if 'is-active'in args else 0)
 with patch.object(m.subprocess,'run',side_effect=inactive):m.install()
 check(['systemctl','reload','nginx']not in commands,'Inactive web server is never started/reloaded by migration')
 m.SITE.unlink()
 hosted='server {\nserver_name call.openweb.co.za;\n}\nserver {\nlisten 443 ssl;\nserver_name call.openweb.co.za;\nroot /var/www/fusionpbx/public;\n'+m.INCLUDE+'\n}\n'
 m.HOSTED.write_text(hosted);m.HOSTED.chmod(0o640)
 with patch.object(m,'hosted_profile')as proof:
  check(m.site_content()==hosted,'Existing allowlisted hosted layout retains every byte')
  check(proof.call_count==1,'Hosted layout requires independent database ownership proof')
  check(m.targets()[0]==m.HOSTED,'Recovery targets the selected actual hosted site')
 for bad in [hosted.replace('call.openweb.co.za','other.invalid'),hosted.replace(m.INCLUDE,''),hosted+ m.INCLUDE,hosted.replace('/fusionpbx/public','/custom')]:
  m.HOSTED.write_text(bad)
  check(refuses(m.site_content),'Unrecognised hosted layout refuses')
 m.HOSTED.write_text(hosted)
 with patch.object(m,'hosted_profile',side_effect=ValueError('unowned')):check(refuses(m.site_content),'Hosted filename alone grants no profile ownership')
 m.TRUST.write_text('invalid certificate')
 check(refuses(m.transport),'Malformed or mismatching trust fails without key rotation')
 check(m.PRIVATE.read_bytes()==original_private,'TLS refusal preserves private key bytes')
print(f'PASS {n} total filesystem/TLS/proxy transaction controls')
