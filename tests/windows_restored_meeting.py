"""Separate, explicit restored-target browser media supplement; no factory reset."""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import types

UUID = r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}'
TABLES = ('v_pbx_meetings', 'v_pbx_meeting_members')
GATE = 'restored_browser_conference_two_way_decoded_audio_video'


FAILURE_CASES = ('unavailable', 'native_windows_meeting_browser_media', 'native_windows_meeting_dependencies',
                 'native_windows_meeting_unknown', *( 'native_windows_meeting_' + name for name in
                 ('browser_start', 'owner_page', 'create', 'host_join', 'guest_join', 'admission', 'decoded_media', 'mute', 'unmute', 'end')))
FAILURE_TYPES = ('RuntimeError', 'ValueError', 'TypeError', 'KeyError', 'AttributeError', 'AssertionError',
                 'TimeoutError', 'TimeoutExpired', 'OSError', 'FileNotFoundError', 'PermissionError',
                 'JSONDecodeError', 'SSLError', 'HTTPError', 'URLError', 'external_error')
FAILURE_SOURCES = ('windows_restored_meeting.py', 'windows-restore-qualification.py',
                   'windows-meet-browser.py', 'windows_meeting_owned_process.py')


def failure_record(error):
    """Read only closed failure metadata; messages, locals and streams stay private."""
    kind = type(error).__name__
    frames = []; trace = error.__traceback__
    expected = {os.path.normcase(os.path.abspath(Path(__file__).with_name(name))): name for name in FAILURE_SOURCES}
    for _ in range(32):
        if trace is None: break
        source = expected.get(os.path.normcase(os.path.abspath(trace.tb_frame.f_code.co_filename)))
        if source is not None and type(trace.tb_lineno) is int and 0 < trace.tb_lineno < 1000000:
            frames.append({'source_basename': source, 'source_line': trace.tb_lineno})
        trace = trace.tb_next
    case = getattr(error, 'restored_meeting_active_case', None)
    def flag(name):
        value = getattr(error, name, None)
        return value if type(value) is bool else None
    record = {'schema': 1, 'state': 'failed', 'producer': 'windows_restored_meeting.py',
            'error_type': kind if kind in FAILURE_TYPES else 'external_error',
            'cleanup_verified': getattr(error, 'restored_meeting_cleanup_verified', False) is True,
            'source_frames': frames[-4:], 'active_case': case if type(case) is str and case in FAILURE_CASES else 'unavailable',
            'owned_process_cleanup_failed': flag('owned_process_cleanup_failed'),
            'owned_processes_closed': flag('owned_processes_closed')}
    if record['active_case'] == 'native_windows_meeting_browser_start':
        try:
            paths = getattr(error, 'meeting_path_failure', None)
            if type(paths) is dict and set(paths) == {'meeting_path'}:
                record.update(restored_path_fields(paths['meeting_path']))
        except BaseException: pass
    return record


def observe_failure_case(error, fixture):
    try:
        case = getattr(fixture, 'active_case', None)
        if type(case) is str and case in FAILURE_CASES:
            error.restored_meeting_active_case = case
    except BaseException: pass


def restored_path_fields(record):
    ws = dict(booleans={'observed','connected','sent','response_received','closed_exact','large_sent','large_response_received'}, integers={'status_code':699,'large_status_code':699,'elapsed_ms':6000}, enums={'phase':{'connect','send','receive','complete','unavailable'},'error_kind':{'none','timeout','tls','websocket','other','unavailable'}})
    pg = dict(booleans={'observed','read_only','query_visible','counts_capped'}, integers={name:512 for name in ('total','active','idle','idle_in_transaction','wait_lock','meeting_select','meeting_update','meeting_insert','meeting_other','meeting_wait_lock')}, enums={'error_kind':{'none','timeout','database','unavailable'}})
    http = dict(booleans={'observed','completed','ok'}, integers={'http_status':599,'elapsed_ms':5000}, enums={'member_state':{'waiting','admitted','left','removed','unavailable','other'},'error_kind':{'none','timeout','tls','http','invalid_json','other','unavailable'}})
    specs={'backend':ws,'frontend':ws,'fragmented_backend':ws,'fragmented_frontend':ws,'database':pg,'host_http':http,'guest_http':http}
    if not isinstance(record,dict) or set(record)!={'before','after'}:
        return {}
    safe={}
    for stage in ('before','after'):
        row=record[stage]
        if not isinstance(row,dict) or set(row)!=set(specs):
            return {}
        safe[stage]={}
        for name,spec in specs.items():
            value=row[name]
            if not isinstance(value,dict) or set(value)!=spec['booleans']|set(spec['integers'])|set(spec['enums']):
                return {}
            if any(type(value[key]) is not bool for key in spec['booleans']) or any(type(value[key]) is not int or not 0<=value[key]<=maximum for key,maximum in spec['integers'].items()) or any(not isinstance(value[key],str) or value[key] not in allowed for key,allowed in spec['enums'].items()):
                return {}
            safe[stage][name]=dict(value)
    return {'meeting_path':safe}


