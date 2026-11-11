#!/usr/bin/env python3
"""Server-authenticated, encrypted tenant recovery and confirmed instance recovery.

Tenant archives are deliberately bound to this installation and its unchanged
workspace/domain set. They never contain instance keys, portal administrator
accounts, API keys, service ownership, billing or subscription entitlements.
"""
import argparse
import contextlib
import datetime as dt
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import uuid

import backups as full

STORE = Path('/var/backups/openwebpbx/tenants')
DOWNLOADS = Path('/var/lib/openwebpbx/tenant-backup-downloads')
WORK = Path('/var/lib/openwebpbx/protection')
STATUS = Path('/var/lib/openwebpbx/protection-status')
INBOX = Path('/var/lib/openwebpbx/protection-inbox')
MAX_BYTES = 50 * 1000**3
MAX_ROWS = 500000
RESERVE = 10 * 1024**3
# Deliberate configuration allowlist. New application tables are never silently
# admitted to tenant restore: their ownership, authorisation and usage semantics
# must be reviewed first. Full-instance backups continue to include everything.
RESTORABLE = set('''v_bridges v_call_block v_call_center_agents v_call_center_queues v_call_center_tiers v_call_flows
v_conference_centers v_conference_rooms v_conferences v_contacts v_contact_addresses v_contact_attachments
v_contact_emails v_contact_groups v_contact_notes v_contact_phones v_contact_relations v_contact_settings
v_contact_times v_contact_urls v_destinations v_device_keys v_device_lines v_device_profile_keys
v_device_profile_settings v_device_profiles v_device_settings v_devices v_dialplan_details v_dialplans
v_domain_settings v_email_templates v_extension_settings v_extensions v_fax v_fifo v_fifo_members
v_follow_me v_follow_me_destinations v_gateways v_ivr_menu_options v_ivr_menus v_music_on_hold
v_paging_group_destinations v_paging_groups v_pbx_cmb_scripts v_pbx_cmb_services v_pbx_cmb_speed_dials
v_pbx_greeting_uses v_pbx_greetings v_pbx_media v_pbx_restore v_phrase_details v_phrases v_recordings
v_ring_group_destinations v_ring_group_users v_ring_groups v_streams v_voicemail_destinations
v_voicemail_greetings v_voicemail_messages v_voicemail_options v_voicemails'''.split())


def ident(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-z][a-z0-9_]{0,62}', value):
        raise full.BackupError('The tenant backup contains an unsupported table or column.')
    return '"' + value + '"'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def key(tenant, key_file=None):
    raw = full.ordinary(key_file or full.KEY).read_bytes()
    if len(raw) != 32:
        raise full.BackupError('Private backup signing is unavailable.')
    return hmac.new(raw, ('openwebpbx/tenant-backup/v1/' + tenant).encode(), hashlib.sha256).digest()


def disk_budget(path, needed):
    if needed < 0 or shutil.disk_usage(path).free < RESERVE + needed:
        raise full.BackupError('Not enough free storage to keep the server safety reserve. Download old copies before asking an administrator to clear space.')


def domain_scope(settings, tenant):
    tenant = str(uuid.UUID(tenant))
    rows = full.query(settings, "select coalesce(jsonb_agg(row_to_json(x)),'[]') from (select d.domain_uuid,d.domain_name from v_domains d where d.domain_uuid in (select home_domain_uuid from v_pbx_tenants where tenant_uuid=" + full.literal(tenant) + " union select domain_uuid from v_pbx_services where tenant_uuid=" + full.literal(tenant) + ') order by d.domain_uuid) x', json_result=True)
    if not rows:
        raise full.BackupError('This tenant has no restorable workspace.')
    for row in rows:
        row['domain_uuid'] = str(uuid.UUID(row['domain_uuid']))
        if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?', row['domain_name']) or '..' in row['domain_name']:
            raise full.BackupError('A tenant domain uses an unsupported storage name.')
        aliases = []
        if full.query(settings, "select to_regclass('v_pbx_sip_domains') is not null") == 't':
            aliases = full.query(settings, "select coalesce(jsonb_agg(sip_domain order by sip_domain),'[]') from v_pbx_sip_domains where domain_uuid=" + full.literal(row['domain_uuid']), json_result=True)
        for name in aliases:
            if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?', name) or '..' in name:
                raise full.BackupError('A tenant SIP address uses an unsupported storage name.')
        row['sip_names'] = aliases
    return rows


def table_inventory(settings):
    return full.query(settings, "select coalesce(jsonb_agg(c.table_name order by c.table_name),'[]') from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema=current_schema() and c.column_name='domain_uuid' and t.table_type='BASE TABLE' and left(c.table_name,2)='v_'", json_result=True)


def tables(settings):
    rows = table_inventory(settings)
    selected = [name for name in rows if name in RESTORABLE]
    if 'v_pbx_templates' not in selected:
        selected.append('v_pbx_templates')
    return sorted(selected)


def predicate(table, domains, tenant):
    if table == 'v_pbx_templates':
        return 'tenant_uuid=' + full.literal(tenant) + '::uuid'
    return 'domain_uuid in (' + ','.join(full.literal(d['domain_uuid']) + '::uuid' for d in domains) + ')'


def snapshot_rows(settings, tenant, domains):
    selected = tables(settings)
    statements = ["select " + full.literal(table) + " name,coalesce((select jsonb_agg(to_jsonb(t)) from " + ident(table) + ' t where ' + predicate(table, domains, tenant) + "),'[]') rows" for table in selected]
    rows = full.query(settings, 'select jsonb_object_agg(name,rows) from (' + ' union all '.join(statements) + ') export', json_result=True)
    if sum(len(data) for data in rows.values()) > MAX_ROWS:
        raise full.BackupError('This tenant exceeds the supported 500,000-row backup size. Use the full-instance backup instead.')
    return rows


def media_services(rows):
    return sorted(str(uuid.UUID(row['service_uuid'])) for row in rows.get('v_pbx_cmb_services',[]))


