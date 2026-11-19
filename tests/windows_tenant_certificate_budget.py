#!/usr/bin/env python3
"""AST-only Windows certificate helper controls, with optional native sentinels.

The native case executes only newly created private PowerShell scripts. It
never imports product environments or accesses certificates, SQL, services,
tasks, DNS, configuration, registration, or default product directories.
"""
import argparse
import ast
from concurrent.futures import ThreadPoolExecutor
import copy
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import shutil
import subprocess
import time
import types

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'packaging/debian/tenant-domains.py'
BACKUPS=ROOT/'packaging/windows/backups.py'
checks=[]

def check(value,label):
    if not value:raise AssertionError(label)
    checks.append(label)

def definitions(path,names):
    tree=ast.parse(path.read_text(encoding='utf-8'))
    nodes=[n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.ClassDef))and n.name in names]
    assert {n.name for n in nodes}==set(names)
    return nodes

WINDOWS,PENDING=(next(n for n in definitions(SOURCE,{'windows','Pending'})if n.name==name)for name in ['windows','Pending'])
ENV=definitions(BACKUPS,{'native_powershell_environment'})[0]

def load(run,*,legacy=False):
    function=copy.deepcopy(WINDOWS)
    if legacy:
        calls=[n for n in ast.walk(function)if isinstance(n,ast.Call)and isinstance(n.func,ast.Attribute)and n.func.attr=='run']
        assert len(calls)==1
        next(k for k in calls[0].keywords if k.arg=='timeout').value=ast.Constant(240)
    scope={'Path':Path,'os':os,'json':json,'subprocess':types.SimpleNamespace(run=run,PIPE=subprocess.PIPE)}
    exec(compile(ast.fix_missing_locations(ast.Module(body=[copy.deepcopy(PENDING),function],type_ignores=[])),str(SOURCE),'exec'),scope)
    return scope['windows'],scope['Pending']

def product_path(value):
    candidate=PureWindowsPath(value)
    return any(candidate.is_relative_to(root)for root in [PureWindowsPath('C:/OpenWebPBX'),PureWindowsPath('C:/ProgramData/OpenWebPBX')])

