#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Exercise actual MSI-selection functions with invented table rows; no MSI access."""
import hashlib
import importlib.util
from pathlib import Path
import unittest
import sys
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


adapter = module(HERE / "extract_media_engine.py", "actual_media_extract_adapter")
helper_path = REPO / "packaging/freeswitch/extract-windows-core.py"
helper = module(helper_path, "actual_read_only_core_extract")


def fixture():
    files = [["core", "c_core", "FreeSwitch.dll", "100"], ["console", "c_core", "FreeSwitchConsole.exe", "100"]]
    components = {"c_core": "ROOT", "c_module": "MOD"}
    for index, name in enumerate(helper.STARTUP_MODULES + adapter.MODULES):
        files.append(["module" + str(index), "c_module", name, "100"])
    return files, components


class SelectionChecks(unittest.TestCase):
    def test_exact_helper_pin_and_actual_complete_selection(self):
        self.assertEqual(hashlib.sha256(helper_path.read_bytes()).hexdigest(), adapter.HELPER_SHA)
        rows, components = fixture()
        selected = adapter.selection(helper.selected_files, rows, components, "ROOT")
        self.assertEqual(len(selected), 13)
        self.assertEqual({path for _, path in selected if path.startswith("mod/")}, {"mod/" + name for name in helper.STARTUP_MODULES + adapter.MODULES})

    def test_all_missing_media_modules_refuse(self):
        for required in adapter.MODULES:
            with self.subTest(required=required):
                rows, components = fixture()
                with self.assertRaises(ValueError):
                    adapter.selection(helper.selected_files, [row for row in rows if row[2] != required], components, "ROOT")

    def test_all_ambiguous_and_foreign_media_modules_refuse(self):
        for required in adapter.MODULES:
            rows, components = fixture()
            row = next(row for row in rows if row[2] == required)
            with self.subTest(required=required, mode="duplicate"):
                with self.assertRaises(ValueError):
                    adapter.selection(helper.selected_files, rows + [["other", "c_module", required.upper(), "100"]], components, "ROOT")
            with self.subTest(required=required, mode="foreign"):
                row[1] = "c_other"
                components["c_other"] = "FOREIGN"
                with self.assertRaises(ValueError):
                    adapter.selection(helper.selected_files, rows, components, "ROOT")

    def test_original_startup_and_directory_guards_remain(self):
        rows, components = fixture()
        with self.assertRaises(ValueError):
            adapter.selection(helper.selected_files, [row for row in rows if row[2] != "mod_sofia.dll"], components, "ROOT")
        rows, components = fixture()
        components["c_module"] = "ROOT"
        with self.assertRaises(ValueError):
            adapter.selection(helper.selected_files, rows, components, "ROOT")


if __name__ == "__main__":
    unittest.main()
