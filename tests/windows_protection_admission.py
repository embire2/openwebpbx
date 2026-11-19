#!/usr/bin/env python3
"""AST-only recovery admission controls; optional real private Windows locks.

No product module initialization, settings, SQL, services, tasks, ACL changes,
registration or default product roots execute. Holders exit naturally.
"""
import argparse
import ast
import concurrent.futures
import contextlib
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import subprocess
import sys
import tempfile
import time
import types

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = ROOT/'packaging/debian/protection.py'
BACKUPS = ROOT/'packaging/windows/backups.py'
BASE_SHA = 'd71aa2ec349131f149bc22c9c82decd6d79965cb098eec4a2b95e5c9c48d2dda'
BACKUP_SHA = '841f1f15d34f357e03da95419eea2420293eb9a2e5d8eb8f0c6c41455decada6'
FIRST_OLD = '            with full.exclusive_guard(full.UPGRADE_LOCK):pass'
FIRST_NEW = '''            with full.backup_worker_guard(full.UPGRADE_LOCK):
                if full.restore_pending() or (full.STATE/'updates/maintenance').exists():return'''
SECOND_OLD = '                with full.exclusive_guard(full.UPGRADE_LOCK):recover_tenant_journals(settings)'
SECOND_NEW = '''                with full.backup_worker_guard(full.UPGRADE_LOCK):
                    if full.restore_pending() or (full.STATE/'updates/maintenance').exists():return
                    recover_tenant_journals(settings)'''
SOURCE = PRODUCT.read_text(encoding='utf-8')
assert SOURCE.count(FIRST_NEW) == SOURCE.count(SECOND_NEW) == 1
PREVIOUS = SOURCE.replace(FIRST_NEW, FIRST_OLD).replace(SECOND_NEW, SECOND_OLD)
assert hashlib.sha256(PREVIOUS.encode()).hexdigest() == BASE_SHA
assert hashlib.sha256(BACKUPS.read_bytes()).hexdigest() == BACKUP_SHA
PINS = {'protection.py': hashlib.sha256(PRODUCT.read_bytes()).hexdigest(),
        'backups.py': BACKUP_SHA, 'previous_protection.py': BASE_SHA}
checks = []
def check(value, label):
    if not value: raise AssertionError(label)
    checks.append(label)

def definitions(source, names):
    nodes = [n for n in ast.parse(source).body
             if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in names]
    assert {n.name for n in nodes} == set(names)
    return nodes

class Busy(RuntimeError): pass
class Fatal(RuntimeError): pass

def native_backend():
    names = {'BackupError', 'BackupBusy', 'reparse', 'windows_exclusive_guard',
             'exclusive_guard', 'backup_worker_guard', 'lock_file', 'unlock_file'}
    scope = {'Path': Path, 'os': os, 'contextlib': contextlib, 'time': time}
    if os.name == 'nt':
        import msvcrt
        scope['msvcrt'] = msvcrt
    exec(compile(ast.Module(body=definitions(BACKUPS.read_text(), names), type_ignores=[]),
                 str(BACKUPS), 'exec'), scope)
    return types.SimpleNamespace(**{n: scope[n] for n in names})

