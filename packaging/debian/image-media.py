#!/usr/bin/env python3
"""Create public, read-only installer media for a clean Debian13 cloud image.

Only the complete pinned release archive and its public identity enter the ISO.
No installed database, cloud-init payload, account, password or key is read.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile


def digest(path):
    with Path(path).open('rb')as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def ordinary(path):
    path=Path(path)
    for part in [path,*path.parents]:
        if part.is_symlink():raise ValueError('Linked installer media path refused.')
    return path


def inspect_archive(archive,expected):
    archive=ordinary(archive);info=archive.stat()
    if not stat.S_ISREG(info.st_mode)or info.st_size>600*1024**2 or info.st_mode&0o022:raise ValueError('Protected complete installer archive required.')
    if not re.fullmatch('[a-f0-9]{64}',expected)or digest(archive)!=expected:raise ValueError('Installer archive checksum mismatch.')
    with tarfile.open(archive,'r:gz')as package:
        members=package.getmembers();names=set();total=0;root=None;manifest=None
        if len(members)>25000:raise ValueError('Installer member limit exceeded.')
        for member in members:
            parts=PurePosixPath(member.name).parts
            if not parts or member.name.rstrip('/')!=str(PurePosixPath(member.name))or member.name.startswith('/')or '..'in parts or '\\'in member.name or not(member.isfile()or member.isdir())or member.name in names or member.mode&0o7000:raise ValueError('Unsafe installer archive member.')
            if root is None:root=parts[0]
            if parts[0]!=root:raise ValueError('One complete installer tree required.')
            names.add(member.name);total+=member.size
            if total>2*1024**3:raise ValueError('Installer extraction size limit exceeded.')
            if len(parts)==2 and parts[1]=='release-manifest.json':
                if not member.isfile()or member.size>4*1024**2:raise ValueError('Bounded installer manifest required.')
                manifest=json.load(package.extractfile(member))
        if not isinstance(manifest,dict)or set(manifest)!={'version','files'}or not re.fullmatch(r'\d+\.\d+\.\d+',manifest.get('version',''))or not isinstance(manifest.get('files'),dict):raise ValueError('Debian installer manifest required.')
        version=manifest['version'];prefix='openwebpbx-'+version+'-debian13-amd64'
        if root!=prefix or archive.name!=prefix+'.tar.gz':raise ValueError('Installer filename/version binding mismatch.')
        files={m.name[len(root)+1:]:m for m in members if m.isfile()}
        if set(files)!=set(manifest['files'])|{'release-manifest.json'}:raise ValueError('Installer inventory mismatch.')
        for name,expected_leaf in manifest['files'].items():
            if not isinstance(expected_leaf,str)or not re.fullmatch('[a-f0-9]{64}',expected_leaf):raise ValueError('Invalid installer leaf digest.')
            with package.extractfile(files[name])as stream:
                if hashlib.file_digest(stream,'sha256').hexdigest()!=expected_leaf:raise ValueError('Installer leaf checksum mismatch.')
        required={'install.sh','configure.py','bootstrap.php','engine.tar.gz','server/OpenWebPbx.Server','updater/OpenWebPbx.Updater','onboarding.py','onboarding.php','webhotel-onboarding.py','web/resources/keys/installation-authority.pem'}
        if not required<=set(files):raise ValueError('Complete current onboarding installer required.')
        return {'schema':1,'version':version,'target':'debian13-amd64','archive':archive.name,'archive_sha256':expected,'archive_bytes':info.st_size,'payload_files':len(manifest['files']),'volume_label':'OPENWEBPBX'+''.join(version.split('.'))}


def build(archive,expected,output,tool=None):
    archive=Path(archive);output=ordinary(output);identity=inspect_archive(archive,expected)
    if len(identity['volume_label'])>32:raise ValueError('Installer media label exceeds ISO limits.')
    sidecar=output.with_suffix(output.suffix+'.manifest.json')
    if output.exists():
        if not sidecar.is_file()or sidecar.is_symlink():raise ValueError('Existing installer media has no ownership manifest.')
        saved=json.loads(sidecar.read_text())
        if any(saved.get(k)!=v for k,v in identity.items())or digest(output)!=saved.get('iso_sha256'):raise ValueError('Existing installer media differs from this release.')
        return saved
    if sidecar.exists():raise ValueError('Uncertain installer media publication requires review.')
    output.parent.mkdir(parents=True,exist_ok=True)
    selected=tool or shutil.which('genisoimage')or shutil.which('xorriso')
    if not selected:raise RuntimeError('Install genisoimage or xorriso to build installer media.')
    with tempfile.TemporaryDirectory(prefix='.openweb-image-',dir=output.parent)as temporary:
        work=Path(temporary);source=work/'source';source.mkdir(mode=0o700)
        shutil.copyfile(archive,source/archive.name)
        (source/'manifest.json').write_text(json.dumps(identity,indent=2)+'\n')
        (source/'README.txt').write_text('OpenWeb PBX '+identity['version']+' Debian13 complete installer.\nPublic software only; run the normal installer in each fresh clone.\nNo account, database or private key is included.\n')
        target=work/'installer.iso';command=[str(selected)]
        if Path(selected).name=='xorriso':command+=['-as','mkisofs']
        command+=['-quiet','-V',identity['volume_label'],'-J','-r','-o',str(target),str(source)]
        subprocess.run(command,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=300)
        identity['iso_sha256']=digest(target);identity['iso_bytes']=target.stat().st_size
        # CreateNew publication never replaces another operator's ISO. Each
        # newly owned file is synced explicitly; no extracted-tree chmod.
        for destination,data_path in [(output,target)]:
            descriptor=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o644)
            with os.fdopen(descriptor,'wb')as out,data_path.open('rb')as source_stream:shutil.copyfileobj(source_stream,out);out.flush();os.fsync(out.fileno());os.fchmod(out.fileno(),0o644)
        descriptor=os.open(sidecar,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o644)
        with os.fdopen(descriptor,'w')as out:json.dump(identity,out,indent=2);out.write('\n');out.flush();os.fsync(out.fileno());os.fchmod(out.fileno(),0o644)
        directory=os.open(output.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:os.fsync(directory)
        finally:os.close(directory)
    return identity


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--archive',type=Path,required=True);parser.add_argument('--sha256',required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    print(json.dumps(build(args.archive,args.sha256,args.output),indent=2))
