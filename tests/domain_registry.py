#!/usr/bin/env python3
"""Actual registry HTTP/PG checks on a brand-new, disposable local cluster."""
from pathlib import Path
import hashlib,json,os,pwd,shutil,socket,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1]
def main():
    if os.geteuid()!=0:raise RuntimeError('The isolated PostgreSQL launcher needs root to select its fixture OS user.')
    binary=Path('/usr/lib/postgresql/18/bin');assert (binary/'initdb').is_file()
    owner=pwd.getpwnam('postgres');temporary=Path(tempfile.mkdtemp(prefix='openweb-registry-check-'));os.chown(temporary,owner.pw_uid,owner.pw_gid)
    database='openweb_registry_check_'+os.urandom(8).hex();sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close();assert port>=20000
    evidence=Path(os.environ.get('OPENWEB_REGISTRY_TEST_EVIDENCE','/tmp/openweb-registry-test-evidence'));evidence.mkdir(mode=0o700,exist_ok=False)
    started=False
    def run(args,**kwargs):return subprocess.run(['runuser','-u','postgres','--',*map(str,args)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kwargs)
    begin=time.monotonic()
    try:
        run([binary/'initdb','-D',temporary/'data','--auth=trust','--no-locale','--encoding=UTF8'])
        run([binary/'pg_ctl','-D',temporary/'data','-l',temporary/'postgres.private.log','-o',f'-h 127.0.0.1 -p {port} -k {temporary} -c fsync=off','-w','start']);started=True
        run([binary/'createdb','-h','127.0.0.1','-p',port,database])
        env=os.environ|{'OPENWEB_REGISTRY_TEST_DATABASE':f'Host=127.0.0.1;Port={port};Database={database};Username=postgres','DOTNET_CLI_TELEMETRY_OPTOUT':'1'}
        fixture=Path('/var/lib/openwebpbx/tenant-domains-20261018/cpanel-parse.original.private.json')
        if fixture.is_file():env['OPENWEB_REGISTRY_CPANEL_PARSE_FIXTURE']=str(fixture)
        with(evidence/'stdout.private').open('wb')as out,(evidence/'stderr.private').open('wb')as err:
            result=subprocess.run(['/opt/dotnet/dotnet','run','--project',str(ROOT/'platform/OpenWebPbx.DomainRegistry.Checks'),'--no-restore'],cwd=ROOT,env=env,stdout=out,stderr=err,timeout=180)
        safe={'exit_code':result.returncode,'elapsed_seconds':round(time.monotonic()-begin,3),'actual_new_private_postgresql_cluster':True,'actual_loopback_http_and_dns_adapter':True,'no_production_database_or_dns_mutation':True,'stdout_sha256':hashlib.sha256((evidence/'stdout.private').read_bytes()).hexdigest(),'stderr_sha256':hashlib.sha256((evidence/'stderr.private').read_bytes()).hexdigest()}
        (evidence/'qualification.safe.json').write_text(json.dumps(safe,indent=2)+'\n')
        if result.returncode:raise RuntimeError('Isolated registry controls failed; original output retained privately.')
        print((evidence/'stdout.private').read_text().strip());print(json.dumps(safe))
    finally:
        if started:run([binary/'pg_ctl','-D',temporary/'data','-m','immediate','-w','stop'])
        shutil.rmtree(temporary)
        for p in evidence.iterdir():p.chmod(0o600)
if __name__=='__main__':main()
