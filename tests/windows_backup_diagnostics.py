"""Actual HTTP/exception/PowerShell controls; never loads a PBX or Windows entrypoint."""
import ast
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'tests/windows_backups_native.py'
MARKER='PRIVATE_BACKUP_DIAGNOSTIC_MARKER_91cb'
OWNED='aaaaaaaa-1111-4111-8111-111111111111'
FOREIGN='bbbbbbbb-2222-4222-8222-222222222222'


def library(legacy=False):
    tree=ast.parse(SOURCE.read_text())
    names={'BACKUP_PHASES','BACKUP_ERROR_TYPES','LAST_HTTP','LAST_FAILED_COMMAND'}
    nodes=[n for n in tree.body if isinstance(n,(ast.Import,ast.ImportFrom)) or
        isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id in names for t in n.targets) or
        isinstance(n,ast.ClassDef) and n.name in {'Hidden','Http'} or
        isinstance(n,ast.FunctionDef) and n.name in {'backup_exception_fields','failed_command_fields','wait_command'}]
    if legacy:
        http=next(n for n in nodes if isinstance(n,ast.ClassDef) and n.name=='Http')
        login=next(n for n in http.body if isinstance(n,ast.FunctionDef) and n.name=='login')
        endpoint=next(n for n in ast.walk(login) if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and n.func.attr=='form').args[0]
        assert isinstance(endpoint,ast.Constant) and endpoint.value=='/login.php'
        endpoint.value='/'  # The sole historical defect, with the actual class unchanged otherwise.
    namespace={};exec(compile(ast.Module(nodes,type_ignores=[]),str(SOURCE),'exec'),namespace)
    return namespace


class ScopedQuery:
    """Controlled query boundary: reject broad SQL and retain unrelated rows."""
    def __init__(self):
        self.settings={};self.seen=[];self.fail=False
        self.command={'command_uuid':OWNED,'action':'create','status':'failed','message':'The backup could not finish. Check private storage, database access and installed backup tools.'}
        self.backups={OWNED:[{'status':'ready','remote_status':'pending'}],FOREIGN:[{'status':'failed','remote_status':MARKER}]}
    @staticmethod
    def literal(value):return "'"+value+"'"
    def query(self,settings,statement,*,json_result=False):
        assert settings is self.settings and json_result is True
        current="select row_to_json(t) from v_pbx_backup_commands t where command_uuid='"+OWNED+"'"
        if statement==current:return dict(self.command)
        prefix="select json_build_object('linked_count',count(*),'local_status',case when count(*)=1 then min(status) else null end,'remote_status',case when count(*)=1 then min(remote_status) else null end) from v_pbx_backups where command_uuid="
        assert statement.startswith(prefix)
        match=re.fullmatch("'([a-f0-9-]{36})'",statement[len(prefix):]);assert match
        identifier=match.group(1);self.seen.append(identifier)
        if self.fail:raise RuntimeError(MARKER)
        rows=self.backups.get(identifier,[])
        return {'linked_count':len(rows),'local_status':rows[0]['status'] if len(rows)==1 else None,'remote_status':rows[0]['remote_status'] if len(rows)==1 else None}


class Handler(http.server.BaseHTTPRequestHandler):
    token_name='a'*64;token_value='b'*64;root_posts=0;login_posts=0
    def log_message(self,*args):pass
    def respond(self,code,body=b'',headers=()):
        self.send_response(code)
        for key,value in headers:self.send_header(key,value)
        self.end_headers();self.wfile.write(body)
    def do_GET(self):
        path=urllib.parse.urlsplit(self.path).path
        if path=='/':return self.respond(302,headers=[('Location','/login.php')])
        if path=='/login.php':return self.respond(200,('<form method="post" action=""><input type="hidden" name="'+self.token_name+'" value="'+self.token_value+'"></form>').encode())
        if path=='/app/pbx_backups/index.php':
            if 'fixture=authenticated' not in self.headers.get('Cookie',''):return self.respond(302,headers=[('Location','/login.php')])
            return self.respond(200,b'Automatic backups')
        if path=='/denied':return self.respond(403,MARKER.encode())
        return self.respond(200,MARKER.encode())
    def do_POST(self):
        payload=urllib.parse.parse_qs(self.rfile.read(int(self.headers.get('Content-Length','0'))).decode())
        if self.path=='/':
            type(self).root_posts+=1;return self.respond(302,headers=[('Location','/login.php')])
        if self.path=='/login.php':
            type(self).login_posts+=1
            valid=payload.get(self.token_name)==[self.token_value] and payload.get('username')==['fiction@example.invalid'] and payload.get('password')==[MARKER]
            return self.respond(200 if valid else 403,headers=[('Set-Cookie','fixture=authenticated; Path=/')] if valid else [])
        return self.respond(403)


