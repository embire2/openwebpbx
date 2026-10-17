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
