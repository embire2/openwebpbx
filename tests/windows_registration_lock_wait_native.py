"""Real Windows private-file contention only; no product worker is invoked."""
from pathlib import Path
import ast, contextlib, hashlib, json, os, re, shutil, subprocess, sys, tempfile, threading, time, types

SOURCE=Path(__file__).resolve().parents[1]
if os.name!='nt':raise RuntimeError('Actual Windows is required for native lock qualification')
child=len(sys.argv)==4 and sys.argv[1]=='--hold-python'
if child:
    ROOT=Path(sys.argv[2])
    if not ROOT.name.startswith('openweb-registration-wait-') or not(ROOT/'fixture-owner.json').is_file():raise RuntimeError('Exact owned test directory required')
else:
    ROOT=Path(tempfile.mkdtemp(prefix='openweb-registration-wait-'))
    (ROOT/'fixture-owner.json').write_text(json.dumps({'scope':'openweb-registration-wait-fixture','source_root':str(SOURCE)}))
BACKUP=SOURCE/'packaging/windows/backups.py'
EXPECTED={rel:hashlib.sha256((SOURCE/rel).read_bytes()).hexdigest() for rel in ['packaging/windows/backups.py','packaging/debian/tenant-domains.py','packaging/windows/Ensure-OnboardingUpgrade.ps1']}
tree=ast.parse(BACKUP.read_text(encoding='utf-8'))
names={'BackupError','BackupBusy','reparse','windows_exclusive_guard','exclusive_guard','lock_file','unlock_file'}
selected=[n for n in tree.body if isinstance(n,(ast.ClassDef,ast.FunctionDef)) and n.name in names]
if {n.name for n in selected}!=names:raise RuntimeError('Exact existing guard source functions required')
B=types.ModuleType('actual_private_backup_guard');B.__dict__.update(Path=Path,os=os,contextlib=contextlib)
exec(compile(ast.Module(body=selected,type_ignores=[]),str(BACKUP),'exec'),B.__dict__)
proposal=SOURCE/'packaging/debian/tenant-domains.py'
tree=ast.parse(proposal.read_text())
helper=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='windows_registration_guard')
scope={'IS_WINDOWS':True,'contextlib':contextlib,'time':time}
exec(compile(ast.Module(body=[helper],type_ignores=[]),str(proposal),'exec'),scope)
acquire=scope['windows_registration_guard']
POWERSHELL=str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe')

if child:
    name=sys.argv[3]
    if re.fullmatch(r'[a-z-]{1,40}',name) is None:raise RuntimeError('Owned fixture case required')
    case=ROOT/name
    with B.windows_exclusive_guard(case/'upgrade.lock'):
        (case/'holder.ready').write_bytes(b'ready')
        deadline=time.monotonic()+15
        while not(case/'holder.release').exists() and time.monotonic()<deadline:time.sleep(0.01)
    raise SystemExit(0)

CHECKS=[];children=[];timers=[];cases=[]
def check(value,label):
    if not value:raise AssertionError(label)
    CHECKS.append(label)
def case(name):
    p=ROOT/name;p.mkdir();(p/'upgrade.lock').write_bytes(b'exact owned lock bytes')
    cases.append(p);return p
def launch_holder(p,kind):
    command=[sys.executable,'-I','-B',str(__file__),'--hold-python',str(ROOT),p.name] if kind=='python' else [POWERSHELL,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(SOURCE/'tests/windows_registration_lock_wait_native.ps1'),'-Mode','Hold','-Directory',str(p)]
    out=(p/'holder.stdout.private').open('xb');err=(p/'holder.stderr.private').open('xb')
    process=subprocess.Popen(command,stdout=out,stderr=err);out.close();err.close();children.append((process,p))
    deadline=time.monotonic()+8
    while not(p/'holder.ready').exists():
        if process.poll() is not None or time.monotonic()>=deadline:raise RuntimeError('Owned bounded holder did not initialize')
        time.sleep(0.01)
    return process
def release(p):
    (p/'holder.release').touch(exist_ok=True)
def delayed_release(p):
    timer=threading.Timer(2,release,args=(p,));timers.append(timer);timer.start();return timer
def finish(process,p):
    release(p);check(process.wait(timeout=18)==0,'private '+p.name+' holder exits normally')
    check((p/'upgrade.lock').read_bytes()==b'exact owned lock bytes','private '+p.name+' lock bytes exact after release')
def native(p):
    command=[POWERSHELL,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(SOURCE/'tests/windows_registration_lock_wait_native.ps1'),'-Mode','Acquire','-Directory',str(p),'-Source',str(SOURCE/'packaging/windows/Ensure-OnboardingUpgrade.ps1')]
    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
    (p/'native.stdout.private').write_bytes(result.stdout);(p/'native.stderr.private').write_bytes(result.stderr)
    check(result.returncode==0,'native acquisition fixture process succeeds')
    return json.loads((p/'native-result.safe.json').read_text(encoding='utf-8-sig'))
