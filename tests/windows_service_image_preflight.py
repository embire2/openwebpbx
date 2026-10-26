"""One owned stopped SCM representation component; never installs or calls a PBX."""
import argparse,hashlib,importlib.util,json,os,re,shutil,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
HELPER='c9bce34d1c158a146cbca8885edc05339b989483be8e3ed8af92fbfd4447b459'
CORE='9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448'
FLAGS='explicit_unquoted_finite_accepted original_quoted_guard_would_refuse absence_before creation_nonce_and_handle_bound service_always_disabled_stopped exact_sc_config_completed cleanup_definition_rechecked owned_service_absent_after service_handle_closed owned_image_removed stock_image_unchanged'.split()
def need(value):
 if not value:raise ValueError('Exact owned stopped SCM representation proof refused.')
def unique(rows):
 out={}
 for k,v in rows:need(k not in out);out[k]=v
 return out
def decode(raw):return json.loads(raw,object_pairs_hook=unique,parse_constant=lambda _:need(False))
def sha(raw):return hashlib.sha256(raw).hexdigest()
def check_native_shape(row):
 need(type(row)is dict and set(row)-({'failure_observation'}if row.get('state')=='failed'else set())==set(FLAGS)|{'schema','state','scope','phase','error_type','native_powershell','new_service_relation','sc_config_relation','explicit_unquoted_relation','installed_PBX_or_historical_path_qualified'})
 need(type(row['schema'])is int and row['schema']==1 and row['scope']=='owned_disabled_stopped_SCM_image_representation_only' and row['native_powershell']=='5.1')
 need(row['state']in ('passed','failed')and row['phase']in ('absence','copy','new_service','sc_config','explicit_unquoted','cleanup','complete'))
 need(type(row['error_type'])is str and re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,79}',row['error_type'])and all(type(row[x])is bool for x in FLAGS)and row['installed_PBX_or_historical_path_qualified']is False)
 for key in ['new_service_relation','sc_config_relation','explicit_unquoted_relation']:need(row[key]in ('quoted_expected','unquoted_expected','canonical_slash_expected','wrong_known_slot','other','unavailable'))
 if 'failure_observation'in row:
  v=row['failure_observation'];need(type(v)is dict and set(v)==set('schema operation source_name source_line hresult owned_sample'.split()))
  need(type(v['schema'])is int and v['schema']==1 and v['operation']in ('absence','copy','new_service','controller_type','service_handle','service_handle_validation','own_row','sc_config','own_row_cleanup','cleanup'))
  need(type(v['source_line'])is int and ((v['source_name']=='unavailable'and v['source_line']==0)or(v['source_name']=='windows_service_image_native.ps1'and 1<=v['source_line']<=10000)))
  need(type(v['hresult'])is int and -2147483648<=v['hresult']<=2147483647)
  v=v['owned_sample']
  if v is not None:
   keys='name_matches description_matches display_matches system_account disabled stopped pid_zero finite_image'.split()
   need(type(v)is dict and set(v)==set(keys)|{'count','image_relation'}and v['count']in ('none','single','multiple'))
   need(v['image_relation']in ('quoted_expected','unquoted_expected','canonical_slash_expected','wrong_known_slot','other','unavailable'))
   need(all(type(v[k])is bool for k in keys)if v['count']=='single'else(v['image_relation']=='unavailable'and all(v[k]is None for k in keys)))
def check_native(row):
 check_native_shape(row)
 need(row['state']=='passed'and row['phase']=='complete'and row['error_type']=='none'and all(row[x]is True for x in FLAGS))
 need(row['explicit_unquoted_relation']=='unquoted_expected')
 need(row['new_service_relation']in ('quoted_expected','unquoted_expected')and row['sc_config_relation']in ('quoted_expected','unquoted_expected'))
def check_job_shape(row):
 need(type(row)is dict and set(row)==set('schema created_suspended assigned_before_resume resumed owned_job_terminated exit_code owned_processes_closed handles_closed ordinary_exit'.split()))
 need(type(row['schema'])is int and row['schema']==1 and (row['exit_code']is None or type(row['exit_code'])is int and 0<=row['exit_code']<=4294967295))
 need(all(type(row[x])is bool for x in 'created_suspended assigned_before_resume resumed owned_job_terminated owned_processes_closed handles_closed ordinary_exit'.split()))
def check_job(row):
 check_job_shape(row)
 need(type(row['exit_code'])is int and row['exit_code']==0 and row['owned_job_terminated']is False)
 need(all(row[x]is True for x in 'created_suspended assigned_before_resume resumed owned_processes_closed handles_closed ordinary_exit'.split()))
