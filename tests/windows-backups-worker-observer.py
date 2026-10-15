"""Disposable hosted-runner observation of the unmodified installed backup worker.

No arguments, SQL, paths, key material or raw child output enter the report.
The task lease changes only Arguments and restores the original action exactly.
"""
import ctypes
from contextlib import contextmanager
import hashlib
import importlib.util
import ipaddress
import json
import ntpath
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import uuid

TOOLS={'psql','pg_dump','pg_restore','ssh-keygen','sftp','powershell','unknown'}
PHASES={'before_upload','upload','after_upload'}
CLASSES={'database_invalid_encoding','database_client_encoding','database_permission','database_connection',
    'database_syntax','ssh_private_key_permissions','ssh_private_key_format','ssh_private_key_unreadable',
    'ssh_host_key','ssh_authentication','ssh_connection','ssh_remote_path','unknown'}
ERRORS={'BackupError','TimeoutExpired','OSError','FileNotFoundError','PermissionError','UnicodeDecodeError','unknown'}
RECOVERY_ERRORS=ERRORS|{'AssertionError','RuntimeError','NameError','TypeError','AttributeError','ValueError','KeyError','IndexError','JSONDecodeError'}
OPERATIONS={'secure','plan','hold','hold-selection','start-web','recover-startup','resume-factory','activate','acl-read','acl-restore','none','unknown'}
RECOVERY_CLASSES=CLASSES|{'shell_command_not_found','shell_permission','shell_parameter_binding','shell_path','shell_invalid_operation',
    'control_path_boundary','control_permission_class','control_startup_snapshot','control_stop_timeout','control_start_timeout','control_request','control_acl_snapshot'}
ACL_CATEGORIES={'config','template_key','runtime','installation','phone_tls_metadata','phone_tls_material','public_access_source',
    'notifications','legacy_push','freeswitch_config','voicemail','recordings','other_owned'}
ACL_BOOLEANS={'before_null','after_null','raw_binary_equal','ace_sequence_equal','ace_set_equal','ace_multiset_equal',
    'ace_multiplicity_equal','all_ordinary_allow_before','all_ordinary_allow_after'}
DESCRIPTOR_BOOLEANS={'strict_sddl_equal','descriptor_binary_equal','owner_equal','group_equal',
    'owner_before_null','owner_after_null','group_before_null','group_after_null'}


def projected_acl(record):
    if (not isinstance(record,dict) or type(record.get('schema')) is not int or record['schema']!=1 or
        record.get('report_status') not in {'read','unavailable','refused'} or not isinstance(record.get('mismatches'),list) or len(record['mismatches'])>3):raise ValueError()
    safe={'schema':1,'report_status':record['report_status'],'mismatches':[]}
    for item in record['mismatches']:
        if not isinstance(item,dict) or not isinstance(item.get('file_category'),str) or item['file_category'] not in ACL_CATEGORIES:raise ValueError()
        entry={'file_category':item['file_category']}
        for key in DESCRIPTOR_BOOLEANS:
            if type(item.get(key)) is not bool:raise ValueError()
            entry[key]=item[key]
        for key,maximum in [('control_flags_before',65535),('control_flags_after',65535),('control_flags_xor',65535),
            ('descriptor_revision_before',255),('descriptor_revision_after',255),('resource_manager_control_before',255),('resource_manager_control_after',255)]:
            if type(item.get(key)) is not int or not 0<=item[key]<=maximum:raise ValueError()
            entry[key]=item[key]
        for label in ('dacl','sacl'):
            acl=item.get(label)
            if not isinstance(acl,dict):raise ValueError()
            value={}
            for key in ACL_BOOLEANS:
                if type(acl.get(key)) is not bool:raise ValueError()
                value[key]=acl[key]
            for side in ('before','after'):
                revision=acl.get('revision_'+side)
                if revision is not None and (type(revision) is not int or not 0<=revision<=255):raise ValueError()
                value['revision_'+side]=revision
                for prefix in ('size_','count_','unique_ace_count_','duplicate_ace_count_'):
                    key=prefix+side
                    if type(acl.get(key)) is not int or not 0<=acl[key]<=65535:raise ValueError()
                    value[key]=acl[key]
            entry[label]=value
        safe['mismatches'].append(entry)
    return safe


