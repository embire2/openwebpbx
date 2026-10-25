"""Private hosted recorder supervisor. No pipe capture or production calling."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

LIMIT = 8 * 1024**2
DEADLINES = {'cmake_version': 30, 'dotnet_version': 30, 'configure': 120,
             'native_build': 180, 'native_contract': 30, 'managed_contract': 120}


def closed_json(raw):
    def unique(rows):
        value = {}
        for name, item in rows:
            if name in value:
                raise ValueError('Repeated private receipt/request field.')
            value[name] = item
        return value
    return json.loads(raw, object_pairs_hook=unique)


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def ordinary(path):
    path = Path(path)
    for item in (path, *path.parents):
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise ValueError('Ordinary private ancestry required.')
    return path


def run_request(path):
    if os.name != 'nt' or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx':
        raise RuntimeError('Only disposable hosted Windows recorder supervision.')
    if sys.version_info[:3] != (3, 12, 10):
        raise RuntimeError('Exact setup-python interpreter version required.')
    path = ordinary(path)
    if path.name != 'request.json' or path.stat().st_size > 65536:
        raise ValueError('Bounded private request required.')
    raw = path.read_bytes()
    if len(raw) > 65536:
        raise ValueError('Private request grew beyond bound.')
    request = closed_json(raw)
    keys = {'schema', 'label', 'command', 'command_sha256', 'working_directory',
            'evidence_directory', 'seconds', 'python_executable', 'python_sha256', 'job_core_sha256'}
    if type(request) is not dict or set(request) != keys or type(request['schema']) is not int or request['schema'] != 1:
        raise ValueError('Closed supervisor request required.')
    label = request['label']
    if type(label) is not str or label not in DEADLINES or type(request['seconds']) is not int or request['seconds'] != DEADLINES[label]:
        raise ValueError('Original exact command deadline required.')
    command = request['command']
    if type(command) is not list or not 1 <= len(command) <= 64 or any(type(x) is not str or '\0' in x or len(x) > 32768 for x in command):
        raise ValueError('Bounded argument vector required.')
    for name in ('command_sha256', 'python_sha256', 'job_core_sha256'):
        value = request[name]
        if type(value) is not str or len(value) != 64 or any(x not in '0123456789abcdef' for x in value):
            raise ValueError('Exact source/tool digest required.')
    root = ordinary(Path(os.environ['RUNNER_TEMP']) / 'phone-wav-evidence')
    directory = ordinary(request['evidence_directory'])
    if not directory.is_dir() or directory.parent.resolve() != root.resolve() or directory.name != 'owned-' + label or path.parent.resolve() != directory.resolve():
        raise ValueError('Exact private per-command evidence scope required.')
    working = ordinary(request['working_directory'])
    workspace = ordinary(os.environ['GITHUB_WORKSPACE'])
    runner_temp = ordinary(os.environ['RUNNER_TEMP'])
    if not working.is_dir() or not (working.resolve().is_relative_to(workspace.resolve()) or working.resolve().is_relative_to(runner_temp.resolve())):
        raise ValueError('Only source or owned temporary working directory required.')
    interpreter = ordinary(request['python_executable'])
    executable = ordinary(command[0])
    if not interpreter.is_absolute() or not executable.is_absolute() or interpreter.suffix.lower() != '.exe' or executable.suffix.lower() != '.exe' or interpreter.resolve() != Path(sys.executable).resolve() or digest(interpreter) != request['python_sha256'] or digest(executable) != request['command_sha256']:
        raise ValueError('Exact explicit installed interpreter/command required.')
    core_path = ordinary(Path(__file__).with_name('WavProducerOwnedProcess.py'))
    if digest(core_path) != request['job_core_sha256']:
        raise ValueError('Reviewed owned Job source changed.')
    spec = importlib.util.spec_from_file_location('openweb_recorder_owned_job', core_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    report = {'schema': 1, 'producer': 'WavProducerOwnedChild', 'state': 'failed',
              'request_sha256': hashlib.sha256(raw).hexdigest(), 'job_core_sha256': request['job_core_sha256'],
              'interpreter_sha256': request['python_sha256'], 'command_image_sha256': request['command_sha256'],
              'command_exit': None, 'timed_out': False, 'owned_processes_closed': False, 'handles_closed': False,
              'error_type': 'none', 'process_proof_sha256': None, 'output_read_completed': False}
    result = None
    failure = None
    try:
        result = module.run(command, directory, request['seconds'], working_directory=working)
        report['command_exit'] = result.returncode
        report['output_read_completed'] = True
    except BaseException as error:
        failure = error
        report['error_type'] = type(error).__name__ if type(error).__name__ in ('RuntimeError', 'OSError', 'TimeoutExpired', 'ValueError') else 'other'
        report['timed_out'] = isinstance(error, subprocess.TimeoutExpired)
    finally:
        proof_path = directory / 'process.safe.json'
        if proof_path.is_file() and proof_path.stat().st_size <= 8192:
            ordinary(proof_path)
            with proof_path.open('rb') as source:
                proof_raw = source.read(8193)
            if len(proof_raw) > 8192:
                raise ValueError('Owned Job proof exceeded its bound.')
            proof = closed_json(proof_raw)
            proof_keys = {'schema', 'created_suspended', 'assigned_before_resume', 'resumed', 'owned_job_terminated', 'exit_code', 'owned_processes_closed', 'handles_closed', 'ordinary_exit'}
            if type(proof) is not dict or set(proof) != proof_keys or type(proof['schema']) is not int or proof['schema'] != 1 or any(type(proof[x]) is not bool for x in proof_keys - {'schema', 'exit_code'}) or proof['resumed'] and not (proof['assigned_before_resume'] and proof['created_suspended']):
                raise ValueError('Exact owned Job closure proof required.')
            if proof['exit_code'] is not None and (type(proof['exit_code']) is not int or not 0 <= proof['exit_code'] <= 0xffffffff):
                raise ValueError('Typed native exit code required.')
            if result is not None and (not proof['ordinary_exit'] or not proof['created_suspended'] or not proof['assigned_before_resume'] or not proof['resumed'] or proof['exit_code'] != result.returncode):
                raise ValueError('Successful result differs from original Job proof.')
            report['process_proof_sha256'] = hashlib.sha256(proof_raw).hexdigest()
            report['owned_processes_closed'] = proof['owned_processes_closed']
            report['handles_closed'] = proof['handles_closed']
        if digest(executable) != request['command_sha256'] or digest(interpreter) != request['python_sha256'] or digest(core_path) != request['job_core_sha256']:
            raise ValueError('Original tool/Job bytes changed during supervision.')
        if failure is None and report['owned_processes_closed'] and report['handles_closed'] and report['output_read_completed']:
            report['state'] = 'observed_complete_owned_child'
        with (directory / 'driver.safe.json').open('x', encoding='utf-8') as target:
            json.dump(report, target, separators=(',', ':'))
    return 0 if report['state'] == 'observed_complete_owned_child' else 1


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(2)
    try:
        raise SystemExit(run_request(sys.argv[1]))
    except Exception:
        # Validation failures never print raw paths/arguments. Missing proof fails
        # parent cleanup closed; no guessed success receipt is manufactured.
        raise SystemExit(1)
