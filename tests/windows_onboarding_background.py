#!/usr/bin/env python3
"""Source-only dispatch controls and optional real Windows private-lock contention.

Only AST-selected definitions execute. Installed environments, registration,
keys, PHP, services, tasks, SQL and default product paths are never invoked.
"""
import argparse
import ast
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import types

ROOT=Path(__file__).resolve().parents[1]
PATHS=['packaging/debian/onboarding.py','packaging/debian/webhotel-onboarding.py',
       'packaging/debian/tenant-domains.py','packaging/windows/backups.py']
PINS={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest()for name in PATHS}
def selected(path,names):
 tree=ast.parse((ROOT/path).read_text(encoding='utf-8'))
 values=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.ClassDef))and n.name in names]
 assert {n.name for n in values}==set(names)
 return values
MAIN=selected(PATHS[0],{'main'})[0]
GUARD=selected(PATHS[2],{'windows_registration_guard'})[0]
checks=[]
def check(ok,label):
 if not ok:raise AssertionError(label)
 checks.append(label)

def invoke(args,*,windows=True,backend=None,native_guard=None,blocked=False,body_error=None):
 state={'environment':0,'guards':[],'bodies':[],'held':False,'metadata':0,'consumer':0}
 @contextlib.contextmanager
 def linux_guard(path,**options):
  state['guards'].append(('linux',options));state['held']=True
  try:yield
  finally:state['held']=False
 b=backend or types.SimpleNamespace(UPGRADE_LOCK='isolated-lock',exclusive_guard=linux_guard)
 @contextlib.contextmanager
 def windows_guard(actual,*,acquisition_seconds=5):
  state['guards'].append(('windows',acquisition_seconds))
  with native_guard(actual,acquisition_seconds=acquisition_seconds)if native_guard else contextlib.nullcontext():
   state['held']=True
   try:yield
   finally:state['held']=False
 d=types.SimpleNamespace(windows_registration_guard=windows_guard,blocked=lambda actual:blocked)
 def environment():state['environment']+=1;return b,d
 def image(action,value,actual_b,actual_d,meta=None):
  state['bodies'].append((action,value,state['held']))
  if body_error:raise body_error
  return {'body':'once'}
 def metadata(actual_b,actual_d):
  assert state['held'];state['metadata']+=1;return {'same':'metadata'}
 def process_jobs(actual_b,actual_d):
  assert state['held'];state['bodies'].append(('tick',{},True))
  if body_error:raise body_error
  return {'required':True}
 def consumer(**options):
  assert not state['held']and options=={'provider':'debian','metadata':{'same':'metadata'}}
  state['consumer']+=1;return {'state':'isolated'}
 scope={'argparse':argparse,'__doc__':'Isolated source fixture','IS_WINDOWS':windows,
        'sys':types.SimpleNamespace(argv=['onboarding.py',*args],stdin=types.SimpleNamespace(buffer=io.BytesIO(b'{"fixture":"only"}'))),
        'json':json,'environment':environment,'image':image,'metadata':metadata,'process_jobs':process_jobs,
        'load':lambda *a:types.SimpleNamespace(run_once=consumer),'ROOT':ROOT,'image_provider':lambda:'debian','subprocess':subprocess}
 exec(compile(ast.Module(body=[MAIN],type_ignores=[]),str(ROOT/PATHS[0]),'exec'),scope)
 result=error=None;original_argv=sys.argv;sys.argv=['onboarding.py',*args]
 try:
  with contextlib.redirect_stderr(io.StringIO()):result=scope['main']()
 except BaseException as caught:error=caught
 finally:sys.argv=original_argv
 return state,result,error

