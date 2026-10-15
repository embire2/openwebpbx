#!/usr/bin/env python3
"""Two real disposable Windows installations; encrypted fictional data only.

All side effects require the private hosted-runner contract. Importing this
module is side-effect free, so capsule and late-copy controls can be tested
independently. Restore uses the supported administrator CLI library, never an
invented HTTPS restore endpoint. Actual operating-system boot is not tested.
"""
import argparse
import contextlib
import hashlib
import hmac
import importlib.util
import ipaddress
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.parse
import wave

ESSENTIAL_GATES = ('fresh', 'native_sip_audio', 'backups', 'direct_113_helper_reapply',
                   'direct_failure_rollback', 'restore_gate_startup')
# These are server execution evidence, not customer configuration. Every other
# table, including SIP credentials, media indexes, hotel state and jobs, is exact.
OPERATIONAL_TABLES = frozenset(('v_user_logs', 'v_logs', 'v_pbx_update_status',
    'v_pbx_backup_status', 'v_pbx_job_slots', 'v_pbx_presence', 'v_pbx_user_presence'))
RESTORE_TRANSFORMED_TABLES = frozenset(('v_pbx_backup_settings','v_pbx_backups',
                                      'v_pbx_backup_commands','v_pbx_update_commands'))


def restore_fixture_failure_fields(record, action):
    """Closed cleanup observations; never consume error messages or private data."""
    fields = {'schema', 'action', 'step', 'reason', 'error_type', 'source_basename', 'source_line'}
    steps = ('initialization', 'owned_lookup', 'gateway_guard', 'native_quiescence', 'native_contacts',
             'backup_inventory', 'owned_rows_delete', 'update_commands_delete', 'backup_commands_delete',
             'drafts_delete', 'archive_files_delete', 'cache_cleanup', 'native_reload', 'factory_guard', 'input_commit')
    reasons = ('owned_service_lookup', 'enabled_gateway', 'active_calls', 'phone_identity', 'live_contact',
               'missing_backup_command', 'backup_command_guard', 'backup_metadata_guard', 'backup_link',
               'backup_integrity', 'original_command', 'command_ownership', 'backup_command_changed',
               'original_draft', 'draft_ownership', 'archive_unlink', 'factory_not_empty', 'database_error',
               'json_error', 'type_error', 'runtime_guard', 'external_error')
    types = ('RuntimeException', 'PDOException', 'JsonException', 'TypeError', 'ValueError', 'Error', 'Exception', 'external_error')
    sources = ('windows-restore-qualification.php', 'database.php', 'pbx_paths.php', 'cache.php',
               'event_socket.php', 'config.php', 'external_component')
    if (not isinstance(record, dict) or set(record) != fields or action != 'cleanup'
            or type(record['schema']) is not int or record['schema'] != 1 or record['action'] != action
            or record['step'] not in steps or record['reason'] not in reasons
            or record['error_type'] not in types or record['source_basename'] not in sources
            or type(record['source_line']) is not int or not 0 < record['source_line'] < 1000000):
        return {}
    return {key: record[key] for key in sorted(fields)}


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'), allow_nan=False).encode('utf-8')


