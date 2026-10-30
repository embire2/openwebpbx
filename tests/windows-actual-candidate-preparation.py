#!/usr/bin/env python3
"""Prepare a private signed-test pair from the untouched, qualified Windows22 ZIP.

No native compiler, version overlay, installation, signer or publication is used.
The failure variant changes only the last payload installer invoked by the
immutable Windows21 helper and two bounded noncustomer witness files.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
legacy = module('actual_candidate_legacy_preparer', Path(__file__).with_name('windows-canary-preparation.py'))
candidate = legacy.candidate
legacy.configure_versions('1.0.21', '1.0.22')
BASE = '1.0.21'
TARGET = '1.0.22'
NAME = f'openwebpbx-{TARGET}-windows-x64'
PUBLIC21 = {'source': 'cab93b390ba2e8f33c184f2f085740c2862031a6',
            'sha256': 'ce811ae1eaeb17b46f81bdfc0f12b0baa13409bded8f4df6788f8772d0ea855d',
            'bytes': 643070428}
MODERN = ('web_readiness','tenant_domains','meeting_transport','meeting_browser','phone_health','stun','native_clock','native_providers','native_call_me_back')
FAULT_FILES = {'Install-PhoneHealth.ps1', 'canary-fault.ps1', 'canary-fault.php'}
HOOK = r'''
# Private actual-candidate qualification only: the immutable public21 helper
# really calls this installer last, before validating/committing the update.
if($DeferStart){
 & (Join-Path $PSScriptRoot 'canary-fault.ps1') -PackageRoot $PackageRoot -MaintenanceLock $MaintenanceLock
}
'''

def fault_source():
    # Reuse every existing SYSTEM/parent/lock/runtime/assembly/mutation guard.
    # New actual-candidate scope is narrower than the older canary fixture.
    text = re.sub(r'1\.0\.(13|14)', lambda m: BASE if m[1] == '13' else TARGET, legacy.FAULT_PS_TEMPLATE)
    needle = "$nonce=[string]$contract.nonce;$witness="
    if text.count(needle) != 1:
        raise ValueError('The original bounded fault witness source changed.')
    text = text.replace(needle, "Check (!(Get-ScheduledTask -TaskName 'OpenWebPBX-Onboarding' -ErrorAction SilentlyContinue)) 'Onboarding must not exist before the original21 transaction commits.'\n" + needle)
    needle = 'normal_migration_completed=$true;'
    if text.count(needle) != 1:
        raise ValueError('The original witness fact boundary changed.')
    return text.replace(needle, "normal_migration_completed=$true;onboarding_absent_precommit=$true;actual_signed_candidate=$true;late_payload_hook='Install-PhoneHealth.ps1';")

def inventory(path):
    with zipfile.ZipFile(path) as archive:
        return {entry.filename: hashlib.sha256(archive.read(entry)).hexdigest()
                for entry in archive.infolist() if not entry.is_dir()}

def source_identity(facts):
    """Keep the artifact's build source distinct from this qualification run."""
    qualification = facts.get('source_commit')
    product = facts.get('product_source_commit', qualification)
    if any(re.fullmatch(r'[a-f0-9]{40}', str(v)) is None for v in (qualification, product)):
        raise ValueError('Immutable product and qualification sources are required.')
    if 'product_source_commit' in facts or 'replay' in facts:
        replay = facts.get('replay', {})
        if (replay.get('schema') != 1 or replay.get('original_product_source') != product or
                replay.get('qualification_source') != qualification or
                re.fullmatch(r'[1-9][0-9]{0,19}', str(replay.get('original_run',''))) is None or
                replay.get('exact_zip_sha256') != facts.get('artifacts',{}).get('candidate_sha256') or
                facts.get('candidate_artifact',{}).get('product_source_commit') != product or
                replay.get('windows_runtime_source_identical') is not True or replay.get('runtime_overlays') is not False):
            raise ValueError('Untouched replay product provenance differs from the qualification source.')
    return product, qualification

