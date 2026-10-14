#!/usr/bin/env python3
"""Read the pinned MSI tables/cabinet without installing or running its actions."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

MSI_SHA = 'f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d'
CORE_SHA = '8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726'
APR_SHA = 'bb3adfa1b6b7e3f699b037a0429fca49482e5a9e829ad1f01cc31d447a74a56d'
STOCK_SOFIA_SHA = 'ccf98b4c8ff99f2d670e88ec605f837795e4b878a2984c1df2ea36d9319aeff5'
STARTUP_MODULES = ('mod_commands.dll', 'mod_event_socket.dll', 'mod_console.dll', 'mod_logfile.dll', 'mod_sofia.dll')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def table_rows(path, query, columns):
    msi = ctypes.WinDLL('msi.dll')
    handle = ctypes.c_uint32
    msi.MsiOpenDatabaseW.argtypes = [ctypes.c_wchar_p, ctypes.c_void_p, ctypes.POINTER(handle)]
    msi.MsiDatabaseOpenViewW.argtypes = [handle, ctypes.c_wchar_p, ctypes.POINTER(handle)]
    msi.MsiViewExecute.argtypes = [handle, handle]
    msi.MsiViewFetch.argtypes = [handle, ctypes.POINTER(handle)]
    msi.MsiRecordGetStringW.argtypes = [handle, ctypes.c_uint, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint)]
    msi.MsiCloseHandle.argtypes = [handle]
    database, view = handle(), handle()

    def checked(result):
        if result:
            raise ValueError('Read-only MSI table access failed with code ' + str(result) + '.')

    checked(msi.MsiOpenDatabaseW(str(path.resolve()), None, ctypes.byref(database)))  # MSIDBOPEN_READONLY
    try:
        checked(msi.MsiDatabaseOpenViewW(database, query, ctypes.byref(view)))
        checked(msi.MsiViewExecute(view, handle()))
        result = []
        while True:
            record = handle()
            status = msi.MsiViewFetch(view, ctypes.byref(record))
            if status == 259:  # ERROR_NO_MORE_ITEMS
                break
            checked(status)
            try:
                row = []
                for field in range(1, columns + 1):
                    length = ctypes.c_uint()
                    status = msi.MsiRecordGetStringW(record, field, None, ctypes.byref(length))
                    if status not in (0, 234) or length.value > 32768:
                        raise ValueError('A pinned MSI table string is invalid.')
                    capacity = ctypes.c_uint(length.value + 1)
                    text = ctypes.create_unicode_buffer(capacity.value)
                    checked(msi.MsiRecordGetStringW(record, field, text, ctypes.byref(capacity)))
                    row.append(text.value)
                result.append(row)
            finally:
                msi.MsiCloseHandle(record)
        return result
    finally:
        if view.value:
            msi.MsiCloseHandle(view)
        msi.MsiCloseHandle(database)


def selected_files(files, components, directory, include_startup_probe=False):
    selected = [(row, row[2].split('|')[-1]) for row in files
                if components.get(row[1]) == directory and row[2].split('|')[-1].lower().endswith('.dll')]
    if not include_startup_probe:
        return selected
    required = ('FreeSwitchConsole.exe',) + STARTUP_MODULES
    module_directory = None
    for name in required:
        matches = [row for row in files if row[2].split('|')[-1].casefold() == name.casefold()]
        if len(matches) != 1 or matches[0][1] not in components:
            raise ValueError('The exact MSI startup runtime is absent or ambiguous.')
        row = matches[0]
        actual_directory = components[row[1]]
        if name == 'FreeSwitchConsole.exe':
            if actual_directory != directory:
                raise ValueError('The MSI console is outside the reviewed core directory.')
            relative = name
        else:
            if not actual_directory or actual_directory == directory:
                raise ValueError('The MSI support module directory is invalid.')
            if module_directory is not None and actual_directory != module_directory:
                raise ValueError('The MSI startup modules belong to different directories.')
            module_directory = actual_directory
            relative = 'mod/' + name
        selected.append((row, relative))
    return selected


def extract(msi, output, include_startup_probe=False):
    if sys.platform != 'win32' or msi.is_symlink() or digest(msi) != MSI_SHA:
        raise ValueError('Read-only extraction requires Windows and the exact pinned source MSI.')
    if output.exists() or not output.is_absolute():
        raise ValueError('Use a new dedicated extraction directory.')
    components = dict(table_rows(msi, 'SELECT `Component`, `Directory_` FROM `Component`', 2))
    files = table_rows(msi, 'SELECT `File`, `Component_`, `FileName`, `FileSize` FROM `File`', 4)
    cores = [row for row in files if row[2].split('|')[-1].lower() == 'freeswitch.dll']
    if len(cores) != 1 or cores[0][1] not in components:
        raise ValueError('The pinned MSI does not identify one unambiguous core directory.')
    directory = components[cores[0][1]]
    selected = selected_files(files, components, directory, include_startup_probe)
    seven = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / '7-Zip/7z.exe'
    command = str(seven) if seven.is_file() else shutil.which('7z.exe')
    if not command:
        raise ValueError('The hosted 7-Zip data extractor is required.')
    output.mkdir(parents=True)
    cabinet, core = output / 'cabinet', output / 'core'
    core.mkdir()
    subprocess.run([command, 'x', '-y', '-o' + str(cabinet), str(msi.resolve())], check=True)
    copied = {}
    for (identity, _, original_name, size), relative in selected:
        name = original_name.split('|')[-1]
        if not identity or any(c in identity for c in '/\\:') or any(c in name for c in '/\\:') or relative.casefold() in copied:
            raise ValueError('The pinned MSI core file identity is unsafe or duplicated.')
        source = cabinet / identity
        if source.is_symlink() or not source.is_file() or source.stat().st_size != int(size):
            raise ValueError('A cabinet member differs from its pinned MSI File table.')
        destination = core / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        copied[relative.casefold()] = digest(destination)
    if copied.get('freeswitch.dll') != CORE_SHA or copied.get('libapr.dll') != APR_SHA:
        raise ValueError('The extracted core/APR hashes differ from the reviewed pinned MSI.')
    if include_startup_probe and copied.get('mod/mod_sofia.dll') != STOCK_SOFIA_SHA:
        raise ValueError('The exact MSI stock registrar control did not verify.')
    result = {'schema': 1, 'source_msi_sha256': MSI_SHA, 'core_sha256': CORE_SHA, 'apr_sha256': APR_SHA,
              'core_directory': str(core), 'files': copied, 'msi_access': 'read-only-tables-and-cabinet',
              'installer_actions_executed': False, 'extractor_sha256': digest(Path(command))}
    if include_startup_probe:
        result['startup_probe_files'] = ['FreeSwitchConsole.exe'] + ['mod/' + name for name in STARTUP_MODULES]
    (output / 'core-extraction.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--msi', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--include-startup-probe', action='store_true', help='Extract only the exact console and five support modules for the private native startup gate.')
    args = parser.parse_args()
    try:
        result = extract(args.msi, args.output, args.include_startup_probe)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
