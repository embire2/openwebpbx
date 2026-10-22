#!/usr/bin/env python3
"""Bounded, private Phone Health observation; never changes phones or firewall rules."""
import fcntl
import ctypes
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

LOCK = Path('/run/openwebpbx-upgrade.lock')
MAINTENANCE = Path('/var/lib/openwebpbx/updates/maintenance')
RESTORE_HOLD = Path('/var/lib/openwebpbx/backup-restore/hold-openwebpbx.service')
PHP = Path('/usr/bin/php')
ENTRY = Path('/opt/openwebpbx/tools/phone-health.php')
MAX_RESPONSE = 4 * 1024 * 1024
COUNTS = ('observed_contacts', 'checked_domains', 'open', 'new', 'resolved', 'queued')
LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
LIBC.prctl.restype = ctypes.c_int


def unprivileged_child():
    # This single-threaded worker drops every inherited supplementary group and
    # all root UIDs before enabling no-new-privileges and executing PHP. Some
    # Debian host kernels refuse the UID drop if systemd enables it earlier.
    os.setgroups([])
    os.setgid(33)
    os.setuid(33)
    if LIBC.prctl(38, 1, 0, 0, 0) != 0:  # PR_SET_NO_NEW_PRIVS
        raise OSError(ctypes.get_errno(), 'Private health child sandbox failed.')


def protected(path):
    """Root execution must not follow an operator-writable replacement."""
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError('Protected Phone Health paths required.')
        status = item.stat()
        if status.st_uid != 0 or status.st_mode & 0o022:
            raise ValueError('Protected Phone Health paths required.')
    if not path.is_file():
        raise ValueError('Phone Health helper is unavailable.')


def aggregate(raw):
    if len(raw) > 4096:
        raise ValueError('Unexpected Phone Health result.')
    value = json.loads(raw)
    if not isinstance(value, dict) or type(value.get('available')) is not bool:
        raise ValueError('Unexpected Phone Health result.')
    result = {'state': 'observed', 'available': value['available']}
    for name in COUNTS:
        count = value.get(name, 0)
        if type(count) is not int or not 0 <= count <= 2_000_000:
            raise ValueError('Unexpected Phone Health result.')
        result[name] = count
    return result


def observe():
    if os.geteuid() != 0:
        raise PermissionError('Phone Health observation requires the managed worker.')
    descriptor = os.open(LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode) or status.st_uid != 0 or status.st_mode & 0o077:
            raise ValueError('Protected upgrade lock required.')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'state': 'deferred', 'reason': 'upgrade_or_restore'}
        if MAINTENANCE.exists() or RESTORE_HOLD.exists():
            return {'state': 'deferred', 'reason': 'maintenance_or_restore_hold'}
        protected(ENTRY)
        # A stalled native socket must not prevent unknown-state observation.
        # The native contact response stays in private pipes and is never logged.
        native = b'null'
        try:
            probe = subprocess.run([str(PHP), '-d', 'memory_limit=128M', '-d', 'display_errors=0', '-d', 'log_errors=0',
                                    str(ENTRY), 'registrations'], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=7,
                                   preexec_fn=unprivileged_child)
            if probe.returncode == 0 and 0 < len(probe.stdout) <= MAX_RESPONSE:
                parsed = json.loads(probe.stdout)
                if isinstance(parsed, dict):
                    native = probe.stdout
        except (subprocess.TimeoutExpired, ValueError):
            pass
        result = subprocess.run([str(PHP), '-d', 'memory_limit=128M', '-d', 'display_errors=0', '-d', 'log_errors=0',
                                 str(ENTRY), 'monitor'], input=native, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=21, preexec_fn=unprivileged_child)
        if result.returncode != 0:
            raise RuntimeError('Phone Health observation unavailable; existing incidents retained.')
        return aggregate(result.stdout)
    finally:
        os.close(descriptor)


def main():
    try:
        print(json.dumps(observe(), separators=(',', ':')))
        return 0
    except Exception:
        # No exception text: it can contain private connection or SQL values.
        print('{"state":"unavailable","message":"Phone Health observation failed; existing incidents retained."}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
