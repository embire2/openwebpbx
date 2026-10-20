#!/usr/bin/env python3
"""Apply the reviewed Debian16 feed compatibility files; preserve server/calling data."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Apply after all exact-file checks pass.')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError('Run as root on the Debian PBX.')
    folder = Path(__file__).resolve().parent
    manifest = folder / 'feed-compat-manifest.json'
    public = folder / 'release-public.pem'
    if digest(public) != '650fa7af60af8ab4479e1e7a4fbad4391f0292d8ad321378e9a7ce512e4e987a':
        raise RuntimeError('The compatibility signing key differs.')
    subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public), '-signature', str(folder / 'feed-compat-manifest.sig'), str(manifest)], check=True, stdout=subprocess.DEVNULL)
    contract = json.loads(manifest.read_text())
    if contract['schema'] != 1 or contract['core_version'] != '1.0.16':
        raise RuntimeError('Unsupported compatibility contract.')
    if Path('/var/www/fusionpbx/VERSION').read_text().strip() != '1.0.16':
        raise RuntimeError('This compatibility patch is only for the original Debian1.0.16 updater.')
    os_info = Path('/etc/os-release').read_text().splitlines()
    if 'ID=debian' not in os_info or 'VERSION_ID="13"' not in os_info:
        raise RuntimeError('This compatibility patch requires Debian13.')
    allowed = {
        '/opt/openwebpbx/updater/current/OpenWebPbx.Updater.dll',
        '/opt/openwebpbx/updater/current/OpenWebPbx.Updater.pdb',
        '/var/www/fusionpbx/resources/classes/pbx_updates.php',
    }
    if {row['target'] for row in contract['files']} != allowed or len(contract['files']) != len(allowed):
        raise RuntimeError('Unexpected compatibility targets.')
    with Path('/run/openwebpbx-upgrade.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if Path('/var/lib/openwebpbx/updates/maintenance').exists():
            raise RuntimeError('An upgrade or recovery is in progress.')
        pending = []
        for row in contract['files']:
            target = Path(row['target'])
            source = folder / row['source']
            if not source.is_relative_to(folder) or '..' in Path(row['source']).parts or source.is_symlink() or not source.is_file():
                raise RuntimeError('Unsafe compatibility payload.')
            if digest(source) != row['sha256']:
                raise RuntimeError('Compatibility payload verification failed.')
            if target.is_symlink() or not target.is_file():
                raise RuntimeError('Unexpected installed compatibility target.')
            current = digest(target)
            if current == row['sha256']:
                continue
            if current != row['before_sha256']:
                raise RuntimeError('Installed files differ; custom or other-version installations require review.')
            pending.append((source, target, target.stat()))
        if not args.apply:
            print('Compatibility preflight passed; pending files:', len(pending))
            return
        if not pending:
            print('The Debian update feed compatibility patch is already installed.')
            return
        service = 'openwebpbx-updater'
        subprocess.run(['systemctl', 'is-active', '--quiet', service], check=True)
        recovery = Path('/var/lib/openwebpbx/updates/feed-compat118') / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        recovery.mkdir(parents=True, mode=0o700)
        shutil.copy2(manifest, recovery / manifest.name)
        for _, target, _ in pending:
            shutil.copy2(target, recovery / target.name)
        subprocess.run(['systemctl', 'stop', service], check=True)
        changed = []
        def replace(source, target, stat):
            temp = target.with_name(target.name + '.feed-compat118.tmp')
            try:
                with temp.open('xb') as stream:
                    stream.write(source.read_bytes())
                    stream.flush()
                    os.fsync(stream.fileno())
                os.chmod(temp, stat.st_mode & 0o7777)
                os.chown(temp, stat.st_uid, stat.st_gid)
                os.replace(temp, target)
            finally:
                temp.unlink(missing_ok=True)
        try:
            for source, target, stat in pending:
                replace(source, target, stat)
                changed.append((target, stat))
            subprocess.run(['php', '-l', '/var/www/fusionpbx/resources/classes/pbx_updates.php'], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['systemctl', 'start', service], check=True)
            subprocess.run(['systemctl', 'is-active', '--quiet', service], check=True)
        except BaseException:
            subprocess.run(['systemctl', 'stop', service], check=False)
            for target, stat in reversed(changed):
                replace(recovery / target.name, target, stat)
            subprocess.run(['systemctl', 'start', service], check=True)
            raise
        print('Debian feed compatibility installed. Core remains1.0.16; SIP services and phone settings were untouched.')


if __name__ == '__main__':
    main()
