#!/usr/bin/env python3
"""Derive an import-library definition from an exact pinned x64 PE DLL."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct


def definition(data, expected):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('The target core checksum differs from the verified MSI.')
    if data[:2] != b'MZ' or len(data) < 64:
        raise ValueError('The engine core is not a PE DLL.')
    pe = struct.unpack_from('<I', data, 60)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('The engine core has no PE header.')
    machine, count = struct.unpack_from('<HH', data, pe + 4)
    optional_size, characteristics = struct.unpack_from('<HH', data, pe + 20)
    optional = pe + 24
    if machine != 0x8664 or not characteristics & 0x2000 or struct.unpack_from('<H', data, optional)[0] != 0x20b or not 0 < count < 100:
        raise ValueError('The engine core must be an x64 PE32+ DLL.')
    export_rva, export_size = struct.unpack_from('<II', data, optional + 112)
    sections = []
    for number in range(count):
        position = optional + optional_size + number * 40
        virtual_size, virtual, size, raw = struct.unpack_from('<IIII', data, position + 8)
        flags = struct.unpack_from('<I', data, position + 36)[0]
        sections.append((virtual, max(virtual_size, size), raw, size, flags))

    def offset(rva, length=1):
        for virtual, extent, raw, size, _ in sections:
            if virtual <= rva and rva + length <= virtual + min(extent, size):
                value = raw + rva - virtual
                if value + length <= len(data):
                    return value
        raise ValueError('A core export points outside its bounded PE section.')

    address = offset(export_rva, 40)
    base, functions, names, addresses, name_addresses, ordinals = struct.unpack_from('<IIIIII', data, address + 16)
    if not 0 < names <= functions <= 65536:
        raise ValueError('The core export count is invalid.')
    entries = []
    data_exports = []
    seen = set()
    for index in range(names):
        name_rva = struct.unpack_from('<I', data, offset(name_addresses + index * 4, 4))[0]
        start = offset(name_rva)
        end = data.find(b'\0', start, min(len(data), start + 4096))
        if end < 0:
            raise ValueError('A core export name is not bounded.')
        name = data[start:end].decode('ascii')
        if not re.fullmatch(r'[A-Za-z_?][A-Za-z0-9_?@$]*', name) or name in seen:
            raise ValueError('A core export name is invalid or duplicated.')
        seen.add(name)
        ordinal = struct.unpack_from('<H', data, offset(ordinals + index * 2, 2))[0]
        if ordinal >= functions:
            raise ValueError('A core export ordinal is invalid.')
        function = struct.unpack_from('<I', data, offset(addresses + ordinal * 4, 4))[0]
        if export_rva <= function < export_rva + export_size:
            raise ValueError('Forwarded core exports require separate review.')
        offset(function)
        flags = next(flags for virtual, extent, _, _, flags in sections if virtual <= function < virtual + extent)
        is_data = not flags & 0x20000000
        entries.append(f' {name} @{base + ordinal}' + (' DATA' if is_data else ''))
        if is_data:
            data_exports.append(name)
    text = 'LIBRARY FreeSwitch.dll\nEXPORTS\n' + '\n'.join(entries) + '\n'
    return text, {'machine': 'x64', 'core_sha256': expected, 'named_exports': len(entries), 'data_exports': data_exports,
                  'definition_sha256': hashlib.sha256(text.encode('ascii')).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.dll.is_symlink() or args.dll.stat().st_size > 128 * 1024 * 1024:
            raise ValueError('The core input must be an ordinary bounded DLL.')
        text, report = definition(args.dll.read_bytes(), args.expected_sha256)
        args.output.write_text(text, encoding='ascii')
    except (ValueError, UnicodeError, OSError, struct.error, StopIteration):
        parser.exit(1, 'The exact x64 core export definition could not be generated.\n')
    print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    main()
