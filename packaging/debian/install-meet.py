#!/usr/bin/env python3
"""Recoverable browser-meeting proxy for the standard Debian installation."""
from pathlib import Path
import os
import json
import stat
import re
import ssl
import tempfile
import subprocess

SITE=Path('/etc/nginx/sites-available/openwebpbx')
HOSTED=Path('/etc/nginx/sites-available/openweb-call.conf')
WEB=Path('/var/www/fusionpbx')
CONFIG=Path('/etc/fusionpbx/config.conf')
SNIPPET=Path('/etc/nginx/snippets/openweb-meet.conf')
TRUST=Path('/etc/openwebpbx/meet-ca.pem')
PRIVATE=Path('/etc/freeswitch/tls/openweb-meet/wss.pem')
JOURNAL=Path('/var/lib/openwebpbx/updates/install-journal.json')
INCLUDE=' include /etc/nginx/snippets/openweb-meet.conf;'
MARKER=' location ~ /\\. { deny all; }'


def transport():
    for path in (TRUST,PRIVATE):
        if path.is_symlink() or any(p.is_symlink() for p in path.parents) or not path.is_file():
            raise ValueError('The private meeting transport is not initialized safely.')
    try:
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(PRIVATE)) # Includes a real private-key/certificate match.
        certificate=re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',PRIVATE.read_text(),re.S)
        if not certificate or ssl.PEM_cert_to_DER_cert(certificate[0])!=ssl.PEM_cert_to_DER_cert(TRUST.read_text()):
            raise ValueError('The private meeting trust certificate differs from its endpoint.')
    except (OSError,ssl.SSLError) as error:
        raise ValueError('The private meeting transport needs administrator review.') from error


