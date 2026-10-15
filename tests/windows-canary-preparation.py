#!/usr/bin/env python3
"""Prepare unsigned, private Windows 1.0.14 laboratory canaries.

This never installs, signs or publishes anything. Original native source hashes
must resolve to the qualified immutable git tree. The only source overlays are
VERSION and platform/Directory.Build.props, supplied below native-root/overlays.
Native version evidence is read from the actual Windows build's verification.json;
preparation itself is not a native Windows acceptance result.
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
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

BASE = '1.0.13'
TARGET = '1.0.14'
NAME = f'openwebpbx-{TARGET}-windows-x64'
REPOSITORY = Path(__file__).resolve().parents[1]
ESSENTIAL_GATES = ('fresh', 'native_sip_audio', 'backups', 'direct_113_helper_reapply',
                   'direct_failure_rollback', 'restore_gate_startup')
OVERLAYS = {'VERSION', 'platform/Directory.Build.props'}
ASSEMBLIES = {'server/OpenWebPbx.Server.dll', 'desktop/OpenWebPbx.Desktop.dll',
              'updater/OpenWebPbx.Updater.dll'}
NATIVE_TREES = {'server', 'desktop', 'updater'}
SOURCE_EVIDENCE_FIELDS = {'schema', 'version', 'source_commit', 'sdk', 'operating_system',
                          'runner_image', 'visual_studio', 'run_url', 'source_inputs', 'overlays',
                          'preparation_source_commit', 'preparation_run_id'}
VERIFICATION_FIELDS = {'schema', 'version', 'assemblies', 'manager_startup',
                       'protocol_checks', 'updater_checks', 'database_integration'}
FAULT_FILES = {'Install-MailQueue.ps1', 'canary-fault.ps1', 'canary-fault.php'}
HASH = re.compile(r'[a-f0-9]{64}')
MAX_ENTRIES = 100_000
MAX_FILE = 256 * 1024**2
MAX_TOTAL = 20 * 1024**3
MAX_JSON = 32 * 1024**2

_spec = importlib.util.spec_from_file_location(
    'windows_candidate_archive', Path(__file__).with_name('windows_candidate_archive.py'))
candidate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(candidate)


FAULT_HOOK = r'''
# Private canary fault: the complete ordinary deferred mail installation above
# must finish before the separately guarded noncustomer witness may run.
if($DeferStart -and !$Tick){
 & (Join-Path $PSScriptRoot 'canary-fault.ps1') -PackageRoot $PackageRoot -MaintenanceLock $MaintenanceLock
}
'''

FAULT_PS = r'''#Requires -Version 5.1
# Private disposable canary only. Never sign, publish, register a phone or call a carrier.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][IO.FileStream]$MaintenanceLock)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
Check ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $PSVersionTable.PSEdition -ne 'Core') 'Native Windows PowerShell is required.'
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$qa=Join-Path $state 'qualification113'
$contractPath=Join-Path $qa 'canary-fault-contract.json';$sentinelPath=Join-Path $qa 'canary-host-sentinel.json'
if(-not ('CanaryFileIdentity' -as [type])){Add-Type @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class CanaryFileIdentity {
 [StructLayout(LayoutKind.Sequential)] public struct Info {
  public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
  public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
 }
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info information);
}
'@}
function PrivateFile([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force
 Check (!$item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Length -le 65536) 'An ordinary bounded private contract file is required.'
 $file=[IO.File]::Open($Path,'Open','Read','Read');try{$information=[CanaryFileIdentity+Info]::new();Check ([CanaryFileIdentity]::GetFileInformationByHandle($file.SafeFileHandle,[ref]$information) -and $information.Links -eq 1) 'Private contract links are forbidden.'}finally{$file.Dispose()}
 $acl=Get-Acl -LiteralPath $Path;$owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
 Check ($acl.AreAccessRulesProtected -and $owner -in 'S-1-5-18','S-1-5-32-544') 'Private contract ownership or inheritance is invalid.'
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
  Check ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -in 'S-1-5-18','S-1-5-32-544') 'A private contract grants unrelated access.'
 }
 return Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
Check ($identity.User.Value -eq 'S-1-5-18') 'Only the installed SYSTEM worker may reach this private witness.'
$contract=PrivateFile $contractPath;$sentinel=PrivateFile $sentinelPath
Check ($contract.schema -eq 1 -and $contract.authorized -eq $true -and $contract.nonce -match '^[a-f0-9]{24}$' -and [string]$contract.run_id -match '^[0-9]+$') 'The private fault contract is not authorized.'
foreach($record in $contract,$sentinel){
 Check ($record.disposable -eq $true -and $record.github_actions -eq $true -and $record.runner_environment -eq 'github-hosted' -and $record.repository -eq 'embire2/openwebpbx' -and $record.expected_computer -eq $env:COMPUTERNAME) 'Only the exact disposable GitHub runner is eligible.'
}
Check ($sentinel.schema -eq 1 -and $sentinel.nonce -eq $contract.nonce -and [string]$sentinel.run_id -eq [string]$contract.run_id -and $contract.baseline_version -eq '1.0.13' -and $contract.target_version -eq '1.0.14' -and $contract.expected_domain -eq 'windowsqa.example.invalid') 'The independent runner sentinel does not match.'
Check ($MaintenanceLock.CanRead -and $MaintenanceLock.CanWrite -and [IO.Path]::GetFullPath($MaintenanceLock.Name) -eq (Join-Path $state 'upgrade.lock')) 'The genuine maintenance transaction is required.'
$installation=Get-Content (Join-Path $state 'installation.json') -Raw|ConvertFrom-Json
Check ($installation.Completed -and $installation.RestoreServer -and $installation.Version -eq '1.0.13' -and $installation.DomainName -eq 'windowsqa.example.invalid') 'The original disposable restore-server identity is required.'
$runtime=Get-Content (Join-Path $state 'runtime.json') -Raw|ConvertFrom-Json
Check ($runtime.Switch.Host -eq '127.0.0.1' -and [int]$runtime.Switch.Port -eq 8021 -and $runtime.ConnectionStrings.Pbx -match '(?i)(^|;)Host=127\.0\.0\.1(;|$)' -and $runtime.ConnectionStrings.Pbx -match '(?i)(^|;)Port=5433(;|$)') 'Only the original local private runtime is eligible.'
$journal=Get-Content (Join-Path $state 'updates\install-journal.json') -Raw|ConvertFrom-Json
Check ($journal.state -eq 'migrating' -and $journal.previous_version -eq '1.0.13' -and $journal.version -eq '1.0.14' -and !$journal.operator_rollback) 'The real original worker transaction has not reached normal migration.'
$worker=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'"
$self=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)
$workerProcess=Get-CimInstance Win32_Process -Filter ('ProcessId='+$worker.ProcessId)
Check ($worker.State -eq 'Running' -and $worker.StartName -eq 'LocalSystem' -and $self.ParentProcessId -eq $worker.ProcessId -and $workerProcess.ExecutablePath -eq "$root\updater\slots\1.0.13\OpenWebPbx.Updater.exe") 'The original installed worker must be the actual parent.'
Check ([Reflection.AssemblyName]::GetAssemblyName("$root\updater\slots\1.0.13\OpenWebPbx.Updater.dll").Version.ToString() -eq '1.0.13.0') 'The original worker assembly was not retained.'
foreach($service in 'OpenWebPBX','FreeSWITCH'){Check ((Get-Service $service).Status -eq 'Stopped') 'Candidate witness requires stopped original call/job services.'}
Check ((Get-Content (Join-Path $PackageRoot 'VERSION') -Raw).Trim() -eq '1.0.14' -and (Get-Content "$root\web\VERSION" -Raw).Trim() -eq '1.0.14') 'The actual candidate payload was not deployed.'
foreach($part in 'server','desktop','updater'){
 $dll=Join-Path $PackageRoot ($part+'\OpenWebPbx.'+$(if($part -eq 'server'){'Server'}elseif($part -eq 'desktop'){'Desktop'}else{'Updater'})+'.dll')
 Check ([Reflection.AssemblyName]::GetAssemblyName($dll).Version.ToString() -eq '1.0.14.0') 'The source candidate does not have a real14 assembly.'
 if($part -ne 'updater'){
  $deployed=Join-Path $root ($part+'\'+[IO.Path]::GetFileName($dll))
  Check ([Reflection.AssemblyName]::GetAssemblyName($deployed).Version.ToString() -eq '1.0.14.0' -and (Get-FileHash $deployed -Algorithm SHA256).Hash -eq (Get-FileHash $dll -Algorithm SHA256).Hash) 'The actual candidate assembly bytes were not deployed.'
 }
}
function OwnedDeferredTask([string]$Name,[string]$Description,[string]$Execute,[string]$Arguments){
 $task=Get-ScheduledTask -TaskName $Name
 Check ($task.TaskPath -eq '\' -and $task.Description -eq $Description -and $task.Principal.UserId -in 'SYSTEM','S-1-5-18' -and $task.Principal.LogonType -eq 'ServiceAccount' -and !$task.Settings.Enabled -and @($task.Actions).Count -eq 1 -and $task.Actions.Execute -eq $Execute -and $task.Actions.Arguments -eq $Arguments) 'The genuine owned deferred task is required.'
 return $task
}
# Install-Backups and the ordinary Install-MailQueue have already returned.
Check (Test-Path "$root\backup-runtime\python.exe" -PathType Leaf) 'The ordinary pinned backup runtime is missing.'
$backup=Get-ScheduledTask -TaskName 'OpenWebPBX-Backups'
Check ($backup.TaskPath -eq '\' -and $backup.Principal.UserId -in 'SYSTEM','S-1-5-18' -and $backup.Principal.LogonType -eq 'ServiceAccount' -and !$backup.Settings.Enabled -and @($backup.Actions).Count -eq 1 -and $backup.Actions.Execute -eq "$root\backup-runtime\python.exe" -and $backup.Actions.Arguments -eq '-I "C:\OpenWebPBX\tools\backups.py" worker' -and $backup.Actions.WorkingDirectory -eq "$root\tools") 'The genuine deferred backup task is required.'
$mail=OwnedDeferredTask 'OpenWebPBX Outgoing Mail' 'OpenWeb PBX owned global outgoing mail task' "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Install-MailQueue.ps1" -Tick'
$nonce=[string]$contract.nonce;$witness=Join-Path $qa ('canary-fault-witness-'+$nonce+'.json');$newFile="$root\backup-runtime\canary-$nonce.txt"
Check (!(Test-Path -LiteralPath $witness) -and !(Test-Path -LiteralPath $newFile)) 'An existing nonce witness must never be overwritten.'
$before=$env:OPENWEB_WINDOWS_CANARY_CONTRACT;$beforeNonce=$env:OPENWEB_WINDOWS_CANARY_NONCE
$env:OPENWEB_WINDOWS_CANARY_CONTRACT=$contractPath;$env:OPENWEB_WINDOWS_CANARY_NONCE=$nonce
Push-Location "$root\web"
try{& "$root\php\php.exe" (Join-Path $PSScriptRoot 'canary-fault.php') "$root\web" $nonce;Check ($LASTEXITCODE -eq 0) 'The bounded noncustomer database witness did not finish.'}
finally{Pop-Location;if($null -eq $before){Remove-Item Env:\OPENWEB_WINDOWS_CANARY_CONTRACT -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_CANARY_CONTRACT=$before};if($null -eq $beforeNonce){Remove-Item Env:\OPENWEB_WINDOWS_CANARY_NONCE -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_CANARY_NONCE=$beforeNonce}}
[IO.File]::WriteAllText($newFile,'Private disposable canary '+$nonce,[Text.UTF8Encoding]::new($false))
[xml]$xml=Export-ScheduledTask -TaskName 'OpenWebPBX-Backups'
$namespace=[Xml.XmlNamespaceManager]::new($xml.NameTable);$uri=$xml.DocumentElement.NamespaceURI
if($uri){$namespace.AddNamespace('task',$uri)}
$settings=$xml.SelectSingleNode($(if($uri){'/task:Task/task:Settings'}else{'/Task/Settings'}),$namespace)
if(!$settings){throw 'The owned task settings are unavailable.'}
$hidden=$settings.SelectSingleNode($(if($uri){'task:Hidden'}else{'Hidden'}),$namespace)
if(!$hidden){$hidden=$xml.CreateElement('Hidden',$uri);[void]$settings.AppendChild($hidden)}
$hidden.InnerText='true'
Register-ScheduledTask -TaskName 'OpenWebPBX-Backups' -Xml $xml.OuterXml -Force|Out-Null
$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$native=$scheduler.GetFolder('\').GetTask('OpenWebPBX-Backups')
$original=$native.GetSecurityDescriptor(7);$security=[Security.AccessControl.RawSecurityDescriptor]::new($original)
$ace=[Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]::None,[Security.AccessControl.AceQualifier]::AccessAllowed,0x00120089,[Security.Principal.SecurityIdentifier]::new('S-1-5-19'),$false,$null)
$security.DiscretionaryAcl.InsertAce($security.DiscretionaryAcl.Count,$ace)
$native.SetSecurityDescriptor($security.GetSddlForm(([Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group -bor [Security.AccessControl.AccessControlSections]::Access)),0x10)
Check ((Get-ScheduledTask -TaskName 'OpenWebPBX-Backups').Settings.Hidden -and $native.GetSecurityDescriptor(7) -ne $original) 'The bounded owned task witness did not take effect.'
$facts=@{schema=1;state='post_deploy_fault';nonce=$nonce;run_id=[string]$contract.run_id;baseline_version='1.0.13';target_version='1.0.14';normal_migration_completed=$true;backup_and_mail_deferred=$true;candidate_actual_assemblies=$true;original_worker_parent=$true;services_stopped=$true;new_noncustomer_table=$true;new_noncustomer_file=$true;owned_task_hidden_changed=$true;owned_task_read_acl_changed=$true;customer_rows_modified=$false;registration_sent=$false;carrier_calls=$false}
$temporary=$witness+'.new';[IO.File]::WriteAllText($temporary,($facts|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $witness
throw 'The private disposable canary reached its bounded post-migration fault. The original installed helper must roll back.'
'''

FAULT_PHP = r'''<?php
// Private new-object-only witness; never update existing customer rows.
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
$root=str_replace('\\','/',$argv[1]??'');$nonce=$argv[2]??'';
$path=str_replace('\\','/',getenv('OPENWEB_WINDOWS_CANARY_CONTRACT')?:'');
if($root!=='C:/OpenWebPBX/web'||!preg_match('/^[a-f0-9]{24}$/D',$nonce)||getenv('OPENWEB_WINDOWS_CANARY_NONCE')!==$nonce||$path!=='C:/ProgramData/OpenWebPBX/qualification113/canary-fault-contract.json')exit(2);
$contract=json_decode(file_get_contents($path),true,32,JSON_THROW_ON_ERROR);
if(($contract['authorized']??false)!==true||($contract['nonce']??null)!==$nonce||!preg_match('/^[0-9]+$/D',(string)($contract['run_id']??'')))exit(2);
require $root.'/resources/require.php';$db=$database->db;
$name='openweb_canary_'.$nonce;$lookup=$db->prepare('SELECT to_regclass(:name)');$lookup->execute(['name'=>'public.'.$name]);
if($lookup->fetchColumn()!==null)exit(2);
$db->beginTransaction();
try{
 $db->exec('CREATE TABLE public."'.$name.'"(id integer PRIMARY KEY,run_id text NOT NULL)');
 $insert=$db->prepare('INSERT INTO public."'.$name.'"(id,run_id) VALUES(1,:run)');$insert->execute(['run'=>(string)$contract['run_id']]);
 $db->commit();
}catch(Throwable $error){if($db->inTransaction())$db->rollBack();throw $error;}
echo '{"new_noncustomer_table":true,"customer_rows_modified":false}'.PHP_EOL;
'''


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def regular(path: Path, limit=MAX_FILE) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
        raise ValueError('An input must be an ordinary bounded single-link file.')


def document(path: Path) -> dict:
    regular(path, MAX_JSON)
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate provenance fields are forbidden.')
            result[key] = value
        return result
    value = json.loads(path.read_text(encoding='utf-8-sig'), object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError('A provenance document must be an object.')
    return value


def git_run(repository: Path, *args: str) -> bytes:
    result = subprocess.run(['git', *args], cwd=repository, check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return result.stdout


def original_sources(repository: Path, commit: str) -> dict[str, str]:
    if not re.fullmatch(r'[a-f0-9]{40}', commit):
        raise ValueError('Native source needs a complete immutable commit.')
    actual = git_run(repository, 'rev-parse', '--verify', commit + '^{commit}').decode().strip()
    if actual != commit:
        raise ValueError('Native source commit is not immutable.')
    names = git_run(repository, 'ls-tree', '-r', '--name-only', commit, '--',
                    'platform', 'packaging/updates/release-public.pem', 'VERSION').decode().splitlines()
    if len(names) < 40 or not OVERLAYS.issubset(names) or 'packaging/updates/release-public.pem' not in names:
        raise ValueError('The original native source inventory is incomplete.')
    result = {}
    for name in names:
        candidate.safe_relative(name)
        result[name] = hashlib.sha256(git_run(repository, 'show', commit + ':' + name)).hexdigest()
    return result


def qualified_facts(path: Path) -> dict:
    facts = document(path)
    if facts.get('schema') != 1 or facts.get('state') not in ('passed', 'partial'):
        raise ValueError('The exact base qualification is not eligible.')
    if not isinstance(facts.get('gates'), dict) or any(
            facts['gates'].get(gate) != 'passed' for gate in ESSENTIAL_GATES):
        raise ValueError('Every essential original Windows gate must have passed.')
    if not isinstance(facts.get('artifacts'), dict):
        raise ValueError('The qualification archive identity is missing.')
    checksum = facts['artifacts'].get('candidate_sha256')
    if not isinstance(checksum, str) or not HASH.fullmatch(checksum):
        raise ValueError('The qualification does not bind the complete original archive.')
    return facts


def native_inventory(root: Path) -> dict[str, str]:
    if not root.is_dir() or root.is_symlink():
        raise ValueError('Native output must be an ordinary directory.')
    actual = {}
    total = 0
    folded = set()
    for path in root.rglob('*'):
        if path.is_symlink():
            raise ValueError('Native output links are forbidden.')
        relative = path.relative_to(root).as_posix()
        candidate.safe_relative(relative)
        if relative.casefold() in folded:
            raise ValueError('Native output has Windows path collisions.')
        folded.add(relative.casefold())
        if path.is_dir():
            continue
        regular(path, MAX_FILE)
        name = path.name.casefold()
        if name in candidate.PRIVATE_NAMES or name.startswith('.env') or name.endswith(('.key', '.pfx', '.p12', '.dump', '.owpbx')):
            raise ValueError('Native output includes private runtime/signing material.')
        if name.endswith(('.pem', '.json', '.txt')):
            with path.open('rb') as stream:
                beginning = stream.read(512).lstrip()
            if re.match(rb'-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----', beginning):
                raise ValueError('Native output includes private PEM material.')
        total += path.stat().st_size
        if len(actual) >= MAX_ENTRIES or total > MAX_TOTAL:
            raise ValueError('Native output exceeds bounded inventory limits.')
        actual[relative] = digest(path)
    checksum_file = root / 'SHA256SUMS'
    regular(checksum_file, MAX_JSON)
    expected = {}
    for line in checksum_file.read_text(encoding='utf-8-sig').splitlines():
        match = re.fullmatch(r'([a-f0-9]{64})  (.+)', line)
        if not match:
            raise ValueError('Native checksum inventory is malformed.')
        name = candidate.safe_relative(match[2])
        if name in expected or name == 'SHA256SUMS':
            raise ValueError('Native checksum inventory has duplicate/self entries.')
        expected[name] = match[1]
    if expected != {name: checksum for name, checksum in actual.items() if name != 'SHA256SUMS'}:
        raise ValueError('Native checksums do not cover exact actual files.')
    return actual


def verify_native(root: Path, facts: dict, repository: Path) -> tuple[dict, dict]:
    inventory = native_inventory(root)
    inputs = document(root / 'source-inputs.json')
    verification = document(root / 'verification.json')
    if set(inputs) - SOURCE_EVIDENCE_FIELDS or set(verification) - VERIFICATION_FIELDS:
        raise ValueError('Native evidence contains fields outside public source/build provenance.')
    if inputs.get('version') != TARGET or inputs.get('source_commit') != facts.get('source_commit'):
        raise ValueError('Native target/source commit does not match the qualified base.')
    original = original_sources(repository, inputs['source_commit'])
    recorded = {}
    if not isinstance(inputs.get('source_inputs'), list):
        raise ValueError('Original native source evidence is missing.')
    for entry in inputs['source_inputs']:
        if not isinstance(entry, dict) or set(entry) != {'path', 'sha256'}:
            raise ValueError('Original native source evidence is malformed.')
        name = candidate.safe_relative(entry['path'])
        if name in recorded or not isinstance(entry['sha256'], str) or not HASH.fullmatch(entry['sha256']):
            raise ValueError('Original native source evidence is duplicated or invalid.')
        recorded[name] = entry['sha256']
    if recorded != original:
        raise ValueError('Native original source hashes differ from the immutable base tree.')
    overlays = {}
    if not isinstance(inputs.get('overlays'), list):
        raise ValueError('The two target version overlays are required.')
    for entry in inputs['overlays']:
        if not isinstance(entry, dict) or set(entry) != {'path', 'original_sha256', 'sha256'}:
            raise ValueError('A source overlay record is malformed.')
        name = candidate.safe_relative(entry['path'])
        if name in overlays or name not in OVERLAYS or entry['original_sha256'] != original[name] or entry['sha256'] != inventory.get('overlays/' + name):
            raise ValueError('A native overlay is not exactly bound to its original and target bytes.')
        overlays[name] = entry
    if set(overlays) != OVERLAYS or {name for name in inventory if name.startswith('overlays/')} != {'overlays/' + name for name in OVERLAYS}:
        raise ValueError('Only the two explicit native version overlays are permitted.')
    original_version = git_run(repository, 'show', inputs['source_commit'] + ':VERSION')
    original_props = git_run(repository, 'show', inputs['source_commit'] + ':platform/Directory.Build.props')
    if original_version.decode('utf-8-sig').strip() != BASE:
        raise ValueError('Original native source is not the qualified13 baseline.')
    if (root / 'overlays/VERSION').read_bytes() != original_version.replace(BASE.encode(), TARGET.encode()):
        raise ValueError('The release version overlay changes more than its version label.')
    version_props = ET.fromstring(original_props).findall('./PropertyGroup/Version')
    if len(version_props) != 1 or version_props[0].text != BASE:
        raise ValueError('Original assembly version evidence is ambiguous.')
    expected_props, replacements = re.subn(rb'(<Version>)1\.0\.13(</Version>)', rb'\g<1>1.0.14\g<2>', original_props)
    if replacements != 1 or (root / 'overlays/platform/Directory.Build.props').read_bytes() != expected_props:
        raise ValueError('The assembly overlay changes more than its single version label.')
    if verification.get('version') != TARGET or not isinstance(verification.get('assemblies'), list):
        raise ValueError('Actual Windows14 assembly verification evidence is missing.')
    assemblies = {}
    for entry in verification['assemblies']:
        if not isinstance(entry, dict) or set(entry) != {'path', 'assembly_version', 'sha256'}:
            raise ValueError('Windows assembly evidence is malformed.')
        name = candidate.safe_relative(entry['path'])
        if name in assemblies or name not in ASSEMBLIES or entry['assembly_version'] != TARGET + '.0' or entry['sha256'] != inventory.get(name):
            raise ValueError('Recorded actual14 assembly evidence does not bind its bytes.')
        assemblies[name] = entry
    if set(assemblies) != ASSEMBLIES:
        raise ValueError('All three real Windows assembly records are required.')
    for path in ASSEMBLIES:
        if path[:-4] + '.exe' not in inventory:
            raise ValueError('A complete native executable tree is missing.')
    return inventory, {'source_commit': inputs['source_commit'], 'original_source_files': len(original),
                       'source_inputs_sha256': inventory['source-inputs.json'],
                       'verification_sha256': inventory['verification.json'],
                       'checksum_inventory_sha256': inventory['SHA256SUMS'],
                       'overlays': [overlays[name] for name in sorted(overlays)],
                       'windows_recorded_assemblies': [assemblies[name] for name in sorted(assemblies)]}


def file_inventory(root: Path) -> dict[str, str]:
    return {path.relative_to(root).as_posix(): digest(path)
            for path in root.rglob('*') if path.is_file()}


def difference(before: dict, after: dict) -> list[dict]:
    return [{'path': name, 'change': 'added' if name not in before else 'removed' if name not in after else 'changed',
             'before_sha256': before.get(name), 'after_sha256': after.get(name)}
            for name in sorted(set(before) | set(after)) if before.get(name) != after.get(name)]


def manifest(root: Path) -> None:
    path = root / 'release-manifest.json'
    content = file_inventory(root)
    content.pop('release-manifest.json', None)
    path.write_text(json.dumps({'version': TARGET, 'files': content}, indent=2, sort_keys=True) + '\n')


def package(root: Path, destination: Path) -> dict:
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(root.rglob('*')):
            if path.is_file():
                archive.write(path, NAME + '/' + path.relative_to(root).as_posix())
    checksum = digest(destination)
    verified = candidate.verify(destination, TARGET, checksum)
    return {'archive': destination.name, 'sha256': checksum, 'bytes': destination.stat().st_size,
            'files': verified['files'], 'manifest_sha256': digest(root / 'release-manifest.json')}


def prepare(base_archive: Path, base_facts: Path, native_root: Path, output_dir: Path,
            *, repository: Path = REPOSITORY, preparation_source_commit: str | None = None,
            preparation_run_id: str | None = None) -> dict:
    """Read verified inputs and emit private unsigned normal/fault directories."""
    base_archive, base_facts, native_root, output_dir = map(Path, (base_archive, base_facts, native_root, output_dir))
    preparation_source_commit = preparation_source_commit or os.environ.get('GITHUB_SHA')
    preparation_run_id = preparation_run_id or os.environ.get('GITHUB_RUN_ID')
    if not isinstance(preparation_source_commit, str) or not re.fullmatch(r'[a-f0-9]{40}', preparation_source_commit) or not isinstance(preparation_run_id, str) or not re.fullmatch(r'[0-9]+', preparation_run_id):
        raise ValueError('Preparation needs an immutable workflow source commit and run identifier.')
    facts = qualified_facts(base_facts)
    regular(base_archive, MAX_TOTAL)
    base = candidate.verify(base_archive, BASE, facts['artifacts']['candidate_sha256'])
    native, provenance = verify_native(native_root, facts, repository)
    if output_dir.is_symlink() or output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir())):
        raise ValueError('A new or empty ordinary private output directory is required.')
    output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    output_dir.chmod(0o700)
    with tempfile.TemporaryDirectory(prefix='.canary-preparation-', dir=output_dir) as temporary:
        work = Path(temporary)
        normal = work / 'normal' / NAME
        normal.mkdir(parents=True)
        prefix = f'openwebpbx-{BASE}-windows-x64/'
        before = {}
        with zipfile.ZipFile(base_archive) as archive:
            for entry in archive.infolist():
                if entry.is_dir():
                    continue
                name = candidate.safe_relative(entry.filename[len(prefix):])
                before[name] = hashlib.sha256(archive.read(entry)).hexdigest()
                destination = normal / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, destination.open('xb') as target:
                    shutil.copyfileobj(source, target, 1024**2)
                mode = (entry.external_attr >> 16) & 0o777
                destination.chmod(mode or 0o600)
        for part in NATIVE_TREES:
            shutil.rmtree(normal / part)
            for name in sorted(native):
                if name.startswith(part + '/'):
                    target = normal / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(native_root / name, target)
                    target.chmod(0o600)
        for name in ('VERSION', 'web/VERSION'):
            data = (normal / name).read_bytes()
            if data.decode('utf-8-sig').strip() != BASE:
                raise ValueError('The original package version files differ from qualified13.')
            (normal / name).write_bytes(data.replace(BASE.encode(), TARGET.encode()))
        readme = normal / 'README.txt'
        data = readme.read_bytes()
        expected = b'OpenWeb PBX ' + BASE.encode()
        if not data.startswith(expected + b'\n') and not data.startswith(expected + b'\r\n'):
            raise ValueError('The original package README version label is ambiguous.')
        readme.write_bytes(b'OpenWeb PBX ' + TARGET.encode() + data[len(expected):])
        manifest(normal)
        after = file_inventory(normal)
        normal_diff = difference(before, after)
        allowed = {'VERSION', 'web/VERSION', 'README.txt', 'release-manifest.json'}
        if any(entry['path'] not in allowed and entry['path'].split('/')[0] not in NATIVE_TREES for entry in normal_diff):
            raise ValueError('Normal canary changes bytes outside the native/version allowlist.')
        fault = work / 'fault' / NAME
        shutil.copytree(normal, fault)
        mail = fault / 'Install-MailQueue.ps1'
        mail.write_bytes(mail.read_bytes() + FAULT_HOOK.encode())
        (fault / 'canary-fault.ps1').write_text(FAULT_PS)
        (fault / 'canary-fault.php').write_text(FAULT_PHP)
        manifest(fault)
        fault_diff = difference(after, file_inventory(fault))
        if {entry['path'] for entry in fault_diff} != FAULT_FILES | {'release-manifest.json'}:
            raise ValueError('Fault canary changed more than its three private witness files and manifest.')
        for variant in ('normal', 'fault'):
            directory = work / variant
            result = package(directory / NAME, directory / (NAME + '.zip'))
            if variant == 'normal':
                normal_result = result
            else:
                fault_result = result
        result = {'schema': 1, 'state': 'prepared_unsigned', 'private_laboratory_only': True,
                  'base_version': BASE, 'target_version': TARGET, 'source_commit': facts['source_commit'],
                  'preparation_source_commit': preparation_source_commit,
                  'preparation_run_id': preparation_run_id,
                  'base_archive_sha256': base['sha256'],
                  'base_archive': base, 'base_facts_sha256': digest(base_facts),
                  'essential_base_gates': {gate: facts['gates'][gate] for gate in ESSENTIAL_GATES},
                  'native_provenance': provenance, 'normal': normal_result, 'fault': fault_result,
                  'normal_diff': normal_diff, 'fault_diff': fault_diff,
                  'fault_contract': {'contract': 'qualification113/canary-fault-contract.json',
                                     'sentinel': 'qualification113/canary-host-sentinel.json',
                                     'witness': 'qualification113/canary-fault-witness-<nonce>.json',
                                     'nonce': '24 lowercase hexadecimal characters',
                                     'required_fields': ['schema', 'nonce', 'run_id', 'disposable',
                                                         'github_actions', 'runner_environment', 'repository',
                                                         'expected_computer', 'expected_domain', 'baseline_version',
                                                         'target_version', 'authorized'],
                                     'sentinel_fields': ['schema', 'nonce', 'run_id', 'disposable',
                                                         'github_actions', 'runner_environment', 'repository',
                                                         'expected_computer'],
                                     'worker_identity': 'SYSTEM; genuine installed13 service parent',
                                     'guards': 'private single-link protected SYSTEM/Admin contract and sentinel; exact GitHub disposable identity; installed13 restore server; migrating13 to14; stopped services; real14 assembly bytes; genuine disabled backup/mail tasks'},
                  'limitations': ['Unsigned; no private signing key or signer is included.',
                                  'No installation, HTTPS worker, native calls or rollback was executed by preparation.',
                                  'Run fault14 to complete rollback to13 before serving the higher-sequence normal14 feed; neither is a public release.']}
        for variant in ('normal', 'fault'):
            shutil.move(str(work / variant), str(output_dir / variant))
        evidence = output_dir / 'evidence'
        evidence.mkdir(mode=0o700)
        for name in ('source-inputs.json', 'verification.json', 'SHA256SUMS'):
            shutil.copyfile(native_root / name, evidence / name)
        for name in OVERLAYS:
            target = evidence / 'overlays' / name
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copyfile(native_root / 'overlays' / name, target)
        report = output_dir / 'provenance.json'
        report.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
        report.chmod(0o600)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-archive', type=Path, required=True)
    parser.add_argument('--base-facts', type=Path, required=True)
    parser.add_argument('--native-root', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GITHUB_REPOSITORY') != 'embire2/openwebpbx' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        parser.error('Run preparation only in the explicitly owned disposable GitHub workflow.')
    prepare(args.base_archive, args.base_facts, args.native_root, args.output_dir)
    print('Private unsigned14 canaries prepared from exact qualified13 bytes and Windows build evidence. No installation or publication was performed.')


if __name__ == '__main__':
    main()
