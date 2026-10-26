"""Small unchanged native listener repro; raw native output remains private."""
import argparse,hashlib,importlib.util,json,os,re,shutil,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
PINS={'native':'32fbf9074500f4c9a367904dd0833ffa2a25bdbac94d819360945ec8ff0c3934','common':'18ca8ea882873a6a495793349c34e306c9ced5e49a4b07015577bdf903508c28','gates':'58973e24a201799c10ddb5d96c197da4c1b4fef6e20ec26dea5b528b7475ca27','suite':'38b150900d771f0b911e882e21c6428c46ea8c404db0ec9bf39904d26d3633c9','job':'9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448'}
POSITIVE='actual_native_defender actual_os_listener_ownership service_identity_adapter_double global_policy_exact actual_throw_after_create_and_enable idempotent foreign_named_rule_preserved configured_private_ports_excluded profiles_all_enabled_at_observation'.split()
NEGATIVE='firewall_enforcement_tested firewall_profiles_changed installed_server_changed calls_placed'.split()
WRAPPER_KEYS='schema scope state phase native_invoked caught_error error_type hresult source_name source_line stack_frames stack_frames_truncated error_observation_complete original_sources_unchanged earlier_native_primary_recovered native_cleanup_qualified_by_wrapper'.split()
def need(value):
 if not value:raise ValueError('Exact unchanged native listener component refused.')
def unique(items):
 out={}
 for key,value in items:need(key not in out);out[key]=value
 return out
def decode(raw):return json.loads(raw,object_pairs_hook=unique,parse_constant=lambda _:need(False))
def sha(raw):return hashlib.sha256(raw).hexdigest()
def native_shape(row):
 need(type(row)is dict and set(row)==set(POSITIVE+NEGATIVE+['schema','producer','state','checks']))
 need(type(row['schema'])is int and row['schema']==1 and row['producer']=='windows_public_listeners_native.ps1'and row['state']=='passed'and type(row['checks'])is int and 21<=row['checks']<=100000)
 need(all(type(row[k])is bool for k in POSITIVE+NEGATIVE))
def native_pass(row,exit_code):
 native_shape(row);need(type(exit_code)is int and exit_code==0 and all(row[k]is True for k in POSITIVE)and all(row[k]is False for k in NEGATIVE))
def wrapper_shape(row):
 need(type(row)is dict and set(row)==set(WRAPPER_KEYS)and type(row['schema'])is int and row['schema']==1 and row['scope']=='unchanged_owned_native_public_listener_component_only')
 need(row['state']in ('failed','returned')and row['phase']in ('input','native','complete'))
 need(all(type(row[k])is bool for k in ['native_invoked','caught_error','stack_frames_truncated','error_observation_complete','original_sources_unchanged','earlier_native_primary_recovered','native_cleanup_qualified_by_wrapper']))
 need(row['earlier_native_primary_recovered']is False and row['native_cleanup_qualified_by_wrapper']is False)
 need(type(row['error_type'])is str and re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,79}',row['error_type'])and type(row['hresult'])is int and -2147483648<=row['hresult']<=2147483647)
 need(type(row['source_line'])is int and ((row['source_name']=='unavailable'and row['source_line']==0)or(row['source_name']in ('windows_public_listeners_native.ps1','PublicAccess.Common.ps1','Restore-Gates.ps1','windows_public_listeners_component.ps1')and 1<=row['source_line']<=100000)))
 frames=row['stack_frames'];need(type(frames)is list and len(frames)<=4)
 for frame in frames:need(type(frame)is dict and set(frame)=={'source_name','source_line'}and frame['source_name']in ('windows_public_listeners_native.ps1','PublicAccess.Common.ps1','Restore-Gates.ps1','windows_public_listeners_component.ps1')and type(frame['source_line'])is int and 1<=frame['source_line']<=100000)
 if row['state']=='returned':need(row['phase']=='complete'and row['native_invoked']is True and row['caught_error']is False and row['error_type']=='none'and row['hresult']==0 and row['error_observation_complete']is False and row['source_name']=='unavailable'and not frames and row['stack_frames_truncated']is False)
 else:need(row['caught_error']is True)
