#!/usr/bin/env python3
"""Opt-in UDP STUN binding only. Never adopts an operator's coturn service."""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PACKAGE=Path(__file__).resolve().parent
UNIT=Path('/etc/systemd/system/openwebpbx-stun.service')
CONFIG=Path('/etc/openwebpbx-stun.conf')
LINK=Path('/etc/systemd/system/multi-user.target.wants/openwebpbx-stun.service')
STATE=Path('/var/lib/openwebpbx/stun')
# Persistent until package recovery proves the newly installed vendor is disabled:
# a reboot must not drop a runtime mask and start the unconfigured vendor daemon.
MASK=Path('/etc/systemd/system/coturn.service')
VENDOR_CONFIGS=[Path('/etc/turnserver.conf'),Path('/etc/default/coturn'),Path('/etc/systemd/system/coturn.service.d'),Path('/run/systemd/system/coturn.service')]
VENDOR_LINK=Path('/etc/systemd/system/multi-user.target.wants/coturn.service')

def ordinary(path):
    path=Path(path)
    if any(p.is_symlink() for p in [path,*path.parents]):raise ValueError('Linked STUN installation path refused.')
    if path.exists() and (path.stat().st_uid!=0 or path.stat().st_mode&0o022):raise ValueError('Root-owned protected STUN path required.')
    return path

def write(path,data,mode=0o644):
    ordinary(path);ordinary(path.parent).mkdir(parents=True,exist_ok=True,mode=0o755)
    descriptor,name=tempfile.mkstemp(prefix='.stun-',dir=path.parent)
    try:
        with os.fdopen(descriptor,'wb') as stream:
            os.fchmod(stream.fileno(),mode);os.fchown(stream.fileno(),0,0);stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(name,path)
        sync(path.parent)
    finally:Path(name).unlink(missing_ok=True)

def sync(path):
    descriptor=os.open(path,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)

def command(*args,check=True):
    return subprocess.run(args,check=check,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=30)

def service(name):
    result=command('systemctl','show',name,'-p','LoadState','-p','ActiveState','-p','MainPID','-p','FragmentPath','-p','DropInPaths')
    return dict(line.split('=',1) for line in result.stdout.splitlines() if '=' in line)

def render(addresses):
    ips=sorted(set(str(ipaddress.ip_address(value)) for value in addresses))
    if not ips or any(ipaddress.ip_address(value).is_unspecified or ipaddress.ip_address(value).is_multicast for value in ips):raise ValueError('Explicit unicast listening addresses required.')
    template=ordinary(PACKAGE/'openwebpbx-stun.conf').read_text()
    if template.count('@LISTENING_IPS@')!=1:raise ValueError('Unexpected managed STUN template.')
    return template.replace('@LISTENING_IPS@','\n'.join('listening-ip='+value for value in ips)).encode()

def recover_package():
    journal=ordinary(STATE/'package-transaction.json')
    if not journal.exists():return
    record=json.loads(journal.read_text())
    if record!={'schema':1,'vendor_originally_absent':True,'mask':str(MASK)}:raise ValueError('Review the interrupted STUN package transaction.')
    if not MASK.is_symlink() or os.readlink(MASK)!='/dev/null':raise ValueError('Owned package mask was replaced; review before recovery.')
    native=service('coturn.service')
    if native.get('ActiveState') not in ('inactive','failed','') or native.get('MainPID','0')!='0':raise ValueError('Unexpected running coturn; owned mask retained for review.')
    command('systemctl','disable','coturn.service')
    # systemctl may ignore disable while masked. This exact link was absent
    # before our package transaction; never remove another target or a file.
    if VENDOR_LINK.is_symlink():
        if os.readlink(VENDOR_LINK) not in ('/usr/lib/systemd/system/coturn.service','/lib/systemd/system/coturn.service'):raise ValueError('Vendor enable link changed; owned mask retained for review.')
        VENDOR_LINK.unlink();sync(VENDOR_LINK.parent)
    if VENDOR_LINK.exists() or VENDOR_LINK.is_symlink():raise ValueError('New vendor enablement remains; owned mask retained for review.')
    MASK.unlink();sync(MASK.parent);command('systemctl','daemon-reload');journal.unlink();sync(journal.parent)

def install_package():
    if shutil.which('turnserver'):return
    native=service('coturn.service')
    if native.get('LoadState') not in ('','not-found') or any(p.exists() or p.is_symlink() for p in [MASK,VENDOR_LINK,*VENDOR_CONFIGS]):raise ValueError('Existing coturn belongs to its operator.')
    ordinary(STATE).mkdir(parents=True,exist_ok=True,mode=0o700);STATE.chmod(0o700)
    journal=ordinary(STATE/'package-transaction.json')
    if journal.exists():raise ValueError('Recover the interrupted STUN package transaction first.')
    write(journal,(json.dumps({'schema':1,'vendor_originally_absent':True,'mask':str(MASK)})+'\n').encode(),0o600)
    ordinary(MASK.parent).mkdir(parents=True,exist_ok=True);os.symlink('/dev/null',MASK);sync(MASK.parent)
    try:
        command('systemctl','daemon-reload')
        subprocess.run(['apt-get','update'],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=600)
        subprocess.run(['apt-get','install','-y','--no-install-recommends','coturn'],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=os.environ|{'DEBIAN_FRONTEND':'noninteractive'},timeout=900)
    finally:recover_package()
    if not shutil.which('turnserver'):raise ValueError('The coturn executable is unavailable.')