def portable():
 for args,want in [(['--image-sign'],5),(['--image-sign','--background'],30),(['--image-proof','--background'],30)]:
  s,r,e=invoke(args);check(e is None and r=={'body':'once'}and s['guards']==[('windows',want)]and s['bodies']==[(args[0][8:],{'fixture':'only'},True)],'actual Windows '+str(args)+' selects exact acquisition bound and original body once')
 s,r,e=invoke(['--image-bind','--background']);check(e is None and s['guards']==[('windows',30)]and s['metadata']==1 and s['bodies']==[('bind',{'fixture':'only'},False)],'background bind retains metadata guard then releases before certificate body')
 s,r,e=invoke(['--tick']);check(e is None and s['guards']==[('windows',30)]and len(s['bodies'])==1 and s['consumer']==1,'scheduled Windows tick selects30 and consumer remains outside guard')
 for windows,args in [(False,['--image-sign','--background']),(False,['--tick','--background']),(True,['--tick','--background'])]:
  s,r,e=invoke(args,windows=windows);check(isinstance(e,SystemExit)and e.code==2 and s['environment']==0 and not s['guards']and not s['bodies'],'invalid background context refuses before environment '+str((windows,args)))
 s,r,e=invoke(['--image-sign'],windows=False);check(e is None and s['guards']==[('linux',{})]and len(s['bodies'])==1,'Linux foreground image lock behavior unchanged')
 s,r,e=invoke(['--tick'],windows=False);check(e is None and s['guards']==[('linux',{'wait_seconds':5})]and s['consumer']==1,'Linux scheduled five-second behavior unchanged')
 for args in [['--image-sign','--background'],['--tick']]:
  s,r,e=invoke(args,blocked=True);check(not s['bodies']and((isinstance(e,RuntimeError))if args[0]!='--tick'else(r=={'state':'deferred','reason':'maintenance_or_restore_hold'})),'background does not bypass maintenance/restore hold '+args[0])
 for error in [RuntimeError('isolated body'),PermissionError('isolated body')]:
  s,r,e=invoke(['--image-sign','--background'],body_error=error);check(e is error and len(s['bodies'])==1 and len(s['guards'])==1 and not s['held'],'original guarded-body '+type(error).__name__+' propagates once')
 # Execute the actual helper method with only its child-process boundary fake.
 klass=selected(PATHS[1],{'Agent'})[0];method=next(n for n in klass.body if isinstance(n,ast.FunctionDef)and n.name=='helper')
 for windows in [False,True]:
  calls=[]
  def run(command,**options):calls.append((command,options));return types.SimpleNamespace(returncode=0,stdout=b'{"same":"result"}')
  scope={'ordinary':lambda path:None,'HELPER':Path(__file__),'sys':sys,'IS_WINDOWS':windows,'json':json,'subprocess':types.SimpleNamespace(run=run),'Pending':RuntimeError,'decode_json':json.loads}
  exec(compile(ast.Module(body=[method],type_ignores=[]),str(ROOT/PATHS[1]),'exec'),scope)
  for action in ['init','bind','store','status','sign','proof','display']:
   value={'unchanged':'request'};result=scope['helper'](None,action,value);command,options=calls[-1]
   expected=[sys.executable,'-I','-B',str(Path(__file__)),'--image-'+action]+(['--background']if windows else[])
   check(command==expected and options=={'input':json.dumps(value).encode(),'capture_output':True,'timeout':900 if action=='bind'else 90,'check':False}and result=={'same':'result'},'actual '+('Windows background'if windows else'Linux unchanged')+' helper preserves argv/body/deadline '+action)


def native_backend():
 names={'BackupError','BackupBusy','reparse','windows_exclusive_guard','exclusive_guard','lock_file','unlock_file'}
 scope={'Path':Path,'os':os,'contextlib':contextlib}
 if os.name=='nt':import msvcrt;scope['msvcrt']=msvcrt
 exec(compile(ast.Module(body=selected(PATHS[3],names),type_ignores=[]),str(ROOT/PATHS[3]),'exec'),scope)
 b=types.SimpleNamespace(**{name:scope[name]for name in names})
 guards={'IS_WINDOWS':True,'contextlib':contextlib,'time':time}
 exec(compile(ast.Module(body=[GUARD],type_ignores=[]),str(ROOT/PATHS[2]),'exec'),guards)
 return b,guards['windows_registration_guard']

def hold(directory):
 assert os.name=='nt'and directory.parent.name.startswith('openweb-onboarding-background-')
 assert (directory.parent/'fixture-owner.json').is_file()and directory.name in ['foreground','background','tick']
 b,_=native_backend()
 with b.windows_exclusive_guard(directory/'upgrade.lock'):
  (directory/'holder.ready').write_bytes(b'ready');time.sleep(15)
 (directory/'holder.finished').write_bytes(b'finished')