def portable():
    text=SOURCE.read_text(encoding='utf-8');current="timeout=900 if operation=='Certify' else 240"
    check(text.count(current)==1 and hashlib.sha256(text.replace(current,'timeout=240').encode()).hexdigest()=="cfd38abe197461c491c8a565125c6fbba6979703878b0525c12dc24feebf5792",'all source bytes outside the one approved timeout expression remain exact frozen613')
    for value in ['C:\\OpenWebPBX', 'c:\\OPENWEBPBX\\tools', 'C:/OpenWebPBX/tools', 'C:\\ProgramData\\OpenWebPBX\\state', 'c:\\PROGRAMDATA\\openwebpbx\\state', 'C:/ProgramData/OpenWebPBX/state']:
        check(product_path(value),'actual Windows product default path refused: '+value)
    for value in ['C:\\Windows\\Temp\\openweb-tenant-certificate-budget-owned', 'C:/Windows/Temp/openweb-tenant-certificate-budget-owned', 'C:\\OpenWebPBX-qa\\openweb-tenant-certificate-budget-owned', 'C:\\ProgramData\\OpenWebPBX-qa\\openweb-tenant-certificate-budget-owned']:
        check(not product_path(value),'own TEMP or distinct sibling is not mistaken for a product root: '+value)
    calls=[];environment={'fixture':'exact environment object'}
    backend=types.SimpleNamespace(APP=Path('isolated app'),native_powershell_environment=lambda:environment)
    def success(command,**options):
        calls.append((command,options));return types.SimpleNamespace(returncode=0,stdout=b'{"unchanged":"result"}',stderr=b'')
    windows,pending=load(success)
    operations=['Certify','Prepare','Record','KeyAcl','FilePrivate','FilePublic','DirectoryPrivate','DirectoryPublic','certify','unknown']
    for operation in operations:
        before=len(calls);result=windows(backend,operation,Path('input with spaces.json'));command,options=calls[-1]
        expected=[str(Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'),'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(backend.APP/'tools/Tenant-Domains.ps1'),'-Operation',operation,'-InputFile','input with spaces.json']
        check(command==expected and options=={'stdout':subprocess.PIPE,'stderr':subprocess.PIPE,'env':environment,'timeout':900 if operation=='Certify' else 240}and options['env']is environment and result=={'unchanged':'result'}and len(calls)==before+1,'exact command/env/result/body once: '+operation)
    legacy,_=load(success,legacy=True);legacy(backend,'Certify',Path('input'));check(calls[-1][1]['timeout']==240,'retained legacy helper has original240 deadline')
    for error in [FileNotFoundError('isolated executable'),PermissionError('isolated executable'),subprocess.TimeoutExpired(['isolated'],900)]:
        attempts=[]
        def fail(*args,**kwargs):attempts.append((args,kwargs));raise error
        actual,_=load(fail)
        try:actual(backend,'Certify',Path('input'))
        except BaseException as caught:check(caught is error and len(attempts)==1,'unchanged '+type(error).__name__+' propagates once')
        else:raise AssertionError('Expected original subprocess error')
    for raw,want,seconds in [(b'{"error_category":"certificate_pending","retry_seconds":3600}','certificate_pending',3600),(b'{"error_category":"rate_limited","retry_seconds":123}','rate_limited',123),(b'not json','certificate_pending',3600),(b'{"extra":true}','certificate_pending',3600)]:
        attempts=[]
        def refused(*args,**kwargs):attempts.append((args,kwargs));return types.SimpleNamespace(returncode=7,stdout=b'',stderr=raw)
        actual,problem=load(refused)
        try:actual(backend,'Certify',Path('input'))
        except problem as caught:check((caught.category,caught.seconds)==(want,seconds)and len(attempts)==1,'original refusal/backoff protocol once: '+want+'/'+str(seconds))
        else:raise AssertionError('Expected original helper refusal')
    attempts=[]
    def malformed(*args,**kwargs):attempts.append(1);return types.SimpleNamespace(returncode=0,stdout=b'not json',stderr=b'')
    actual,_=load(malformed)
    try:actual(backend,'Certify',Path('input'))
    except json.JSONDecodeError:check(attempts==[1],'malformed success JSON still refuses without retry')
    else:raise AssertionError('Malformed machine output accepted')

def native_environment():
    scope={'os':os,'Path':Path}
    exec(compile(ast.Module(body=[copy.deepcopy(ENV)],type_ignores=[]),str(BACKUPS),'exec'),scope)
    return scope['native_powershell_environment']()

def native(work):
    check(os.name=='nt','native fixture requires Windows')
    work=work.resolve();check(work.name.startswith('openweb-tenant-certificate-budget-')and not work.exists()and work.parent.is_dir(),'new explicitly owned native work root')
    for ancestor in [work.parent,*work.parent.parents]:
        check(not ancestor.is_symlink()and not(getattr(ancestor.stat(),'st_file_attributes',0)&0x400),'ordinary native ancestor: '+ancestor.name)
    check(not product_path(work),'fixture does not use default product roots')
    work.mkdir(mode=0o700);environment=native_environment();program=Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    quote=lambda value:"'"+str(value).replace("'","''")+"'"
    acl="$ErrorActionPreference='Stop';$p="+quote(work)+";$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544');$acl.SetAccessRuleProtection($true,$false);foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $p -AclObject $acl"
    import base64
    prepared=subprocess.run([str(program),'-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(acl.encode('utf-16le')).decode()],capture_output=True,env=environment,timeout=30)
    check(prepared.returncode==0,'only own new native fixture root receives private ACL')
    script=r'''param([string]$Operation,[string]$InputFile)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSVersion.Major-ne5){throw 'Actual Windows PowerShell5.1 required'}
$value=[IO.File]::ReadAllText($InputFile)|ConvertFrom-Json
[IO.File]::AppendAllText($value.started,"once`n")
if($value.exit_seven){[Console]::Error.Write('{"error_category":"certificate_pending","retry_seconds":3600}');exit 7}
Start-Sleep -Seconds $value.seconds
[IO.File]::WriteAllText($value.completed,'once')
@{not_after='source-only-native-sentinel';operation=$Operation;input_file=$InputFile}|ConvertTo-Json -Compress
exit 0
'''
    cases=[]
    def case(name,seconds,exit_seven=False):
        app=work/(name+' app with spaces');(app/'tools').mkdir(parents=True)
        (app/'tools/Tenant-Domains.ps1').write_text(script,encoding='utf-8')
        request=app/'input with spaces.json';started=app/'started.txt';completed=app/'completed.txt'
        request.write_text(json.dumps({'seconds':seconds,'started':str(started),'completed':str(completed),'exit_seven':exit_seven}),encoding='utf-8')
        cases.append(app);return app,request,started,completed
    old_case=case('legacy',245);new_case=case('current',245)
    def execute(case_data,legacy):
        app,request,started,completed=case_data;calls=[]
        def real(command,**options):calls.append({'timeout':options['timeout'],'argc':len(command)});return subprocess.run(command,**options)
        helper,_=load(real,legacy=legacy);backend=types.SimpleNamespace(APP=app,native_powershell_environment=lambda:environment)
        began=time.monotonic();result=error=None
        try:result=helper(backend,'Certify',request)
        except BaseException as caught:error=caught
        return {'elapsed':time.monotonic()-began,'result':result,'error':error,'calls':calls,'started':started.read_text(encoding='utf-8')if started.exists()else'','completed':completed.exists(),'request':str(request)}
    successful=False
    try:
        with ThreadPoolExecutor(max_workers=2)as executor:
            old_future=executor.submit(execute,old_case,True);new_future=executor.submit(execute,new_case,False)
            old,new=old_future.result(),new_future.result()
        check(isinstance(old['error'],subprocess.TimeoutExpired)and old['error'].timeout==240 and old['calls']==[{'timeout':240,'argc':11}],'real retained240 process expires once')
        check(old['started']=='once\n'and not old['completed']and old['elapsed']>=239,'old native body entered once but could not finish245s')
        check(new['error']is None and new['calls']==[{'timeout':900,'argc':11}]and new['elapsed']>=245,'actual current Certify900 waits for native245s body once')
        check(new['started']=='once\n'and new['completed'],'current native body completes exactly once')
        check(new['result']=={'not_after':'source-only-native-sentinel','operation':'Certify','input_file':new['request']},'real Windows argv with spaces and JSON protocol remain exact')
        app,request,started,completed=case('exit-seven',0,True);calls=[]
        def real(command,**options):calls.append(1);return subprocess.run(command,**options)
        helper,problem=load(real);backend=types.SimpleNamespace(APP=app,native_powershell_environment=lambda:environment)
        try:helper(backend,'Certify',request)
        except problem as caught:check((caught.category,caught.seconds)==('certificate_pending',3600)and calls==[1]and started.read_text()=='once\n'and not completed.exists(),'real native exit7 remains one original refusal/backoff')
        else:raise AssertionError('Native exit7 accepted')
        successful=True
        return {'old_elapsed_seconds':old['elapsed'],'new_elapsed_seconds':new['elapsed'],'parallel_native_delay_seconds':245,'old_declared_timeout':240,'new_declared_timeout':900,'process_bodies_once':True}
    finally:
        if successful:
            for app in cases:shutil.rmtree(app)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--native',action='store_true');parser.add_argument('--work-root',type=Path);args=parser.parse_args()
    portable();result={'passed':True,'portable_controls':len(checks),'source_only':True,'product_environments_imported':False,'default_product_paths_accessed':False,'service_sql_certificate_task_network_changes':False,'source_pins':{str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()for path in [SOURCE,BACKUPS]},'checks':checks.copy()}
    if args.native:
        assert args.work_root;before=len(checks);result['native']=native(args.work_root);result['native_controls']=len(checks)-before;result['checks']=checks.copy();result['private_fixture_app_trees_removed']=True
        (args.work_root/'native-result.safe.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result))

if __name__=='__main__':main()