def hosted_profile():
    # Read-only proof for the one legacy hosted layout. Never infer ownership
    # from a site filename, host name or user-controlled SIP header alone.
    code=r"""require $argv[1].'/resources/classes/config.php';config::load($argv[2]);require $argv[1].'/resources/classes/auto_loader.php';new auto_loader();$db=database::new()->db;
$q=$db->query("select sip_profile_uuid,sip_profile_name,sip_profile_enabled from v_sip_profiles where sip_profile_name='openweb-meet' or sip_profile_uuid='cfb1c835-c30c-409b-bff7-a893a7e84df1'");$r=$q->fetchAll(PDO::FETCH_ASSOC);if(count($r)!==1||$r[0]['sip_profile_uuid']!=='cfb1c835-c30c-409b-bff7-a893a7e84df1'||$r[0]['sip_profile_name']!=='openweb-meet'||!in_array($r[0]['sip_profile_enabled'],[true,'true','t'],true))exit(2);
foreach(['sip-ip'=>'127.0.0.1','wss-binding'=>'127.0.0.1:7444','context'=>'openweb-meet-only','auth-calls'=>'true','tls-cert-dir'=>rtrim((string)config::load()->get('switch.conf.dir'),'/').'/tls/openweb-meet']as$n=>$v){$q=$db->prepare('select sip_profile_setting_value,sip_profile_setting_enabled from v_sip_profile_settings where sip_profile_uuid=? and sip_profile_setting_name=?');$q->execute([$r[0]['sip_profile_uuid'],$n]);$s=$q->fetchAll(PDO::FETCH_ASSOC);if(count($s)!==1||$s[0]['sip_profile_setting_value']!==$v||!in_array($s[0]['sip_profile_setting_enabled'],[true,'true','t'],true))exit(3);}"""
    result=subprocess.run(['php','-r',code,str(WEB),str(CONFIG)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if result.returncode:raise ValueError('The existing hosted meeting profile needs administrator review.')


def selected_site():
    if SITE.exists() or SITE.is_symlink():return SITE
    if HOSTED.exists() or HOSTED.is_symlink():return HOSTED
    return SITE


def hosted_content(site):
    if site.is_symlink() or any(p.is_symlink() for p in site.parents) or not site.is_file():
        raise ValueError('The existing hosted meeting site is not ordinary.')
    text=site.read_text()
    active='\n'.join(line.split('#',1)[0].strip()for line in text.splitlines())
    if (active.count(INCLUDE.strip())!=1 or active.count('root /var/www/fusionpbx/public;')!=1
        or re.findall(r'(?m)^server_name\s+([^;]+);$',active)!=['call.openweb.co.za','call.openweb.co.za']
        or len(re.findall(r'(?m)^listen 443 ssl;$',active))!=1 or '/meet-sip/' in active):
        raise ValueError('The existing hosted meeting site needs administrator review.')
    transport();hosted_profile()
    return text # An already installed legacy proxy keeps every original byte.


def site_content(site=None):
    site=selected_site() if site is None else Path(site)
    if site==HOSTED:return hosted_content(site)
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
    return [selected_site(),SNIPPET,TRUST,PRIVATE]


def write(path,data,mode,owner=None):
    if path.is_symlink() or any(p.is_symlink() for p in path.parents):raise ValueError('A meeting proxy file location is linked.')
    if path.exists() and not path.is_file():raise ValueError('A meeting proxy file is not ordinary.')
    if path.is_file() and path.read_bytes()==data:return
    st=path.stat() if path.exists() else None
    missing=[];parent=path.parent
    while not parent.exists():missing.append(parent);parent=parent.parent
    for parent in reversed(missing):parent.mkdir(mode=0o755);parent.chmod(0o755)
    temporary=None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent,prefix='.meeting-',delete=False)as f:
            temporary=Path(f.name);f.write(data);f.flush();os.fsync(f.fileno());os.fchmod(f.fileno(),st.st_mode&0o777 if st else mode);os.fchown(f.fileno(),owner[0] if owner else st.st_uid if st else 0,owner[1] if owner else st.st_gid if st else 0)
        os.replace(temporary,path)
        fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
    finally:
        if temporary:temporary.unlink(missing_ok=True)


def migrating():
    if JOURNAL.is_symlink() or any(p.is_symlink() for p in JOURNAL.parents):
        raise ValueError('The meeting upgrade journal location needs review.')
    if not JOURNAL.exists():return False
    if not JOURNAL.is_file():raise ValueError('The meeting upgrade journal is not ordinary.')
    return json.loads(JOURNAL.read_text()).get('state')=='migrating'


def reload_proxy():
    """Reload only an already running web server; never start a held service."""
    subprocess.run(['nginx','-t'],check=True)
    active=subprocess.run(['systemctl','is-active','--quiet','nginx'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if active.returncode==0:
        subprocess.run(['systemctl','reload','nginx'],check=True)


def install():
    text=site_content()
    if text is None:return # configure.py writes the complete fresh site later.
    transport()
    site=selected_site()
    # The old installed updater still owns rollback during a 1.0.15 upgrade.
    # Leave its in-memory proxy untouched until the committed new worker starts.
    defer=migrating()
    before={}
    absent_dirs=[]
    for path in (site,SNIPPET):
        if path.is_symlink() or any(p.is_symlink() for p in path.parents) or path.exists() and not path.is_file():
            raise ValueError('The meeting proxy file location needs review.')
        st=path.stat() if path.exists() else None
        before[path]=(path.read_bytes(),stat.S_IMODE(st.st_mode),st.st_uid,st.st_gid) if st else None
        parent=path.parent
        while not parent.exists():
            if parent not in absent_dirs:absent_dirs.append(parent)
            parent=parent.parent
    reload_attempted=False
    try:
        write(SNIPPET,Path(__file__).with_name('meet-nginx.conf').read_bytes(),0o644)
        write(site,text.encode(),0o644)
        if defer:subprocess.run(['nginx','-t'],check=True)
        else:
            reload_attempted=True
            reload_proxy()
    except BaseException:
        # Restore bytes, absent states and metadata before restoring the old
        # runtime. A failed reload may have taken effect despite its exit code.
        for path,entry in before.items():
            if entry is None:path.unlink(missing_ok=True)
            else:
                data,mode,uid,gid=entry
                write(path,data,mode,(uid,gid));path.chmod(mode);os.chown(path,uid,gid)
        for directory in absent_dirs:
            try:directory.rmdir()
            except OSError:pass
        if reload_attempted:reload_proxy()
        raise

if __name__=='__main__':install()
