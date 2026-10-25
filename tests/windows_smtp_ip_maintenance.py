"""Controlled IP-mail deferral proof; no installed PBX, PHP, SMTP or calls."""
import argparse,hashlib,importlib.util,json,os,shutil,subprocess,sys,tempfile,threading,time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('owned_ip_mail',ROOT/'tests/windows-native-acceptance.py');n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)
COMMAND=[n.WINPS,'-NoProfile','-NonInteractive','-File','C:/OpenWebPBX/tools/Install-MailQueue.ps1','-Tick']
def need(v):
 if not v:raise AssertionError('Controlled IP-mail proof refused')
def response(row,code=0):return subprocess.CompletedProcess(COMMAND,code,json.dumps(row).encode(),b'PRIVATE_NEVER_EXPORT')
class Clock:
 def __init__(self):self.now=0.;self.sleeps=[]
 def mono(self):return self.now
 def sleep(self,value):need(0<=value<=.25);self.sleeps.append(value);self.now+=value

def controls():
 cases=0
 for mode in ['processed','unconfigured','restore','malformed','nonzero','timeout','defer_once','defer_forever','defer_sleep_edge']:
  c=Clock();sink=SimpleNamespace(deliveries=[]);calls=[];original=None
  f=SimpleNamespace(smtp_failure={})
  def wait(pred,limit):
   need(0<limit<=15)
   if not pred():c.now+=limit;raise AssertionError('OWNED_ORIGINAL_PRIMARY')
  f.wait=wait
  def run(args,**kwargs):
   nonlocal original
   need(args==COMMAND and kwargs['capture_output']is True and kwargs['check']is True);calls.append(kwargs)
   need(kwargs['timeout']==110 if len(calls)==1 else 0<kwargs['timeout']<=15)
   if len(calls)==1:c.now+=110
   if mode=='nonzero':original=subprocess.CalledProcessError(75,args,output=b'PRIVATE',stderr=b'PRIVATE');raise original
   if mode=='timeout':original=subprocess.TimeoutExpired(args,110,output=b'PRIVATE');raise original
   if mode=='defer_sleep_edge':c.now+=14.9 if len(calls)==1 else 0
   if mode.startswith('defer')and(mode!='defer_once'or len(calls)==1):return response({'deferred':True,'reason':'maintenance'})
   if mode=='restore':return response({'deferred':True,'reason':'restore'})
   if mode=='unconfigured':return response({'configured':False,'selected':0,'attempts_consumed':0})
   if mode=='malformed':return response({'deferred':'true','reason':'maintenance','private':'PRIVATE'})
   sink.deliveries.extend([None,None]);return response({'configured':True,'selected':2,'processed':2})
  failed=None
  with patch.object(n.time,'monotonic',side_effect=c.mono),patch.object(n.time,'sleep',side_effect=c.sleep),patch.object(n.subprocess,'run',side_effect=run):
   try:n.smtp_ip_dispatch_and_wait(f,sink)
   except BaseException as e:failed=e
  if mode in ['processed','defer_once']:need(failed is None)
  else:need(failed is not None)
  if mode in ['processed','unconfigured','restore','malformed','nonzero','timeout']:need(len(calls)==1)
  if mode in ['nonzero','timeout']:need(failed is original)
  if mode=='defer_once':need(len(calls)==2 and f.smtp_failure['smtp_tick_retry_count']==1 and f.smtp_failure['smtp_tick_maintenance_deferrals']==1)
  if mode=='defer_forever':need(len(calls)<=64 and c.now<=125.000001)
  if mode=='defer_sleep_edge':need(len(calls)==1 and c.now<=125.000001)
  need(c.now<=125.000001 and all(x<=.25 for x in c.sleeps));need('PRIVATE'not in json.dumps(f.smtp_failure));cases+=1
 # The observational collector preserves the exact primary even if it fails.
 primary=RuntimeError('OWNED_ORIGINAL_PRIMARY')
 with patch.object(n,'smtp_snapshot',side_effect=ValueError('PRIVATE')):
  try:
   try:raise primary
   except BaseException as e:n.smtp_capture_failure(e,None,None,None);raise
  except BaseException as e:need(e is primary)
 cases+=1
 # Only enum totals and the selected owned seed are projected, never raw rows.
 rows=[{'email_queue_uuid':'PRIVATE_ID','email_status':'waiting','email_retry_count':1,'response_class':'connection','secret':'PRIVATE'}, {'email_queue_uuid':'PRIVATE_OTHER','email_status':'sent','email_retry_count':0,'response_class':'none'}]
 sink=SimpleNamespace(deliveries=[],envelopes=[],connections=[],record_lock=threading.Lock());f=SimpleNamespace(smtp_failure={},cli=lambda action:{'mail':rows})
 safe=n.smtp_snapshot(f,sink,'PRIVATE_ID');need(safe['smtp_owned_mail_rows']==2 and safe['smtp_owned_waiting_count']==1 and safe['smtp_owned_sent_count']==1 and safe['smtp_owned_connection_count']==1);need('PRIVATE'not in json.dumps(safe));need(all(type(v)is int and 0<=v<=64 for k,v in safe.items()if k.startswith('smtp_owned_')));cases+=1
 return cases