def native(work):
 assert os.name=='nt'and not work.exists()and work.name.startswith('openweb-onboarding-background-')
 work.mkdir(mode=0o700);(work/'fixture-owner.json').write_text(json.dumps({'scope':'source-only-Windows-onboarding-background','source_pins':PINS}))
 b,guard=native_backend();children=[];before=len(checks);started=time.monotonic()
 try:
  for name,args,want in [('foreground',['--image-sign'],False),('background',['--image-sign','--background'],True),('tick',['--tick'],True)]:
   directory=work/name;directory.mkdir(mode=0o700);lock=directory/'upgrade.lock';lock.write_bytes(b'exact isolated lock bytes');b.UPGRADE_LOCK=lock
   child=subprocess.Popen([sys.executable,'-I','-B',str(Path(__file__).resolve()),'--hold',str(directory)],stdout=subprocess.PIPE,stderr=subprocess.PIPE);children.append(child)
   deadline=time.monotonic()+10
   while not(directory/'holder.ready').exists():
    if child.poll()is not None or time.monotonic()>=deadline:raise RuntimeError('Owned bounded native holder did not initialize')
    time.sleep(0.01)
   begin=time.monotonic();s,r,e=invoke(args,backend=b,native_guard=guard);elapsed=time.monotonic()-begin
   if want:check(e is None and len(s['bodies'])==1 and 14<=elapsed<30,'native '+name+' outwaits natural15s holder and body executes once')
   else:check(type(e)is b.BackupBusy and not s['bodies']and 4.8<=elapsed<8,'native foreground default5 refuses natural15s holder without body')
   out,err=child.communicate(timeout=20);check(child.returncode==0 and (directory/'holder.finished').exists(),'native '+name+' holder exits naturally without termination')
   check(lock.read_bytes()==b'exact isolated lock bytes','native '+name+' exact lock bytes retained')
   with b.exclusive_guard(lock):pass
   check(True,'native '+name+' handles released for immediate reacquisition')
  b.UPGRADE_LOCK=work/'missing'/'upgrade.lock';begin=time.monotonic();s,r,e=invoke(['--image-sign','--background'],backend=b,native_guard=guard)
  check(type(e)is b.BackupError and not s['bodies']and time.monotonic()-begin<1,'native missing-path error refuses immediately without busy retry')
  directory=work/'body';directory.mkdir(mode=0o700);b.UPGRADE_LOCK=directory/'upgrade.lock';b.UPGRADE_LOCK.write_bytes(b'body-once');error=b.BackupBusy('isolated body')
  s,r,e=invoke(['--image-sign','--background'],backend=b,native_guard=guard,body_error=error)
  check(e is error and len(s['bodies'])==1 and len(s['guards'])==1,'native guarded body Busy is never retried or relabelled')
  with b.exclusive_guard(b.UPGRADE_LOCK):pass
  check(True,'native body failure releases original handle')
  result={'passed':True,'native_checks':len(checks)-before,'elapsed_seconds':time.monotonic()-started,'source_pins':PINS,'natural_holder_seconds':15,'default_product_paths_or_workers_or_acl_changes':False,'scope':'AST-only actual dispatch and real Windows private-file guards'}
  (work/'native-result.safe.json').write_text(json.dumps(result,indent=2));return result
 finally:
  for child in children:
   # Holders have a fixed15s lifetime; never signal or kill a worker/holder.
   child.communicate(timeout=25)
   assert child.returncode==0

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--native',action='store_true');parser.add_argument('--work-root',type=Path);parser.add_argument('--hold',type=Path);a=parser.parse_args()
 if a.hold:hold(a.hold.resolve());raise SystemExit(0)
 portable();report={'passed':True,'portable_checks':len(checks),'source_pins':PINS,'default_product_paths_or_workers_or_acl_changes':False}
 if a.native:
  assert a.work_root;report['native']=native(a.work_root.resolve())
 print(json.dumps(report))
