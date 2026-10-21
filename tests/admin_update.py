#!/usr/bin/env python3
"""Exercise the signed admin package against owned real-filesystem web trees."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from unittest.mock import patch

parser = argparse.ArgumentParser()
parser.add_argument('--package', type=Path, required=True)
args = parser.parse_args()
spec = importlib.util.spec_from_file_location('admin_update', args.package / 'install-admin-update.py')
m = importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
contract = m.verify(args.package)
checks = 0


def ok(value, message):
    global checks
    if not value:raise AssertionError(message)
    checks += 1


def refuses(fn):
    try:fn()
    except (RuntimeError, subprocess.CalledProcessError):return True
    return False


def fixture(folder, variant):
    folder.mkdir()
    for target in ['app/pbx_setup/index.php', 'resources/classes/pbx_call_me_back.php']:
        p = folder / target;p.parent.mkdir(parents=True, exist_ok=True)
        baseline = args.package / ('baselines/' + variant + '/index.php' if target.endswith('index.php') else 'baselines/pbx_call_me_back.php')
        p.write_bytes(baseline.read_bytes())
        p.chmod(0o644)
    (folder / 'VERSION').write_text('1.0.16\n')


with tempfile.TemporaryDirectory(prefix='openweb-admin119-') as temp:
    base = Path(temp)
    for variant in ['stock16', 'hosted16']:
        web = base / variant;fixture(web, variant)
        plan = m.plan(args.package, web, contract)
        ok(len(plan) == 6, 'Full preflight missing targets')
        originals = {str(p.relative_to(web)): (p.read_bytes(), p.stat().st_mode, p.stat().st_uid, p.stat().st_gid) for p in web.rglob('*') if p.is_file()}
        replace = m.replace
        counter = [0]

        def fail_once(source, target, st):
            counter[0] += 1
            if counter[0] == 4:raise RuntimeError('Owned fixture failure after three writes')
            return replace(source, target, st)

        with patch.object(m, 'replace', fail_once):
            ok(refuses(lambda: m.apply(plan, web, base / (variant + '-recovery-failure'))), 'Fault did not stop apply')
        current = {str(p.relative_to(web)): (p.read_bytes(), p.stat().st_mode, p.stat().st_uid, p.stat().st_gid) for p in web.rglob('*') if p.is_file()}
        ok(current == originals, 'Partial failure did not recover exact originals')
        m.apply(m.plan(args.package, web, contract), web, base / (variant + '-recovery-success'))
        ok(m.plan(args.package, web, contract) == [], 'Second application not idempotent')
        ok((web / 'VERSION').read_text() == '1.0.16\n', 'Full core version changed')
        ok((web / 'ADMIN_VERSION').read_text().strip() == '1.0.19', 'Admin version missing')
        ok(all((p.stat().st_mode & 0o777) == 0o644 for p in web.rglob('*') if p.is_file() and p.name != 'VERSION'), 'Installed file modes differ')
        target = web / 'app/pbx_setup/index.php';target.write_bytes(target.read_bytes() + b'\n<!-- custom -->')
        ok(refuses(lambda: m.plan(args.package, web, contract)), 'Custom installed input accepted')
    damaged = base / 'damaged';shutil.copytree(args.package, damaged)
    (damaged / 'admin-update-manifest.json').write_text('{}')
    ok(refuses(lambda: m.verify(damaged)), 'Invalid signed metadata accepted')
    shutil.rmtree(damaged);shutil.copytree(args.package, damaged)
    (damaged / 'release-public.pem').write_text('foreign key')
    ok(refuses(lambda: m.verify(damaged)), 'Foreign signing key accepted')
    shutil.rmtree(damaged);shutil.copytree(args.package, damaged)
    payload = damaged / contract['files'][0]['variants'][0]['source'];payload.write_bytes(payload.read_bytes() + b'bad')
    web = base / 'tamper';fixture(web, 'stock16')
    ok(refuses(lambda: m.plan(damaged, web, contract)), 'Tampered payload accepted')
    p = web / 'app/pbx_setup/index.php';p.unlink();p.symlink_to(base / 'foreign')
    ok(refuses(lambda: m.plan(args.package, web, contract)), 'Linked target accepted')
print(json.dumps({'checks': checks, 'stock_and_hosted16': True, 'exact_partial_failure_recovery': True, 'idempotent': True}))
