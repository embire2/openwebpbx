#!/usr/bin/env python3
"""Recoverable browser-meeting proxy for the standard Debian installation."""
from pathlib import Path
import os
import tempfile
import subprocess

SITE=Path('/etc/nginx/sites-available/openwebpbx')
SNIPPET=Path('/etc/nginx/snippets/openweb-meet.conf')
TRUST=Path('/etc/openwebpbx/meet-ca.pem')
PRIVATE=Path('/etc/freeswitch/tls/openweb-meet/wss.pem')
INCLUDE=' include /etc/nginx/snippets/openweb-meet.conf;'
MARKER=' location ~ /\\. { deny all; }'


def site_content(site=SITE):
    if site.is_symlink() or any(p.is_symlink() for p in site.parents):
        raise ValueError('Review the existing meeting web-server configuration before updating.')
    if not site.is_file():
        if os.environ.get('OPENWEB_FRESH_INSTALL')=='1':return None
        raise ValueError('The standard OpenWeb PBX web-server site is missing. Review the meeting proxy before updating.')
    text=site.read_text()
    if text.count('root /var/www/fusionpbx;')!=1 or text.count('listen 443 ssl;')!=1:
        raise ValueError('The existing web-server site needs review before adding meetings.')
    if INCLUDE.strip() in text:
        if text.count(INCLUDE.strip())!=1:raise ValueError('Duplicate meeting proxy includes need review.')
        return text
    if '/meet-sip/' in text or text.count(MARKER)!=1:
        raise ValueError('The existing meeting proxy needs review before updating.')
    return text.replace(MARKER,INCLUDE+'\n'+MARKER,1)


def targets():
    site_content() # Refuse unsupported configurations before any new files change.
    return [SITE,SNIPPET,TRUST,PRIVATE]


def write(path,data,mode):
    if path.is_symlink() or any(p.is_symlink() for p in path.parents):raise ValueError('A meeting proxy file location is linked.')
    if path.exists() and not path.is_file():raise ValueError('A meeting proxy file is not ordinary.')
    if path.is_file() and path.read_bytes()==data:return
    st=path.stat() if path.exists() else None
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
    temporary=None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent,prefix='.meeting-',delete=False)as f:
            temporary=Path(f.name);f.write(data);f.flush();os.fsync(f.fileno());os.fchmod(f.fileno(),st.st_mode&0o777 if st else mode);os.fchown(f.fileno(),st.st_uid if st else 0,st.st_gid if st else 0)
        os.replace(temporary,path)
        fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
    finally:
        if temporary:temporary.unlink(missing_ok=True)


def install():
    text=site_content()
    if text is None:return # configure.py writes the complete fresh site later.
    if not TRUST.is_file() or not PRIVATE.is_file():raise ValueError('The private meeting transport is not initialized.')
    write(SNIPPET,Path(__file__).with_name('meet-nginx.conf').read_bytes(),0o644)
    write(SITE,text.encode(),0o644)
    subprocess.run(['nginx','-t'],check=True)
    subprocess.run(['systemctl','reload','nginx'],check=True)

if __name__=='__main__':install()
