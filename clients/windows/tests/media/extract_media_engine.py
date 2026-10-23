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
sys.dont_write_bytecode = True

HELPER_SHA = "f3014f84cb7aa6fd51f751c1fe34605b7b80710771916c6c6013837c09412d98"
MODULES = ("mod_dptools.dll", "mod_dialplan_xml.dll", "mod_sndfile.dll", "mod_tone_stream.dll", "mod_conference.dll", "mod_vpx.dll")


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def selection(base, files, components, directory):
    selected = base(files, components, directory, True)
    module_dirs = {components[row[1]] for row, relative in selected if relative.startswith("mod/")}
    if len(module_dirs) != 1:
        raise ValueError("Exact MSI module directory required.")
    for name in MODULES:
        matches = [row for row in files if row[2].split("|")[-1].casefold() == name.casefold()]
        if len(matches) != 1 or components.get(matches[0][1]) not in module_dirs:
            raise ValueError("Required unambiguous MSI media module absent.")
        selected.append((matches[0], "mod/" + name))
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--msi", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "win32" or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("GITHUB_REPOSITORY") != "embire2/openwebpbx":
        raise ValueError("Only the disposable hosted Windows lab is allowed.")
    if args.helper.is_symlink() or sha(args.helper) != HELPER_SHA:
        raise ValueError("The read-only MSI table reader changed.")
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    for path in (args.msi, args.output):
        if not path.is_absolute() or not path.resolve().is_relative_to(root):
            raise ValueError("Owned temporary extraction paths required.")
    spec = importlib.util.spec_from_file_location("owned_msi_table_reader", args.helper)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    original = helper.selected_files
    helper.selected_files = lambda files, components, directory, include_startup_probe=False: selection(original, files, components, directory)
    result = helper.extract(args.msi, args.output, True)
    result["media_probe_files"] = ["mod/" + name for name in MODULES]
    result["media_adapter_sha256"] = sha(Path(__file__))
    result["installer_actions_executed"] = False
    (args.output / "media-extraction.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No MSI table paths, original errors or contents leave this process.
        print(json.dumps({"schema": 1, "state": "failed", "operation": "read_only_msi_media_extract", "exception_type": type(error).__name__}), file=sys.stderr)
        sys.exit(1)
