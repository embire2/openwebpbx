"""Observe the unchanged DID driver's validation entry; no qualification shortcut."""
import argparse
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile

SOURCE = '3fbb9c12f9013f82b4350aa9c5f4a2f43f842878'
PINS = {'tests/windows_trunk_numbers.py': {'bytes': 3911, 'sha256': 'abd31b33fc14b14b8b5779205528aa735e87e6dcae0c83d3475377aab1e9d233'}, 'tests/pbx_trunk_numbers.py': {'bytes': 4432, 'sha256': 'c08c5913a804851f160aa6a73f2c77c2322a0839182748db082c279e4cc70d7c'}, 'tests/pbx_trunk_numbers.php': {'bytes': 14003, 'sha256': 'f9d98c157f7712c570a41d0c5357e1b460cbac2771b03afa1ec631e56975fa1e'}, 'tests/windows_meeting_owned_process.py': {'bytes': 9205, 'sha256': '9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448'}, 'tests/windows_did_seal.ps1': {'bytes': 1633, 'sha256': '1d65d2a07655fcbbf6ce1d683e289becc0455b83aa55e028b62d22fef0674b12'}, 'tests/windows_did_seal.cs': {'bytes': 2253, 'sha256': '008dabbb9674bdd486a1d518cc4ca20505f2dfcd6aa502a753e5dfd0b4cd7e7e'}, 'tests/windows_did_diagnostic_public.pem': {'bytes': 625, 'sha256': '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307'}}
KNOWN = {'windows_trunk_numbers.py', 'pbx_trunk_numbers.py', 'windows_meeting_owned_process.py', 'windows_did_component.py'}
JOB_KEYS = set('schema created_suspended assigned_before_resume resumed owned_job_terminated exit_code owned_processes_closed handles_closed ordinary_exit'.split())
BOOL_KEYS = JOB_KEYS - {'schema', 'exit_code'}
ERRORS = {'CalledProcessError', 'TimeoutExpired', 'FileNotFoundError', 'PermissionError', 'OSError', 'ValueError', 'RuntimeError', 'AssertionError', 'KeyError', 'TypeError'}


def need(value):
    if not value:
        raise ValueError('Exact unchanged DID observation refused.')


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def phases(raw):
    tree = ast.parse(raw)
    main = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'main')
    lines = {}
    for node in ast.walk(main):
        if not isinstance(node, ast.Call):
            continue
        name = None
        if isinstance(node.func, ast.Name) and node.func.id == 'run' and node.args:
            command = node.args[0]
            if isinstance(command, ast.List) and isinstance(command.elts[0], ast.Call):
                tool = ast.literal_eval(command.elts[0].args[0])
                name = 'initdb' if tool == 'initdb' else 'pg_start' if ast.literal_eval(command.elts[-1]) == 'start' else 'pg_stop'
        elif isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and node.func.value.id == 'subprocess' and node.func.attr == 'run':
            if isinstance(node.args[0], ast.List) and isinstance(node.args[0].elts[0], ast.Attribute):
                name = 'php66'
        if name:
            for line in range(node.lineno, node.end_lineno + 1):
                lines[line] = name
    need(set(lines.values()) == {'initdb', 'pg_start', 'php66', 'pg_stop'})
    return lines


def proof_shape(proof):
    need(type(proof) is dict and set(proof) == JOB_KEYS)
    need(type(proof['schema']) is int and proof['schema'] == 1)
    need(all(type(proof[key]) is bool for key in BOOL_KEYS))
    need(proof['exit_code'] is None or type(proof['exit_code']) is int and 0 <= proof['exit_code'] <= 4294967295)
    return dict(proof)


def project(result, proof, phase_lines):
    need(result.returncode is None or type(result.returncode) is int and -2147483648 <= result.returncode <= 4294967295)
    need(type(result.stderr) is str and len(result.stderr.encode('utf-8')) <= 3 * 8388608)
    frames = []; observed = []; error_types = []
    for text in result.stderr.splitlines():
        # Strip only bounded ANSI SGR color controls; unsupported escapes stay unknown.
        text = re.sub(r'\x1b\[[0-9;]{0,64}m', '', text)
        frame = re.fullmatch(r'\s*File "([^"\r\n]{1,4096})", line ([1-9][0-9]{0,5}), in [A-Za-z0-9_<>]{1,80}\s*', text)
        if frame:
            name = frame[1].replace('\\', '/').rsplit('/', 1)[-1]
            line = int(frame[2])
            if name in KNOWN and line <= 100000:
                if len(frames) < 4:
                    frames.append({'source_name': name, 'source_line': line})
                if name == 'pbx_trunk_numbers.py' and line in phase_lines and phase_lines[line] not in observed:
                    observed.append(phase_lines[line])
        kind = re.match(r'^([A-Za-z_][A-Za-z0-9_.]{0,100}):', text)
        if kind:
            short = kind[1].rsplit('.', 1)[-1]
            if short in ERRORS and short not in error_types:
                error_types.append(short)
    row = {'schema': 1, 'scope': 'instrumented_initdb_failure_validation_observation_only',
           'instrumented_driver_base_source_commit': SOURCE, 'child_exit': result.returncode,
           'original_job_proof': proof_shape(proof),
           'known_source_frames': frames, 'observed_portable_phases': observed[:4],
           'observed_error_types': error_types[:4],
           'stderr_sha256': sha(result.stderr.encode('utf-8')),
           'raw_stderr_or_commands_emitted': False,
           'original_validation_still_required': True,
           'normal_or_package_acceptance': False}
    need(len(json.dumps(row).encode()) <= 4096)
    return row


