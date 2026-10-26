#!/usr/bin/env python3
"""Refresh app source over an authenticated unchanged SDK/source-JAR archive.

No SDK content is omitted or regenerated. This avoids requiring another multi-GB
SDK checkout for a Java/resource-only app release with identical dependencies.
"""
import argparse
import copy
import gzip
import hashlib
import io
import json
import posixpath
import stat
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

BASE_SHA256='e30b2bdcc3e80ef057966472c8a206424702daf822f21885ff305d0d5c9d7f24'
BASE_URL='https://github.com/embire2/openwebpbx/releases/download/v1.0.18/openwebpbx-1.0.18-android-source.tar.gz'
PREFIX='openwebpbx-android/'
ROOT=Path(__file__).resolve().parents[3]
DOCS=('docs/android-video.md','docs/android.md','docs/android-tenant-addresses-1.0.18.md','docs/android-push.md','docs/android-availability.md','docs/google-play.md','docs/google-play-review.md','packaging/updates/PROTOCOL.md')

def safe(member):
    name=member.name.rstrip('/')
    path=PurePosixPath(name)
    if (not name.startswith(PREFIX) or path.is_absolute() or '..' in path.parts
            or str(path)!=name or '\\' in name or any(ord(c)<32 for c in name)):
        raise ValueError('Unsafe source member')
    if not (member.isfile() or member.issym() or member.isdir()):
        raise ValueError('Unsupported source member')
    if member.size<0 or member.size>256*1024*1024:
        raise ValueError('Oversized source member')
    if member.issym():
        target=posixpath.normpath(posixpath.join(posixpath.dirname(name),member.linkname))
        if member.linkname.startswith('/') or not target.startswith(PREFIX) or '\\' in member.linkname:
            raise ValueError('Source symlink escapes its archive')
    return name

class Reader:
    def __init__(self,stream):self.stream=stream;self.digest=hashlib.sha256();self.bytes=0
    def read(self,length=-1):
        data=self.stream.read(length);self.digest.update(data);self.bytes+=len(data);return data

def scan_baseline(path):
    inventory=None;version=None;members=set();sdk_files=0
    with tarfile.open(path,'r|gz') as base:
        for member in base:
            name=safe(member)
            if name in members:raise ValueError('Duplicate original source member')
            members.add(name)
            if name==PREFIX+'dependency-sources/RUNTIME-DEPENDENCIES.txt':
                if member.size>65536:raise ValueError('Invalid dependency inventory')
                inventory=base.extractfile(member).read()
            if name==PREFIX+'VERSION':version=base.extractfile(member).read(100)
            if name.startswith(PREFIX+'linphone-sdk-5.5.23/') and member.isfile():sdk_files+=1
    return inventory,version,sdk_files

