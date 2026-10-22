#!/usr/bin/env python3
"""Actual PostgreSQL controls for the read-only Windows factory comparator.

Requires a newly created disposable database named exactly as below. Never use
an installed PBX database. Only the platform/bootstrap seam is replaced; the
preservation body runs unchanged under real PHP/PDO and PostgreSQL.
"""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, tempfile

parser=argparse.ArgumentParser();parser.add_argument('--port',required=True,type=int);args=parser.parse_args()
if not 1024<=args.port<=65535:raise SystemExit('Owned loopback fixture port required.')
root=Path(__file__).resolve().parent.parent
command=['psql','-X','-A','-t','-v','ON_ERROR_STOP=1','-h','127.0.0.1','-p',str(args.port),'-U','postgres','-d','openweb_health_preservation_fixture']
def sql(value):
 result=subprocess.run(command+['-c',value],capture_output=True,text=True)
 if result.returncode:raise RuntimeError('The owned PostgreSQL fixture refused.')
 return result.stdout.strip()
assert sql("select count(*) from pg_tables where schemaname='public'")=='0','A fresh empty fixture is required.'
original=(root/'tests/windows_phone_health_installed.php').read_text()
guard="if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);\nrequire 'C:/OpenWebPBX/web/resources/require.php';\n$db=database::new()->db;"
assert original.count(guard)==1
private=original.replace(guard,"$db=new PDO(getenv('OPENWEB_PRESERVATION_FIXTURE_DSN'),'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);",1)
env=os.environ|{'OPENWEB_PRESERVATION_FIXTURE_DSN':f'pgsql:host=127.0.0.1;port={args.port};dbname=openweb_health_preservation_fixture'}
checks=0
with tempfile.TemporaryDirectory(prefix='openweb-health-preservation-')as work:
 script=Path(work)/'installed.php';script.write_text(private)
 def snapshot():
  result=subprocess.run(['php',str(script),'preservation'],env=env,capture_output=True,text=True)
  if result.returncode:raise RuntimeError('The actual PHP preservation control refused.')
  record=json.loads(result.stdout)
  assert record['state']=='observed' and record['complete_public_rows'] and record['complete_namespace_inventory']
  assert len(record['public_preservation_sha256'])==64
  return record['public_preservation_sha256']
 def check(value):
  global checks
  assert value,'Actual preservation comparison failed.';checks+=1
 sql('create table v_pbx_restore(domain_uuid uuid);create table fixture_contacts(k text,v text);create table fixture_health(changed timestamptz);create table fixture_logs(v text);create sequence fixture_sequence;insert into fixture_contacts values(\'same\',\'private-test-value\'),(\'same\',\'private-test-value\')')
 baseline=snapshot();check(snapshot()==baseline)
 for change,undo in [
  ("insert into fixture_contacts values('same','private-test-value')","delete from fixture_contacts where ctid in(select ctid from fixture_contacts limit 1)"),
  ("update fixture_contacts set v='changed' where ctid in(select ctid from fixture_contacts limit 1)","update fixture_contacts set v='private-test-value'"),
  ("insert into fixture_health values(now())","delete from fixture_health"),
  ("insert into fixture_logs values('private-test-log')","delete from fixture_logs"),
  ("create schema health_native_owned_fixture","drop schema health_native_owned_fixture"),
  ("alter table fixture_contacts add column extra integer","alter table fixture_contacts drop column extra"),
  ("alter table fixture_contacts add constraint fixture_check check(k<>'')","alter table fixture_contacts drop constraint fixture_check"),
  ("select nextval('fixture_sequence')","select setval('fixture_sequence',1,false)"),
 ]:
  before=snapshot();sql(change);check(snapshot()!=before);sql(undo)
  # A dropped column leaves real catalogue state; do not pretend to roll it back.
  check(snapshot()==before if 'add column' not in change else snapshot()!=before)
 sql("insert into v_pbx_restore values('00000000-0000-4000-8000-000000000001')")
 refused=subprocess.run(['php',str(script),'preservation'],env=env,capture_output=True).returncode!=0;check(refused)
 sql('drop table v_pbx_restore,fixture_contacts,fixture_health,fixture_logs;drop sequence fixture_sequence')
print(json.dumps({'state':'passed','actual_php_pdo_postgresql':True,'checks':checks,'source_sha256':hashlib.sha256(original.encode()).hexdigest(),'no_installed_database':True}))
