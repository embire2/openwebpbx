#!/usr/bin/env python3
"""Real isolated PostgreSQL + encrypted tenant archive recovery controls."""
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'packaging/debian'))
import backups as full
import protection as p

checks = 0

def check(ok, name):
    global checks
    if not ok:raise AssertionError(name)
    checks += 1

def rejects(fn, name):
    try:fn()
    except full.BackupError:check(True, name); return
    raise AssertionError(name)

settings = full.read_settings()
schema = 'backup125_' + uuid.uuid4().hex[:16]
original_env = full.database_environment
with tempfile.TemporaryDirectory(prefix='openweb-protection-tests-', dir='/var/lib/openwebpbx') as directory:
    root = Path(directory); root.chmod(0o700)
    full.query(settings, 'CREATE SCHEMA ' + p.ident(schema))
    full.database_environment = lambda s: original_env(s) | {'PGOPTIONS':'-c search_path='+schema+',public'}
    try:
        for sql in [
            'CREATE TABLE v_domains(domain_uuid uuid PRIMARY KEY,domain_name text)',
            'CREATE TABLE v_pbx_tenants(tenant_uuid uuid PRIMARY KEY,tenant_name text,home_domain_uuid uuid,owner_user_uuid uuid,enabled boolean)',
            'CREATE TABLE v_pbx_services(service_uuid uuid,tenant_uuid uuid,domain_uuid uuid)',
            'CREATE TABLE v_extensions(extension_uuid uuid PRIMARY KEY,domain_uuid uuid,extension text,password text,description text)',
            'CREATE TABLE v_pbx_templates(template_uuid uuid PRIMARY KEY,tenant_uuid uuid,payload_ciphertext text)',
            'CREATE TABLE v_pbx_media(media_uuid uuid PRIMARY KEY,domain_uuid uuid,file_path text)',
            'CREATE TABLE v_pbx_restore(domain_uuid uuid PRIMARY KEY,config jsonb)',
            'CREATE TABLE v_pbx_access_keys(key_uuid uuid PRIMARY KEY,domain_uuid uuid,token_hash text)',
            'CREATE TABLE v_pbx_callback_jobs(job_uuid uuid PRIMARY KEY,domain_uuid uuid,status text)',
            'CREATE TABLE v_pbx_service_entitlements(domain_uuid uuid PRIMARY KEY,plan_uuid uuid,extension_limit int,concurrent_calls int,extra_extensions int DEFAULT 0,extra_calls int DEFAULT 0,billable boolean DEFAULT false,restore_hold boolean DEFAULT false)',
            'CREATE TABLE v_pbx_tenant_restore_receipts(job_uuid uuid PRIMARY KEY,tenant_uuid uuid)',
            'CREATE TABLE v_pbx_mobile_accounts(account_uuid uuid PRIMARY KEY,domain_uuid uuid,extension_uuid uuid REFERENCES v_extensions(extension_uuid) ON DELETE CASCADE,password_hash text)',
            'CREATE TABLE v_pbx_mobile_devices(device_uuid uuid PRIMARY KEY,domain_uuid uuid,extension_uuid uuid REFERENCES v_extensions(extension_uuid) ON DELETE CASCADE,token_hash text,revoked_at timestamptz)',
            'CREATE TABLE v_pbx_mobile_enrollments(enrollment_uuid uuid PRIMARY KEY,domain_uuid uuid,extension_uuid uuid REFERENCES v_extensions(extension_uuid) ON DELETE CASCADE,ciphertext text)',
            'CREATE TABLE v_pbx_cmb_services(service_uuid uuid PRIMARY KEY,domain_uuid uuid,prompt_state text,enabled boolean,prompt_refresh_state text,prompt_refresh_token text,prompt_refresh_until timestamptz,prompt_refresh_after timestamptz,prompt_refresh_message text)',
            'CREATE TABLE v_pbx_cmb_accounts(account_uuid uuid PRIMARY KEY,domain_uuid uuid,service_uuid uuid REFERENCES v_pbx_cmb_services(service_uuid) ON DELETE CASCADE,used_seconds integer,reserved_seconds integer)',
            'CREATE TABLE v_pbx_cmb_bindings(binding_uuid uuid PRIMARY KEY,domain_uuid uuid,account_uuid uuid REFERENCES v_pbx_cmb_accounts(account_uuid) ON DELETE CASCADE,enabled boolean)',
            'CREATE TABLE v_xml_cdr(xml_cdr_uuid uuid PRIMARY KEY,domain_uuid uuid,billsec integer)',
            'CREATE TABLE v_user_settings(setting_uuid uuid PRIMARY KEY,domain_uuid uuid,secret_value text)',
            'CREATE TABLE v_api_keys(key_uuid uuid PRIMARY KEY,domain_uuid uuid,token_hash text)',
            'CREATE TABLE v_pbx_tenant_backups(backup_uuid uuid PRIMARY KEY,tenant_uuid uuid,requested_by uuid,filename text,status text,app_version text,size_bytes bigint,sha256 text,media_count integer,verified_at timestamptz,message text)',
            'CREATE TABLE v_users(user_uuid uuid PRIMARY KEY,domain_uuid uuid,user_enabled text)',
            'CREATE TABLE v_user_groups(user_uuid uuid,group_uuid uuid,domain_uuid uuid)',
            'CREATE TABLE v_group_permissions(group_uuid uuid,domain_uuid uuid,permission_name text,permission_assigned text)',
        ]:full.query(settings, sql)
        a,b,da,db,ea,eb = [str(uuid.uuid4()) for _ in range(6)]
        for tenant,domain,name,ext,eid in [(a,da,'alpha.example.invalid','100',ea),(b,db,'beta.example.invalid','200',eb)]:
            full.query(settings, 'INSERT INTO v_domains VALUES('+full.literal(domain)+','+full.literal(name)+')')
            full.query(settings, 'INSERT INTO v_pbx_tenants VALUES('+','.join(full.literal(x) for x in [tenant,name,domain,str(uuid.uuid4()),True])+')')
            full.query(settings, 'INSERT INTO v_pbx_services VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),tenant,domain])+')')
            full.query(settings, 'INSERT INTO v_extensions VALUES('+','.join(full.literal(x) for x in [eid,domain,ext,'fixture-password-'+ext,'original-'+ext])+')')
            full.query(settings, 'INSERT INTO v_pbx_templates VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),tenant,'fixture-encrypted-template'])+')')
        actor,group=[str(uuid.uuid4()) for _ in range(2)]
        full.query(settings,'INSERT INTO v_users VALUES('+','.join(full.literal(x) for x in [actor,da,'true'])+')')
        full.query(settings,'INSERT INTO v_user_groups VALUES('+','.join(full.literal(x) for x in [actor,group,db])+')')
        full.query(settings,'INSERT INTO v_group_permissions VALUES('+','.join(full.literal(x) for x in [group,None,'pbx_backup_instance','true'])+')')
        check(not p.permission(settings,actor,'pbx_backup_instance'),'root worker rejects foreign-domain role assignment')
        full.query(settings,'UPDATE v_user_groups SET domain_uuid=NULL;UPDATE v_group_permissions SET domain_uuid='+full.literal(db))
        check(not p.permission(settings,actor,'pbx_backup_instance'),'root worker rejects foreign-domain permission')
        full.query(settings,'UPDATE v_group_permissions SET domain_uuid=NULL')
        check(p.permission(settings,actor,'pbx_backup_instance'),'root worker accepts freshly granted valid instance permission')
        full.query(settings,"UPDATE v_users SET user_enabled='false'")
        check(not p.permission(settings,actor,'pbx_backup_instance'),'root worker rejects disabled operator despite group grant')
        full.MEDIA = {'storage':root/'storage','recordings':root/'recordings','custom-sounds':root/'sounds'}
        p.WORK = root/'work';p.WORK.mkdir()
        key_file = root/'key';key_file.write_bytes(os.urandom(32));key_file.chmod(0o600)
        media = root/'storage/openwebpbx'/da/'greetings/welcome.wav';media.parent.mkdir(parents=True);media.write_bytes(b'fixture-original-audio')
        full.query(settings, 'INSERT INTO v_pbx_media VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),da,str(media)])+')')
        key_id=str(uuid.uuid4());full.query(settings,'INSERT INTO v_pbx_access_keys VALUES('+','.join(full.literal(x) for x in [key_id,da,'fixture-current-api-key-hash'])+')')
        full.query(settings,'INSERT INTO v_pbx_callback_jobs VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),da,'completed'])+')')
        device,account,enrollment,service,callback,binding=[str(uuid.uuid4()) for _ in range(6)]
        full.query(settings,'INSERT INTO v_pbx_mobile_accounts VALUES('+','.join(full.literal(x) for x in [account,da,ea,'old-account-password'])+')')
        full.query(settings,'INSERT INTO v_pbx_mobile_devices VALUES('+','.join(full.literal(x) for x in [device,da,ea,'old-device-token'])+',NULL)')
        full.query(settings,'INSERT INTO v_pbx_mobile_enrollments VALUES('+','.join(full.literal(x) for x in [enrollment,da,ea,'old-QR-ciphertext'])+')')
        full.query(settings,'INSERT INTO v_pbx_cmb_services VALUES('+','.join(full.literal(x) for x in [service,da,'ready',True,'pending',None,None,None,''])+')')
        full.query(settings,'INSERT INTO v_pbx_cmb_accounts VALUES('+','.join(full.literal(x) for x in [callback,da,service,20,0])+')')
        full.query(settings,'INSERT INTO v_pbx_cmb_bindings VALUES('+','.join(full.literal(x) for x in [binding,da,callback,True])+')')
        full.query(settings,'INSERT INTO v_xml_cdr VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),da,10])+')')
        full.query(settings,'INSERT INTO v_user_settings VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),da,'current-user-setting'])+')')
        full.query(settings,'INSERT INTO v_api_keys VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),da,'current-legacy-API-key'])+')')
        callback_audio=root/'storage/openwebpbx/call-me-back'/service/'greeting.wav';callback_audio.parent.mkdir(parents=True);callback_audio.write_bytes(b'owned callback greeting')
        archive=root/'tenant.owtenant';password='fixture-backup-password-125'
        body=p.create_tenant(settings,a,archive,password,key_file=key_file,version='1.0.25')
        check(archive.is_file() and not b'fixture-password-100' in archive.read_bytes(),'encrypted phone credentials')
        check('v_pbx_access_keys' not in body['tables'] and 'v_pbx_service_entitlements' not in body['tables'],'identity and billing excluded')
        check('v_pbx_callback_jobs' not in body['tables'],'call execution queues excluded')
        check(set(r['domain_uuid'] for r in body['tables']['v_extensions'])=={da},'other tenant rows excluded')
        check(len(body['files'])==2,'owned custom and Call Me Back audio included')
        check(not set(body['tables']) & {'v_pbx_mobile_accounts','v_pbx_mobile_devices','v_pbx_mobile_enrollments','v_pbx_cmb_accounts','v_pbx_cmb_bindings','v_xml_cdr','v_api_keys','v_user_settings'},'app identity, usage, CDR and legacy keys excluded')
        with p.verified_tenant(settings,a,archive,password,key_file=key_file,version='1.0.25') as (_,verified):check(verified==body,'real encryption and independent verification')
        def verify(tenant=a,pw=password,source=archive,version='1.0.25',kf=key_file):
            with p.verified_tenant(settings,tenant,source,pw,key_file=kf,version=version):pass
        rejects(lambda:verify(pw='different-password'), 'wrong password refused')
        rejects(lambda:verify(tenant=b), 'cross-tenant restore refused')
        rejects(lambda:verify(version='1.0.26'), 'wrong release refused')
        foreign_key=root/'foreign-key';foreign_key.write_bytes(os.urandom(32))
        rejects(lambda:verify(kf=foreign_key),'foreign installation signing key refused')
        # Knowing an archive password does not allow a client to create an
        # authenticated database dump that edits another tenant or global data.
        plain=root/'plain.tar.gz';full.decrypt_file(archive,plain,password)
        forged=root/'forged.tar.gz'
        with tarfile.open(plain,'r:gz') as src,tarfile.open(forged,'w:gz') as dst:
            for member in src:
                data=src.extractfile(member).read()
                if member.name=='tenant.json':
                    data=json.loads(data);data['body']['tables']['v_extensions'][0]['password']='forged';data=p.canonical(data)
                member.size=len(data);dst.addfile(member,io.BytesIO(data))
        bad=root/'forged.owtenant';full.encrypt_file(forged,bad,password)
        rejects(lambda:verify(source=bad),'re-encrypted forged manifest refused')
        p.INBOX=root/'inbox';p.INBOX.mkdir();p.STORE=root/'tenant-store';p.STORE.mkdir();p.DOWNLOADS=root/'downloads';p.DOWNLOADS.mkdir()
        full.KEY=key_file;full.WEB_VERSION=root/'VERSION';full.WEB_VERSION.write_text('1.0.25')
        def upload(source):
            uid=str(uuid.uuid4());path=p.INBOX/(uid+'.upload');path.write_bytes(source.read_bytes())
            return {'upload_uuid':uid,'size':path.stat().st_size,'sha256':full.checksum(path)}
        request=upload(archive);imported=p.import_backup(settings,{'action':'tenant_import','tenant_uuid':a,'requested_by':str(uuid.uuid4()),'request':request},password)
        check(full.query(settings,'SELECT status FROM v_pbx_tenant_backups WHERE backup_uuid='+full.literal(imported))=='ready','actual encrypted upload import is verified before publication')
        check((p.DOWNLOADS/(imported+'.owtenant')).is_file() and not (p.INBOX/(request['upload_uuid']+'.upload')).exists(),'verified import downloadable and staging removed')
        request=upload(bad);rejects(lambda:p.import_backup(settings,{'action':'tenant_import','tenant_uuid':a,'requested_by':str(uuid.uuid4()),'request':request},password),'forged encrypted upload refused before publication')
        check(full.query(settings,'SELECT count(*) FROM v_pbx_tenant_backups')=='1','failed import creates no ready catalogue row')
        request=upload(archive);request['sha256']='0'*64
        rejects(lambda:p.receive_upload(request,root/'bad-checksum.copy'),'changed upload checksum refused')
        uid=str(uuid.uuid4());linked=p.INBOX/(uid+'.upload');linked.symlink_to(archive)
        rejects(lambda:p.receive_upload({'upload_uuid':uid,'size':archive.stat().st_size,'sha256':full.checksum(archive)},root/'linked.copy'),'linked upload refused')
        linked.unlink()
        uid=str(uuid.uuid4());linked=p.INBOX/(uid+'.upload');os.link(archive,linked)
        rejects(lambda:p.receive_upload({'upload_uuid':uid,'size':archive.stat().st_size,'sha256':full.checksum(archive)},root/'hardlinked.copy'),'hardlinked upload refused')
        full.query(settings,'UPDATE v_extensions SET description=\'changed-current\' WHERE domain_uuid='+full.literal(da))
        media.write_bytes(b'fixture-current-audio')
        full.query(settings,'UPDATE v_pbx_access_keys SET token_hash=\'still-current\' WHERE key_uuid='+full.literal(key_id))
        full.query(settings,"UPDATE v_pbx_mobile_accounts SET password_hash='current-account-password';UPDATE v_pbx_mobile_devices SET token_hash='current-revoked-token',revoked_at=now();UPDATE v_pbx_mobile_enrollments SET ciphertext='current-QR-ciphertext';UPDATE v_pbx_cmb_accounts SET used_seconds=80,reserved_seconds=7;UPDATE v_pbx_cmb_bindings SET enabled=false;")
        full.query(settings,'INSERT INTO v_xml_cdr VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),da,80])+')')
        p.restore_tenant(settings,a,archive,password,str(uuid.uuid4()),key_file=key_file,version='1.0.25',check_calls=False)
        check(full.query(settings,'SELECT description FROM v_extensions WHERE extension_uuid='+full.literal(ea))=='original-100','actual PostgreSQL restore')
        check(full.query(settings,'SELECT password FROM v_extensions WHERE extension_uuid='+full.literal(ea))=='fixture-password-100','original phone password preserved')
        check(full.query(settings,'SELECT description FROM v_extensions WHERE extension_uuid='+full.literal(eb))=='original-200','foreign tenant unchanged')
        check(media.read_bytes()==b'fixture-original-audio','actual media restore')
        check(full.query(settings,'SELECT token_hash FROM v_pbx_access_keys WHERE key_uuid='+full.literal(key_id))=='still-current','current API key unchanged')
        check(full.query(settings,'SELECT password_hash FROM v_pbx_mobile_accounts')=='current-account-password','current app password retained without FK cascade')
        check(full.query(settings,'SELECT token_hash||\':\'||(revoked_at is not null)::text FROM v_pbx_mobile_devices')=='current-revoked-token:true','revoked app device remains revoked')
        check(full.query(settings,'SELECT ciphertext FROM v_pbx_mobile_enrollments')=='current-QR-ciphertext','current stable QR binding retained')
        check(full.query(settings,"SELECT used_seconds::text||':'||reserved_seconds::text FROM v_pbx_cmb_accounts")=='80:7','consumed and reserved callback minutes retained')
        check(full.query(settings,'SELECT enabled FROM v_pbx_cmb_bindings')=='f','revoked callback caller authentication retained')
        check(full.query(settings,'SELECT sum(billsec) FROM v_xml_cdr')=='90','append-only billing call history retained')
        check(full.query(settings,'SELECT prompt_refresh_state FROM v_pbx_cmb_services')=='blocked','pending paid narration is not replayed')
        check(callback_audio.read_bytes()==b'owned callback greeting','Call Me Back narration media restored')
        check(full.query(settings,'SELECT count(*) FROM v_pbx_service_entitlements')=='0','legacy missing entitlement preserved')
        check(len(list(p.WORK.glob('restore-*/before.owtenant')))==1,'encrypted pre-restore recovery copy retained')
        # A database failure occurs AFTER media replacement and must put back
        # both current database state and current media without touching beta.
        full.query(settings,'UPDATE v_extensions SET description=\'before-failed-restore\' WHERE domain_uuid='+full.literal(da))
        media.write_bytes(b'current-before-failure')
        full.query(settings,"CREATE FUNCTION deny_fixture_restore() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture'; END $$")
        full.query(settings,'CREATE TRIGGER deny_fixture_restore BEFORE INSERT OR UPDATE ON v_extensions FOR EACH ROW EXECUTE FUNCTION deny_fixture_restore()')
        rejects(lambda:p.restore_tenant(settings,a,archive,password,str(uuid.uuid4()),key_file=key_file,version='1.0.25',check_calls=False),'actual database failure refused')
        check(full.query(settings,'SELECT description FROM v_extensions WHERE extension_uuid='+full.literal(ea))=='before-failed-restore','database failure rolls back current rows')
        check(media.read_bytes()==b'current-before-failure','database failure recovers current media')
        check(full.query(settings,'SELECT count(*) FROM v_pbx_service_entitlements')=='0','failed restore releases temporary holds')
        full.query(settings,'DROP TRIGGER deny_fixture_restore ON v_extensions')
        # Removing a newly added phone must not silently cascade-delete its
        # current app access or security records while rewinding configuration.
        extra=str(uuid.uuid4());full.query(settings,'INSERT INTO v_extensions VALUES('+','.join(full.literal(x) for x in [extra,da,'101','new-fixture-password','current extra phone'])+')')
        full.query(settings,'INSERT INTO v_pbx_mobile_devices VALUES('+','.join(full.literal(x) for x in [str(uuid.uuid4()),da,extra,'new-current-token'])+',NULL)')
        rejects(lambda:p.restore_tenant(settings,a,archive,password,str(uuid.uuid4()),key_file=key_file,version='1.0.25',check_calls=False),'protected new phone removal refused')
        check(full.query(settings,'SELECT count(*) FROM v_pbx_mobile_devices')=='2','foreign-to-snapshot current security rows survive refusal')
        full.query(settings,'DELETE FROM v_pbx_mobile_devices WHERE extension_uuid='+full.literal(extra)+';DELETE FROM v_extensions WHERE extension_uuid='+full.literal(extra))
        # A failed recovery must not reopen a tenant whose files are only
        # partially put back. A later successful recovery releases the hold.
        full.query(settings,'CREATE TRIGGER deny_fixture_restore BEFORE INSERT OR UPDATE ON v_extensions FOR EACH ROW EXECUTE FUNCTION deny_fixture_restore()')
        original_copy=full.atomic_copy
        def failed_recovery_copy(source,target,**kwargs):
            if Path(source).name.startswith('before-'):raise full.BackupError('Intentional recovery-copy failure in isolated fixture.')
            return original_copy(source,target,**kwargs)
        full.atomic_copy=failed_recovery_copy
        rejects(lambda:p.restore_tenant(settings,a,archive,password,str(uuid.uuid4()),key_file=key_file,version='1.0.25',check_calls=False),'failed file recovery is reported')
        full.atomic_copy=original_copy
        check(full.query(settings,'SELECT restore_hold FROM v_pbx_service_entitlements WHERE domain_uuid='+full.literal(da))=='t','failed file recovery keeps tenant calls held')
        p.recover_tenant_journals(settings)
        check(full.query(settings,'SELECT count(*) FROM v_pbx_service_entitlements')=='0','proven recovery releases only its temporary hold')
        full.query(settings,'DROP TRIGGER deny_fixture_restore ON v_extensions')
        # Restoring a retained extension at the exact package allowance must
        # update its existing UUID, not run a new-phone INSERT quota check.
        full.query(settings,'INSERT INTO v_pbx_service_entitlements(domain_uuid,extension_limit,concurrent_calls) VALUES('+full.literal(da)+',1,1)')
        full.query(settings,"CREATE FUNCTION fixture_extension_quota() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF (SELECT count(*) FROM v_extensions WHERE domain_uuid=NEW.domain_uuid)>=(SELECT extension_limit FROM v_pbx_service_entitlements WHERE domain_uuid=NEW.domain_uuid) THEN RAISE EXCEPTION 'fixture quota';END IF;RETURN NEW;END $$;CREATE TRIGGER fixture_extension_quota BEFORE INSERT ON v_extensions FOR EACH ROW EXECUTE FUNCTION fixture_extension_quota()")
        p.restore_tenant(settings,a,archive,password,str(uuid.uuid4()),key_file=key_file,version='1.0.25',check_calls=False)
        check(full.query(settings,'SELECT count(*) FROM v_extensions WHERE domain_uuid='+full.literal(da))=='1','retained extension restores at its exact authoritative allowance')
        full.query(settings,'UPDATE v_extensions SET domain_uuid='+full.literal(db)+' WHERE extension_uuid='+full.literal(ea))
        before_media=media.read_bytes()
        rejects(lambda:p.restore_tenant(settings,a,archive,password,str(uuid.uuid4()),key_file=key_file,version='1.0.25',check_calls=False),'old extension UUID now owned by another tenant refused')
        check(full.query(settings,'SELECT domain_uuid FROM v_extensions WHERE extension_uuid='+full.literal(ea))==db and media.read_bytes()==before_media,'foreign current extension and media untouched by UUID collision')
        full.query(settings,'UPDATE v_extensions SET domain_uuid='+full.literal(da)+' WHERE extension_uuid='+full.literal(ea))
        full.query(settings,'UPDATE v_pbx_cmb_services SET domain_uuid='+full.literal(db)+' WHERE service_uuid='+full.literal(service))
        callback_audio.write_bytes(b'foreign current callback greeting')
        rejects(lambda:p.restore_tenant(settings,a,archive,password,str(uuid.uuid4()),key_file=key_file,version='1.0.25',check_calls=False),'old callback UUID now owned by another tenant refused')
        check(callback_audio.read_bytes()==b'foreign current callback greeting','foreign callback media untouched before ownership rejection')
        full.query(settings,'UPDATE v_pbx_cmb_services SET domain_uuid='+full.literal(da)+' WHERE service_uuid='+full.literal(service))
        full.query(settings,'UPDATE v_pbx_service_entitlements SET extension_limit=0 WHERE domain_uuid='+full.literal(da))
        rejects(lambda:p.restore_tenant(settings,a,archive,password,str(uuid.uuid4()),key_file=key_file,version='1.0.25',check_calls=False),'current resource allowance enforced')
        # Ownership changes invalidate a previous scope, even with correct keys.
        full.query(settings,'UPDATE v_domains SET domain_name=\'renamed.example.invalid\' WHERE domain_uuid='+full.literal(da))
        rejects(verify,'changed domain identity refused')
        print('PASS:',checks,'real PostgreSQL/encryption/tenant isolation/recovery controls')
    finally:
        full.database_environment=original_env
        full.query(settings,'DROP SCHEMA '+p.ident(schema)+' CASCADE')