def require(value):
    if not value: raise RuntimeError('The exact restored conference supplement refused.')


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def ordinary(path, directory=False):
    path = Path(path)
    require(path.is_dir() if directory else path.is_file())
    for item in (path, *path.parents):
        info = item.lstat()
        require(not item.is_symlink() and not (getattr(info, 'st_file_attributes', 0) & 0x400))
    return path


def digest(path):
    path = ordinary(path); require(path.stat().st_size <= 8 * 1024**2)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path, maximum=2 * 1024**2):
    path = ordinary(path); require(0 < path.stat().st_size <= maximum)
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result); result[key] = value
        return result
    return json.loads(path.read_text(encoding='utf-8-sig'), object_pairs_hook=pairs,
                      parse_constant=lambda _: require(False))


def write_new(path, value):
    raw = canonical(value)
    with Path(path).open('xb') as file:
        file.write(raw); file.flush(); os.fsync(file.fileno())


@contextlib.contextmanager
def native_environment():
    original = os.environ.get('OPENWEB_WINDOWS_NATIVE_TEST')
    os.environ['OPENWEB_WINDOWS_NATIVE_TEST'] = '1'
    try: yield
    finally:
        if original is None: os.environ.pop('OPENWEB_WINDOWS_NATIVE_TEST', None)
        else: os.environ['OPENWEB_WINDOWS_NATIVE_TEST'] = original


