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


def stable_files(q):
    root = ordinary(q.backups.RESTORE, True)
    entries = list(root.rglob('*')); require(len(entries) <= 64)
    result = {str(p.relative_to(root)): digest(p) for p in entries if not p.is_dir()}
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
    except BaseException as error: primary = error
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
        print(json.dumps({'schema': 1, 'state': 'failed', 'producer': 'windows_restored_meeting.py',
                          'error_type': type(error).__name__ if type(error).__name__ in ('RuntimeError', 'ValueError', 'TimeoutExpired', 'OSError') else 'external_error',
                          'cleanup_verified': getattr(error, 'restored_meeting_cleanup_verified', False) is True}))
        raise SystemExit(1)
