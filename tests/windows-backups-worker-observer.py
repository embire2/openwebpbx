"""Disposable hosted-runner observation of the unmodified installed backup worker.

No arguments, SQL, paths, key material or raw child output enter the report.
The task lease changes only Arguments and restores the original action exactly.
"""
import ctypes
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
        self.module=module;self.report=report;self.phase='before_upload';self.events=[];self.truncated=False
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
                        event={'event':'tool_failure','tool':tool,'failure_class':closed_stderr(tool,result.stderr)}
                        if -(2**31)<=result.returncode<2**31:event['returncode']=result.returncode
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
