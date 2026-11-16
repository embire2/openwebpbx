#!/usr/bin/env python3
"""Offline component-manifest checks; uses newly generated fixture keys only."""
import base64
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / 'packaging/updates/sign-windows-updater-repair.py'
sys.path.insert(0, str(SOURCE.parent))
spec = importlib.util.spec_from_file_location('repair_signer', SOURCE)
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
count = 0


def check(value, message):
    global count
    count += 1
    if not value:
        raise AssertionError(message)


def reject(action):
    global count
    try:
        action()
    except (ValueError, OSError, subprocess.CalledProcessError):
        count += 1
        return
    raise AssertionError('An invalid component-signing input was accepted.')


with tempfile.TemporaryDirectory(prefix='openweb-repair-signer-fixture-') as folder:
    base = Path(folder)
    root = base / 'repair'
    root.mkdir()
    names = sorted(signer.REQUIRED) + [f'Fixture{i:03}.dll' for i in range(223)]
    for name in names:
        (root / name).write_bytes(('Owned signer fixture: ' + name).encode())
    private, public, other_private, other_public = [base / name for name in ('test-private.pem', 'test-public.pem', 'other-private.pem', 'other-public.pem')]
    for key, pub in ((private, public), (other_private, other_public)):
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(key)], check=True, capture_output=True)
        key.chmod(0o600)
        subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-out', str(pub)], check=True, capture_output=True)
    output = base / 'repair-manifest.json'
    receipt = signer.sign(root, private, public, output)
    envelope = json.loads(output.read_bytes())
    payload_bytes = base64.b64decode(envelope['payload'], validate=True)
    payload = json.loads(payload_bytes)
    check(set(envelope) == {'key_id', 'payload', 'signature'} and envelope['key_id'] == 'release-2026-a', 'Envelope does not match the pinned-key protocol.')
    check(set(payload) == {'schema', 'kind', 'product', 'repair_id', 'version', 'minimum_installed_version', 'maximum_installed_version', 'published_at', 'expires_at', 'files'}, 'Repair schema differs from the Windows bootstrap.')
    check(payload['schema'] == 1 and payload['kind'] == 'windows-updater-repair' and payload['product'] == 'openwebpbx', 'Wrong component namespace.')
    check(payload['repair_id'] == 'upgrade-path-1' and payload['version'] == '1.0.23', 'Wrong component identity.')
    check((payload['minimum_installed_version'], payload['maximum_installed_version']) == ('1.0.20', '1.0.23'), 'Installed range widened.')
    check(len(payload['files']) == 227 and payload['files'] == signer.inventory(root), 'Inventory is incomplete or not exact.')
    check(receipt['files'] == 227 and 'test-private' not in json.dumps(receipt), 'Receipt contains private source details.')
    check(output.stat().st_mode & 0o777 == 0o600, 'Signed output is not private by default.')
    expires = dt.datetime.fromisoformat(payload['expires_at'].replace('Z', '+00:00'))
    published = dt.datetime.fromisoformat(payload['published_at'].replace('Z', '+00:00'))
    check(expires - published == dt.timedelta(days=150), 'Expiry is not bounded from actual publication.')
    unsigned, signature = base / 'payload', base / 'signature'
    unsigned.write_bytes(payload_bytes)
    original_signature = base64.b64decode(envelope['signature'], validate=True)
    signature.write_bytes(original_signature)

    def verify():
        return subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public), '-signature', str(signature), str(unsigned)], capture_output=True).returncode == 0

    check(verify(), 'Generated-key signature did not verify independently.')
    unsigned.write_bytes(payload_bytes.replace(b'1.0.23', b'1.0.24', 1))
    check(not verify(), 'Tampered component identity retained a valid signature.')
    unsigned.write_bytes(payload_bytes)
    signature.write_bytes(bytes([original_signature[0] ^ 1]) + original_signature[1:])
    check(not verify(), 'Tampered signature was accepted.')
    signature.write_bytes(original_signature)
    changed = root / names[-1]
    original = changed.read_bytes()
    changed.write_bytes(b'changed fixture')
    check(signer.inventory(root) != payload['files'], 'Changed executable bytes matched the signed inventory.')
    changed.write_bytes(original)
    changed.unlink()
    reject(lambda: signer.build(root))
    changed.write_bytes(original)
    extra = root / 'unexpected.dll'
    extra.write_bytes(b'extra')
    reject(lambda: signer.build(root))
    extra.unlink()
    exe = root / 'OpenWebPbx.Updater.exe'
    renamed = root / 'wrong-entry.exe'
    exe.rename(renamed)
    reject(lambda: signer.build(root))
    renamed.rename(exe)
    duplicate = root / 'openwebpbx.updater.EXE'
    duplicate.write_bytes(b'case collision')
    reject(lambda: signer.build(root))
    duplicate.unlink()
    unsafe = root / 'invalid:stream.dll'
    changed.rename(unsafe)
    reject(lambda: signer.build(root))
    unsafe.rename(changed)
    unsafe_directory = root / 'invalid:directory'
    unsafe_directory.mkdir()
    reject(lambda: signer.build(root))
    unsafe_directory.rmdir()
    target = base / 'external.bin'
    target.write_bytes(b'external fixture')
    changed.unlink()
    changed.symlink_to(target)
    reject(lambda: signer.build(root))
    changed.unlink()
    os.link(target, changed)
    reject(lambda: signer.build(root))
    changed.unlink()
    changed.write_bytes(original)
    linked_dir = root / 'linked-directory'
    linked_dir.symlink_to(base, target_is_directory=True)
    reject(lambda: signer.build(root))
    linked_dir.unlink()
    linked_root = base / 'linked-root'
    linked_root.symlink_to(root, target_is_directory=True)
    reject(lambda: signer.build(linked_root))
    before = output.read_bytes()
    reject(lambda: signer.sign(root, private, public, output))
    check(output.read_bytes() == before, 'A retained manifest was overwritten.')
    reject(lambda: signer.sign(root, private, public, root / 'manifest.json'))
    for days in (0, 181, True, 1.5):
        reject(lambda days=days: signer.build(root, days=days))
    reject(lambda: signer.build(root, now=dt.datetime(2026, 11, 16)))
    for mode in (0o644, 0o400):
        private.chmod(mode)
        reject(lambda: signer.sign(root, private, public, base / 'bad-mode.json'))
    private.chmod(0o600)
    linked_key = base / 'linked-key'
    linked_key.symlink_to(private)
    reject(lambda: signer.sign(root, linked_key, public, base / 'linked-key.json'))
    repository = signer.REPOSITORY
    signer.REPOSITORY = base
    try:
        reject(lambda: signer.sign(root, private, public, base / 'checkout-key.json'))
    finally:
        signer.REPOSITORY = repository
    mismatch = base / 'wrong-key.json'
    reject(lambda: signer.sign(root, private, other_public, mismatch))
    check(not mismatch.exists(), 'A signature made with an unpinned key was published.')
    cli_output = base / 'cli.json'
    result = subprocess.run([sys.executable, str(SOURCE), '--repair-root', str(root), '--private-key', str(private), '--public-key', str(public), '--expires-days', '1', '--output', str(cli_output)], check=True, capture_output=True)
    check(json.loads(result.stdout)['files'] == 227 and cli_output.is_file(), 'Standalone operator command failed.')

print(f'PASS: {count} offline Windows updater component-signing, exact inventory, tamper and refusal controls (generated fixture keys only)')