def admit(q, adapter):
    s = q.s; adapter = ordinary(adapter, True)
    require(os.name == 'nt' and os.environ.get('OPENWEB_WINDOWS_RESTORE_TEST') == '1'
            and os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
            and os.environ.get('GITHUB_REPOSITORY') == 'embire2/openwebpbx'
            and os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch')
    require(s['role'] == 'target' and s['run_id'] == os.environ['GITHUB_RUN_ID']
            and s['source_commit'] == os.environ['GITHUB_SHA'] and s['disposable'] is True)
    require(adapter.parent == Path(os.environ['ProgramData']) / 'OpenWebPBX/native-qualification'
            and re.fullmatch('[a-f0-9]{24}', adapter.name) and adapter.name != s['scope'] and not list(adapter.iterdir()))
    ordinary(q.path); ordinary(q.work, True); ordinary(q.source, True)
    require(q.source == Path(os.environ['GITHUB_WORKSPACE']))
    require(q.work == Path(os.environ['ProgramData']) / 'OpenWebPBX/restore-qualification' / s['scope'])
    require(GATE not in q.facts.get('gates', {}))
    for name in ('explicit_restored_calls_activation', 'restored_original_credentials_two_way_decoded_native_audio',
                 'restored_original_native_voicemail_121_pin_free_retrieval', 'restored_original_native_clock_1026_Nathaniel_GMT2_audio'):
        require(q.facts.get('gates', {}).get(name) == 'passed')
    require(not q.backups.held('calls') and all(q.backups.held(name) for name in ('jobs', 'updates', 'backups')))
    channels = json.loads(q.es_api('show channels as json'))
    require(type(channels.get('row_count')) is int and channels['row_count'] == 0)


def rows(q):
    # One SQL statement gives a single MVCC snapshot of every complete row.
    parts = ["'" + table + "',(select coalesce(json_agg(row_to_json(t)),'[]'::json) from public." + table + ' t)' for table in TABLES]
    parts.append("'bindings',(select coalesce(json_agg(row_to_json(t)),'[]'::json) from public.v_sip_profile_settings t where sip_profile_uuid='cfb1c835-c30c-409b-bff7-a893a7e84df1')")
    answer = q.query('select json_build_object(' + ','.join(parts) + ') as inventory')
    require(type(answer) is list and len(answer) == 1 and set(answer[0]) == {'inventory'})
    result = answer[0]['inventory']; require(type(result) is dict and set(result) == set(TABLES) | {'bindings'})
    for name, value in result.items():
        require(type(value) is list and len(value) <= 2048 and all(type(row) is dict for row in value))
        result[name] = sorted(value, key=canonical)
    return result


def preserved_rows(before, after, identity, subject, ledger=None, successful=False):
    require(set(before) == set(after) == set(TABLES) | {'bindings'})
    require(before['bindings'] == after['bindings'])
    old = {row['meeting_uuid']: row for row in before['v_pbx_meetings']}
    current = {row['meeting_uuid']: row for row in after['v_pbx_meetings']}
    require(len(old) == len(before['v_pbx_meetings']) and len(current) == len(after['v_pbx_meetings']))
    require(all(current.get(key) == row for key, row in old.items()))
    added = set(current) - set(old); require(len(added) <= 1)
    if successful: require(len(added) == 1 and ledger is not None)
    owned = next(iter(added), None)
    if owned:
        row = current[owned]
        require(re.fullmatch(UUID, owned) and row['domain_uuid'] == identity['domain_uuid']
                and row['owner_uuid'] == identity['owner_user_uuid'] and row['subject'] == subject)
        if ledger is not None:
            require(type(ledger) is dict and set(ledger) == {'schema', 'meeting_uuid', 'subject'}
                    and type(ledger['schema']) is int and ledger['schema'] == 1
                    and ledger['meeting_uuid'] == owned and ledger['subject'] == subject)
        if successful: require(row['ended_at'] is not None)
    else: require(ledger is None)
    for table in ('v_pbx_meeting_members',):
        remaining = [row for row in after[table] if row.get('meeting_uuid') != owned]
        require(remaining == before[table])
    if owned:
        members = [row for row in after['v_pbx_meeting_members'] if row.get('meeting_uuid') == owned]
        require(len(members) <= 2 and len({row['member_uuid'] for row in members}) == len(members)
                and all(re.fullmatch(UUID, row['member_uuid']) for row in members))
        require(all(row['state'] in ('waiting', 'admitted', 'left', 'removed') for row in members))
    return owned


def recovery_file_digest(path, expected_size, maximum):
    path = ordinary(path)
    require(type(expected_size) is int and type(maximum) is int and 0 <= expected_size <= maximum)
    result = hashlib.sha256(); count = 0
    with path.open('rb') as stream:
        before = os.fstat(stream.fileno()); require(before.st_size == expected_size)
        while True:
            chunk = stream.read(min(1024**2, expected_size - count + 1))
            if not chunk: break
            count += len(chunk); require(count <= expected_size); result.update(chunk)
        after = os.fstat(stream.fileno())
        current = ordinary(path).stat()
        require(count == expected_size == after.st_size == current.st_size
                and (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino) == (current.st_dev, current.st_ino))
    return result.hexdigest()


def recovery_inventory(q, root):
    journal = root / 'journal.json'; copies_root = root / 'factory-files'
    if not journal.exists():
        if copies_root.exists(): require(next(ordinary(copies_root, True).iterdir(), None) is None)
        return {}, 0
    # The journal retains the old metadata bound. Recovery data files instead
    # use the actual core producer's existing archive/data policy, streamed.
    original_journal = digest(journal); value = read_json(journal, 8 * 1024**2)
    maximum_files, maximum_bytes = q.backups.MAX_FILES, q.backups.MAX_ARCHIVE
    require(type(maximum_files) is int and 0 < maximum_files <= 500000
            and type(maximum_bytes) is int and 0 < maximum_bytes <= 50 * 1000**3)
    require(type(value) is dict and type(value.get('schema')) is int and value['schema'] == 1
            and type(value.get('factory_security_version')) is int and value['factory_security_version'] == 1
            and type(value.get('files')) is dict and len(value['files']) <= maximum_files)
    copies_root = ordinary(copies_root, True); names = set(); targets = set(); sizes = {}; hashes = {}; total = 0
    allowed = tuple(q.backups.ROOTS.values()) + tuple(q.backups.MEDIA.values())
    for target_name, entry in value['files'].items():
        require(type(target_name) is str)
        target = Path(target_name)
        require(target.is_absolute() and str(target) == target_name and '..' not in target.parts
                and target not in targets and any(target == root or root in target.parents for root in allowed))
        for item in (target, *target.parents): require(not q.backups.reparse(item))
        targets.add(target)
        require(type(entry) is dict and type(entry.get('exists')) is bool)
        if not entry['exists']:
            require('copy' not in entry); continue
        name, size, checksum = entry.get('copy'), entry.get('size'), entry.get('sha256')
        require(type(name) is str and re.fullmatch(r'0|[1-9][0-9]{0,5}', name)
                and int(name) < maximum_files and name not in names
                and type(size) is int and 0 <= size <= maximum_bytes
                and type(entry.get('mode')) is int and 0 <= entry['mode'] <= 0o7777
                and type(entry.get('sddl')) is str and 0 < len(entry['sddl']) <= 32768
                and type(checksum) is str and re.fullmatch('[a-f0-9]{64}', checksum))
        names.add(name); total += size; require(total <= maximum_bytes)
        key = 'factory-files/' + name; sizes[key] = size; hashes[key] = checksum
    children = []
    for child in copies_root.iterdir():
        require(len(children) < len(names)); children.append(child)
    require(len(children) == len(names) and {path.name for path in children} == names)
    dump = ordinary(root / 'factory.dump'); size = dump.stat().st_size
    checksum = value.get('factory_dump_sha256')
    require(type(checksum) is str and re.fullmatch('[a-f0-9]{64}', checksum)
            and 0 <= size <= maximum_bytes and total + size <= maximum_bytes)
    sizes['factory.dump'] = size; hashes['factory.dump'] = checksum
    for key, size in sizes.items():
        require(recovery_file_digest(root / key, size, maximum_bytes) == hashes[key])
    require(digest(journal) == original_journal)
    return {key: (sizes[key], hashes[key]) for key in sizes}, len(names)


def stable_files(q):
    root = ordinary(q.backups.RESTORE, True)
    recovery, copy_count = recovery_inventory(q, root); entries = []
    for path in root.rglob('*'):
        require(len(entries) < 64 + copy_count); entries.append(path)
    result = {}
    for path in entries:
        if path.is_dir(): continue
        key = path.relative_to(root).as_posix()
        result[str(path.relative_to(root))] = recovery_file_digest(path, recovery[key][0], q.backups.MAX_ARCHIVE) if key in recovery else digest(path)
        if key in recovery: require(result[str(path.relative_to(root))] == recovery[key][1])
    for p in entries: ordinary(p, p.is_dir())
    require('hold-calls' not in result and all('hold-' + name in result for name in ('jobs', 'updates', 'backups')))
    for name, path in {'original_input': q.path, 'original_ca': q.s['web_ca'], 'runtime': q.backups.STATE / 'runtime.json',
                       'meet_ca': q.backups.STATE / 'meet-ca.pem', 'phone_tls': q.backups.STATE / 'phone-tls.json',
                       'installed_configuration': q.backups.CONFIG}.items(): result['file:' + name] = digest(path)
    return result


def closed_summary(record):
    require(type(record) is dict and set(record) == {'checks', 'wss_roundtrips', 'host_frames', 'guest_frames',
                                                    'host_tone_ratio', 'guest_tone_ratio', 'physical_camera'})
    require(type(record['checks']) is int and record['checks'] == 9 and type(record['wss_roundtrips']) is int and record['wss_roundtrips'] == 16)
    require(all(type(record[k]) is int and 10 <= record[k] <= 2147483647 for k in ('host_frames', 'guest_frames')))
    require(all(type(record[k]) in (int, float) and .65 < record[k] <= 1 for k in ('host_tone_ratio', 'guest_tone_ratio')))
    require(record['physical_camera'] == 'unqualified')
    return dict(record)


def qualify(q, adapter):
    adapter = Path(adapter); admit(q, adapter)
    before_files = stable_files(q); before = rows(q)
    identity = q.s['owned']; subject = 'Owned Windows video ' + adapter.name
    require(not any(row['subject'] == subject for row in before['v_pbx_meetings']))
    require(all(re.fullmatch(UUID, identity[key]) for key in ('domain_uuid', 'owner_user_uuid', 'service_uuid', 'tenant_uuid', 'home_domain_uuid')))
    service = q.query("select s.service_uuid,s.domain_uuid,s.tenant_uuid,d.domain_name,t.home_domain_uuid,t.owner_user_uuid from v_pbx_services s join v_domains d using(domain_uuid) join v_pbx_tenants t using(tenant_uuid) where s.service_uuid='" + identity['service_uuid'] + "'")
    require(service == [identity])
    administrators = q.query("select user_uuid,domain_uuid,username,user_enabled from v_users where user_uuid='" + identity['owner_user_uuid'] + "'")
    require(len(administrators) == 1 and administrators[0]['username'] == q.s['admin_email'] and administrators[0]['user_enabled'] in ('true', True))
    admin = administrators[0]
    domains = q.query('select domain_uuid,domain_name from v_domains order by domain_uuid')
    native = {'schema': 1, 'restore_server': True, 'scope': adapter.name, 'owned': identity,
              'baseline': {'users': administrators, 'domains': domains}, 'factory_admin': admin,
              'restored_target_binding': {'run_id': q.s['run_id'], 'source_commit': q.s['source_commit'],
                                          'restore_scope': q.s['scope'], 'restore_input_sha256': before_files['file:original_input']}}
    evidence = adapter / 'evidence'; evidence.mkdir(); write_new(adapter / 'input.json', native)
    adapter_input_sha256 = digest(adapter / 'input.json')
    write_new(evidence / 'restored-baseline.private.json', before)
    ca = ordinary(q.s['web_ca']); pem = ca.read_text(); require(pem.count('-----BEGIN CERTIFICATE-----') == 1 and 'PRIVATE KEY' not in pem)
    ssl.PEM_cert_to_DER_cert(pem); shutil.copyfile(ca, evidence / 'fixture-root.pem')
    browser = load('restored_original_browser', q.source / 'tests/windows-meet-browser.py')
    process = load('restored_owned_browser_process', q.source / 'tests/windows_meeting_owned_process.py')
    proof = []; lifecycle = []; primary = None; clean = False
    ledger_path = evidence / 'restored-meeting.private.json'
    def record(name, **fields):
        require(name == 'native_windows_meeting_browser_video_audio' and not proof)
        proof.append(closed_summary(fields))
    def command(arguments, *, capture_output, text, timeout):
        require(capture_output is True and text is True and timeout == 240 and len(lifecycle) < 2)
        phase = 'dependencies' if not lifecycle else 'browser'
        require(Path(arguments[0]).name.lower() == 'node.exe')
        if phase == 'browser':
            require(arguments[1:] == [str(q.source / 'tests/windows-meet-browser.cjs'), str(evidence / 'meeting-browser.private.json')])
            settings = read_json(arguments[2]); settings['restoredLedger'] = str(ledger_path)
            Path(arguments[2]).write_bytes(canonical(settings))
        work = evidence / ('process-' + phase); work.mkdir()
        result = process.run(arguments, work, timeout=timeout)
        owned = read_json(work / 'process.safe.json', 2048)
        require(set(owned) == {'schema', 'created_suspended', 'assigned_before_resume', 'resumed', 'owned_job_terminated',
                              'exit_code', 'owned_processes_closed', 'handles_closed', 'ordinary_exit'}
                and type(owned['schema']) is int and owned['schema'] == 1
                and all(owned[key] is True for key in ('created_suspended', 'assigned_before_resume', 'resumed', 'owned_processes_closed', 'handles_closed', 'ordinary_exit'))
                and owned['owned_job_terminated'] is False and type(owned['exit_code']) is int
                and owned['exit_code'] == result.returncode)
        lifecycle.append(phase); return result
    fixture = types.SimpleNamespace(evidence=evidence, source=q.source, php=Path('C:/OpenWebPBX/php/php.exe'),
                                    script=q.source / 'tests/windows-native-fixture.php', path=adapter / 'input.json',
                                    s={'scope': adapter.name, 'public_url': 'https://windowsqa.example.invalid:8443'}, record=record)
    browser.subprocess = types.SimpleNamespace(run=command)
    try:
        web = q.web(True); fixture.web = types.SimpleNamespace(open=web.opener)
        with native_environment(): browser.run(fixture)
        require(lifecycle == ['dependencies', 'browser'] and len(proof) == 1)
    except BaseException as error:
        primary = error
        observe_failure_case(error, fixture)
    finally:
        try:
            require(not getattr(primary, 'owned_process_cleanup_failed', False)
                    and getattr(primary, 'owned_processes_closed', True))
            ledger = read_json(ledger_path, 1024) if ledger_path.exists() else None
            after = rows(q); owned = preserved_rows(before, after, identity, subject, ledger, primary is None)
            # On browser failure, use only this newly observed row with exact
            # owner/domain/subject, never a subject-based broad cancel.
            if owned and after['v_pbx_meetings'][[r['meeting_uuid'] for r in after['v_pbx_meetings']].index(owned)]['ended_at'] is None:
                q.submit(q.web(True), '/app/pbx_meet/', 'cancel', {'id': owned, 'confirm_cancel': '1'}, {'id': owned})
                after = rows(q); preserved_rows(before, after, identity, subject, ledger, True)
            require(stable_files(q) == before_files)
            require(digest(adapter / 'input.json') == adapter_input_sha256
                    and digest(evidence / 'fixture-root.pem') == before_files['file:original_ca'])
            channels = json.loads(q.es_api('show channels as json'))
            require(type(channels.get('row_count')) is int and channels['row_count'] == 0)
            require(not (evidence / 'meeting-browser.private.json').exists())
            entries = list(adapter.rglob('*')); require(len(entries) <= 30000)
            for path in entries: ordinary(path, path.is_dir())
            saved = q.work / 'restored-meeting-evidence-private'; require(not saved.exists())
            shutil.move(str(adapter), str(saved)); require(not adapter.exists())
            clean = True
        except BaseException as error:
            if primary is None: primary = error
            else: primary.restored_meeting_cleanup_failed = True
    if primary is not None:
        primary.restored_meeting_cleanup_verified = clean
        raise primary
    summary = {'schema': 1, 'state': 'passed', 'producer': 'windows_restored_meeting.py',
               'run_id': q.s['run_id'], 'source_commit': q.s['source_commit'],
               'base_suite_run_id': q.s['base_suite_run_id'], 'base_archive_sha256': q.s['candidate_sha256'],
               'media': proof[0], 'original_meetings_and_members_preserved': True, 'original_bindings_and_holds_preserved': True,
               'owned_processes_closed': True, 'owned_native_scope_removed': clean, 'remaining_calls': 0,
               'existing_invitation_continuity': 'unqualified', 'physical_camera': 'unqualified', 'external_nat': 'unqualified'}
    write_new(q.work / 'restored-conference.safe.json', summary)
    return summary


def main():
    # Explicit native admission before reading installed state or importing the
    # normal restore driver. Both paths are supplied only by the private driver.
    require(os.name == 'nt' and os.environ.get('OPENWEB_WINDOWS_RESTORE_TEST') == '1')
    parser = argparse.ArgumentParser(); parser.add_argument('--input', type=Path, required=True); parser.add_argument('--adapter', type=Path, required=True)
    args = parser.parse_args()
    original = load('restored_conference_qualification', Path(__file__).with_name('windows-restore-qualification.py'))
    print(json.dumps(qualify(original.Qualification(args.input), args.adapter)))


if __name__ == '__main__':
    try: main()
    except BaseException as error:
        try: print(json.dumps(failure_record(error)))
        except BaseException: pass
        raise SystemExit(1)