def install(addresses,activate=False,package=False):
    if os.geteuid()!=0:raise PermissionError('STUN installation requires root.')
    if ordinary(STATE/'package-transaction.json').exists():raise ValueError('Recover the interrupted STUN package transaction first.')
    content=render(addresses);unit=ordinary(PACKAGE/UNIT.name).read_bytes()
    for target in [UNIT,CONFIG,STATE,STATE/'installation.json']:ordinary(target)
    if LINK.is_symlink() and LINK.resolve()!=UNIT or LINK.exists() and not LINK.is_symlink():raise ValueError('Existing STUN enable link belongs to its operator.')
    record_path=STATE/'installation.json';record=json.loads(record_path.read_text()) if record_path.exists() else None
    if record is not None:
        if set(record)!={'schema','unit_sha256','config_sha256'} or record['schema']!=1 or not UNIT.is_file() or not CONFIG.is_file() or hashlib.sha256(UNIT.read_bytes()).hexdigest()!=record['unit_sha256'] or hashlib.sha256(CONFIG.read_bytes()).hexdigest()!=record['config_sha256']:raise ValueError('Existing STUN configuration changed; preserve it for operator review.')
    else:
        if STATE.exists() and any(STATE.iterdir()):raise ValueError('Existing STUN state belongs to its operator.')
        if any(p.exists() or p.is_symlink() for p in [UNIT,CONFIG,LINK]):raise ValueError('Existing STUN configuration belongs to its operator.')
        if service(UNIT.name).get('LoadState') not in ('','not-found') or service('coturn.service').get('LoadState') not in ('','not-found') or any(p.exists() or p.is_symlink() for p in VENDOR_CONFIGS):raise ValueError('Existing coturn service/configuration belongs to its operator.')
    current=service(UNIT.name)
    if current.get('DropInPaths') or current.get('LoadState') not in ('','not-found','loaded') or current.get('LoadState')=='loaded' and current.get('FragmentPath')!=str(UNIT):raise ValueError('Existing STUN service needs operator review.')
    sockets=command('ss','-H','-l','-n','-u','-t','-p','sport = :3478').stdout.strip().splitlines()
    pid=current.get('MainPID','0')
    processes=command('pgrep','-x','turnserver',check=False).stdout.split()
    if any(value!=pid for value in processes):raise ValueError('An existing turnserver process belongs to its operator.')
    if any(pid=='0' or ('pid='+pid+',') not in line for line in sockets):raise ValueError('Port3478 already belongs to another listener.')
    local=json.loads(command('ip','-j','address','show').stdout)
    available={str(ipaddress.ip_address(a['local'])) for interface in local for a in interface.get('addr_info',[]) if a.get('local')}
    requested={str(ipaddress.ip_address(a)) for a in addresses}
    if not requested<=available or any(ipaddress.ip_address(a).is_loopback for a in requested):raise ValueError('STUN must bind explicit installed non-loopback addresses.')
    if not shutil.which('turnserver'):
        if not package:raise ValueError('coturn is absent; explicitly request --install-package.')
        install_package()
    STATE.mkdir(parents=True,exist_ok=True,mode=0o700);STATE.chmod(0o700)
    # Existing managed service choices remain unchanged unless activation is explicit.
    old={p:p.read_bytes() if p.exists() else None for p in [UNIT,CONFIG,record_path]}
    try:
        if UNIT.exists() and UNIT.read_bytes()!=unit and current.get('ActiveState')=='active':raise ValueError('Stop the managed STUN service before changing its unit.')
        if CONFIG.exists() and CONFIG.read_bytes()!=content and current.get('ActiveState')=='active':raise ValueError('Stop the managed STUN service before changing its addresses.')
        records={UNIT:unit,CONFIG:content,record_path:(json.dumps({'schema':1,'unit_sha256':hashlib.sha256(unit).hexdigest(),'config_sha256':hashlib.sha256(content).hexdigest()})+'\n').encode()}
        for path,data in records.items():
            if old[path]!=data:write(path,data,0o600 if path==record_path else 0o644)
        command('systemctl','daemon-reload')
    except BaseException:
        for path,data in old.items():
            if data is None:path.unlink(missing_ok=True)
            else:write(path,data,0o600 if path==record_path else 0o644)
        command('systemctl','daemon-reload',check=False);raise
    if activate:command('systemctl','enable','--now',UNIT.name)
    return {'state':'active' if activate else 'staged','port':3478,'protocol':'udp','stun_only':True,'turn_relay':False}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--listen-ip',action='append',default=[]);parser.add_argument('--install-package',action='store_true');parser.add_argument('--activate',action='store_true');parser.add_argument('--recover-package',action='store_true');args=parser.parse_args()
    if args.recover_package:
        if os.geteuid()!=0:raise PermissionError('Package recovery requires root.')
        recover_package()
    else:print(json.dumps(install(args.listen_ip,args.activate,args.install_package)))
