#!/usr/bin/env python3
"""Install instance-only alias worker and public nonce path; never owns central DNS secrets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
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
UNIT_HASHES={
 'openwebpbx-tenant-domains.service':'2241bd472f9176f4ec1cab87b358a8be9aa057920b361f4cc34586454496309f',
 'openwebpbx-tenant-domains.timer':'c40c6fe585e981bf6d0912e40cb5dc2728b4a142bbfa8cfdad762f472bcfe6ca',
}
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
 text=path.read_text();active='\n'.join(line.split('#',1)[0]for line in text.splitlines())
 # The fresh template places listen and server_name on one line; the hosted
 # template uses separate lines. Accept these exact directive boundaries.
 pattern=r'(?m)^([ \t]*(?:listen[ \t]+(?:80|443[ \t]+ssl);[ \t]*)?server_name[ \t]+([^;\r\n]+);)'
 names=[m[2]for m in re.finditer(pattern,active)]
 if len(names)!=2 or names!=re.findall(r'\bserver_name\s+([^;]+);',active)or names[0]!=names[1]or not re.fullmatch(r'[a-z0-9.-]+',names[0])or not re.search(r'(?m)^[ \t]*root[ \t]+/var/www/fusionpbx(?:/public)?[ \t]*;',active):raise ValueError('Review the existing HTTPS website before adding tenant domains.')
 if text.count(INCLUDE)not in(0,2):raise ValueError('Review the tenant instance-proof includes.')
 if INCLUDE not in text:text=re.sub(pattern,lambda m:m[1]+'\n '+INCLUDE,text)
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

def runtime_storage():
 for path in [STATE,STATE/'proofs',STATE/'proofs/.well-known',STATE/'proofs/.well-known/openwebpbx-instance']:
  ordinary(path);path.mkdir(parents=True,exist_ok=True,mode=0o750)
  if path.stat().st_uid!=0 or path.stat().st_mode&0o022:raise ValueError('Protected tenant-domain state required.')
  path.chmod(0o750);os.chown(path,0,33)

def activate_installed():
 # The committed worker runs from TOOLS after verified package staging has
 # been removed. Reuse protected installed inputs; never invent a manifest
 # or copy unit templates from the installed helper directory.
 for directory in [TOOLS,UNIT.parent,SNIPPET.parent]:
  ordinary(directory);status=directory.stat()
  if not stat.S_ISDIR(status.st_mode)or status.st_uid!=0 or status.st_mode&0o022:raise ValueError('Protected installed tenant-domain directories required.')
 for path in [*[TOOLS/name for name in PROGRAMS],UNIT,TIMER,SNIPPET]:
  ordinary(path);status=path.stat()
  if not stat.S_ISREG(status.st_mode)or status.st_uid!=0 or status.st_mode&0o022:raise ValueError('Protected installed tenant-domain files required.')
 for unit in [UNIT,TIMER]:
  if hashlib.sha256(unit.read_bytes()).hexdigest()!=UNIT_HASHES[unit.name]:raise ValueError('A tenant-domain unit differs from the managed configuration.')
 for link in LINKS:
  if link.is_symlink()and link.resolve()!=TIMER:raise ValueError('An existing timer link belongs to another configuration.')
 site,text=site_content();ordinary(site);status=site.stat()
 if not stat.S_ISREG(status.st_mode)or status.st_uid!=0 or status.st_mode&0o022:raise ValueError('Protected installed tenant-domain website required.')
 if text is None or text.count(INCLUDE)!=2 or site.read_text()!=text or SNIPPET.read_text()!=PROOF:raise ValueError('Tenant domains must be staged by the verified package before activation.')
 runtime_storage()
 subprocess.run(['nginx','-t'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=20)
 if subprocess.run(['systemctl','is-active','--quiet','nginx']).returncode==0:subprocess.run(['systemctl','reload','nginx'],check=True,timeout=20)
 subprocess.run(['systemctl','daemon-reload'],check=True,timeout=30)
 if subprocess.run(['systemctl','is-enabled','--quiet',TIMER.name]).returncode==0:subprocess.run(['systemctl','start',TIMER.name],check=True,timeout=30)

def install(activate=False):
 if os.geteuid()!=0:raise PermissionError('Tenant domains install requires root.')
 if PACKAGE==TOOLS:
  if not activate:raise ValueError('Use the verified release package to stage tenant domains.')
  return activate_installed()
 manifest=json.loads((PACKAGE/'release-manifest.json').read_text())
 for name in [*PROGRAMS,UNIT.name,TIMER.name]:
  digest=hashlib.sha256((PACKAGE/name).read_bytes()).hexdigest()
  if digest!=manifest['files'].get(name)or(name in UNIT_HASHES and digest!=UNIT_HASHES[name]):raise ValueError('Tenant domain helper differs from the release manifest.')
 site,text=site_content();first=not TIMER.exists();old=site.read_bytes()if site.exists()else None
 for target in [UNIT,TIMER]:
  ordinary(target)
  if target.exists()and not target.read_bytes().startswith(b'# OpenWeb PBX managed tenant domains v1\n'):raise ValueError('A tenant-domain unit belongs to another configuration.')
 for link in LINKS:
  if link.is_symlink()and link.resolve()!=TIMER:raise ValueError('An existing timer link belongs to another configuration.')
 # Older updaters cannot reload a restored proxy after failure. Stage only
 # captured code/configuration; create runtime storage after durable commit.
 if activate or os.environ.get('OPENWEB_FRESH_INSTALL')=='1':
  runtime_storage()
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
