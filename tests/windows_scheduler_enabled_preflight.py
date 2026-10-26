"""One owned never-started Scheduler default export component; no installed PBX."""
import argparse,hashlib,importlib.util,json,os,re,shutil,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
CORE='9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448'
PINS={'job':CORE,'backup':'3b27c75c1c47989c99b3f551689fa9895810f5e22e40f0a296057a6d8dd17c6d','installer':'02b2ef281e28e7b005eb1468822af5b3ed5ca48211abeaca2264a5721ceb0992','health':'c9bce34d1c158a146cbca8885edc05339b989483be8e3ed8af92fbfd4447b459'}
FLAGS='absence_before creation_nonce_bound source_owned settings_match_installer no_triggers never_run_observed owned_name_identity_adapter original_xml_comparisons_unchanged default_omission_reproduced cleanup_definition_hash_rechecked owned_task_absent_after stock_image_unchanged source_unchanged historical_failed_XML_or_backup_qualified'.split()
REQUIRED=[x for x in FLAGS if x not in ('default_omission_reproduced','historical_failed_XML_or_backup_qualified')]
def need(value):
 if not value:raise ValueError('Exact owned Scheduler default export component refused.')
def unique(rows):
 out={}
 for k,v in rows:need(k not in out);out[k]=v
 return out
def decode(raw):return json.loads(raw,object_pairs_hook=unique,parse_constant=lambda _:need(False))
def sha(raw):return hashlib.sha256(raw).hexdigest()
def check_native_shape(row):
 need(type(row)is dict and set(row)==set(FLAGS)|set('schema state scope phase error_type cleanup_error_type native_powershell original_enabled original_count original_literal disabled_enabled disabled_count disabled_literal original_comparer_result'.split()))
 need(type(row['schema'])is int and row['schema']==1 and row['scope']=='owned_never_started_Scheduler_default_enabled_only' and row['native_powershell']=='5.1')
 need(row['state']in ('passed','failed')and row['phase']in ('absence','register','original_export','disable','disabled_export','original_comparer','cleanup','complete'))
 need(all(type(row[x])is bool for x in FLAGS)and row['historical_failed_XML_or_backup_qualified']is False)
 for x in ('error_type','cleanup_error_type'):need(type(row[x])is str and re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,79}',row[x]))
 for prefix in ('original','disabled'):
  need(row[prefix+'_enabled']is None or type(row[prefix+'_enabled'])is bool)
  count=row[prefix+'_count'];literal=row[prefix+'_literal']
  need(count in ('unavailable','none','single','multiple')and literal in ('unavailable','absent','true','false','other','multiple'))
  need((count,literal)in {('unavailable','unavailable'),('none','absent'),('single','true'),('single','false'),('single','other'),('multiple','multiple')})
 need(row['original_comparer_result']in ('unavailable','accepted','enabled_node_guard_refused','disabled_reenabled_guard_refused','definition_guard_refused'))
 reproduced=row['original_enabled']is True and row['original_count']=='none'and row['original_literal']=='absent'and row['disabled_count']=='single'and row['disabled_literal']=='false'and row['original_comparer_result']=='enabled_node_guard_refused'
 need(row['default_omission_reproduced']is reproduced)
def check_native(row):
 check_native_shape(row)
 need(row['state']=='passed'and row['phase']=='complete'and row['error_type']=='none'and row['cleanup_error_type']=='none'and all(row[x]is True for x in REQUIRED))
 need(row['original_enabled']is True and row['disabled_enabled']is False and row['original_count']in ('none','single')and row['original_literal']in ('absent','true')and row['disabled_count']=='single'and row['disabled_literal']=='false')
 if row['original_count']=='none':need(row['original_comparer_result']=='enabled_node_guard_refused'and row['default_omission_reproduced']is True)
 else:need(row['original_comparer_result']in ('accepted','definition_guard_refused')and row['default_omission_reproduced']is False)
def check_job_shape(row):
 need(type(row)is dict and set(row)==set('schema created_suspended assigned_before_resume resumed owned_job_terminated exit_code owned_processes_closed handles_closed ordinary_exit'.split()))
 need(type(row['schema'])is int and row['schema']==1 and (row['exit_code']is None or type(row['exit_code'])is int and 0<=row['exit_code']<=4294967295))
 need(all(type(row[x])is bool for x in 'created_suspended assigned_before_resume resumed owned_job_terminated owned_processes_closed handles_closed ordinary_exit'.split()))
def check_job(row):
 check_job_shape(row)
 need(type(row['exit_code'])is int and row['exit_code']==0 and row['owned_job_terminated']is False)
 need(all(row[x]is True for x in 'created_suspended assigned_before_resume resumed owned_processes_closed handles_closed ordinary_exit'.split()))