def eligible(facts, version):
    if facts.get('schema') != 1 or facts.get('state') not in ('passed', 'partial'):
        raise ValueError('The actual full-suite facts are not eligible.')
    product, qualification = source_identity(facts)
    for gate in (*legacy.ESSENTIAL_GATES, *MODERN):
        if facts.get('gates', {}).get(gate) != 'passed':
            raise ValueError('Every original full software gate must pass.')
    checksum = facts.get('candidate_artifact', {}).get('sha256')
    if (not re.fullmatch(r'[a-f0-9]{64}', str(checksum)) or
            facts.get('candidate_artifact', {}).get('filename') != f'openwebpbx-{version}-windows-x64.zip' or
            facts['candidate_artifact'].get('private_exclusions') != 'passed'):
        raise ValueError('The facts must bind the exact audited original ZIP.')
    if facts.get('artifacts', {}).get('candidate_sha256') != checksum:
        raise ValueError('The original artifact and candidate-export hashes differ.')
    if version == TARGET:
        transition = facts.get('public21_transition', {})
        if (facts.get('mode') != 'public21_to_actual_candidate22' or
                transition.get('state') != 'passed' or transition.get('upgrade_mechanism') != 'candidate22_manual_helper' or
                transition.get('candidate_source_commit') != product or
                transition.get('candidate_qualification_source_commit') != qualification or transition.get('candidate_sha256') != checksum or
                any(transition.get('gates', {}).get(g) != 'passed' for g in ('public21_to_candidate22','public21_rollback'))):
            raise ValueError('The actual22 archive needs its separately scoped real21 manual transition/full suite.')
    return checksum

def verify_pair(normal, fault, target_facts, provenance):
    checksum = eligible(target_facts, TARGET)
    product, qualification = source_identity(target_facts)
    if (provenance.get('kind') != 'actual_candidate' or provenance.get('target_version') != TARGET or
            provenance.get('base_version') != BASE or provenance.get('target_source_commit') != product or provenance.get('target_qualification_source_commit') != qualification or
            provenance.get('normal', {}).get('sha256') != checksum or provenance.get('no_native_rebuild') is not True or
            provenance.get('no_version_overlay') is not True):
        raise ValueError('The actual candidate/source identity differs.')
    candidate.verify(normal, TARGET, checksum)
    candidate.verify(fault, TARGET, provenance['fault']['sha256'])
    before, after = inventory(normal), inventory(fault)
    changed = {p.removeprefix(NAME+'/') for p in before.keys() | after.keys() if before.get(p) != after.get(p)}
    if changed != FAULT_FILES | {'release-manifest.json'}:
        raise ValueError('The actual fault changed an undeclared payload.')
    with zipfile.ZipFile(normal) as n, zipfile.ZipFile(fault) as f:
        original = n.read(NAME+'/Install-PhoneHealth.ps1')
        if f.read(NAME+'/Install-PhoneHealth.ps1') != original + HOOK.encode():
            raise ValueError('The late invoked installer changed outside its exact appended hook.')
        if f.read(NAME+'/canary-fault.ps1') != fault_source().encode() or f.read(NAME+'/canary-fault.php') != legacy.FAULT_PHP.encode():
            raise ValueError('The complete bounded witness differs from its source.')
    return {'normal_sha256': checksum, 'fault_sha256': legacy.digest(fault), 'changed_files': sorted(changed)}