class Diagnostics(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
        cls.base='http://127.0.0.1:'+str(cls.server.server_port)
    @classmethod
    def tearDownClass(cls):cls.server.shutdown();cls.server.server_close();cls.thread.join()
    def setUp(self):self.ns=library();self.http=self.ns['Http'](self.base)
    def test_actual_legacy_root_redirect_loses_post_and_correct_endpoint_authenticates(self):
        Handler.root_posts=0;Handler.login_posts=0
        old=library(legacy=True);client=old['Http'](self.base)
        with self.assertRaises(AssertionError) as failure:client.login('fiction@example.invalid',MARKER)
        self.assertEqual((Handler.root_posts,Handler.login_posts),(1,0))
        old_fields=old['backup_exception_fields'](failure.exception,'HTTPS and CSRF',[])
        self.assertEqual(old_fields['error_type'],'AssertionError')
        self.http.login('fiction@example.invalid',MARKER)
        self.assertEqual((Handler.root_posts,Handler.login_posts),(1,1))
        self.assertEqual(self.ns['LAST_HTTP'],{'target':'backups','method':'GET','status':200})
    def test_csrf_and_authenticated_marker_remain_required(self):
        code,_=self.http.request('/login.php',{'username':'fiction@example.invalid','password':MARKER})
        self.assertEqual(code,403)
        with self.assertRaises(AssertionError):self.http.login('fiction@example.invalid','wrong-fictional-password')
        self.assertEqual(self.ns['LAST_HTTP']['status'],403)
    def test_real_http_denial_and_query_values_are_closed(self):
        self.assertEqual(self.http.request('/denied?private='+MARKER)[0],403)
        self.assertEqual(self.ns['LAST_HTTP'],{'target':'unknown','method':'GET','status':403})
        self.http.request('/app/pbx_backups/download.php?id='+MARKER)
        self.assertEqual(self.ns['LAST_HTTP'],{'target':'download','method':'GET','status':200})
        self.assertNotIn(MARKER,json.dumps(self.ns['LAST_HTTP']))
    def test_real_network_exception_retains_target_without_status(self):
        sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
        client=self.ns['Http']('http://127.0.0.1:'+str(port))
        try:client.request('/app/pbx_mobile/push.php',{'private':MARKER})
        except urllib.error.URLError as error:
            fields=self.ns['backup_exception_fields'](error,'HTTPS and CSRF',[])
        else:self.fail('A closed local port unexpectedly answered')
        self.assertEqual(fields['error_type'],'URLError')
        self.assertEqual(fields['last_http'],{'target':'notifications','method':'POST','status':None})
        self.assertNotIn(MARKER,json.dumps(fields))
    def test_ssl_exception_retains_request_and_never_error_message(self):
        class Broken:
            def open(self,*args,**kwargs):raise ssl.SSLCertVerificationError(MARKER)
        self.http.opener=Broken()
        try:self.http.request('/login.php')
        except ssl.SSLCertVerificationError as error:fields=self.ns['backup_exception_fields'](error,'HTTPS and CSRF',[])
        self.assertEqual(fields['error_type'],'SSLCertVerificationError')
        self.assertEqual(fields['last_http'],{'target':'login','method':'GET','status':None})
        self.assertNotIn(MARKER,json.dumps(fields))
    def test_real_exception_frames_are_known_and_bounded(self):
        namespace=dict(self.ns)
        exec(compile('def recurse(n):\n if n: return recurse(n-1)\n raise AssertionError("'+MARKER+'")\n',str(SOURCE),'exec'),namespace)
        try:namespace['recurse'](20)
        except AssertionError as error:fields=self.ns['backup_exception_fields'](error,'retention',['completed'])
        self.assertEqual(len(fields['source_frames']),8)
        self.assertTrue(all(f['source_basename']=='windows_backups_native.py' and type(f['source_line']) is int for f in fields['source_frames']))
        self.assertEqual(fields['completed_checks'],1);self.assertNotIn(MARKER,json.dumps(fields))
    def test_unknown_exception_and_phase_are_not_exported(self):
        error=type(MARKER,(Exception,),{})(MARKER)
        fields=self.ns['backup_exception_fields'](error,MARKER,[])
        self.assertEqual((fields['error_type'],fields['failed_phase']),('unknown','unknown'))
        self.assertNotIn(MARKER,json.dumps(fields))
    def test_failed_command_query_is_exact_and_reports_no_foreign_values(self):
        database=ScopedQuery();self.ns['b']=database
        fields=self.ns['failed_command_fields'](database.settings,OWNED,database.command)
        self.assertEqual(database.seen,[OWNED]);self.assertEqual(fields['report_status'],'read')
        self.assertEqual((fields['action'],fields['status'],fields['local_status'],fields['remote_status']),('create','failed','ready','pending'))
        self.assertEqual(fields['message_category'],'generic_non_backup_error')
        for private in (OWNED,FOREIGN,MARKER,database.command['message']):self.assertNotIn(private,json.dumps(fields))
        database.backups[OWNED]=[]
        fields=self.ns['failed_command_fields'](database.settings,OWNED,database.command)
        self.assertEqual((fields['linked_count'],fields['local_status'],fields['remote_status']),(0,'absent','absent'))
        database.backups[OWNED]=[{'status':'ready','remote_status':'pending'}]*2
        fields=self.ns['failed_command_fields'](database.settings,OWNED,database.command)
        self.assertEqual(fields['report_status'],'refused');self.assertNotIn('local_status',fields)
    def test_failed_command_refuses_invalid_or_other_command_before_query(self):
        database=ScopedQuery();self.ns['b']=database
        for identifier,row in [(OWNED+"' or true --",database.command),(OWNED.upper(),database.command),(FOREIGN,database.command),(OWNED,dict(database.command,command_uuid=FOREIGN)),(OWNED,dict(database.command,status='completed')),(OWNED,dict(database.command,action='delete'))]:
            fields=self.ns['failed_command_fields'](database.settings,identifier,row)
            self.assertNotEqual(fields['report_status'],'read')
        self.assertEqual(database.seen,[])
    def test_command_message_mapping_is_exact_not_private_text(self):
        database=ScopedQuery();self.ns['b']=database
        message='A private file changed during the backup. No completed copy was published. Retry at a quiet time.'
        exact=self.ns['failed_command_fields'](database.settings,OWNED,dict(database.command,message=message))
        self.assertEqual(exact['message_category'],'private_file_changed')
        for altered in (message+MARKER,MARKER,'x'*4097):
            fields=self.ns['failed_command_fields'](database.settings,OWNED,dict(database.command,message=altered))
            self.assertEqual(fields['message_category'],'unknown');self.assertNotIn(MARKER,json.dumps(fields))
    def test_actual_wait_assertion_survives_failed_observer_and_completed_bypasses_it(self):
        database=ScopedQuery();self.ns['b']=database;database.fail=True
        try:self.ns['wait_command'](database.settings,OWNED)
        except AssertionError as error:fields=self.ns['backup_exception_fields'](error,'native SFTP',['one','two','three'])
        else:self.fail('The failed command unexpectedly passed')
        self.assertEqual(fields['error_type'],'AssertionError');self.assertEqual(fields['failed_command']['report_status'],'unavailable')
        self.assertNotIn(MARKER,json.dumps(fields))
        database.command['status']='completed';database.seen=[]
        self.assertEqual(self.ns['wait_command'](database.settings,OWNED)['status'],'completed');self.assertEqual(database.seen,[])
        self.assertIsNone(self.ns['LAST_FAILED_COMMAND'])
    def test_actual_powershell_report_projector_boundaries_privacy_and_original_failure(self):
        pwsh=os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh')
        self.assertTrue(pwsh,'Pass OPENWEB_TEST_PWSH to require actual PowerShell projection controls')
        with tempfile.TemporaryDirectory(prefix='backup-diag-') as folder:
            directory=Path(folder);script=directory/'controls.ps1'
            script.write_text(PS_CONTROLS,encoding='utf-8')
            database=ScopedQuery();self.ns['b']=database;self.ns['LAST_HTTP'].update(target='backups',method='POST',status=200)
            try:self.ns['wait_command'](database.settings,OWNED)
            except AssertionError as error:fields=self.ns['backup_exception_fields'](error,'native SFTP',['one','two','three'])
            fixture=directory/'python-failure.json';fixture.write_text(json.dumps({'state':'failed','failure':fields,'private':MARKER}),encoding='utf-8')
            result=subprocess.run([pwsh,'-NoProfile','-File',str(script),'-Suite',str(ROOT/'tests/windows-suite.ps1'),'-FailureInput',str(fixture)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,'Actual PowerShell projection controls failed')
            self.assertNotIn(MARKER,result.stdout);self.assertNotIn(MARKER,result.stderr)
            summary=json.loads(result.stdout);self.assertEqual(summary['state'],'passed');self.assertGreaterEqual(summary['checks'],14)


PS_CONTROLS=r'''
param([string]$Suite,[string]$FailureInput)
$ErrorActionPreference='Stop';$count=0
function Check([bool]$Value){if(!$Value){throw 'A backup diagnostic projection control failed.'};$script:count++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Suite,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'BackupFailureReport'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$directory=Join-Path $PSScriptRoot 'backup-qualification';New-Item -ItemType Directory -Path $directory|Out-Null
$path=Join-Path $directory 'report.json';$marker='PRIVATE_BACKUP_DIAGNOSTIC_MARKER_91cb'
function Save($Record){[IO.File]::WriteAllText($path,($Record|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
$record=Get-Content -LiteralPath $FailureInput -Encoding UTF8 -Raw|ConvertFrom-Json -AsHashtable
Check ((BackupFailureReport $path ([datetime]::MinValue)).report_status -ceq 'absent')
Save $record;$safe=BackupFailureReport $path ([datetime]::MinValue)
Check ($safe.report_status -ceq 'read' -and $safe.failed_phase -ceq 'native SFTP' -and $safe.error_type -ceq 'AssertionError')
Check ($safe.source_frames.Count -ge 1 -and $safe.source_frames[0].source_line -gt 0 -and $safe.last_http.status -eq 200)
Check (!(($safe|ConvertTo-Json -Depth 12).Contains($marker)))
Check ($safe.failed_command.report_status -ceq 'read' -and $safe.failed_command.linked_count -eq 1 -and $safe.failed_command.local_status -ceq 'ready' -and $safe.failed_command.remote_status -ceq 'pending' -and $safe.failed_command.message_category -ceq 'generic_non_backup_error')
$record.failure.failed_command.private=$marker
foreach($key in 'action','status','message_category','local_status','remote_status'){$original=$record.failure.failed_command[$key];$record.failure.failed_command[$key]=@($original,$marker);Save $record;$safe=BackupFailureReport $path ([datetime]::MinValue);Check (!$safe.failed_command.ContainsKey($key) -and !(($safe|ConvertTo-Json -Depth 12).Contains($marker)));$record.failure.failed_command[$key]=$original}
$record.failure.failed_command.linked_count=2;Save $record;Check (!(BackupFailureReport $path ([datetime]::MinValue)).failed_command.ContainsKey('linked_count'));$record.failure.failed_command.linked_count=1
$record.failure.failed_command.schema=$true;Save $record;Check (!(BackupFailureReport $path ([datetime]::MinValue)).ContainsKey('failed_command'));$record.failure.failed_command.schema=1
foreach($key in 'failed_phase','error_type'){$original=$record.failure[$key];$record.failure[$key]=@($original,$marker);Save $record;$safe=BackupFailureReport $path ([datetime]::MinValue);Check ($safe[$key] -ceq 'unknown' -and !(($safe|ConvertTo-Json -Depth 12).Contains($marker)));$record.failure[$key]=$original}
foreach($key in 'target','method'){$original=$record.failure.last_http[$key];$record.failure.last_http[$key]=@($original,$marker);Save $record;$safe=BackupFailureReport $path ([datetime]::MinValue);Check ($safe.last_http[$key] -ceq 'unknown' -and !(($safe|ConvertTo-Json -Depth 12).Contains($marker)));$record.failure.last_http[$key]=$original}
$record.failure.source_frames=@(@{source_basename=@('windows_backups_native.py',$marker);source_line=100},@{source_basename='backups.py';source_line=$true});$record.failure.last_http.status='403';Save $record;$safe=BackupFailureReport $path ([datetime]::MinValue)
Check ($safe.source_frames.Count -eq 0 -and $null -eq $safe.last_http.status -and !(($safe|ConvertTo-Json -Depth 12).Contains($marker)))
$record.failure.schema=$true;Save $record;Check ((BackupFailureReport $path ([datetime]::MinValue)).report_status -ceq 'invalid');$record.failure.schema=1
$record.state='passed';Save $record;Check ((BackupFailureReport $path ([datetime]::MinValue)).report_status -ceq 'invalid');$record.state='failed'
Save $record;Check ((BackupFailureReport $path ([datetime]::UtcNow.AddDays(1))).report_status -ceq 'refused')
[IO.File]::WriteAllText($path,('x'*65537));Check ((BackupFailureReport $path ([datetime]::MinValue)).report_status -ceq 'refused')
[IO.File]::WriteAllText($path,'{invalid');Check ((BackupFailureReport $path ([datetime]::MinValue)).report_status -ceq 'unavailable')
Remove-Item -LiteralPath $path;New-Item -ItemType SymbolicLink -Path $path -Target $Suite|Out-Null
Check ((BackupFailureReport $path ([datetime]::MinValue)).report_status -ceq 'refused');Remove-Item -LiteralPath $path
# Execute only the actual inner backup-call catch against an owned throwing stub.
$tries=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text.Contains("'windows-backups.ps1'")},$true)|Sort-Object {$_.Extent.EndOffset-$_.Extent.StartOffset})
$call=$tries[0].Extent.Text
Check ($call.Contains('BackupFailureReport') -and $call.Contains('catch{};throw}'))
$fake=Join-Path $PSScriptRoot 'windows-backups.ps1';[IO.File]::WriteAllText($fake,"param(`$PackageRoot,`$AdminEmail,`$AdminPassword,[switch]`$DisposableFactory,`$SftpConfig);throw [InvalidOperationException]::new('private original failure')")
$state=$PSScriptRoot;$facts=@{};$PackageRoot='fictional';$admin='fiction@example.invalid';$password=$null;$sftpConfig='fictional';$backupStartedAt=[datetime]::UtcNow
# A created scriptblock has no script-file PSScriptRoot; bind only its fixed
# child name to the owned stub instead of evaluating any real backup helper.
function Join-Path {param($Path,$ChildPath);if($ChildPath -ceq 'windows-backups.ps1'){return $fake};return Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath}
function BackupFailureReport {throw [FormatException]::new('private observer failure')}
$originalPreserved=$false;try{. ([scriptblock]::Create($call))}catch{$originalPreserved=$_.Exception -is [InvalidOperationException]}
Check $originalPreserved
@{state='passed';checks=$count}|ConvertTo-Json -Compress
'''


if __name__=='__main__':unittest.main()
