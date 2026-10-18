#!/usr/bin/env python3
"""Meet restore integration against an explicitly supplied disposable PostgreSQL fixture.

OPENWEB_MEET_TEST_CONFIG points to an unquoted config.conf for an owned
openweb_meet_* database on a private /tmp/openweb-* Unix socket. No live
service command is executed: only the Nginx command boundary is recorded.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from unittest.mock import patch

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('meet_backup',root/'packaging/debian/backups.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
config=Path(os.environ['OPENWEB_MEET_TEST_CONFIG']);settings=b.read_settings(config)
assert settings['database.0.host'].startswith('/tmp/openweb-') and settings['database.0.name'].startswith('openweb_meet_'),'Explicit owned private fixture required'
n=0
def check(value,message):
 global n
 assert value,message;n+=1

def php(code,cfg,*args):
 prefix="require $argv[1].'/resources/classes/config.php';config::load($argv[2]);require $argv[1].'/resources/classes/auto_loader.php';new auto_loader();require $argv[1].'/resources/functions.php';$db=database::new()->db;"
 r=subprocess.run(['php','-r',prefix+code,str(root),str(cfg),*map(str,args)],capture_output=True)
 if r.returncode:raise RuntimeError('Private PHP fixture failed: '+r.stderr.decode())

def snapshot():
 return b.query(settings,"select coalesce(json_agg(s order by sip_profile_setting_uuid),'[]')from v_sip_profile_settings s")

with tempfile.TemporaryDirectory(prefix='openweb-meet-restore-')as tmp:
 work=Path(tmp);engine=work/'engine';state=work/'state';cfgdir=work/'config';cfgdir.mkdir();cfg=cfgdir/'config.conf'
 target=settings|{'openweb.public_host':'meet-restore.invalid','openweb.public_ip':'198.51.100.42','switch.conf.dir':str(engine)}
 cfg.write_text(''.join(k+' = '+v+'\n'for k,v in target.items()));cfg.chmod(0o600)
 b.ROOTS={'fusionpbx-config':cfgdir,'runtime-config':state,'freeswitch-config':engine};b.WEB_VERSION=root/'VERSION'
 check(b.restore_meeting(target)is False,'Legacy source without a meeting profile performs no new transform')
 php('pbx_meet_install::apply($db);pbx_meet_install::tls((string)config::load()->get("switch.conf.dir"),$argv[3]);',cfg,state)
 pem=engine/'tls/openweb-meet/wss.pem';ca=state/'meet-ca.pem';identity=(pem.read_bytes(),ca.read_bytes());custom=engine/'custom.wav';custom.write_bytes(b'customer recording remains exact')
 b.query(settings,"update v_sip_profile_settings set sip_profile_setting_value='192.0.2.8'where sip_profile_uuid='cfb1c835-c30c-409b-bff7-a893a7e84df1'and sip_profile_setting_name in('rtp-ip','ext-rtp-ip');update v_sip_profile_settings set sip_profile_setting_value='/source/conf/tls/openweb-meet'where sip_profile_uuid='cfb1c835-c30c-409b-bff7-a893a7e84df1'and sip_profile_setting_name='tls-cert-dir'")
 b.query(settings,"insert into v_sip_profiles(sip_profile_uuid,sip_profile_name,sip_profile_enabled)values(gen_random_uuid(),'internal',true);insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled)select gen_random_uuid(),sip_profile_uuid,'inbound-codec-prefs','G722,PCMU',true from v_sip_profiles where sip_profile_name='internal'")
 check(b.restore_meeting(target)is True,'Actual production restore helper validates TLS and rebinds owned profile')
 values=json.loads(b.query(settings,"select json_object_agg(sip_profile_setting_name,sip_profile_setting_value)from v_sip_profile_settings where sip_profile_uuid='cfb1c835-c30c-409b-bff7-a893a7e84df1'"))
 check(values['rtp-ip']==values['ext-rtp-ip']=='198.51.100.42','Both restored media addresses use replacement server IP')
 check(values['tls-cert-dir']==str(engine/'tls/openweb-meet'),'TLS directory uses actual target engine configuration path')
 check(b.query(settings,"select sip_profile_setting_value from v_sip_profile_settings join v_sip_profiles using(sip_profile_uuid)where sip_profile_name='internal'")=='G722,PCMU,VP8','Restore enables VP8 without changing established audio order')
 check((pem.read_bytes(),ca.read_bytes())==identity and custom.read_bytes()==b'customer recording remains exact','Restore preserves TLS keys/pin/custom recording bytes exactly')
 before=snapshot();b.restore_meeting(target);check(snapshot()==before,'Repeated restore helper makes no database changes')
 ca.write_bytes(b'wrong trust pin');before=snapshot()
 try:b.restore_meeting(target);raise AssertionError('Mismatching trust accepted')
 except b.BackupError:pass
 check(snapshot()==before and pem.read_bytes()==identity[0]and ca.read_bytes()==b'wrong trust pin','Invalid trust refuses before DB changes or key rotation');ca.write_bytes(identity[1])
 # Preserve only target machine address/database. Customer source settings survive.
 source_cfg=work/'source.conf';source_cfg.write_text(''.join(k+' = '+v+'\n'for k,v in (target|{'openweb.public_ip':'192.0.2.8','database.0.name':'source_fixture','custom.keep':'source customer value'}).items()))
 runtime=work/'runtime.json';runtime.write_text(json.dumps({'ConnectionStrings':{'Pbx':'source'},'Custom':{'keep':'source'}}))
 b.preserve_target_database(target,source_cfg,runtime);restored=b.read_settings(source_cfg)
 check(restored['openweb.public_ip']=='198.51.100.42'and restored['database.0.name']==target['database.0.name'],'Source restore retains actual target database and public media address')
 check(restored['custom.keep']=='source customer value'and json.loads(runtime.read_text())['Custom']=={'keep':'source'},'Target-address preservation leaves unrelated source configuration intact')
 b.preserve_target_database({k:v for k,v in target.items()if k!='openweb.public_ip'},source_cfg,runtime)
 check('openweb.public_ip'not in b.read_settings(source_cfg),'Target without explicit IP does not inherit source machine address')
 check(b.meeting_transport_files({'files':{'runtime-config/meet-ca.pem':{},'freeswitch-config/tls/openweb-meet/wss.pem':{}}}),'Complete private identity is recognized')
 check(not b.meeting_transport_files({'files':{}}),'Legacy backup without meeting assets remains supported')
 for name in ['runtime-config/meet-ca.pem','freeswitch-config/tls/openweb-meet/wss.pem']:
  try:b.meeting_transport_files({'files':{name:{}}});raise AssertionError('Partial TLS identity accepted')
  except b.BackupError:check(True,'Partial private identity refuses before restore mutations')
 # Import the real sibling helper; mock only its OS service command boundary.
 commands=[]
 def command(args,**kwargs):commands.append(args);return subprocess.CompletedProcess(args,0)
 with patch.object(subprocess,'run',side_effect=command):b.reload_meeting_proxy()
 check(commands==[['nginx','-t'],['systemctl','is-active','--quiet','nginx'],['systemctl','reload','nginx']],'Restore uses actual Nginx validation/reload hook to read changed trust pin')
print(f'PASS {n} actual isolated PostgreSQL/PHP/crypto restore integration controls')
