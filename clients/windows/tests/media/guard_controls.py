#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Invoke actual entrypoints with non-hosted child environment; require early refusal."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", type=Path, required=True)
    parser.add_argument("--pwsh", type=Path, required=True)
    parser.add_argument("--assembly", type=Path, required=True)
    args = parser.parse_args()
    args.dotnet = args.dotnet.resolve(strict=True)
    args.pwsh = args.pwsh.resolve(strict=True)
    args.assembly = args.assembly.resolve(strict=True)
    here = Path(__file__).resolve().parent
    client = here.parents[1]
    env = os.environ.copy()
    env["GITHUB_ACTIONS"] = "false"
    env["RUNNER_ENVIRONMENT"] = "not-hosted-guard-control"
    with tempfile.TemporaryDirectory(prefix="phone-media-guards-") as scope:
        root = Path(scope)
        missing, report = root / "missing", root / "must-not-exist.json"
        cases = [
            ("managed", [str(args.dotnet), str(args.assembly), "--run", str(missing), str(report)], 2),
            ("wrapper", [str(args.pwsh), "-NoProfile", "-NonInteractive", "-File", str(client / "tools/Test-ClientMedia.ps1"), "-SdkZip", str(missing), "-CoreMsi", str(missing), "-EngineZip", str(missing), "-SourceCommit", "0" * 40, "-Report", str(report)], 1),
            ("extractor", [os.sys.executable, str(here / "extract_media_engine.py"), "--helper", str(missing), "--msi", str(missing), "--output", str(root / "absent")], 1),
        ]
        for name, command, expected in cases:
            result = subprocess.run(command, env=env, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
            if result.returncode != expected or result.stdout or len(result.stderr) > 32768 or list(root.iterdir()):
                raise RuntimeError("The actual early-refusal boundary failed: " + name)
            if name == "managed":
                value = json.loads(result.stderr)
                if value != {"schema": 1, "state": "refused_or_failed", "error_type": "InvalidOperationException"}:
                    raise RuntimeError("The managed guard did not return its closed refusal.")
        print(json.dumps({"schema": 1, "state": "passed_actual_early_refusals", "controls": len(cases), "non_hosted_child_environment": True, "native_engine_started": False, "actual_native_calling": False}))


if __name__ == "__main__":
    main()
