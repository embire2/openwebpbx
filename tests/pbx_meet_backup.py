#!/usr/bin/env python3
"""Meet restore integration against an explicitly supplied disposable PostgreSQL fixture.

OPENWEB_MEET_TEST_CONFIG points to an unquoted config.conf for an owned
openweb_meet_* database on a private /tmp/openweb-* Unix socket. No live
service command is executed: only the proxy command boundary is recorded.
Use --windows to exercise the Windows backup implementation on this fixture;
native IIS, certificate-store and ACL checks run separately on Windows.
"""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import secrets
import sys
from unittest.mock import patch

root=Path(__file__).resolve().parents[1]
windows = '--windows' in sys.argv[1:]
spec=importlib.util.spec_from_file_location('meet_backup',root/('packaging/windows/backups.py' if windows else 'packaging/debian/backups.py'))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
config=Path(os.environ['OPENWEB_MEET_TEST_CONFIG']);settings=b.read_settings(config)
owned_host = settings['database.0.host'].startswith('/tmp/openweb-') or (windows and settings['database.0.host']=='127.0.0.1' and str(config).startswith('/tmp/openweb-') and int(settings['database.0.port'])>1024)
assert owned_host and settings['database.0.name'].startswith('openweb_meet_'),'Explicit owned private fixture required'
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

schema='openweb_meet_restore_'+secrets.token_hex(8)
b.query(settings,'create schema '+schema)
for table in ['v_domains','v_users','v_groups','v_sip_profiles','v_sip_profile_settings','v_conference_profiles','v_conference_profile_params','v_dialplans','v_dialplan_details','v_menus','v_menu_items','v_menu_languages','v_menu_item_groups','v_pbx_meetings','v_pbx_meeting_members']:
 b.query(settings,'create table '+schema+'.'+table+'(like public.'+table+' including all)')