def owned_roots(domains, services=()):
    roots = []
    for d in domains:
        name, uid = d['domain_name'], d['domain_uuid']
        roots += [full.MEDIA['storage'] / 'openwebpbx' / uid,
                  full.MEDIA['recordings'] / uid, full.MEDIA['custom-sounds'] / uid]
        for storage_name in set([name] + d.get('sip_names', [])):
            roots += [full.MEDIA['storage'] / 'voicemail/default' / storage_name,
                      full.MEDIA['storage'] / 'voicemail' / storage_name,
                      full.MEDIA['recordings'] / storage_name]
    roots += [full.MEDIA['storage']/'openwebpbx/call-me-back'/str(uuid.UUID(service)) for service in services]
    return roots


def owned_path(path, domains, services=()):
    path = Path(path)
    if not path.is_absolute() or any(x.is_symlink() for x in (path, *path.parents)):
        raise full.BackupError('Tenant media must use ordinary files in this tenant’s storage folders.')
    if not any(path.is_relative_to(root) and path != root for root in owned_roots(domains,services)):
        raise full.BackupError('A tenant media file is outside its supported private storage folder.')
    return path


def inventory(domains, rows):
    paths = set();services=media_services(rows)
    for root in owned_roots(domains,services):
        if root.exists():
            if root.is_symlink() or not root.is_dir():
                raise full.BackupError('Tenant media storage must be an ordinary folder.')
            paths.update(p for p in root.rglob('*') if not p.is_dir())
    for row in rows.get('v_pbx_media', []):
        if row.get('file_path') and Path(row['file_path']).is_file():
            paths.add(owned_path(row['file_path'], domains,services))
    files = {}
    size = 0
    for i, path in enumerate(sorted(paths)):
        owned_path(path, domains,services)
        full.ordinary(path)
        s = path.stat()
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
            raise full.BackupError('Tenant backups refuse linked or special media files.')
        size += s.st_size
        if size > MAX_BYTES or i >= full.MAX_FILES:
            raise full.BackupError('Tenant media exceeds the supported backup size.')
        files['media/' + str(i)] = {'target': str(path), 'size': s.st_size, 'sha256': full.checksum(path),
                                   'mode': stat.S_IMODE(s.st_mode), 'mtime_ns': s.st_mtime_ns}
    return files


def create_tenant(settings, tenant, destination, password, *, key_file=None, version=None):
    domains = domain_scope(settings, tenant)
    rows = snapshot_rows(settings, tenant, domains)
    files = inventory(domains, rows)
    body = {'schema': 1, 'kind': 'openweb-tenant', 'tenant_uuid': tenant, 'domains': domains,
            'version': version or full.ordinary(full.WEB_VERSION).read_text().strip(),
            'source_host': settings.get('openweb.public_host', ''),
            'created_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'tables': rows, 'files': files, 'media_services':media_services(rows),
            'coverage':{'restored_tables':sorted(rows),'preserved_tables':sorted(set(table_inventory(settings))-set(rows))},
            'excluded': 'Instance keys, portal and app accounts, QR credentials, roles, API keys, ownership, billing, consumed callback minutes, caller authentication, call history and execution queues remain current.'}
    signed = {'body': body, 'signature': hmac.new(key(tenant, key_file), canonical(body), hashlib.sha256).hexdigest()}
    meta = canonical(signed)
    needed = len(meta) * 3 + sum(f['size'] for f in files.values()) * 3 + 8*1024**2
    disk_budget(destination.parent, needed)
    with tempfile.TemporaryDirectory(prefix='.tenant-create-', dir=destination.parent) as tmp:
        packed = Path(tmp) / 'payload.tar.gz'
        with tarfile.open(packed, 'w:gz', compresslevel=6) as archive:
            info = tarfile.TarInfo('tenant.json'); info.size = len(meta); info.mode = 0o600
            archive.addfile(info, io.BytesIO(meta))
            for name, entry in files.items():
                path = full.ordinary(entry['target']); before = path.stat()
                if before.st_size != entry['size'] or before.st_mtime_ns != entry['mtime_ns']:
                    raise full.BackupError('Media changed during the backup. Try again at a quieter time.')
                info = tarfile.TarInfo(name); info.size = entry['size']; info.mode = 0o600
                with path.open('rb') as stream:archive.addfile(info, stream)
                if path.stat().st_mtime_ns != before.st_mtime_ns or full.checksum(path) != entry['sha256']:
                    raise full.BackupError('Media changed during the backup. Try again at a quieter time.')
        full.encrypt_file(packed, destination, password)
    with verified_tenant(settings, tenant, destination, password, key_file=key_file, version=version) as (_, check):
        if check != body:raise full.BackupError('The completed tenant backup did not match its source.')
    return body