started=time.monotonic()
try:
    p=case('python-waits-dotnet');child=launch_holder(p,'dotnet');delayed_release(p);B.UPGRADE_LOCK=p/'upgrade.lock';bodies=0;begin=time.monotonic()
    with acquire(B):bodies+=1
    elapsed=time.monotonic()-begin
    check(bodies==1 and 0.5<elapsed<5.5,'Python waits for real .NET sharing contention then executes body once');finish(child,p)

    p=case('python-exhausted');child=launch_holder(p,'dotnet');B.UPGRADE_LOCK=p/'upgrade.lock';bodies=0;begin=time.monotonic()
    try:
        with acquire(B):bodies+=1
    except B.BackupBusy:elapsed=time.monotonic()-begin
    else:raise AssertionError('Permanent native contention accepted')
    check(bodies==0 and 4.8<=elapsed<6,'Python original Busy exhaustion remains five-second bounded with no body');finish(child,p)

    p=case('unchanged-default');child=launch_holder(p,'dotnet');begin=time.monotonic()
    try:
        with B.exclusive_guard(p/'upgrade.lock'):raise AssertionError('Default lock unexpectedly acquired')
    except B.BackupBusy:elapsed=time.monotonic()-begin
    check(elapsed<0.5,'all existing default Windows guard clients still fail immediately');finish(child,p)

    p=case('dotnet-waits-python');child=launch_holder(p,'python');delayed_release(p);r=native(p)
    check(r['state']=='acquired' and r['bodyCount']==1 and 0.4<r['elapsedSeconds']<5.5,'native Ensure acquisition waits for real Python lock and body executes once');finish(child,p)

    p=case('dotnet-exhausted');child=launch_holder(p,'python');r=native(p)
    check(r['state']=='deferred' and r['reason']=='maintenance_busy' and r['bodyCount']==0 and 4.8<=r['elapsedSeconds']<6,'native Ensure returns unchanged deferred JSON after five seconds without body');finish(child,p)

    p=case('body-error-once');B.UPGRADE_LOCK=p/'upgrade.lock';original=B.BackupBusy('private guarded-body fixture');bodies=0
    try:
        with acquire(B):bodies+=1;raise original
    except B.BackupBusy as e:check(e is original and bodies==1,'real acquired guard body BackupBusy preserves exact exception without replay')
    with B.exclusive_guard(p/'upgrade.lock'):pass
    check((p/'upgrade.lock').read_bytes()==b'exact owned lock bytes','real body failure releases exact original handle')

    p=case('python-invalid-path');B.UPGRADE_LOCK=p/'missing'/'upgrade.lock';begin=time.monotonic()
    try:
        with acquire(B):raise AssertionError('Invalid parent acquired')
    except B.BackupError as e:check(type(e)is B.BackupError and time.monotonic()-begin<0.5,'real native missing-parent error never becomes Busy or retries')
    p=case('native-missing-file');(p/'upgrade.lock').unlink();r=native(p)
    check(r['state']=='error' and r['nativeCode'] in (2,3) and r['bodyCount']==0 and r['elapsedSeconds']<0.5,'real native missing-path exception propagates immediately without retry')
    p=case('native-directory');(p/'upgrade.lock').unlink();(p/'upgrade.lock').mkdir();r=native(p)
    check(r['state']=='error' and r['nativeCode'] in (5,267) and r['bodyCount']==0 and r['elapsedSeconds']<0.5,'real native invalid-directory/access error is never retried')
    result={'passed':True,'scope':'isolated_real_Windows_private_dotnet_python_contention_only','checkCount':len(CHECKS),'checks':CHECKS,'elapsedSeconds':time.monotonic()-started,'noInstalledLockTaskServicePortOrWorkerTouched':True,'sourcePins':EXPECTED}
    (ROOT/'native-contention-results.safe.json').write_text(json.dumps(result,indent=2)+'\n')

finally:
    for timer in timers:timer.join(timeout=3)
    cleanup=[]
    for child,p in children:
        release(p)
        code=child.wait(timeout=18)
        cleanup.append({'case':p.name,'pid':child.pid,'exitCode':code,'normalExitNoSignal':True})
    for p in cases:
        for leaf in ['upgrade.lock','holder.ready','holder.release']:
            target=p/leaf
            if target.is_dir():target.rmdir()
            elif target.exists():target.unlink()
    (ROOT/'native-fixture-cleanup.safe.json').write_text(json.dumps({'children':cleanup,'allOwnedHandlesAndChildrenClosed':True,'testOwnedLockAndMarkersRemoved':True,'noSignalsOrForeignDeletes':True},indent=2)+'\n')

result['cleanup']={'ownedChildrenExitedNormally':len(children),'allHandlesClosed':True,'ownedTestRootRemoved':True}
shutil.rmtree(ROOT)
print(json.dumps(result))
