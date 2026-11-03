"""Private disposable SYSTEM startup observation. NEVER executes a worker."""
from pathlib import Path
import ctypes, datetime as dt, hashlib, importlib.util, json, os, subprocess, sys, time, traceback
EXPECTED_HELPER = 'a1b032a6ead38af079acb945869845a8f56015823e891dedc2bb22e33e23545e'
STAGES = ('module_import','read_settings','native_psql_readonly_select1','upgrade_open_existing','store_worker_open_existing')
def digest(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def need(value,message):
    if not value: raise ValueError(message)
def system_sid():
    from ctypes import wintypes as w
    adv=ctypes.WinDLL('advapi32',use_last_error=True);kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.GetCurrentProcess.restype=w.HANDLE
    kernel.CloseHandle.argtypes=(w.HANDLE,);kernel.CloseHandle.restype=w.BOOL
    kernel.LocalFree.argtypes=(ctypes.c_void_p,);kernel.LocalFree.restype=ctypes.c_void_p
    adv.OpenProcessToken.argtypes=(w.HANDLE,w.DWORD,ctypes.POINTER(w.HANDLE));adv.OpenProcessToken.restype=w.BOOL
    adv.GetTokenInformation.argtypes=(w.HANDLE,ctypes.c_int,ctypes.c_void_p,w.DWORD,ctypes.POINTER(w.DWORD));adv.GetTokenInformation.restype=w.BOOL
    adv.ConvertSidToStringSidW.argtypes=(ctypes.c_void_p,ctypes.POINTER(w.LPWSTR));adv.ConvertSidToStringSidW.restype=w.BOOL
    token=w.HANDLE();need(adv.OpenProcessToken(kernel.GetCurrentProcess(),8,ctypes.byref(token)),'Token query unavailable')
    try:
        length=w.DWORD();adv.GetTokenInformation(token,1,None,0,ctypes.byref(length));buf=ctypes.create_string_buffer(length.value)
        need(adv.GetTokenInformation(token,1,buf,length,ctypes.byref(length)),'Token identity unavailable')
        pointer=ctypes.cast(buf,ctypes.POINTER(ctypes.c_void_p))[0];out=w.LPWSTR()
        need(adv.ConvertSidToStringSidW(pointer,ctypes.byref(out)),'Token SID unavailable')
        try:return out.value
        finally:kernel.LocalFree(out)
    finally:kernel.CloseHandle(token)
def ordinary(p):
    p=Path(p)
    need(p.is_absolute() and all(not x.is_symlink() and not(x.exists()and getattr(x.lstat(),'st_file_attributes',0)&0x400)for x in [p,*p.parents]),'Ordinary fixed diagnostic paths required')
    return p
def closed_error(error):
    allowed=('BackupError','BackupBusy','OSError','PermissionError','FileNotFoundError','ImportError','ModuleNotFoundError','ValueError','TypeError','RuntimeError','TimeoutExpired','JSONDecodeError')
    selected=None
    for frame in traceback.extract_tb(error.__traceback__):
        if Path(frame.filename).name in ('backups.py','readonly-preamble.py'):selected=frame
    return {'exception_type':type(error).__name__ if type(error).__name__ in allowed else 'other','source_basename':Path(selected.filename).name if selected else 'unknown','source_line':selected.lineno if selected else 0,'native_error':getattr(error,'winerror',None),'hresult':getattr(error,'hresult',None)}
def main():
    os.umask(0o077);context=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
    if context.get('RootAuthorizedReadOnlyOriginalPublic21BaselineDiagnostic')is not True:
        print(json.dumps({'falseAuthorityNoObservation':True}));return
    # The parent enforces actual runner CI/run identity before staging this protected context.
    # Scheduler SYSTEM children do not inherit the runner process environment.
    need(os.name=='nt','Native Windows observation required')
    need(system_sid()=='S-1-5-18','Actual SYSTEM token required')
    root=ordinary(context['privateEvidenceRoot']);need(root.is_dir(),'Preprotected private evidence root required');start=time.monotonic();deadline=start+75
    def save(name,value):
        with (root/name).open('xb')as f:
            raw=value if isinstance(value,bytes)else(json.dumps(value,indent=2)+'\n').encode();f.write(raw);f.flush();os.fsync(f.fileno())
    def budget():need(time.monotonic()<deadline,'Original75s diagnostic body budget expired')
    package=ordinary(context['verifiedPublic21PackageRoot']);manifest=ordinary(package/'release-manifest.json');need(digest(manifest)==context['public21ManifestSHA256'],'Verified immutable public21 manifest changed');m=json.loads(manifest.read_text(encoding='utf-8-sig'));need(m['version']=='1.0.21'and m['files']['backups.py']==EXPECTED_HELPER,'Actual cab93 package required')
    app=Path('C:/OpenWebPBX');helper=ordinary(app/'tools/backups.py');need(digest(helper)==EXPECTED_HELPER,'Actual unchanged public21 helper required')
    for relative,installed in [('backup-runtime/python.exe',Path(sys.executable)),('backup-runtime/python313.zip',Path(sys.executable).parent/'python313.zip'),('Backup-Control.ps1',app/'tools/Backup-Control.ps1'),('CallRecords.Common.ps1',app/'tools/CallRecords.Common.ps1')]:
        need(digest(ordinary(installed))==m['files'][relative]==digest(ordinary(package/relative)),'Original installed runtime/helper binding differs')
    records={};module=None;settings=None
    def observe(stage,body):
        budget();tick=time.monotonic()
        try:
            value=body();budget();records[stage]={'result':'observed','elapsed_ms':int((time.monotonic()-tick)*1000),**(value or{})};return value
        except Exception as error:
            save(stage+'.exception.PRIVATE.json',{'type':type(error).__name__,'message':str(error),'traceback':traceback.format_exc()})
            for label,value in [('stdout',getattr(error,'stdout',None)),('stderr',getattr(error,'stderr',None))]:
                if isinstance(value,bytes):save(stage+'.'+label+'.PARTIAL.PRIVATE.bin',value)
            records[stage]={'result':'error','elapsed_ms':int((time.monotonic()-tick)*1000),**closed_error(error)};return None
    def imported():
        nonlocal module
        spec=importlib.util.spec_from_file_location('immutable_installed_public21_backup_observation',helper);module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
        return {'helper_hash_exact':True}
    observe('module_import',imported)
    def read():
        nonlocal settings
        settings=module.read_settings();return {'read_settings_succeeded':True,'credential_values_never_projected':True}
    if records['module_import']['result']=='observed':observe('read_settings',read)
    else:records['read_settings']={'result':'not_observed_prerequisite_failed'}
    def psql():
        # Same original database_command/environment and query argv. SQL is fixed,
        # explicit READ ONLY; no worker, housekeeping, status or queue operation.
        command=module.database_command(settings)+['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','--single-transaction','-f','-']
        sql=b'SET standard_conforming_strings=on;\nSET TRANSACTION READ ONLY;\nSET LOCAL statement_timeout=15000;\nSELECT 1;\n'
        result=subprocess.run(command,input=sql,env=module.database_environment(settings),capture_output=True,timeout=min(20,max(1,deadline-time.monotonic()-5)))
        save('native-psql.stdout.PRIVATE.bin',result.stdout);save('native-psql.stderr.PRIVATE.bin',result.stderr)
        return {'native_exit_code':result.returncode,'select1_exact':result.returncode==0 and result.stdout.strip()==b'1','read_only_transaction':True}
    if settings is not None:observe('native_psql_readonly_select1',psql)
    else:records['native_psql_readonly_select1']={'result':'not_observed_prerequisite_failed'}
    def opened(path):
        # Product-native DesiredAccess/ShareMode/flags, with OPEN_EXISTING only.
        # NO Create/OpenAlways, WriteFile, LockFileEx, byte padding or mutation.
        from ctypes import wintypes as w
        path=ordinary(path)
        if not path.exists():return {'path_exists':False,'result':'missing_not_created'}
        need(path.is_file() and path.stat().st_nlink==1,'Existing lock must be ordinary single-link file')
        kernel=ctypes.WinDLL('kernel32',use_last_error=True);create=kernel.CreateFileW;create.argtypes=(w.LPCWSTR,w.DWORD,w.DWORD,ctypes.c_void_p,w.DWORD,w.DWORD,w.HANDLE);create.restype=w.HANDLE
        close=kernel.CloseHandle;close.argtypes=(w.HANDLE,);close.restype=w.BOOL
        handle=create(str(path),0xC0000000,0,None,3,0x00200080,None)
        if handle==ctypes.c_void_p(-1).value:
            code=ctypes.get_last_error();return {'path_exists':True,'result':'native_refusal','native_error':code,'sharing_or_byte_lock_code':code in(32,33)}
        try:return {'path_exists':True,'opened_existing_and_closed_without_write_or_byte_lock':True}
        finally:close(handle)
    state=Path(os.environ['ProgramData'])/'OpenWebPBX'
    observe('upgrade_open_existing',lambda:opened(state/'upgrade.lock'))
    observe('store_worker_open_existing',lambda:opened(state/'automatic-backups/worker.lock'))
    need(set(records)==set(STAGES),'Every closed observation stage required')
    # Strict public DTO: raw values/messages/paths/argv stay in private artifacts.
    boolean_fields={'helper_hash_exact','read_settings_succeeded','credential_values_never_projected','select1_exact','read_only_transaction','path_exists','sharing_or_byte_lock_code','opened_existing_and_closed_without_write_or_byte_lock'}
    integer_fields={'elapsed_ms','source_line','native_error','hresult','native_exit_code'}
    text_fields={'result','exception_type','source_basename'}
    results={'observed','error','not_observed_prerequisite_failed','missing_not_created','native_refusal'}
    for stage,row in records.items():
        need(set(row)<=boolean_fields|integer_fields|text_fields,'Unknown closed observation field')
        need(row.get('result')in results,'Unknown closed stage result')
        for key,value in row.items():
            if key in boolean_fields:need(type(value)is bool,'Closed Boolean required')
            elif key in integer_fields:need(value is None or(type(value)is int and -2147483648<=value<=4294967295),'Closed native integer required')
            else:need(type(value)is str and len(value)<=64,'Closed label required')

    budget()  # Never accept final closed success after the original body deadline.
    save('closed-observation.safe.json',{'observation_completed':True,'production_worker_success_claim':False,'old_failure_cause_still_unknown':True,'actual_system':True,'original_helper_a1b_exact':True,'stages':records,'elapsed_seconds':time.monotonic()-start,'only_static_select1_and_existing_file_open_close':True,'worker_secure_status_queue_or_lifecycle_invoked':False})
if __name__=='__main__':main()
