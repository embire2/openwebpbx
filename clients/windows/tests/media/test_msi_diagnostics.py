#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Actual closed producer/stream-routing functions; all MSI/process inputs doubled."""
import ast
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


adapter = load(HERE / "extract_media_engine.py", "actual_closed_msi_adapter")
selection_fixture = load(HERE / "test_engine_selection.py", "actual_msi_selection_fixture")


class DiagnosticControls(unittest.TestCase):
    def test_every_actual_missing_module_has_only_the_closed_enum_and_real_source(self):
        for name in adapter.MODULES:
            with self.subTest(module=name):
                rows, components = selection_fixture.fixture()
                try:
                    adapter.selection(selection_fixture.helper.selected_files,
                                      [row for row in rows if row[2] != name], components, "ROOT")
                except adapter.MediaModuleSelectionError as error:
                    value = adapter.closed_failure(error)
                else:
                    self.fail("The actual unchanged required-module predicate did not refuse.")
                self.assertEqual(set(value), {"schema", "producer", "state", "operation", "substage", "exception_type", "missing_module", "source_basename", "source_line"})
                self.assertEqual(value["missing_module"], name)
                self.assertEqual(value["substage"], "select_media_modules")
                self.assertEqual(value["exception_type"], "MediaModuleSelectionError")
                self.assertEqual(value["source_basename"], "extract_media_engine.py")
                self.assertGreater(value["source_line"], 0)
                self.assertNotIn(str(HERE), json.dumps(value))

    def test_private_messages_unknown_module_and_unknown_type_never_escape(self):
        adapter.substage = "select_media_modules"
        value = adapter.closed_failure(adapter.MediaModuleSelectionError("PRIVATE_MUST_NOT_ESCAPE"))
        self.assertEqual(value["missing_module"], "unknown")
        private_error = type("PrivateCustomerException", (Exception,), {})("PRIVATE_MUST_NOT_ESCAPE")
        value = adapter.closed_failure(private_error)
        self.assertEqual(value["exception_type"], "other")
        self.assertEqual(value["source_basename"], "external_component")
        self.assertEqual(value["source_line"], 0)
        self.assertNotIn("PRIVATE", json.dumps(value))
        self.assertNotIn("PrivateCustomer", json.dumps(value))

    def actual_nested(self, name, namespace):
        tree = ast.parse((HERE / "extract_media_engine.py").read_text())
        main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main")
        found = [node for node in main.body if isinstance(node, ast.FunctionDef) and node.name == name]
        self.assertEqual(len(found), 1)
        exec(compile(ast.Module(body=found, type_ignores=[]), str(HERE / "extract_media_engine.py"), "exec"), namespace)
        return namespace[name]

    def test_actual_table_wrapper_preserves_one_invocation_arguments_result_and_failure(self):
        calls = []
        def tables(*args, **kwargs):
            calls.append((args, kwargs))
            return [("unchanged",)]
        namespace = {"original_tables": tables, "substage": "helper_extract"}
        actual = self.actual_nested("tables", namespace)
        self.assertEqual(actual("owned", "query", 4), [("unchanged",)])
        self.assertEqual(calls, [(("owned", "query", 4), {})])
        self.assertEqual(namespace["substage"], "msi_tables")
        original = ValueError("PRIVATE_ERROR")
        def fail(*args):
            raise original
        namespace["original_tables"] = fail
        with self.assertRaises(ValueError) as caught:
            actual("same", "query", 4)
        self.assertIs(caught.exception, original)

    def test_actual_cabinet_wrapper_routes_only_stderr_and_preserves_primary(self):
        calls = []
        def run(*args, **kwargs):
            calls.append((args, kwargs))
            return "unchanged result"
        namespace = {"subprocess": SimpleNamespace(run=run, STDOUT=subprocess.STDOUT), "substage": "helper_extract"}
        actual = self.actual_nested("cabinet", namespace)
        command = ["owned7z", "x", "-y", "-oowned", "owned.msi"]
        self.assertEqual(actual(command, check=True), "unchanged result")
        self.assertEqual(calls, [((command,), {"check": True, "stderr": subprocess.STDOUT})])
        self.assertEqual(namespace["substage"], "copy_core_files")
        original = subprocess.CalledProcessError(17, command)
        def fail(*args, **kwargs):
            raise original
        namespace["subprocess"].run = fail
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            actual(command, check=True)
        self.assertIs(caught.exception, original)
        self.assertEqual(namespace["substage"], "extract_cabinet")


if __name__ == "__main__":
    unittest.main()
