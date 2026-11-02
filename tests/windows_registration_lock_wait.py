"""Actual proposed helper plus existing native-code classifier; no host actions."""
from pathlib import Path
import ast, contextlib, hashlib, json, types

ROOT=Path(__file__).resolve().parents[1]
tree=ast.parse((ROOT/'packaging/debian/tenant-domains.py').read_text())
node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='windows_registration_guard')
native_path=ROOT/'packaging/windows/backups.py'
native=ast.parse(native_path.read_text())
classes=[n for n in native.body if isinstance(n,ast.ClassDef) and n.name in {'BackupError','BackupBusy'}]
windows=next(n for n in native.body if isinstance(n,ast.FunctionDef) and n.name=='windows_exclusive_guard')
refuse=next(n for n in ast.walk(windows) if isinstance(n,ast.FunctionDef) and n.name=='refuse')
base={};exec(compile(ast.Module(body=[*classes,refuse],type_ignores=[]),'actual-native-refusal-classifier','exec'),base)
CHECKS=[]
def check(ok,name):
 if not ok:raise AssertionError(name)
 CHECKS.append(name)
def fixture(sequence,*,body_seconds=0,oversleep=0):
 class Clock:
  now=0.0
  sleeps=[]
  @classmethod
  def monotonic(cls):return cls.now
  @classmethod
  def sleep(cls,seconds):cls.sleeps.append(seconds);cls.now+=seconds+oversleep
 state={'enters':0,'bodies':0,'releases':0,'errors':[],'sequence':list(sequence)}
 @contextlib.contextmanager
 def acquire(path):
  check_path=path=='exact-upgrade-lock'
  if not check_path:raise AssertionError('Original lock changed')
  state['enters']+=1
  item=state['sequence'].pop(0) if state['sequence'] else 32
  if type(item)is int:
   try:base['refuse'](item)
   except base['BackupError'] as error:state['errors'].append(error);raise
  elif item is not None:raise item
  Clock.now+=body_seconds
  try:yield
  finally:state['releases']+=1
 b=types.SimpleNamespace(BackupBusy=base['BackupBusy'],UPGRADE_LOCK='exact-upgrade-lock',exclusive_guard=acquire)
 scope={'IS_WINDOWS':True,'contextlib':contextlib,'time':Clock}
 exec(compile(ast.Module(body=[node],type_ignores=[]),'actual-proposed-registration-guard','exec'),scope)
 return scope,b,state,Clock

scope,b,state,clock=fixture([32,33,None])
with scope['windows_registration_guard'](b):state['bodies']+=1
check(state['enters']==3 and state['bodies']==1 and state['releases']==1 and clock.sleeps==[0.05,0.05],'only actual native32/33 acquisition refusals retry; action runs once')
for code in [2,3,5,13,80,87,123,999]:
 scope,b,state,clock=fixture([code,None])
 try:
  with scope['windows_registration_guard'](b):state['bodies']+=1
 except base['BackupError'] as e:check(type(e)is base['BackupError'] and state['enters']==1 and state['bodies']==0 and not clock.sleeps,'native nonbusy '+str(code)+' refuses without retry')
for error in [PermissionError('private'),OSError('private'),ValueError('private'),FileNotFoundError('private'),KeyboardInterrupt(),SystemExit(7)]:
 scope,b,state,clock=fixture([error,None])
 try:
  with scope['windows_registration_guard'](b):state['bodies']+=1
 except BaseException as caught:check(caught is error and state['enters']==1 and not clock.sleeps,'original acquisition '+type(error).__name__+' propagates once')
for error in [base['BackupBusy']('guarded body'),base['BackupError']('guarded body'),RuntimeError('guarded body'),KeyboardInterrupt(),SystemExit(7)]:
 scope,b,state,clock=fixture([None,None])
 try:
  with scope['windows_registration_guard'](b):state['bodies']+=1;raise error
 except BaseException as caught:check(caught is error and state['enters']==1 and state['bodies']==1 and state['releases']==1 and not clock.sleeps,'guarded-body '+type(error).__name__+' is never retried or relabeled')
scope,b,state,clock=fixture([32,None],oversleep=5)
try:
 with scope['windows_registration_guard'](b):state['bodies']+=1
except base['BackupBusy'] as e:check(e is state['errors'][-1] and state['enters']==1 and state['bodies']==0,'deadline rethrows original last native refusal and forbids a late acquisition')
scope,b,state,clock=fixture([None],body_seconds=5)
try:
 with scope['windows_registration_guard'](b):state['bodies']+=1
except TimeoutError:check(state['bodies']==0 and state['releases']==1,'late successful acquisition closes before body at the five-second fence')
scope,b,state,clock=fixture([32]*200)
try:
 with scope['windows_registration_guard'](b):state['bodies']+=1
except base['BackupBusy'] as e:check(e is state['errors'][-1] and clock.now==5 and state['enters']<=101 and state['bodies']==0,'permanent contention stops at exactly five monotonic seconds')
scope,b,state,clock=fixture([None]);scope['IS_WINDOWS']=False
try:
 with scope['windows_registration_guard'](b):state['bodies']+=1
except RuntimeError:check(state['enters']==0,'Windows-only helper cannot change Debian acquisition behavior')
for rel,expected in [('packaging/debian/onboarding.py', '47e7555e4bc728fa41107b8eac1508921e2589ebaf54f518200120d4fc42a2d4'), ('packaging/debian/tenant-domains.py', 'c1da2609922d536854f1b0accb2b89e3899efeb844656f930169141aa3e30949')]:
 tree=ast.parse((ROOT/rel).read_text())
 calls=[ast.dump(n)for n in ast.walk(tree)if isinstance(n,ast.Call)and isinstance(n.func,ast.Attribute)and isinstance(n.func.value,ast.Name)and n.func.value.id=='subprocess'and n.func.attr=='run']
 check(hashlib.sha256('\n'.join(calls).encode()).hexdigest()==expected,rel+' native argv/options/child deadlines remain reviewed')
oldbackup=hashlib.sha256(native_path.read_bytes()).hexdigest()
check('wait_seconds' not in ast.unparse(next(n for n in native.body if isinstance(n,ast.FunctionDef) and n.name=='exclusive_guard').args),'generic Windows guard default API remains unchanged')
report={'passed':True,'scope':'source_only_acquisition_component_with_exact_existing_native32_33_classifier','checkCount':len(CHECKS),'checks':CHECKS,'proposedSource':{rel:hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()for rel in ['packaging/debian/onboarding.py','packaging/debian/tenant-domains.py']},'nativeBackupSourceUnchangedSHA256':oldbackup,'nativeWindowsExecution':False,'liveChanges':False,'buildOrDispatch':False}

print(json.dumps({'passed':True,'checkCount':len(CHECKS),'proposedSource':report['proposedSource']}))
