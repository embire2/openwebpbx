"""Disposable Windows native backup qualification; never runs on a customer PBX.

Invoked by windows-backups.ps1 with private fixture inputs. Report values contain
only acceptance facts. SFTP is explicitly unqualified unless loopback inputs
are supplied and a real upload plus wrong-host-key refusal succeed.
"""
import hashlib
import hmac
import html.parser
import http.cookiejar
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from unittest.mock import patch
import uuid

if os.name != 'nt' or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('OPENWEB_WINDOWS_BACKUP_TEST') != '1':
    raise SystemExit('An explicitly disposable Windows hosted runner is required.')
spec=importlib.util.spec_from_file_location('native_backups',Path('C:/OpenWebPBX/tools/backups.py'))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)


class Hidden(html.parser.HTMLParser):
    def __init__(self):super().__init__();self.tokens={}
    def handle_starttag(self,tag,attributes):
        values=dict(attributes)
        if tag=='input' and values.get('type')=='hidden' and re.fullmatch('[a-f0-9]{64}',values.get('name','')):
            self.tokens[values['name']]=values.get('value','')


def ps(script, timeout=180):
    result=subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe'),
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',script],env=b.native_powershell_environment(),capture_output=True,timeout=timeout)
    if result.returncode:raise RuntimeError('A native Windows qualification control failed.')
    return result.stdout.decode('utf-8-sig').strip()


class Http:
    def __init__(self,base):
        self.base=base.rstrip('/');self.cookies=http.cookiejar.CookieJar()
        self.opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookies),urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    def request(self,path,data=None):
        body=urllib.parse.urlencode(data).encode() if data is not None else None
        request=urllib.request.Request(self.base+path,data=body,headers={'User-Agent':'OpenWebPBX-Native-Backup-Qualification','Referer':self.base+path})
        try:
            with self.opener.open(request,timeout=30) as result:return result.status,result.read()
        except urllib.error.HTTPError as error:return error.code,error.read()
    def form(self,path,data):
        code,raw=self.request(path);assert code==200,'The authorized form is unavailable'
        parser=Hidden();parser.feed(raw.decode());assert parser.tokens,'The normal form has no CSRF token'
        return self.request(path,parser.tokens|data)
    def login(self,email,password):
        code,_=self.form('/',{'username':email,'password':password,'domain_name':urllib.parse.urlparse(self.base).hostname})
        assert code==200,'Normal HTTPS sign-in failed'
        code,raw=self.request('/app/pbx_backups/index.php');assert code==200 and b'Automatic backups' in raw,'The signed-in instance administrator cannot open Backups'


def fixture(operation, path, php):
    result=subprocess.run(['C:/OpenWebPBX/php/php.exe',php,operation,str(path)],cwd='C:/OpenWebPBX/web',capture_output=True,timeout=120)
    if result.returncode:raise RuntimeError('The owned PBX fixture operation failed.')


def target_thumbprint():
    result=json.loads(ps("Import-Module WebAdministration;$b=Get-WebBinding -Name OpenWebPBX -Protocol https|Select-Object -First 1;$h=$b.certificateHash;if($h -is [string]){$t=$h}else{$t=([BitConverter]::ToString($h)).Replace('-','')};@{thumbprint=$t}|ConvertTo-Json -Compress"))['thumbprint']
    assert re.fullmatch('[a-fA-F0-9]{40,64}',str(result)),'The target IIS certificate identity is unavailable'
    return result


def wait_command(settings, identifier):
    deadline=time.monotonic()+240
    while time.monotonic()<deadline:
        row=b.query(settings,'select row_to_json(t) from v_pbx_backup_commands t where command_uuid='+b.literal(identifier),json_result=True)
        if row and row['status'] in ('completed','failed'):
            assert row['status']=='completed','The actual SYSTEM task did not complete the backup request'
            return row
        time.sleep(.5)
    raise AssertionError('The actual SYSTEM task did not finish within the bounded fixture time')


def request_backup(client,settings):
    code,raw=client.form('/app/pbx_backups/index.php',{'action':'create','backup_uuid':''})
    assert code==200 and b'Request queued' in raw,'The authenticated CSRF backup request failed'
    identifier=b.query(settings,"select command_uuid from v_pbx_backup_commands where status in ('pending','running') order by created_at desc limit 1")
    assert re.fullmatch('[a-f0-9-]{36}',identifier),'The native request was not queued'
    ps('Start-ScheduledTask -TaskName OpenWebPBX-Backups')
    wait_command(settings,identifier)
    return b.query(settings,'select row_to_json(t) from v_pbx_backups t where command_uuid='+b.literal(identifier),json_result=True)


