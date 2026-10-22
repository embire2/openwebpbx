#!/usr/bin/env python3
"""Actual tenant orchestration and POSIX lock controls; native guard is separate."""
from pathlib import Path
import contextlib, importlib.util, json, os, tempfile, types
from unittest.mock import patch

root=Path(__file__).resolve().parent.parent
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
tenant=load('tenant_contention',root/'packaging/debian/tenant-domains.py')
backup=load('backup_contention',root/'packaging/windows/backups.py')
checks=0;calls=[]
class ReachedBridge(RuntimeError):pass
def bridge(*args):calls.append('bridge');raise ReachedBridge('Owned sentinel')
def forbidden(*args):raise AssertionError('Network/certificate operation forbidden')
def check(value):
 global checks
 assert value,'Actual tenant contention control failed.';checks+=1
def run(b):
 spec=types.SimpleNamespace(loader=types.SimpleNamespace(exec_module=lambda *a:None))
 with patch.object(tenant.importlib.util,'spec_from_file_location',return_value=spec),patch.object(tenant.importlib.util,'module_from_spec',return_value=b),patch.object(tenant,'bridge',side_effect=bridge),patch.object(tenant,'Broker',side_effect=forbidden),patch.object(tenant,'certify',side_effect=forbidden):return tenant.run()
def refuses(b,kind):
 calls.clear()
 try:run(b)
 except kind:check(not calls);return
 raise AssertionError('Required unsafe/permission refusal was swallowed.')
with tempfile.TemporaryDirectory(prefix='openweb-tenant-contention-')as work:
 base=Path(work);backup.STATE=base;backup.RESTORE=base/'backup-restore';backup.RESTORE.mkdir();backup.UPGRADE_LOCK=base/'upgrade.lock';backup.UPGRADE_LOCK.touch();tenant.IS_WINDOWS=True
 hold=backup.RESTORE/'hold-updates';hold.write_text('owned');original_guard=backup.exclusive_guard
 calls.clear();check(run(backup)=={'state':'deferred','reason':'maintenance_or_restore_hold'});check(not calls)
 with original_guard(backup.UPGRADE_LOCK):
  check(run(backup)=={'state':'deferred','reason':'maintenance_or_restore_hold'});check(not calls)
  hold.unlink();check(run(backup)=={'state':'deferred','reason':'maintenance_busy'});check(not calls)
  journal=backup.RESTORE/'journal.json';journal.write_text('{invalid');refuses(backup,json.JSONDecodeError);journal.unlink()
 hold.write_text('owned')
 ordinary=backup.UPGRADE_LOCK;linked=base/'linked.lock'
 if os.name=='nt':os.link(ordinary,linked)
 else:linked.symlink_to(ordinary)
 backup.UPGRADE_LOCK=linked;refuses(backup,backup.BackupError);backup.UPGRADE_LOCK=ordinary;linked.unlink()
 backup.UPGRADE_LOCK=base/'missing/upgrade.lock';refuses(backup,backup.BackupError);backup.UPGRADE_LOCK=ordinary
 @contextlib.contextmanager
 def permission_guard(path):raise backup.BackupError('Private permission detail');yield
 backup.exclusive_guard=permission_guard;refuses(backup,backup.BackupError);backup.exclusive_guard=original_guard
 @contextlib.contextmanager
 def add_hold_after_lock(path):
  with original_guard(path):hold.write_text('owned');yield
 hold.unlink();backup.exclusive_guard=add_hold_after_lock;calls.clear();check(run(backup)=={'state':'deferred','reason':'maintenance_or_restore_hold'});check(not calls);backup.exclusive_guard=original_guard
 hold.unlink();calls.clear()
 try:run(backup)
 except ReachedBridge:check(calls==['bridge'])
 else:raise AssertionError('Successful entry failed to reach the guarded body.')
 with original_guard(ordinary):check(True)
 # A body failure of the same type must propagate, not become a deferral.
 with patch.object(tenant,'blocked',side_effect=backup.BackupBusy('Body failure')):
  refuses(backup,backup.BackupBusy)
 with original_guard(ordinary):check(True)
 # The Debian branch neither looks up BackupBusy nor changes its error result.
 if os.name!='nt':
  tenant.IS_WINDOWS=False;hold.write_text('owned')
  debian=types.SimpleNamespace(UPGRADE_LOCK=ordinary,RESTORE=backup.RESTORE,STATE=base,exclusive_guard=original_guard)
  calls.clear();check(run(debian)=={'state':'deferred','reason':'maintenance_or_restore_hold'});check(not calls)
  with original_guard(ordinary):refuses(debian,backup.BackupBusy)
print(json.dumps({'state':'passed','checks':checks,'actual_source_orchestration':True,'actual_posix_locks':os.name!='nt','actual_native_windows_guard':os.name=='nt','network_sql_certificate_calls_during_defer':0}))