def job_shape(row):
 need(type(row)is dict and set(row)==set('schema created_suspended assigned_before_resume resumed owned_job_terminated exit_code owned_processes_closed handles_closed ordinary_exit'.split())and type(row['schema'])is int and row['schema']==1)
 need(row['exit_code']is None or type(row['exit_code'])is int and 0<=row['exit_code']<=4294967295)
 need(all(type(row[k])is bool for k in 'created_suspended assigned_before_resume resumed owned_job_terminated owned_processes_closed handles_closed ordinary_exit'.split()))
def job_pass(row):
 job_shape(row);need(row['exit_code']==0 and row['owned_job_terminated']is False and all(row[k]is True for k in 'created_suspended assigned_before_resume resumed owned_processes_closed handles_closed ordinary_exit'.split()))
def bounded(path,limit):
 need(path.is_file()and not path.is_symlink()and not(getattr(path.lstat(),'st_file_attributes',0)&0x400))
 with path.open('rb')as stream:raw=stream.read(limit+1)
 need(0<len(raw)<=limit);return raw
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=Path,required=True);args=parser.parse_args()
 need(os.name=='nt'and sys.version_info[:3]==(3,12,10)and sys.maxsize>2**32 and os.environ.get('GITHUB_ACTIONS')=='true'and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx')
 need(os.environ.get('GITHUB_REF')=='refs/heads/qualification/windows121-listener-native-20261026'and os.environ.get('GITHUB_RUN_ATTEMPT')=='1'and re.fullmatch('[a-f0-9]{40}',os.environ.get('GITHUB_SHA',''))and re.fullmatch('[1-9][0-9]{0,19}',os.environ.get('GITHUB_RUN_ID',''))and os.path.normcase(sys.executable)==os.path.normcase(os.environ.get('OWNED_PYTHON','')))
 evidence=args.evidence;need(evidence.is_absolute()and os.path.normcase(str(evidence))==os.path.normcase(str(Path(os.environ['RUNNER_TEMP'])/'listener-native-component-evidence'))and not evidence.exists());evidence.mkdir(mode=0o700)
 paths={'native':ROOT/'tests/windows_public_listeners_native.ps1','common':ROOT/'packaging/windows/PublicAccess.Common.ps1','gates':ROOT/'packaging/windows/Restore-Gates.ps1','suite':ROOT/'tests/windows-suite.ps1','job':ROOT/'tests/windows_meeting_owned_process.py','wrapper':ROOT/'tests/windows_public_listeners_component.ps1','driver':Path(__file__),'workflow':ROOT/'.github/workflows/windows-listener-native-component.yml','powershell':Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'}
 need(all(p.is_file()and not p.is_symlink()and not(getattr(p.lstat(),'st_file_attributes',0)&0x400)for p in paths.values()));hashes={k:sha(p.read_bytes())for k,p in paths.items()};need(all(hashes[k]==v for k,v in PINS.items()))
 work=Path(tempfile.mkdtemp(prefix='openweb-original-listener-'));scope=work/'scope';scope.mkdir();jobdir=work/'job';jobdir.mkdir();before=dict(os.environ);complete=False;primary=None;error='none';observation_error='none';child_exit=None;native_observed=False;ordinary_job=False
 def preserve(name,path,validator,limit):
  nonlocal observation_error
  try:
   if path.is_file():
    raw=bounded(path,limit);validator(decode(raw));target=evidence/name
    if target.exists():need(target.read_bytes()==raw)
    else:
     with target.open('xb')as stream:stream.write(raw)
  except BaseException as failure:observation_error=type(failure).__name__
 try:
  spec=importlib.util.spec_from_file_location('original_Job240',paths['job']);job=importlib.util.module_from_spec(spec);spec.loader.exec_module(job)
  result=job.run([str(paths['powershell']),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(paths['wrapper']),'-SourceRoot',str(ROOT),'-OwnedRoot',str(scope)],jobdir,timeout=240)
  child_exit=result.returncode
  # A report emitted before native finally fails remains an observation only.
  preserve('native-report.safe.json',jobdir/'stdout.private.log',native_shape,16384)
  raw=bounded(jobdir/'stdout.private.log',16384);row=decode(raw);native_pass(row,child_exit)
  wrapped=decode(bounded(scope/'wrapper.safe.json',4096));wrapper_shape(wrapped);need(wrapped['state']=='returned'and wrapped['original_sources_unchanged']is True)
  proof=decode(bounded(jobdir/'process.safe.json',8192));job_pass(proof)
  need(dict(os.environ)==before and all(sha(p.read_bytes())==hashes[k]for k,p in paths.items()))
  need({p.name for p in scope.iterdir()}=={'wrapper.safe.json'}and{p.name for p in jobdir.iterdir()}=={'process.safe.json','stdout.private.log','stderr.private.log'})
  for item in [work,*work.rglob('*')]:need(not item.is_symlink()and not(getattr(item.lstat(),'st_file_attributes',0)&0x400)and not(item.is_file()and item.stat().st_size>8388608))
  preserve('wrapper.safe.json',scope/'wrapper.safe.json',wrapper_shape,4096);preserve('process.safe.json',jobdir/'process.safe.json',job_shape,8192);need(observation_error=='none')
  # Only validated closed records copy; arbitrary stdout/stderr remain private.
  streams={k:{'available':True,'bytes':(jobdir/(k+'.private.log')).stat().st_size,'nonempty':(jobdir/(k+'.private.log')).stat().st_size>0,'count_capped':False}for k in ('stdout','stderr')}
  shutil.rmtree(work);need(not work.exists());complete=True;native_observed=True;ordinary_job=True
 except BaseException as failure:
  primary=failure;error=type(failure).__name__;raise
 finally:
  if not complete:
   streams={}
   for k in ('stdout','stderr'):
    path=jobdir/(k+'.private.log');value=None
    if path.is_file()and not path.is_symlink():value=path.stat().st_size
    streams[k]={'available':value is not None,'bytes':min(value,8388609)if value is not None else None,'nonempty':value>0 if value is not None else None,'count_capped':value is not None and value>8388608}
   preserve('native-report.safe.json',jobdir/'stdout.private.log',native_shape,16384)
   preserve('wrapper.safe.json',scope/'wrapper.safe.json',wrapper_shape,4096);preserve('process.safe.json',jobdir/'process.safe.json',job_shape,8192)
   native_observed=(evidence/'native-report.safe.json').is_file()
   try:
    proof=decode(bounded(jobdir/'process.safe.json',8192));job_shape(proof);child_exit=proof['exit_code'];ordinary_job=proof['ordinary_exit']
   except BaseException:pass
  receipt={'schema':1,'state':'passed_native_component_only'if complete else 'failed_component_cleanup_unqualified','run_id':os.environ['GITHUB_RUN_ID'],'source_commit':os.environ['GITHUB_SHA'],'source_inputs':hashes,'original_native_attempt_limit':1,'original_Job_timeout_seconds':240,'child_exit':child_exit,'streams':streams,'closed_original_report_observed':native_observed,'report_alone_authorizes_nothing':True,'ordinary_owned_Job_exit_observed':ordinary_job,'parent_environment_unchanged':dict(os.environ)==before,'owned_driver_scope_removed':complete,'native_cleanup_qualified':complete,'earlier_native_primary_recovered':False,'historical_failure_or_PBX_release_qualified':False,'error_type':error,'observation_error_type':observation_error}
  raw=(json.dumps(receipt,sort_keys=True)+'\n').encode();need(len(raw)<=8192)
  try:
   with(evidence/'source.safe.json').open('xb')as stream:stream.write(raw)
  except BaseException:
   if primary is None:raise
if __name__=='__main__':
 try:main()
 except BaseException:print('Unchanged native listener component refused; cleanup and PBX qualification remain unqualified.',file=sys.stderr);sys.exit(1)