def derive(secret, label):
    if not isinstance(secret, str) or len(secret) < 32 or not isinstance(label, str):
        raise ValueError('An independent temporary qualification passphrase is required.')
    return hmac.new(secret.encode(), ('openweb-restore-qualification/v1/' + label).encode(), hashlib.sha256).digest()


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def read_json(path, maximum=8 * 1024**2):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate evidence keys are refused.')
            result[key] = value
        return result
    data = Path(path).read_bytes()
    if len(data) > maximum:
        raise ValueError('Private evidence exceeds its bound.')
    return json.loads(data.decode('utf-8-sig'), object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Non-finite evidence is refused.')))


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.new')
    temporary.write_bytes(canonical(value))
    os.replace(temporary, path)


def seal_capsule(payload, key):
    if len(key) != 32:
        raise ValueError('The capsule audit key must be independently derived.')
    return {'payload': payload, 'mac': hmac.new(key, canonical(payload), hashlib.sha256).hexdigest()}


def open_capsule(envelope, key, expected_binding, cipherpath):
    if set(envelope) != {'payload', 'mac'} or len(key) != 32:
        raise ValueError('The exact authenticated source capsule is required.')
    payload, mac = envelope['payload'], envelope['mac']
    if (not isinstance(mac, str) or not re.fullmatch('[a-f0-9]{64}', mac)
            or not hmac.compare_digest(mac, hmac.new(key, canonical(payload), hashlib.sha256).hexdigest())):
        raise ValueError('Source capsule authentication failed.')
    if payload.get('schema') != 1 or any(payload.get(k) != v for k, v in expected_binding.items()):
        raise ValueError('Source/target artifact, workflow or package identities differ.')
    archive = Path(cipherpath)
    if archive.is_symlink() or not archive.is_file() or not 64 < archive.stat().st_size <= 8 * 1024**3:
        raise ValueError('Only the bounded original fictional ciphertext is accepted.')
    if payload.get('cipher_sha256') != digest(archive) or payload.get('cipher_bytes') != archive.stat().st_size:
        raise ValueError('The complete transferred ciphertext differs.')
    with archive.open('rb') as stream:
        magic = stream.read(8)
    if magic != b'OWPBXB01':
        raise ValueError('A native encrypted backup is required.')
    forbidden = {'password', 'passphrase', 'private_key', 'event_socket', 'users', 'admin_password', 'logs'}
    def inspect(value):
        if isinstance(value, dict):
            if forbidden.intersection(value):
                raise ValueError('A plaintext credential field is refused in transfer evidence.')
            for item in value.values(): inspect(item)
        elif isinstance(value, list):
            for item in value: inspect(item)
    inspect(payload)
    return payload


def restore_identity_failure_fields(error):
    if (type(error) is not ValueError
            or getattr(error, 'failure_kind', None) != 'non_distinct_installation_identity'
            or not isinstance(getattr(error, 'identity_field', None), str)
            or error.identity_field not in ('hardware_uuid_hmac', 'hostname_hmac', 'certificate_sha256', 'template_key_sha256')):
        return {}
    return {'failure_kind': 'non_distinct_installation_identity', 'identity_field': error.identity_field}


NATIVE_CASES = {'native-source': ('source_real_two_way_recorded_call', 'source_real_native_voicemail_deposit'),
                'native-target': ('restored_original_credentials_two_way_decoded_native_audio', 'restored_original_native_voicemail_pin_rfc2833_retrieval')}
PEER_ERROR_TYPES = ('RuntimeError','AssertionError','ValueError','TypeError','KeyError','AttributeError','OSError','TimeoutError',
                    'ConnectionError','ConnectionResetError','ConnectionAbortedError','ConnectionRefusedError','BrokenPipeError',
                    'SSLError','SSLEOFError','SSLCertVerificationError','JSONDecodeError','UnicodeDecodeError','check_failed','external_error')
PEER_ERROR_SOURCES = ('windows-restore-qualification.py','pbx_v20_restore_native.py','sip_trunk_live.py','socket.py','ssl.py','decoder.py','external_component')


def restore_peer_failure_fields(records):
    keys = {'peer_index','stage','status_code','error_type','source_basename','source_line'}
    if not isinstance(records,list) or not 0 < len(records) <= 12:return []
    for row in records:
        if (not isinstance(row,dict) or set(row)!=keys or type(row['peer_index']) is not int or row['peer_index'] not in (0,1)
                or row['stage'] not in ('unregister','registration_ids','flush_registration','contact_absence','peer_close')
                or type(row['status_code']) is not int or not (row['status_code']==0 or 100<=row['status_code']<=699)
                or row['error_type'] not in PEER_ERROR_TYPES or row['source_basename'] not in PEER_ERROR_SOURCES
                or type(row['source_line']) is not int or not 0<=row['source_line']<1000000):return []
    return [dict(row) for row in records]


def peer_failure(index,stage,code=0,error=None):
    trace = error.__traceback__ if error else None
    while trace and trace.tb_next:trace=trace.tb_next
    source = Path(trace.tb_frame.f_code.co_filename).name if trace else 'windows-restore-qualification.py'
    kind = type(error).__name__ if error else 'check_failed'
    return {'peer_index':index,'stage':stage,'status_code':code if type(code) is int and 100<=code<=699 else 0,
            'error_type':kind if kind in PEER_ERROR_TYPES else 'external_error',
            'source_basename':source if source in PEER_ERROR_SOURCES else 'external_component',
            'source_line':trace.tb_lineno if trace else sys._getframe(1).f_lineno}


def completed_native_cases(facts, action):
    return [name for name in NATIVE_CASES.get(action,()) if name in facts.get('checks',[]) and facts.get('gates',{}).get(name)=='passed']


def restore_completed_native_cases(cases,action):
    if (not isinstance(action,str) or action not in NATIVE_CASES or not isinstance(cases,list) or len(cases)>2
            or any(not isinstance(name,str) or name not in NATIVE_CASES[action] for name in cases)
            or len(set(cases))!=len(cases)):return None
    return list(cases)


def distinct_installations(source, target):
    # Numeric DB OIDs can legitimately coincide between fresh clusters. The
    # system identifier and actual credential HMAC must differ independently.
    for key in ('cluster', 'database_credentials'):
        if source['target_owned'][key] == target['target_owned'][key]:
            raise ValueError('Source and target must be genuinely distinct PostgreSQL installations.')
    for key in ('hardware_uuid_hmac', 'hostname_hmac', 'certificate_sha256', 'template_key_sha256'):
        if source[key] == target[key]:
            error = ValueError('Source and replacement identities or private material are identical.')
            error.failure_kind = 'non_distinct_installation_identity'; error.identity_field = key
            raise error
    if source['hosted_job_id']==target['hosted_job_id'] or not all(re.fullmatch('[1-9][0-9]{0,19}',str(v['hosted_job_id'])) for v in (source,target)):
        raise ValueError('Distinct authenticated hosted jobs are required.')


def preserve_machine_identity(actual, expected):
    for name in ('machine_sid_hmac','hardware_uuid_hmac','hostname_hmac','runner_name_hmac','hosted_job_id'):
        if actual.get(name)!=expected.get(name):
            raise ValueError('The original target machine, SID or authenticated runner identity changed.')


def compare_snapshots(before, after, mode):
    if mode not in ('factory-recovery', 'source-restored'):
        raise ValueError('Unknown snapshot comparison.')
    if before['schema_metadata'] != after['schema_metadata']:
        raise ValueError('Schema ownership, grants or definitions changed.')
    if mode == 'factory-recovery' and before['target_owned'] != after['target_owned']:
        raise ValueError('Factory PostgreSQL identity, roles or private credentials changed.')
    exclusions = OPERATIONAL_TABLES | (RESTORE_TRANSFORMED_TABLES if mode == 'source-restored' else frozenset())
    # Full global rows, including SMTP/profiles/admin memberships/defaults,
    # are equally protected; tenant-only rows cannot establish full SQL restore.
    a = {k: v for k, v in before['all_table_values'].items() if k not in exclusions}
    b = {k: v for k, v in after['all_table_values'].items() if k not in exclusions}
    if a != b:
        raise ValueError('Preserved non-operational PBX records changed.')
    if mode == 'source-restored' and before['source_phone_tuples'] != after['source_phone_tuples']:
        raise ValueError('Actual native phone credentials or mailbox PINs changed.')
    if mode == 'source-restored' and before['restore_projections'] != after['restore_projections']:
        raise ValueError('Unchanged backup secrets/settings or command/archive identities changed.')


def late_copy_fault(original, keypath, notificationpath, media_roots, witness, error_type=RuntimeError, *, media_paths=None):
    """Throw once AFTER three real private copies; recovery remains unpatched.

    This exists only in the private subprocess harness. No production restore
    flag, endpoint or permission bypass is added.
    """
    keypath, notificationpath = Path(keypath).resolve(), Path(notificationpath).resolve()
    roots = tuple(Path(p).resolve() for p in media_roots)
    exact_media = None if media_paths is None else {Path(p).resolve() for p in media_paths}
    witness.update({'copied': [], 'categories': [], 'injected': False})
    def copy(source, target, *args, **kwargs):
        result = original(source, target, *args, **kwargs)
        path = Path(target).resolve()
        if witness['injected']:
            return result
        is_media = path in exact_media if exact_media is not None else any(root in path.parents for root in roots)
        category = ('key' if path == keypath else 'notification' if path == notificationpath
                    else 'media' if is_media else None)
        if category:
            if not path.is_file() or digest(path) != digest(source):
                raise AssertionError('The late-failure witness requires complete actual copies.')
            witness['copied'].append({'category': category, 'sha256': digest(path)})
            witness['categories'] = sorted(set(witness['categories']) | {category})
        if witness['categories'] == ['key', 'media', 'notification']:
            witness['injected'] = True
            raise error_type('Private qualification late-copy failure.')
        return result
    return copy


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def wait_for(predicate, seconds=120):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.2)
    raise TimeoutError('A bounded qualification condition did not complete.')


