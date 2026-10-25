"""Isolated source-pinned stock metadata: same direct and original owned-Job chains."""
import argparse,hashlib,importlib.util,json,os,re,shutil,stat,subprocess,sys,tempfile
from pathlib import Path
HERE=Path(__file__).resolve().parent
PINS={'windows-meet-wss-path.ps1':'1af196ada3620ff909ed2d6d5759f688b351615ace70dffc4cf132688b323062','windows_meeting_owned_process.py':'9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448','windows-meet-wss-failure.cjs':'d66b6d3e6115ec4c121098d5348724996dcd49369beae268d8fd04980b5c2239'}
FIELDS={'command_type','command_name','module_name','module_path','module_base','module_version','module_guid','source_file','implementation'}
def need(v):
 if not v:raise ValueError('Closed component guard refused.')
def pairs(rows):
 result={}
 for k,v in rows:need(k not in result);result[k]=v
 return result
def decode(raw):return json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:need(False))
def ordinary(p):
 for x in (Path(p),*Path(p).parents):need(not x.is_symlink()and not(x.stat().st_file_attributes&stat.FILE_ATTRIBUTE_REPARSE_POINT))
ERRORS={'RuntimeException','CommandNotFoundException','FileNotFoundException','IOException','UnauthorizedAccessException','PSInvalidOperationException','InvalidOperationException','CmdletInvocationException','TypeLoadException','other'}
def error(value):need(type(value)is dict and set(value)=={'error_type','hresult'}and value['error_type']in ERRORS and type(value['hresult'])is int and -2147483648<=value['hresult']<=2147483647)
def outcome(value):
 need(type(value)is dict and set(value)=={'exit_code','error_type','code_kind','errno','killed','signal','elapsed_ms','powershell_state','powershell'})
 need(value['error_type']in('none','Error','TypeError','RangeError','TimeoutError','AbortError','other')and value['code_kind']in('none','exit','ENOENT','EACCES','EPERM','ETIMEDOUT','ABORT_ERR','ERR_CHILD_PROCESS_STDIO_MAXBUFFER','other')and value['signal']in('none','SIGTERM','SIGKILL','other')and value['powershell_state']in('absent','invalid')and value['powershell']is None)
 for key,lo,hi in [('exit_code',-2147483648,4294967295),('errno',-2147483648,2147483647)]:need(value[key]is None or type(value[key])is int and lo<=value[key]<=hi)
 need((value['killed']is None or type(value['killed'])is bool)and type(value['elapsed_ms'])is int and 0<=value['elapsed_ms']<=32000)
def validate(row):
 need(type(row)is dict and set(row)=={'schema','state','producer','bootstrap','imports','commands','observer_errors','original_helpers_source_sha256','diagnostic_only','wss_eligible','media_eligible','restore_eligible','release_eligible','owner_eligible'})
 need(type(row['schema'])is int and row['schema']==1 and row['state']=='observed'and row['producer']=='windows-stock-component.ps1'and row['original_helpers_source_sha256']==PINS['windows-meet-wss-path.ps1']and row['diagnostic_only']is True and all(row[k]is False for k in('wss_eligible','media_eligible','restore_eligible','release_eligible','owner_eligible')))
 b=row['bootstrap'];need(type(b)is dict and set(b)=={'state','error'}and b['state']in('passed','failed'))
 if b['state']=='failed':error(b['error'])
 else:need(b['error']is None)
 need(type(row['imports'])is list and len(row['imports'])==2)
 for i,name in zip(row['imports'],('Security','Utility')):
  need(type(i)is dict and set(i)=={'module','state','error'}and i['module']==name and i['state']in('passed','failed'))
  if i['state']=='failed':error(i['error'])
  else:need(i['error']is None)
 need(type(row['observer_errors'])is int and row['observer_errors']==0 and type(row['commands'])is list and 6<=len(row['commands'])<=12)
 for x in row['commands']:
  need(type(x)is dict and set(x)in({'scope','command','check','proof','all_original_fields_true','metadata'},{'scope','command','check','proof','all_original_fields_true','metadata','lookup_error'}))
  need(x['scope']in('original_bootstrap','continuation')and x['command']in('Get-Acl','ConvertTo-Json','Add-Type')and x['check']in('qualified','visible')and type(x['all_original_fields_true'])is bool)
  if x['proof']is None:need(x['scope']=='continuation'and x['metadata']is None and'lookup_error'in x);error(x['lookup_error']);continue
  need('lookup_error'not in x)
  need(type(x['proof'])is dict and set(x['proof'])==FIELDS and all(type(v)is bool for v in x['proof'].values())and x['all_original_fields_true']==all(x['proof'].values()))
  m=x['metadata'];need(type(m)is dict and set(m)=={'command_kind','module_kind','module_version','module_guid','implementation_type','assembly_name','assembly_version','public_key_token','module_path','module_base','assembly_location'})
  need(m['command_kind']in('cmdlet','function','alias','other')and m['module_kind']in('Security','Utility','other'))
  for key in('module_version','assembly_version'):need(m[key]is None or type(m[key])is str and re.fullmatch(r'\d{1,5}(?:\.\d{1,5}){1,3}',m[key]))
  need(m['module_guid']is None or type(m['module_guid'])is str and re.fullmatch('[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}',m['module_guid']))
  need(m['implementation_type']is None or type(m['implementation_type'])is str and re.fullmatch(r'Microsoft\.PowerShell\.Commands\.[A-Za-z0-9_]{1,100}',m['implementation_type']))
  need(m['assembly_name']in(None,'Microsoft.PowerShell.Security','Microsoft.PowerShell.Commands.Utility')and m['public_key_token']in(None,'31bf3856ad364e35'))
  for key in('module_path','module_base','assembly_location'):
   p=m[key];need(type(p)is dict and set(p)=={'kind','value'}and p['kind']in('windows_stock','outside_windows_redacted','windows_other_redacted','unavailable'))
   if p['kind']=='windows_stock':need(type(p['value'])is str and len(p['value'])<=320 and re.fullmatch(r'[A-Za-z]:\\Windows\\(?:System32\\WindowsPowerShell\\v1\.0(?:\\[^\x00-\x1f\x7f]*)?|Microsoft\.NET\\assembly\\GAC_[^\x00-\x1f\x7f]*)',p['value'],re.I))
   else:need(p['value']is None)
 continuation={(x['command'],x['check'])for x in row['commands']if x['scope']=='continuation'};need(continuation=={(name,check)for name in('Get-Acl','ConvertTo-Json','Add-Type')for check in('qualified','visible')})
 return row

