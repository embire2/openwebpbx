#!/usr/bin/env python3
"""Bundle the app, exact SDK/submodule source and Maven source JARs, without private data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import urllib.request

p = argparse.ArgumentParser()
p.add_argument('--sdk-source', type=Path, required=True)
p.add_argument('--dependency-sources', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
project = Path(__file__).resolve().parents[1]
android_version = re.search(r'versionName = .*\?: "([^"]+)"', (project/'app/build.gradle.kts').read_text()).group(1)
assert re.fullmatch(r'\d+\.\d+\.\d+', android_version)
sdk = a.sdk_source.resolve()
assert subprocess.check_output(['git','-C',str(sdk),'rev-parse','HEAD'], text=True).strip() == '348e8de32fb2ac56b7b0a7167968fc1ac707f7b2', 'Unexpected SDK revision'
submodules = subprocess.check_output(['git','-C',str(sdk),'submodule','status','--recursive'],text=True)
assert not any(line[:1] in ('-', '+', 'U') for line in submodules.splitlines()), 'SDK submodule versions do not match'
def sdk_clean():
    assert not subprocess.check_output(['git','-C',str(sdk),'status','--porcelain','--untracked-files=no','--ignore-submodules=untracked']), 'SDK or submodule tracked source is dirty'
sdk_clean()
sdk_files = [sdk/os.fsdecode(name) for name in subprocess.check_output(['git','-C',str(sdk),'ls-files','--recurse-submodules','-z']).split(b'\0') if name]
assert sdk_files, 'Missing tracked SDK source'
a.dependency_sources.mkdir(parents=True,exist_ok=True)
inventory = (project/'app/build/runtime-dependencies.txt').read_text().splitlines()
manifest = []
for coordinate in inventory:
    group, artifact, version = coordinate.split(':')
    if group == 'org.linphone':
        continue
    path = '/'.join((group.replace('.','/'),artifact,version,f'{artifact}-{version}-sources.jar'))
    target = a.dependency_sources/(group+'-'+artifact+'-'+version+'-sources.jar')
    if not target.exists():
        urls = ['https://dl.google.com/dl/android/maven2/'+path, 'https://repo.maven.apache.org/maven2/'+path]
        for url in urls:
            try:
                with urllib.request.urlopen(url,timeout=30) as response: data=response.read(64*1024*1024)
                target.write_bytes(data)
                break
            except Exception:
                continue
        else:
            raise RuntimeError('No source JAR for '+coordinate)
    manifest.append({'coordinate':coordinate,'source_file':target.name,'sha256':hashlib.sha256(target.read_bytes()).hexdigest()})
(a.dependency_sources/'MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
(a.dependency_sources/'LINPHONE-SUBMODULES.txt').write_text(submodules)
(a.dependency_sources/'RUNTIME-DEPENDENCIES.txt').write_text('\n'.join(inventory)+'\n')
a.output.parent.mkdir(parents=True,exist_ok=True)
def permitted(path):
    return not any(part in ('.git','.gradle','.kotlin','__pycache__','build','.idea') for part in path.parts) and path.name not in ('local.properties','signing.properties') and path.suffix not in ('.jks','.keystore')
def add_source(archive,file,source,name):
    relative=file.relative_to(source)
    assert not relative.is_absolute() and '..' not in relative.parts, 'Unsafe source path'
    assert file.is_file() or file.is_symlink(), 'Tracked source file is missing'
    if file.is_symlink():
        assert file.resolve().is_relative_to(source.resolve()), 'Source symlink escapes tree'
    info=archive.gettarinfo(str(file),arcname=name+'/'+relative.as_posix());info.uid=info.gid=0;info.uname=info.gname='';info.mtime=0
    if file.is_symlink():archive.addfile(info)
    else:
        with file.open('rb') as stream:archive.addfile(info,stream)
with tarfile.open(a.output, 'w:gz', compresslevel=6) as archive:
    for source,name in ((project,'openwebpbx-android/mobile/android'),(a.dependency_sources,'openwebpbx-android/dependency-sources')):
        for file in sorted(source.rglob('*')):
            relative=file.relative_to(source)
            if (file.is_file() or file.is_symlink()) and permitted(relative):add_source(archive,file,source,name)
    # A tracked build/ directory in the SDK contains upstream CMake/Android
    # source, unlike the app's generated Gradle build directory.
    for file in sorted(sdk_files):add_source(archive,file,sdk,'openwebpbx-android/linphone-sdk-5.5.23')
    # Android releases can advance independently of a complete server installer.
    import io
    marker=android_version.encode()+b'\n';info=tarfile.TarInfo('openwebpbx-android/VERSION');info.mode=0o644;info.size=len(marker);archive.addfile(info,io.BytesIO(marker))
    archive.add(project.parents[1]/'VERSION',arcname='openwebpbx-android/CORE_SOURCE_VERSION')
    for relative in ['docs/android-video.md','docs/android.md','docs/android-tenant-addresses-1.0.18.md','docs/android-push.md','docs/android-availability.md','docs/google-play.md','docs/google-play-review.md','packaging/updates/PROTOCOL.md']:
        archive.add(project.parents[1]/relative,arcname='openwebpbx-android/'+relative)
sdk_clean()
print(json.dumps({'archive':str(a.output),'bytes':a.output.stat().st_size,'sha256':hashlib.sha256(a.output.read_bytes()).hexdigest(),'dependency_sources':len(manifest),'tracked_sdk_files':len(sdk_files)}))