def prepare(base_archive, base_facts_path, target_archive, target_facts_path, output, *, source_commit, run_id):
    base_archive, base_facts_path, target_archive, target_facts_path, output = map(Path, (base_archive, base_facts_path, target_archive, target_facts_path, output))
    if not re.fullmatch(r'[a-f0-9]{40}', str(source_commit)) or not re.fullmatch(r'[0-9]+', str(run_id)):
        raise ValueError('Immutable preparation source/run identities are required.')
    base_facts, target_facts = legacy.document(base_facts_path), legacy.document(target_facts_path)
    if (eligible(base_facts, BASE) != PUBLIC21['sha256'] or base_facts['source_commit'] != PUBLIC21['source'] or
            base_archive.stat().st_size != PUBLIC21['bytes']):
        raise ValueError('Only the genuine immutable public21 baseline is eligible.')
    base_result = candidate.verify(base_archive, BASE, PUBLIC21['sha256'])
    target_sha = eligible(target_facts, TARGET)
    target_product, target_qualification = source_identity(target_facts)
    target_result = candidate.verify(target_archive, TARGET, target_sha)
    if output.is_symlink() or output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise ValueError('A new empty private output is required.')
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.actual-candidate-', dir=output) as tmp:
        work = Path(tmp); fault_root = work/NAME; fault_root.mkdir()
        with zipfile.ZipFile(target_archive) as archive:
            # verify() already rejects traversal, symlinks/collisions and
            # unlisted payloads before extraction into this new owned tree.
            archive.extractall(work)
            manifest_bytes = archive.read(NAME+'/release-manifest.json')
        before = legacy.file_inventory(fault_root)
        phone = fault_root/'Install-PhoneHealth.ps1'
        if not phone.is_file() or b'[switch]$DeferStart' not in phone.read_bytes() or b'$MaintenanceLock' not in phone.read_bytes():
            raise ValueError('The last genuine public21 payload installer contract changed.')
        phone.write_bytes(phone.read_bytes()+HOOK.encode())
        (fault_root/'canary-fault.ps1').write_bytes(fault_source().encode())
        (fault_root/'canary-fault.php').write_bytes(legacy.FAULT_PHP.encode())
        legacy.manifest(fault_root)
        normal_dir, fault_dir = output/'normal', output/'fault';normal_dir.mkdir();fault_dir.mkdir()
        normal = normal_dir/(NAME+'.zip');shutil.copyfile(target_archive, normal)
        if legacy.digest(normal) != target_sha:
            raise ValueError('Normal ZIP must remain byte-identical, including original compression.')
        (normal_dir/NAME).mkdir();(normal_dir/NAME/'release-manifest.json').write_bytes(manifest_bytes)
        fault_result = legacy.package(fault_root, fault_dir/(NAME+'.zip'))
        (fault_dir/NAME).mkdir();shutil.copyfile(fault_root/'release-manifest.json', fault_dir/NAME/'release-manifest.json')
        provenance = {'schema':1,'kind':'actual_candidate','state':'prepared_unsigned','private_laboratory_only':True,
                      'base_version':BASE,'target_version':TARGET,'source_commit':base_facts['source_commit'],
                      'target_source_commit':target_product,'target_qualification_source_commit':target_qualification,'target_suite_run_id':str(target_facts['run_id']),
                      'preparation_source_commit':source_commit,'preparation_run_id':str(run_id),
                      'base_archive_sha256':base_result['sha256'],'base_facts_sha256':legacy.digest(base_facts_path),
                      'target_facts_sha256':legacy.digest(target_facts_path),'target_archive_sha256':target_sha,
                      'no_native_rebuild':True,'no_version_overlay':True,'normal':target_result | {'archive':normal.name,'bytes':normal.stat().st_size,'manifest_sha256':hashlib.sha256(manifest_bytes).hexdigest()},'fault':fault_result,
                      'fault_diff':legacy.difference(before,legacy.file_inventory(fault_root)),
                      'late_payload_hook':'Install-PhoneHealth.ps1','onboarding_must_be_absent_precommit':True,
                      'limitations':['Unsigned; Root signs offline.','Preparation is not an installation, rollback or calling result.']}
        verify_pair(normal, fault_dir/(NAME+'.zip'), target_facts, provenance)
        for name,path in [('target-facts.json',target_facts_path),('baseline-facts.json',base_facts_path)]:shutil.copyfile(path,output/name)
        (output/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
        return provenance

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for arg in ('base-archive','base-facts','target-archive','target-facts','output-dir'):parser.add_argument('--'+arg,type=Path,required=True)
    args=parser.parse_args()
    value=prepare(args.base_archive,args.base_facts,args.target_archive,args.target_facts,args.output_dir,source_commit=os.environ.get('GITHUB_SHA'),run_id=os.environ.get('GITHUB_RUN_ID'))
    print(json.dumps({'state':value['state'],'kind':value['kind'],'normal_sha256':value['normal']['sha256'],'fault_sha256':value['fault']['sha256']}))
if __name__=='__main__':main()