def require_compatible(original_inventory,original_version,sdk_files,inventory):
    if original_inventory!=inventory or original_version!=b'1.0.18\n' or sdk_files<1000:
        raise ValueError('SDK/runtime source baseline is incompatible with this build')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--base-source',type=Path,required=True);parser.add_argument('--runtime-inventory',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.output.exists() or args.output.is_symlink():raise FileExistsError('An existing corresponding-source archive must not be overwritten')
    with args.base_source.open('rb') as source:
        if hashlib.file_digest(source,'sha256').hexdigest()!=BASE_SHA256:raise ValueError('Original published SDK/source archive changed')
    inventory=args.runtime_inventory.read_bytes()
    original_inventory,original_version,sdk_files=scan_baseline(args.base_source)
    require_compatible(original_inventory,original_version,sdk_files,inventory)
    version=(ROOT/'ANDROID_VERSION').read_text().strip()
    if version!='1.0.20':raise ValueError('This refresh applies only to the matching Android 1.0.20 release')
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    subprocess.run(['git','diff','--exit-code','--','mobile/android','ANDROID_VERSION'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
    tracked=subprocess.check_output(['git','ls-files','-z','--','mobile/android'],cwd=ROOT).split(b'\0')
    files=[Path(item.decode()) for item in tracked if item]
    records=[];written=set()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open('wb') as raw,gzip.GzipFile(fileobj=raw,mode='wb',compresslevel=6,mtime=0) as compressed,tarfile.open(fileobj=compressed,mode='w|') as output:
        def write(member,stream=None):
            name=safe(member)
            if name in written:raise ValueError('Duplicate refreshed source member')
            written.add(name);member=copy.copy(member);member.uid=member.gid=0;member.uname=member.gname='';member.mtime=0
            if member.isfile():
                reader=Reader(stream);output.addfile(member,reader)
                if reader.bytes!=member.size:raise ValueError('Source read was incomplete')
                records.append({'path':name,'kind':'file','mode':member.mode,'bytes':reader.bytes,'sha256':reader.digest.hexdigest()})
            else:
                output.addfile(member)
                records.append({'path':name,'kind':'symlink' if member.issym() else 'directory','mode':member.mode,'target':member.linkname})
        with tarfile.open(args.base_source,'r|gz') as base:
            for member in base:
                if member.name.startswith((PREFIX+'linphone-sdk-5.5.23/',PREFIX+'dependency-sources/')):
                    write(member,base.extractfile(member) if member.isfile() else None)
        for relative in sorted(files+[Path(item) for item in DOCS]):
            file=ROOT/relative
            if file.suffix in ('.jks','.keystore','.apk','.aab') or any(part in ('.git','.gradle','build','.kotlin') for part in relative.parts):
                raise ValueError('Private/generated app source cannot be distributed')
            member=tarfile.TarInfo(PREFIX+relative.as_posix());member.mode=stat.S_IMODE(file.lstat().st_mode)
            if file.is_symlink():
                if not file.resolve().is_relative_to(ROOT/'mobile/android'):raise ValueError('App source symlink escapes project')
                member.type=tarfile.SYMTYPE;member.linkname=file.readlink().as_posix();write(member)
            else:
                member.size=file.stat().st_size
                with file.open('rb') as stream:write(member,stream)
        for name,data in [('VERSION',(version+'\n').encode()),('CORE_SOURCE_VERSION',(ROOT/'VERSION').read_bytes())]:
            member=tarfile.TarInfo(PREFIX+name);member.mode=0o644;member.size=len(data);write(member,io.BytesIO(data))
        manifest={'schema':1,'android_version':version,'source_commit':commit,'base_source':{'url':BASE_URL,'sha256':BASE_SHA256},'runtime_inventory_sha256':hashlib.sha256(inventory).hexdigest(),'sdk_files':sdk_files,'files':records}
        manifest_bytes=(json.dumps(manifest,sort_keys=True,separators=(',',':'))+'\n').encode();member=tarfile.TarInfo(PREFIX+'SOURCE-MANIFEST.json');member.mode=0o644;member.size=len(manifest_bytes);output.addfile(member,io.BytesIO(manifest_bytes))
    # Reopen and verify every retained/new byte, including symlink inventory.
    expected={record['path']:record for record in records};seen=set();manifest_seen=False
    with tarfile.open(args.output,'r|gz') as archive:
        for member in archive:
            name=safe(member)
            if name==PREFIX+'SOURCE-MANIFEST.json':
                if manifest_seen or not member.isfile() or archive.extractfile(member).read()!=manifest_bytes:raise ValueError('Refreshed source manifest changed')
                manifest_seen=True;continue
            if name in seen:raise ValueError('Refreshed source contains duplicate members')
            record=expected[name];seen.add(name)
            if member.mode!=record['mode']:raise ValueError('Refreshed source mode changed')
            if member.isfile():
                with archive.extractfile(member) as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
                if member.size!=record['bytes'] or digest!=record['sha256']:raise ValueError('Refreshed source byte verification failed')
            elif member.linkname!=record['target']:raise ValueError('Refreshed source link verification failed')
    if not manifest_seen or seen!=set(expected):raise ValueError('Refreshed source inventory is incomplete')
    with args.output.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
    print(json.dumps({'android_version':version,'source_commit':commit,'files':len(records),'sdk_files':sdk_files,'bytes':args.output.stat().st_size,'sha256':digest}))

if __name__=='__main__':main()
