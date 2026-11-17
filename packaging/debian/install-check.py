#!/usr/bin/env python3
"""Read-only integrity check for a complete, standalone Debian installation."""
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import sys

sys.dont_write_bytecode = True


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('The release manifest contains a duplicate field.')
        result[key] = value
    return result


def validate_package(package):
    package = Path(package)
    if package.is_symlink() or not package.is_dir():
        raise ValueError('Use an ordinary folder containing the complete extracted release.')
    version = (package / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('The installation version is invalid.')
    manifest = json.loads((package / 'release-manifest.json').read_text(), object_pairs_hook=unique_keys)
    if not isinstance(manifest, dict) or set(manifest) != {'version', 'files'} or manifest['version'] != version:
        raise ValueError('The complete installation manifest is invalid.')
    files = manifest['files']
    if not isinstance(files, dict) or not {'VERSION', 'web/VERSION', 'installation.json', 'release_contract.py', 'install-check.py'} <= set(files):
        raise ValueError('The complete standalone installation is required.')
    actual = set()
    for path in package.rglob('*'):
        if path.is_symlink():
            raise ValueError('The extracted installation must not contain symbolic links.')
        if path.is_file():
            actual.add(path.relative_to(package).as_posix())
    if actual != set(files) | {'release-manifest.json'}:
        raise ValueError('Files are missing or unlisted. Extract the complete release into an empty folder.')
    for name, expected in files.items():
        if not isinstance(name, str) or not name or '\\' in name or ':' in name:
            raise ValueError('The release manifest contains an invalid path.')
        relative = PurePosixPath(name)
        if relative.is_absolute() or any(part in {'', '.', '..'} for part in name.split('/')):
            raise ValueError('The release manifest contains an unsafe path.')
        path = package / relative
        if not path.is_file() or not path.resolve().is_relative_to(package.resolve()):
            raise ValueError('The release files must stay inside the extracted folder.')
        if not isinstance(expected, str) or not re.fullmatch(r'[a-f0-9]{64}', expected):
            raise ValueError('The release manifest contains an invalid checksum.')
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != expected:
            raise ValueError('Release checksum failed: ' + name)
    if (package / 'web/VERSION').read_text().strip() != version:
        raise ValueError('The web application and full installer versions differ.')
    # The portable contract implementation is loaded only after its exact
    # manifest hash has passed. No installed PBX module or previous version is used.
    spec = importlib.util.spec_from_file_location('full_installation_contract', package / 'release_contract.py')
    full = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(full)
    description = full.validate_stage(package, 'debian', version)
    for name in ['install.sh', 'server/OpenWebPbx.Server', 'updater/OpenWebPbx.Updater']:
        if not (package / name).stat().st_mode & 0o111:
            raise ValueError('An installer or service executable is not executable: ' + name)
    return description


def main():
    if len(sys.argv) != 1:
        raise ValueError('Run install.sh --check to check this full installation package.')
    description = validate_package(Path(__file__).resolve().parent)
    print('OpenWeb PBX ' + description['version'] + ' full standalone installation verified.')
    print('No earlier OpenWeb PBX installation is required. The local database and services are set up automatically.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError) as error:
        print('Installation check failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
