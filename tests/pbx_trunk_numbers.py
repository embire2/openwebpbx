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
        try:
            subprocess.run([*launcher, *map(str, command)], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
        except subprocess.CalledProcessError as error:
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
        run([pg('initdb'), '-D', base / 'data', '--auth=trust', '--username=postgres',
             '--no-locale', '--encoding=UTF8'])
        # The private cluster listens only on loopback; no SIP engine exists.
        run([pg('pg_ctl'), '-D', base / 'data', '-l', base / 'postgres.private.log',
             '-o', f'-h 127.0.0.1 -p {port} -c fsync=off', '-w', 'start'])
        started = True
        subprocess.run([args.php, str(root / 'tests/pbx_trunk_numbers.php')],
                       env=env, check=True, timeout=90)
    finally:
        if started:
            run([pg('pg_ctl'), '-D', base / 'data', '-m', 'immediate', '-w', 'stop'])
        shutil.rmtree(base)


if __name__ == '__main__':
    main()
