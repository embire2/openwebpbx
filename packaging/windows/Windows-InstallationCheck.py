#!/usr/bin/env python3
"""Read-only verification of a full Windows installer, using its included runtime."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True


def unique_keys(pairs):
    result = {}
    insensitive = set()
    for key, value in pairs:
        if key.casefold() in insensitive:
            raise ValueError('The installation JSON contains a repeated field.')
        insensitive.add(key.casefold())
        result[key] = value
    return result


def validate_package(package):
    package = Path(package)
    for parent in [package, *package.parents]:
        if parent.is_symlink() or (hasattr(parent, 'is_junction') and parent.is_junction()):
            raise ValueError('The installation folder contains a link or junction.')
    if not package.is_dir():
        raise ValueError('Use an ordinary folder containing the full Windows release.')
    version = (package / 'VERSION').read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('The installation version is invalid.')
    manifest = json.loads((package / 'release-manifest.json').read_text(encoding='utf-8'), object_pairs_hook=unique_keys)
    if not isinstance(manifest, dict) or set(manifest) != {'version', 'files'} or manifest['version'] != version:
        raise ValueError('The complete installation manifest is invalid.')
    files = manifest['files']
    if not isinstance(files, dict) or not {'VERSION', 'web/VERSION', 'installation.json', 'release_contract.py',
                                         'Check-Installation.ps1', 'Windows-InstallationCheck.py', 'backup-runtime/python.exe'} <= set(files):
        raise ValueError('The full standalone installation is required.')
    actual = set()
    for path in package.rglob('*'):
        if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
            raise ValueError('The extracted installation contains a link or junction.')
        if path.is_file():
            if path.stat().st_nlink != 1:
                raise ValueError('The extracted installation contains a hard link.')
            actual.add(path.relative_to(package).as_posix())
    if actual != set(files) | {'release-manifest.json'}:
        raise ValueError('Files are missing or unlisted. Extract the complete release into an empty folder.')
    for name, expected in files.items():
        if (not isinstance(name, str) or not name or name.startswith('/') or re.search(r'[\\:\x00-\x1f<>"|?*]', name)
                or any(part in {'', '.', '..'} or part.endswith((' ', '.'))
                       or re.fullmatch(r'(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?', part, re.I)
                       for part in name.split('/'))):
            raise ValueError('The release manifest contains an unsafe Windows path.')
        path = package / name
        if not path.is_file() or not path.resolve().is_relative_to(package.resolve()):
            raise ValueError('The installation files must stay inside their extracted folder.')
        if not isinstance(expected, str) or not re.fullmatch(r'[a-f0-9]{64}', expected):
            raise ValueError('The release manifest contains an invalid checksum.')
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != expected:
            raise ValueError('Release checksum failed: ' + name)
    if (package / 'web/VERSION').read_text(encoding='utf-8').strip() != version:
        raise ValueError('The web application and full installer versions differ.')
    spec = importlib.util.spec_from_file_location('full_windows_installation_contract', package / 'release_contract.py')
    full = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(full)
    return full.validate_stage(package, 'windows', version)


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('Run Install-OpenWebPBX.ps1 -Check to check the complete installer.')
        description = validate_package(Path(sys.argv[1]))
        print('OpenWeb PBX ' + description['version'] + ' full standalone Windows installation verified.')
        print('No earlier OpenWeb PBX installation is required. The local database and services are set up automatically.')
    except (OSError, ValueError, TypeError, KeyError) as error:
        print('Installation check failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
