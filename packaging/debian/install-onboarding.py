#!/usr/bin/env python3
"""Stage the fixed registration worker; preserve an administrator's disabled timer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

PACKAGE=Path(__file__).parent
TOOLS=Path('/opt/openwebpbx/tools')
UNITS=Path('/etc/systemd/system')
PROGRAMS=['onboarding.py','onboarding.php','webhotel-onboarding.py','install-onboarding.py']
NAMES=['openwebpbx-onboarding.service','openwebpbx-onboarding.timer']

def ordinary(path):
    for p in [path,*path.parents]:
        if p.is_symlink():raise ValueError('Linked registration installation paths need review.')
    return path

def targets():
    link=UNITS/'timers.target.wants/openwebpbx-onboarding.timer'
    return [*[TOOLS/n for n in PROGRAMS],*[UNITS/n for n in NAMES],*([link]if not link.exists()and not link.is_symlink()else [])]

def write(path,data):
    ordinary(path);path.parent.mkdir(exist_ok=True,parents=True,mode=0o755)
    fd,name=tempfile.mkstemp(dir=path.parent,prefix='.onboarding-install-')
    try:
        with os.fdopen(fd,'wb')as stream:stream.write(data);stream.flush();os.fsync(stream.fileno());os.fchmod(stream.fileno(),0o644)
        os.replace(name,path)
    finally:Path(name).unlink(missing_ok=True)

def install(activate=False):
    if os.geteuid()!=0:raise PermissionError('Root registration installer required.')
    first=not (UNITS/NAMES[1]).exists()
    if PACKAGE!=TOOLS:
        manifest=json.loads((PACKAGE/'release-manifest.json').read_text())['files']
        for name in [*PROGRAMS,*NAMES]:
            source=ordinary(PACKAGE/name)
            if not source.is_file()or hashlib.sha256(source.read_bytes()).hexdigest()!=manifest.get(name):raise ValueError('Registration source differs from release manifest.')
        for name in NAMES:
            dest=ordinary(UNITS/name)
            if dest.exists()and not dest.read_bytes().startswith(b'# OpenWeb PBX managed installation registration v1\n'):raise ValueError('An existing registration unit belongs to another installation.')
        for name in PROGRAMS:write(TOOLS/name,(PACKAGE/name).read_bytes())
        for name in NAMES:write(UNITS/name,(PACKAGE/name).read_bytes())
    else:
        for path in [*[TOOLS/n for n in PROGRAMS],*[UNITS/n for n in NAMES]]:
            s=ordinary(path).stat()
            if not stat.S_ISREG(s.st_mode)or s.st_uid!=0 or s.st_mode&0o022:raise ValueError('Protected installed registration files required.')
        if any(not (UNITS/name).read_bytes().startswith(b'# OpenWeb PBX managed installation registration v1\n')for name in NAMES):
            return 'custom'
    subprocess.run(['systemctl','daemon-reload'],check=True,timeout=30)
    if first:subprocess.run(['systemctl','enable',NAMES[1]],check=True,timeout=30)
    if activate and subprocess.run(['systemctl','is-enabled','--quiet',NAMES[1]]).returncode==0:subprocess.run(['systemctl','restart',NAMES[1]],check=True,timeout=30)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--activate',action='store_true');args=parser.parse_args();install(args.activate)
