"""Run incoming-number controls in a newly created disposable PostgreSQL cluster.

Portable entry: --postgres-bin PATH and --php PATH select installed tools.
Never reads a production connection string, server configuration or credentials.
"""
from pathlib import Path
import argparse
import base64
import json
import re
import os
import shutil
import socket
import stat
import subprocess
import tempfile


def seal_initdb_failure(error, command):
    # Failure-only, existing native buffers; no native command is repeated.
    if os.name != 'nt' or str(command[0]).replace('\\', '/').lower() != 'c:/openwebpbx/pgsql/bin/initdb.exe':
        return
    if os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx' or os.environ.get('GITHUB_REF') != 'refs/heads/qualification/windows121-did-native-20261026' or os.environ.get('GITHUB_RUN_ATTEMPT') != '1':
        return
    source=os.environ.get('GITHUB_SHA','');run=os.environ.get('GITHUB_RUN_ID','')
    if not re.fullmatch('[a-f0-9]{40}',source) or not re.fullmatch('[1-9][0-9]{0,19}',run):
        return
    out=error.stdout if error.stdout is not None else b'';err=error.stderr if error.stderr is not None else b''
    if type(out)is not bytes or type(err)is not bytes or len(out)+len(err)>1048576 or type(error.returncode)is not int:
        return
    evidence=Path(os.environ['RUNNER_TEMP'])/'did-native-component-evidence'
    if not evidence.is_absolute() or not evidence.is_dir() or evidence.is_symlink():
        return
    payload=json.dumps({'schema':1,'producer':'pbx_trunk_numbers.py','phase':'initdb','native_exit_code':error.returncode,'stdout_base64':base64.b64encode(out).decode('ascii'),'stderr_base64':base64.b64encode(err).decode('ascii')},separators=(',',':')).encode()
    script=Path(__file__).resolve().parent/'windows_did_seal.ps1';pwsh=shutil.which('pwsh')
    if not script.is_file() or not pwsh:
        return
    subprocess.run([pwsh,'-NoProfile','-NonInteractive','-File',str(script),'-Source',source,'-Run',run,'-Output',str(evidence/'native-initdb.sealed.safe.json')],input=payload,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True,timeout=20)


def prepare_windows_fixture_base(base):
    if os.name != 'nt':
        return
    root=Path(tempfile.gettempdir());info=base.lstat()
    if not base.is_absolute() or base.parent!=root or not re.fullmatch(r'openweb-did-[a-z0-9_]{8}',base.name) or not stat.S_ISDIR(info.st_mode) or base.is_symlink() or getattr(info,'st_file_attributes',0)&0x400 or any(base.iterdir()):
        raise ValueError('Only the new ordinary empty owned Windows fixture base is admitted.')
    helper=Path(os.environ['SystemRoot'])/'System32'/'icacls.exe'
    if not helper.is_absolute() or not helper.is_file() or helper.is_symlink() or getattr(helper.lstat(),'st_file_attributes',0)&0x400:
        raise ValueError('Absolute ordinary native ACL helper required.')
    # Append inherited Modify for fixed BuiltinUsers only to this disposable root.
    # Existing owner/admin/SYSTEM rules and all foreign/PBX paths remain untouched.
    subprocess.run([str(helper),str(base),'/grant','*S-1-5-32-545:(OI)(CI)M'],
                   check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)


PHASES = {'before_acl','after_acl','before_initdb','after_initdb','before_pg_start','after_pg_start','before_php66','after_php66','before_pg_stop','after_pg_stop','before_cleanup','after_cleanup'}