def acl_category(module,name):
    path=ntpath.normcase(ntpath.normpath(name))
    exact={ntpath.normcase(ntpath.normpath(str(value))):label for value,label in (
        (module.CONFIG,'config'),(module.KEY,'template_key'),(module.STATE/'runtime.json','runtime'),
        (module.STATE/'installation.json','installation'),(module.STATE/'phone-tls.json','phone_tls_metadata'))}
    if path in exact:return exact[path]
    roots=[(module.ROOTS.get(key),label) for key,label in (
        ('phone-tls','phone_tls_material'),('mobile-notifications','notifications'),('mobile-push','legacy_push'),
        ('mobile-push-settings','legacy_push'),('freeswitch-config','freeswitch_config'))]
    roots.extend([(module.STATE/'restored-source/public-access','public_access_source'),
        (module.STATE/'storage/voicemail','voicemail'),(module.STATE/'storage/recordings','recordings')])
    for root,label in roots:
        if root is not None:
            parent=ntpath.normcase(ntpath.normpath(str(root)))
            if path==parent or path.startswith(parent+'\\'):return label
    return 'other_owned'


def closed_stderr(tool,raw):
    if not isinstance(raw,bytes) or len(raw)>262144:return 'unknown'
    text=raw.decode('utf-8',errors='replace')
    if tool=='psql':
        for pattern,category in (
            (r'invalid byte sequence for encoding "[A-Za-z0-9_-]+"|has no equivalent in encoding "[A-Za-z0-9_-]+"','database_invalid_encoding'),
            (r'invalid (?:value for parameter "client_encoding"|client encoding)','database_client_encoding'),
            (r'ERROR:\s+permission denied','database_permission'),
            (r'connection to server .* failed:|could not connect to server:','database_connection'),
            (r'ERROR:\s+syntax error at or near','database_syntax')):
            if re.search(pattern,text):return category
    if tool in {'ssh-keygen','sftp'}:
        for pattern,category in (
            (r'WARNING: UNPROTECTED PRIVATE KEY FILE!|Permissions .+ are too open\.|Load key .+: bad permissions','ssh_private_key_permissions'),
            (r'Load key .+: (?:invalid format|error in libcrypto)|is not a key file\.','ssh_private_key_format'),
            (r'Identity file .+ not accessible:|Load key .+: (?:No such file or directory|Permission denied)','ssh_private_key_unreadable'),
            (r'REMOTE HOST IDENTIFICATION HAS CHANGED!|Host key verification failed\.|No .+ host key is known for .+ and you have requested strict checking','ssh_host_key'),
            (r'Permission denied \((?:publickey|password|keyboard-interactive)(?:,(?:publickey|password|keyboard-interactive))*\)\.?','ssh_authentication'),
            (r'(?:dest open|remote open|stat remote|realpath|rename|Couldn.t stat remote file).+(?:No such file or directory|Permission denied|Failure)','ssh_remote_path'),
            (r'connect to host .+ port [0-9]+: (?:Connection refused|Connection timed out|No route to host|Network is unreachable|Connection reset)|Connection closed','ssh_connection')):
            if re.search(pattern,text):return category
    return 'unknown'


def tool_name(command,tools):
    try:
        if not isinstance(command,(list,tuple)) or not command or not isinstance(command[0],(str,os.PathLike)):return 'unknown'
        return tools.get(ntpath.normcase(ntpath.normpath(str(command[0]))),'unknown')
    except BaseException:return 'unknown'