def fingerprint(settings,domain,key):
    rows={table:b.query(settings,'select coalesce(json_agg(t order by row_to_json(t)::text),\'[]\') from '+table+' t where domain_uuid='+b.literal(domain),json_result=True)
          for table in ('v_extensions','v_gateways','v_pbx_restore','v_call_center_queues','v_call_center_agents','v_call_center_tiers')}
    return hmac.new(key,json.dumps(rows,sort_keys=True,separators=(',',':')).encode(),hashlib.sha256).hexdigest()


def local_service_check(private,archive):
    folder=private/'localservice';folder.mkdir(exist_ok=True)
    # This owned result directory is writable by the test identity; the actual
    # notification store and script retain their independent read-only ACLs.
    b.secure_acl(folder,kind='media')
    script=folder/'read.ps1';report=folder/'result.json'
    report.unlink(missing_ok=True)
    notification=b.STATE/'mobile-notifications/config.json'
    assert notification.is_file(),'A normal HTTPS-created notification identity is required'
    previous=notification.read_bytes()
    script.write_text("$r=@{runtime=$false;archive=$false;notification_read=$false;notification_write=$false};try{$x=[IO.File]::ReadAllBytes('"+str(b.STATE/'runtime.json').replace("'","''")+"');$r.runtime=$x.Length -gt 0}catch{};try{$x=[IO.File]::ReadAllBytes('"+str(archive).replace("'","''")+"');$r.archive=$true}catch{};try{$x=[IO.File]::ReadAllBytes('"+str(notification).replace("'","''")+"');$r.notification_read=$x.Length -gt 0}catch{};try{$s=[IO.File]::Open('"+str(notification).replace("'","''")+"',[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$s.Dispose();$r.notification_write=$true}catch{};$r|ConvertTo-Json|Set-Content '"+str(report).replace("'","''")+"' -Encoding UTF8",encoding='utf-8')
    b.secure_acl(script,kind='config')
    name='OpenWebPBX-Backup-LocalService-'+uuid.uuid4().hex
    try:
        ps("$a=New-ScheduledTaskAction -Execute ($env:SystemRoot+'/System32/WindowsPowerShell/v1.0/powershell.exe') -Argument '-NoProfile -NonInteractive -File \""+str(script)+"\"';$p=New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\\LOCAL SERVICE' -LogonType ServiceAccount -RunLevel Limited;Register-ScheduledTask -TaskName '"+name+"' -Action $a -Principal $p -Force|Out-Null;Start-ScheduledTask -TaskName '"+name+"'")
        deadline=time.monotonic()+30
        while not report.exists() and time.monotonic()<deadline:time.sleep(.2)
        result=json.loads(report.read_text(encoding='utf-8-sig'))
        assert result['runtime'] is True and result['archive'] is False,'Actual LocalService access exceeded the private backup boundary or cannot read its runtime'
        assert result['notification_read'] is True and result['notification_write'] is False,'Actual LocalService notification permissions are not read-only'
        assert notification.read_bytes()==previous,'The read-only permission probe changed notification identity bytes'
    finally:
        ps("Unregister-ScheduledTask -TaskName '"+name+"' -Confirm:$false -ErrorAction SilentlyContinue")


