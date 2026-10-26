"""Disposable native component runner; original Windows Job240 supervision only."""
import argparse,hashlib,importlib.util,json,os,re,sys,uuid
from pathlib import Path
CORE_SHA='9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448'
def require(value):
 if not value:raise ValueError('Owned native LocalService component refused.')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def ordinary(path):
 path=Path(path)
 for p in [path,*path.parents]:require(not p.is_symlink()and not getattr(p.lstat(),'st_file_attributes',0)&0x400)
 return path
p=argparse.ArgumentParser();p.add_argument('--source-commit',required=True);a=p.parse_args()
require(os.name=='nt'and os.environ.get('GITHUB_ACTIONS')=='true'and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx')
require(re.fullmatch('[a-f0-9]{40}',a.source_commit)is not None and a.source_commit==os.environ.get('GITHUB_SHA'))
require(sys.version_info[:3]==(3,12,10));tools=ordinary(Path(__file__).resolve().parent);core_path=ordinary(tools/'windows_meeting_owned_process.py');require(digest(core_path)==CORE_SHA)
for name in ['windows-backup-localservice-task.ps1','windows_backup_localservice_preflight.ps1','windows_backup_localservice_read_probe.py']:ordinary(tools/name)
core_spec=importlib.util.spec_from_file_location('exact_original_component_job',core_path);core=importlib.util.module_from_spec(core_spec);core_spec.loader.exec_module(core)
root=ordinary(Path(os.environ['RUNNER_TEMP']));work=root/('OpenWebPBX-BackupPublicationEvidence-'+uuid.uuid4().hex);work.mkdir(mode=0o700);evidence=work/'safe';evidence.mkdir(mode=0o700);job=work/'job';job.mkdir(mode=0o700)
source={name:digest(tools/name)for name in ['windows-backup-localservice-task.ps1','windows_backup_localservice_preflight.ps1','windows_backup_localservice_read_probe.py','windows_backup_localservice_preflight.py','windows_meeting_owned_process.py']}
record={'schema':1,'source_commit':a.source_commit,'source_files':source,'python_version':'.'.join(map(str,sys.version_info[:3])),'job_timeout_seconds':240,'core_sha256':CORE_SHA,'calling_backup_restore_release_qualified':False}
ps=ordinary(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe');previous=os.environ.get('OPENWEB_WINDOWS_BACKUP_TEST');os.environ['OPENWEB_WINDOWS_BACKUP_TEST']='1'
state='failed';error_type='none'
try:
 result=core.run([str(ps),'-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(tools/'windows_backup_localservice_preflight.ps1'),'-PythonExecutable',str(Path(sys.executable).resolve()),'-EvidenceDirectory',str(evidence)],job,240)
 require(result.returncode==0);state='observed_complete_component'
except BaseException as error:
 error_type=type(error).__name__ if type(error).__name__ in ['RuntimeError','ValueError','TimeoutExpired','OSError'] else 'other'
finally:
 (evidence/'source.safe.json').write_text(json.dumps(record,separators=(',',':')),encoding='utf-8')
 if previous is None:os.environ.pop('OPENWEB_WINDOWS_BACKUP_TEST',None)
 else:os.environ['OPENWEB_WINDOWS_BACKUP_TEST']=previous
 proof_path=job/'process.safe.json';proof=json.loads(proof_path.read_text())if proof_path.exists()else None
 if proof is not None:(evidence/'job.safe.json').write_text(json.dumps(proof,separators=(',',':')),encoding='utf-8')
 (evidence/'runner.safe.json').write_text(json.dumps({'schema':1,'state':state,'error_type':error_type,'original_job_source_sha256':CORE_SHA,'source_inputs_unchanged':all(digest(tools/n)==v for n,v in source.items()),'calling_backup_restore_release_qualified':False},separators=(',',':')),encoding='utf-8')
 output=Path(os.environ['GITHUB_OUTPUT']);require(output.is_file())
 with output.open('a',encoding='utf-8')as f:f.write('evidence_root='+str(evidence)+'\n')
require(state=='observed_complete_component')
print(json.dumps({'state':'native_component_completed_pending_strict_reader','actual_release_qualified':False}))
