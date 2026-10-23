#!/usr/bin/env python3
"""Owned PostgreSQL policy fixture; no live database, PBX, firewall or service."""
from pathlib import Path
import json,os,pwd,shutil,socket,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
def main():
    owner=pwd.getpwnam('postgres');binary=Path('/usr/lib/postgresql/18/bin')
    work=Path(tempfile.mkdtemp(prefix='public-listener-pg-',dir='/var/tmp'));os.chown(work,owner.pw_uid,owner.pw_gid)
    with socket.socket() as probe:probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
    assert port>1024
    name='public_listener_'+os.urandom(8).hex();started=False
    def run(args):return subprocess.run(['runuser','-u','postgres','--',*map(str,args)],capture_output=True,check=True)
    try:
        run([binary/'initdb','-D',work/'data','--auth=trust','--no-locale','--encoding=UTF8'])
        run([binary/'pg_ctl','-D',work/'data','-l',work/'postgres.log','-o',f'-h 127.0.0.1 -p {port} -k {work} -c fsync=off','-w','start']);started=True
        run([binary/'createdb','-h','127.0.0.1','-p',port,name])
        result=subprocess.run(['php',ROOT/'tests/windows_public_listeners.php',f'pgsql:host=127.0.0.1;port={port};dbname={name};user=postgres'],capture_output=True,text=True,timeout=30)
        if result.returncode:raise RuntimeError(result.stderr[-4096:])
        report=json.loads(result.stdout);assert report['state']=='passed' and report['actual_postgresql'] is True
        print(json.dumps(report))
    finally:
        if started:run([binary/'pg_ctl','-D',work/'data','-m','immediate','-w','stop'])
        shutil.rmtree(work)
if __name__=='__main__':main()