def invoke(directory, *, previous=False, windows=True, backend=None,
           acquire_error=None, gate_after=None, body_error=None, start_second=None):
    directory.mkdir(parents=True, exist_ok=True)
    state_root = directory/'state'; (state_root/'updates').mkdir(parents=True, exist_ok=True)
    paths = {n: directory/n for n in ['store','downloads','work','status']}
    for path in paths.values(): path.mkdir(exist_ok=True)
    state = {'dirs': [], 'recover': 0, 'queries': [], 'upgrade_entries': [], 'held': 0}
    full = types.SimpleNamespace(STATE=state_root, UPGRADE_LOCK=directory/'upgrade.lock',
                                 BackupBusy=backend.BackupBusy if backend else Busy,
                                 BackupError=backend.BackupError if backend else Fatal)
    full.restore_pending = lambda: (state_root/'restore.flag').exists()
    @contextlib.contextmanager
    def guard(path, bounded):
        upgrade = path == full.UPGRADE_LOCK
        if upgrade:
            state['upgrade_entries'].append('30s' if bounded else 'nonblocking')
            stage = len(state['upgrade_entries'])
            if acquire_error: raise acquire_error
        else: stage = None
        real = (backend.backup_worker_guard(path) if bounded else backend.exclusive_guard(path)) if backend else contextlib.nullcontext()
        with real:
            state['held'] += 1
            try:
                if upgrade and gate_after and stage == gate_after[0]:
                    target = state_root/('restore.flag' if gate_after[1] == 'restore' else 'updates/maintenance')
                    target.write_bytes(b'fixture-only')
                yield
            finally: state['held'] -= 1
    full.exclusive_guard = lambda path: guard(path, False)
    full.backup_worker_guard = lambda path: guard(path, True)
    def safe_directory(path, group=None):
        state['dirs'].append((path.name, group))
        if len(state['dirs']) == 1 and start_second: start_second(directory)
        return path
    full.safe_private_directory = safe_directory
    def query(settings, sql, **options):
        state['queries'].append(sql)
        return ''  # Deliberately EMPTY queue, never execute or emulate SQL.
    full.query = query
    def recover(settings):
        state['recover'] += 1
        if body_error: raise body_error
    scope = {'os': types.SimpleNamespace(name='nt' if windows else 'posix'),
             'full': full, 'STORE': paths['store'], 'DOWNLOADS': paths['downloads'],
             'WORK': paths['work'], 'STATUS': paths['status'],
             'recover_tenant_journals': recover, 'json': json, 'contextlib': contextlib}
    exec(compile(ast.Module(body=definitions(PREVIOUS if previous else SOURCE, {'worker'}),
                            type_ignores=[]), str(PRODUCT), 'exec'), scope)
    error = None
    try: scope['worker']({'fixture_only': True})
    except BaseException as caught: error = caught
    return state, error

def effects(state):
    return {k: state[k] for k in ['dirs','recover','queries']}

def portable(work):
    for blocked in ['C:/OpenWebPBX/openweb-protection-admission-x',
                    r'c:\OPENWEBPBX\openweb-protection-admission-x',
                    'C:/ProgramData/OpenWebPBX/openweb-protection-admission-x',
                    r'C:\PROGRAMDATA\OPENWEBPBX\openweb-protection-admission-x']:
        check(not valid_native_root(Path(blocked)), 'native default product root refused '+blocked)
    check(not valid_native_root(Path(tempfile.gettempdir())/'..'/'openweb-protection-admission-x'),
          'native parent traversal refused before filesystem changes')
    check(valid_native_root(Path(tempfile.gettempdir())/'openweb-protection-admission-x'),
          'own native TEMP prefix admitted')
    check(hashlib.sha256(PREVIOUS.encode()).hexdigest() == BASE_SHA,
          'whole baseline7 module byte-exact after reversing ONLY two Windows preclaim changes')
    old, e = invoke(work/'empty-old', previous=True)
    new, f = invoke(work/'empty-new')
    check(e is None and f is None and effects(old) == effects(new) and
          len(new['dirs']) == 4 and new['recover'] == 1 and len(new['queries']) == 2,
          'actual old/new EMPTYQUEUE startup executes identical four ACL callbacks, recovery once, two SQL strings without execution')
    check(new['upgrade_entries'] == ['30s','30s'] and old['upgrade_entries'] == ['nonblocking','nonblocking'],
          'only both scheduled Windows preclaim probes select existing30s helper')
    for previous in [False, True]:
        s, e = invoke(work/('linux-'+str(previous)), previous=previous, windows=False)
        check(e is None and not s['upgrade_entries'] and len(s['queries']) == 2,
              'Linux worker path unchanged '+str(previous))
    for stage in [1, 2]:
        for gate in ['restore','maintenance']:
            s, e = invoke(work/('gate-'+str(stage)+'-'+gate), gate_after=(stage,gate))
            check(e is None and s['recover'] == 0 and not s['queries'] and
                  len(s['dirs']) == (0 if stage == 1 else 4) and not s['held'],
                  'fresh '+gate+' after waited guard'+str(stage)+' defers before protected work')
    for error in [Busy('native contention'), Fatal('native permission/path'), PermissionError('native permission')]:
        s, e = invoke(work/('acquire-'+type(error).__name__), acquire_error=error)
        check((e is None if isinstance(error, Busy) else e is error) and
              not s['dirs'] and not s['queries'] and not s['recover'],
              'acquisition '+type(error).__name__+' preserves classification and pending queue')
    for error in [Busy('body contention'), Fatal('body failure'), PermissionError('body permission')]:
        s, e = invoke(work/('body-'+type(error).__name__), body_error=error)
        check((e is None if isinstance(error, Busy) else e is error) and
              s['recover'] == 1 and len(s['upgrade_entries']) == 2 and not s['queries'] and not s['held'],
              'existing recovery body '+type(error).__name__+' runs once without acquisition retry')
    native = next(n for n in ast.parse(BACKUPS.read_text()).body
                  if isinstance(n,ast.FunctionDef) and n.name == 'windows_exclusive_guard')
    refuse = next(n for n in native.body if isinstance(n,ast.FunctionDef) and n.name == 'refuse')
    scope = {'BackupBusy': Busy, 'BackupError': Fatal}
    exec(compile(ast.Module(body=[refuse],type_ignores=[]),str(BACKUPS),'exec'),scope)
    for code in [32,33,5,2,87]:
        try: scope['refuse'](code)
        except BaseException as error:
            check(type(error) is (Busy if code in [32,33] else Fatal),
                  'exact native source error classifier '+str(code)+' only32/33 defers')
    check(SOURCE.count('full.backup_worker_guard(full.UPGRADE_LOCK)') == 2,
          'foreground and all postclaim guards untouched under whole-module invariance')


