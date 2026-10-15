#!/usr/bin/env python3
"""Exercise actual codec import/launcher and strict payload observation, without compilation."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--powershell', default='pwsh')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


def inventory(directory):
    return {p.relative_to(directory).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob('*') if p.is_file()}


tree = ast.parse((root / 'packaging/codecs/bcg729/build-windows-local.py').read_text())
build = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'build')
index = next(i for i, n in enumerate(build.body) if isinstance(n, ast.Assign)
             and ast.unparse(n).startswith('spec = importlib.util.spec_from_file_location('))
actual_import = build.body[index:index + 3]
check(ast.unparse(actual_import[0]) == "spec = importlib.util.spec_from_file_location('core_exports', exports_helper)")
check(ast.unparse(actual_import[1]) == 'exports = importlib.util.module_from_spec(spec)')
check(ast.unparse(actual_import[2]) == 'spec.loader.exec_module(exports)')
# Run only the exact import block: no compiler/network/admin/platform bypass.
fragment = ('import importlib.util, sys\nfrom pathlib import Path\n'
            "exports_helper=Path(sys.argv[sys.argv.index('--core-export-helper')+1])\n"
            + '\n'.join(ast.unparse(n) for n in actual_import) + '\n'
            + "assert callable(exports.definition)\nassert sys.flags.isolated == 1\n")
with tempfile.TemporaryDirectory(prefix='openweb-codec-payload-') as temporary:
    work = Path(temporary)
    inputs = []
    for mode in ('old', 'fixed'):
        package = work / mode / "release package's path"
        recipe = package / 'codecs/bcg729'
        recipe.mkdir(parents=True)
        shutil.copyfile(root / 'packaging/freeswitch/core-exports.py', recipe / 'core-exports.py')
        (recipe / 'build-windows-local.py').write_text(fragment)
        before = inventory(package)
        (package / 'release-manifest.json').write_text(json.dumps({'files': before}))
        inputs.append({'mode': mode, 'package': str(package), 'python': sys.executable,
                       'private': str(work / f'{mode}-private.json'), 'before': before})
    data = work / 'input.json'
    data.write_text(json.dumps(inputs))
    script = work / 'controls.ps1'
    script.write_text(r'''
param([string]$SourceRoot,[string]$InputPath)
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$installer=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Install-LocalCodec.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual codec installer must parse.'}
$commands=@($installer.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.Extent.Text.StartsWith('& $python ') -and $node.Extent.Text.Contains('build-windows-local.py')},$true))
if($commands.Count -ne 1 -or !$commands[0].Extent.Text.StartsWith('& $python -I -B ')){throw 'The exact isolated no-bytecode launcher is required.'}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual upgrade hook must parse.'}
foreach($name in 'WriteJson','PayloadInventory'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'The actual inventory functions must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
$results=@()
foreach($entry in (Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json)){
 $PackageRoot=$entry.package;$recipeRoot=Join-Path $PackageRoot 'codecs/bcg729';$python=$entry.python
 $EngineRoot=Join-Path $PackageRoot 'unused-engine';$StateRoot=Split-Path $PackageRoot -Parent;$work=$StateRoot
 $recipe=[pscustomobject]@{source_manifest_sha256='unused';core_sha256='unused';apr_sha256='unused'}
 $command=$commands[0].Extent.Text
 # Adapt only path separators for this Linux-hosted source control; the
 # actual interpreter flags, spaced/quoted paths and argument list remain.
 if([IO.Path]::DirectorySeparatorChar -ne '\'){$command=$command.Replace('\','/')}
 if($entry.mode -ceq 'old'){$command=$command.Replace('& $python -I -B ','& $python -I ')}
 # Isolated Python ignores this global setting. The explicit -B is necessary.
 $env:PYTHONDONTWRITEBYTECODE='1'
 Invoke-Expression $command
 if($LASTEXITCODE){throw 'The actual source import failed.'}
 $facts=PayloadInventory $PackageRoot $entry.private
 $results+=@{mode=$entry.mode;facts=$facts}
}
[IO.File]::WriteAllText((Join-Path (Split-Path $InputPath -Parent) 'results.json'),($results|ConvertTo-Json -Depth 8))
''')
    execution = subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-File', str(script),
                                '-SourceRoot', str(root), '-InputPath', str(data)], capture_output=True, text=True)
    assert execution.returncode == 0, execution.stderr
    results = json.loads((work / 'results.json').read_text(encoding='utf-8-sig'))
    for entry, result in zip(inputs, results):
        package = Path(entry['package'])
        after = inventory(package)
        before = entry['before']
        check(all(after[name] == digest for name, digest in before.items()))
        facts = result['facts']
        private = json.loads(Path(entry['private']).read_text(encoding='utf-8-sig'))
        check(facts['payload_inventory_observed'] is True and facts['payload_reparse_count'] == 0)
        if entry['mode'] == 'old':
            extra = [name for name in after if name not in before and name != 'release-manifest.json']
            check(len(extra) == 1 and extra[0].startswith('codecs/bcg729/__pycache__/core-exports.')
                  and extra[0].endswith('.pyc'))
            check(facts['payload_extra_count'] == 1 and facts['payload_extra_categories'] == ['codec_helper_cache'])
            check(facts['payload_extra_extensions'] == ['.pyc'])
            check(private['extra_relative_paths'] == extra)
        else:
            check(set(after) == set(before) | {'release-manifest.json'})
            check(facts['payload_extra_count'] == 0 and facts['payload_extra_categories'] == [])
            check(private['extra_relative_paths'] == [])
        check(not any('relative_paths' in name for name in facts))
    # Unknown extras are observed, never deleted/accepted. Only fixed labels
    # cross the boundary; their secret-shaped path remains private.
    package = Path(inputs[1]['package'])
    foreign = package / 'private-sentinel-do-not-publish.bin'
    foreign.write_bytes(b'private-sentinel-do-not-publish')
    control = work / 'unknown.ps1'
    control.write_text(r'''
param([string]$SourceRoot,[string]$PackageRoot,[string]$PrivatePath)
$ErrorActionPreference='Stop';$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$t,[ref]$e)
foreach($name in 'WriteJson','PayloadInventory'){$n=@($ast.FindAll({param($x)$x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $name},$true));Invoke-Expression $n[0].Extent.Text}
PayloadInventory $PackageRoot $PrivatePath|ConvertTo-Json -Depth 5
''')
    observed = subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-File', str(control),
                               '-SourceRoot', str(root), '-PackageRoot', str(package),
                               '-PrivatePath', str(work / 'unknown-private.json')], check=True, capture_output=True, text=True)
    facts = json.loads(observed.stdout)
    check(facts['payload_inventory_observed'] is True and facts['payload_extra_count'] == 1)
    check(facts['payload_extra_categories'] == ['root_other'] and facts['payload_extra_extensions'] == ['other'])
    check(facts['payload_extra_known_basenames'] == [] and 'private-sentinel' not in observed.stdout)
    check(foreign.read_bytes() == b'private-sentinel-do-not-publish')
    check(json.loads((work / 'unknown-private.json').read_text(encoding='utf-8-sig'))['extra_relative_paths'] == [foreign.name])
    product = (root / 'packaging/windows/Upgrade-OpenWebPBX.ps1').read_text()
    check("if (!$hashes.ContainsKey($relative)) { throw 'The extracted release contains files missing from its manifest.' }" in product)
print(f'PASS {checks} actual codec-import/launcher/payload-immutability controls; no compilation or PBX accessed')
