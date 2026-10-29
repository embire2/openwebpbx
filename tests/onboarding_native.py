#!/usr/bin/env python3
"""Run actual .NET onboarding/worker checks in a new isolated PostgreSQL cluster."""
from pathlib import Path
import argparse
import os
import pwd
import shutil
import socket
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dotnet', type=Path, default=Path('/opt/dotnet/dotnet'))
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--packages', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parents[1]
    base = Path(tempfile.mkdtemp(prefix='onboarding-native-pg-'))
    owner = pwd.getpwnam('postgres'); os.chown(base,owner.pw_uid,owner.pw_gid)
    pg = sorted(Path('/usr/lib/postgresql').glob('*/bin/initdb'),key=lambda p:int(p.parts[-3]))[-1].parent
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
    def run(*command):
        return subprocess.run(['runuser','-u','postgres','--',*map(str,command)],capture_output=True,check=True,timeout=45)
    started = False
    try:
        run(pg/'initdb','-D',base/'data','--auth=trust','--no-locale','--encoding=UTF8')
        run(pg/'pg_ctl','-D',base/'data','-l',base/'postgres.private.log','-o',f'-h 127.0.0.1 -p {port} -k {base} -c fsync=off','-w','start'); started=True
        run(pg/'psql','-h','127.0.0.1','-p',port,'-d','postgres','-X','-v','ON_ERROR_STOP=1','-c',
            'create table v_domains(domain_uuid uuid primary key,domain_name text,domain_enabled text);'
            'create table v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean);'
            'create table v_pbx_services(service_uuid uuid primary key,tenant_uuid uuid,domain_uuid uuid);')
        env = os.environ | {'NUGET_PACKAGES':str(args.packages),'OPENWEB_TEST_DATABASE':f'Host=127.0.0.1;Port={port};Database=postgres;Username=postgres'}
        subprocess.run([str(args.dotnet),'build',str(root/'platform/OpenWebPbx.Checks/OpenWebPbx.Checks.csproj'),
                        '--artifacts-path',str(args.artifacts),'-v','minimal'],env=env,cwd=root,check=True,timeout=180)
        assembly=args.artifacts/'bin/OpenWebPbx.Checks/debug/OpenWebPbx.Checks.dll'
        subprocess.run([str(args.dotnet),str(assembly)],env=env,cwd=root,check=True,timeout=120)
    finally:
        if started or (base/'data/postmaster.pid').exists():run(pg/'pg_ctl','-D',base/'data','-m','immediate','-w','stop')
        shutil.rmtree(base)


if __name__ == '__main__':
    main()
