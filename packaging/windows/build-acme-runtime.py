#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Materialise the unmodified, pinned official simple-acme Windows runtime."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import urllib.request
import zipfile

VERSION = "2.4.1.2444"
COMMIT = "b21505a1b21e0f7738d95b2aea00306cdf9260f2"
ARCHIVE = "simple-acme.v2.4.1.2444.win-x64.trimmed.zip"
ARCHIVE_SHA256 = "b53fd863dfe4e02ec8618e9676b331d805fa1d688b83251f797f9339d221dada"
SOURCE_SHA256 = "68f60e945a36d9a55e1f4f58e71e1ef9c36223b3b2d5ae557deec12e10a0a326"
LICENSE_SHA256 = "f35d8ebf4da420cca8699d306e95770ff6c8238acf640cba657586e91f046c89"
URL = "https://github.com/simple-acme/simple-acme/releases/download/v2.4.1/" + ARCHIVE
SOURCE_URL = "https://codeload.github.com/simple-acme/simple-acme/tar.gz/" + COMMIT
LICENSE_URL = "https://raw.githubusercontent.com/simple-acme/simple-acme/" + COMMIT + "/LICENSE"


def fetched(url: str, maximum: int) -> bytes:
    with urllib.request.urlopen(url, timeout=90) as source:
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("An upstream file exceeded its bounded size")
    return data


def build(archive: Path, output: Path, licenses: Path | None = None) -> dict:
    if archive.is_symlink() or hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("The official ACME archive hash did not match")
    if output.exists() or output.is_symlink():
        raise ValueError("Choose a new ordinary ACME bundle output")
    licenses = licenses or Path(__file__).resolve().parent.parent / "licenses" / "simple-acme"
    inventory_path = licenses / "inventory.json"
    inventory = json.loads(inventory_path.read_text())
    if inventory_path.is_symlink() or inventory["source_commit"] != COMMIT or inventory["binary_archive_sha256"] != ARCHIVE_SHA256:
        raise ValueError("The ACME license/source inventory changed")
    for name, expected in inventory["file_sha256"].items():
        if PurePosixPath(name).name != name or (licenses / name).is_symlink() or hashlib.sha256((licenses / name).read_bytes()).hexdigest() != expected:
            raise ValueError("An ACME dependency license changed")
    license_bytes = (licenses / "LICENSE.simple-acme.txt").read_bytes()
    if hashlib.sha256(license_bytes).hexdigest() != LICENSE_SHA256:
        raise ValueError("The pinned upstream license changed")
    output.mkdir(parents=True, mode=0o755)
    output.chmod(0o755)
    try:
        with zipfile.ZipFile(archive) as package:
            seen = set()
            for entry in package.infolist():
                path = PurePosixPath(entry.filename)
                if path.is_absolute() or ".." in path.parts or "\\" in entry.filename or entry.filename in seen or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError("The official archive contains an unsafe entry")
                seen.add(entry.filename)
                destination = output.joinpath(*path.parts)
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                if entry.is_dir():
                    destination.mkdir(exist_ok=True, mode=0o755)
                else:
                    destination.write_bytes(package.read(entry))
                    destination.chmod(0o644)
        if not (output / "wacs.exe").is_file() or not (output / "settings_default.json").is_file():
            raise ValueError("The pinned ACME archive is incomplete")
        (output / "LICENSE.simple-acme.txt").write_bytes(license_bytes)
        shutil.copytree(licenses, output / "licenses")
        metadata = {"repository": "https://github.com/simple-acme/simple-acme", "release": "v2.4.1", "commit": COMMIT, "version": VERSION, "license": "Apache-2.0", "archive_url": URL, "archive_sha256": ARCHIVE_SHA256, "source_url": SOURCE_URL, "source_sha256": SOURCE_SHA256, "license_url": LICENSE_URL, "license_sha256": LICENSE_SHA256, "modified_upstream_files": False}
        (output / "UPSTREAM.json").write_text(json.dumps(metadata, indent=2) + "\n")
        files = {p.relative_to(output).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.rglob("*")) if p.is_file()}
        result = {"schema": 1, "version": VERSION, "archive_sha256": ARCHIVE_SHA256, "files": files}
        (output / "bundle-manifest.json").write_text(json.dumps(result, indent=2) + "\n")
        for path in output.rglob("*"):
            path.chmod(0o755 if path.is_dir() else 0o644)
        return result
    except BaseException:
        shutil.rmtree(output)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path, help="Official ZIP; download URL is pinned in this script")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--licenses", type=Path, help="Reviewed pinned dependency license/source inventory")
    args = parser.parse_args()
    build(args.archive, args.output, args.licenses)
    print("PASS: pinned unmodified simple-acme runtime, source recipe and upstream license")