def execute(pwsh):
 need(os.name=='nt'and os.environ.get('OPENWEB_STOCK_COMPONENT')=='1'and os.environ.get('GITHUB_ACTIONS')=='true'and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'and os.environ.get('RUNNER_OS')=='Windows'and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx'and os.environ.get('GITHUB_EVENT_NAME')=='workflow_dispatch')
 for name,expected in PINS.items():need(hashlib.sha256((HERE/name).read_bytes()).hexdigest()==expected)
 node=shutil.which('node.exe');need(node is not None);ordinary(node);ordinary(pwsh)
 root=Path(os.environ['RUNNER_TEMP'])/'openwebpbx-stock-component';root.mkdir(exist_ok=True);ordinary(root);work=root/os.urandom(12).hex();work.mkdir();before=dict(os.environ)
 output=Path(os.environ['RUNNER_TEMP'])/'stock-module-component.json';need(not output.exists());facts=dict(schema=1,state='failed',producer='windows_stock_component.py',run_id=os.environ['GITHUB_RUN_ID'],source_commit=os.environ['GITHUB_SHA'],helper_source_commit='13d691175b815dc90728e03dbd433a4306014838',diagnostic_only=True,wss_eligible=False,media_eligible=False,restore_eligible=False,release_eligible=False,owner_eligible=False,contexts={})
 try:
  spec=importlib.util.spec_from_file_location('exact_original_owned_job',HERE/'windows_meeting_owned_process.py');owned=importlib.util.module_from_spec(spec);spec.loader.exec_module(owned)
  for context in('direct','owned'):
   report=work/(context+'.safe.clixml');command=[node,str(HERE/'windows-stock-component.cjs'),str(report)]
   if context=='direct':result=subprocess.run(command,capture_output=True,text=True,timeout=240);lifecycle=None
   else:
    directory=work/'job';directory.mkdir();result=owned.run(command,directory,timeout=240);lifecycle=decode((directory/'process.safe.json').read_bytes());need(set(lifecycle)=={'schema','created_suspended','assigned_before_resume','resumed','owned_job_terminated','exit_code','owned_processes_closed','handles_closed','ordinary_exit'}and lifecycle['schema']==1 and lifecycle['owned_job_terminated']is False and lifecycle['exit_code']==result.returncode and all(lifecycle[k]is True for k in('created_suspended','assigned_before_resume','resumed','owned_processes_closed','handles_closed','ordinary_exit')))
   need(len(result.stdout.encode())<=16384 and len(result.stderr.encode())<=16384);child=decode(result.stdout);need(set(child)=={'schema','producer','child_outcome'}and child['schema']==1 and child['producer']=='windows-stock-component.cjs');outcome(child['child_outcome']);facts['contexts'][context]=dict(observation=None,node_child=child['child_outcome'],owned_job=lifecycle)
   need(result.returncode==0 and report.is_file()and report.stat().st_size<=131072)
   parsed=subprocess.run([pwsh,'-NoProfile','-NonInteractive','-File',str(HERE/'windows-stock-component.ps1'),'-ReadReport','-ReportPath',str(report)],capture_output=True,timeout=30);need(parsed.returncode==0 and len(parsed.stdout)<=65536)
   row=validate(decode(parsed.stdout));facts['contexts'][context]=dict(observation=row,node_child=child['child_outcome'],owned_job=lifecycle)
  need(dict(os.environ)==before);facts['state']='observed';facts['environment_preserved']=True
 except BaseException as error:facts['failure_type']=type(error).__name__ if type(error).__name__ in ('ValueError','RuntimeError','TimeoutExpired','OSError','FileNotFoundError') else 'other'
 finally:
  paths=list(work.rglob('*'));need(len(paths)<=12 and all(not p.is_symlink()and not(p.stat().st_file_attributes&stat.FILE_ATTRIBUTE_REPARSE_POINT)for p in paths));shutil.rmtree(work);facts['owned_fixture_removed']=not work.exists();output.write_text(json.dumps(facts,indent=2)+'\n')
 need(facts['state']=='observed'and facts['owned_fixture_removed']);print(json.dumps({'state':'observed','diagnostic_only':True,'contexts':2,'owned_fixture_removed':True}))
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--execute',action='store_true');parser.add_argument('--pwsh',required=True);args=parser.parse_args()
 try:need(args.execute);execute(args.pwsh)
 except BaseException:print('The isolated stock component refused; only closed facts may be retained.',file=sys.stderr);raise SystemExit(1)