def sharing_proof(pwsh,require_native):
 if not require_native:return {'actual_native_windows':False,'native_Job_or_sharing_proof':'pending','actual_PHP_SMTP_or_installed_server_qualified':False}
 need(os.name=='nt'and sys.version_info[:3]==(3,12,10));expected=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe';need(os.path.normcase(str(pwsh))==os.path.normcase(str(expected.resolve())))
 core_path=ROOT/'tests/windows_meeting_owned_process.py';core_sha=hashlib.sha256(core_path.read_bytes()).hexdigest();need(core_sha=='9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448')
 spec=importlib.util.spec_from_file_location('owned_original_Job240',core_path);job=importlib.util.module_from_spec(spec);spec.loader.exec_module(job)
 source=(ROOT/'packaging/windows/Install-MailQueue.ps1').read_text();original_sha=hashlib.sha256(source.encode()).hexdigest();gates=(ROOT/'packaging/windows/Restore-Gates.ps1').read_bytes();binary_sha=hashlib.sha256(pwsh.read_bytes()).hexdigest();root=Path(tempfile.mkdtemp(prefix='openweb-owned-smtp-ip-'));complete=False;proofs=[];holder_result={};owner=None
 def ordinary(directory):
  value=json.loads((directory/'process.safe.json').read_bytes());need(set(value)=={'schema','created_suspended','assigned_before_resume','resumed','owned_job_terminated','exit_code','owned_processes_closed','handles_closed','ordinary_exit'}and type(value['schema'])is int and value['schema']==1 and type(value['exit_code'])is int and value['exit_code']==0)
  need(all(value[k]is True for k in ['created_suspended','assigned_before_resume','resumed','owned_processes_closed','handles_closed','ordinary_exit'])and value['owned_job_terminated']is False);proofs.append(value)
 def execute(script,label):
  directory=root/label;directory.mkdir();result=job.run([str(pwsh),'-NoProfile','-NonInteractive','-File',str(script)],directory,timeout=240);ordinary(directory);need(result.returncode==0 and len(result.stdout)<=4096 and len(result.stderr)<=4096);return result
 try:
  state=root/'state';state.mkdir();(state/'updates').mkdir();(state/'backup-restore').mkdir();tools=root/'tools';tools.mkdir();(tools/'Restore-Gates.ps1').write_bytes(gates);(state/'installation.json').write_text('{"Completed":true}');q=lambda p:"'"+str(p).replace("'","''")+"'"
  original="$root='C:\\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX'";need(source.count(original)==1);source=source.replace(original,'$root='+q(root)+';$state='+q(state))
  delegate='& "$root\\php\\php.exe" (Join-Path $PSScriptRoot \'process-mail.php\') "$root\\web"';need(source.count(delegate)==1);source=source.replace(delegate,'Invoke-FixtureDispatch')
  helper=tools/'Install-MailQueue.ps1';helper.write_text(source);counter=root/'count';counter.write_text('0');ready=root/'ready';release=root/'release'
  wrapper=root/'tick.ps1';wrapper.write_text("$ErrorActionPreference='Stop';if($PSVersionTable.PSEdition-ceq 'Desktop'){$env:PSModulePath=$PSHOME+'\\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\\WindowsPowerShell\\Modules'}\nfunction Invoke-FixtureDispatch{[IO.File]::WriteAllText("+q(counter)+",([int][IO.File]::ReadAllText("+q(counter)+")+1));$global:LASTEXITCODE=0;'{\"configured\":true,\"selected\":2,\"processed\":2}'}\n& "+q(helper)+' -Tick')
  holder=root/'hold.ps1';holder.write_text("$ErrorActionPreference='Stop';$lock=[IO.File]::Open("+q(state/'upgrade.lock')+",'OpenOrCreate','ReadWrite','None');try{[IO.File]::WriteAllText("+q(ready)+",'ready');$end=[DateTime]::UtcNow.AddSeconds(20);while(!(Test-Path -LiteralPath "+q(release)+")-and [DateTime]::UtcNow-lt $end){Start-Sleep -Milliseconds 20}}finally{$lock.Dispose()}")
  def hold():
   try:holder_result['value']=execute(holder,'job-holder')
   except BaseException as error:holder_result['error']=error
  owner=threading.Thread(target=hold,daemon=True);started=time.monotonic();owner.start()
  end=time.monotonic()+5
  while not ready.exists()and time.monotonic()<end and owner.is_alive():time.sleep(.02)
  need(ready.exists());old=execute(wrapper,'job-original-held');need(n.smtp_tick_fields(old)['smtp_tick_outcome']=='deferred_maintenance'and counter.read_text()=='0')
  f=SimpleNamespace(smtp_failure={});sink=SimpleNamespace(deliveries=[]);ticks=0
  def wait(pred,limit):
   end=time.monotonic()+limit
   while not pred()and time.monotonic()<end:time.sleep(.01)
   need(pred())
  f.wait=wait
  def adapted(args,**kwargs):
   nonlocal ticks
   need(args==COMMAND);ticks+=1;begin=time.monotonic();result=execute(wrapper,'job-retry-'+str(ticks));need(time.monotonic()-begin<=kwargs['timeout']);kind=n.smtp_tick_fields(result)['smtp_tick_outcome']
   if kind=='deferred_maintenance'and not release.exists():release.write_text('release')
   if kind=='processed':sink.deliveries.extend([None,None])
   return result
  with patch.object(n.subprocess,'run',side_effect=adapted):n.smtp_ip_dispatch_and_wait(f,sink)
  need(int(counter.read_text())==1 and f.smtp_failure['smtp_tick_maintenance_deferrals']>=1 and f.smtp_failure['smtp_tick_retry_count']>=1)
  release.touch();owner.join(timeout=15);need(not owner.is_alive()and 'error'not in holder_result and 'value'in holder_result)
  reacquire=root/'reacquire.ps1';reacquire.write_text("$ErrorActionPreference='Stop';$f=[IO.File]::Open("+q(state/'upgrade.lock')+",'Open','ReadWrite','None');try{if(!$f.CanRead-or !$f.CanWrite){throw 'Exclusive owned lock refused'}}finally{$f.Dispose()};'{\"exclusive\":true,\"disposed\":true}'")
  acquired=execute(reacquire,'job-fresh-lock');need(json.loads(acquired.stdout)=={'exclusive':True,'disposed':True});elapsed=time.monotonic()-started;need(elapsed<=125)
  need(hashlib.sha256(pwsh.read_bytes()).hexdigest()==binary_sha and (tools/'Restore-Gates.ps1').read_bytes()==gates and hashlib.sha256(core_path.read_bytes()).hexdigest()==core_sha)
  proof={'actual_native_windows':True,'actual_original_Tick_lock_deferral_branch':True,'original_zero_exit_held_lock_did_not_dispatch':True,'positive_maintenance_only_retry_counted_adapter_dispatch':True,'actual_PHP_SMTP_or_installed_server_qualified':False,'original_Tick_sha256':original_sha,'powershell_sha256':binary_sha,'owned_job_source_sha256':core_sha,'native_adapter_Job_timeout_seconds':240,'main_110_plus_15_timing_qualified':False,'native_adapter_total_ms':int(elapsed*1000),'holder_thread_joined':True,'owned_jobs_count':len(proofs),'ordinary_Job_descendant_handle_closure':True,'fresh_exclusive_lock_reacquired':True,'parent_environment_unchanged':True};complete=True
 finally:
  if owner is not None and owner.is_alive():
   try:(root/'release').touch();owner.join(timeout=15)
   except BaseException:pass
  # Failure/forced/unknown scope remains retained; only a completely proved run deletes.
  if complete:shutil.rmtree(root)
 need(not root.exists());proof['owned_temporary_scope_removed']=True;return proof

def main():
 a=argparse.ArgumentParser();a.add_argument('--pwsh',required=True,type=Path);a.add_argument('--require-native',action='store_true');args=a.parse_args();need(args.pwsh.is_absolute()and args.pwsh.is_file());before=dict(os.environ);count=controls();proof=sharing_proof(args.pwsh.resolve(),args.require_native);need(dict(os.environ)==before);print(json.dumps({'schema':1,'state':'passed_controlled_preflight_only'if args.require_native else'passed_portable_controls_only','controlled_cases':count,**proof},sort_keys=True))
if __name__=='__main__':main()
