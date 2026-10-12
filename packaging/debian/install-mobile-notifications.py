#!/usr/bin/env python3
"""Provision the private PHP-owned notification configuration without widening state ACLs."""
import os
from pathlib import Path
import stat
import tempfile

STATE = Path('/var/lib/openwebpbx')
MAX_CONFIG = 65536


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def check_path(path):
    if any(item.is_symlink() for item in [path, *path.parents]):
        raise ValueError('Notification storage must not contain symbolic links.')


def check_file(path):
    check_path(path)
    if path.exists():
        status = path.stat()
        if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1 or status.st_size > MAX_CONFIG:
            raise ValueError('Notification configuration is not a bounded ordinary file.')


def validate_directory(directory, owner=33, group=33):
    check_path(directory)
    parent = directory.parent.stat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0 or parent.st_mode & 0o022:
        raise ValueError('The instance state directory must remain protected by root.')
    if directory.exists():
        status = directory.stat()
        if not stat.S_ISDIR(status.st_mode) or (status.st_uid, status.st_gid, stat.S_IMODE(status.st_mode)) != (owner, group, 0o700):
            raise ValueError('Existing notification directory permissions need administrator review.')


def ensure_directory(directory, owner=33, group=33):
    validate_directory(directory, owner, group)
    if not directory.exists():
        directory.mkdir(mode=0o700)
        os.chown(directory, owner, group)
        sync_directory(directory.parent)


def read_stable(path):
    check_file(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > MAX_CONFIG:
            raise ValueError('Notification configuration is not a bounded ordinary file.')
        data = stream.read(MAX_CONFIG + 1)
        after = os.fstat(stream.fileno())
    identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if len(data) > MAX_CONFIG or identity(before) != identity(after) or identity(after) != identity(path.stat()):
        raise ValueError('Notification configuration changed during migration. Retry when idle.')
    return data


def install(state=STATE, owner=33, group=33):
    if os.geteuid() != 0:
        raise PermissionError('Notification storage installation requires root.')
    directory = state / 'mobile-notifications'
    current = directory / 'config.json'
    lock = directory / 'config.json.lock'
    legacy = state / 'mobile-push.json'
    # Validate every input before creating or changing any file. Existing
    # current configuration wins; the legacy file stays available to rollback.
    validate_directory(directory, owner, group)
    for path in [current, lock, legacy]:
        check_file(path)
    data = read_stable(legacy) if not current.exists() and legacy.exists() else None
    ensure_directory(directory, owner, group)
    if data is not None:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=directory, prefix='.notification-migrate-', delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(data)
                stream.flush()
                os.fchmod(stream.fileno(), 0o600)
                os.fchown(stream.fileno(), owner, group)
                os.fsync(stream.fileno())
            os.replace(temporary, current)
            sync_directory(directory)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    for path in [current, lock]:
        if path.exists():
            os.chmod(path, 0o600)
            os.chown(path, owner, group)
            with path.open('rb') as stream:
                os.fsync(stream.fileno())
    sync_directory(directory)


if __name__ == '__main__':
    install()
