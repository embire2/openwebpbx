#!/usr/bin/env python3
"""Real cross-process Linux maintenance locks; no live PBX/database/service writes."""
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
b=load('scheduler_backups',ROOT/'packaging/debian/backups.py')
w=load('scheduler_onboarding',ROOT/'packaging/debian/onboarding.py')
d=load('scheduler_domains',ROOT/'packaging/debian/tenant-domains.py')

class SchedulerLocks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='openweb-scheduler-locks-')
        self.path=Path(self.temp.name);self.lock=self.path/'maintenance.lock';self.lock.touch(mode=0o600)
    def tearDown(self):self.temp.cleanup()
    @contextlib.contextmanager
    def holder(self,seconds=None):
        release=self.path/'release';release.unlink(missing_ok=True)
        code="import fcntl,pathlib,sys,time\nf=pathlib.Path(sys.argv[1]).open('a');fcntl.flock(f,fcntl.LOCK_EX);print('LOCKED',flush=True)\n"
        code+=("time.sleep(float(sys.argv[2]))\n"if seconds is not None else"while not pathlib.Path(sys.argv[2]).exists():time.sleep(.01)\n")
        child=subprocess.Popen([sys.executable,'-I','-B','-c',code,str(self.lock),str(seconds)if seconds is not None else str(release)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(),'LOCKED');yield child
        finally:
            release.touch()
            if child.poll()is None:
                try:child.wait(timeout=8)
                except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=3)
            self.assertEqual(child.returncode,0,child.stderr.read());child.stdout.close();child.stderr.close()
    def test_default_lock_refuses_immediately(self):
        with self.holder():
            started=time.monotonic()
            with self.assertRaises(b.BackupError):
                with b.exclusive_guard(self.lock):self.fail('Entered a held lock')
            self.assertLess(time.monotonic()-started,.25)
    def test_wait_acquires_after_real_short_holder(self):
        with self.holder(.3):
            started=time.monotonic()
            with b.exclusive_guard(self.lock,wait_seconds=1):self.assertGreaterEqual(time.monotonic()-started,.2)
            self.assertLess(time.monotonic()-started,1.5)
    def test_real_long_holder_has_bounded_refusal(self):
        with self.holder():
            started=time.monotonic()
            with self.assertRaises(b.BackupError):
                with b.exclusive_guard(self.lock,wait_seconds=.2):self.fail('Entered a held lock')
            self.assertGreaterEqual(time.monotonic()-started,.18);self.assertLess(time.monotonic()-started,.6)
    def test_only_lock_contention_is_retried(self):
        with patch.object(b.fcntl,'flock',side_effect=PermissionError('native refusal'))as call:
            started=time.monotonic()
            with self.assertRaisesRegex(PermissionError,'native refusal'):
                with b.exclusive_guard(self.lock,wait_seconds=5):pass
            self.assertEqual(call.call_count,1);self.assertLess(time.monotonic()-started,.25)
    def test_guarded_body_blocking_error_is_not_retried(self):
        entered=[];error=BlockingIOError('body failure')
        with patch.object(b.fcntl,'flock',wraps=fcntl.flock)as call:
            with self.assertRaises(BlockingIOError)as caught:
                with b.exclusive_guard(self.lock,wait_seconds=5):entered.append(True);raise error
            self.assertIs(caught.exception,error);self.assertEqual(entered,[True]);self.assertEqual(call.call_count,1)
    def test_invalid_wait_cannot_extend_bound(self):
        for value in[-1,5.1,float('inf'),float('nan'),True,'5',None]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    with b.exclusive_guard(self.lock,wait_seconds=value):pass
    def test_backup_scheduler_waits_before_any_queue_claim(self):
        claims=[]
        with patch.object(b,'UPGRADE_LOCK',self.lock),patch.object(b,'_worker',side_effect=lambda *a,**kw:claims.append(time.monotonic())or'completed'):
            with self.holder(.3):
                started=time.monotonic();self.assertEqual(b.worker({}),'completed')
                self.assertEqual(len(claims),1);self.assertGreaterEqual(claims[0]-started,.2)
    def test_backup_scheduler_long_holder_preserves_queue(self):
        with patch.object(b,'UPGRADE_LOCK',self.lock),patch.object(b,'_worker')as claim,self.holder():
            started=time.monotonic()
            with self.assertRaises(b.BackupError):b.worker({})
            self.assertGreaterEqual(time.monotonic()-started,4.9);self.assertLess(time.monotonic()-started,5.6);claim.assert_not_called()
    def test_two_real_scheduler_processes_are_serial_and_claim_once_each(self):
        events=self.path/'claims.jsonl'
        program="""import importlib.util,json,os,pathlib,sys,time
s=importlib.util.spec_from_file_location('b',sys.argv[1]);b=importlib.util.module_from_spec(s);s.loader.exec_module(b);b.UPGRADE_LOCK=pathlib.Path(sys.argv[2])
def body(*a,**kw):
 def event(value):
  fd=os.open(sys.argv[3],os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)
  try:os.write(fd,(json.dumps({'pid':os.getpid(),'event':value})+'\\n').encode())
  finally:os.close(fd)
 event('claim');time.sleep(.15);event('complete')
b._worker=body;b.worker({})
"""
        with self.holder():
            children=[subprocess.Popen([sys.executable,'-I','-B','-c',program,str(ROOT/'packaging/debian/backups.py'),str(self.lock),str(events)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)for _ in range(2)]
            try:
                time.sleep(.25);self.assertFalse(events.exists(),'Queue claim occurred before maintenance acquisition')
                (self.path/'release').touch()
                for child in children:
                    out,err=child.communicate(timeout=6);self.assertEqual(child.returncode,0,err)
            finally:
                for child in children:
                    if child.poll()is None:child.terminate();child.wait(timeout=3)
        records=[json.loads(line)for line in events.read_text().splitlines()];self.assertEqual([r['event']for r in records],['claim','complete','claim','complete']);self.assertEqual(records[0]['pid'],records[1]['pid']);self.assertEqual(records[2]['pid'],records[3]['pid']);self.assertNotEqual(records[0]['pid'],records[2]['pid'])
    def test_linux_onboarding_tick_waits_before_processing_jobs(self):
        adapter=SimpleNamespace(UPGRADE_LOCK=self.lock,exclusive_guard=b.exclusive_guard);jobs=[]
        with patch.object(w,'IS_WINDOWS',False),patch.object(w,'environment',return_value=(adapter,SimpleNamespace(blocked=lambda b:False))),patch.object(w,'process_jobs',side_effect=lambda *a:jobs.append(time.monotonic())or{'required':False}),patch.object(sys,'argv',['onboarding.py','--tick']),self.holder(.3):
            started=time.monotonic();self.assertEqual(w.main(),{'required':False});self.assertEqual(len(jobs),1);self.assertGreaterEqual(jobs[0]-started,.2)
    def test_windows_tick_keeps_original_guard_signature(self):
        calls=[]
        @contextlib.contextmanager
        def original_guard(path):calls.append(path);yield
        adapter=SimpleNamespace(UPGRADE_LOCK=self.lock,exclusive_guard=original_guard)
        with patch.object(w,'IS_WINDOWS',True),patch.object(w,'environment',return_value=(adapter,SimpleNamespace(blocked=lambda b:False))),patch.object(w,'process_jobs',return_value={'required':False}),patch.object(sys,'argv',['onboarding.py','--tick']):self.assertEqual(w.main(),{'required':False})
        self.assertEqual(calls,[self.lock])
    def test_linux_tenant_scheduler_waits_before_reading_local_work(self):
        adapter=SimpleNamespace(UPGRADE_LOCK=self.lock,exclusive_guard=b.exclusive_guard)
        spec=SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module:None));observed=[]
        with patch.object(d,'IS_WINDOWS',False),patch.object(d.importlib.util,'spec_from_file_location',return_value=spec),patch.object(d.importlib.util,'module_from_spec',return_value=adapter),patch.object(d,'blocked',side_effect=lambda b:observed.append(time.monotonic())or True),patch.object(d,'bridge')as bridge,self.holder(.3):
            started=time.monotonic();self.assertEqual(d.run(),{'state':'deferred','reason':'maintenance_or_restore_hold'});self.assertEqual(len(observed),1);self.assertGreaterEqual(observed[0]-started,.2);bridge.assert_not_called()
    def test_windows_tenant_scheduler_keeps_original_guard_signature(self):
        calls=[]
        @contextlib.contextmanager
        def original_guard(path):calls.append(path);yield
        adapter=SimpleNamespace(UPGRADE_LOCK=self.lock,exclusive_guard=original_guard);spec=SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module:None))
        with patch.object(d,'IS_WINDOWS',True),patch.object(d.importlib.util,'spec_from_file_location',return_value=spec),patch.object(d.importlib.util,'module_from_spec',return_value=adapter),patch.object(d,'blocked',return_value=True):self.assertEqual(d.run(),{'state':'deferred','reason':'maintenance_or_restore_hold'})
        self.assertEqual(calls,[self.lock])
    def test_explicit_tenant_host_move_keeps_immediate_refusal(self):
        adapter=SimpleNamespace(UPGRADE_LOCK=self.lock,exclusive_guard=b.exclusive_guard)
        spec=SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module:None))
        with patch.object(d,'IS_WINDOWS',False),patch.object(d.importlib.util,'spec_from_file_location',return_value=spec),patch.object(d.importlib.util,'module_from_spec',return_value=adapter),patch.object(d,'blocked')as blocked,patch.object(d,'bridge')as bridge,self.holder():
            started=time.monotonic()
            with self.assertRaises(b.BackupError):d.run(move=True,confirm='operator.example.invalid')
            self.assertLess(time.monotonic()-started,.25);blocked.assert_not_called();bridge.assert_not_called()

if __name__=='__main__':unittest.main()