def bounded(path):
 need(path.is_file()and not path.is_symlink()and not(getattr(path.lstat(),'st_file_attributes',0)&0x400))
 with path.open('rb')as stream:raw=stream.read(8193)
 need(0<len(raw)<=8192)
 return raw
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=Path,required=True);args=parser.parse_args()
 need(os.name=='nt'and sys.version_info[:3]==(3,12,10)and sys.maxsize>2**32 and os.environ.get('GITHUB_ACTIONS')=='true'and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx')
 need(os.environ.get('GITHUB_REF')=='refs/heads/qualification/windows121-scheduler-enabled-20261026'and os.environ.get('GITHUB_RUN_ATTEMPT')=='1'and re.fullmatch('[a-f0-9]{40}',os.environ.get('GITHUB_SHA',''))and re.fullmatch('[1-9][0-9]{0,19}',os.environ.get('GITHUB_RUN_ID','')))
 need(os.path.normcase(sys.executable)==os.path.normcase(os.environ.get('OWNED_PYTHON','')))
 evidence=args.evidence;need(evidence.is_absolute()and os.path.normcase(str(evidence))==os.path.normcase(str(Path(os.environ['RUNNER_TEMP'])/'scheduler-enabled-preflight-evidence'))and not evidence.exists());evidence.mkdir(mode=0o700)
 paths={'native':ROOT/'tests/windows_scheduler_enabled_native.ps1','backup':ROOT/'tests/windows-backup-updater-quiescence.ps1','installer':ROOT/'packaging/windows/Install-Updater.ps1','health':ROOT/'tests/windows-health-updater-quiescence.ps1','job':ROOT/'tests/windows_meeting_owned_process.py','driver':Path(__file__),'workflow':ROOT/'.github/workflows/windows-scheduler-enabled-preflight.yml','powershell':Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'}
 need(all(p.is_file()and not p.is_symlink()and not(getattr(p.lstat(),'st_file_attributes',0)&0x400)for p in paths.values()))
 hashes={name:sha(path.read_bytes())for name,path in paths.items()};need(all(hashes[name]==pin for name,pin in PINS.items()))
 work=Path(tempfile.mkdtemp(prefix='openweb-owned-scheduler-enabled-'));scope=work/'scope';scope.mkdir();jobdir=work/'job';jobdir.mkdir();before=dict(os.environ);complete=False;error='none';primary_error=None;observation_error='none';started=time.monotonic()
 try:
  spec=importlib.util.spec_from_file_location('owned_original_Job240',paths['job']);job=importlib.util.module_from_spec(spec);spec.loader.exec_module(job)
  result=job.run([str(paths['powershell']),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(paths['native']),'-SourceRoot',str(ROOT),'-OwnedRoot',str(scope)],jobdir,timeout=240)
  native_raw=bounded(scope/'native.safe.json');check_native(decode(native_raw))
  proof_raw=bounded(jobdir/'process.safe.json');check_job(decode(proof_raw))
  need(result.returncode==0 and len(result.stdout)<=4096 and len(result.stderr)==0 and time.monotonic()-started<=125)
  need(dict(os.environ)==before and all(sha(path.read_bytes())==hashes[name]for name,path in paths.items()))
  need({x.name for x in scope.iterdir()}=={'native.safe.json'}and{x.name for x in jobdir.iterdir()}=={'process.safe.json','stdout.private.log','stderr.private.log'})
  for item in [work,*work.rglob('*')]:need(not item.is_symlink()and not(getattr(item.lstat(),'st_file_attributes',0)&0x400)and not(item.is_file()and item.stat().st_size>8192))
  for name,raw in [('native.safe.json',native_raw),('process.safe.json',proof_raw)]:
   with(evidence/name).open('xb')as stream:stream.write(raw)
  shutil.rmtree(work);need(not work.exists());complete=True
 except BaseException as failure:
  error=type(failure).__name__;primary_error=failure
  # Failed/forced/unknown scope stays private. Never synthesize cleanup.
  raise
 finally:
  for name,path in [('native.safe.json',scope/'native.safe.json'),('process.safe.json',jobdir/'process.safe.json')]:
   try:
    if path.is_file():
     raw=bounded(path);row=decode(raw)
     if name=='native.safe.json':check_native_shape(row)
     else:check_job_shape(row)
     target=evidence/name
     if target.exists():need(target.read_bytes()==raw)
     else:
      with target.open('xb')as stream:stream.write(raw)
   except BaseException as observed:observation_error=type(observed).__name__
  receipt={'schema':1,'state':'passed_native_component_only'if complete else 'failed_component_no_qualification','run_id':os.environ['GITHUB_RUN_ID'],'source_commit':os.environ['GITHUB_SHA'],'source_inputs':hashes,'native_Job_timeout_seconds':240,'ordinary_owned_job_and_handle_closure':complete,'parent_environment_unchanged':dict(os.environ)==before,'owned_temporary_scope_removed':complete,'historical_failed_XML_recovered':False,'installed_PBX_backup_or_full_release_qualified':False,'error_type':error,'observation_error_type':observation_error}
  raw=(json.dumps(receipt,sort_keys=True)+'\n').encode();need(len(raw)<=8192)
  try:
   with(evidence/'source.safe.json').open('xb')as stream:stream.write(raw)
  except BaseException:
   if primary_error is None:raise
if __name__=='__main__':
 try:main()
 except BaseException:
  # Original native error remains in private Job logs and typed receipts.
  print('Scheduler default component refused; no qualification.',file=sys.stderr);sys.exit(1)
