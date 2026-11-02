"""QA-only exact empty tenant-worker content check; never runs the worker."""
import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

FILES = {
    'C:\\ProgramData\\fusionpbx\\tenant-domains-instance-key.pem': 'key',
    'C:\\ProgramData\\OpenWebPBX\\tenant-domains\\ready.json': 'ready',
    'C:\\ProgramData\\OpenWebPBX\\tenant-domains\\proofs\\.well-known\\openwebpbx-instance\\web.config': 'proof',
}
PROOF_SHA256 = '4f389ee1fa66dadb5951c29cc9b14642f1b87b1c914446235eefca6a57f84ba4'
RECIPES = {
    'directory': '662af41d7f05cd6a71602c0c4afb62bdebd75b3db3ddf11d98ada9638caffb5e',
    'atomic': '5ebe767ac3c2f231e3153933648c53de6b332660555e2027990b44192bf31074',
    'identity': '784bc9ee7c9c521067ce85cbbf0edeff39967d88695a9b95fe1029c5f982a35a',
}

def need(value, message):
    if not value:
        raise RuntimeError(message)

def object_json(raw):
    def pairs(rows):
        out = {}
        for key, value in rows:
            need(key not in out, 'Duplicate metadata key')
            out[key] = value
        return out
    return json.loads(raw, object_pairs_hook=pairs)

def validate_bytes(expected_host, values):
    need(type(expected_host) is str and expected_host and len(expected_host) <= 253, 'Original host required')
    need(set(values) == {'key', 'ready', 'proof'}, 'Three exact files required')
    key = serialization.load_pem_private_key(values['key'], None)
    need(isinstance(key, ec.EllipticCurvePrivateKey) and key.curve.name == 'secp256r1', 'Exact P256 key required')
    need(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()) == values['key'], 'Source key format differs')
    public = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    ready = object_json(values['ready'])
    expected = {'schema': 1, 'server_host': expected_host, 'key_hash': hashlib.sha256(public).hexdigest(), 'aliases': {}}
    need(ready == expected and type(ready['schema']) is int, 'Exact empty ready/P256/host binding required')
    need(json.dumps(expected).encode() == values['ready'], 'Ready bytes differ from source serialization')
    need(hashlib.sha256(values['proof']).hexdigest() == PROOF_SHA256, 'Exact source proof configuration required')
    return True

def source_recipes(package):
    path = package/'tenant-domains.py'
    text = path.read_text()
    nodes = {n.name:n for n in ast.parse(text).body if isinstance(n, ast.FunctionDef)}
    for name, expected in RECIPES.items():
        need(hashlib.sha256(ast.get_source_segment(text, nodes[name]).encode()).hexdigest() == expected, 'Frozen tenant file recipe differs')

def main():
    need(os.name == 'nt' and len(sys.argv) == 3, 'Actual Windows private context required')
    context = object_json(Path(sys.argv[1]).read_bytes())
    need(set(context) == {'expected_host', 'files', 'package_root'} and set(context['files']) == set(FILES), 'Exact content context required')
    package = Path(context['package_root'])
    source_recipes(package)
    values = {}
    for name, kind in FILES.items():
        path = Path(name)
        for item in (path, *path.parents):
            need(not item.is_symlink() and not(item.lstat().st_file_attributes & 0x400), 'Linked proof path refused')
        stat = path.stat()
        need(path.is_file() and stat.st_nlink == 1 and 1 <= stat.st_size <= 4096, 'Ordinary bounded proof file required')
        raw = path.read_bytes(); row = context['files'][name]
        need(set(row) == {'sha256','bytes'} and type(row['bytes']) is int and row['bytes'] == len(raw) and row['sha256'] == hashlib.sha256(raw).hexdigest(), 'Content differs from actual captured private map')
        values[kind] = raw
    validate_bytes(context['expected_host'], values)
    # This native IPC action performs only required-policy reads. It never
    # invokes initialize/tick/lease/reconcile or any certificate operation.
    app = Path('C:/OpenWebPBX')
    result = subprocess.run([str(app/'php/php.exe'),str(app/'tools/onboarding.php'),str(app/'web'),'policy'],input=b'{}',capture_output=True,timeout=40)
    need(result.returncode == 0 and len(result.stdout) <= 1024, 'Current legacy policy IPC unavailable')
    policy = object_json(result.stdout)
    need(type(policy) is dict and set(policy) == {'required'} and policy['required'] is False, 'Current legacy required policy must remain false')
    need(not Path('C:/ProgramData/OpenWebPBX-Installation/onboarding-required').exists(), 'Legacy required marker changed')
    out={'schema':1,'state':'passed','original_policy_required':False,'p256_ready_binding':True,'exact_source_proof':True,'new_files':3,'new_directories':5,'source_recipes':RECIPES,'actual_CI_prior_paths_claimed':False}
    with Path(sys.argv[2]).open('x',encoding='utf-8') as stream:
        json.dump(out,stream)

if __name__ == '__main__':
    main()
