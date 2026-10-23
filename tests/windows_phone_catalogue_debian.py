#!/usr/bin/env python3
"""Real owned Linux filesystem; explicit systemd/path adapters, no installed changes."""
import hashlib
import fcntl
import ast
import subprocess
from unittest import mock
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import types
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class CatalogueDebian(unittest.TestCase):
    def setUp(self):
        if os.name != 'posix' or os.geteuid() != 0:
            raise RuntimeError('This actual-filesystem fixture requires an isolated Linux root context.')
        self.base = Path('/var/lib/openwebpbx/windows-phone100') / ('catalogue-debian-fixture-' + uuid.uuid4().hex)
        self.base.mkdir(mode=0o700)
        self.addCleanup(shutil.rmtree, self.base)
        self.package = self.base / 'package'
        self.package.mkdir()
        spec = importlib.util.spec_from_file_location('catalogue_debian_fixture', ROOT / 'packaging/debian/install-windows-phone-catalogue.py')
        self.m = m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        m.PACKAGE = self.package
        m.TOOLS = self.base / 'tools'; m.TOOLS.mkdir()
        m.STATE = self.base / 'state/windows-phone-catalogue'; m.STATE.parent.mkdir()
        unitdir = self.base / 'systemd'; unitdir.mkdir()
        m.UNIT = unitdir / 'openwebpbx-windows-phone-catalogue.service'
        m.TIMER = unitdir / 'openwebpbx-windows-phone-catalogue.timer'
        m.CHOICE = m.TOOLS / 'windows-phone-catalogue-install.json'
        m.MAINTENANCE_LOCK = self.base/'maintenance.lock'; m.MAINTENANCE_LOCK.write_bytes(b'owned lease bytes'); m.MAINTENANCE_LOCK.chmod(0o600)
        m.PENDING = self.base/'updates'; m.PENDING.mkdir(mode=0o700)
        self.envpatch=mock.patch.dict(os.environ, {}, clear=False); self.envpatch.start(); self.addCleanup(self.envpatch.stop)
        os.environ.pop(m.LEASE_ENV, None)
        m.LINKS = (unitdir / 'timers.target.wants' / m.TIMER.name,
                   unitdir / 'openwebpbx-updater.service.wants' / m.TIMER.name)
        for link in m.LINKS:
            link.parent.mkdir()
        names = (*m.PROGRAMS, m.UNIT.name, m.TIMER.name)
        files = {}
        for name in names:
            source = ROOT / ('packaging/updates/' if name == 'windows-phone-catalogue.php' else 'packaging/debian/') / name
            content = source.read_bytes()
            (self.package / name).write_bytes(content)
            files[name] = hashlib.sha256(content).hexdigest()
        (self.package/'VERSION').write_text('1.0.20\n'); files['VERSION']=hashlib.sha256((self.package/'VERSION').read_bytes()).hexdigest()
        (self.package / 'release-manifest.json').write_text(json.dumps({'version':'1.0.20','files': files}))
        self.calls = []
        self.enabled = False
        self.loaded = 'not-found'
        self.fail_enable = False
        self.active = False
        self.stuck_writer = False

        def run(args, **kwargs):
            self.calls.append(tuple(args))
            if args[1] == 'enable':
                if self.fail_enable:
                    raise RuntimeError('Deliberate fixture enable refusal')
                self.enabled = True
                for link in m.LINKS:
                    if not link.exists():
                        link.symlink_to(m.TIMER)
            if args[1] == 'stop': self.active=False
            if args[1] == 'start': self.active=True
            code=(0 if self.enabled else 1) if args[1]=='is-enabled' else ((0 if self.active else 3) if args[1]=='is-active' else 0)
            return types.SimpleNamespace(returncode=code)
        def output(args, **kwargs):
            prop=args[3]
            if prop=='--property=FragmentPath': return str(m.UNIT if args[2]==m.UNIT.name else m.TIMER)+'\n'
            if prop=='--property=ActiveState': return ('active' if self.stuck_writer else 'inactive')+'\n'
            if prop=='--property=MainPID': return '0\n'
            return self.loaded+'\n'
        m.subprocess = types.SimpleNamespace(run=run, check_output=output, DEVNULL=-3)

    def choice(self):
        return json.loads(self.m.CHOICE.read_text())

    def activate(self):
        self.m.PACKAGE = self.m.TOOLS
        return self.m.install(True)

    def snapshot(self):
        result = {}
        for p in sorted(self.base.rglob('*')):
            s = p.lstat()
            result[str(p.relative_to(self.base))] = (
                stat.S_IMODE(s.st_mode), s.st_uid, s.st_gid,
                ('link', os.readlink(p)) if p.is_symlink() else ('directory',) if p.is_dir() else ('file', p.read_bytes()))
        return result

    def test_stage_disabled_until_commit(self):
        self.m.install()
        self.assertFalse(self.m.STATE.exists())
        self.assertFalse(self.enabled)
        self.assertNotIn('enable', [c[1] for c in self.calls])
        self.assertNotIn('start', [c[1] for c in self.calls])
        self.assertIs(self.choice()['enable_on_commit'], True)
        self.assertEqual(self.choice()['service_sha256'], hashlib.sha256(self.m.UNIT.read_bytes()).hexdigest())
        self.assertEqual(self.choice()['timer_sha256'], hashlib.sha256(self.m.TIMER.read_bytes()).hexdigest())

    def test_activate_owns_real_permissions_and_links(self):
        self.m.install(); self.activate()
        self.assertTrue(self.enabled)
        self.assertIs(self.choice()['enable_on_commit'], False)
        self.assertEqual(stat.S_IMODE(self.m.STATE.stat().st_mode), 0o2750)
        self.assertEqual(stat.S_IMODE((self.m.STATE/'owner.json').stat().st_mode), 0o640)
        self.assertEqual(stat.S_IMODE((self.m.STATE/'refresh.lock').stat().st_mode), 0o600)
        for link in self.m.LINKS:
            self.assertEqual(link.resolve(), self.m.TIMER)

    def test_explicit_disabled_choice_stays_disabled(self):
        self.m.install(); self.activate()
        self.enabled = False; self.active = False
        for link in self.m.LINKS: link.unlink()
        self.calls.clear(); self.m.PACKAGE = self.package; self.m.install(); self.activate()
        self.assertFalse(self.enabled)
        self.assertNotIn('enable', [c[1] for c in self.calls])
        self.assertNotIn('start', [c[1] for c in self.calls])
        self.assertTrue(all(not p.exists() for p in self.m.LINKS))

    def test_enabled_choice_preserved(self):
        self.m.install(); self.activate(); self.calls.clear()
        self.m.PACKAGE = self.package; self.m.install(); self.activate()
        self.assertTrue(self.enabled)
        self.assertNotIn('enable', [c[1] for c in self.calls])
        self.assertIn('start', [c[1] for c in self.calls])

    def test_actual_changed_unit_refuses_before_any_effect(self):
        self.m.install()
        self.m.UNIT.write_bytes(self.m.UNIT.read_bytes() + b'\nExecStart=/foreign/command\n')
        before = self.snapshot(); self.calls.clear()
        with self.assertRaises(ValueError): self.activate()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.calls, [])

    def test_unsealed_owned_header_is_not_ownership(self):
        self.m.UNIT.write_bytes(self.m.HEADER + b'[Service]\nExecStart=/foreign/command\n')
        before = self.snapshot()
        with self.assertRaises(ValueError): self.m.install()
        self.assertEqual(before, self.snapshot())
        self.assertEqual(self.calls, [])

    def test_foreign_choice_refuses_before_restage(self):
        self.m.install(); self.m.CHOICE.write_text('{"schema":true}')
        before = self.snapshot(); self.calls.clear()
        with self.assertRaises(ValueError): self.m.install()
        self.assertEqual(before, self.snapshot()); self.assertEqual(self.calls, [])

    def test_external_loaded_registration_refuses(self):
        self.loaded = 'loaded'; before = self.snapshot()
        with self.assertRaises(ValueError): self.m.install()
        self.assertEqual(before, self.snapshot()); self.assertEqual(self.calls, [])

    def test_enable_failure_and_restage_keep_prepared_choice(self):
        self.m.install(); self.fail_enable = True
        with self.assertRaises(RuntimeError): self.activate()
        self.assertIs(self.choice()['enable_on_commit'], True)
        self.m.PACKAGE = self.package; self.m.install()
        self.assertIs(self.choice()['enable_on_commit'], True)
        self.fail_enable = False; self.activate()
        self.assertTrue(self.enabled); self.assertIs(self.choice()['enable_on_commit'], False)

    def test_unknown_state_retained(self):
        self.m.install(); self.activate()
        unknown = self.m.STATE/'unknown.json'; unknown.write_bytes(b'foreign fixture')
        before = self.snapshot(); self.calls.clear()
        with self.assertRaises(ValueError): self.activate()
        self.assertEqual(before, self.snapshot()); self.assertEqual(self.calls, [])

    def test_foreign_enablement_link_retained(self):
        self.m.LINKS[0].symlink_to(self.package/'foreign')
        before = self.snapshot()
        with self.assertRaises(ValueError): self.m.install()
        self.assertEqual(before, self.snapshot()); self.assertEqual(self.calls, [])

    def test_hardlinked_choice_refuses(self):
        self.m.install(); os.link(self.m.CHOICE, self.base/'choice-link')
        before = self.snapshot(); self.calls.clear()
        with self.assertRaises(ValueError): self.activate()
        self.assertEqual(before, self.snapshot()); self.assertEqual(self.calls, [])

    def load_script(self, name):
        spec=importlib.util.spec_from_file_location('catalogue_'+name.replace('-','_'), ROOT/'packaging/debian'/name)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        return module

    def test_helper_checksum_precedes_candidate_import(self):
        support=self.load_script('install-support.py');support.PACKAGE=self.package
        support.SUPPORT={'install-windows-phone-catalogue.py':self.m.TOOLS/'install-windows-phone-catalogue.py'}
        sentinel=self.base/'untrusted-import-ran'
        (self.package/'install-windows-phone-catalogue.py').write_text('from pathlib import Path\nPath('+repr(str(sentinel))+').write_text("untrusted")\n')
        with self.assertRaises(ValueError):support.install()
        self.assertFalse(sentinel.exists())

    def test_actual_shared_lock_blocks_before_service_or_file_writes(self):
        with self.m.MAINTENANCE_LOCK.open('r+b') as held:
            fcntl.flock(held,fcntl.LOCK_EX)
            before=self.snapshot()
            with self.assertRaises(BlockingIOError): self.m.install()
            self.assertEqual(self.snapshot(),before);self.assertEqual(self.calls,[])
        self.m.install()

    def test_inherited_descriptor_requires_own_real_exclusive_lease(self):
        with self.m.MAINTENANCE_LOCK.open('r+b') as lease:
            os.environ[self.m.LEASE_ENV]=str(lease.fileno())
            with self.assertRaises(ValueError): self.m.inherited_fd()
            fcntl.flock(lease,fcntl.LOCK_SH)
            with self.assertRaises(ValueError): self.m.inherited_fd()
            fcntl.flock(lease,fcntl.LOCK_EX)
            self.assertEqual(self.m.inherited_fd(),lease.fileno())
            with self.m.maintenance_lease() as inherited: self.assertEqual(inherited,lease.fileno())
            with self.m.MAINTENANCE_LOCK.open('r+b') as other:
                with self.assertRaises(BlockingIOError): fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(self.m.MAINTENANCE_LOCK.read_bytes(),b'owned lease bytes')

    def test_actual_fd_survives_php_support_helper_chain(self):
        # Execute the actual bootstrap passthru statement and actual support
        # launch function. Only the leaf install BODY is a declared read-only
        # lease probe; no systemd, installed configuration or services execute.
        chain=self.base/'chain';chain.mkdir()
        source=ROOT/'packaging/debian/install-windows-phone-catalogue.py'
        prelude=f"import importlib.util,os\nfrom pathlib import Path\ns=importlib.util.spec_from_file_location('leaf',{str(source)!r});m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.MAINTENANCE_LOCK=Path({str(self.m.MAINTENANCE_LOCK)!r})\n"
        (chain/'install-windows-phone-catalogue.py').write_text(prelude+"with m.maintenance_lease() as fd: print('actual inherited lease accepted')\n")
        support=(ROOT/'packaging/debian/install-support.py').read_text()
        tree=ast.parse(support);node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='run_catalogue_helper')
        launch=ast.get_source_segment(support,node)
        (chain/'install-support.py').write_text(prelude+"import subprocess\nPACKAGE=Path(__file__).parent\n"+launch+"\nrun_catalogue_helper(m.inherited_fd(),False)\n")
        bootstrap=(ROOT/'packaging/windows/bootstrap.php').read_text()
        exact="  $command='python3 '.escapeshellarg(__DIR__.'/install-support.py');passthru($command,$result);"
        self.assertEqual(bootstrap.count(exact),1)
        (chain/'bootstrap.php').write_text('<?php\n'+exact+'\nexit($result);\n')
        upgrade=self.load_script('upgrade.py')
        with self.m.MAINTENANCE_LOCK.open('r+b') as lease:
            fcntl.flock(lease,fcntl.LOCK_EX);upgrade.CATALOGUE_LOCK_FD=lease.fileno()
            result=subprocess.run(['php',str(chain/'bootstrap.php')],capture_output=True,text=True,timeout=10,**upgrade.catalogue_child_options())
            self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,'actual inherited lease accepted\n')
            with self.m.MAINTENANCE_LOCK.open('r+b') as contender:
                with self.assertRaises(BlockingIOError):fcntl.flock(contender,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(self.m.MAINTENANCE_LOCK.read_bytes(),b'owned lease bytes')

    def test_pending_bundle_is_inert_and_exact_prior_absence_restores(self):
        support=self.load_script('install-support.py');upgrade=self.load_script('upgrade.py')
        backup=self.base/'backup';backup.mkdir(mode=0o700);(backup/'files').mkdir();(backup/'files.json').write_text('[]')
        (backup/'integrity.json').write_text(json.dumps({'files.json':hashlib.sha256((backup/'files.json').read_bytes()).hexdigest()}))
        support.augment_snapshot(backup,self.m.pending_targets())
        entries=json.loads((backup/'files.json').read_text());self.assertEqual(len(entries),7);self.assertTrue(all(not e['exists'] for e in entries))
        self.m.assert_first_absence();self.calls.clear();self.m.stage_pending()
        self.assertEqual(self.calls,[]);self.assertFalse(self.m.STATE.exists());self.assertFalse(self.m.UNIT.exists());self.assertFalse(self.m.TIMER.exists())
        self.assertTrue(all(not p.exists() for p in (self.m.TOOLS/n for n in self.m.PROGRAMS)))
        upgrade.UPDATES=self.m.PENDING
        self.assertEqual(upgrade.catalogue_pending_helper('1.0.20'),self.m.pending_path('install-windows-phone-catalogue.py'))
        with self.assertRaises(upgrade.RecoveryRequired):upgrade.catalogue_pending_helper('1.0.19')
        self.m.pending_path('windows-phone-catalogue.php').write_bytes(b'changed inert input')
        with self.assertRaises(upgrade.RecoveryRequired):upgrade.catalogue_pending_helper('1.0.20')
        upgrade.restore_files(backup)
        self.assertTrue(all(not p.exists() for p in self.m.pending_targets()))
        self.assertEqual({p.name for p in self.m.PENDING.iterdir()},set())

    def test_pending_bundle_preserves_existing_exact_snapshot_on_rollback(self):
        support=self.load_script('install-support.py');upgrade=self.load_script('upgrade.py');self.m.stage_pending()
        before={p.name:(p.read_bytes(),p.stat().st_mode,p.stat().st_uid,p.stat().st_gid) for p in self.m.pending_targets()}
        backup=self.base/'backup';backup.mkdir(mode=0o700);(backup/'files').mkdir();(backup/'files.json').write_text('[]')
        (backup/'integrity.json').write_text('{}');support.augment_snapshot(backup,self.m.pending_targets())
        self.m.pending_path('VERSION').write_bytes(b'foreign snapshot fixture');upgrade.restore_files(backup)
        after={p.name:(p.read_bytes(),p.stat().st_mode,p.stat().st_uid,p.stat().st_gid) for p in self.m.pending_targets()}
        self.assertEqual(before,after)

    def test_deferred_activation_requires_matching_durable_commit(self):
        self.m.stage_pending();self.calls.clear()
        (self.m.PENDING/'install-journal.json').write_text('{"state":"migrating","version":"1.0.20"}')
        before=self.snapshot()
        with self.assertRaises(ValueError):self.m.install(True,'1.0.20')
        self.assertEqual(before,self.snapshot());self.assertEqual(self.calls,[])
        (self.m.PENDING/'install-journal.json').write_text('{"state":"completed","version":"1.0.20"}')
        self.m.install(True,'1.0.20');self.assertTrue(self.enabled)
        self.assertTrue(all(p.exists() for p in self.m.pending_targets()))

    def test_existing_catalogue_refuses_legacy_first_install_route(self):
        self.m.install();before=self.snapshot();self.calls.clear()
        with self.assertRaises(ValueError):self.m.assert_first_absence()
        self.assertEqual(before,self.snapshot());self.assertEqual(self.calls,[])

    def test_actual_busy_inherited_descriptor_does_not_authorize_another_file(self):
        foreign=self.base/'foreign.lock';foreign.write_bytes(b'foreign')
        with foreign.open('r+b') as f:
            fcntl.flock(f,fcntl.LOCK_EX);os.environ[self.m.LEASE_ENV]=str(f.fileno())
            with self.assertRaises(ValueError):self.m.inherited_fd()

    def test_existing_owned_writer_stops_before_helper_replacement(self):
        self.m.install();self.activate();self.calls.clear();self.m.PACKAGE=self.package
        original=self.m.atomic
        def observe(path,content,mode=0o644):
            self.assertTrue(any(c[1]=='stop' for c in self.calls));self.assertFalse(self.active)
            return original(path,content,mode)
        self.m.atomic=observe;self.m.install();self.assertTrue(self.active)

    def test_writer_still_active_refuses_helper_replacement(self):
        self.m.install();self.activate();self.m.PACKAGE=self.package;before=self.snapshot();self.stuck_writer=True
        with self.assertRaises(ValueError):self.m.install()
        self.assertEqual(before,self.snapshot())
        self.assertTrue(self.active)


if __name__ == '__main__':
    unittest.main()