class Qualification:
    def __init__(self, path):
        self.path = Path(path); self.work = self.path.parent; self.s = read_json(path, 2 * 1024**2)
        if (os.name != 'nt' or os.environ.get('OPENWEB_WINDOWS_RESTORE_TEST') != '1'
                or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
                or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx'
                or os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'):
            raise RuntimeError('Only the explicitly disposable hosted Windows runner is permitted.')
        expected = Path(os.environ['ProgramData']) / 'OpenWebPBX/restore-qualification'
        if (self.path.name != 'input.json' or self.work.parent.resolve() != expected.resolve()
                or not re.fullmatch('[a-f0-9]{24}', self.work.name)
                or self.s.get('scope') != self.work.name or self.s.get('run_id') != os.environ['GITHUB_RUN_ID']
                or self.s.get('role') not in ('source', 'target') or self.s.get('disposable') is not True):
            raise RuntimeError('The exact private source/target qualification scope is required.')
        self.source = Path(self.s['source_root'])
        self.backups = load_module('restore_qualification_backups', Path('C:/OpenWebPBX/tools/backups.py'))
        self.settings = self.backups.read_settings(self.backups.CONFIG)
        self.helper = load_module('restore_qualification_web', self.source / 'tests/windows-updater-fixture.py')
        self.facts_path = self.work / 'facts.json'
        self.facts = read_json(self.facts_path) if self.facts_path.exists() else {
            'schema': 1, 'role': self.s['role'], 'state': 'running', 'checks': [], 'gates': {},
            'actual_os_boot': 'unqualified', 'carrier': 'unqualified', 'public_delivery': 'unqualified'}

    def refresh(self): self.s = read_json(self.path, 2 * 1024**2)
    def save(self): write_json(self.path, self.s)
    def record(self, name):
        self.facts['checks'].append(name); self.facts['gates'][name] = 'passed'; write_json(self.facts_path, self.facts)
    def php(self, action):
        failure_path = Path(str(self.path) + '.cleanup.failure.json')
        failure_absent = not failure_path.exists() and not failure_path.is_symlink()
        child = subprocess.run(['C:/OpenWebPBX/php/php.exe', str(self.source / 'tests/windows-restore-qualification.php'),
            action, str(self.path)], cwd='C:/OpenWebPBX/web', stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        (self.work / (action + '.private.out')).write_bytes(child.stdout)
        (self.work / (action + '.private.err')).write_bytes(child.stderr)
        if child.returncode:
            error = RuntimeError('The private scoped PHP fixture failed.')
            if action == 'cleanup' and failure_absent:
                try:
                    if not failure_path.is_symlink() and failure_path.is_file() and failure_path.stat().st_size <= 2048:
                        fields = restore_fixture_failure_fields(read_json(failure_path, 2048), action)
                        if fields: error.fixture_failure = fields
                except Exception:
                    pass  # Observation failure must not replace the original child failure.
            raise error
        self.refresh(); return json.loads(child.stdout.decode('utf-8-sig'))
    def snapshot(self, label):
        self.s['snapshot_label'] = label; self.save(); self.php('snapshot')
        return read_json(self.work / (label + '-database.json'))
    def query(self, sql):
        return self.backups.query(self.settings, "select coalesce(json_agg(row_to_json(t)),'[]'::json) from (" + sql + " ) t", json_result=True)
    def cli(self, arguments, *, password=None, expect_failure=False):
        # Exercise the installed public CLI's real argparse/Admin check and
        # implementation. Only interactive passphrase delivery is adapted by
        # this private subprocess; passwords never enter process arguments.
        previous_args, previous_prompt = sys.argv, self.backups.getpass.getpass
        output, errors = io.StringIO(), io.StringIO(); code = 0
        sys.argv = ['backups.py', *arguments]
        if password is not None: self.backups.getpass.getpass = lambda _prompt: password
        try:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                try: self.backups.main()
                except SystemExit as result: code = result.code or 0
        finally:
            sys.argv, self.backups.getpass.getpass = previous_args, previous_prompt
            (self.work / ('cli-' + arguments[0] + '.private.out')).write_text(output.getvalue(), encoding='utf-8')
            (self.work / ('cli-' + arguments[0] + '.private.err')).write_text(errors.getvalue(), encoding='utf-8')
        if (expect_failure and code != 1) or (not expect_failure and code != 0):
            raise RuntimeError('The real administrator CLI did not return its expected result.')
        self.facts['cli_entry'] = 'real_installed_main_argparse_and_administrator_guard'
        self.facts['passphrase_input'] = 'private_fixture_getpass_adapter_no_password_arguments'
        self.facts['actual_console_keyboard_input'] = 'unqualified'
    def web(self, source_password=False):
        s = dict(self.s)
        if source_password: s['admin_password'] = s['source_admin_password']
        return self.helper.Web(s)
    def submit(self, web, path, action, fields, selector=None, button=False):
        status, _, text = web.request(path)
        forms = [f for f in self.helper.Forms(text).forms if f['method'] == 'post'
                 and (({'name': 'action', 'value': action} in f['buttons']) if button else f['fields'].get('action') == action)
                 and (not selector or all(f['fields'].get(k) == v for k, v in selector.items()))
                 and (action is not None or 'provider' in f['fields'])]
        if status != 200 or len(forms) != 1: raise RuntimeError('The exact ordinary HTTPS/CSRF form is unavailable.')
        form = forms[0]; payload = form['fields'] | fields
        if button: payload['action'] = action
        status, url, text = web.request(form['action'] or path, payload)
        if status != 200 or 'setup-message error' in text or 'role="alert"' in text:
            raise RuntimeError('The ordinary authenticated HTTPS operation was rejected.')
        return url, text

    def setup(self):
        web = self.web()
        self.submit(web, '/app/pbx_updates/index.php', 'save_instance', {'mode': 'notify', 'maintenance_hour': '2', 'maintenance_duration': '2'})
        self.submit(web, '/app/pbx_mobile/push.php', None, {'enabled': '1', 'provider': 'webpush', 'delivery': 'direct', 'relay_url': '', 'relay_token': ''})
        if self.s['role'] == 'source':
            values = {'company_name': 'Fictional restore ' + self.s['scope'], 'service_name': self.s['service_name'], 'timezone': 'UTC',
                'tenant_uuid': '', 'trunk[host]': '', 'trunk[name]': 'No provider', 'trunk[authentication]': 'ip',
                'outbound[prefix]': '', 'outbound[strip]': '0', 'outbound[prepend]': '', 'inbound_number': '', 'inbound_destination': ''}
            for i, number in enumerate(('8100', '8101')):
                values.update({f'users[{i}][number]': number, f'users[{i}][name]': 'Fictional restore ' + number, f'users[{i}][email]': 'sink@example.invalid'})
            url, _ = self.submit(web, '/app/pbx_setup/?view=wizard', 'review_setup', values)
            if 'view=review' not in url: raise RuntimeError('The normal setup review was not reached.')
            drafts = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).get('draft', [])
            if len(drafts) != 1 or not re.fullmatch('[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', drafts[0]):
                raise RuntimeError('The exact normal guided-setup draft identity is required.')
            self.s['owned_draft_ids'] = drafts; self.save()
            self.submit(web, url, 'create_setup', {'acknowledged': '1'})
            for number in ('8100', '8101'):
                self.submit(web, '/app/pbx_setup/?view=users&edit=' + number, 'save', {'name': 'Fictional restore ' + number,
                    'email': 'sink@example.invalid', 'enabled': '1', 'voicemail_enabled': '1', 'voicemail_email': 'None',
                    'record_calls': '1' if number == '8100' else '0', 'profile': 'Available', 'timeout': '3', 'auto_status': '',
                    'no_answer': 'VoiceMail:' + number, 'busy': 'VoiceMail:' + number, 'not_registered': 'VoiceMail:' + number})
            for action, fields in (('add_room', {'number': '8100', 'room_name': 'Fictional room ' + self.s['scope']}),
                                   ('check_in', {'number': '8100', 'guest_name': 'Fictional restore guest'})):
                self.submit(web, '/app/pbx_setup/?view=hotel', 'hotel_action', fields | {'hotel_action': action}, {'hotel_action': action})
            self.php('discover'); self.php('seed-job')
            self.record('normal_https_source_company_pbx_users_hotel_future_job')
        else: self.record('normal_https_independent_target_identity')

    def es_api(self, command):
        # Fixed owned commands only; no customer identities or arbitrary API.
        if not (command.startswith('sofia profile internal flush_inbound_reg ') or command.startswith('sofia_contact ')
                or command in ('show channels as json', 'show calls as json')):
            raise ValueError('An unsupported native fixture command was requested.')
        s = self.s['event_socket']; connection = socket.create_connection((s['host'], int(s['port'])), timeout=5)
        connection.settimeout(5); buffer = bytearray()
        def frame():
            while True:
                split = buffer.find(b'\n\n')
                if split >= 0:
                    headers = dict(line.split(': ', 1) for line in buffer[:split].decode().splitlines() if ': ' in line)
                    size = int(headers.get('Content-Length', 0))
                    if not 0 <= size <= 1024**2: raise RuntimeError('Native response exceeds its bound.')
                    if len(buffer) >= split + 2 + size:
                        body = bytes(buffer[split + 2:split + 2 + size]); del buffer[:split + 2 + size]; return headers, body
                chunk = connection.recv(65536)
                if not chunk: raise RuntimeError('Native fixture connection closed.')
                buffer.extend(chunk)
        try:
            if frame()[0].get('Content-Type') != 'auth/request': raise RuntimeError('Native authentication challenge missing.')
            connection.sendall(('auth ' + s['password'] + '\n\n').encode())
            if not frame()[0].get('Reply-Text', '').startswith('+OK'): raise RuntimeError('Native authentication failed.')
            connection.sendall(('api ' + command + '\n\n').encode()); return frame()[1].decode()
        finally: connection.close()

    def peers(self):
        sip = load_module('sip_trunk_live', self.source / 'tests/sip_trunk_live.py')
        original = load_module('restore_qualification_native', self.source / 'tests/pbx_v20_restore_native.py')
        original.Path = lambda value: self.work / 'last-private-response.txt' if str(value).startswith('/var/lib/') else Path(value)
        status = self.php('status'); bind = status['bind']
        address = ipaddress.ip_address(bind)
        if address.version != 4 or address.is_unspecified or address.is_multicast:
            raise RuntimeError('The actual local engine IPv4 address is required.')
        # A local socket bind is an independent refusal for an off-machine address.
        probe = socket.socket(); probe.bind((bind, 0)); probe.close()
        records = self.s['users']; peers = [original.SourcePhone(u, self.s['realm'], bind) for u in records]
        return sip, original, peers, (bind, 5060)

    def clean_peers(self, peers, destination):
        failures = []
        for index,peer in enumerate(peers):
            stage='unregister';code=0
            try:
                code=peer.register(destination, expires=0)['code']
                if code != 200: failures.append(peer_failure(index,stage,code))
                stage='registration_ids'
                for callid in peer.registration_call_ids:
                    if not re.fullmatch('[a-f0-9]{24}@localfixture', callid): raise ValueError('Foreign registration cleanup refused.')
                    stage='flush_registration'
                    self.es_api('sofia profile internal flush_inbound_reg ' + callid)
                    stage='registration_ids'
                stage='contact_absence'
                if not self.es_api('sofia_contact ' + peer.auth_user + '@' + self.s['realm']).strip().startswith('error/'):
                    failures.append(peer_failure(index,stage,code))
            except Exception as error: failures.append(peer_failure(index,stage,code,error))
            finally:
                try:peer.close()
                except Exception as error:failures.append(peer_failure(index,'peer_close',code,error))
        if failures:
            error=RuntimeError('Owned peer cleanup is incomplete.');error.peer_cleanup_failure=restore_peer_failure_fields(failures)
            raise error

    def peer_ledger(self, peers):
        # Retain exact original REGISTER identities even when a later media
        # assertion fails. Never publish this private cleanup ledger.
        write_json(self.work / 'register-cleanup-private.json',
                   {'realm': self.s['realm'], 'ids': [cid for peer in peers for cid in peer.registration_call_ids]})

    def native(self, target=False):
        sip, original, peers, destination = self.peers(); caller, called = peers; call = None
        earlier_recordings = {row['media_uuid'] for row in self.php('status')['recordings']}
        primary=None
        try:
            for peer in peers:
                if peer.register(destination)['code'] != 200: raise RuntimeError('Actual original-tuple registration failed.')
                self.peer_ledger(peers)
            old = set(called.dialogs); call = caller.dial('8101', destination)
            if call['code'] != 200: raise RuntimeError('The real internal native call was not answered.')
            remote = wait_for(lambda: next((v for k, v in called.dialogs.items() if k not in old and v.get('acked')), None))
            time.sleep(7); sip.rtp_rate_check(call['media']); sip.rtp_rate_check(remote)
            original.decoded_tone_check(call['media'], 550); original.decoded_tone_check(remote, 440)
            caller.hangup(call); call = None; time.sleep(.5)
            if not target:
                # Record the answered-call identity BEFORE the subsequent
                # voicemail-deposit leg creates its separate recording. UUID
                # sort order does not identify two-way call content.
                def recorded_answered_call():
                    new = [row for row in self.php('status')['recordings'] if row['media_uuid'] not in earlier_recordings
                           and row['media'].get('exists') and row['media']['size'] > 32000]
                    if len(new) > 1: raise RuntimeError('Answered-call recording ownership is ambiguous.')
                    return new[0] if new else None
                recording = wait_for(recorded_answered_call)
                self.s['answered_recording_uuid'] = recording['media_uuid']; self.save()
            self.record('restored_original_credentials_two_way_decoded_native_audio' if target else 'source_real_two_way_recorded_call')
            if target:
                native = load_module('restore_qualification_prompts', self.source / 'tests/windows-native-acceptance.py')
                observer = native.NativePlayback(self.s['event_socket'], self.s['realm'])
                try:
                    call = called.dial('*97', destination)
                    if call['code'] != 200: raise RuntimeError('Restored native mailbox retrieval was not answered.')
                    index, prompt = observer.prompt(call['callid'], ['vm-enter_pass.wav', 'vm-listen_new.wav'])
                    if prompt.endswith('vm-enter_pass.wav'):
                        for digit in self.s['users'][1]['voicemail_pin'] + '#': called.dtmf(call, digit)
                        index, _ = observer.prompt(call['callid'], ['vm-listen_new.wav'], after=index)
                    called.dtmf(call, '1')
                    capsule = read_json(self.work / 'source-capsule-private.json')['payload']
                    message_name = Path(capsule['media']['voicemail']['relative']).name
                    observer.prompt(call['callid'], [message_name], after=index)
                    time.sleep(4); original.decoded_tone_check(call['media'], 440)
                    called.hangup(call); call = None; self.record('restored_original_native_voicemail_pin_rfc2833_retrieval')
                finally: observer.close()
            else:
                if called.register(destination, expires=0)['code'] != 200: raise RuntimeError('Native voicemail deposit isolation failed.')
                call = caller.dial('8101', destination)
                if call['code'] != 200: raise RuntimeError('Actual native voicemail deposit was not answered.')
                time.sleep(32); caller.hangup(call); call = None
                self.record('source_real_native_voicemail_deposit')
        except BaseException as error:
            primary=error;raise
        finally:
            if call is not None:
                try: (called if target else caller).hangup(call)
                except Exception: pass
            try:self.clean_peers(peers, destination)
            except Exception as cleanup:
                if primary is None:primary=cleanup;raise
                primary.peer_cleanup_failure=restore_peer_failure_fields(getattr(cleanup,'peer_cleanup_failure',[]))
            finally:
                if primary is not None:
                    primary.native_action='native-target' if target else 'native-source'
                    primary.completed_native_cases=completed_native_cases(self.facts,primary.native_action)

    def media(self):
        def finalized():
            status = self.php('status')
            vm = next((v for v in status['voicemail'] if v['voicemail_id'] == '8101' and v['media'].get('exists') and v['media']['size'] > 32000), None)
            recording = next((v for v in status['recordings'] if v['media_uuid'] == self.s.get('answered_recording_uuid')
                              and v['media'].get('exists') and v['media']['size'] > 32000), None)
            return (vm, recording) if vm and recording else None
        vm, recording = wait_for(finalized)
        result = {}
        for kind, entry in (('voicemail', vm), ('recording', recording)):
            path = Path(entry['media']['path'])
            with wave.open(str(path), 'rb') as wav:
                if wav.getsampwidth() != 2 or wav.getnframes() < wav.getframerate() * 4:
                    raise RuntimeError('Real recorded PCM media is not finalized.')
                rate, channels = wav.getframerate(), wav.getnchannels()
                raw = wav.readframes(wav.getnframes())
            values = struct.unpack('<' + 'h' * (len(raw) // 2), raw)
            ratios = []
            for frequency in (440,) if kind == 'voicemail' else (440, 550):
                best = 0
                for channel in range(channels):
                    samples = values[channel::channels][-rate * 2:]
                    energy = sum(x*x for x in samples)
                    real = sum(x*math.cos(2*math.pi*frequency*i/rate) for i, x in enumerate(samples))
                    imaginary = sum(x*math.sin(2*math.pi*frequency*i/rate) for i, x in enumerate(samples))
                    best = max(best, 2 * (real*real+imaginary*imaginary) / (len(samples)*max(energy, 1)))
                if best < .75: raise RuntimeError('Independent native recording tone decoding failed.')
                ratios.append(round(best, 4))
            storage = Path('C:/ProgramData/OpenWebPBX/storage').resolve()
            result[kind] = {'relative': path.resolve().relative_to(storage).as_posix(), 'sha256': digest(path), 'bytes': path.stat().st_size,
                            'decoded_ratios': ratios, 'rate': rate, 'channels': channels}
        write_json(self.work / 'media.json', result); self.record('real_native_voicemail_and_recording_file_decoding'); return result

    def backup_request(self, source_password=False):
        web = self.web(source_password)
        path = '/app/pbx_backups/index.php'
        denied = web.request(path, {'action': 'create', 'backup_uuid': ''})
        if denied[0] != 403: raise RuntimeError('Backup missing-CSRF denial failed.')
        backup_values = {'enabled': '0', 'schedule_hour': '0', 'retention': '2',
            'include_media': '1', 'passphrase': self.s['passphrase'], 'passphrase_confirm': self.s['passphrase'],
            'sftp_enabled': '0', 'sftp_port': '22'}
        self.submit(web, path, 'save', backup_values)
        before = {r['command_uuid'] for r in self.query('select command_uuid from v_pbx_backup_commands')}
        self.submit(web, path, 'create', {'backup_uuid': ''}, button=True)
        owner = self.s['owned']['owner_user_uuid']
        def requested():
            rows = [r for r in self.query("select command_uuid,status,backup_uuid,requested_by from v_pbx_backup_commands where action='create'")
                    if r['command_uuid'] not in before and r['requested_by'] == owner]
            if len(rows) > 1: raise RuntimeError('The normal administrator backup request is ambiguous.')
            return rows[0] if rows else None
        command = wait_for(requested)
        self.s.setdefault('owned_backup_commands', []).append(command['command_uuid']); self.save()
        # The actual installed task runs as SYSTEM. It may already be running;
        # request processing is idempotent and remains in the normal task path.
        child = subprocess.run([str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'),
            '-NoProfile', '-NonInteractive', '-Command', "Start-ScheduledTask -TaskName 'OpenWebPBX-Backups'"],
            env=self.backups.native_powershell_environment(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        if child.returncode: raise RuntimeError('The actual SYSTEM backup task did not start.')
        def completed():
            row = self.query("select command_uuid,status,backup_uuid from v_pbx_backup_commands where command_uuid='" + command['command_uuid'] + "'")[0]
            if row['status'] == 'failed': raise RuntimeError('Actual encrypted scheduled backup failed.')
            return row if row['status'] == 'completed' else None
        command = wait_for(completed, 600)
        row = self.query("select * from v_pbx_backups where command_uuid='" + command['command_uuid'] + "'")[0]
        if row['status'] != 'ready' or not row['include_media']: raise RuntimeError('The normal media backup is unavailable.')
        download = self.work / 'fixture.owpbx'
        url = web.base + '/app/pbx_backups/download.php?id=' + row['backup_uuid']
        with web.opener.open(url, timeout=120) as response, download.open('xb') as stream:
            if response.status != 200: raise RuntimeError('Authenticated ciphertext download failed.')
            while chunk := response.read(1024**2): stream.write(chunk)
        if digest(download) != row['sha256'] or download.stat().st_size != int(row['size_bytes']):
            raise RuntimeError('Complete authenticated ciphertext differs from the SYSTEM backup.')
        with self.backups.verify_archive(download, self.s['passphrase'], workspace=self.work) as (_, manifest):
            if not manifest.get('include_media'): raise RuntimeError('Native archive media manifest is missing.')
        self.cli(['verify', str(download)], password=self.s['passphrase'])
        self.cli(['verify', str(download)], password=self.s['passphrase'] + '-wrong', expect_failure=True)
        self.record('normal_admin_https_csrf_actual_system_encrypted_media_backup_download')
        # Separate the daily scheduler from the manual request. A real enabled
        # SYSTEM timer must create a requester-NULL command without our calling
        # create_archive/worker or inserting a command in SQL.
        existing = {r['command_uuid'] for r in self.query('select command_uuid from v_pbx_backup_commands')}
        self.submit(web, path, 'save', backup_values | {'enabled': '1', 'passphrase': '', 'passphrase_confirm': ''})
        if self.s['role']=='target':
            if not self.query("select last_scheduled_date=(now() at time zone 'UTC')::date same_day from v_pbx_backup_settings where singleton=1")[0]['same_day']:
                raise RuntimeError('The duplicate-day guard requires the source and target qualification to remain within the same UTC day.')
            # A real installed SYSTEM task must run with the unchanged restored
            # date and create NO duplicate before we make the bounded fixture
            # date overdue. Never insert a command or call worker() directly.
            start=time.time()
            command="Start-ScheduledTask -TaskName 'OpenWebPBX-Backups'"
            executable=str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe')
            child=subprocess.run([executable,'-NoProfile','-NonInteractive','-Command',command],env=self.backups.native_powershell_environment(),capture_output=True,timeout=30)
            if child.returncode:raise RuntimeError('The actual duplicate-day task did not start.')
            def fresh_task():
                command="Get-ScheduledTaskInfo -TaskName 'OpenWebPBX-Backups'|Select-Object LastTaskResult,@{Name='unix';Expression={([DateTimeOffset]$_.LastRunTime.ToUniversalTime()).ToUnixTimeSeconds()}}|ConvertTo-Json -Compress"
                child=subprocess.run([executable,'-NoProfile','-NonInteractive','-Command',command],env=self.backups.native_powershell_environment(),capture_output=True,timeout=30)
                if child.returncode:raise RuntimeError('The real backup task evidence is unavailable.')
                value=json.loads(child.stdout.decode('utf-8-sig'))
                return value if value['LastTaskResult']==0 and value['unix']>=int(start) else None
            wait_for(fresh_task,180)
            if any(r['command_uuid'] not in existing for r in self.query("select command_uuid from v_pbx_backup_commands where requested_by is null")):
                raise RuntimeError('The normal restored-TODAY schedule created a duplicate backup.')
            self.record('normal_restored_today_schedule_actual_system_task_no_duplicate')
            changed=self.query("with changed as (update v_pbx_backup_settings set last_scheduled_date=(now() at time zone 'UTC')::date-1 where singleton=1 and last_scheduled_date=(now() at time zone 'UTC')::date returning singleton) select * from changed")
            if len(changed)!=1:raise RuntimeError('The exact fixture-only previous-date seed failed.')
            self.facts['target_scheduler_date']='private_previous_date_fixture_seed_after_exact_restore_and_today_no_duplicate_proof'
        def scheduled():
            rows = [r for r in self.query("select command_uuid,status from v_pbx_backup_commands where action='create' and requested_by is null")
                    if r['command_uuid'] not in existing]
            if len(rows) > 1: raise RuntimeError('The daily scheduled backup is ambiguous.')
            return rows[0] if rows else None
        schedule = wait_for(scheduled, 180)
        self.s.setdefault('owned_scheduled_backup_commands', []).append(schedule['command_uuid']); self.save()
        def scheduled_complete():
            rows = self.query("select b.status,b.include_media,b.sha256,b.filename,c.status command_status from v_pbx_backups b join v_pbx_backup_commands c using(command_uuid) where c.command_uuid='" + schedule['command_uuid'] + "'")
            if not rows: return None
            if rows[0]['command_status'] == 'failed': raise RuntimeError('The real daily scheduled backup failed.')
            return rows[0] if rows[0]['command_status'] == 'completed' and rows[0]['status'] == 'ready' else None
        scheduled_row = wait_for(scheduled_complete, 600)
        if not scheduled_row['include_media'] or digest(self.backups.STORE / scheduled_row['filename']) != scheduled_row['sha256']:
            raise RuntimeError('The scheduled encrypted media archive is incomplete.')
        self.record('normal_admin_enabled_actual_system_timer_daily_encrypted_media_backup')
        # Transfer the automatic archive. Its static customer/global rows and
        # backup secret settings are quiescent; only the explicitly projected
        # command/archive lifecycle columns change after pg_dump.
        scheduled_id = self.query("select backup_uuid from v_pbx_backups where command_uuid='" + schedule['command_uuid'] + "'")[0]['backup_uuid']
        scheduled_download = self.work/'scheduled.owpbx'
        with web.opener.open(web.base+'/app/pbx_backups/download.php?id='+scheduled_id,timeout=120) as response, scheduled_download.open('xb') as stream:
            if response.status != 200: raise RuntimeError('Authenticated scheduled ciphertext download failed.')
            while chunk := response.read(1024**2):stream.write(chunk)
        if digest(scheduled_download)!=scheduled_row['sha256']:raise RuntimeError('The complete actual scheduled ciphertext differs.')
        self.cli(['verify',str(scheduled_download)],password=self.s['passphrase'])
        return scheduled_download

    def identity(self):
        # Independently re-read the target after restore. An image SID can be
        # reused between hosted images, but this target's original SID cannot
        # change. The authenticated jobs plus hardware/hostname prove separation.
        command="$admin=@(Get-LocalUser|Where-Object {$_.SID.Value -match '-500$'});if($admin.Count -ne 1){exit 2};@{sid=($admin[0].SID.Value -replace '-500$','');hardware=(Get-CimInstance Win32_ComputerSystemProduct).UUID;hostname=[Environment]::MachineName}|ConvertTo-Json -Compress"
        executable=str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe')
        child=subprocess.run([executable,'-NoProfile','-NonInteractive','-Command',command],env=self.backups.native_powershell_environment(),capture_output=True,timeout=30)
        if child.returncode:raise RuntimeError('The actual target machine identity could not be independently read.')
        machine=json.loads(child.stdout.decode('utf-8-sig'));hardware=machine['hardware'].upper()
        if not re.fullmatch('[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}',hardware) or hardware.replace('-','') in ('0'*32,'F'*32):
            raise RuntimeError('A real nonplaceholder hardware UUID is required.')
        key=derive(self.s['passphrase'],'machine-identity')
        hashed=lambda value:hmac.new(key,value.encode(),hashlib.sha256).hexdigest()
        result = {'template_key_sha256': digest('C:/ProgramData/fusionpbx/openweb-template.key'),
                  'certificate_sha256': self.s['certificate_sha256'],'machine_sid_hmac':hashed(machine['sid']),
                  'hardware_uuid_hmac':hashed(hardware),'hostname_hmac':hashed(machine['hostname'].upper()),
                  'runner_name_hmac':hashed(os.environ['RUNNER_NAME']),'hosted_job_id':self.s['hosted_job_id']}
        preserve_machine_identity(result,self.s)
        notification = Path('C:/ProgramData/OpenWebPBX/mobile-notifications/config.json')
        result['notification_sha256'] = digest(notification)
        return result

    def export_source(self):
        media = self.media(); archive = self.backup_request(); snapshot = self.snapshot('source')
        payload = {'schema': 1, 'run_id': self.s['run_id'], 'source_commit': self.s['source_commit'], 'base_suite_run_id': self.s['base_suite_run_id'],
            'candidate_sha256': self.s['candidate_sha256'], 'scope': self.s['scope'], 'owned': self.s['owned'],
            'service_name': self.s['service_name'], 'owned_job_uuid': self.s['owned_job_uuid'], 'media': media,
            'owned_backup_commands': self.s['owned_backup_commands'], 'owned_draft_ids': self.s.get('owned_draft_ids', []),
            'owned_scheduled_backup_commands': self.s['owned_scheduled_backup_commands'],
            'source_snapshot': snapshot, 'cipher_sha256': digest(archive), 'cipher_bytes': archive.stat().st_size} | self.identity()
        envelope = seal_capsule(payload, derive(self.s['passphrase'], 'capsule'))
        destination = Path(self.s['transfer_directory']); destination.mkdir()
        shutil.copyfile(archive, destination / 'fixture.owpbx'); write_json(destination / 'capsule.json', envelope)
        if set(p.name for p in destination.iterdir()) != {'fixture.owpbx', 'capsule.json'}:
            raise RuntimeError('The transfer export contains unexpected private material.')
        self.record('authenticated_ciphertext_only_distinct_job_transfer'); self.facts['state'] = 'passed'; write_json(self.facts_path, self.facts)

    def target_source(self):
        envelope = read_json(Path(self.s['transfer_directory']) / 'capsule.json')
        expected = {k: self.s[k] for k in ('run_id', 'source_commit', 'base_suite_run_id', 'candidate_sha256', 'scope', 'service_name')}
        expected['hosted_job_id']=self.s['source_hosted_job_id']
        archive = Path(self.s['transfer_directory']) / 'fixture.owpbx'
        payload = open_capsule(envelope, derive(self.s['passphrase'], 'capsule'), expected, archive)
        write_json(self.work / 'source-capsule-private.json', envelope)
        return payload, archive

    def file_inventory(self, paths):
        files, parents = {}, {}
        allowed = tuple(self.backups.ROOTS.values()) + tuple(self.backups.MEDIA.values())
        for path in paths:
            path = Path(path)
            if path.is_symlink(): raise RuntimeError('Linked private restore target refused.')
            files[str(path)] = {'exists': path.is_file(), 'sha256': digest(path) if path.is_file() else None}
            # Broadest owned directory root; do not read Program Files or the
            # unrelated FreeSWITCH program-root ACL through the product helper.
            matches = [root for root in allowed if root in path.parents]
            if not matches: raise RuntimeError('Restore mapping escaped the private directory roots.')
            boundary = min(matches, key=lambda root: len(root.parts))
            for parent in (path.parent, *path.parent.parents):
                parents[str(parent)] = {'exists': parent.is_dir()}
                if parent == boundary: break
        existing = [p for p, v in files.items() if v['exists']] + [p for p, v in parents.items() if v['exists']]
        acls = self.backups.control('acl-read', {'paths': existing})
        for group in (files, parents):
            for name, value in group.items():
                if value['exists']: value['sddl'] = acls[name]
        return {'files': files, 'parents': parents}

    def late_restore(self):
        payload, archive = self.target_source(); before = self.snapshot('target-before'); identity = self.identity()
        distinct_installations(payload['source_snapshot'] | {k: payload[k] for k in identity}, before | identity)
        with self.backups.verify_archive(archive, self.s['passphrase'], workspace=self.work) as (_, manifest):
            mapping = self.backups.restore_targets(manifest)
        inventory = self.file_inventory(mapping.values()); write_json(self.work / 'target-files-before.json', inventory)
        # Explicitly verify refusal precedes any mutation.
        self.cli(['restore', str(archive), '--confirm-database', self.settings['database.0.name']],
                 password=self.s['passphrase'] + '-wrong', expect_failure=True)
        compare_snapshots(before, self.snapshot('target-wrongpass'), 'factory-recovery')
        if self.identity() != identity or self.file_inventory(mapping.values()) != inventory:
            raise RuntimeError('Wrong-passphrase refusal changed target private bytes or ACLs.')
        self.record('wrong_passphrase_restore_refused_before_target_mutation')
        original = self.backups.atomic_copy; witness = {}
        native_media_files = [self.backups.STATE / 'storage' / media['relative'] for media in payload['media'].values()]
        self.backups.atomic_copy = late_copy_fault(original, self.backups.KEY,
            self.backups.STATE / 'mobile-notifications/config.json', [], witness, self.backups.BackupError,
            media_paths=native_media_files)
        failed = False
        try:
            self.cli(['restore', str(archive), '--confirm-database', self.settings['database.0.name']],
                     password=self.s['passphrase'], expect_failure=True); failed = True
        finally: self.backups.atomic_copy = original; write_json(self.work / 'late-copy-witness.json', witness)
        if not failed or not witness['injected'] or witness['categories'] != ['key', 'media', 'notification']:
            raise RuntimeError('The required real late-copy restore failure was not exercised.')
        if not {entry['sha256'] for entry in witness['copied'] if entry['category'] == 'media'}.intersection(
                media['sha256'] for media in payload['media'].values()):
            raise RuntimeError('The late fault did not copy an actual recorded native voicemail or recording.')
        journal = read_json(self.backups.RESTORE / 'journal.json')
        if journal['state'] == 'recovery_required':
            if not all(self.backups.held(s) for s in self.backups.HELD_UNITS):
                raise RuntimeError('Interrupted recovery lacks durable service holds.')
            self.record('late_failure_durable_explicit_recovery_holds'); self.cli(['recover'])
            journal = read_json(self.backups.RESTORE / 'journal.json')
        if journal['state'] != 'recovered': raise RuntimeError('Actual late failure did not recover the factory.')
        compare_snapshots(before, self.snapshot('target-recovered'), 'factory-recovery')
        if self.identity() != identity or self.file_inventory(mapping.values()) != inventory:
            raise RuntimeError('Late restore recovery did not restore exact target private bytes, absence and parent ACLs.')
        if any(self.backups.held(s) for s in self.backups.HELD_UNITS): raise RuntimeError('Recovered factory still has unexpected holds.')
        shutil.move(self.backups.RESTORE, self.work / 'recovered-attempt')
        self.record('late_key_notification_media_failure_exact_factory_database_bytes_acl_recovery')

    def restore(self):
        payload, archive = self.target_source()
        self.cli(['restore', str(archive), '--confirm-database', self.settings['database.0.name']], password=self.s['passphrase'])
        if not all(self.backups.held(s) for s in self.backups.HELD_UNITS): raise RuntimeError('Restore must initially hold all four service classes.')
        self.s['owned'] = payload['owned']; self.s['owned_job_uuid'] = payload['owned_job_uuid']
        self.s['owned_backup_commands'] = payload['owned_backup_commands']; self.s['owned_draft_ids'] = payload['owned_draft_ids']
        self.s['owned_scheduled_backup_commands'] = payload['owned_scheduled_backup_commands']
        self.save(); self.php('discover')
        after = self.snapshot('target-restored'); before = read_json(self.work / 'target-before-database.json')
        if before['target_owned'] != after['target_owned']: raise RuntimeError('Restore overwrote replacement DB identity, roles or credentials.')
        compare_snapshots(payload['source_snapshot'], after, 'source-restored')
        identity = self.identity()
        if identity['template_key_sha256'] != payload['template_key_sha256'] or identity['notification_sha256'] != payload['notification_sha256']:
            raise RuntimeError('Source private encryption or notification identity was not restored.')
        if (identity['certificate_sha256'] == payload['certificate_sha256'] or identity['hardware_uuid_hmac']==payload['hardware_uuid_hmac']
                or identity['hostname_hmac']==payload['hostname_hmac'] or identity['hosted_job_id']==payload['hosted_job_id']):
            raise RuntimeError('Restore adopted source machine or certificate-store bindings.')
        tls = read_json(self.backups.STATE / 'phone-tls.json')
        if tls.get('CertificateThumbprint') or tls.get('RestorePending') is not True:
            raise RuntimeError('Source phone TLS material must be inactive and require target preparation.')
        for media in payload['media'].values():
            file = self.backups.STATE / 'storage' / media['relative']
            if digest(file) != media['sha256'] or file.stat().st_size != media['bytes']:
                raise RuntimeError('Actual source native voicemail/recording bytes changed.')
        self.web(True); self.record('supported_private_cli_clean_server_restore_target_identity_all_holds_admin_https')
        self.s['job_due'] = True; self.save(); job = self.php('seed-job')
        if job['state'] != 'waiting' or job['attempts'] != 0: raise RuntimeError('A held restored job was claimed.')

    def activate(self, selection):
        if selection not in self.backups.HELD_UNITS: raise ValueError('Invalid explicit service activation.')
        self.cli(['activate', '--' + selection, '--confirm-server', 'windowsqa.example.invalid'])
        if self.backups.held(selection): raise RuntimeError('Selected activation remained held.')
        self.record('explicit_restored_' + selection + '_activation')

    def job(self):
        sip, original, peers, destination = self.peers(); caller = peers[0]
        try:
            if caller.register(destination)['code'] != 200: raise RuntimeError('The restored wakeup phone did not register.')
            self.peer_ledger(peers)
            before = set(caller.dialogs); time.sleep(3)
            job = self.php('job-status')
            if job['state'] != 'waiting' or job['attempts'] != 0 or set(caller.dialogs) != before:
                raise RuntimeError('Held job startup generated a call before explicit activation.')
            self.activate('jobs')
            key, remote = wait_for(lambda: next(((k, v) for k, v in caller.dialogs.items() if k not in before and v.get('acked')), None), 120)
            time.sleep(3)
            if remote['received'] < 25: raise RuntimeError('Restored native wakeup has no real RTP.')
            remote.setdefault('dtmf_events', []).append({'digit': 1})
            def completed():
                state = self.php('job-status')
                if state['state'] == 'failed': raise RuntimeError('The actual restored C# job failed.')
                return state if state['state'] == 'completed' else None
            state = wait_for(completed)
            if state['attempts'] != 1: raise RuntimeError('Restored durable job attempted an unexpected number of calls.')
            self.record('restored_future_job_held_then_actual_native_wakeup_claim_rtp_rfc2833_completion')
        finally: self.clean_peers(peers, destination)

    def cleanup(self):
        if 'owned' in self.s:
            if json.loads(self.es_api('show channels as json'))['row_count'] != 0: raise RuntimeError('Cleanup refuses active native calls.')
            self.s['cleanup_native'] = True; self.save(); self.php('cleanup')
            for command in self.s.get('owned_backup_commands', []) + self.s.get('owned_scheduled_backup_commands', []):
                if self.query("select command_uuid from v_pbx_backup_commands where command_uuid='" + command + "'"):
                    raise RuntimeError('An exact owned global backup command survived cleanup.')
                if self.query("select backup_uuid from v_pbx_backups where command_uuid='" + command + "'"):
                    raise RuntimeError('Exact owned encrypted backup metadata survived cleanup.')
            for draft in self.s.get('owned_draft_ids', []):
                if self.query("select draft_uuid from v_pbx_setup_drafts where draft_uuid='" + draft + "'"):
                    raise RuntimeError('An exact owned guided-setup draft survived cleanup.')
            for root in (self.backups.STATE / 'storage/openwebpbx' / self.s['owned']['domain_uuid'],
                         self.backups.STATE / 'storage/voicemail/default' / self.s['realm'],
                         self.backups.STATE / 'storage/recordings' / self.s['realm']):
                if root.is_dir() and not root.is_symlink(): shutil.rmtree(root)
        self.record('owned_rows_contacts_calls_media_factory_cleanup')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--action', choices=('setup', 'native-source', 'export-source', 'late-restore', 'restore',
        'activate-calls', 'native-target', 'job', 'activate-updates', 'activate-backups', 'target-backup', 'cleanup'), required=True)
    args = parser.parse_args(); qualification = Qualification(args.input)
    actions = {'setup': qualification.setup, 'native-source': qualification.native, 'export-source': qualification.export_source,
        'late-restore': qualification.late_restore, 'restore': qualification.restore,
        'activate-calls': lambda: qualification.activate('calls'), 'native-target': lambda: qualification.native(True),
        'job': qualification.job, 'activate-updates': lambda: qualification.activate('updates'),
        'activate-backups': lambda: qualification.activate('backups'), 'target-backup': lambda: qualification.backup_request(True),
        'cleanup': qualification.cleanup}
    actions[args.action]()


if __name__ == '__main__':
    try: main()
    except BaseException as error:
        # Only type/location go to the caller. Exception messages, SQL, HTTP
        # bodies, credential input and real native streams remain private.
        trace = error.__traceback__
        while trace and trace.tb_next: trace = trace.tb_next
        basename = Path(trace.tb_frame.f_code.co_filename).name if trace else 'windows-restore-qualification.py'
        facts = {'state': 'failed', 'error_type': type(error).__name__, 'active_case': 'restore_qualification',
                 'source_basename': basename if re.fullmatch(r'[A-Za-z0-9_.-]{1,120}', basename) else 'unknown',
                 'source_line': trace.tb_lineno if trace and 0 < trace.tb_lineno < 1000000 else 0}
        observation = restore_fixture_failure_fields(getattr(error, 'fixture_failure', None), 'cleanup')
        if observation: facts['fixture_failure'] = observation
        facts.update(restore_identity_failure_fields(error))
        peer_failures=restore_peer_failure_fields(getattr(error,'peer_cleanup_failure',None))
        if peer_failures:facts['peer_cleanup_failure']=peer_failures
        cases=restore_completed_native_cases(getattr(error,'completed_native_cases',None),getattr(error,'native_action',None))
        if cases is not None:facts['completed_native_cases']=cases
        print(json.dumps(facts)); sys.exit(1)