old_options=os.environ.get('PGOPTIONS')
os.environ['PGOPTIONS']='-c search_path='+schema+',public'
try:
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
  # A scheduled backup may capture active room sessions. Restore must revoke
  # only transient access while retaining room identity/invitation/history.
  b.query(settings,"insert into v_domains(domain_uuid,domain_name,domain_enabled)values('9e086a9d-0590-4d9b-b176-ff324e5bc41a','meet-restore.invalid',true);insert into v_users(user_uuid,username)values('a6073c4b-ef43-4340-9a2f-b2a9865a6f55','owned-meet-restore');insert into v_pbx_meetings(meeting_uuid,domain_uuid,owner_uuid,subject,starts_at,ends_at,invite_hash,dial_number)values('fc2cd825-b13d-4563-a504-d97a3c46928f','9e086a9d-0590-4d9b-b176-ff324e5bc41a','a6073c4b-ef43-4340-9a2f-b2a9865a6f55','Preserve scheduled room',now(),now()+interval '4 hours',repeat('a',64),'98123456')")
  for i,state_name in enumerate(['waiting','admitted','removed','left']):
   b.query(settings,"insert into v_pbx_meeting_members(member_uuid,meeting_uuid,member_name,role,state,token_hash,sip_username,sip_a1_hash,call_uuid)values(gen_random_uuid(),'fc2cd825-b13d-4563-a504-d97a3c46928f','Historical name "+str(i)+"','guest','"+state_name+"',"+b.literal(hashlib.sha256((str(i+1)*64).encode()).hexdigest())+",'owc-owned-"+str(i)+"',repeat('b',32),"+("gen_random_uuid()"if i<3 else "null")+")")
  room_before=b.query(settings,"select row_to_json(p)from v_pbx_meetings p where meeting_uuid='fc2cd825-b13d-4563-a504-d97a3c46928f'")
  php('if((new pbx_meet($db))->status($argv[3])["state"]!=="waiting")exit(5);',cfg,'1'*64)
  members_before=json.loads(b.query(settings,"select json_agg(m order by member_name)from v_pbx_meeting_members m"))
  check(b.restore_meeting(target)is True,'Actual production restore helper validates TLS and rebinds owned profile')
  members_after=json.loads(b.query(settings,"select json_agg(m order by member_name)from v_pbx_meeting_members m"))
  check(room_before==b.query(settings,"select row_to_json(p)from v_pbx_meetings p where meeting_uuid='fc2cd825-b13d-4563-a504-d97a3c46928f'"),'Restore preserves exact schedule/invitation/owner/room record')
  check([m['state']for m in members_after]==['left','left','removed','left']and all(m['call_uuid']is None for m in members_after),'Restored active members leave and stale calls clear without erasing historical states')
  for old_member,new_member in zip(members_before,members_after):
   preserve=['member_uuid','meeting_uuid','member_name','role','sip_username','created_at','seen_at','muted']
   check(all(old_member[k]==new_member[k]for k in preserve),'Member identity and nontransient history retained')
   if old_member['state']in ['waiting','admitted']or old_member['call_uuid']is not None:
    check(old_member['token_hash']!=new_member['token_hash']and old_member['sip_a1_hash']!=new_member['sip_a1_hash'],'Restored transient token and SIP credential hashes are revoked')
   else:check(old_member==new_member,'Already inactive history without a stale call is byte-for-byte unchanged')
  check(b.query(settings,"select count(*)from v_pbx_meeting_members where state in('waiting','admitted')")=='0','Old guest token/SIP predicates and stale capacity match zero restored sessions')
  for token in ['1'*64,'2'*64,'3'*64,'4'*64]:
   php('try{(new pbx_meet($db))->status($argv[3]);exit(5);}catch(DomainException){}',cfg,token)
   check(True,'Actual token API rejects every previous guest credential')

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
  # Record only the OS service boundary; all preceding TLS/database work ran.
  commands=[]
  environments=[]
  def command(args,**kwargs):
   commands.append(args);environments.append(kwargs.get('env'));return subprocess.CompletedProcess(args,0,stdout=b'',stderr=b'')
  if windows:
   app=work/'application';tools=app/'tools';tools.mkdir(parents=True);shutil.copyfile(root/'packaging/windows/Install-Meet.ps1',tools/'Install-Meet.ps1');b.APP=app
   with patch.object(subprocess,'run',side_effect=command):b.reload_meeting_proxy()
   check(len(commands)==1 and commands[0][-6:]==['-File',str(tools/'Install-Meet.ps1'),'-PackageRoot',str(tools),'-RebindRestoredTransport','-MaintenanceLockHeld'],'Restore requires guarded native meeting rebind')
   check(environments[0]['PSModulePath']==b.native_powershell_environment()['PSModulePath'],'Native proxy refresh isolates Windows PowerShell module roots')
   (state/'meet-proxy.json').write_text('{"machine-bound":"must stay local"}')
   inventory=b.file_inventory({'runtime-config':state})
   check('runtime-config/meet-ca.pem' in inventory and 'runtime-config/meet-proxy.json' not in inventory,'Portable CA is included and machine-bound ownership ledger excluded')
   check(str(b.safe_member('runtime-config/meet-ca.pem'))=='runtime-config/meet-ca.pem','Archive validator accepts the portable meeting trust pin')
   try:b.safe_member('runtime-config/meet-proxy.json');raise AssertionError('Machine ledger accepted')
   except b.BackupError:check(True,'Archive validator refuses machine ownership ledger')
  else:
   with patch.object(subprocess,'run',side_effect=command):b.reload_meeting_proxy()
   check(commands==[['nginx','-t'],['systemctl','is-active','--quiet','nginx'],['systemctl','reload','nginx']],'Restore uses actual Nginx validation/reload hook to read changed trust pin')
finally:
 if old_options is None:os.environ.pop('PGOPTIONS',None)
 else:os.environ['PGOPTIONS']=old_options
 b.query(settings,'drop schema '+schema+' cascade')
print(f'PASS {n} actual isolated PostgreSQL/PHP/crypto restore integration controls')
