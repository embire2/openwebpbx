"""Actual proposed helper plus existing native-code classifier; no host actions."""
from pathlib import Path
import ast, contextlib, hashlib, json, sys, types

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
# The background lease must outwait the actual observed twelve-second holder,
# while all default/foreground cases above retain their five-second deadline.
scope,b,state,clock=fixture([32]*240+[None])
with scope['windows_registration_guard'](b,acquisition_seconds=30):state['bodies']+=1
check(state['bodies']==1 and state['releases']==1 and 11.9<clock.now<12.1,'background waits through twelve seconds and executes one body')
for seconds in [0,4,6,31,True,5.0,None]:
 scope,b,state,clock=fixture([None])
 try:
  with scope['windows_registration_guard'](b,acquisition_seconds=seconds):state['bodies']+=1
 except ValueError:check(state['enters']==0 and state['bodies']==0,'unapproved acquisition bound refuses before lock: '+repr(seconds))
scope,b,state,clock=fixture([32]*700)
try:
 with scope['windows_registration_guard'](b,acquisition_seconds=30):state['bodies']+=1
except base['BackupBusy'] as e:check(e is state['errors'][-1] and clock.now==30 and state['bodies']==0,'background contention remains thirty-second bounded')
for rel,expected in [('packaging/debian/onboarding.py', '4f797326faae79d65eaf4d142412f98f6c3655fd57ac78eccd0f9b52c740300c'), ('packaging/debian/tenant-domains.py', 'd31082c502087b4b4dac3d762cec0acabe08c49b80d6f94b95faeecf76e9a504')]:
 tree=ast.parse((ROOT/rel).read_text())
 calls=[ast.dump(n,**({'show_empty':True}if sys.version_info>=(3,13)else{}))for n in ast.walk(tree)if isinstance(n,ast.Call)and isinstance(n.func,ast.Attribute)and isinstance(n.func.value,ast.Name)and n.func.value.id=='subprocess'and n.func.attr=='run']
 check(hashlib.sha256('\n'.join(calls).encode()).hexdigest()==expected,rel+' native argv/options/child deadlines match reviewed explicit acquisition bound')
# Execute the actual routing and Ensure argv construction with host operations
# replaced at their boundaries. No service, task, file or worker is invoked.
product=ast.parse((ROOT/'packaging/debian/tenant-domains.py').read_text())
run_node=next(n for n in product.body if isinstance(n,ast.FunctionDef)and n.name=='run')
ensure_node=next(n for n in product.body if isinstance(n,ast.FunctionDef)and n.name=='ensure_windows_onboarding')
for move,want in [(False,30),(True,5)]:
 routes=[]
 class Busy(RuntimeError):pass
 fake_b=types.SimpleNamespace(BackupBusy=Busy)
 loader=types.SimpleNamespace(exec_module=lambda b:None)
 fake_util=types.SimpleNamespace(spec_from_file_location=lambda *a:types.SimpleNamespace(loader=loader),module_from_spec=lambda spec:fake_b)
 @contextlib.contextmanager
 def route_guard(b,*,acquisition_seconds=5):
  routes.append(('guard',acquisition_seconds));yield
 scope={'Path':Path,'__file__':str(ROOT/'packaging/debian/tenant-domains.py'),'importlib':types.SimpleNamespace(util=fake_util),'IS_WINDOWS':True,'contextlib':contextlib,'ensure_windows_onboarding':lambda b,**kw:(routes.append(('ensure',kw['acquisition_seconds']))or{'state':'not_needed'}),'windows_registration_guard':route_guard,'blocked':lambda b:True}
 exec(compile(ast.Module(body=[run_node],type_ignores=[]),'actual-background-routing','exec'),scope)
 check(scope['run'](move=move)=={'state':'deferred','reason':'maintenance_or_restore_hold'}and routes==[('ensure',want),('guard',want)],'actual '+('move foreground'if move else'scheduled background')+' chooses bound for both acquisition stages')
argv=[]
def capture(command,**kwargs):
 argv.append((command,kwargs));return types.SimpleNamespace(returncode=0,stdout=b'{"state":"not_needed"}')
scope={'Path':Path,'os':types.SimpleNamespace(environ={'SystemRoot':'C:/Windows'}),'subprocess':types.SimpleNamespace(run=capture),'json':json,'Pending':RuntimeError}
exec(compile(ast.Module(body=[ensure_node],type_ignores=[]),'actual-ensure-child-options','exec'),scope)
fake_b=types.SimpleNamespace(APP=Path('C:/OpenWebPBX'),native_powershell_environment=lambda:{'owned':'environment'})
for seconds in [None,30]:
 result=scope['ensure_windows_onboarding'](fake_b,**({}if seconds is None else{'acquisition_seconds':seconds}));command,options=argv[-1]
 check(result=={'state':'not_needed'}and command[-2:]==['-AcquisitionSeconds',str(5 if seconds is None else seconds)]and options=={'capture_output':True,'env':{'owned':'environment'},'timeout':60},'Ensure forwards '+str(5 if seconds is None else seconds)+' explicitly with original environment and child deadline')
for seconds in [0,6,31,True,5.0]:
 before=len(argv)
 try:scope['ensure_windows_onboarding'](fake_b,acquisition_seconds=seconds)
 except ValueError:check(len(argv)==before,'Ensure refuses invalid bound without child execution '+repr(seconds))
oldbackup=hashlib.sha256(native_path.read_bytes()).hexdigest()
check('wait_seconds' not in ast.unparse(next(n for n in native.body if isinstance(n,ast.FunctionDef) and n.name=='exclusive_guard').args),'generic Windows guard default API remains unchanged')
report={'passed':True,'scope':'source_only_acquisition_component_with_exact_existing_native32_33_classifier','checkCount':len(CHECKS),'checks':CHECKS,'proposedSource':{rel:hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()for rel in ['packaging/debian/onboarding.py','packaging/debian/tenant-domains.py']},'nativeBackupSourceUnchangedSHA256':oldbackup,'nativeWindowsExecution':False,'liveChanges':False,'buildOrDispatch':False}

print(json.dumps({'passed':True,'checkCount':len(CHECKS),'proposedSource':report['proposedSource']}))
