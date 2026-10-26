"""Bound the disposable DID PostgreSQL/PHP controls with the existing Windows Job."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PINS = {'tests/windows_meeting_owned_process.py': '9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448', 'tests/pbx_trunk_numbers.py': 'fb70bffb06a122352a5c5f9f31dd0b5c5b7826c34267d66fd5a206814a930d30', 'tests/pbx_trunk_numbers.php': 'f9d98c157f7712c570a41d0c5357e1b460cbac2771b03afa1ec631e56975fa1e', 'tests/windows_did_seal.ps1': '1d65d2a07655fcbbf6ce1d683e289becc0455b83aa55e028b62d22fef0674b12', 'tests/windows_did_seal.cs': '008dabbb9674bdd486a1d518cc4ca20505f2dfcd6aa502a753e5dfd0b4cd7e7e', 'tests/windows_did_diagnostic_public.pem': '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307'}
JOB_KEYS = set('schema created_suspended assigned_before_resume resumed owned_job_terminated exit_code owned_processes_closed handles_closed ordinary_exit'.split())
JOB_TRUE = 'created_suspended assigned_before_resume resumed owned_processes_closed handles_closed ordinary_exit'.split()


def need(value):
    if not value:
        raise ValueError('Disposable Windows DID controls refused.')


def decode(raw):
    def unique(items):
        row = {}
        for key, value in items:
            need(key not in row)
            row[key] = value
        return row
    need(type(raw) is str and 0 < len(raw.encode('utf-8')) <= 8192)
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda _: need(False))


def validate(result, proof):
    need(type(result.returncode) is int and result.returncode == 0)
    row = decode(result.stdout)
    need(type(row) is dict and set(row) == {'controls', 'actual_isolated_postgresql', 'engine_calls', 'customer_connection'})
    need(type(row['controls']) is int and row['controls'] == 66)
    need(row['actual_isolated_postgresql'] is True and row['customer_connection'] is False)
    need(type(row['engine_calls']) is list and row['engine_calls'] == [])
    need(type(proof) is dict and set(proof) == JOB_KEYS)
    need(type(proof['schema']) is int and proof['schema'] == 1)
    need(type(proof['exit_code']) is int and proof['exit_code'] == 0)
    need(proof['owned_job_terminated'] is False and all(proof[key] is True for key in JOB_TRUE))
    return row


def bounded(path):
    need(path.is_file() and not path.is_symlink() and not (getattr(path.lstat(), 'st_file_attributes', 0) & 0x400))
    with path.open('rb') as stream:
        raw = stream.read(8193)
    need(0 < len(raw) <= 8192)
    return raw.decode('utf-8')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    need(os.name == 'nt')
    paths = {name: ROOT / name for name in PINS}
    for name, path in paths.items():
        need(path.is_file() and not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == PINS[name])
    need(args.evidence.is_absolute() and not args.evidence.exists())
    args.evidence.mkdir(mode=0o700)
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('unchanged_owned_DID_Job240', paths['tests/windows_meeting_owned_process.py'])
    job = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(job)
    result = job.run([sys.executable, '-B', str(paths['tests/pbx_trunk_numbers.py']),
                      '--postgres-bin', r'C:\OpenWebPBX\pgsql\bin',
                      '--php', r'C:\OpenWebPBX\php\php.exe'], args.evidence, timeout=240)
    row = validate(result, decode(bounded(args.evidence / 'process.safe.json')))
    need(all(hashlib.sha256(path.read_bytes()).hexdigest() == PINS[name] for name, path in paths.items()))
    print(json.dumps(row, sort_keys=True))


if __name__ == '__main__':
    main()
