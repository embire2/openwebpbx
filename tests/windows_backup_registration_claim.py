"""A busy registration snapshot must leave the same backup request queued.

Runs real source functions with isolated adapters. --native also checks the
actual Windows/CRT lock contract in a new private fixture directory; no product
database, scheduler, services, registration state or customer files are used.
"""
import argparse
import ast
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[1]/'packaging/windows/backups.py')
p.add_argument('--previous',type=Path)
p.add_argument('--native',action='store_true')
p.add_argument('--work-root',type=Path)
a=p.parse_args();checks=0
def need(value):
 global checks
 assert value
 checks+=1
tree=ast.parse(a.source.read_text())
def find(name,parsed=tree):return next(n for n in parsed.body if isinstance(n,(ast.FunctionDef,ast.ClassDef)) and n.name==name)
ns={'contextlib':contextlib,'STORE':'store','DOWNLOADS':'downloads','KEY':'key',
    'ROOTS':{'registration-state':'own-state','config':'config'},'MEDIA':{'voicemail':'media'}}
exec(compile(ast.Module(body=[find(n) for n in ['BackupError','BackupBusy','_worker']],type_ignores=[]),str(a.source),'exec'),ns)
Busy,Error=ns['BackupBusy'],ns['BackupError']
def run(*,entry_error=None,body_error=None,release_error=None,roots=None):
 events=[];rows={'request':'pending','archive':None};held=False
 @contextlib.contextmanager
 def guard(selected):
  nonlocal held
  events.append(('entry',selected))
  if entry_error:raise entry_error('isolated acquisition')
  held=True
  try:yield
  finally:
   held=False;events.append(('release',None))
   if release_error:raise release_error('isolated release')
 def body(settings,**kwargs):
  need(held);events.append(('body',kwargs));rows['request']='running'
  if body_error:raise body_error('isolated body')
  rows.update(request='completed',archive='one-archive');return 'one-result'
 ns.update(registration_guard=guard,_registration_worker=body)
 error=None;result=None
 try:result=ns['_worker']({'owned':'fixture'},store='own-store',downloads='own-downloads',roots=roots,version='1.0.27',key_file='own-key')
 except BaseException as e:error=type(e)
 return events,rows,result,error

events,rows,result,error=run(entry_error=Busy)
need(error is None and result is None and rows=={'request':'pending','archive':None})
need([v[0] for v in events]==['entry'])
for exception in [Error,OSError,ValueError,RuntimeError]:
 events,rows,result,error=run(entry_error=exception)
 need(error is exception and rows['request']=='pending' and len(events)==1)
events,rows,result,error=run()
need(error is None and result=='one-result' and rows=={'request':'completed','archive':'one-archive'})
need([v[0] for v in events]==['entry','body','release'])
need(events[0][1]==ns['ROOTS']|ns['MEDIA'])
need(events[1][1]=={'store':'own-store','downloads':'own-downloads','roots':None,'version':'1.0.27','key_file':'own-key'})
for exception in [Busy,Error,OSError,RuntimeError]:
 events,rows,result,error=run(body_error=exception)
 need(error is exception and rows['request']=='running' and [v[0] for v in events]==['entry','body','release'])
events,rows,result,error=run(release_error=Busy)
need(error is Busy and rows['request']=='completed' and len(events)==3)
events,rows,result,error=run(roots={})
need(error is None and events[0][1]=={} and events[1][1]['roots']=={})
events,rows,result,error=run(roots={'registration-state':'exact-own-state'})
need(error is None and events[0][1]=={'registration-state':'exact-own-state'})