def bounded(path):
 with path.open('rb')as stream:raw=stream.read(8193)
 need(0<len(raw)<=8192)
 return raw
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=Path,required=True);args=parser.parse_args()
 need(os.name=='nt' and sys.version_info[:3]==(3,12,10) and os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx')
 need(os.environ.get('GITHUB_REF')=='refs/heads/qualification/windows121-service-image-20261026'and os.environ.get('GITHUB_RUN_ATTEMPT')=='1'and re.fullmatch('[a-f0-9]{40}',os.environ.get('GITHUB_SHA','')))
 evidence=args.evidence;need(evidence.is_absolute()and os.path.normcase(str(evidence))==os.path.normcase(str(Path(os.environ['RUNNER_TEMP'])/'service-image-preflight-evidence'))and not evidence.exists());evidence.mkdir(mode=0o700)
 native=ROOT/'tests/windows_service_image_native.ps1';helper=ROOT/'tests/windows-health-updater-quiescence.ps1';core=ROOT/'tests/windows_meeting_owned_process.py'
 pwsh=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe';need(pwsh.is_file()and not pwsh.is_symlink())
 hashes={name:sha(path.read_bytes())for name,path in [('native',native),('helper',helper),('job',core),('driver',Path(__file__)),('powershell',pwsh)]};need(hashes['helper']==HELPER and hashes['job']==CORE)
 work=Path(tempfile.mkdtemp(prefix='openweb-owned-service-image-'));scope=work/'scope';scope.mkdir();jobdir=work/'job';jobdir.mkdir();before=dict(os.environ);complete=False;error='none';primary_error=None;observation_error='none';started=time.monotonic()
 try:
  spec=importlib.util.spec_from_file_location('owned_original_Job240',core);job=importlib.util.module_from_spec(spec);spec.loader.exec_module(job)
  result=job.run([str(pwsh),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(native),'-SourceRoot',str(ROOT),'-OwnedRoot',str(scope)],jobdir,timeout=240)
  native_raw=bounded(scope/'native.safe.json');(evidence/'native.safe.json').write_bytes(native_raw)
  proof_raw=bounded(jobdir/'process.safe.json');(evidence/'process.safe.json').write_bytes(proof_raw)
  need(result.returncode==0 and len(result.stdout)<=4096 and len(result.stderr)==0);check_native(decode(native_raw));check_job(decode(proof_raw));need(time.monotonic()-started<=125)
  need(dict(os.environ)==before and all(sha(path.read_bytes())==hashes[name]for name,path in [('native',native),('helper',helper),('job',core),('driver',Path(__file__)),('powershell',pwsh)]))
  need({x.name for x in scope.iterdir()}=={'native.safe.json'} and {x.name for x in jobdir.iterdir()}=={'process.safe.json','stdout.private.log','stderr.private.log'})
  for item in [work,*work.rglob('*')]:need(not item.is_symlink()and not(getattr(item.lstat(),'st_file_attributes',0)&0x400)and not(item.is_file()and item.stat().st_size>8192))
  shutil.rmtree(work);need(not work.exists());complete=True
 except BaseException as failure:
  error=type(failure).__name__;primary_error=failure
  # Failed/forced/unknown scope stays retained. Never claim or synthesize cleanup.
  raise
 finally:
  # Failure-only original observation collection never replaces the primary.
  for name,path in [('native.safe.json',scope/'native.safe.json'),('process.safe.json',jobdir/'process.safe.json')]:
   try:
    if path.is_file()and not path.is_symlink():
     raw=bounded(path)
     row=decode(raw)
     if name=='native.safe.json':check_native_shape(row)
     else:check_job_shape(row)
     target=evidence/name
     if target.exists():need(target.read_bytes()==raw)
     else:
      with target.open('xb')as stream:stream.write(raw)
   except BaseException as observed:observation_error=type(observed).__name__
  receipt={'schema':1,'state':'passed_native_component_only'if complete else 'failed_component_no_qualification','run_id':os.environ['GITHUB_RUN_ID'],'source_commit':os.environ['GITHUB_SHA'],'source_inputs':hashes,'native_Job_timeout_seconds':240,'ordinary_owned_job_and_handle_closure':complete,'parent_environment_unchanged':dict(os.environ)==before,'owned_temporary_scope_removed':complete,'historical_d677_raw_path_recovered':False,'installed_PBX_backup_or_full_release_qualified':False,'error_type':error,'observation_error_type':observation_error}
  raw=(json.dumps(receipt,sort_keys=True)+'\n').encode();need(len(raw)<=8192)
  try:
   with(evidence/'source.safe.json').open('xb')as stream:stream.write(raw)
  except BaseException:
   if primary_error is None:raise
if __name__=='__main__':main()
