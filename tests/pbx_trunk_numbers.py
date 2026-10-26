"""Run incoming-number controls in a newly created disposable PostgreSQL cluster.

Portable entry: --postgres-bin PATH and --php PATH select installed tools.
Never reads a production connection string, server configuration or credentials.
"""
from pathlib import Path
import argparse
import os
import shutil
import socket
import subprocess
import tempfile


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
        subprocess.run([*launcher, *map(str, command)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
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