# The existing queued-command and archive business body stays byte-for-byte
# equivalent at AST level, apart from its name and the now-held guard wrapper.
if a.previous:
 previous=ast.parse(a.previous.read_text());old=find('_worker',previous)
 current=find('_registration_worker')
 current.name='_worker'
 calls=[n for n in ast.walk(current) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=='_create_archive']
 need(len(calls)==1);calls[0].func.id='create_archive'
 need(ast.dump(old,include_attributes=False)==ast.dump(current,include_attributes=False))
 for name in ['create_archive','registration_guard','exclusive_guard','windows_exclusive_guard','restore','recover']:
  need(ast.dump(find(name,previous),include_attributes=False)==ast.dump(find(name),include_attributes=False))

result={'passed':True,'checks':checks,'source_sha256':hashlib.sha256(a.source.read_bytes()).hexdigest(),
        'pending_request_unchanged_when_snapshot_busy':True,'guarded_body_runs_once':True,
        'real_source_functions':True,'native':False,'product_data_or_services_written':False}
if a.native:
 assert os.name=='nt' and a.work_root and not a.work_root.exists()
 a.work_root.mkdir(mode=0o700)
 spec=importlib.util.spec_from_file_location('registration_backup_fixture',a.source)
 m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 private=a.work_root/'private';private.mkdir(mode=0o700)
 directory=private/'image-onboarding';directory.mkdir(mode=0o700)
 lock=directory/'worker.lock';lock.write_bytes(b'\0')
 # Scaffold only the three NEW fixture paths. Do not call installed backup
 # control or grant access to existing product configuration to prepare a test.
 acl_code=r"""$ErrorActionPreference='Stop';try{$v=[Console]::In.ReadToEnd()|ConvertFrom-Json
foreach($p in $v.paths){
 $full=[IO.Path]::GetFullPath($p);if(!$full.StartsWith([IO.Path]::GetFullPath($v.root)+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Only new fixture children permitted'}
 $item=Get-Item -LiteralPath $full;if($item.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Fixture links refused'}
 $acl=if($item.PSIsContainer){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
 $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
 $inherit=if($item.PSIsContainer){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl',$inherit,'None','Allow'))}
 Set-Acl -LiteralPath $full -AclObject $acl
}}catch{[Console]::Error.WriteLine('FIXTURE_ACL_ERROR:'+ $_.Exception.GetType().Name + ':'+($_.FullyQualifiedErrorId -split ',')[0]);exit 1}"""
 prepared=subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-NonInteractive','-Command',acl_code],
  input=json.dumps({'root':str(a.work_root.resolve()),'paths':[str(q.resolve()) for q in [private,directory,lock]]}),
  env=m.native_powershell_environment(),capture_output=True,text=True,timeout=30)
 if prepared.returncode:
  import re
  error=re.search(r'FIXTURE_ACL_ERROR:[A-Za-z0-9_]+:[A-Za-z0-9_-]+',prepared.stderr)
  raise RuntimeError(error[0] if error else 'Private fixture ACL preparation failed')
 need(prepared.returncode==0)
 child_code="import msvcrt,sys,time;f=open(sys.argv[1],'r+b');msvcrt.locking(f.fileno(),msvcrt.LK_NBLCK,1);print('HELD',flush=True);time.sleep(15);f.close()"
 child=subprocess.Popen([sys.executable,'-I','-B','-c',child_code,str(lock)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 need(child.stdout.readline().strip()=='HELD')
 rows={'request':'pending','claims':0}
 def actual_body(settings,**kwargs):
  rows.update(request='completed',claims=rows['claims']+1)
  try:
   with m.exclusive_guard(lock):raise AssertionError('The snapshot lock was not held')
  except m.BackupBusy:pass
  return 'actual-once'
 m._registration_worker=actual_body
 began=time.monotonic();value=m._worker({},roots={'registration-state':private})
 need(value is None and rows=={'request':'pending','claims':0} and child.poll() is None)
 need(time.monotonic()-began<10)
 need(child.wait(timeout=20)==0)
 value=m._worker({},roots={'registration-state':private})
 need(value=='actual-once' and rows=={'request':'completed','claims':1})
 result.update(checks=checks,native=True,crt_consumer_exits_naturally=True)
 (a.work_root/'result.safe.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
