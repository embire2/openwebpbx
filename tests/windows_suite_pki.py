#!/usr/bin/env python3
"""Actual recovery-input AST and generated X509 controls; no host/store mutation."""
import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys
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
$commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.Extent.Text.StartsWith('& $python ') -and $node.Extent.Text.Contains('--phase prepare-pki')},$true))
if($commands.Count -ne 1){throw 'The actual PKI preparation command must be unique.'}
$flags=@();foreach($element in $commands[0].CommandElements|Select-Object -Skip 1){if($element.Extent.Text -ceq '$script'){break};$flags+=$element.Extent.Text}
[IO.File]::WriteAllText(($inputFile+'.flags.json'),(ConvertTo-Json -InputObject $flags),[Text.UTF8Encoding]::new($false))
$guards=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($expectedVersion -cnotmatch ')},$true))
if($guards.Count -ne 1){throw 'The actual immutable factory version guard must be unique.'}
$guard=[ScriptBlock]::Create($guards[0].Extent.Text);$results=@()
foreach($case in @(
 @{package='1.0.13';installed='1.0.13';completed=$true;restore=$true;domain='windowsqa.example.invalid';accept=$true},
 @{package='1.0.20';installed='1.0.20';completed=$true;restore=$true;domain='windowsqa.example.invalid';accept=$true},
 @{package='1.0.20';installed='1.0.13';completed=$true;restore=$true;domain='windowsqa.example.invalid';accept=$false},
 @{package='';installed='';completed=$true;restore=$true;domain='windowsqa.example.invalid';accept=$false},
 @{package='1.0.20';installed='1.0.20';completed=$false;restore=$true;domain='windowsqa.example.invalid';accept=$false},
 @{package='1.0.20';installed='1.0.20';completed=$true;restore=$false;domain='windowsqa.example.invalid';accept=$false},
 @{package='1.0.20';installed='1.0.20';completed=$true;restore=$true;domain='foreign.example.invalid';accept=$false}
)){
 $expectedVersion=$case.package;$installation=@{Version=$case.installed;Completed=$case.completed;RestoreServer=$case.restore;DomainName=$case.domain};$accepted=$true
 try{& $guard}catch{$accepted=$false}
 if($accepted -ne $case.accept){throw 'The actual factory source/version/identity guard did not enforce its expected boundary.'};$results+=$accepted
}
[IO.File]::WriteAllText(($inputFile+'.guards.json'),(ConvertTo-Json -InputObject $results),[Text.UTF8Encoding]::new($false))
''')
    subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-File', str(extractor),
                    '-SourceRoot', str(root), '-inputFile', str(input_path), '-evidence', str(evidence)],
                   check=True, capture_output=True)
    source_input = json.loads(input_path.read_text(encoding='utf-8-sig'))
    flags = json.loads(Path(str(input_path) + '.flags.json').read_text(encoding='utf-8-sig'))
    guards = json.loads(Path(str(input_path) + '.guards.json').read_text(encoding='utf-8-sig'))
    check(guards == [True, True, False, False, False, False, False])
    check(flags == ['-I', '-B'])
    check("@('-I','-B',$script,'--input',$inputFile,'--phase','pki-server')" in (root / 'tests/windows-suite-pki.ps1').read_text())
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
    # Run the actual PKI generator in fresh child interpreters against ordinary
    # copied cryptography sources. Like the packaged Windows _pth runtime,
    # these live outside the standard-library ZIP. -I ignores the workflow's
    # PYTHONDONTWRITEBYTECODE; only explicit -B keeps the extraction immutable.
    import cryptography
    package = Path(cryptography.__file__).resolve().parent
    for label, arguments in [('previous', ['-I']), ('actual', flags)]:
        runtime = base / (label + '-runtime')
        runtime.mkdir()
        shutil.copytree(package, runtime / 'cryptography', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        before = {path.relative_to(runtime).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in runtime.rglob('*') if path.is_file()}
        child_evidence = base / (label + '-evidence')
        child_evidence.mkdir()
        child_input = base / (label + '-input.json')
        child_input.write_text(json.dumps(source_input | {'evidence_directory': str(child_evidence)}))
        child = base / (label + '-child.py')
        child.write_text('import importlib.util,json,sys\nfrom pathlib import Path\n'
                         + 'sys.path.insert(0,' + repr(str(runtime)) + ')\n'
                         + 'spec=importlib.util.spec_from_file_location("actual_native",' + repr(str(root / 'tests/windows-native-acceptance.py')) + ')\n'
                         + 'native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)\n'
                         + 'native.prepare_pki(native.Fixture(' + repr(str(child_input)) + '))\n'
                         + 'import cryptography\n'
                         + 'assert Path(cryptography.__file__).resolve() == Path(' + repr(str(runtime / 'cryptography/__init__.py')) + ').resolve()\n'
                         + 'print(json.dumps({"isolated":sys.flags.isolated,"dont_write_bytecode":sys.dont_write_bytecode}))\n')
        import os
        result = subprocess.run([sys.executable] + arguments + [str(child)],
                                env=os.environ | {'PYTHONDONTWRITEBYTECODE': '1'},
                                check=True, capture_output=True, text=True)
        status = json.loads(result.stdout)
        check(status['isolated'] == 1 and status['dont_write_bytecode'] == (label == 'actual'))
        after = {path.relative_to(runtime).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                 for path in runtime.rglob('*') if path.is_file()}
        check(all(after.get(path) == digest for path, digest in before.items()))
        if label == 'previous':
            added = set(after) - set(before)
            check(bool(added) and all('__pycache__/' in path and path.endswith('.pyc') for path in added))
        else:
            check(before == after)
        check((child_evidence / 'fixture.pfx').is_file() and (child_evidence / 'pki-private.json').is_file())
print(f'PASS {checks} actual AST/X509 recovery-PKI input/signature/key controls; no store or PBX touched')
