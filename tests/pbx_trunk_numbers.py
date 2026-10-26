"""Run incoming-number controls in a newly created disposable PostgreSQL cluster.

Portable entry: --postgres-bin PATH and --php PATH select installed tools.
Never reads a production connection string, server configuration or credentials.
"""
from pathlib import Path
import argparse
import os
import re
import shutil
import socket
import stat
import subprocess
import tempfile


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
                            error.output=out; error.stderr=err
                    except BaseException:
                        pass
                    raise
        else:
            subprocess.run([*launcher, *map(str, command)], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = os.environ.copy()
    env['OPENWEB_TEST_DSN'] = f'pgsql:host=127.0.0.1;port={port};dbname=postgres'
    started = False
    try:
        prepare_windows_fixture_base(base)
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