def observe_phase(phase):
    # Fixed source/run/phase only. Observation failure never changes execution.
    try:
        source=os.environ.get('GITHUB_SHA','');run=os.environ.get('GITHUB_RUN_ID','')
        if phase not in PHASES or not re.fullmatch('[a-f0-9]{40}',source) or not re.fullmatch('[1-9][0-9]{0,19}',run):
            return
        evidence=Path(os.environ['RUNNER_TEMP'])/'did-native-component-evidence'
        if not evidence.is_absolute() or not evidence.is_dir() or evidence.is_symlink() or getattr(evidence.lstat(),'st_file_attributes',0)&0x400:
            return
        target=evidence/'native-phase.safe.json';temporary=evidence/'native-phase.pending'
        raw=(json.dumps({'schema':1,'source_commit':source,'run_id':run,'phase':phase},separators=(',',':'))+'\n').encode()
        if len(raw)>512:
            return
        descriptor=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        try:
            with os.fdopen(descriptor,'wb')as stream:
                stream.write(raw);stream.flush();os.fsync(stream.fileno())
            os.replace(temporary,target)
        finally:
            if temporary.exists():temporary.unlink()
    except BaseException:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--postgres-bin', type=Path,
                        default=Path(os.getenv('OPENWEB_TEST_POSTGRES_BIN',
                            r'C:\Program Files\PostgreSQL\18\bin' if os.name == 'nt'
                            else '/usr/lib/postgresql/18/bin')))
    parser.add_argument('--php', default=os.getenv('OPENWEB_TEST_PHP', 'php'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    base = Path(tempfile.mkdtemp(prefix='openweb-did-'))
    launcher = []
    if os.name != 'nt' and os.geteuid() == 0:
        import pwd
        owner = pwd.getpwnam('postgres')
        os.chown(base, owner.pw_uid, owner.pw_gid)
        launcher = ['runuser', '-u', 'postgres', '--']
    suffix = '.exe' if os.name == 'nt' else ''
    def pg(name):
        return args.postgres_bin / (name + suffix)
    def run(command):
        captured = os.name != 'nt'
        try:
            if os.name == 'nt':
                # Wait for the original control process, not pipe EOF held by a
                # background child. Both private files stay inside our fixture.
                with tempfile.TemporaryFile(mode='w+b', dir=base) as output, tempfile.TemporaryFile(mode='w+b', dir=base) as errors:
                    try:
                        subprocess.run([*launcher, *map(str, command)], check=True,
                                       stdout=output, stderr=errors, timeout=45)
                    except subprocess.CalledProcessError as error:
                        try:
                            output.seek(0); errors.seek(0)
                            out=output.read(1048577); err=errors.read(1048577)
                            if len(out)+len(err)<=1048576:
                                error.output=out; error.stderr=err; captured=True
                        except BaseException:
                            pass
                        raise
            else:
                subprocess.run([*launcher, *map(str, command)], check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
        except subprocess.CalledProcessError as error:
            if captured:
                try:
                    seal_initdb_failure(error, command)
                except BaseException:
                    pass
            raise
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = os.environ.copy()
    env['OPENWEB_TEST_DSN'] = f'pgsql:host=127.0.0.1;port={port};dbname=postgres'
    started = False
    try:
        observe_phase('before_acl')
        prepare_windows_fixture_base(base)
        observe_phase('after_acl')
        observe_phase('before_initdb')
        run([pg('initdb'), '-D', base / 'data', '--auth=trust', '--username=postgres',
             '--no-locale', '--encoding=UTF8'])
        observe_phase('after_initdb')
        # The private cluster listens only on loopback; no SIP engine exists.
        observe_phase('before_pg_start')
        run([pg('pg_ctl'), '-D', base / 'data', '-l', base / 'postgres.private.log',
             '-o', f'-h 127.0.0.1 -p {port} -c fsync=off', '-w', 'start'])
        observe_phase('after_pg_start')
        started = True
        observe_phase('before_php66')
        subprocess.run([args.php, str(root / 'tests/pbx_trunk_numbers.php')],
                       env=env, check=True, timeout=90)
        observe_phase('after_php66')
    finally:
        if started:
            observe_phase('before_pg_stop')
            run([pg('pg_ctl'), '-D', base / 'data', '-m', 'immediate', '-w', 'stop'])
            observe_phase('after_pg_stop')
        observe_phase('before_cleanup')
        shutil.rmtree(base)
        observe_phase('after_cleanup')


if __name__ == '__main__':
    main()