def wrap_validate(original, sink, phase_lines):
    def observed(result, proof):
        # Diagnostic refusal must never replace or bypass the original predicate.
        try:
            sink(project(result, proof, phase_lines))
        except BaseException:
            pass
        return original(result, proof)
    return observed


def prefix_inventory():
    base = Path(tempfile.gettempdir())
    need(base.is_absolute() and base.is_dir() and not base.is_symlink())
    rows = {}
    for path in base.iterdir():
        if not path.name.startswith('openweb-did-'):
            continue
        need(re.fullmatch(r'openweb-did-[A-Za-z0-9_-]{1,100}', path.name) and len(rows) < 128)
        link = path.is_symlink() or bool(getattr(path.lstat(), 'st_file_attributes', 0) & 0x400)
        rows[path.name] = {'link': link, 'directory': False if link else path.is_dir()}
    return rows


def exception_projection(error):
    frames = []
    trace = error.__traceback__
    while trace is not None:
        name = Path(trace.tb_frame.f_code.co_filename).name
        if name in KNOWN and len(frames) < 4:
            frames.append({'source_name': name, 'source_line': trace.tb_lineno})
        trace = trace.tb_next
    kind = type(error).__name__
    return {'error_type': kind if kind in ERRORS else 'other', 'known_source_frames': frames}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    evidence = args.evidence
    need(evidence.is_absolute() and evidence.is_dir() and not evidence.is_symlink())
    observation = evidence / 'driver-validation.safe.json'
    summary = evidence / 'driver-component.safe.json'
    need(not observation.exists() and not summary.exists())
    root = Path(__file__).resolve().parents[1]
    files = {}
    for name, expected in PINS.items():
        path = root / name
        need(path.is_file() and not path.is_symlink())
        raw = path.read_bytes(); need(len(raw) == expected['bytes'] and sha(raw) == expected['sha256'])
        files[name] = raw
    portable_phases = phases(files['tests/pbx_trunk_numbers.py'])
    path = root / 'tests/windows_trunk_numbers.py'
    spec = importlib.util.spec_from_file_location('exact_unchanged_DID_driver', path)
    driver = importlib.util.module_from_spec(spec); spec.loader.exec_module(driver)
    def sink(row):
        raw = (json.dumps(row, sort_keys=True) + '\n').encode(); need(len(raw) <= 4096)
        with observation.open('xb') as target:
            target.write(raw)
        print(raw.decode().strip(), file=sys.stderr)
    driver.validate = wrap_validate(driver.validate, sink, portable_phases)
    before = prefix_inventory(); argv = sys.argv[:]; primary = None; after = None
    try:
        sys.argv = [str(path), '--evidence', str(evidence/'original-job')]
        driver.main()
    except BaseException as error:
        primary = error
        raise
    finally:
        sys.argv = argv
        try:
            after = prefix_inventory()
            unchanged = all((root/name).read_bytes() == raw for name, raw in files.items())
            new = sorted(set(after)-set(before))
            fallback = None
            if not observation.exists():
                # Preserve failures before validate; consume only the already bounded
                # original Job files and emit the same fixed fields, never raw stderr.
                job = evidence/'original-job'
                proof_path = job/'process.safe.json'; stderr_path = job/'stderr.private.log'
                if proof_path.is_file() and stderr_path.is_file() and proof_path.stat().st_size <= 8192 and stderr_path.stat().st_size <= 8388608:
                    proof = proof_shape(json.loads(proof_path.read_bytes()))
                    code = proof['exit_code']
                    result = type('ExistingResult', (), {'returncode': code, 'stderr': stderr_path.read_text(encoding='utf-8', errors='replace')})()
                    fallback = project(result, proof, portable_phases)
            with open(sys.executable, 'rb') as executable:
                executable_sha256 = sha(executable.read())
            row = {'schema': 1, 'scope': 'instrumented_initdb_failure_driver_component_observation_only',
                   'instrumented_driver_base_source_commit': SOURCE, 'source_inputs': PINS,
                   'original_sources_unchanged': unchanged,
                   'validation_observation_available': observation.is_file(),
                   'failure_before_validation_observation': fallback,
                   'original_exception': exception_projection(primary) if primary else None,
                   'default_python_version': '.'.join(map(str, sys.version_info[:3])),
                   'default_python_executable_sha256': executable_sha256,
                   'prefix_inventory_before': before, 'prefix_inventory_after': after,
                   'new_prefix_nodes_remaining': new,
                   'foreign_prefix_nodes_removed': sorted(set(before)-set(after)),
                   'owned_prefix_cleanup_qualified': not new and before == after,
                   'full_normal_or_package_accepted': False}
            raw = (json.dumps(row, sort_keys=True) + '\n').encode(); need(len(raw) <= 65536)
            with summary.open('xb') as target:
                target.write(raw)
        except BaseException:
            if primary is None:
                raise
    need(after == before and observation.is_file())
    need(all((root/name).read_bytes() == raw for name, raw in files.items()))


if __name__ == '__main__':
    main()
