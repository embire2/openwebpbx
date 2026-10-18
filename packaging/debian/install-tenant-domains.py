#!/usr/bin/env python3
"""Install instance-only alias worker and public nonce path; never owns central DNS secrets."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
PACKAGE=Path(__file__).resolve().parent
TOOLS=Path('/opt/openwebpbx/tools')
STATE=Path('/var/lib/openwebpbx/tenant-domains')
SITE=Path('/etc/nginx/sites-available/openwebpbx')
HOSTED=Path('/etc/nginx/sites-available/openweb-call.conf')
SNIPPET=Path('/etc/nginx/snippets/openweb-tenant-domains-proof.conf')
INCLUDE='include /etc/nginx/snippets/openweb-tenant-domains-proof.conf;'
UNIT=Path('/etc/systemd/system/openwebpbx-tenant-domains.service')
TIMER=Path('/etc/systemd/system/openwebpbx-tenant-domains.timer')
LINKS=[Path('/etc/systemd/system/timers.target.wants/openwebpbx-tenant-domains.timer'),Path('/etc/systemd/system/openwebpbx-updater.service.wants/openwebpbx-tenant-domains.timer')]
PROGRAMS=['tenant-domains.py','tenant-domains.php','tenant-domains-nginx.conf','install-tenant-domains.py']
PROOF='''# OpenWeb PBX managed tenant instance proof v1
location ^~ /.well-known/openwebpbx-instance/ {
 root /var/lib/openwebpbx/tenant-domains/proofs;
 default_type text/plain;
 add_header Cache-Control "no-store";
 try_files $uri =404;
 limit_except GET { deny all; }
}
'''
def ordinary(path):
 path=Path(path)
 for item in [path,*path.parents]:
  if item.is_symlink():raise ValueError('Review linked tenant-domain installation paths.')
 return path

def site_content():
 path=SITE if SITE.exists()or SITE.is_symlink()else HOSTED
 ordinary(path)
 if not path.exists():
  if os.environ.get('OPENWEB_FRESH_INSTALL')=='1':return path,None
  raise ValueError('Review the existing HTTPS website before adding tenant domains.')
 text=path.read_text();names=re.findall(r'(?m)^\s*server_name\s+([^;]+);',text)
 if len(names)!=2 or names[0]!=names[1]or not re.fullmatch(r'[a-z0-9.-]+',names[0])or not any(root in text for root in ['root /var/www/fusionpbx;','root /var/www/fusionpbx/public;']):raise ValueError('Review the existing HTTPS website before adding tenant domains.')
 if text.count(INCLUDE)not in(0,2):raise ValueError('Review the tenant instance-proof includes.')
 if INCLUDE not in text:text=re.sub(r'(?m)^(\s*server_name\s+[^;]+;)',lambda m:m[1]+'\n '+INCLUDE,text)
 return path,text

def targets():
 site,_=site_content();return [site,SNIPPET,UNIT,TIMER,*[TOOLS/name for name in PROGRAMS],*[p for p in LINKS if not p.exists()and not p.is_symlink()]]

def write(path,data,mode=0o644):
 ordinary(path);path.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.NamedTemporaryFile(dir=path.parent,prefix='.tenant-install-',delete=False)as stream:
  temp=Path(stream.name)
  try:stream.write(data);stream.flush();os.fsync(stream.fileno());os.fchmod(stream.fileno(),mode)
  except BaseException:temp.unlink(missing_ok=True);raise
 os.replace(temp,path)

def install(activate=False):
 if os.geteuid()!=0:raise PermissionError('Tenant domains install requires root.')
 manifest=json.loads((PACKAGE/'release-manifest.json').read_text())
 import hashlib
 for name in [*PROGRAMS,UNIT.name,TIMER.name]:
  if hashlib.sha256((PACKAGE/name).read_bytes()).hexdigest()!=manifest['files'].get(name):raise ValueError('Tenant domain helper differs from the release manifest.')
 site,text=site_content();first=not TIMER.exists();old=site.read_bytes()if site.exists()else None
 for target in [UNIT,TIMER]:
  ordinary(target)
  if target.exists()and not target.read_bytes().startswith(b'# OpenWeb PBX managed tenant domains v1\n'):raise ValueError('A tenant-domain unit belongs to another configuration.')
 for link in LINKS:
  if link.is_symlink()and link.resolve()!=TIMER:raise ValueError('An existing timer link belongs to another configuration.')
 # Older updaters cannot reload a restored proxy after failure. Stage only
 # captured code/configuration; create runtime storage after durable commit.
 if activate or os.environ.get('OPENWEB_FRESH_INSTALL')=='1':
  for path in [STATE,STATE/'proofs',STATE/'proofs/.well-known',STATE/'proofs/.well-known/openwebpbx-instance']:
   ordinary(path);path.mkdir(parents=True,exist_ok=True,mode=0o750)
   if path.stat().st_uid!=0 or path.stat().st_mode&0o022:raise ValueError('Protected tenant-domain state required.')
   path.chmod(0o750);os.chown(path,0,33)
 for name in PROGRAMS:write(TOOLS/name,(PACKAGE/name).read_bytes())
 write(UNIT,(PACKAGE/UNIT.name).read_bytes());write(TIMER,(PACKAGE/TIMER.name).read_bytes());write(SNIPPET,PROOF.encode())
 if text is not None:
  write(site,text.encode())
  try:
   subprocess.run(['nginx','-t'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=20)
   if activate and subprocess.run(['systemctl','is-active','--quiet','nginx']).returncode==0:subprocess.run(['systemctl','reload','nginx'],check=True,timeout=20)
  except BaseException:
   if old is not None:write(site,old)
   raise
 subprocess.run(['systemctl','daemon-reload'],check=True,timeout=30)
 if first:subprocess.run(['systemctl','enable',TIMER.name],check=True,timeout=30)
 if activate and subprocess.run(['systemctl','is-enabled','--quiet',TIMER.name]).returncode==0:subprocess.run(['systemctl','start',TIMER.name],check=True,timeout=30)
if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--activate',action='store_true');args=parser.parse_args();install(args.activate)