class WorkerObservation:
    def __init__(self,module,report):
        self.module=module;self.report=report;self.phase='before_upload';self.events=[];self.truncated=False;self.classify=closed_stderr;self.details=lambda tool,raw:{}
        self.tools={ntpath.normcase(ntpath.normpath(module.tool(name))):name for name in TOOLS-{'powershell','unknown'}}
        powershell=str(Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe')
        self.tools[ntpath.normcase(ntpath.normpath(powershell))]='powershell'
    def record(self,event):
        try:
            if len(self.events)==8:self.truncated=True
            else:self.events.append(event|{'phase':self.phase})
            value={'schema':1,'events':self.events,'truncated':self.truncated}
            temporary=self.report.with_name('.worker-observer-'+uuid.uuid4().hex+'.tmp')
            try:
                with temporary.open('x',encoding='utf-8',newline='\n') as stream:
                    json.dump(value,stream,separators=(',',':'));stream.flush();os.fsync(stream.fileno())
                os.replace(temporary,self.report)
            finally:temporary.unlink(missing_ok=True)
        except BaseException:pass
    def install(self):
        original_run=self.module.run;original_upload=self.module.upload_sftp;real_subprocess=self.module.subprocess;observer=self
        def emit(event):
            try:observer.record(event)
            except BaseException:pass
        class Subprocess:
            def __getattr__(self,name):return getattr(real_subprocess,name)
            def run(self,command,*arguments,**keywords):
                tool=tool_name(command,observer.tools)
                try:result=real_subprocess.run(command,*arguments,**keywords)
                except BaseException as error:
                    emit({'event':'tool_failure','tool':tool,'failure_class':'unknown','error_type':type(error).__name__ if type(error).__name__ in ERRORS else 'unknown'})
                    raise
                try:
                    if type(result.returncode) is int and result.returncode!=0:
                        event={'event':'tool_failure','tool':tool,'failure_class':observer.classify(tool,result.stderr)}
                        if -(2**31)<=result.returncode<2**32:
                            event['returncode']=result.returncode if result.returncode<2**31 else result.returncode-2**32
                        try:event.update(observer.details(tool,result.stderr))
                        except BaseException:pass
                        emit(event)
                except BaseException:pass
                return result
        def run(command,*arguments,**keywords):
            try:return original_run(command,*arguments,**keywords)
            except BaseException as error:
                emit({'event':'run_failure','tool':tool_name(command,observer.tools),'error_type':type(error).__name__ if type(error).__name__ in ERRORS else 'unknown'})
                raise
        def upload(*arguments,**keywords):
            observer.phase='upload'
            try:return original_upload(*arguments,**keywords)
            except BaseException as error:
                emit({'event':'upload_failure','error_type':type(error).__name__ if type(error).__name__ in ERRORS else 'unknown'})
                raise
            finally:observer.phase='after_upload'
        self.module.subprocess=Subprocess();self.module.run=run;self.module.upload_sftp=upload


class LocalQueryObservation(WorkerObservation):
    """Observe local query failures independently of the separate SYSTEM worker."""
    def __init__(self,module,report):
        super().__init__(module,report);self.phase='local_query';self.active=False;self.originals={};self.wrappers_restored=False
    def record(self,event):
        if self.active:super().record(event)
    def __enter__(self):
        self.originals={name:getattr(self.module,name) for name in ('run','subprocess','upload_sftp','query')}
        try:
            super().install();original=self.originals['query'];observer=self
            def query(*arguments,**keywords):
                previous=observer.active;observer.active=True
                try:return original(*arguments,**keywords)
                except BaseException as error:
                    try:observer.record({'event':'query_failure','error_type':type(error).__name__ if type(error).__name__ in ERRORS else 'unknown'})
                    except BaseException:pass
                    raise
                finally:observer.active=previous
            self.module.query=query
        except BaseException:
            self.__exit__(*sys.exc_info());raise
        return self
    def __exit__(self,kind,error,trace):
        try:
            for name,value in self.originals.items():setattr(self.module,name,value)
            self.wrappers_restored=all(getattr(self.module,name) is value for name,value in self.originals.items())
        except BaseException:
            if error is None:raise
        return False
    def safe_report(self):
        events=[]
        for event in self.events[:8]:
            if event.get('phase')!='local_query' or event.get('event') not in {'tool_failure','run_failure','query_failure'}:continue
            value={'event':event['event']}
            for key,choices in [('tool',TOOLS),('failure_class',CLASSES),('error_type',ERRORS)]:
                if isinstance(event.get(key),str) and event[key] in choices:value[key]=event[key]
            if type(event.get('returncode')) is int and -(2**31)<=event['returncode']<2**31:value['returncode']=event['returncode']
            events.append(value)
        return {'schema':1,'wrappers_restored':self.wrappers_restored,'events':events,'truncated':self.truncated}


def recovery_error(error):
    frames=[];trace=error.__traceback__
    while trace is not None:
        name=Path(trace.tb_frame.f_code.co_filename).name
        if name in {'backups.py','windows_backups_native.py'} and 0<trace.tb_lineno<=20000:
            frames.append({'source_basename':name,'source_line':trace.tb_lineno})
        trace=trace.tb_next
    return {'error_type':type(error).__name__ if type(error).__name__ in RECOVERY_ERRORS else 'unknown','source_frames':frames[-8:]}


def recovery_stderr(tool,raw):
    category=closed_stderr(tool,raw)
    if category!='unknown' or tool!='powershell' or not isinstance(raw,bytes) or len(raw)>262144:return category
    text=raw.decode('utf-8',errors='replace')
    messages={
        'A backup path is outside the owned private locations.':'control_path_boundary',
        'Backup paths must not contain links or junctions.':'control_path_boundary',
        'An unknown backup permission class was requested.':'control_permission_class',
        'The factory startup snapshot is invalid.':'control_startup_snapshot',
        'The factory service startup snapshot is invalid.':'control_startup_snapshot',
        'The factory running-service snapshot is invalid.':'control_startup_snapshot',
        'The factory web/task snapshot is invalid.':'control_startup_snapshot',
        'The certificate-task snapshot is invalid.':'control_startup_snapshot',
        'The additional-task snapshot is invalid.':'control_startup_snapshot',
        'The PBX application pool did not stop.':'control_stop_timeout',
        'The PBX application pool did not start.':'control_start_timeout',
        'A backup control request is invalid.':'control_request',
        'A factory private-data permission snapshot is invalid.':'control_acl_snapshot'}
    matched={category for message,category in messages.items()
             if re.search(r'(?m)^\s*(?:\+?\s*FullyQualifiedErrorId\s*:\s*)?'+re.escape(message)+r'\s*$',text)}
    if len(matched)==1:return matched.pop()
    if matched:return 'unknown'
    for pattern,category in (
        (r'\bCommandNotFoundException\b','shell_command_not_found'),
        (r'\b(?:UnauthorizedAccessException|PSSecurityException|SecurityException)\b','shell_permission'),
        (r'\bParameterBinding(?:Validation)?Exception\b','shell_parameter_binding'),
        (r'\b(?:FileNotFoundException|DirectoryNotFoundException|ItemNotFoundException|PathNotFound)\b','shell_path'),
        (r'\bInvalidOperationException\b','shell_invalid_operation')):
        if re.search(pattern,text):return category
    return 'unknown'


def recovery_position(tool,raw):
    if tool!='powershell' or not isinstance(raw,bytes) or len(raw)>262144:return {}
    positions=set()
    for line in raw.decode('utf-8',errors='replace').splitlines():
        if len(line)>2048:continue
        match=re.fullmatch(r'\s*At [^\r\n]*[\\/]Backup-Control\.ps1:([1-9][0-9]{0,4}) char:[1-9][0-9]{0,5}\s*',line)
        if match and 1<=int(match[1])<=20000:positions.add(int(match[1]))
    if len(positions)!=1:return {}
    return {'native_source_basename':'Backup-Control.ps1','native_source_line':positions.pop()}


class RecoveryObservation(WorkerObservation):
    """Local harness call only; every original function/outcome is retained."""
    def __init__(self,module,report,injected):
        super().__init__(module,report);self.phase='restore';self.operation='none';self.injected=injected
        self.classify=recovery_stderr;self.details=recovery_position;self.recover_called=False;self.wrappers_restored=False
        self.original_error=None;self.recovery_error=None;self.reported_error=None;self.originals={}
        self.acl_observation=None;self.acl_checks_restored=False
    def record(self,event):
        super().record(event|{'operation':self.operation if isinstance(self.operation,str) and self.operation in OPERATIONS else 'unknown'})
    def __enter__(self):
        self.originals={name:getattr(self.module,name) for name in ('run','control','_recover','subprocess','upload_sftp')}
        try:
            super().install();original_control=self.originals['control'];original_recover=self.originals['_recover'];observer=self
            def control(operation,*arguments,**keywords):
                previous=observer.operation;observer.operation=operation if isinstance(operation,str) and operation in OPERATIONS else 'unknown'
                try:return original_control(operation,*arguments,**keywords)
                except BaseException as error:
                    try:observer.record({'event':'control_failure'}|recovery_error(error))
                    except BaseException:pass
                    raise
                finally:observer.operation=previous
            def recover(*arguments,**keywords):
                observer.recover_called=True
                try:
                    original=sys.exception()
                    if original is not None:observer.original_error=recovery_error(original)
                except BaseException:pass
                previous=observer.phase;observer.phase='recovery'
                try:return original_recover(*arguments,**keywords)
                except BaseException as error:
                    try:
                        observer.recovery_error=recovery_error(error)
                        observer.record({'event':'recovery_failure'}|observer.recovery_error)
                    except BaseException:pass
                    raise
                finally:observer.phase=previous
            self.module.control=control;self.module._recover=recover
        except BaseException:
            self.__exit__(*sys.exc_info());raise
        return self
    def __exit__(self,kind,error,trace):
        try:
            for name,value in self.originals.items():setattr(self.module,name,value)
            self.wrappers_restored=all(getattr(self.module,name) is value for name,value in self.originals.items())
        except BaseException:
            if error is None:raise
        return False
    def note_reported(self,error):
        try:self.reported_error=recovery_error(error)
        except BaseException:pass
    @contextmanager
    def acl_checks(self,files):
        original=self.module.control;observer=self
        def control(operation,*arguments,**keywords):
            result=original(operation,*arguments,**keywords)
            try:
                if operation=='acl-read' and len(arguments)==1 and not keywords and isinstance(arguments[0],dict):
                    paths=arguments[0].get('paths')
                    if isinstance(paths,list) and len(paths)==1 and isinstance(paths[0],str):
                        name=paths[0];entry=files.get(name)
                        if isinstance(entry,dict) and entry.get('exists') is True and isinstance(entry.get('sddl'),str) and isinstance(result,dict) and isinstance(result.get(name),str) and result[name]!=entry['sddl']:
                            observer.note_acl_mismatch(name,entry['sddl'],result[name])
            except BaseException:pass
            return result
        self.module.control=control
        try:yield
        finally:
            self.module.control=original;self.acl_checks_restored=self.module.control is original
    def note_acl_mismatch(self,name,before,after):
        try:
            if self.acl_observation is None:self.acl_observation={'schema':1,'report_status':'unavailable','mismatches':[]}
            if len(self.acl_observation['mismatches'])>=3:return
            if len(before)>131072 or len(after)>131072:return
            request={'schema':1,'items':[{'file_category':acl_category(self.module,name),'before':before,'after':after}]}
            powershell=str(Path(os.environ.get('SystemRoot','C:/Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe')
            output=self.module.run([powershell,'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(Path(__file__).with_name('windows-backup-sddl.ps1'))],
                input=json.dumps(request,separators=(',',':')).encode('utf-8'),env=self.module.native_powershell_environment(),timeout=20)
            if not isinstance(output,bytes) or len(output)>65536:return
            value=projected_acl(json.loads(output.decode('utf-8-sig')))
            if value['report_status']=='read' and len(value['mismatches'])==1:
                self.acl_observation['mismatches'].extend(value['mismatches']);self.acl_observation['report_status']='read'
        except BaseException:pass
    def safe_report(self):
        state='unavailable'
        try:
            journal=self.module.RESTORE/'journal.json'
            if not journal.exists():state='absent'
            else:
                journal=ordinary(journal)
                if journal.stat().st_size<=8*1024*1024:
                    value=json.loads(journal.read_text(encoding='utf-8-sig')).get('state')
                    state=value if isinstance(value,str) and value in {'prepared','restoring','restored','recovery_required','recovered'} else 'unknown'
        except BaseException:pass
        result={'schema':1,'journal_state':state,'recover_called':self.recover_called,'wrappers_restored':self.wrappers_restored,'events':self.events,'truncated':self.truncated}
        try:
            reached=self.injected()
            if type(reached) is bool:result['injection_reached']=reached
        except BaseException:pass
        for key in ('original_error','recovery_error','reported_error'):
            if getattr(self,key) is not None:result[key]=getattr(self,key)
        if self.acl_observation is not None:
            try:result['acl_observation']=projected_acl(self.acl_observation)|{'control_restored':self.acl_checks_restored}
            except BaseException:pass
        return result


def projected_events(record):
    if (type(record.get('schema')) is not int or record['schema']!=1 or type(record.get('truncated')) is not bool or
        not isinstance(record.get('events'),list) or len(record['events'])>8):raise ValueError()
    events=[]
    for event in record['events']:
        if (not isinstance(event,dict) or event.get('event') not in {'tool_failure','run_failure','upload_failure'} or
            event.get('phase') not in PHASES):raise ValueError()
        safe={'event':event['event'],'phase':event['phase']}
        for key,choices in (('tool',TOOLS),('failure_class',CLASSES),('error_type',ERRORS)):
            if isinstance(event.get(key),str) and event[key] in choices:safe[key]=event[key]
        if type(event.get('returncode')) is int and -(2**31)<=event['returncode']<2**31:safe['returncode']=event['returncode']
        events.append(safe)
    return events


def ordinary(path):
    path=Path(path)
    for parent in (path,*path.parents):
        if parent.is_symlink() or parent.exists() and getattr(parent.lstat(),'st_file_attributes',0)&0x400:
            raise RuntimeError('Disposable worker observation refuses linked paths.')
    if not path.is_file() or path.stat().st_nlink!=1:raise RuntimeError('Disposable worker observation needs an ordinary file.')
    return path


def validated_config(path):
    path=ordinary(path)
    expected=Path(os.environ.get('ProgramData','C:/ProgramData'))/'OpenWebPBX/backup-qualification'
    if path.name!='worker-observer-config.json' or ntpath.normcase(str(path.parent))!=ntpath.normcase(str(expected)) or path.stat().st_size>8192:
        raise RuntimeError('Disposable worker observation scope refused.')
    config=json.loads(path.read_text(encoding='utf-8'))
    if (type(config.get('schema')) is not int or config['schema']!=1 or config.get('disposable_hosted_runner') is not True or
        config.get('hostname')!=socket.gethostname() or not re.fullmatch('[0-9]+',str(config.get('run_id',''))) or
        not re.fullmatch('[a-f0-9]{40}',str(config.get('source_commit',''))) or config.get('repository')!='embire2/openwebpbx' or
        not re.fullmatch(r'embire2/openwebpbx/\.github/workflows/windows-(?:suite|backups-diagnostics)\.yml@refs/heads/customization',str(config.get('workflow_ref',''))) or
        not re.fullmatch('[a-f0-9]{64}',str(config.get('source_sha256',''))) or not re.fullmatch('[a-f0-9]{64}',str(config.get('launcher_sha256','')))):
        raise RuntimeError('Disposable worker observation binding refused.')
    if hashlib.sha256(ordinary(Path(__file__)).read_bytes()).hexdigest()!=config['launcher_sha256']:
        raise RuntimeError('Disposable worker observation source changed.')
    return config


def launch(path):
    if os.name!='nt' or not ctypes.windll.shell32.IsUserAnAdmin():raise RuntimeError('Disposable native Windows administrator worker required.')
    config=validated_config(path);source=ordinary(Path('C:/OpenWebPBX/tools/backups.py'))
    if hashlib.sha256(source.read_bytes()).hexdigest()!=config['source_sha256']:raise RuntimeError('Installed backup source changed.')
    spec=importlib.util.spec_from_file_location('observed_native_backups',source);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    settings=module.read_settings()
    from urllib.parse import urlsplit
    parsed=urlsplit(settings.get('openweb.public_url',''))
    if parsed.scheme!='https' or not parsed.hostname or not all(ipaddress.ip_address(row[4][0]).is_loopback for row in socket.getaddrinfo(parsed.hostname,None,type=socket.SOCK_STREAM)):
        raise RuntimeError('Only the disposable loopback installation may be observed.')
    WorkerObservation(module,Path(path).with_name('worker-observer-report.json')).install()
    sys.argv=[str(source),*sys.argv[2:]]
    return module.main()


class TaskActionLease:
    def __init__(self,module,ps,private,package):
        if os.name!='nt' or os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('OPENWEB_WINDOWS_BACKUP_TEST')!='1':
            raise RuntimeError('An explicitly disposable hosted runner is required.')
        self.module=module;self.ps=ps;self.private=private;self.package=package;self.snapshot=None;self.restored=False
        self.report=private/'worker-observer-report.json';self.config=private/'worker-observer-config.json';self.launcher=private/'worker-observer.py'
    @staticmethod
    def quote(value):return "'"+str(value).replace("'","''")+"'"
    def task(self):
        return json.loads(self.ps("$t=Get-ScheduledTask -TaskName OpenWebPBX-Backups;$a=@($t.Actions);if($a.Count -ne 1){throw 'Expected one backup action'};$x=[xml](Export-ScheduledTask -TaskName OpenWebPBX-Backups);@{execute=$a[0].Execute;arguments=$a[0].Arguments;working_directory=$a[0].WorkingDirectory;principal=$x.Task.Principals.OuterXml;triggers=$x.Task.Triggers.OuterXml;settings=$x.Task.Settings.OuterXml;user=$t.Principal.UserId;logon=[string]$t.Principal.LogonType}|ConvertTo-Json -Compress"))
    def set_arguments(self,arguments):
        self.ps("$t=Get-ScheduledTask -TaskName OpenWebPBX-Backups;$a=@($t.Actions);if($a.Count -ne 1){throw 'Expected one backup action'};$a[0].Arguments="+self.quote(arguments)+";Set-ScheduledTask -TaskName OpenWebPBX-Backups -Action $a|Out-Null")
    def __enter__(self):
        expected=self.module.STATE/'backup-qualification'
        if self.private!=expected or any(self.module.reparse(path) for path in (self.private,*self.private.parents)):
            raise RuntimeError('Private worker observer scope refused.')
        installed=ordinary(Path('C:/OpenWebPBX/tools/backups.py'));packaged=ordinary(self.package/'backups.py')
        digest=hashlib.sha256(installed.read_bytes()).hexdigest()
        if hashlib.sha256(packaged.read_bytes()).hexdigest()!=digest:raise RuntimeError('Installed and packaged backup source differ.')
        self.snapshot=self.task()
        if (ntpath.normcase(self.snapshot['execute'])!=ntpath.normcase('C:/OpenWebPBX/backup-runtime/python.exe') or
            self.snapshot['arguments']!='-I "C:\\OpenWebPBX\\tools\\backups.py" worker' or
            ntpath.normcase(self.snapshot['working_directory'])!=ntpath.normcase('C:/OpenWebPBX/tools') or
            str(self.snapshot['user']).upper() not in {'SYSTEM','S-1-5-18','NT AUTHORITY\\SYSTEM'} or self.snapshot['logon']!='ServiceAccount'):
            raise RuntimeError('The installed SYSTEM backup action differs from the expected worker.')
        for path in (self.report,self.config,self.launcher):
            if path.exists():raise RuntimeError('A previous disposable worker observation must not be overwritten.')
        shutil.copyfile(ordinary(Path(__file__)),self.launcher);self.module.secure_acl(self.launcher)
        config={'schema':1,'disposable_hosted_runner':True,'hostname':socket.gethostname(),'run_id':os.environ.get('GITHUB_RUN_ID'),
            'source_commit':os.environ.get('GITHUB_SHA'),'repository':os.environ.get('GITHUB_REPOSITORY'),'workflow_ref':os.environ.get('GITHUB_WORKFLOW_REF'),
            'source_sha256':digest,'launcher_sha256':hashlib.sha256(self.launcher.read_bytes()).hexdigest()}
        self.module.atomic_json(self.config,config)
        validated_config(self.config)
        self.arguments=f'-I "{self.launcher}" "{self.config}" worker'
        try:
            self.set_arguments(self.arguments)
            if self.task()!=self.snapshot|{'arguments':self.arguments}:raise RuntimeError('The temporary backup task action changed other metadata.')
        except BaseException:
            try:self.restore()
            except BaseException:pass
            raise
        return self
    def restore(self):
        current=self.task()
        if current==self.snapshot:self.restored=True;return
        if current!=self.snapshot|{'arguments':self.arguments}:raise RuntimeError('The temporary backup task acquired unexpected metadata changes.')
        self.set_arguments(self.snapshot['arguments'])
        self.restored=self.task()==self.snapshot
        if not self.restored:raise RuntimeError('The original backup task action did not restore exactly.')
    def __exit__(self,kind,error,traceback):
        try:self.restore()
        except BaseException:
            if error is None:raise
        return False
    def safe_report(self):
        result={'schema':1,'report_status':'unavailable','action_restored':self.restored}
        try:
            file=ordinary(self.report)
            if file.stat().st_size>16384:return result|{'report_status':'refused'}
            record=json.loads(file.read_text(encoding='utf-8'))
            result.update(report_status='read',events=projected_events(record),truncated=record['truncated'])
        except BaseException:pass
        return result


if __name__=='__main__':launch(Path(sys.argv[1]))
