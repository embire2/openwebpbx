#!/usr/bin/env python3
"""Explicit native systemd qualification: UID drop and read-only registration probe."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / 'packaging/debian/openwebpbx-phone-health.service'
PREFIX = Path('/var/lib/openwebpbx/phone-health-20261022/unit-review')
ENTRY = Path('/opt/openwebpbx/tools/phone-health.php')

PROBE = '''import importlib.util,json,subprocess,sys
from pathlib import Path
s=importlib.util.spec_from_file_location('owned_health',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.ENTRY=Path(sys.argv[2]);m.protected(m.ENTRY)
code="""$s=file_get_contents('/proc/self/status');echo json_encode(['dropped'=>posix_geteuid()===33,'gid33'=>posix_getegid()===33,'groups_empty'=>posix_getgroups()===[],'nnp'=>preg_match('/^NoNewPrivs:\\\\s+1$/m',$s)===1,'caps_zero'=>preg_match('/^CapEff:\\\\s+0+$/m',$s)===1,'cannot_regain_root'=>!@posix_setuid(0)]);"""
facts={}
try:
 p=subprocess.run(['/usr/bin/php','-d','display_errors=0','-d','log_errors=0','-r',code],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,preexec_fn=m.unprivileged_child)
 facts={'drop_process_returncode':p.returncode,'drop_stderr_empty':not bool(p.stderr),'privilege_drop':json.loads(p.stdout)}
except Exception as e:facts['privilege_drop']={'dropped':False,'error_class':type(e).__name__}
if facts['privilege_drop'].get('dropped'):
 p=subprocess.run(['/usr/bin/php','-d','display_errors=0','-d','log_errors=0',str(m.ENTRY),'registrations'],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=7,preexec_fn=m.unprivileged_child)
 try:v=json.loads(p.stdout);valid=isinstance(v,dict)and isinstance(v.get('row_count'),int)
 except Exception:valid=False
 facts['read_only_native']={'returncode':p.returncode,'bounded':0<len(p.stdout)<=4194304,'shape_valid':valid,'stderr_empty':not bool(p.stderr)}
print(json.dumps(facts))
'''


def properties():
    result = {}
    active = False
    for line in UNIT.read_text().splitlines():
        if line.startswith('['):
            active = line == '[Service]'
        elif active and line and not line.startswith('#'):
            name, value = line.split('=', 1)
            if name != 'ExecStart':
                result[name] = value
    return result


def run_case(folder, stage, label, settings):
    output = folder / (label + '.safe.json')
    command = ['systemd-run', '--quiet', '--wait', '--collect',
               '--unit=openwebpbx-health-native-' + folder.name[-12:] + '-' + label]
    for name, value in settings.items():
        command.extend(['-p', name + '=' + value])
    command.extend(['-p', 'StandardOutput=append:' + str(output), '-p',
                    'StandardError=append:' + str(folder / (label + '.private.stderr')),
                    '/usr/bin/python3', '-I', '-B', str(folder / 'probe.py'),
                    str(stage / 'phone-health.py'), str(stage / 'phone-health.php')])
    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=35)
    if process.returncode != 0:
        raise RuntimeError('Native read-only diagnostic unit failed; keep private evidence.')
    return json.loads(output.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-read-only', action='store_true', required=True)
    args = parser.parse_args()
    if os.geteuid() != 0 or not Path('/run/systemd/system').is_dir() or not ENTRY.is_file():
        parser.error('An explicitly selected installed Debian systemd test host is required.')
    os.umask(0o077)
    PREFIX.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder = Path(tempfile.mkdtemp(prefix='native-', dir=PREFIX))
    (folder / 'probe.py').write_text(PROBE)
    (folder / 'probe.py').chmod(0o600)
    actual = properties()
    baseline = dict(actual, NoNewPrivileges='true')
    stage = Path(tempfile.mkdtemp(prefix='openwebpbx-health-qa-', dir='/run'))
    stage.chmod(0o755)
    manifest = {}
    try:
        for name in ('phone-health.py', 'phone-health.php'):
            content = (ROOT / 'packaging/debian' / name).read_bytes()
            (stage / name).write_bytes(content)
            (stage / name).chmod(0o644)
            manifest[name] = hashlib.sha256(content).hexdigest()
        old = run_case(folder, stage, 'old', baseline)
        fixed = run_case(folder, stage, 'fixed', actual)
        if not all(fixed['privilege_drop'].get(key) is True for key in
                   ('dropped', 'gid33', 'groups_empty', 'nnp', 'caps_zero', 'cannot_regain_root')):
            raise RuntimeError('The candidate child does not retain its required private sandbox.')
        native = fixed.get('read_only_native', {})
        if not (native.get('returncode') == 0 and native.get('shape_valid') and native.get('bounded') and native.get('stderr_empty')):
            raise RuntimeError('The candidate sandbox cannot read current native registrations.')
    finally:
        # Only the exact two owned source copies may be removed. Keep changed or
        # unexpected files for review instead of broad temporary-tree deletion.
        if set(path.name for path in stage.iterdir()) != set(manifest):
            raise RuntimeError('Native diagnostic cleanup needs review.')
        for name, digest in manifest.items():
            path = stage / name
            if path.is_symlink() or path.stat().st_uid != 0 or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise RuntimeError('Native diagnostic source changed; retained for review.')
        for name in manifest:
            (stage / name).unlink()
        stage.rmdir()
    receipt = {'at': time.time(), 'unit_sha256': hashlib.sha256(UNIT.read_bytes()).hexdigest(),
               'candidate_uid_drop_and_read_only_native_pass': True,
               'old_nnp_privilege_drop_refused': old['privilege_drop'].get('dropped') is False,
               'old_error_class': old['privilege_drop'].get('error_class'),
               'child_uid33_gid33_empty_groups_nnp1_caps0_cannot_regain_root': True,
               'source_helper_hashes': manifest,
               'source_unit_properties_used': True, 'health_monitor_executed': False,
               'customer_mail_unblocks_calls': False, 'evidence': str(folder)}
    (folder / 'qualification.safe.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()