@contextlib.contextmanager
def verified_tenant(settings, tenant, source, password, *, key_file=None, version=None):
    full.ordinary(source)
    disk_budget(source.parent, source.stat().st_size * 2 + 8*1024**2)
    with tempfile.TemporaryDirectory(prefix='.tenant-check-', dir=source.parent) as tmp:
        tmp = Path(tmp); payload = tmp / 'payload.tar.gz'
        full.decrypt_file(source, payload, password)
        with tarfile.open(payload, 'r:gz') as archive:
            first = archive.next()
            if first is None or first.name != 'tenant.json' or not first.isfile() or not 1 <= first.size <= 64*1024**2:
                raise full.BackupError('The tenant backup inventory is invalid.')
            signed = json.load(archive.extractfile(first)); body = signed.get('body')
            if not isinstance(body, dict) or body.get('schema') != 1 or body.get('kind') != 'openweb-tenant' or body.get('tenant_uuid') != tenant:
                raise full.BackupError('This backup belongs to another tenant or is unsupported.')
            signature = hmac.new(key(tenant, key_file), canonical(body), hashlib.sha256).hexdigest()
            if not isinstance(signed.get('signature'), str) or not hmac.compare_digest(signed['signature'], signature):
                raise full.BackupError('This tenant backup was not signed by this installation.')
            installed = version or full.ordinary(full.WEB_VERSION).read_text().strip()
            if body.get('version') != installed or body.get('source_host') != settings.get('openweb.public_host', '') or body.get('domains') != domain_scope(settings, tenant):
                raise full.BackupError('Restore requires the same release, installation and unchanged tenant PBX addresses.')
            selected = tables(settings)
            if not isinstance(body.get('tables'), dict) or set(body['tables']) != set(selected):
                raise full.BackupError('The tenant database layout changed. Use a backup from this release and installation.')
            if any(not isinstance(data, list) for data in body['tables'].values()) or sum(map(len, body['tables'].values())) > MAX_ROWS:
                raise full.BackupError('The tenant backup row inventory is unsupported.')
            for table, records in body['tables'].items():
                for row in records:
                    if not isinstance(row, dict) or (row.get('tenant_uuid') != tenant if table == 'v_pbx_templates' else row.get('domain_uuid') not in [d['domain_uuid'] for d in body['domains']]):
                        raise full.BackupError('The tenant backup contains records outside its workspace.')
            if body.get('media_services')!=media_services(body['tables']):raise full.BackupError('The Call Me Back media inventory is not owned by this tenant.')
            files = body.get('files'); seen = set(); total = 0
            if not isinstance(files, dict) or len(files) > full.MAX_FILES:raise full.BackupError('The media inventory is unsupported.')
            for name, entry in files.items():
                if not re.fullmatch(r'media/[0-9]+', name) or not isinstance(entry, dict) or type(entry.get('size')) is not int or not 0 <= entry['size'] <= MAX_BYTES or not re.fullmatch('[a-f0-9]{64}', str(entry.get('sha256', ''))):
                    raise full.BackupError('The media inventory is invalid.')
                owned_path(entry.get('target', ''), body['domains'],body['media_services']); total += entry['size']
            if total > MAX_BYTES:raise full.BackupError('Tenant media exceeds the supported backup size.')
            disk_budget(source.parent, total + payload.stat().st_size + 8*1024**2)
            while member := archive.next():
                entry = files.get(member.name)
                if not entry or member.name in seen or not member.isfile() or member.issym() or member.islnk() or member.sparse or member.size != entry['size']:
                    raise full.BackupError('The tenant backup contains unexpected, linked or damaged media.')
                seen.add(member.name); target = tmp / member.name; target.parent.mkdir(exist_ok=True)
                with archive.extractfile(member) as src, target.open('xb') as out:shutil.copyfileobj(src, out, full.CHUNK)
                if full.checksum(target) != entry['sha256']:raise full.BackupError('A tenant media file failed its integrity check.')
            if seen != set(files):raise full.BackupError('The tenant backup is missing media.')
        yield tmp, body


def order_tables(settings, selected):
    edges = full.query(settings, "select coalesce(jsonb_agg(jsonb_build_array(child.relname,parent.relname)),'[]') from pg_constraint c join pg_class child on child.oid=c.conrelid join pg_namespace n on n.oid=child.relnamespace join pg_class parent on parent.oid=c.confrelid where c.contype='f' and n.nspname=current_schema()", json_result=True)
    remaining = set(selected); result = []
    while remaining:
        ready = sorted(t for t in remaining if not any(c == t and p in remaining and p != t for c,p in edges))
        if not ready:raise full.BackupError('The tenant tables contain circular dependencies. Use a full-instance restore instead.')
        result += ready; remaining -= set(ready)
    return result


def document_query(settings,sql):
    """Large signed JSON is stdin/file data, never an oversized process argv."""
    with tempfile.NamedTemporaryFile(mode='w',dir=WORK,prefix='.tenant-query-',delete=False) as stream:
        path=Path(stream.name);stream.write('SET standard_conforming_strings=on;\n'+sql);stream.flush();os.fsync(stream.fileno())
    try:return full.run(full.database_command(settings)+['-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-f',str(path)],env=full.database_environment(settings),timeout=60).decode().strip()
    finally:path.unlink(missing_ok=True)


def primary_keys(settings):
    return full.query(settings,"select coalesce(jsonb_object_agg(name,columns),'{}') from (select cl.relname name,jsonb_agg(a.attname order by k.ord) columns from pg_constraint c join pg_class cl on cl.oid=c.conrelid join pg_namespace n on n.oid=cl.relnamespace cross join lateral unnest(c.conkey) with ordinality k(num,ord) join pg_attribute a on a.attrelid=cl.oid and a.attnum=k.num where c.contype='p' and n.nspname=current_schema() group by cl.relname) p",json_result=True)


def current_ownership(settings,tenant,body):
    primary=primary_keys(settings);checks=[]
    for table,rows in body['tables'].items():
        keys=primary.get(table)
        if not keys:raise full.BackupError('A configuration table has no stable identity. Use full-instance recovery instead.')
        if not rows:continue
        data=full.literal(json.dumps([{k:row[k] for k in keys} for row in rows]))
        join=' AND '.join('s.'+ident(k)+'=p.'+ident(k) for k in keys)
        scope=predicate(table,body['domains'],tenant).replace('domain_uuid','p.domain_uuid').replace('tenant_uuid','p.tenant_uuid')
        checks.append('SELECT 1 FROM '+ident(table)+' p JOIN jsonb_populate_recordset(NULL::'+ident(table)+','+data+'::jsonb) s ON '+join+' WHERE ('+scope+') IS NOT TRUE')
    if checks and document_query(settings,'SELECT EXISTS(SELECT 1 FROM ('+' UNION ALL '.join(checks)+') collisions);')=='t':
        raise full.BackupError('A phone or service from this older backup now belongs to another tenant. This restore cannot replace another tenant’s records or media.')


