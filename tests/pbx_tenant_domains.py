"""Disposable PostgreSQL runner for actual PHP tenant host boundaries."""
from pathlib import Path
import os,pwd,shutil,socket,subprocess,tempfile
def main():
    root=Path(__file__).resolve().parents[1];base=Path(tempfile.mkdtemp(prefix='openweb-tenant-php-'));pg=Path('/usr/lib/postgresql/18/bin');owner=pwd.getpwnam('postgres');os.chown(base,owner.pw_uid,owner.pw_gid)
    sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close();started=False
    def run(args):return subprocess.run(['runuser','-u','postgres','--',*map(str,args)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        run([pg/'initdb','-D',base/'data','--auth=trust','--no-locale','--encoding=UTF8']);run([pg/'pg_ctl','-D',base/'data','-l',base/'pg.private.log','-o',f'-h 127.0.0.1 -p {port} -k {base} -c fsync=off','-w','start']);started=True
        subprocess.run(['php',str(root/'tests/pbx_tenant_domains.php'),f'pgsql:host=127.0.0.1;port={port};dbname=postgres',str(base/'state')],check=True,timeout=45)
    finally:
        if started:run([pg/'pg_ctl','-D',base/'data','-m','immediate','-w','stop'])
        shutil.rmtree(base)
if __name__=='__main__':main()
