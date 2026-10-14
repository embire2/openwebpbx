#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build the signed Windows package's four music rates; no runtime converter."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import wave


def build(source_root: Path, output: Path) -> dict:
    source_root = source_root.resolve(strict=True)
    source = source_root / "lofi-beat-loop-schmoop.wav"
    manifest = json.loads((source_root / "manifest.json").read_text())
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    if source.is_symlink() or original != manifest["files"][source.name]["sha256"]:
        raise ValueError("Bundled source music failed verification")
    with wave.open(str(source)) as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError("The canonical music format changed")
        frames = wav.getnframes()
    if output.exists() or output.is_symlink():
        raise ValueError("Choose a new ordinary music bundle output")
    output.mkdir(parents=True, mode=0o755)
    output.chmod(0o755)
    result = {"schema": 1, "source_sha256": original, "rates": {}}
    try:
        for rate in (8000, 16000, 32000, 48000):
            directory = output / str(rate)
            directory.mkdir(mode=0o755)
            directory.chmod(0o755)
            destination = directory / source.name
            if rate == 16000:
                shutil.copyfile(source, destination)
            else:
                subprocess.run(["sox", str(source), "-r", str(rate), str(destination), "rate", "-v", str(rate)], check=True)
            destination.chmod(0o644)
            with wave.open(str(destination)) as wav:
                if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype(), wav.getnframes()) != (1, 2, rate, "NONE", frames * rate // 16000):
                    raise ValueError("A prepared music rate failed format verification")
            result["rates"][str(rate)] = {"path": str(destination.relative_to(output)), "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(), "bytes": destination.stat().st_size, "frames": frames * rate // 16000}
        for name in ("README.md", "manifest.json"):
            shutil.copyfile(source_root / name, output / name)
            (output / name).chmod(0o644)
        (output / "bundle-manifest.json").write_text(json.dumps(result, indent=2) + "\n")
        (output / "bundle-manifest.json").chmod(0o644)
        return result
    except BaseException:
        shutil.rmtree(output)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    build(args.source_root, args.output)
    print("PASS: four verified prebuilt hold-music rates and original provenance")
