#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Read-only, pinned MSI extraction adapter for the disposable client media lab."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import traceback
from types import SimpleNamespace
sys.dont_write_bytecode = True

HELPER_SHA = "f3014f84cb7aa6fd51f751c1fe34605b7b80710771916c6c6013837c09412d98"
MODULES = ("mod_dptools.dll", "mod_dialplan_xml.dll", "mod_sndfile.dll", "mod_tone_stream.dll", "mod_conference.dll", "mod_vpx.dll")
SUBSTAGES = ("bootstrap", "validate_host", "helper_identity", "owned_paths", "helper_import", "helper_extract", "msi_tables", "select_media_modules", "extract_cabinet", "copy_core_files", "write_manifest")
substage = "bootstrap"


class MediaModuleSelectionError(ValueError):
    def __init__(self, module):
        self.module = module if module in MODULES else "unknown"
        super().__init__("Required unambiguous MSI media module absent.")


def closed_failure(error):
    allowed = {"ValueError", "MediaModuleSelectionError", "FileNotFoundError", "PermissionError", "OSError", "CalledProcessError", "TimeoutExpired", "ImportError", "ModuleNotFoundError", "KeyError", "TypeError", "AttributeError", "RuntimeError"}
    frames = [frame for frame in traceback.extract_tb(error.__traceback__)
              if Path(frame.filename).name in ("extract_media_engine.py", "extract-windows-core.py")]
    frame = frames[-1] if frames else None
    return {"schema": 1, "producer": "extract_media_engine.py", "state": "failed",
            "operation": "read_only_msi_media_extract", "substage": substage if substage in SUBSTAGES else "bootstrap",
            "exception_type": type(error).__name__ if type(error).__name__ in allowed else "other",
            "missing_module": error.module if isinstance(error, MediaModuleSelectionError) and error.module in MODULES else "unknown",
            "source_basename": Path(frame.filename).name if frame else "external_component",
            "source_line": frame.lineno if frame and 0 < frame.lineno <= 100000 else 0}


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def selection(base, files, components, directory):
    global substage
    substage = "select_media_modules"
    selected = base(files, components, directory, True)
    module_dirs = {components[row[1]] for row, relative in selected if relative.startswith("mod/")}
    if len(module_dirs) != 1:
        raise ValueError("Exact MSI module directory required.")
    for name in MODULES:
        matches = [row for row in files if row[2].split("|")[-1].casefold() == name.casefold()]
        if len(matches) != 1 or components.get(matches[0][1]) not in module_dirs:
            raise MediaModuleSelectionError(name)
        selected.append((matches[0], "mod/" + name))
    substage = "copy_core_files"
    return selected


def main():
    global substage
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--msi", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    substage = "validate_host"
    if sys.platform != "win32" or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("GITHUB_REPOSITORY") != "embire2/openwebpbx":
        raise ValueError("Only the disposable hosted Windows lab is allowed.")
    substage = "helper_identity"
    if args.helper.is_symlink() or sha(args.helper) != HELPER_SHA:
        raise ValueError("The read-only MSI table reader changed.")
    substage = "owned_paths"
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    for path in (args.msi, args.output):
        if not path.is_absolute() or not path.resolve().is_relative_to(root):
            raise ValueError("Owned temporary extraction paths required.")
    substage = "helper_import"
    spec = importlib.util.spec_from_file_location("owned_msi_table_reader", args.helper)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    original = helper.selected_files
    helper.selected_files = lambda files, components, directory, include_startup_probe=False: selection(original, files, components, directory)
    original_tables = helper.table_rows
    def tables(*arguments, **keywords):
        global substage
        substage = "msi_tables"
        return original_tables(*arguments, **keywords)
    helper.table_rows = tables
    def cabinet(*arguments, **keywords):
        global substage
        substage = "extract_cabinet"
        # Same command/arguments/check/one invocation. Route only its private
        # native stderr to the existing private stdout drain, leaving this
        # adapter's stderr a single closed diagnostic on failure.
        result = subprocess.run(*arguments, **keywords, stderr=subprocess.STDOUT)
        substage = "copy_core_files"
        return result
    helper.subprocess = SimpleNamespace(run=cabinet)
    substage = "helper_extract"
    result = helper.extract(args.msi, args.output, True)
    substage = "write_manifest"
    result["media_probe_files"] = ["mod/" + name for name in MODULES]
    result["media_adapter_sha256"] = sha(Path(__file__))
    result["installer_actions_executed"] = False
    (args.output / "media-extraction.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No MSI table paths, original errors or contents leave this process.
        print(json.dumps(closed_failure(error)), file=sys.stderr)
        sys.exit(1)
