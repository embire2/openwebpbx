"""Prepared native Hash/read-lease/exclusive-lock component; Temp files only."""
from pathlib import Path
import argparse,contextlib,hashlib,importlib.util,json,os,re,shutil,subprocess,sys,tempfile,threading,uuid
BASE=Path(__file__).resolve().parent

def require(value):
    if not value:raise RuntimeError('The exact owned hash-sharing component refused.')

def native_entry(execute):
    require(execute is True and os.name=='nt' and os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted' and os.environ.get('GITHUB_REPOSITORY')=='embire2/openwebpbx')

def sources():
    pins=json.loads((BASE/'source-pins.json').read_text())
    require(pins['source_commit']=='23477de2f295db8b09a7a79228a19184c394de03')
    for name,row in pins['files'].items():
        path=BASE/name;require(path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest()==row['sha256'])
    spec=importlib.util.spec_from_file_location('owned_guard_source_loader',BASE/'windows_backup_guard.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module.load_guard(BASE/'backups.py')

def child_json(command):
    result=subprocess.run(command,capture_output=True,timeout=25)
    require(result.returncode==0 and not result.stderr.strip() and 0<len(result.stdout)<=8192)
    return json.loads(result.stdout.decode('utf-8-sig'))

def hash_result(value,expected=None):
    require(type(value) is dict and type(value.get('schema')) is int and value['schema']==1)
    if value.get('state')=='hashed':
        require(set(value)=={'schema','state','sha256'} and value['sha256']==expected)
    else:
        require(set(value)=={'schema','state','error_type','hresult','win32_code'} and value['state']=='refused' and value['error_type'] in ('IOException','UnauthorizedAccessException','FileNotFoundException','DirectoryNotFoundException','Win32Exception','other','unavailable'))
        if value['error_type']=='unavailable':
            require(value['hresult'] is None and value['win32_code'] is None)
        else:
            require(type(value['hresult']) is int and -(2**31)<=value['hresult']<2**31)
            code=value['win32_code'];require(code is None or type(code) is int and 0<=code<=65535)
            if code is not None and value['error_type']!='Win32Exception':
                require(value['hresult']&0xffff0000==0x80070000 and code==value['hresult']&0xffff)
    return value

@contextlib.contextmanager
def csharp_reader(pwsh,state,children):
    p=subprocess.Popen([str(pwsh),'-NoLogo','-NoProfile','-NonInteractive','-File',str(BASE/'Hold-ReadLease.ps1'),'-StateRoot',str(state)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    children.append(p);ready=[]
    reader=threading.Thread(target=lambda:ready.append(p.stdout.readline(8193)),daemon=True);reader.start();reader.join(20)
    try:
        require(not reader.is_alive() and len(ready)==1 and len(ready[0])<=8192 and json.loads(ready[0])=={'state':'read_lease_held'} and p.poll() is None)
        yield
    finally:
        if p.poll() is None:
            try:p.stdin.write(b'release\n');p.stdin.flush()
            except BrokenPipeError:pass
        try:out,err=p.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill();out,err=p.communicate(timeout=5)
            raise RuntimeError('The exact owned read-lease child exceeded its cleanup deadline.')
        require(p.returncode==0 and not err.strip())

def run(args):
    # Refuse before source reads, path/temp construction or child execution.
    native_entry(args.execute)
    require(args.pwsh.is_absolute() and args.pwsh.is_file() and not args.pwsh.is_symlink())
    require(re.fullmatch('[a-f0-9]{64}',args.pwsh_sha256) and hashlib.sha256(args.pwsh.read_bytes()).hexdigest()==args.pwsh_sha256)
    require(re.fullmatch('[a-f0-9]{64}',args.python_sha256) and hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest()==args.python_sha256)
    guard=sources();fixture=Path(tempfile.gettempdir())/('OpenWebPBX-hash-sharing-'+uuid.uuid4().hex)
    state=fixture/'state'
    paths={'upgrade':state/'upgrade.lock','worker':state/'automatic-backups/worker.lock'}
    original={'upgrade':b'','worker':b'fictional worker lock bytes'}
    rows=[];children=[];primary=None;preserved=False;cleaned=False;created=False
    def observe(case,target,expected_state):
        value=child_json([str(args.pwsh),'-NoLogo','-NoProfile','-NonInteractive','-File',str(BASE/'Hash-Probe.ps1'),'-Fixture',str(fixture),'-Target',target])
        value=hash_result(value,hashlib.sha256(original[target]).hexdigest());rows.append({'case':case,'target':target,'observation':value})
        require(value['state']==expected_state)
        if expected_state=='refused':require(value['error_type']=='IOException' and value['hresult']==-2147024864 and value['win32_code']==32)
    try:
        fixture.mkdir();created=True;state.mkdir();(state/'automatic-backups').mkdir()
        for name,path in paths.items():path.write_bytes(original[name])
        for target in paths:observe('unheld_'+target,target,'hashed')
        with csharp_reader(args.pwsh,state,children):observe('actual_csharp_read_read','upgrade','hashed')
        observe('after_csharp_release','upgrade','hashed')
        for target,path in paths.items():
            with guard.exclusive_guard(path):observe('actual_python_exclusive_'+target,target,'refused')
            observe('after_python_release_'+target,target,'hashed')
        preserved=all(path.read_bytes()==original[name] for name,path in paths.items())
        require(preserved and all(p.poll() is not None for p in children))
    except BaseException as error:primary=error
    finally:
        for p in children:
            try:
                if p.poll() is None:p.kill();p.wait(timeout=5)
            except BaseException as error:
                if primary is None:primary=error
        try:
            require(all(p.poll() is not None for p in children))
            if created:
                require(fixture.is_dir() and not guard.reparse(fixture))
                require(all(not guard.reparse(p) for p in fixture.rglob('*')))
                if not preserved:preserved=all(path.is_file() and path.read_bytes()==original[name] for name,path in paths.items())
                shutil.rmtree(fixture);cleaned=not fixture.exists()
        except BaseException as error:
            if primary is None:primary=error
    report={'schema':1,'state':'passed' if primary is None and cleaned else 'failed','source_commit':'23477de2f295db8b09a7a79228a19184c394de03','actual_native_windows':True,'pwsh_sha256':args.pwsh_sha256,'python_sha256':args.python_sha256,'python_version':'.'.join(str(n) for n in sys.version_info[:3]),'observations':rows,'original_bytes_preserved':preserved,'owned_children_exited':all(p.poll() is not None for p in children),'owned_fixture_removed':cleaned,'historical_failure_cause_proven':False,'installed_source_or_service_changed':False,'backup_control_request_writer_tested':False}
    print(json.dumps(report),flush=True)
    if primary is not None:raise primary

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--execute',action='store_true');parser.add_argument('--pwsh',type=Path,required=True);parser.add_argument('--pwsh-sha256',required=True);parser.add_argument('--python-sha256',required=True)
    run(parser.parse_args())
