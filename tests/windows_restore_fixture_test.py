#!/usr/bin/env python3
"""Focused PHP fixture contract tests. No Windows, owner, native calls or DB.

These execute only the fixture's pure guards and private evidence helpers on
Linux PHP. A passed shape check is never a Windows restore acceptance result.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


FIXTURE = Path(__file__).with_name('windows-restore-qualification.php')
PHP = shutil.which('php')
SCOPE = 'abc123' * 4
ADMIN = '11111111-1111-4111-8111-111111111111'
DOMAIN = '22222222-2222-4222-8222-222222222222'
JOB = '33333333-3333-4333-8333-333333333333'


@unittest.skipUnless(PHP, 'PHP is required for the offline guard tests')
class RestoreFixture(unittest.TestCase):
    def php(self, code, data=None):
        program = ("define('OPENWEB_RESTORE_FIXTURE_LIBRARY_ONLY',true);"
                   "require " + json.dumps(str(FIXTURE)) + ';'
                   "$input=json_decode(stream_get_contents(STDIN),true,64,JSON_THROW_ON_ERROR);"
                   "try{" + code + "}catch(Throwable $e){fwrite(STDERR,get_class($e));exit(7);}")
        return subprocess.run([PHP, '-r', program], input=json.dumps(data),
                              capture_output=True, text=True, check=False)

    def assert_accepts(self, code, data=None):
        result = self.php(code, data)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def assert_refuses(self, code, data=None):
        result = self.php(code, data)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(result.stdout, '')

    def contract(self):
        return {
            'input': {'schema': 1, 'disposable': True, 'github_actions': True,
                      'runner_environment': 'github-hosted', 'repository': 'embire2/openwebpbx',
                      'scope': SCOPE, 'run_id': '38602000000', 'role': 'source',
                      'admin_email': 'fixture@example.invalid', 'service_name': 'Restore ' + SCOPE},
            'environment': {'OPENWEB_WINDOWS_RESTORE_TEST': '1', 'GITHUB_ACTIONS': 'true',
                            'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_REPOSITORY': 'embire2/openwebpbx',
                            'GITHUB_RUN_ID': '38602000000'},
            'installation': {'RestoreServer': True, 'Completed': True,
                             'DomainName': 'windowsqa.example.invalid', 'AdminEmail': 'fixture@example.invalid'},
            'scope': SCOPE,
        }

    contract_code = "restore_fixture_contract($input['input'],$input['environment'],$input['installation'],$input['scope']);"

    def test_source_and_independent_target_contract(self):
        data = self.contract()
        self.assert_accepts(self.contract_code, data)
        data['input']['role'] = 'target'
        self.assert_accepts(self.contract_code, data)

    def test_refuses_forged_disposable_or_run_identity(self):
        for group, field, value in [('input', 'disposable', 'true'),
                                    ('input', 'github_actions', 'true'),
                                    ('input', 'run_id', 38602000000),
                                    ('input', 'scope', 'f' * 24),
                                    ('input', 'role', 'owner'),
                                    ('environment', 'GITHUB_RUN_ID', 'old'),
                                    ('environment', 'RUNNER_ENVIRONMENT', 'self-hosted'),
                                    ('environment', 'GITHUB_REPOSITORY', 'another/repo'),
                                    ('environment', 'OPENWEB_WINDOWS_RESTORE_TEST', '0')]:
            with self.subTest(group=group, field=field):
                data = self.contract()
                data[group][field] = value
                self.assert_refuses(self.contract_code, data)

    def test_refuses_owner_or_unfinished_installation(self):
        for field, value in [('DomainName', 'call.openweb.co.za'), ('Completed', False),
                             ('RestoreServer', 1), ('AdminEmail', 'someone@example.invalid')]:
            with self.subTest(field=field):
                data = self.contract()
                data['installation'][field] = value
                self.assert_refuses(self.contract_code, data)

    def test_service_name_must_include_exact_scope(self):
        for name in ['Restore fixture', 'x' * 121, 'Restore ' + SCOPE + '\n']:
            data = self.contract()
            data['input']['service_name'] = name
            self.assert_refuses(self.contract_code, data)

    def owned(self):
        return {'service_uuid': '44444444-4444-4444-8444-444444444444', 'domain_uuid': DOMAIN,
                'tenant_uuid': '55555555-5555-4555-8555-555555555555',
                'home_domain_uuid': '66666666-6666-4666-8666-666666666666',
                'owner_user_uuid': ADMIN,
                'domain_name': 'pbx-123456abcdef.company-abcdef123456.windowsqa.example.invalid'}

    def test_exact_original_realm_and_current_admin_required(self):
        code = "restore_fixture_owned($input['owned'],$input['admin']);"
        data = {'owned': self.owned(), 'admin': ADMIN}
        self.assert_accepts(code, data)
        for field, value in [('owner_user_uuid', JOB), ('domain_name', 'pbx-123456abcdef.call.openweb.co.za'),
                             ('home_domain_uuid', DOMAIN), ('service_uuid', '../escape')]:
            changed = copy.deepcopy(data)
            changed['owned'][field] = value
            self.assert_refuses(code, changed)
        changed = copy.deepcopy(data)
        changed['admin'] = JOB  # A replacement's former admin UUID cannot authorize the source tenant.
        self.assert_refuses(code, changed)

    def test_future_internal_job_is_exactly_namespaced(self):
        state = {'scope': SCOPE, 'owned': self.owned(), 'owned_job_uuid': JOB}
        row = {'job_uuid': JOB, 'domain_uuid': DOMAIN, 'kind': 'wakeup', 'target_number': '8100',
               'internal_target': True, 'request_key': 'restore-qualification/' + SCOPE + '/' + JOB}
        code = "restore_fixture_job($input['row'],$input['state']);"
        self.assert_accepts(code, {'row': row, 'state': state})
        for field, value in [('domain_uuid', ADMIN), ('job_uuid', ADMIN), ('kind', 'callback'),
                             ('target_number', '+27821234567'), ('internal_target', False),
                             ('request_key', 'another/' + JOB)]:
            changed = dict(row, **{field: value})
            self.assert_refuses(code, {'row': changed, 'state': state})

    def test_hmac_canonical_keys_rows_and_value_types(self):
        code = "echo json_encode([restore_fixture_digest($input['a'],str_repeat('k',32)),restore_fixture_digest($input['b'],str_repeat('k',32)),restore_fixture_rows_digest($input['rows1'],str_repeat('k',32)),restore_fixture_rows_digest($input['rows2'],str_repeat('k',32))]);"
        a = {'password': ' exact whitespace ', 'config': {'b': 2, 'a': 1}}
        b = {'config': {'a': 1, 'b': 2}, 'password': ' exact whitespace '}
        out = json.loads(self.assert_accepts(code, {'a': a, 'b': b, 'rows1': [a, {'id': 1}], 'rows2': [{'id': 1}, b]}))
        self.assertEqual(out[0], out[1])
        self.assertEqual(out[2], out[3])
        b['password'] = b['password'].strip()
        changed = json.loads(self.assert_accepts(code, {'a': a, 'b': b, 'rows1': [1], 'rows2': ['1']}))
        self.assertNotEqual(changed[0], changed[1])
        self.assertNotEqual(changed[2], changed[3])
        self.assert_refuses("restore_fixture_digest('value','short');")

    def test_wakeup_requires_owned_checked_in_room(self):
        state = {'scope': SCOPE, 'owned': self.owned()}
        room = {'domain_uuid': DOMAIN, 'number': '8100', 'room_name': 'Restore ' + SCOPE, 'occupied': True}
        code = "restore_fixture_room($input['room'],$input['state']);"
        self.assert_accepts(code, {'room': room, 'state': state})
        for field, value in [('domain_uuid', ADMIN), ('number', '8101'), ('occupied', False), ('room_name', 'Unowned room')]:
            self.assert_refuses(code, {'room': dict(room, **{field: value}), 'state': state})

    def test_manual_and_scheduled_commands_preserve_original_and_foreign_rows(self):
        code="restore_fixture_backup_command($input['row'],$input['id'],$input['admin'],$input['baseline'],$input['scheduled']);"
        identifier='11111111-2222-4333-8444-555555555555'
        for scheduled in [False,True]:
            row={'command_uuid':identifier,'status':'completed','requested_by':None if scheduled else ADMIN}
            state={'row':row,'id':identifier,'admin':ADMIN,'baseline':[],'scheduled':scheduled}
            self.assert_accepts(code,state)
            self.assert_refuses(code,state|{'baseline':[identifier]})
            self.assert_refuses(code,state|{'row':row|{'status':'running'}})
            self.assert_refuses(code,state|{'row':row|{'command_uuid':DOMAIN}})
            self.assert_refuses(code,state|{'row':row|{'requested_by':DOMAIN}})
            self.assert_refuses(code,state|{'row':row|{'requested_by':ADMIN if scheduled else None}})

    def snapshot(self):
        return {'schema': 1, 'label': 'target-restored', 'scope': SCOPE, 'role': 'target',
                'target_owned': {name: '1' * 64 for name in ['database_identity', 'cluster', 'roles', 'memberships', 'role_settings', 'database_credentials']},
                'schema_metadata': {name: '2' * 64 for name in ['schema', 'tables', 'columns']},
                'all_table_values': {name: {'rows': 0, 'hmac': '3' * 64} for name in ['v_users', 'v_domains', 'v_extensions', 'v_gateways', 'v_dialplans', 'v_voicemails', 'v_voicemail_messages', 'v_recordings', 'v_pbx_media', 'v_pbx_jobs', 'v_pbx_services', 'v_pbx_tenants', 'v_pbx_restore']},
                'scoped_values': {}, 'restore_projections': {name:{'rows':0,'hmac':'4'*64} for name in ['v_pbx_backup_settings','v_pbx_backups','v_pbx_backup_commands','v_pbx_update_commands']}, 'source_phone_tuples': None}

    def test_snapshot_does_not_accept_empty_identity_or_pbxtables(self):
        code = "restore_fixture_snapshot_shape($input);"
        baseline = self.snapshot()
        self.assert_accepts(code, baseline)
        for group in ['target_owned', 'schema_metadata', 'all_table_values']:
            changed = copy.deepcopy(baseline)
            changed[group] = {}
            self.assert_refuses(code, changed)
        changed = copy.deepcopy(baseline)
        changed['all_table_values']['v_extensions']['rows'] = -1
        self.assert_refuses(code, changed)
        changed = copy.deepcopy(baseline)
        changed['target_owned']['database_credentials'] = 'private plaintext password'
        self.assert_refuses(code, changed)

    def test_health_restore_proof_requires_the_complete_matching_table_inventory(self):
        code="restore_fixture_snapshot_shape($input);";baseline=self.snapshot()
        baseline['all_table_values']['v_pbx_phone_health_recoveries']={'rows':5,'hmac':'a'*64}
        proof={'rows':5,'hmac':'b'*64,'pending':2};baseline['health_recovery_restore']=proof
        self.assert_accepts(code,baseline)
        for value in (None,{}, proof|{'rows':4},proof|{'rows':True},proof|{'pending':True},
                      proof|{'pending':6},proof|{'hmac':'PRIVATE'},proof|{'extra':'PRIVATE'}):
            changed=copy.deepcopy(baseline);changed['health_recovery_restore']=value
            self.assert_refuses(code,changed)
        changed=copy.deepcopy(baseline);del changed['health_recovery_restore']
        self.assert_refuses(code,changed)

    def test_private_input_path_refuses_symlinks_and_unscoped_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'restore-qualification'
            folder = root / SCOPE
            folder.mkdir(parents=True)
            path = folder / 'input.json'
            path.write_text('{}')
            code = "echo restore_fixture_private_path($input['path'],$input['root']);"
            self.assertEqual(self.assert_accepts(code, {'path': str(path), 'root': str(root)}), str(folder))
            outside = Path(temporary) / 'input.json'
            outside.write_text('{}')
            path.unlink()
            path.symlink_to(outside)
            self.assert_refuses(code, {'path': str(path), 'root': str(root)})
            self.assert_refuses(code, {'path': str(outside), 'root': str(root)})

    failure_code = "echo json_encode(restore_fixture_failure_record(new $input['type']($input['message']),$input['path'],$input['action'],$input['step'],$input['root']));"

    def failure_input(self, root, **updates):
        path = root / SCOPE / 'input.json'
        path.parent.mkdir(exist_ok=True);path.write_bytes(b'{"original":true}')
        return dict(path=str(path),root=str(root),action='cleanup',step='factory_guard',
                    type='RuntimeException',message='A distinct empty factory is required.') | updates

    def test_cleanup_failure_actual_php_record_is_closed_and_exclusive(self):
        with tempfile.TemporaryDirectory() as temporary:
            data=self.failure_input(Path(temporary));path=Path(data['path']);sidecar=Path(str(path)+'.cleanup.failure.json')
            self.assertEqual(self.assert_accepts(self.failure_code,data),'true')
            record=json.loads(sidecar.read_bytes())
            self.assertEqual(set(record),{'schema','action','step','reason','error_type','source_basename','source_line'})
            self.assertEqual(record | {'source_line':1},dict(schema=1,action='cleanup',step='factory_guard',reason='factory_not_empty',
                             error_type='RuntimeException',source_basename='external_component',source_line=1))
            self.assertGreater(record['source_line'],0);self.assertLess(record['source_line'],1000000)
            self.assertLessEqual(sidecar.stat().st_size,2048)
            original=sidecar.read_bytes();data['message']='PRIVATE SQL password /private/path'
            self.assertEqual(self.assert_accepts(self.failure_code,data),'false')
            self.assertEqual(sidecar.read_bytes(),original);self.assertEqual(path.read_bytes(),b'{"original":true}')

    def test_cleanup_failure_private_messages_only_become_fixed_type_reason(self):
        for kind,reason in [('RuntimeException','runtime_guard'),('PDOException','database_error'),('JsonException','json_error'),
                            ('TypeError','type_error'),('ValueError','type_error'),('Error','external_error'),('Exception','external_error')]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                data=self.failure_input(Path(temporary),type=kind,message='PRIVATE SQL password /private/path')
                self.assertEqual(self.assert_accepts(self.failure_code,data),'true')
                raw=Path(data['path']+'.cleanup.failure.json').read_text();record=json.loads(raw)
                self.assertEqual(record['error_type'],kind);self.assertEqual(record['reason'],reason)
                self.assertNotIn('PRIVATE',raw);self.assertNotIn('password',raw);self.assertNotIn('/private',raw)

    def test_cleanup_failure_captures_actual_source_guard_origin(self):
        with tempfile.TemporaryDirectory() as temporary:
            data=self.failure_input(Path(temporary))
            code="try{restore_fixture_private_path($input['root'].'/missing.json',$input['root']);}catch(Throwable $error){echo json_encode(restore_fixture_failure_record($error,$input['path'],$input['action'],$input['step'],$input['root']));}"
            self.assertEqual(self.assert_accepts(code,data),'true')
            record=json.loads(Path(data['path']+'.cleanup.failure.json').read_text())
            self.assertEqual(record['source_basename'],'windows-restore-qualification.php')
            self.assertEqual(record['error_type'],'RuntimeException');self.assertEqual(record['reason'],'runtime_guard')
            lines=FIXTURE.read_text().splitlines()
            self.assertIn('An ordinary private scoped input is required.',lines[record['source_line']-1])

    def test_cleanup_failure_fixed_reasons_and_stages_match_actual_cleanup_source(self):
        source=FIXTURE.read_text()
        # All exact source guards used for classification must still be thrown
        # by the actual routine rather than merely existing in its allowlist.
        reasons=dict(re.findall(r"'([^']+)'=>'([a-z_]+)'",source.split('function restore_fixture_failure_record',1)[1].split('$type=get_class',1)[0]))
        actual=source.split('function restore_fixture_main',1)[1]
        for message,reason in reasons.items():
            with self.subTest(reason=reason),tempfile.TemporaryDirectory() as temporary:
                self.assertIn("throw new RuntimeException('"+message+"')",actual if reason not in ('backup_command_guard',) else source.split('function restore_fixture_failure_record',1)[0])
                data=self.failure_input(Path(temporary),message=message)
                self.assertEqual(self.assert_accepts(self.failure_code,data),'true')
                self.assertEqual(json.loads(Path(data['path']+'.cleanup.failure.json').read_text())['reason'],reason)
        for step in ('initialization','owned_lookup','gateway_guard','native_quiescence','native_contacts','backup_inventory',
                     'owned_rows_delete','update_commands_delete','backup_commands_delete','drafts_delete','archive_files_delete',
                     'cache_cleanup','native_reload','factory_guard','input_commit'):
            with self.subTest(step=step),tempfile.TemporaryDirectory() as temporary:
                self.assertIn("$GLOBALS['restore_fixture_failure_step']='"+step+"'",actual)
                data=self.failure_input(Path(temporary),step=step)
                self.assertEqual(self.assert_accepts(self.failure_code,data),'true')

    def test_cleanup_failure_refuses_wrong_action_step_path_and_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);data=self.failure_input(root)
            variants=[data|{'action':'snapshot'},data|{'step':'PRIVATE'},data|{'path':str(root/SCOPE/'other.json')},
                      data|{'root':str(root/'missing')},data|{'path':str(root/'input.json')}]
            (root/SCOPE/'other.json').write_text('{}');(root/'input.json').write_text('{}')
            for item in variants:
                with self.subTest(item=item):self.assertEqual(self.assert_accepts(self.failure_code,item),'false')
            alias=root/('d'*24);alias.symlink_to(root/SCOPE,target_is_directory=True)
            self.assertEqual(self.assert_accepts(self.failure_code,data|{'path':str(alias/'input.json')}),'false')
            path=Path(data['path']);path.unlink();path.symlink_to(root/'input.json')
            self.assertEqual(self.assert_accepts(self.failure_code,data),'false')
            path.unlink();path.write_text('{}')
            sidecar=Path(str(path)+'.cleanup.failure.json');sidecar.symlink_to(root/'input.json')
            self.assertEqual(self.assert_accepts(self.failure_code,data),'false')
            self.assertEqual((root/'input.json').read_text(),'{}')
            self.assertEqual({p.name for p in (root/SCOPE).iterdir()},{'input.json','input.json.cleanup.failure.json','other.json'})

    def test_indexed_media_is_read_only_and_owned(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / DOMAIN
            root.mkdir()
            # This fixture is arbitrary bytes; the pure guard never claims a native WAV.
            path = root / 'opaque.dat'
            path.write_bytes(b'synthetic offline evidence')
            code = "echo json_encode(restore_fixture_media($input['path'],$input['roots']));"
            result = json.loads(self.assert_accepts(code, {'path': str(path), 'roots': [str(root)]}))
            self.assertTrue(result['exists'])
            self.assertEqual(result['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(path.read_bytes(), b'synthetic offline evidence')
            self.assert_refuses(code, {'path': str(path), 'roots': [str(root / 'other')]})
            self.assertEqual(json.loads(self.assert_accepts(code, {'path': str(root / 'missing'), 'roots': [str(root)]})), {'exists': False})

    def test_private_atomic_evidence_write_keeps_real_newlines(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'evidence.json'
            code = "restore_fixture_write($input['path'],$input['value']);"
            for value in [{'state': 'before'}, {'private': 'original\ncredential'}]:
                self.assert_accepts(code, {'path': str(path), 'value': value})
                self.assertEqual(json.loads(path.read_text()), value)
                self.assertEqual(list(path.parent.glob('*.new-*')), [])
            target = Path(temporary) / 'target.json'
            target.write_text('{}')
            path.unlink()
            path.symlink_to(target)
            self.assert_refuses(code, {'path': str(path), 'value': {'changed': True}})
            self.assertEqual(target.read_text(), '{}')

    def test_unflagged_entry_refuses_before_loading_installed_app(self):
        result = subprocess.run([PHP, str(FIXTURE), 'baseline', '/missing/input.json'],
                                env={**os.environ, 'OPENWEB_WINDOWS_RESTORE_TEST': '0'},
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    @unittest.skipUnless(hasattr(os, 'geteuid') and os.geteuid() == 0 and Path('/usr/lib/postgresql/18/bin/initdb').is_file()
                         and shutil.which('runuser'), 'An isolated PostgreSQL 18 runtime is required')
    def test_named_schema_grants_on_isolated_postgresql(self):
        # No installed PBX connection or credentials are used. A Unix-socket-only
        # private cluster proves real PostgreSQL expressions and ACL ordering.
        with tempfile.TemporaryDirectory(prefix='openweb-restore-fixture-') as temporary:
            import pwd
            work = Path(temporary)
            work.chmod(0o755)
            cluster = work / 'cluster'
            cluster.mkdir(mode=0o700)
            owner = pwd.getpwnam('postgres')
            os.chown(cluster, owner.pw_uid, owner.pw_gid)
            runtime = Path('/usr/lib/postgresql/18/bin')

            def pg(program, *arguments, input=None):
                return subprocess.run(['runuser', '-u', 'postgres', '--', str(runtime / program), *arguments],
                                      input=input, capture_output=True, text=True, cwd=cluster, check=True)

            pg('initdb', '-D', str(cluster), '--auth-local=trust', '--encoding=UTF8', '--locale=C')
            pg('pg_ctl', '-D', str(cluster), '-l', str(cluster / 'server.log'), '-o',
               "-h '' -k " + str(cluster), '-w', 'start')
            try:
                args = ('-h', str(cluster), '-U', 'postgres', '-d', 'postgres', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-At')
                pg('psql', *args, input="create role zzz_fixture;create role aaa_fixture;create table v_fixture(id integer,password text);grant select on v_fixture to zzz_fixture,aaa_fixture;grant usage on schema public to zzz_fixture,aaa_fixture;")
                queries = json.loads(self.assert_accepts('echo json_encode(restore_fixture_schema_queries());'))
                outputs = {}
                for name, sql in queries.items():
                    result = pg('psql', *args, input='select coalesce(json_agg(t),\'[]\') from (' + sql + ') t;')
                    outputs[name] = json.loads(result.stdout)
                self.assertEqual(outputs['tables'][0]['owner_name'], 'postgres')
                grants = outputs['tables'][0]['grants']
                self.assertIn('aaa_fixture', [item['grantee'] for item in grants])
                self.assertIn('zzz_fixture', [item['grantee'] for item in grants])
                self.assertEqual([item['grantee'] for item in grants], sorted(item['grantee'] for item in grants))
                self.assertNotIn('relowner', outputs['tables'][0])
                self.assertNotIn('nspowner', outputs['schema'][0])
                self.assertEqual([item['column_name'] for item in outputs['columns']], ['id', 'password'])
                # Real PostgreSQL rows feed the exact production test guard.
                # A protected baseline/foreign row survives; only the recorded
                # requester-NULL completed scheduled row is eligible to delete.
                owned='11111111-2222-4333-8444-555555555555';original='22222222-2222-4333-8444-555555555555'
                pg('psql',*args,input="create table v_pbx_backup_commands(command_uuid uuid primary key,status text,requested_by uuid);"
                    +"insert into v_pbx_backup_commands values('"+owned+"','completed',null),('"+original+"','completed',null);")
                selected=json.loads(pg('psql',*args,input="select row_to_json(t) from v_pbx_backup_commands t where command_uuid='"+owned+"';").stdout)
                code="restore_fixture_backup_command($input['row'],$input['id'],$input['admin'],$input['baseline'],true);"
                self.assert_accepts(code,{'row':selected,'id':owned,'admin':ADMIN,'baseline':[original]})
                protected=json.loads(pg('psql',*args,input="select row_to_json(t) from v_pbx_backup_commands t where command_uuid='"+original+"';").stdout)
                self.assert_refuses(code,{'row':protected,'id':original,'admin':ADMIN,'baseline':[original]})
                self.assertEqual(pg('psql',*args,input='select count(*) from v_pbx_backup_commands;').stdout.strip(),'2')

                # Execute the actual cleanup transaction against the real
                # production draft FK. The former order loses its recorded
                # draft through ON DELETE CASCADE, then refuses and rolls back.
                source=FIXTURE.read_text();start=source.index('$db->beginTransaction();',source.index("if($action==='cleanup')"))
                end=source.index("\n        $GLOBALS['restore_fixture_failure_step']='archive_files_delete';",start)
                transaction=source[start:end]
                draft_start=transaction.index("            $GLOBALS['restore_fixture_failure_step']='drafts_delete';")
                draft_end=transaction.index("            $GLOBALS['restore_fixture_failure_step']='owned_rows_delete';",draft_start)
                draft_body=transaction[draft_start:draft_end]
                self.assertLess(transaction.index("foreach($s['owned_draft_ids']"),transaction.index('delete from v_domains'))
                former=transaction.replace(draft_body,'',1).replace('            $db->commit();',draft_body+'            $db->commit();',1)
                self.assertGreater(former.index("foreach($s['owned_draft_ids']"),former.index('delete from v_domains'))
                schema=FIXTURE.parent.parent/'app/pbx_setup/resources/install.sql'
                ddl=schema.read_text().split('CREATE TABLE IF NOT EXISTS v_pbx_setup_drafts (',1)[1].split('\n);',1)[0]
                self.assertIn('completed_domain_uuid uuid REFERENCES v_domains(domain_uuid) ON DELETE CASCADE',ddl)
                factory='aaaaaaaa-1111-4111-8111-111111111111';home='bbbbbbbb-1111-4111-8111-111111111111'
                foreign='cccccccc-1111-4111-8111-111111111111';foreign_user='dddddddd-1111-4111-8111-111111111111'
                draft='eeeeeeee-1111-4111-8111-111111111111';foreign_draft='ffffffff-1111-4111-8111-111111111111'
                baseline_draft='aaaaaaaa-2222-4222-8222-222222222222';missing='bbbbbbbb-2222-4222-8222-222222222222'
                pg('psql',*args,input='create table v_domains(domain_uuid uuid primary key,domain_name text);'
                    +'create table v_users(user_uuid uuid primary key,domain_uuid uuid references v_domains(domain_uuid));'
                    +'CREATE TABLE IF NOT EXISTS v_pbx_setup_drafts ('+ddl+'\n);'
                    +f"insert into v_domains values('{factory}','factory.invalid'),('{DOMAIN}','owned.invalid'),('{home}','owned-home.invalid'),('{foreign}','foreign.invalid');"
                    +f"insert into v_users values('{ADMIN}','{factory}'),('{foreign_user}','{foreign}');"
                    +f"insert into v_pbx_setup_drafts(draft_uuid,user_uuid,kind,preview,expires_at,completed_domain_uuid) values('{draft}','{ADMIN}','setup','{{}}',now()+interval '1 hour','{DOMAIN}'),('{foreign_draft}','{foreign_user}','setup','{{}}',now()+interval '1 hour','{foreign}'),('{baseline_draft}','{ADMIN}','setup','{{}}',now()+interval '1 hour',null);")
                snapshot_sql="select json_build_object('domains',(select json_agg(t order by domain_uuid) from v_domains t),'users',(select json_agg(t order by user_uuid) from v_users t),'drafts',(select json_agg(t order by draft_uuid) from v_pbx_setup_drafts t),'commands',(select json_agg(t order by command_uuid) from v_pbx_backup_commands t));"
                before=json.loads(pg('psql',*args,input=snapshot_sql).stdout)
                state={'owned_draft_ids':[draft],'owned_backup_commands':[],'owned_scheduled_backup_commands':[],
                       'baseline':{'drafts':[baseline_draft],'backup_commands':[original]}}
                setup="$db=new PDO('pgsql:host='.$input['socket'].';dbname=postgres','postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);$s=$input['state'];$domain=$input['domain'];$owned=$input['owned'];$admin=['user_uuid'=>$input['admin']];$q=static function(string $sql,array $args=[])use($db):PDOStatement{$p=$db->prepare($sql);$p->execute($args);return $p;};"
                data={'socket':str(cluster),'state':state,'domain':DOMAIN,'owned':{'home_domain_uuid':home,'tenant_uuid':JOB},'admin':ADMIN}
                former_code=setup+"try{"+former+"}catch(Throwable $error){if($error->getMessage()!=='Only recorded owned drafts may be removed.')throw $error;echo '{\"former_cascade_guard_refused\":true}';}"
                self.assertEqual(json.loads(self.assert_accepts(former_code,data)),{'former_cascade_guard_refused':True})
                self.assertEqual(json.loads(pg('psql',*args,input=snapshot_sql).stdout),before)
                for refused in (baseline_draft,foreign_draft,missing):
                    with self.subTest(refused=refused):
                        bad=copy.deepcopy(data);bad['state']['owned_draft_ids']=[refused]
                        self.assert_refuses(setup+transaction,bad)
                        self.assertEqual(json.loads(pg('psql',*args,input=snapshot_sql).stdout),before)
                self.assert_accepts(setup+transaction,data)
                after=json.loads(pg('psql',*args,input=snapshot_sql).stdout)
                self.assertEqual(after['domains'],[row for row in before['domains'] if row['domain_uuid'] not in (DOMAIN,home)])
                self.assertEqual(after['drafts'],[row for row in before['drafts'] if row['draft_uuid']!=draft])
                self.assertEqual(after['users'],before['users']);self.assertEqual(after['commands'],before['commands'])
                pg('psql',*args,input="begin;delete from v_pbx_backup_commands where command_uuid='"+owned+"' and requested_by is null and status in ('completed','failed');commit;")
                self.assertEqual(pg('psql',*args,input='select command_uuid from v_pbx_backup_commands;').stdout.strip(),original)
            finally:
                pg('pg_ctl', '-D', str(cluster), '-m', 'immediate', '-w', 'stop')


if __name__ == '__main__':
    unittest.main()