def main(path):
    data=json.loads(path.read_text(encoding='utf-8-sig'));private=path.parent;report=Path(data['report'])
    facts={'platform':'native Windows hosted runner','checks':[],'fully_qualified':False,'sftp':'unqualified'}
    phase='factory guard';settings=b.read_settings();password=secrets.token_hex(32);audit_key=os.urandom(32)
    assert b.ordinary(Path(data['package_root'])/'VERSION').read_text().strip()==b.WEB_VERSION.read_text().strip(),'The installed release is not the supplied package'
    for table in ('v_extensions','v_pbx_tenants','v_pbx_services','v_pbx_restore','v_recordings','v_voicemail_messages'):
        assert b.query(settings,'select count(*) from '+table)=='0','A separate empty factory is required'
    assert b.query(settings,'select count(*) from v_users')=='1' and b.query(settings,'select count(*) from v_domains')=='1','A separate empty factory is required'
    parsed=urllib.parse.urlparse(settings['openweb.public_url']);assert parsed.scheme=='https','Trusted HTTPS is required'
    assert all(ipaddress.ip_address(row[4][0]).is_loopback for row in socket.getaddrinfo(parsed.hostname,None,type=socket.SOCK_STREAM)),'Only loopback test HTTP is permitted'
    try:
        phase='HTTPS and CSRF';client=Http(settings['openweb.public_url']);client.login(data['admin_email'],data['admin_password'])
        code,_=client.request('/app/pbx_backups/index.php',{'action':'create'});assert code==403,'Missing CSRF was accepted'
        code,raw=client.form('/app/pbx_backups/index.php',{'action':'save','enabled':'0','schedule_hour':'0','retention':'2','include_media':'1','passphrase':password,'sftp_enabled':'0','sftp_port':'22'})
        assert code==200 and b'Backup settings saved' in raw and password.encode() not in raw,'Normal HTTPS settings or secret masking failed'
        facts['checks'].append('normal HTTPS sign-in/settings/password masking/missing-CSRF denial')
        phase='source notification identity'
        code,raw=client.form('/app/pbx_mobile/push.php',{'enabled':'1','provider':'webpush','delivery':'direct','relay_url':'','relay_token':''})
        assert code==200 and b'Incoming wake-up settings saved' in raw,'Normal IIS notification setup failed'
        notification=b.STATE/'mobile-notifications/config.json';source_notification=notification.read_bytes()
        assert json.loads(source_notification).get('vapid_private_key'),'The source notification identity is incomplete'
        phase='source trusted TLS'
        ps("& 'C:/OpenWebPBX/tools/Enable-PhoneTLS.ps1' -CertificateThumbprint '"+target_thumbprint()+"'")
        assert (b.STATE/'phone-tls.json').exists(),'A real source phone certificate is required for restore qualification'
        phase='owned PBX';fixture('create',path,data['fixture_php']);data=json.loads(path.read_text(encoding='utf-8-sig'));domain=data['fixture_domain']
        b.atomic_json(private/'owned-fixture.json',{key:data[key] for key in ('fixture_domain','fixture_realm')})
        expected=fingerprint(settings,domain,audit_key);source_key=b.KEY.read_bytes()
        sentinel={b.MEDIA['storage']/'openwebpbx'/domain/'backup.wav':os.urandom(4096),b.MEDIA['recordings']/'backup-fixture.wav':os.urandom(5000),b.MEDIA['custom-sounds']/'backup-fixture.wav':os.urandom(4500)}
        for file,payload in sentinel.items():file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(payload)
        task=json.loads(ps("$t=Get-ScheduledTask -TaskName OpenWebPBX-Backups;@{user=$t.Principal.UserId;logon=[string]$t.Principal.LogonType;action=$t.Actions.Execute;enabled=[bool]$t.Settings.Enabled}|ConvertTo-Json -Compress"))
        assert str(task['user']).upper() in ('SYSTEM','S-1-5-18','NT AUTHORITY\\SYSTEM') and task['logon']=='ServiceAccount' and task['enabled'],'The real task is not SYSTEM/ServiceAccount/enabled'
        phase='actual SYSTEM backup';row=request_backup(client,settings);archive=b.STORE/row['filename']
        assert row['status']=='ready' and b.checksum(archive)==row['sha256'],'The actual task did not publish verified ciphertext'
        code,download=client.request('/app/pbx_backups/download.php?id='+row['backup_uuid']);assert code==200 and hashlib.sha256(download).hexdigest()==row['sha256'],'Authenticated IIS download changed the encrypted file'
        anonymous=Http(settings['openweb.public_url']);_,denied=anonymous.request('/app/pbx_backups/download.php?id='+row['backup_uuid']);assert not denied.startswith(b.MAGIC),'An unauthenticated download leaked the archive'
        with b.verify_archive(archive,password) as (extracted,manifest):
            assert (extracted/'fusionpbx-config/openweb-template.key').read_bytes()==source_key,'Source key was omitted'
            assert manifest['platform']==b.PLATFORM,'The native archive platform is wrong'
        try:
            with b.verify_archive(archive,'Wrong generated fixture password 123'):pass
        except b.BackupError:pass
        else:raise AssertionError('Wrong backup password was accepted')
        local_service_check(private,archive)
        facts['checks'].append('actual SYSTEM archive/verification/wrong-password/media/key/IIS download/unauthenticated denial/LocalService private boundary')
        phase='retention';second=request_backup(client,settings);third=request_backup(client,settings)
        assert b.query(settings,"select count(*) from v_pbx_backups where status='ready'")=='2' and not archive.exists(),'Native retention did not retain exactly two successful backups'
        archive=b.STORE/third['filename'];protected=private/'restore-source.owpbx';shutil.copyfile(archive,protected);b.secure_acl(protected)
        code,_=client.form('/app/pbx_backups/index.php',{'action':'verify','backup_uuid':third['backup_uuid']});assert code==200,'Normal HTTPS verification was rejected'
        command=b.query(settings,"select command_uuid from v_pbx_backup_commands where action='verify' order by created_at desc limit 1");ps('Start-ScheduledTask -TaskName OpenWebPBX-Backups');wait_command(settings,command)
        facts['checks'].append('actual native retention and normal HTTPS verification request')
        if data.get('sftp_config'):
            phase='native SFTP';remote=json.loads(Path(data['sftp_config']).read_text(encoding='utf-8-sig'))
            assert remote['sftp_host'] in ('127.0.0.1','localhost'),'Only isolated loopback SFTP is permitted'
            values={'action':'save','enabled':'0','schedule_hour':'0','retention':'2','include_media':'1','passphrase':'','sftp_enabled':'1','sftp_identity':remote['identity']}
            values.update({key:remote[key] for key in ('sftp_host','sftp_port','sftp_user','sftp_directory','sftp_host_key')})
            code,raw=client.form('/app/pbx_backups/index.php',values);assert code==200 and b'Backup settings saved' in raw,'Normal HTTPS SFTP configuration was rejected'
            sent=request_backup(client,settings);archive=b.STORE/sent['filename']
            assert sent['status']=='ready' and sent['remote_status']=='uploaded','The actual SYSTEM SFTP worker did not report verified upload'
            target=Path(remote['observed_directory'])/archive.name
            assert b.checksum(target)==b.checksum(archive),'The separate loopback SFTP receiver has different ciphertext'
            from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
            from cryptography.hazmat.primitives.serialization import Encoding,PublicFormat
            key=Ed25519PrivateKey.generate().public_key().public_bytes(Encoding.OpenSSH,PublicFormat.OpenSSH).decode()
            code,_=client.form('/app/pbx_backups/index.php',values|{'sftp_host_key':key});assert code==200,'The isolated wrong-host-key setup was not saved'
            refused=request_backup(client,settings)
            assert refused['status']=='ready' and refused['remote_status']=='failed' and not (Path(remote['observed_directory'])/refused['filename']).exists(),'The actual SYSTEM SFTP worker accepted the wrong host key or discarded its safe local copy'
            facts['sftp']='real SYSTEM loopback upload/wrong-host-key refusal/local-copy preservation passed';facts['checks'].append(facts['sftp'])
        phase='factory reset';fixture('clear',path,data['fixture_php'])
        for file in sentinel:file.unlink(missing_ok=True)
        media=b.MEDIA['storage']/'openwebpbx'/domain
        if media.is_dir():shutil.rmtree(media)
        ps('Disable-ScheduledTask -TaskName OpenWebPBX-Backups|Out-Null')
        b.query(settings,"update v_pbx_backup_settings set enabled=false,passphrase_secret='',sftp_enabled=false")
        target_key=os.urandom(32);b.KEY.write_bytes(target_key)
        factory_credentials={key:settings[key] for key in settings if key.startswith('database.0.')}
        factory_files={file:file.read_bytes() for file in (b.CONFIG,b.KEY,b.STATE/'runtime.json',b.STATE/'installation.json')}
        phase='native restore recovery';original_copy=b.atomic_copy;failed=False
        def fail_once(source,target,**arguments):
            nonlocal failed
            if not failed:failed=True;raise b.BackupError('Injected qualification-only file failure')
            return original_copy(source,target,**arguments)
        try:
            with patch.object(b,'atomic_copy',fail_once):b.restore(protected,password,settings,confirm_database=settings['database.0.name'])
        except b.BackupError:pass
        else:raise AssertionError('The injected native restore failure was ignored')
        assert json.loads((b.RESTORE/'journal.json').read_text())['state']=='recovered','Native recovery did not finish'
        for file,payload in factory_files.items():assert file.read_bytes()==payload,'Native recovery changed factory private bytes'
        assert all(not b.held(key) for key in b.HELD_UNITS),'Native factory recovery retained activation gates'
        for name,entry in json.loads((b.RESTORE/'journal.json').read_text())['files'].items():
            if entry['exists']:assert b.control('acl-read',{'paths':[name]})[name]==entry['sddl'],'Native recovery changed original file ACL/owner'
        facts['checks'].append('actual Windows services/IIS failure recovery and exact private bytes/ACL restoration')
        # Retain completed failure evidence rather than deleting recovery material.
        history=private/'recovered-attempt';shutil.move(str(b.RESTORE),str(history));b.safe_private_directory(b.RESTORE)
        phase='native successful restore';b.restore(protected,password,settings,dry_run=True)
        b.restore(protected,password,settings,confirm_database=settings['database.0.name'])
        assert fingerprint(settings,domain,audit_key)==expected,'Restored PBX users/credentials/provider/queue/config differ'
        assert b.KEY.read_bytes()==source_key,'The original source encryption key did not restore'
        assert {key:value for key,value in b.read_settings().items() if key.startswith('database.0.')}==factory_credentials,'Target database identity changed'
        for file,payload in sentinel.items():assert file.read_bytes()==payload,'Native private media restore changed bytes'
        assert notification.read_bytes()==source_notification,'Native restore changed the source notification identity'
        local_service_check(private,protected)
        facts['checks'].append('restored notification identity preserved; real LOCAL SERVICE reads config and cannot open it for writing or read private ciphertext')
        assert all(b.held(key) for key in b.HELD_UNITS),'Native restore lost a durable activation hold'
        states=json.loads(ps("@{calls=[string](Get-Service FreeSWITCH).Status;jobs=[string](Get-Service OpenWebPBX).Status;updates=[string](Get-Service OpenWebPBXUpdater).Status;backup=[bool](Get-ScheduledTask OpenWebPBX-Backups).Settings.Enabled;cleanup=[bool](Get-ScheduledTask OpenWebPBX-Cleanup).Settings.Enabled}|ConvertTo-Json -Compress"))
        assert states=={'calls':'Stopped','jobs':'Stopped','updates':'Stopped','backup':False,'cleanup':False},'Native restored services/tasks were not held'
        client=Http(settings['openweb.public_url']);client.login(data['admin_email'],data['admin_password'])
        facts['checks'].append('actual fresh-factory guarded restore/byte-exact PBX and media/source key/target DB identity/native persistent service+task holds/normal restored HTTPS')
        phase='activation'
        tls=b.STATE/'phone-tls.json'
        if tls.exists():
            metadata=json.loads(tls.read_text(encoding='utf-8-sig'));assert metadata.get('RestorePending') is True,'Source certificate metadata was silently activated'
            thumbprint=json.loads(factory_files[b.STATE/'installation.json']).get('CertificateThumbprint') or target_thumbprint()
            assert re.fullmatch('[a-fA-F0-9]{40,64}',str(thumbprint)),'The target IIS certificate identity is unavailable'
            ps("& 'C:/OpenWebPBX/tools/Enable-PhoneTLS.ps1' -CertificateThumbprint '"+str(thumbprint)+"' -PrepareRestored")
        b.activate(settings,['calls'],settings['openweb.public_host'])
        assert not b.held('calls') and all(b.held(key) for key in ('jobs','updates','backups')),'Calls-only activation released other services'
        states=json.loads(ps("@{calls=[string](Get-Service FreeSWITCH).Status;jobs=[string](Get-Service OpenWebPBX).Status;updates=[string](Get-Service OpenWebPBXUpdater).Status}|ConvertTo-Json -Compress"))
        assert states=={'calls':'Running','jobs':'Stopped','updates':'Stopped'},'Calls-only activation misstarted a service'
        facts['checks'].append('actual trusted TLS preparation/poststart readiness and calls-only activation')
        # Keep the restored fixture safely held for the parent workflow's cleanup.
        b.atomic_json(b.RESTORE/'hold-calls',{'schema':1,'selection':'calls'});b.control('hold-selection',{'selection':'calls'})
        facts['fully_qualified']=facts['sftp']!='unqualified';facts['state']='passed' if facts['fully_qualified'] else 'core passed; native SFTP unqualified'
        b.atomic_json(report,facts)
        print('Native Windows backup core qualification passed. '+('SFTP passed.' if facts['fully_qualified'] else 'Native SFTP remains unqualified.'))
    except BaseException:
        facts['state']='failed';facts['failed_phase']=phase;b.atomic_json(report,facts)
        print('Native Windows backup qualification failed in '+phase+'. Private evidence retained; no passing result claimed.',file=sys.stderr)
        return 1
    return 0


if __name__=='__main__':raise SystemExit(main(Path(sys.argv[1])))
