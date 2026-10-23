"""Observe normal LocalService CDR import after one real owned decoded call.

No explicit importer, service restart, spool mutation or configuration write.
"""
import json
import math
import re
import subprocess
import time


def service_record(value):
    fields = {'schema', 'producer', 'state', 'read_only', 'actual_localservice_identity',
              'candidate_bound', 'no_separate_importer', 'process_id'}
    if not isinstance(value, dict) or set(value) != fields:
        raise AssertionError('The native background service identity is incomplete')
    if type(value['schema']) is not int or value['schema'] != 1 or value['producer'] != 'windows_cdr_service.ps1' or value['state'] != 'observed':
        raise AssertionError('The native background service producer is invalid')
    for field in ('read_only', 'actual_localservice_identity', 'candidate_bound', 'no_separate_importer'):
        if value[field] is not True:
            raise AssertionError('The actual background service scope was not proven')
    if type(value['process_id']) is not int or not 1 <= value['process_id'] <= 4294967295:
        raise AssertionError('The actual background service process is unavailable')
    return value


def observe_service(fixture, powershell):
    result = subprocess.run([powershell, '-NoProfile', '-NonInteractive', '-File',
                             str(fixture.source / 'tests/windows_cdr_service.ps1'),
                             '-PackageRoot', fixture.s['package_root']],
                            capture_output=True, text=True, timeout=20)
    if result.returncode or len(result.stdout) > 8192 or result.stderr.strip():
        raise AssertionError('The actual normal LocalService identity was not observed')
    return service_record(json.loads(result.stdout))


def observation(value):
    counts = {'cdr_rows': 1, 'answered_cdr_rows': 1, 'history_rows': 2,
              'history_owner_rows': 2, 'spool_files_present': 4, 'quarantined_files_present': 4}
    flags = {'read_only', 'record_scope_exact', 'history_sources_exact', 'spool_absent', 'completed'}
    if not isinstance(value, dict) or set(value) != {'schema', 'state', 'scope'} | set(counts) | flags:
        raise AssertionError('The background call-record observer shape is invalid')
    if type(value['schema']) is not int or value['schema'] != 1 or value['state'] != 'observed' or value['scope'] != 'owned_call':
        raise AssertionError('The background call-record observer scope is invalid')
    if any(type(value[name]) is not int or not 0 <= value[name] <= limit for name, limit in counts.items()):
        raise AssertionError('The background call-record counts are invalid')
    if any(type(value[name]) is not bool for name in flags) or not value['read_only']:
        raise AssertionError('The background call-record flags are invalid')
    complete = (value['cdr_rows'] == value['answered_cdr_rows'] == 1
                and value['history_rows'] == value['history_owner_rows'] == 2
                and value['spool_files_present'] == value['quarantined_files_present'] == 0
                and value['record_scope_exact'] and value['history_sources_exact'] and value['spool_absent'])
    if value['completed'] != complete:
        raise AssertionError('The background call-record completion is inconsistent')
    return value


def qualify(fixture, call_id, before, service_reader, clock=time.monotonic, sleep=time.sleep):
    service_record(before)
    if not isinstance(call_id, str) or re.fullmatch(r'[a-f0-9]{24}@localfixture', call_id) is None:
        raise AssertionError('Only the actual owned decoded call can be observed')
    started = clock()
    for polls in range(1, 27):
        value = observation(fixture.cli('cdr-status', call_id))
        elapsed = clock() - started
        if not math.isfinite(elapsed) or elapsed < 0 or elapsed > 30:
            raise AssertionError('Normal background call-record import exceeded its bound')
        if value['completed']:
            after = service_record(service_reader())
            if after['process_id'] != before['process_id']:
                raise AssertionError('The background importer process restarted')
            return dict(actual_background_import=True, actual_localservice_identity=True,
                        backend_pid_unchanged=True, read_only_observer=True,
                        no_explicit_importer=True, before_system_drain=True,
                        exact_call_domain_correlation=True, history_sources_exact=True,
                        spool_absent=True, matched_cdr_rows=1, answered_cdr_rows=1,
                        history_rows=2, history_owner_rows=2, polls=polls,
                        elapsed_seconds=round(elapsed, 3))
        if elapsed >= 25:
            break
        sleep(min(1, 25 - elapsed))
    raise AssertionError('The normal LocalService did not finish this owned call record')
