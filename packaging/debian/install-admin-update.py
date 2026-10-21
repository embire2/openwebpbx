#!/usr/bin/env python3
"""Install the signed 1.0.19 incoming-routing update on an exact Debian16 web tree."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

PUBLIC_SHA = '650fa7af60af8ab4479e1e7a4fbad4391f0292d8ad321378e9a7ce512e4e987a'
TARGETS = {'ADMIN_VERSION', 'app/pbx_setup/index.php', 'app/pbx_setup/trunk-routes.php',
           'app/pbx_setup/trunk-routes.js', 'resources/classes/pbx_trunk_routes.php',
           'resources/classes/pbx_call_me_back.php'}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(folder):
    public = folder / 'release-public.pem'
    if public.is_symlink() or sha(public) != PUBLIC_SHA:
        raise RuntimeError('Unexpected release signing key.')
    subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public), '-signature',
                    str(folder / 'admin-update-manifest.sig'), str(folder / 'admin-update-manifest.json')],
                   check=True, stdout=subprocess.DEVNULL)
    contract = json.loads((folder / 'admin-update-manifest.json').read_text())
    if contract['schema'] != 1 or contract['version'] != '1.0.19' or contract['base_core'] != '1.0.16':
        raise RuntimeError('Unsupported admin update.')
    if len(contract['files']) != len(TARGETS) or {r['target'] for r in contract['files']} != TARGETS:
        raise RuntimeError('Unexpected update targets.')
    return contract


def plan(folder, web, contract):
    entry = web / 'app/pbx_setup/index.php'
    if not entry.is_file() or any(p.is_symlink() for p in [entry, *entry.parents]):
        raise RuntimeError('Refusing an absent or linked admin entry page.')
    pending = []
    for row in contract['files']:
        target = web / row['target']
        if any(p.is_symlink() for p in [target, *target.parents]):
            raise RuntimeError('Refusing a linked target.')
        before = sha(target) if target.is_file() else None
        matches = [v for v in row['variants'] if before in (v['before_sha256'], v['sha256'])]
        if len(matches) != 1:
            raise RuntimeError('Installed file differs: ' + row['target'] + '. Custom builds require review.')
        variant = matches[0]
        source = folder / variant['source']
        if not source.is_relative_to(folder) or '..' in Path(variant['source']).parts or any(p.is_symlink() for p in [source, *source.parents]) or not source.is_file() or sha(source) != variant['sha256']:
            raise RuntimeError('Payload verification failed.')
        if source.suffix == '.php':
            subprocess.run(['php', '-l', str(source)], check=True, stdout=subprocess.DEVNULL)
        if before != variant['sha256']:
            st = target.stat() if target.exists() else (web / 'app/pbx_setup/index.php').stat()
            pending.append((source, target, before, st))
    return pending


def replace(source, target, st):
    temp = target.with_name(target.name + '.admin119-stage')
    try:
        with temp.open('xb') as stream:
            stream.write(source.read_bytes());stream.flush();os.fsync(stream.fileno())
        os.chmod(temp, st.st_mode & 0o7777);os.chown(temp, st.st_uid, st.st_gid)
        os.replace(temp, target)
    finally:
        if temp.exists():temp.unlink()


def apply(pending, web, recovery):
    recovery.mkdir(parents=True, mode=0o700)
    journal = []
    for source, target, before, st in pending:
        relative = str(target.relative_to(web));backup = recovery / relative
        if before is not None:
            backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700);shutil.copy2(target, backup)
        journal.append({'target': relative, 'before_sha256': before, 'after_sha256': sha(source),
                        'mode': st.st_mode & 0o7777, 'uid': st.st_uid, 'gid': st.st_gid})
    (recovery / 'journal.json').write_text(json.dumps(journal, indent=2))
    changed = []
    try:
        for source, target, before, st in pending:
            if (sha(target) if target.exists() else None) != before:
                raise RuntimeError('An installed file changed during activation.')
            replace(source, target, st);changed.append((target, before, st))
            if sha(target) != sha(source):raise RuntimeError('Installed bytes differ.')
    except BaseException:
        for target, before, st in reversed(changed):
            if before is None:target.unlink()
            else:replace(recovery / target.relative_to(web), target, st)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Apply after exact-file and signature checks.')
    args = parser.parse_args()
    if os.geteuid() != 0:raise RuntimeError('Run as root on the Debian PBX.')
    os.umask(0o077)
    web = Path('/var/www/fusionpbx');folder = Path(__file__).resolve().parent
    info = Path('/etc/os-release').read_text().splitlines()
    if 'ID=debian' not in info or 'VERSION_ID="13"' not in info or (web / 'VERSION').read_text().strip() != '1.0.16':
        raise RuntimeError('This update requires Debian13 with the complete1.0.16 core.')
    contract = verify(folder)
    with Path('/run/openwebpbx-upgrade.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if Path('/var/lib/openwebpbx/updates/maintenance').exists():raise RuntimeError('An upgrade/recovery is in progress.')
        pending = plan(folder, web, contract)
        if not args.apply:print('Verified admin1.0.19 update; pending files:', len(pending));return
        if not pending:print('Admin1.0.19 is already installed.');return
        recovery = Path('/var/lib/openwebpbx/updates/admin119') / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        apply(pending, web, recovery)
        print('Admin1.0.19 installed. Refresh Voice & Chat. Core/Android versions, providers and calls are unchanged.')
        print('Recovery files:', recovery)


if __name__ == '__main__':main()