def apply_rows(settings, tenant, body, job):
    selected = order_tables(settings, body['tables']); domains = body['domains']
    primary = primary_keys(settings)
    columns = full.query(settings,"select coalesce(jsonb_object_agg(name,columns),'{}') from (select table_name name,jsonb_agg(column_name order by ordinal_position) columns from information_schema.columns where table_schema=current_schema() and is_generated='NEVER' group by table_name) c",json_result=True)
    foreign = full.query(settings,"select coalesce(jsonb_agg(row_to_json(x)),'[]') from (select child.relname child,parent.relname parent,jsonb_agg(ca.attname order by k.ord) child_columns,jsonb_agg(pa.attname order by k.ord) parent_columns from pg_constraint c join pg_class child on child.oid=c.conrelid join pg_namespace n on n.oid=child.relnamespace join pg_class parent on parent.oid=c.confrelid cross join lateral unnest(c.conkey,c.confkey) with ordinality k(cnum,pnum,ord) join pg_attribute ca on ca.attrelid=child.oid and ca.attnum=k.cnum join pg_attribute pa on pa.attrelid=parent.oid and pa.attnum=k.pnum where c.contype='f' and n.nspname=current_schema() group by c.oid,child.relname,parent.relname) x",json_result=True)
    stages = {table:'openweb_restore_'+str(i) for i,table in enumerate(selected)}
    commands = ['SET standard_conforming_strings=on;','BEGIN ISOLATION LEVEL REPEATABLE READ;','SET CONSTRAINTS ALL DEFERRED;',"SELECT pg_advisory_xact_lock(741103125);"]
    commands += ['LOCK TABLE ' + ident(t) + ' IN SHARE ROW EXCLUSIVE MODE;' for t in sorted(selected)]
    for table in selected:
        if not primary.get(table):raise full.BackupError('A tenant configuration table has no stable identity. Use a full-instance restore instead.')
        records=body['tables'][table]
        if table=='v_pbx_greetings':records=[dict(row,state='cancelled',call_uuid=None,lease_until=None,last_result='Waiting request cancelled during tenant restore.') if row.get('state') in ('pending','preparing','ready_to_call','calling') else row for row in records]
        if table=='v_pbx_cmb_services':
            records=[dict(row,prompt_state='failed',enabled=False,prompt_refresh_state='blocked',prompt_refresh_token=None,prompt_refresh_until=None,prompt_refresh_after=None,prompt_refresh_message='Waiting narration cancelled during tenant restore.') if row.get('prompt_state') in ('pending','generating') else dict(row,prompt_refresh_state='blocked',prompt_refresh_token=None,prompt_refresh_until=None,prompt_refresh_after=None,prompt_refresh_message='Waiting narration cancelled during tenant restore.') if row.get('prompt_refresh_state') in ('pending','preparing') else row for row in records]
        stage=ident(stages[table]);commands.append('CREATE TEMP TABLE '+stage+' ON COMMIT DROP AS SELECT * FROM '+ident(table)+' WITH NO DATA;')
        if records:commands.append('INSERT INTO '+stage+' SELECT * FROM jsonb_populate_recordset(NULL::'+ident(table)+','+full.literal(json.dumps(records,ensure_ascii=False))+'::jsonb);')
        scope=predicate(table,domains,tenant).replace('domain_uuid','p.domain_uuid').replace('tenant_uuid','p.tenant_uuid')
        join=' AND '.join('s.'+ident(k)+'=p.'+ident(k) for k in primary[table])
        commands.append('DO $$ BEGIN IF EXISTS(SELECT 1 FROM '+ident(table)+' p JOIN '+stage+' s ON '+join+' WHERE ('+scope+") IS NOT TRUE) THEN RAISE EXCEPTION 'A restored record now belongs to another tenant. Restore cancelled.';END IF;END $$;")
    # Do not cascade-delete a current app identity, revoked token, staff role,
    # consumed-minute account or execution queue while replacing configuration.
    # Retained UUIDs are updated in place; removing a referenced parent requires
    # a deliberate ordinary account/job removal first.
    for edge in foreign:
        parent,child=edge['parent'],edge['child']
        if parent not in stages or child in stages:continue
        join=' AND '.join('c.'+ident(c)+'=p.'+ident(p) for c,p in zip(edge['child_columns'],edge['parent_columns']))
        retained=' AND '.join('s.'+ident(k)+'=p.'+ident(k) for k in primary[parent])
        owned=predicate(parent,domains,tenant).replace('domain_uuid','p.domain_uuid').replace('tenant_uuid','p.tenant_uuid')
        source=full.literal(json.dumps(body['tables'][parent],ensure_ascii=False))
        if document_query(settings,'SELECT EXISTS(SELECT 1 FROM '+ident(child)+' c JOIN '+ident(parent)+' p ON '+join+' WHERE '+owned+' AND NOT EXISTS(SELECT 1 FROM jsonb_populate_recordset(NULL::'+ident(parent)+','+source+'::jsonb) s WHERE '+retained+'));')=='t':
            raise full.BackupError('This backup would remove a phone or service with current account access, usage or waiting actions. Remove those accounts or cancel those actions normally before restoring.')
        commands.append('DO $$ BEGIN IF EXISTS(SELECT 1 FROM '+ident(child)+' c JOIN '+ident(parent)+' p ON '+join+' WHERE '+predicate(parent,domains,tenant).replace('domain_uuid','p.domain_uuid').replace('tenant_uuid','p.tenant_uuid')+' AND NOT EXISTS(SELECT 1 FROM '+ident(stages[parent])+' s WHERE '+retained+")) THEN RAISE EXCEPTION 'This backup would remove a phone or service with current account access, usage or queued actions. Remove those accounts or cancel those actions normally before restoring.'; END IF; END $$;")
    protected=[]
    for edge in foreign:
        parent,child=edge['parent'],edge['child']
        if parent not in stages or child in stages:continue
        join=' AND '.join('c.'+ident(c)+'=p.'+ident(p) for c,p in zip(edge['child_columns'],edge['parent_columns']))
        scope=predicate(parent,domains,tenant).replace('domain_uuid','p.domain_uuid').replace('tenant_uuid','p.tenant_uuid')
        stage='openweb_protected_'+str(len(protected));protected.append((stage,child))
        commands.append('CREATE TEMP TABLE '+ident(stage)+' ON COMMIT DROP AS SELECT c.* FROM '+ident(child)+' c WHERE EXISTS(SELECT 1 FROM '+ident(parent)+' p WHERE '+join+' AND '+scope+');')
    # Remove only configuration absent from the archive. Updating retained
    # identities in place avoids ON DELETE CASCADE and avoids INSERT quota
    # checks being applied to an existing phone at its package allowance.
    for table in reversed(selected):
        match=' AND '.join('s.'+ident(k)+'=p.'+ident(k) for k in primary[table])
        condition=predicate(table,domains,tenant).replace('domain_uuid','p.domain_uuid').replace('tenant_uuid','p.tenant_uuid')
        commands.append('DELETE FROM '+ident(table)+' p WHERE '+condition+' AND NOT EXISTS(SELECT 1 FROM '+ident(stages[table])+' s WHERE '+match+');')
    for table in selected:
        names=columns[table];keys=primary[table];updates=[name for name in names if name not in keys]
        match=' AND '.join('s.'+ident(k)+'=p.'+ident(k) for k in keys)
        scope=predicate(table,domains,tenant).replace('domain_uuid','p.domain_uuid').replace('tenant_uuid','p.tenant_uuid')
        if updates:commands.append('UPDATE '+ident(table)+' p SET '+','.join(ident(c)+'=s.'+ident(c) for c in updates)+' FROM '+ident(stages[table])+' s WHERE '+match+' AND '+scope+';')
        commands.append('INSERT INTO '+ident(table)+'('+','.join(ident(c) for c in names)+') SELECT '+','.join('s.'+ident(c) for c in names)+' FROM '+ident(stages[table])+' s WHERE NOT EXISTS(SELECT 1 FROM '+ident(table)+' p WHERE '+match+');')
    # Also defend against indirect cascades through retained configuration
    # children: every current protected dependent must survive byte-for-byte.
    for stage,child in protected:
        commands.append('DO $$ BEGIN IF EXISTS(SELECT 1 FROM '+ident(stage)+' old WHERE NOT EXISTS(SELECT 1 FROM '+ident(child)+" current WHERE to_jsonb(current)=to_jsonb(old))) THEN RAISE EXCEPTION 'Current account, authorisation, history or usage rows would change. This tenant restore was cancelled.'; END IF; END $$;")
    commands.append('INSERT INTO v_pbx_tenant_restore_receipts(job_uuid,tenant_uuid) VALUES('+full.literal(job)+','+full.literal(tenant)+');')
    commands.append('COMMIT;')
    with tempfile.NamedTemporaryFile(mode='w',dir=WORK,prefix='.tenant-sql-',delete=False) as stream:
        sql=Path(stream.name);stream.write('\n'.join(commands));stream.flush();os.fsync(stream.fileno())
    try:full.run(full.database_command(settings)+['-X','-q','-v','ON_ERROR_STOP=1','-f',str(sql)],env=full.database_environment(settings),timeout=300)
    finally:sql.unlink(missing_ok=True)


