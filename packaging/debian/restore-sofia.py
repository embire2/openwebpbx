#!/usr/bin/env python3
"""Install the reviewed registrar module on the pinned engine, while stopped.

The caller first extends the existing updater recovery snapshot with TARGET.
Fresh installs already contain these bytes and need no replacement.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

TARGET=Path('/usr/lib/freeswitch/mod/mod_sofia.so')
LIBRARY=Path('/usr/lib/libfreeswitch.so.1.0.0')
ENTRY='usr/lib/freeswitch/mod/mod_sofia.so'
MODULE_SHA256='da061fd1de81432139461b86e4db8b6c79a2599d3cf0187cc74c1d332ed47452'
LIBRARY_SHA256='069d79800131cc050d359313c03ac827e2beaf7b7719984dcab462e32fbfce6a'

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def stopped():
    result=subprocess.run(['systemctl','show','freeswitch','--property=ActiveState','--value'],capture_output=True,text=True,check=True)
    if result.stdout.strip() not in ('inactive','failed'):
        raise RuntimeError('Stop the call engine within the updater before changing its registrar module.')

def validate_target():
    if TARGET.is_symlink() or any(parent.is_symlink() for parent in TARGET.parents) or not TARGET.is_file():
        raise ValueError('The registrar module must be an ordinary installed file.')
    if not LIBRARY.is_file() or digest(LIBRARY)!=LIBRARY_SHA256:
        raise ValueError('The registrar update requires the pinned Debian engine. The previous module is preserved.')

def payload(package,manifest):
    archive=package/'engine.tar.gz'
    if archive.is_symlink() or not archive.is_file() or digest(archive)!=manifest['files'].get('engine.tar.gz'):
        raise ValueError('The native engine differs from the verified release manifest.')
    with tarfile.open(archive) as source:
        members=[member for member in source if member.name==ENTRY]
        if len(members)!=1 or not members[0].isfile() or not 1024<=members[0].size<=16*1024*1024:
            raise ValueError('The release must contain exactly one ordinary registrar module.')
        content=source.extractfile(members[0]).read()
    if hashlib.sha256(content).hexdigest()!=MODULE_SHA256:
        raise ValueError('The registrar bytes differ from the reviewed native build.')
    validate_target()
    if digest(TARGET)==MODULE_SHA256:return None
    stopped()
    return content

def install(content):
    if content is None:return False
    if os.geteuid()!=0 or hashlib.sha256(content).hexdigest()!=MODULE_SHA256:
        raise ValueError('A root installer and the reviewed registrar bytes are required.')
    validate_target();stopped()
    with tempfile.NamedTemporaryFile(prefix='.openweb-sofia-',dir=TARGET.parent,delete=False) as stream:
        temporary=Path(stream.name)
        try:
            stream.write(content);stream.flush();os.fsync(stream.fileno());os.fchmod(stream.fileno(),0o755);os.fchown(stream.fileno(),0,0)
            os.replace(temporary,TARGET)
            fd=os.open(TARGET.parent,os.O_RDONLY|os.O_DIRECTORY)
            try:os.fsync(fd)
            finally:os.close(fd)
        finally:temporary.unlink(missing_ok=True)
    return True