def valid_native_root(work):
    p = PureWindowsPath(str(work))
    if '..' in p.parts: return False
    for blocked in [PureWindowsPath('C:/OpenWebPBX'), PureWindowsPath('C:/ProgramData/OpenWebPBX')]:
        if p.is_relative_to(blocked): return False
    return p.is_relative_to(PureWindowsPath(tempfile.gettempdir())) and work.name.startswith('openweb-protection-admission-')

def hold(directory, seconds, marker):
    assert os.name == 'nt' and (directory.parent/'fixture-owner.json').is_file()
    assert valid_native_root(directory.parent)
    for ancestor in [directory, *directory.parents]:
        assert not(getattr(ancestor.stat(),'st_file_attributes',0)&0x400)
    assert directory.name in ['first-old','first-new','second-old','second-new','timeout','first-hold','second-hold']
    b = native_backend()
    with b.exclusive_guard(directory/'upgrade.lock'):
        (directory/'holder.ready').write_bytes(b'ready'); time.sleep(seconds)
        if marker:
            target = directory/'state'/('restore.flag' if marker == 'restore' else 'updates/maintenance')
            target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(b'own-fixture-hold')
    (directory/'holder.finished').write_bytes(b'finished')

def native_case(work, name):
    directory = work/name; directory.mkdir()
    (directory/'upgrade.lock').write_bytes(b'unchanged-own-lock')
    b = native_backend(); children = []
    def launch(directory):
        seconds = 35 if name == 'timeout' else 15
        marker = 'restore' if name == 'first-hold' else 'maintenance' if name == 'second-hold' else ''
        child = subprocess.Popen([sys.executable,'-I','-B',str(Path(__file__).resolve()),
                                  '--hold',str(directory),'--seconds',str(seconds),'--marker',marker],
                                 stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        children.append(child); deadline = time.monotonic()+15
        while not(directory/'holder.ready').exists():
            if child.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('Own natural holder did not become ready')
            time.sleep(.01)
    second = name.startswith('second')
    if not second: launch(directory)
    started = time.monotonic()
    state, error = invoke(directory, previous=name.endswith('old'), backend=b,
                          start_second=launch if second else None)
    elapsed = time.monotonic()-started
    if name.endswith('old'):
        assert error is None and not state['queries'] and not state['recover'] and elapsed < 5
    elif name == 'timeout':
        assert error is None and not state['dirs'] and not state['queries'] and 29.5 <= elapsed < 34
    elif name in ['first-hold','second-hold']:
        assert error is None and not state['queries'] and not state['recover'] and elapsed >= 14
        assert len(state['dirs']) == (0 if name == 'first-hold' else 4)
    else:
        assert error is None and len(state['dirs']) == 4 and state['recover'] == 1 and len(state['queries']) == 2
        assert 14 <= elapsed < 32
    for child in children:
        stdout, stderr = child.communicate(timeout=40)
        assert child.returncode == 0 and not stderr and (directory/'holder.finished').exists()
    assert (directory/'upgrade.lock').read_bytes() == b'unchanged-own-lock'
    with b.exclusive_guard(directory/'upgrade.lock'): pass
    return {'case':name,'passed':True,'worker_seconds':elapsed,'natural_holders_exited':True,
            'held_seconds':35 if name == 'timeout' else 15,'effects':effects(state),
            'handles_reacquired':True}

def native(work):
    assert os.name == 'nt' and valid_native_root(work) and not work.exists()
    for ancestor in work.parents:
        assert not(getattr(ancestor.stat(),'st_file_attributes',0)&0x400)
    work.mkdir(); (work/'fixture-owner.json').write_text(json.dumps({'source_pins':PINS}))
    started = time.monotonic()
    cases = ['first-old','first-new','second-old','second-new','timeout','first-hold','second-hold']
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(cases)) as pool:
        results = list(pool.map(lambda name:native_case(work,name),cases))
    b = native_backend()
    old, e = invoke(work/'empty-native-old', previous=True, backend=b)
    new, f = invoke(work/'empty-native-new', backend=b)
    assert e is None and f is None and effects(old) == effects(new) and new['recover'] == 1 and len(new['queries']) == 2
    for name, error in [('Busy',b.BackupBusy('body once')),('fatal',RuntimeError('body once'))]:
        s,e = invoke(work/('body-native-'+name),backend=b,body_error=error)
        assert (e is None if name == 'Busy' else e is error) and s['recover'] == 1 and not s['queries']
        with b.exclusive_guard(work/('body-native-'+name)/'upgrade.lock'): pass
    missing = work/'missing'/'upgrade.lock'; begin = time.monotonic()
    try:
        with b.backup_worker_guard(missing): pass
    except b.BackupError as error:
        assert type(error) is b.BackupError and time.monotonic()-begin < 2
    else: raise AssertionError('Missing path must be fatal')
    result = {'passed':True,'scope':'AST-only source; no product imports/default paths/SQL/services/ACL writes',
              'native_cases':results,'empty_queue_startup_old_new_effects_exact':True,
              'body_failures_once':True,'missing_path_fatal':True,'source_pins':PINS,
              'elapsed_seconds':time.monotonic()-started,'portable_controls':len(checks)}
    (work/'native-result.safe.json').write_text(json.dumps(result,indent=2)); print(json.dumps({'passed':True,'native_cases':len(cases),'elapsed_seconds':result['elapsed_seconds']}))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--native',action='store_true')
    parser.add_argument('--work-root',type=Path); parser.add_argument('--hold',type=Path)
    parser.add_argument('--seconds',type=int,choices=[15,35]); parser.add_argument('--marker',choices=['','restore','maintenance'],default='')
    args = parser.parse_args()
    if args.hold:
        hold(args.hold,args.seconds,args.marker); raise SystemExit(0)
    with tempfile.TemporaryDirectory(prefix='openweb-protection-portable-') as directory:
        portable(Path(directory))
    print(json.dumps({'portable_passed':True,'controls':len(checks),'source_pins':PINS}))
    if args.native:
        assert args.work_root is not None
        native(args.work_root)