def active_calls(domains):
    raw = full.run(['fs_cli','-x','show channels as json'], timeout=15)
    try:rows = json.loads(raw).get('rows', [])
    except (ValueError, AttributeError):raise full.BackupError('Cannot confirm that tenant calls are idle. Retry after call monitoring is available.') from None
    names = {d['domain_name'] for d in domains}; ids = {d['domain_uuid'] for d in domains}
    # Domain context may be absent from show-channels on some profiles. Check
    # each active channel's authoritative variables instead of guessing by CLI.
    for row in rows:
        channel = str(uuid.UUID(row['uuid']))
        for variable in ('domain_uuid', 'domain_name'):
            value = full.run(['fs_cli','-x','uuid_getvar ' + channel + ' ' + variable], timeout=15).decode().strip()
            if value in names | ids:raise full.BackupError('This tenant still has active calls. Wait for them to end before restoring.')


def hold(settings, domains, enabled, temporary=()):
    ids = ','.join(full.literal(d['domain_uuid']) + '::uuid' for d in domains)
    if enabled:
        full.query(settings, 'insert into v_pbx_service_entitlements(domain_uuid,extension_limit,concurrent_calls,restore_hold) select domain_uuid,10000,10000,true from v_domains where domain_uuid in (' + ids + ') on conflict(domain_uuid) do update set restore_hold=true')
    else:
        full.query(settings, 'update v_pbx_service_entitlements set restore_hold=false where domain_uuid in (' + ids + ')')
        if temporary:
            # Remove only our unchanged temporary guard, preserving the absence
            # of an entitlement on legacy services after recovery.
            full.query(settings, 'delete from v_pbx_service_entitlements where domain_uuid in (' + ','.join(full.literal(x) + '::uuid' for x in temporary) + ') and plan_uuid is null and extension_limit=10000 and concurrent_calls=10000 and extra_extensions=0 and extra_calls=0 and not billable and not restore_hold')


def recover_tenant_journals(settings):
    for journal_path in WORK.glob('restore-*/journal.json'):
        full.ordinary(journal_path); journal = json.loads(journal_path.read_text())
        if journal.get('state') in ('completed','recovered'):continue
        committed = full.query(settings, 'select exists(select 1 from v_pbx_tenant_restore_receipts where job_uuid=' + full.literal(str(uuid.UUID(journal['job_uuid']))) + ')') == 't'
        if not committed:
            for target, entry in journal['original'].items():
                path = owned_path(target, journal['domains'],journal.get('media_services',[]))
                if entry['exists']:
                    full.atomic_copy(journal_path.parent / entry['copy'], path, mode=entry['mode'], group=entry['gid'])
                    if os.geteuid()==0:os.chown(path,entry['uid'],entry['gid'])
                else:path.unlink(missing_ok=True)
        journal['state'] = 'completed' if committed else 'recovered'; full.atomic_json(journal_path, journal)
        hold(settings, journal['domains'], False, journal.get('temporary_entitlements', []))


