"""Run the actual restart observer against an owned loopback-only PostgreSQL cluster."""
from pathlib import Path
import json, os, pwd, shutil, socket, subprocess, tempfile


def main():
    source = Path(__file__).resolve().parents[1]
    pg = Path('/usr/lib/postgresql/18/bin')
    owner = pwd.getpwnam('postgres')
    base = Path(tempfile.mkdtemp(prefix='openweb-health-phase-'))
    os.chown(base, owner.pw_uid, owner.pw_gid)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    started = False

    def run(arguments):
        return subprocess.run(['runuser', '-u', 'postgres', '--', *map(str, arguments)],
                              check=True, capture_output=True, timeout=30)
    try:
        run([pg/'initdb', '-D', base/'data', '--auth=trust', '--no-locale', '--encoding=UTF8'])
        run([pg/'pg_ctl', '-D', base/'data', '-l', base/'pg.private.log', '-o',
             f'-h 127.0.0.1 -p {port} -k {base}', '-w', 'start'])
        started = True
        environment = dict(os.environ, OPENWEB_HEALTH_PHASE_TEST_ISOLATED='yes',
                           OPENWEB_HEALTH_PHASE_TEST_DSN=f'pgsql:host=127.0.0.1;port={port};dbname=postgres')
        result = subprocess.run(['php', str(source/'tests/windows_health_restart_phase.php')],
                                env=environment, check=True, capture_output=True, text=True, timeout=40)
        if result.stderr:
            raise RuntimeError('The isolated observer controls emitted stderr.')
        record = json.loads(result.stdout)
        assert record['state'] == 'passed' and record['actual_isolated_postgresql'] is True
        print(json.dumps(record))
    finally:
        if started:
            run([pg/'pg_ctl', '-D', base/'data', '-m', 'immediate', '-w', 'stop'])
        shutil.rmtree(base)


if __name__ == '__main__':
    main()
