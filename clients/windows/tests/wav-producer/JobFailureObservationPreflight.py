"""Prepared hosted-Windows owned control only; no PBX, SDK, signing or calling."""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time

CORE_SHA='afb20f0f207ce0928570d8afd8bee08e3b736bffd7f4e48d3f4aa8fae9fc30de'
OBSERVER_SHA='7601f99702cdc75af73c2e7263c37b409f96153df88bf62378e940f952069f4d'

def require(value):
    if not value: raise ValueError('Owned observation control refused.')
def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def ordinary(path):
    path=Path(path)
    for p in (path,*path.parents):
        st=p.lstat();require(not stat.S_ISLNK(st.st_mode) and not getattr(st,'st_file_attributes',0)&0x400)
    return path

def guard():
    require(os.name=='nt' and sys.version_info[:3]==(3,12,10) and os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx')
    require(not Path('C:/OpenWebPBX').exists() and not (Path(os.environ['ProgramData'])/'OpenWebPBX').exists())

def creation_time(handle):
    class FT(ctypes.Structure): _fields_=[('low',ctypes.c_uint32),('high',ctypes.c_uint32)]
    k=ctypes.WinDLL('kernel32',use_last_error=True);f=k.GetProcessTimes
    f.argtypes=[ctypes.c_void_p,*([ctypes.POINTER(FT)]*4)];f.restype=ctypes.c_int32
    values=[FT()for _ in range(4)];require(f(handle,*[ctypes.byref(v)for v in values]));return(values[0].high<<32)|values[0].low

def load(path,name,pin):
    ordinary(path);require(sha(path)==pin);spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def main(root):
    guard();root=ordinary(root);require(root.is_dir()and {x.name for x in root.iterdir()}=={'system-before.json'});ordinary(root/'system-before.json')
    temp=ordinary(os.environ['RUNNER_TEMP']);require(root.parent.resolve()==temp.resolve() and root.name.startswith('phone-wav-observer-preflight-')and len(root.name)==len('phone-wav-observer-preflight-')+32)
    require(all(c in '0123456789abcdef'for c in root.name[-32:]))
    source=ordinary(Path(__file__).resolve());tools=source.parents[2]/'tools'
    core_path=tools/'WavProducerOwnedProcess.py';observer_path=tools/'WavProducerFailureObservation.py'
    core=load(core_path,'preflight_exact_owned_job',CORE_SHA);observation=load(observer_path,'preflight_failure_observation',OBSERVER_SHA)
    python=ordinary(Path(sys.executable));require(python.is_file()and python.suffix.lower()=='.exe')
    result={'schema':1,'state':'failed','scope':'controlled_owned_observer_preflight_only','core_sha256':CORE_SHA,'observer_sha256':OBSERVER_SHA,'preflight_source_sha256':sha(source),'python_sha256':sha(python),'ordinary_control':False,'leftover_control':False,'observer_failure_control':False,'unknown_error_refused':False,'original_cleanup_proofs_preserved':False,'calling_SDK_WAV_Store_qualified':False}
    try:
        clean=root/'ordinary';clean.mkdir();observer=observation.FailureObserver(core,core_path);observer.install()
        try:r=core.run([str(python),'-I','-B',str(source),'--mode','ordinary'],clean,30,working_directory=root)
        finally:observer.restore()
        proof=json.loads((clean/'process.safe.json').read_text());require(r.returncode==0 and proof['ordinary_exit']is True and proof['owned_processes_closed']is True and proof['handles_closed']is True and proof['owned_job_terminated']is False and observer.snapshot is None)
        result['ordinary_control']=True
        left=root/'leftover';left.mkdir();observer=observation.FailureObserver(core,core_path);observer.install();failure=None
        try:core.run([str(python),'-I','-B',str(source),'--mode','parent'],left,30,working_directory=root)
        except RuntimeError as e:failure=e
        finally:observer.restore()
        require(failure is not None);require(observer.record_failure(failure,left,'0'*64))
        info=json.loads((left/'failure-observation.safe.json').read_text());proof=json.loads((left/'process.safe.json').read_text())
        raw=(left/'stdout.private.log').read_bytes();require(len(raw)<=4096);expected=json.loads(raw)
        require(set(expected)=={'pid','creation_filetime'}and type(expected['pid'])is int and type(expected['creation_filetime'])is int)
        require(info['runtime_error']=='ordinary_descendants_survived'and info['core_origin_line']==104 and info['acceptance_or_cleanup_proof']is False)
        snap=info['pre_termination'];require(snap['state']=='observed'and snap['process_handles_closed']is True and not snap['unavailable_pids']and snap['assigned_count']==snap['listed_count']==1 and len(snap['identities'])==1)
        identity=snap['identities'][0];require(identity['pid']==expected['pid']and identity['creation_filetime']==expected['creation_filetime']and identity['image_basename'].lower()=='python.exe')
        require(proof['ordinary_exit']is False and proof['owned_job_terminated']is True and proof['exit_code']==0 and proof['owned_processes_closed']is True and proof['handles_closed']is True)
        result['leftover_control']=True
        # A deliberately failing observer must still delegate the unchanged real
        # termination and must never become a positive identity/cleanup proof.
        refused=root/'observer-refused';refused.mkdir()
        def unavailable(job):raise ValueError('Controlled observer refusal.')
        observer=observation.FailureObserver(core,core_path,unavailable);observer.install();failure=None
        try:core.run([str(python),'-I','-B',str(source),'--mode','parent'],refused,30,working_directory=root)
        except RuntimeError as e:failure=e
        finally:observer.restore()
        require(failure is not None and observer.record_failure(failure,refused,'0'*64))
        info=json.loads((refused/'failure-observation.safe.json').read_text());proof=json.loads((refused/'process.safe.json').read_text())
        require(info['pre_termination']=={'state':'observer_refused'}and info['acceptance_or_cleanup_proof']is False)
        require(proof['ordinary_exit']is False and proof['owned_job_terminated']is True and proof['owned_processes_closed']is True and proof['handles_closed']is True)
        result['observer_failure_control']=True
        unknown=observation.error_enum(RuntimeError('Untrusted message is never exported.'),core_path)
        require(unknown=={'runtime_error':'unclassified','core_origin_line':None});result['unknown_error_refused']=True
        require(sha(core_path)==CORE_SHA and sha(observer_path)==OBSERVER_SHA)
        result['original_cleanup_proofs_preserved']=True;result['state']='passed_owned_observer_controls_only'
    finally:
        with (root/'preflight.safe.json').open('x')as f:json.dump(result,f,separators=(',',':'));f.flush();os.fsync(f.fileno())
    require(result['state']=='passed_owned_observer_controls_only')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--root');p.add_argument('--mode',choices=['ordinary','parent','descendant']);a=p.parse_args();guard()
    if a.mode=='ordinary':raise SystemExit(0)
    if a.mode=='descendant':time.sleep(30);raise SystemExit(0)
    if a.mode=='parent':
        child=subprocess.Popen([sys.executable,'-I','-B',str(Path(__file__).resolve()),'--mode','descendant'],stdin=subprocess.DEVNULL)
        created=creation_time(int(child._handle));print(json.dumps({'pid':child.pid,'creation_filetime':created}),flush=True);raise SystemExit(0)
    require(a.root is not None);main(a.root)