def restore_tenant(settings, tenant, source, password, job, *, key_file=None, version=None, check_calls=True):
    with verified_tenant(settings, tenant, source, password, key_file=key_file, version=version) as (extracted, body):
        domains = body['domains']; selected = order_tables(settings, body['tables'])
        current_ownership(settings,tenant,body)
        if any(full.query(settings, 'select restore_hold from v_pbx_service_entitlements where domain_uuid=' + full.literal(d['domain_uuid'])) == 't' for d in domains):
            raise full.BackupError('This tenant already has a recovery hold. Ask the instance administrator to complete that recovery first.')
        # A lower subscription cannot be bypassed by restoring an older larger PBX.
        for domain in domains:
            count = sum(r.get('domain_uuid') == domain['domain_uuid'] for r in body['tables'].get('v_extensions', []))
            maximum = full.query(settings, 'select extension_limit+extra_extensions from v_pbx_service_entitlements where domain_uuid=' + full.literal(domain['domain_uuid']))
            if maximum and count > int(maximum):raise full.BackupError('The backup exceeds this PBX’s current extension allowance. Add capacity first.')
        recovery = WORK / ('restore-' + str(uuid.UUID(job))); recovery.mkdir(mode=0o700)
        temporary = [d['domain_uuid'] for d in domains if full.query(settings, 'select exists(select 1 from v_pbx_service_entitlements where domain_uuid=' + full.literal(d['domain_uuid']) + ')') != 't']
        journal = {'job_uuid':job,'tenant_uuid':tenant,'domains':domains,'media_services':body['media_services'],'state':'preparing','original':{},'temporary_entitlements':temporary}
        full.atomic_json(recovery/'journal.json', journal)
        hold(settings, domains, True)
        try:
            if check_calls:active_calls(domains)
            before = recovery / 'before.owtenant'
            create_tenant(settings, tenant, before, password, key_file=key_file, version=version)
            original = {}
            for i, entry in enumerate(body['files'].values()):
                target = owned_path(entry['target'], domains,body['media_services']); original[str(target)] = {'exists':target.exists()}
                if target.exists():
                    full.ordinary(target); info = target.stat(); copy = recovery / ('before-' + str(i)); shutil.copyfile(target, copy); copy.chmod(0o600)
                    original[str(target)].update({'copy':copy.name,'mode':stat.S_IMODE(info.st_mode),'uid':info.st_uid,'gid':info.st_gid})
            journal.update({'state':'prepared','original':original})
            full.atomic_json(recovery/'journal.json', journal)
            try:
                for name, entry in body['files'].items():
                    full.atomic_copy(extracted/name, owned_path(entry['target'], domains,body['media_services']), mode=entry['mode'] & 0o660 or 0o640, group=33)
                apply_rows(settings, tenant, body, job)
                journal['state'] = 'completed'; full.atomic_json(recovery/'journal.json', journal)
            except BaseException:
                recover_tenant_journals(settings)
                raise
            if check_calls:full.run(['fs_cli','-x','reloadxml'], timeout=30)
        finally:
            # A failed file rollback must leave calls held until an operator
            # proves recovery. Never release a partially recovered tenant.
            try:state=json.loads((recovery/'journal.json').read_text()).get('state')
            except (OSError,ValueError):state=None
            if state in ('preparing','completed','recovered'):hold(settings, domains, False, temporary)
        return body


def permission(settings, actor, name):
    return full.query(settings, "select exists(select 1 from v_users u join v_user_groups g using(user_uuid) join v_group_permissions p using(group_uuid) where u.user_uuid=" + full.literal(actor) + " and u.user_enabled='true' and p.permission_name=" + full.literal(name) + " and p.permission_assigned='true' and (g.domain_uuid is null or g.domain_uuid=u.domain_uuid) and (p.domain_uuid is null or p.domain_uuid=u.domain_uuid))") == 't'


def authorized_job(settings, job):
    actor = str(uuid.UUID(job['requested_by']))
    if job['action'].startswith('instance_'):
        if job.get('tenant_uuid') is not None or not permission(settings, actor, 'pbx_backup_instance'):raise full.BackupError('Instance backup permission was withdrawn.')
    else:
        tenant = str(uuid.UUID(job['tenant_uuid']))
        workspace = full.query(settings, 'select row_to_json(t) from v_pbx_tenants t where tenant_uuid=' + full.literal(tenant) + ' and enabled',json_result=True)
        own = workspace and workspace['owner_user_uuid'] == actor
        reseller = workspace and workspace.get('reseller_user_uuid') == actor and permission(settings,actor,'pbx_reseller_manage') and full.query(settings,'select exists(select 1 from v_pbx_tenants where owner_user_uuid='+full.literal(actor)+' and enabled)') == 't'
        if not workspace or not ((own or reseller) and permission(settings, actor, 'pbx_tenant_backup') or permission(settings, actor, 'pbx_backup_instance')):raise full.BackupError('Tenant backup permission was withdrawn.')


def instance_receipt(job, state, message):
    path = STATUS/(str(uuid.UUID(job['job_uuid']))+'.json')
    full.atomic_json(path, {'job_uuid':job['job_uuid'],'action':job['action'],'backup_uuid':job.get('backup_uuid'),
                           'status':state,'message':message,'created_at':job['created_at'],
                           'finished_at':dt.datetime.now(dt.timezone.utc).isoformat() if state != 'running' else None})
    path.chmod(0o640)
    if os.geteuid() == 0:os.chown(path,0,33)


def archive_completed_instance_restore(job):
    # Retain the full pre-restore recovery material without making the next
    # dashboard restore mistake a completed journal for an interrupted one.
    with full.exclusive_guard(full.UPGRADE_LOCK), full.exclusive_guard(full.STORE/'worker.lock'):
        journal = json.loads(full.ordinary(full.RESTORE/'journal.json').read_text())
        if journal.get('state') != 'restored' or any(full.RESTORE.glob('hold-*')):
            raise full.BackupError('The restored server still has a service hold. Review the protected restore journal before continuing.')
        history = full.safe_private_directory(WORK/'instance-history')
        target = history/str(uuid.UUID(job['job_uuid']))
        if target.exists():raise full.BackupError('The completed recovery journal already exists. Ask the administrator to review it.')
        os.replace(full.RESTORE,target)
        full.sync_directory(history)


