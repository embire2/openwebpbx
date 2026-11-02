"""Windows backup-worker acquisition fairness; no real worker or product paths."""
import argparse, ast, contextlib, hashlib, importlib.util, json, os, subprocess, sys, time
from pathlib import Path
from types import SimpleNamespace

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1] / 'packaging/windows/backups.py')
p.add_argument('--previous', type=Path)
p.add_argument('--work-root', type=Path)
p.add_argument('--native', action='store_true')
a = p.parse_args()
checks = 0

def need(value):
    global checks
    assert value
    checks += 1

source = a.source.read_text()
tree = ast.parse(source)
def node(name):
    return next(x for x in tree.body if isinstance(x, (ast.FunctionDef, ast.ClassDef)) and x.name == name)
def segment(name):
    return ast.get_source_segment(source, node(name))

class Clock:
    def __init__(self): self.now = 0; self.sleeps = []
    def monotonic(self): return self.now
    def sleep(self, value): self.sleeps.append(value); self.now += value
class Marker:
    value = False
    def __truediv__(self, name): return self
    def exists(self): return self.value

# Execute the two real source functions with bounded acquisition adapters.
ns = {'contextlib': contextlib, 'os': SimpleNamespace(name='nt')}
exec(compile(ast.Module(body=[node(n) for n in ('BackupError', 'BackupBusy', 'backup_worker_guard', 'worker')], type_ignores=[]), '<actual-backup-worker-functions>', 'exec'), ns)
Busy, Error = ns['BackupBusy'], ns['BackupError']
def case(sequence=(), *, body_error=None, release_error=None, hold=False, maintenance=False, hold_on_wait=False, maintenance_on_wait=False, platform='nt'):
    clock = Clock(); marker = Marker(); marker.value = maintenance
    state = {'attempts': 0, 'body': 0, 'released': 0, 'hold': hold, 'settings': None, 'kwargs': None}
    ns.update(time=clock, os=SimpleNamespace(name=platform), STATE=marker, UPGRADE_LOCK='external-adapter-lock', restore_pending=lambda: state['hold'])
    @contextlib.contextmanager
    def guard(path):
        need(path == 'external-adapter-lock'); state['attempts'] += 1
        if state['attempts'] <= len(sequence):
            exc = sequence[state['attempts'] - 1]
            if exc:
                if hold_on_wait: state['hold'] = True
                if maintenance_on_wait: marker.value = True
                raise exc('fixture')
        try: yield
        finally:
            state['released'] += 1
            if release_error: raise release_error('release fixture')
    def body(settings, **kwargs):
        state['body'] += 1; state['settings'] = settings; state['kwargs'] = kwargs
        if body_error: raise body_error('body fixture')
        return 'one-body-result'
    ns.update(exclusive_guard=guard, _worker=body)
    error = None
    try: state['result'] = ns['worker']({'private': 'unlogged-fixture'}, value=17)
    except BaseException as e: error = type(e)
    return state, clock, error

s,c,e = case(); need(e is None and s['body'] == 1 and s['attempts'] == 1 and s['released'] == 1 and s['result'] == 'one-body-result'); need(s['settings'] == {'private':'unlogged-fixture'} and s['kwargs'] == {'value':17} and not c.sleeps)
s,c,e = case((Busy,Busy)); need(e is None and s['attempts'] == 3 and s['body'] == 1 and c.sleeps == [.25,.25])
s,c,e = case((Busy,)*130); need(e is Busy and s['body'] == 0 and c.now == 30 and max(c.sleeps) <= .25)
for exception in (Error, OSError, RuntimeError):
    s,c,e = case((exception,)); need(e is exception and s['attempts'] == 1 and s['body'] == 0 and not c.sleeps)
for exception in (Busy, Error, OSError, RuntimeError):
    s,c,e = case(body_error=exception); need(e is exception and s['attempts'] == 1 and s['body'] == 1 and s['released'] == 1 and not c.sleeps)
s,c,e = case(release_error=Busy); need(e is Busy and s['attempts'] == 1 and s['body'] == 1 and not c.sleeps)
for options in ({'hold':True},{'maintenance':True}):
    s,c,e = case(**options); need(e is None and s['attempts'] == 0 and s['body'] == 0)
for options in ({'hold_on_wait':True},{'maintenance_on_wait':True}):
    s,c,e = case((Busy,), **options); need(e is None and s['attempts'] == 2 and s['body'] == 0 and s['released'] == 1)
s,c,e = case((Busy,), platform='posix'); need(e is Busy and s['attempts'] == 1 and s['body'] == 0 and not c.sleeps)
s,c,e = case(platform='posix'); need(e is None and s['body'] == 1 and not c.sleeps)
if a.previous:
    old = a.previous.read_text(); prior = ast.parse(old)
    for name in ('exclusive_guard','windows_exclusive_guard','_worker','restore','recover'):
        n = next(x for x in prior.body if isinstance(x,ast.FunctionDef) and x.name == name)
        need(ast.dump(n,include_attributes=False) == ast.dump(node(name),include_attributes=False))

result = {'state':'passed','checks':checks,'sourceSHA256':hashlib.sha256(a.source.read_bytes()).hexdigest(),'actualWorkerFunctions':True,'noRealWorkerOrProductPaths':True,'native':False}
if a.native:
    assert os.name == 'nt' and a.work_root and not a.work_root.exists()
    a.work_root.mkdir(mode=0o700)
    spec=importlib.util.spec_from_file_location('native_backup_wait_current',a.source); m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
    lock=a.work_root/'worker-external.lock';lock.write_bytes(b'')
    child_code="import importlib.util,sys,time;from pathlib import Path;s=importlib.util.spec_from_file_location('holder',sys.argv[1]);m=importlib.util.module_from_spec(s);sys.modules[s.name]=m;s.loader.exec_module(m);\nwith m.exclusive_guard(Path(sys.argv[2])):\n print('HELD',flush=True);time.sleep(float(sys.argv[3]))"
    def holder(seconds):
        child=subprocess.Popen([sys.executable,'-I','-B','-c',child_code,str(a.source.resolve()),str(lock),str(seconds)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        need(child.stdout.readline().strip() == 'HELD');return child
    child=holder(2);began=time.monotonic();body=0
    with m.backup_worker_guard(lock): body+=1
    elapsed=time.monotonic()-began;need(child.wait(timeout=5)==0 and body==1 and 1<=elapsed<10)
    # Real held lock through the unchanged30s bound; holder exits naturally.
    child=holder(32);began=time.monotonic();refused=False
    try:
        with m.backup_worker_guard(lock): raise AssertionError('A held lock entered the body')
    except m.BackupBusy: refused=True
    elapsed=time.monotonic()-began;need(refused and 29.5<=elapsed<32);need(child.wait(timeout=5)==0)
    # Body Busy must leave immediately, with no acquisition retry.
    began=time.monotonic();body=0;refused=False
    try:
        with m.backup_worker_guard(lock): body+=1;raise m.BackupBusy('body fixture')
    except m.BackupBusy: refused=True
    need(refused and body==1 and time.monotonic()-began<1)
    with m.backup_worker_guard(lock): need(True)
    bad=a.work_root/'directory-is-not-lock';bad.mkdir();began=time.monotonic();refused=False
    try:
        with m.backup_worker_guard(bad): raise AssertionError('Invalid lock entered the body')
    except m.BackupError as error: refused=not isinstance(error,m.BackupBusy)
    need(refused and time.monotonic()-began<1)
    result.update(checks=checks,native=True,nativeHolderNaturalExits=True,nativeExhaustBoundSeconds=30)
    (a.work_root/'result.safe.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
