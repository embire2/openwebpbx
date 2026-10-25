"""Disposable Windows diagnostic only; pinned public20 bootstrap and original Job240."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request
import zipfile

BASE_SHA='9a45d51c1ee1d1f985062fc16fb0cdfaea43aee6c1a7a540a7b820852e776522'
BASE_BYTES=585104517
JOB_SHA='9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448'
def need(value):
    if not value:raise ValueError('Exact disposable Windows diagnostic scope/input required.')
def digest(path):
    with Path(path).open('rb')as file:return hashlib.file_digest(file,'sha256').hexdigest()
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);out=importlib.util.module_from_spec(spec);spec.loader.exec_module(out);return out
def main():
    need(os.name=='nt' and os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx' and sys.version_info[:3]==(3,12,10))
    action=sys.argv[1];root=Path(sys.argv[2]);need(root.is_dir() and not root.is_symlink())
    if action=='prepare':
        need(root.parent==Path(os.environ['RUNNER_TEMP']) and root.name.startswith('mail-dbh-work-'))
        archive=root/'public20.original.zip';need(not archive.exists());deadline=time.monotonic()+600;count=0
        url='https://github.com/embire2/openwebpbx/releases/download/v1.0.20/openwebpbx-1.0.20-windows-x64.zip'
        with urllib.request.urlopen(url,timeout=30)as source,archive.open('xb')as target:
            while True:
                chunk=source.read(1024**2)
                if not chunk:break
                count+=len(chunk);need(count<=BASE_BYTES and time.monotonic()<deadline);target.write(chunk)
        need(count==BASE_BYTES and digest(archive)==BASE_SHA)
        verifier=module('owned_public20_archive',Path(__file__).with_name('windows_candidate_archive.py'))
        receipt=verifier.verify(archive,'1.0.20',BASE_SHA);need(receipt['files']==19166)
        with zipfile.ZipFile(archive)as data:data.extractall(root/'package')
        (root/'public20.safe.json').write_text(json.dumps({'schema':1,'state':'authenticated_public20_only','bytes':count,'sha256':BASE_SHA,'payload_files':receipt['files'],'new_release_qualified':False}))
        return 0
    need(action in ('setup','run','inspect','cleanup') and root==Path(os.environ['RUNNER_TEMP'])/'mail-dbh-evidence'/action)
    fixture=Path(sys.argv[3]);need(fixture==Path(os.environ['ProgramData'])/'OpenWebPBX/mail-dbh-diagnostic'/fixture.name and len(fixture.name)==24 and all(x in '0123456789abcdef'for x in fixture.name))
    php=Path('C:/OpenWebPBX/php/php.exe');script=Path(__file__).with_name('windows_mail_dbh_probe.php');core=Path(__file__).with_name('windows_meeting_owned_process.py');need(digest(core)==JOB_SHA)
    php_hash=digest(php);script_hash=digest(script);result=None;error='none'
    try:result=module('owned_original_job240',core).run([str(php),str(script),action,str(fixture).replace('\\','/')],root,timeout=240)
    except BaseException as failure:error=type(failure).__name__ if type(failure).__name__ in ('TimeoutExpired','RuntimeError','OSError','ValueError')else'other'
    proof=json.loads((root/'process.safe.json').read_text());need(set(proof)=={'schema','created_suspended','assigned_before_resume','resumed','owned_job_terminated','exit_code','owned_processes_closed','handles_closed','ordinary_exit'} and type(proof['schema'])is int and proof['schema']==1)
    need(all(type(proof[name])is bool for name in ('created_suspended','assigned_before_resume','resumed','owned_job_terminated','owned_processes_closed','handles_closed','ordinary_exit')))
    need(digest(core)==JOB_SHA and digest(php)==php_hash and digest(script)==script_hash)
    safe={'schema':1,'state':'failed','action':action,'error_type':error,'exit_code':result.returncode if result else None,'job_sha256':JOB_SHA,'php_sha256':php_hash,'script_sha256':script_hash,'owned_processes_closed':proof['owned_processes_closed'],'handles_closed':proof['handles_closed'],'ordinary_exit':proof['ordinary_exit'],'observation':None}
    if result is not None:
        need(len(result.stdout)<=65536 and len(result.stderr)<=8192)
        safe['observation']=json.loads(result.stdout)
        if result.returncode==0 and proof['ordinary_exit']is True and proof['owned_processes_closed']is True and proof['handles_closed']is True:safe['state']='observed'
    with (root/'result.safe.json').open('x')as output:json.dump(safe,output)
    return 0 if safe['state']=='observed'else 1
if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception:raise SystemExit(1)