def receive_upload(request, destination):
    upload = str(uuid.UUID(request['upload_uuid'])); source = INBOX/(upload+'.upload')
    if type(request.get('size')) is not int or not 52 <= request['size'] <= 2*1024**3 or not re.fullmatch('[a-f0-9]{64}', str(request.get('sha256',''))):
        raise full.BackupError('The uploaded backup inventory is invalid.')
    disk_budget(destination.parent, request['size'] * 2 + 8*1024**2)
    if any(path.is_symlink() for path in (INBOX,*INBOX.parents)):
        raise full.BackupError('The protected upload folder needs administrator review.')
    if destination.exists() or destination.is_symlink():raise full.BackupError('The private upload target already exists. Request a new upload.')
    try:descriptor = os.open(source, os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    except OSError:raise full.BackupError('The protected uploaded file is unavailable or linked. Upload the saved copy again.') from None
    created = False
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size != request['size']:
            raise full.BackupError('The uploaded file changed or is not an ordinary encrypted backup.')
        digest = hashlib.sha256()
        with os.fdopen(descriptor, 'rb', closefd=False) as incoming:
            outgoing = destination.open('xb');created = True
            with outgoing:
                count = 0
                while chunk := incoming.read(full.CHUNK):
                    count += len(chunk)
                    if count > request['size']:raise full.BackupError('The uploaded file changed size.')
                    disk_budget(destination.parent,len(chunk))
                    digest.update(chunk); outgoing.write(chunk)
                outgoing.flush();os.fsync(outgoing.fileno())
        after = os.fstat(descriptor)
        if (before.st_ino,before.st_size,before.st_mtime_ns)!=(after.st_ino,after.st_size,after.st_mtime_ns) or count != request['size'] or not hmac.compare_digest(digest.hexdigest(),request['sha256']):
            raise full.BackupError('The upload changed before it could be checked. Upload the saved copy again.')
        destination.chmod(0o600)
        full.sync_directory(destination.parent)
    except BaseException:
        if created:destination.unlink(missing_ok=True)
        raise
    finally:
        os.close(descriptor);source.unlink(missing_ok=True)


def import_backup(settings, job, password):
    instance = job['action']=='instance_import';tenant=job.get('tenant_uuid');bid=str(uuid.uuid4())
    directory=full.safe_private_directory(full.STORE) if instance else STORE
    source=directory/(bid+('.owpbx' if instance else '.owtenant'))
    try:
        receive_upload(job['request'],source)
        if instance:
            manifest=full.restore(source,password,settings,dry_run=True,allow_existing=True)
            full.publish_download(source,full.safe_private_directory(full.DOWNLOADS,group=33)/source.name)
            full.query(settings,'insert into v_pbx_backups(backup_uuid,filename,status,include_media,app_version,size_bytes,sha256,remote_status,message,completed_at,verified_at) values('+','.join(full.literal(v) for v in [bid,source.name,'ready',manifest['include_media'],manifest['version'],source.stat().st_size,full.checksum(source),'disabled','Uploaded full-instance backup checked.'])+',now(),now())')
        else:
            with verified_tenant(settings,tenant,source,password) as (_,manifest):pass
            full.publish_download(source,DOWNLOADS/source.name)
            full.query(settings,'insert into v_pbx_tenant_backups(backup_uuid,tenant_uuid,requested_by,filename,status,app_version,size_bytes,sha256,media_count,verified_at,message) values('+','.join(full.literal(v) for v in [bid,tenant,job['requested_by'],source.name,'ready',manifest['version'],source.stat().st_size,full.checksum(source),len(manifest['files'])])+",now(),'Uploaded tenant settings and media checked.')")
        return bid
    except BaseException:
        source.unlink(missing_ok=True)
        (full.DOWNLOADS/source.name if instance else DOWNLOADS/source.name).unlink(missing_ok=True)
        raise


def worker(settings):
    full.safe_private_directory(STORE); full.safe_private_directory(DOWNLOADS, group=33); full.safe_private_directory(WORK); full.safe_private_directory(STATUS,group=33)
    with full.exclusive_guard(WORK/'worker.lock'):
        recover_tenant_journals(settings)
        for receipt in STATUS.glob('*.json'):
            data=json.loads(full.ordinary(receipt).read_text())
            if data.get('status')=='running':instance_receipt(data,'failed','The recovery worker stopped. Ask the administrator to review the protected recovery journal before retrying.')
        full.query(settings, "update v_pbx_protection_jobs set status='failed',secret_ciphertext='',message='The recovery worker stopped. Review its recovery result before retrying.',finished_at=now() where status='running'")
        command = full.query(settings, "with next as(select job_uuid from v_pbx_protection_jobs where status='pending' order by created_at limit 1 for update skip locked) update v_pbx_protection_jobs j set status='running',started_at=now(),message='Backup operation is running.' from next where j.job_uuid=next.job_uuid returning row_to_json(j)")
        if not command:return
        job = json.loads(command); jid = str(uuid.UUID(job['job_uuid']))
        backup_id = None
        try:
            authorized_job(settings, job); password = full.unseal(job['secret_ciphertext']); action = job['action']; tenant = job.get('tenant_uuid')
            if action in ('tenant_import','instance_import'):
                if action=='instance_import':instance_receipt(job,'running','The uploaded full-instance backup is being checked.')
                with full.exclusive_guard(full.UPGRADE_LOCK) if action=='tenant_import' else contextlib.nullcontext():backup_id=import_backup(settings,job,password)
                message='Uploaded backup checked and added to saved backups. Choose Check backup before confirming a restore.'
            elif action == 'tenant_create':
                backup_id = str(uuid.uuid4()); source = STORE/(backup_id+'.owtenant'); installed = full.ordinary(full.WEB_VERSION).read_text().strip()
                full.query(settings, 'insert into v_pbx_tenant_backups(backup_uuid,tenant_uuid,requested_by,filename,status,app_version) values(' + ','.join(full.literal(v) for v in (backup_id,tenant,job['requested_by'],source.name,'creating',installed)) + ')')
                with full.exclusive_guard(full.UPGRADE_LOCK):body = create_tenant(settings, tenant, source, password)
                full.publish_download(source, DOWNLOADS/source.name)
                full.query(settings, "update v_pbx_tenant_backups set status='ready',size_bytes=" + str(source.stat().st_size) + ',sha256=' + full.literal(full.checksum(source)) + ',media_count=' + str(len(body['files'])) + ",verified_at=now(),message='Encrypted tenant settings and media completed and checked.' where backup_uuid=" + full.literal(backup_id))
                message = 'Tenant settings and media are backed up. Download a copy and keep the password separately.'
            elif action.startswith('tenant_'):
                backup_id = str(uuid.UUID(job['backup_uuid']))
                row = full.query(settings, 'select row_to_json(b) from v_pbx_tenant_backups b where backup_uuid=' + full.literal(backup_id) + ' and tenant_uuid=' + full.literal(tenant), json_result=True)
                source = STORE/(backup_id+'.owtenant')
                if not row or row['status'] != 'ready' or row['filename'] != source.name or full.checksum(full.ordinary(source)) != row['sha256']:raise full.BackupError('The selected tenant backup is unavailable or changed.')
                if action == 'tenant_verify':
                    with verified_tenant(settings, tenant, source, password) as (_, body):pass
                    full.query(settings, 'update v_pbx_tenant_backups set verified_at=now() where backup_uuid=' + full.literal(backup_id))
                    message = 'Backup checked: ' + str(sum(map(len, body['tables'].values()))) + ' PBX records and ' + str(len(body['files'])) + ' media files. ' + str(len(body['coverage']['preserved_tables'])) + ' current security, history or execution tables will be preserved. App and portal access, caller authentication, consumed minutes and resource allowances remain current.'
                elif action == 'tenant_restore':
                    if job['request'].get('replace') is not True:raise full.BackupError('Replacement was not confirmed.')
                    with full.exclusive_guard(full.UPGRADE_LOCK):restore_tenant(settings, tenant, source, password, jid)
                    message = 'Tenant PBX settings and media restored. Current app and portal access, API keys, caller authentication, consumed minutes, call history, ownership and resource allowances were preserved. Reconnect phones and review scheduled actions.'
                else:raise full.BackupError('Unsupported tenant backup operation.')
            elif action in ('instance_verify','instance_restore'):
                instance_receipt(job,'running','The full-instance backup operation is running.')
                backup_id = str(uuid.UUID(job['backup_uuid']))
                row = full.query(settings, 'select row_to_json(b) from v_pbx_backups b where backup_uuid=' + full.literal(backup_id) + " and status='ready'", json_result=True)
                source = full.STORE/(backup_id+'.owpbx')
                if not row or row['filename'] != source.name or full.checksum(full.ordinary(source)) != row['sha256']:raise full.BackupError('The full-instance backup is unavailable or changed.')
                if action == 'instance_verify':
                    body = full.restore(source, password, settings, dry_run=True, allow_existing=True)
                    message = 'Full restore checked: ' + str(len(body['files'])) + ' files and the complete PostgreSQL database. Confirm replacement to stop calls, restore and restart the previous services.'
                else:
                    if job['request'].get('replace') is not True or job['request'].get('confirmed_name') != settings.get('openweb.public_host'):raise full.BackupError('The server replacement was not confirmed.')
                    previous = full.running_services()
                    full.restore(source, password, settings, confirm_database=settings['database.0.name'], allow_existing=True)
                    selections = [name for name, unit in full.HELD_UNITS.items() if unit.removesuffix('.service') in {s.removesuffix('.service') for s in previous}]
                    with full.exclusive_guard(full.UPGRADE_LOCK):
                        for name,unit in full.HELD_UNITS.items():
                            if name not in selections:(full.RESTORE/('hold-'+unit)).unlink(missing_ok=True)
                    if selections:full.activate(settings, selections, settings['openweb.public_host'])
                    archive_completed_instance_restore(job)
                    # This particular checked archive still exists outside the
                    # restored database. Keep it downloadable after rewinding
                    # the catalogue, without trusting other missing entries.
                    full.query(settings, 'insert into v_pbx_backups(backup_uuid,filename,status,include_media,app_version,size_bytes,sha256,remote_status,message,completed_at,verified_at) values('+','.join(full.literal(v) for v in [backup_id,source.name,'ready',row['include_media'],row['app_version'],source.stat().st_size,full.checksum(source),'disabled','Restored from this checked full-instance copy.'])+",now(),now()) on conflict(backup_uuid) do update set status='ready',filename=excluded.filename,size_bytes=excluded.size_bytes,sha256=excluded.sha256,message=excluded.message,verified_at=now()")
                    message = 'Full-instance restore completed. Previously running call services were restarted. API keys were revoked to prevent old credentials from returning; create new keys after checking the recovered server. Check phones and providers before resuming service.'
            else:raise full.BackupError('Unsupported backup operation.')
            full.query(settings, "update v_pbx_protection_jobs set status='completed',secret_ciphertext='',backup_uuid=coalesce(backup_uuid," + full.literal(backup_id) + '),message=' + full.literal(message) + ',finished_at=now() where job_uuid=' + full.literal(jid))
            if action.startswith('instance_'):instance_receipt(job,'completed',message)
        except Exception as error:
            message = str(error) if isinstance(error, full.BackupError) else 'The backup operation could not finish. Ask the instance administrator to inspect protected storage and recovery logs.'
            if job['action']=='tenant_restore':
                try:recovery_state=json.loads((WORK/('restore-'+jid)/'journal.json').read_text()).get('state')
                except (OSError,ValueError):recovery_state=None
                if recovery_state=='prepared':message='Tenant recovery needs administrator review. Calls for this tenant remain held because the original files have not yet been fully recovered.'
            if backup_id and job['action'] == 'tenant_create':
                full.query(settings, "update v_pbx_tenant_backups set status='failed',message=" + full.literal(message) + ' where backup_uuid=' + full.literal(backup_id))
                (STORE/(backup_id+'.owtenant')).unlink(missing_ok=True)
                (DOWNLOADS/(backup_id+'.owtenant')).unlink(missing_ok=True)
            full.query(settings, "update v_pbx_protection_jobs set status='failed',secret_ciphertext='',message=" + full.literal(message) + ',finished_at=now() where job_uuid=' + full.literal(jid))
            if job['action'].startswith('instance_'):instance_receipt(job,'failed',message)
        finally:
            if job['action'] in ('tenant_import','instance_import'):
                try:(INBOX/(str(uuid.UUID(job['request']['upload_uuid']))+'.upload')).unlink(missing_ok=True)
                except (ValueError,KeyError,TypeError):pass


def main():
    parser = argparse.ArgumentParser(description='OpenWeb PBX tenant backup worker.')
    parser.add_argument('action', choices=['worker']); parser.parse_args()
    if os.geteuid() != 0:parser.error('Run the installed worker as root.')
    os.umask(0o077)
    try:worker(full.read_settings())
    except full.BackupError as error:print(str(error)); return 1
    return 0


if __name__ == '__main__':raise SystemExit(main())
