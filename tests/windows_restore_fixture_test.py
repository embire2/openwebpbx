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
                pg('psql',*args,input="begin;delete from v_pbx_backup_commands where command_uuid='"+owned+"' and requested_by is null and status in ('completed','failed');commit;")
                self.assertEqual(pg('psql',*args,input='select command_uuid from v_pbx_backup_commands;').stdout.strip(),original)
            finally:
                pg('pg_ctl', '-D', str(cluster), '-m', 'immediate', '-w', 'stop')


if __name__ == '__main__':
    unittest.main()
