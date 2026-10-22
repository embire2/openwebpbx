"""QA-only post-error observations; never retries or changes restore behavior."""
import errno
import json
import os
from pathlib import Path
import subprocess

BUSY = 'Another backup, restore or release update is running. Retry after it finishes.'
LOCK_STATES = {'available', 'busy', 'missing', 'access_denied', 'not_ordinary', 'other'}
SERVICE_STATES = {'unknown', 'Stopped', 'Running', 'Start Pending', 'Stop Pending', 'Paused', 'Continue Pending', 'Pause Pending'}


def probe_existing_lock(module, path):
    """Use the product's exact byte-lock primitive, on existing ordinary files."""
    record = {'state': 'other', 'stream_closed': True}
    stream = None
    stage = 'open'
    try:
        if not path.exists():
            return {'state': 'missing', 'stream_closed': True}
        if module.reparse(path):
            return {'state': 'not_ordinary', 'stream_closed': True}
        module.ordinary(path)
        if os.name == 'nt' and hasattr(module, 'windows_exclusive_guard'):
            try:
                # OPEN_EXISTING cannot recreate a removed lock. The product's
                # native result distinguishes sharing from access failures.
                with module.windows_exclusive_guard(path, existing_only=True):
                    record['state'] = 'available'
            except module.BackupBusy:
                record['state'] = 'busy'
            except module.BackupError:
                record['state'] = 'other'
            return record
        stream = path.open('r+b')  # Never create, truncate, write or chmod.
        stage = 'lock'
        module.lock_file(stream)
        stage = 'unlock'
        module.unlock_file(stream)
        record['state'] = 'available'
    except OSError as error:
        if stage == 'lock' and error.errno in {errno.EACCES, errno.EAGAIN, errno.EDEADLK}:
            record['state'] = 'busy'
        elif stage == 'open' and isinstance(error, PermissionError):
            record['state'] = 'access_denied'
        elif isinstance(error, FileNotFoundError):
            record['state'] = 'missing'
    except BaseException:
        record['state'] = 'not_ordinary' if stage == 'open' else 'other'
    finally:
        if stream is not None:
            try:
                stream.close()
                record['stream_closed'] = stream.closed
            except BaseException:
                record['stream_closed'] = False
    return record


def native_fields(value):
    fields = {'observed', 'health_observed', 'local_running', 'version_matches', 'iis_login_ready',
              'known_recover_holder', 'holder_count', 'verified_holder_count', 'updater_state'}
    if not isinstance(value, dict) or set(value) != fields:
        return None
    if any(type(value[name]) is not bool for name in fields - {'holder_count', 'verified_holder_count', 'updater_state'}):
        return None
    if any(type(value[name]) is not int or not 0 <= value[name] <= 32 for name in ('holder_count', 'verified_holder_count')):
        return None
    if value['verified_holder_count'] > value['holder_count'] or not isinstance(value['updater_state'], str) or value['updater_state'] not in SERVICE_STATES:
        return None
    return dict(value)


def observe(module, private, error):
    # A failed gate and its exact original exception remain authoritative.
    if type(error) not in (module.BackupError, getattr(module, 'BackupBusy', module.BackupError)) or str(error) != BUSY:
        return None
    if os.name != 'nt' or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx':
        return None
    private = Path(private)
    state = Path(os.environ['ProgramData']) / 'OpenWebPBX'
    if private.resolve() != (state / 'backup-qualification').resolve() or module.reparse(private):
        return None
    record = {'schema': 1, 'observation': 'after_original_busy_error',
              'upgrade': probe_existing_lock(module, module.UPGRADE_LOCK),
              'worker': probe_existing_lock(module, module.STORE / 'worker.lock')}
    try:
        command = [str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'),
                   '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
                   str(Path(__file__).with_suffix('.ps1')), '-PrivateDirectory', str(private), '-DisposableHostedRunner']
        result = subprocess.run(command, env=module.native_powershell_environment(), capture_output=True, timeout=25)
        for name, value in [('backup-lock-private.out', result.stdout), ('backup-lock-private.err', result.stderr)]:
            (private / name).write_bytes(value)
        if result.returncode == 0 and len(result.stdout) <= 8192:
            native = native_fields(json.loads(result.stdout.decode('utf-8-sig')))
            if native is not None:
                record['native'] = native
    except BaseException:
        pass
    return record
