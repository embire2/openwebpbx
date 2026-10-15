#!/usr/bin/env python3
"""Actual recovery-input AST and generated X509 controls; no host/store mutation."""
import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import tempfile
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--powershell', default='pwsh')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('recovery_native', root / 'tests/windows-native-acceptance.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


with tempfile.TemporaryDirectory(prefix='openweb-recovery-pki-') as directory:
    base = Path(directory)
    evidence = base / 'evidence'
    evidence.mkdir()
    input_path = base / 'input.json'
    extractor = base / 'payload.ps1'
    extractor.write_text(r'''
param([string]$SourceRoot,[string]$inputFile,[string]$evidence)
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite-pki.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual recovery fixture must parse.'}
$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Extent.Text.StartsWith('[IO.File]::WriteAllText($inputFile,')},$true))
if($nodes.Count -ne 1){throw 'The actual recovery input writer must be uniquely identified.'}
Invoke-Expression $nodes[0].Extent.Text
''')
    subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-File', str(extractor),
                    '-SourceRoot', str(root), '-inputFile', str(input_path), '-evidence', str(evidence)],
                   check=True, capture_output=True)
    source_input = json.loads(input_path.read_text(encoding='utf-8-sig'))
    check(re.fullmatch('[a-f0-9]{24}', source_input['scope']) is not None)
    check(source_input['source_root'] == str(root) and source_input['evidence_directory'] == str(evidence))
    # Reproduce the previous complete-GUID input through the actual generator.
    old_evidence = base / 'old-evidence'
    old_evidence.mkdir()
    old_input = base / 'old-input.json'
    old_input.write_text(json.dumps(source_input | {'scope': 'a' * 32, 'evidence_directory': str(old_evidence)}))
    try:
        native.prepare_pki(native.Fixture(old_input))
    except ValueError:
        check(True)
    else:
        raise AssertionError('The previous 68-character CN was unexpectedly accepted')
    check(not list(old_evidence.iterdir()))
    native.prepare_pki(native.Fixture(input_path))
    private = json.loads((evidence / 'pki-private.json').read_text())
    ca = x509.load_pem_x509_certificate((evidence / 'fixture-root.pem').read_bytes())
    leaf = x509.load_pem_x509_certificate((evidence / 'fixture-leaf.pem').read_bytes())
    crl = x509.load_der_x509_crl((evidence / 'fixture.crl').read_bytes())
    key = serialization.load_pem_private_key((evidence / 'fixture-key.pem').read_bytes(), None)
    pfx_key, pfx_leaf, pfx_chain = pkcs12.load_key_and_certificates((evidence / 'fixture.pfx').read_bytes(), private['password'].encode())
    common_name = ca.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    check(common_name == 'OpenWeb PBX fictional hosted-runner ' + source_input['scope'] and len(common_name) == 60)
    check(ca.issuer == ca.subject and leaf.issuer == ca.subject and crl.issuer == ca.subject)
    for signed in (ca, leaf):
        ca.public_key().verify(signed.signature, signed.tbs_certificate_bytes, padding.PKCS1v15(), signed.signature_hash_algorithm)
        check(True)
    ca.public_key().verify(crl.signature, crl.tbs_certlist_bytes, padding.PKCS1v15(), crl.signature_hash_algorithm)
    check(True)
    check(ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca)
    check(not leaf.extensions.get_extension_for_class(x509.BasicConstraints).value.ca)
    check(leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName) == ['windowsqa.example.invalid'])
    check(leaf.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value == x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]))
    points = leaf.extensions.get_extension_for_class(x509.CRLDistributionPoints).value
    check([name.value for point in points for name in point.full_name] == ['http://127.0.0.1:18985/fixture.crl'])
    check(pfx_leaf == leaf and len(pfx_chain) == 1 and pfx_chain[0] == ca)
    check(pfx_key.private_numbers() == key.private_numbers())
    check(x509.load_der_x509_certificate((evidence / 'fixture-root.cer').read_bytes()) == ca)
    check((evidence / 'fixture-chain.pem').read_bytes() == (evidence / 'fixture-leaf.pem').read_bytes() + (evidence / 'fixture-root.pem').read_bytes())
    check(private['root_thumbprint'] == hashlib.sha1(ca.public_bytes(serialization.Encoding.DER)).hexdigest())
    check(private['leaf_thumbprint'] == hashlib.sha1(leaf.public_bytes(serialization.Encoding.DER)).hexdigest())
print(f'PASS {checks} actual AST/X509 recovery-PKI input/signature/key controls; no store or PBX touched')
