#!/usr/bin/env python3
"""Bounded PE export tests; no Windows runner, engine or installed files required."""
import hashlib
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('core_exports', Path(__file__).resolve().parents[1] / 'packaging/freeswitch/core-exports.py')
exports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exports)


def dll():
    data = bytearray(0xa00)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 0x80)
    data[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HH', data, 0x84, 0x8664, 2)
    struct.pack_into('<HH', data, 0x94, 240, 0x2000)
    optional = 0x98
    struct.pack_into('<H', data, optional, 0x20b)
    struct.pack_into('<II', data, optional + 112, 0x2000, 0x80)
    for index, (virtual, raw, flags) in enumerate([(0x1000, 0x400, 0x60000020), (0x2000, 0x600, 0x40000040)]):
        position = optional + 240 + index * 40
        struct.pack_into('<IIII', data, position + 8, 0x200, virtual, 0x200, raw)
        struct.pack_into('<I', data, position + 36, flags)
    struct.pack_into('<IIIIII', data, 0x610, 1, 2, 2, 0x2030, 0x2040, 0x2050)
    struct.pack_into('<II', data, 0x630, 0x1000, 0x20c0)
    struct.pack_into('<II', data, 0x640, 0x2060, 0x2070)
    struct.pack_into('<HH', data, 0x650, 0, 1)
    data[0x660:0x66f] = b'switch_fixture\0'
    data[0x670:0x680] = b'SWITCH_GLOBAL_x\0'
    return data


class CoreExportChecks(unittest.TestCase):
    def verify(self, data):
        return exports.definition(data, hashlib.sha256(data).hexdigest())

    def test_function_and_data_exports_have_correct_import_semantics(self):
        text, result = self.verify(dll())
        self.assertIn('switch_fixture @1\n', text)
        self.assertIn('SWITCH_GLOBAL_x @2 DATA\n', text)
        self.assertEqual(result['data_exports'], ['SWITCH_GLOBAL_x'])
        self.assertEqual(result['named_exports'], 2)

    def test_checksum_is_checked_before_export_use(self):
        with self.assertRaises(ValueError):
            exports.definition(dll(), '0' * 64)

    def test_exact_pthread_library_name_retains_export_ordinals_and_data(self):
        data = dll()
        text, result = exports.definition(data, hashlib.sha256(data).hexdigest(), 'pthread.dll')
        self.assertTrue(text.startswith('LIBRARY pthread.dll\nEXPORTS\n'))
        self.assertIn('SWITCH_GLOBAL_x @2 DATA\n', text)
        self.assertEqual(result['definition_sha256'], hashlib.sha256(text.encode('ascii')).hexdigest())

    def test_unreviewed_import_library_name_is_refused(self):
        data = dll()
        for name in ('unreviewed.dll', 'pthread.dll\nEXPORTS\n injected', '../pthread.dll'):
            with self.assertRaises(ValueError):
                exports.definition(data, hashlib.sha256(data).hexdigest(), name)

    def test_real_cli_output_hash_matches_bytes_with_windows_newline_translation(self):
        class WindowsTextPath(type(Path())):
            def write_text(self, data, encoding=None, errors=None, newline=None):
                # Model Windows' platform default while writing actual bytes.
                written = data.replace('\n', '\r\n') if newline is None else data
                self.write_bytes(written.encode(encoding or 'utf-8'))
                return len(written)

        with tempfile.TemporaryDirectory(prefix='openweb-def-') as directory:
            source, output = Path(directory) / 'source.dll', Path(directory) / 'pthread.def'
            source.write_bytes(dll())
            captured = io.StringIO()
            arguments = ['core-exports.py', '--dll', str(source), '--expected-sha256', hashlib.sha256(dll()).hexdigest(),
                         '--output', str(output), '--library-name', 'pthread.dll']
            with patch.object(exports, 'Path', WindowsTextPath), patch.object(sys, 'argv', arguments), contextlib.redirect_stdout(captured):
                exports.main()
            result = json.loads(captured.getvalue())
            actual = output.read_bytes()
            self.assertNotIn(b'\r', actual)
            self.assertTrue(actual.startswith(b'LIBRARY pthread.dll\nEXPORTS\n'))
            self.assertEqual(hashlib.sha256(actual).hexdigest(), result['definition_sha256'])

    def test_zero_initialized_data_in_mapped_section_tail_is_valid(self):
        data = dll()
        struct.pack_into('<I', data, 0x98 + 240 + 40 + 8, 0x400)
        struct.pack_into('<I', data, 0x634, 0x2300)
        text, result = self.verify(data)
        self.assertIn('SWITCH_GLOBAL_x @2 DATA\n', text)
        self.assertEqual(result['data_exports'], ['SWITCH_GLOBAL_x'])

    def test_virtual_function_tail_or_unmapped_data_is_refused(self):
        data = dll()
        struct.pack_into('<I', data, 0x98 + 240 + 8, 0x400)
        struct.pack_into('<I', data, 0x630, 0x1300)
        with self.assertRaises(ValueError):
            self.verify(data)
        data = dll()
        struct.pack_into('<I', data, 0x634, 0x2300)
        with self.assertRaises(ValueError):
            self.verify(data)

    def test_wrong_machine_or_optional_header_is_refused(self):
        for position, value in [(0x84, 0x14c), (0x98, 0x10b)]:
            data = dll()
            struct.pack_into('<H', data, position, value)
            with self.assertRaises(ValueError):
                self.verify(data)

    def test_forwarded_exports_need_review(self):
        data = dll()
        struct.pack_into('<I', data, 0x630, 0x2060)
        with self.assertRaisesRegex(ValueError, 'Forwarded'):
            self.verify(data)

    def test_out_of_bounds_export_tables_and_ordinals_are_refused(self):
        for position, value, kind in [(0x630, 0xffff0000, '<I'), (0x640, 0xffffffff, '<I'), (0x650, 10, '<H')]:
            data = dll()
            struct.pack_into(kind, data, position, value)
            with self.assertRaises(ValueError):
                self.verify(data)

    def test_duplicate_or_unsafe_names_are_refused(self):
        data = dll()
        struct.pack_into('<I', data, 0x644, 0x2060)
        with self.assertRaises(ValueError):
            self.verify(data)
        data = dll()
        data[0x660] = ord(';')
        with self.assertRaises(ValueError):
            self.verify(data)


if __name__ == '__main__':
    unittest.main()
