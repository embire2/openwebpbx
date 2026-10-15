#!/usr/bin/env python3
"""Real isolated fixture imports in temporary package copies; no PBX access."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class FixtureImportControls(unittest.TestCase):
    def test_actual_fixture_imports_preserve_package_only_with_explicit_no_bytecode(self):
        crypto = Path(importlib.util.find_spec('cryptography').origin).parent
        code = r'''
import runpy,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
if sys.argv[3]=='updater':
    functions=runpy.run_path(sys.argv[2])
    try:functions['verify_packets']({}, {}, {}, {}, 'unused-public-key')
    except ValueError:pass
else:
    functions=runpy.run_path(sys.argv[2])
    functions['load_module']('owned_restore_backup_import',Path(sys.argv[1])/'backups.py')
import cryptography
assert Path(cryptography.__file__).parent==Path(sys.argv[1])/'cryptography'
'''
        with tempfile.TemporaryDirectory(prefix='openweb-qualification-import-') as temporary:
            work = Path(temporary)
            shutil.copytree(crypto, work / 'cryptography', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            shutil.copyfile(HERE.parent / 'packaging/windows/backups.py', work / 'backups.py')
            environment = os.environ.copy()
            environment['PYTHONDONTWRITEBYTECODE'] = '1'
            environment['ProgramData'] = str(work / 'unused-program-data')
            for action, source in (('updater', 'windows-updater-fixture.py'), ('restore', 'windows-restore-qualification.py')):
                for flags in (('-I',), ('-I', '-B')):
                    with self.subTest(action=action, flags=flags):
                        for cache in list(work.rglob('__pycache__')):
                            shutil.rmtree(cache)
                        before = {str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in work.rglob('*') if p.is_file()}
                        child = subprocess.run([sys.executable, *flags, '-c', code, str(work), str(HERE / source), action],
                                               env=environment, capture_output=True, timeout=30)
                        self.assertEqual(child.returncode, 0, child.stderr.decode())
                        after = {str(p.relative_to(work)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in work.rglob('*') if p.is_file()}
                        self.assertEqual(before, {name: after[name] for name in before})
                        if '-B' in flags:
                            self.assertEqual(after, before)
                        else:
                            added = after.keys() - before.keys()
                            self.assertTrue(added)
                            self.assertTrue(all(name.endswith('.pyc') for name in added))
                            if action == 'restore':
                                self.assertTrue(any(name.startswith('__pycache__/backups.') for name in added))

    def test_actual_powershell_launchers_set_no_bytecode_before_fixture(self):
        selected = os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh')
        if not selected and os.name == 'nt':
            selected = shutil.which('powershell.exe')
        pwsh = Path(shutil.which(selected) or selected) if selected else None
        if pwsh is None or not pwsh.is_file():
            self.skipTest('PowerShell unavailable; set OPENWEB_TEST_PWSH or provide pwsh/powershell.exe.')
        script = r'''
param([string]$SourceRoot,[string]$FunctionPath)
$ErrorActionPreference='Stop';$root='C:\Fictional';$python='fictional-python';$inputFile='fictional-input';$source='fictional-source';$work='unused';$facts=@{}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function CheckedProcess([string]$Executable,[string[]]$Arguments,[string]$Label,[string]$WorkingDirectory,[int]$Timeout){
 if($Arguments.Count -ne 7 -or $Arguments[0] -cne '-I' -or $Arguments[1] -cne '-B' -or $Arguments[3] -cne '--input' -or $Arguments[5] -cne '--action'){throw 'Fixture argv changed.'}
 $script:launches++
}
$bodies=@()
foreach($pair in @(@{file='windows-updater-qualification.ps1';name='Python'},@{file='windows-restore-qualification.ps1';name='NativeFixture'})){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('tests/'+$pair.file)),[ref]$tokens,[ref]$errors)
 if(@($errors).Count){throw 'Caller source does not parse.'}
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $pair.name},$true))
 if($nodes.Count -ne 1){throw 'Unique exact fixture launcher required.'};$bodies+=$nodes[0].Extent.Text
}
[IO.File]::WriteAllText($FunctionPath,($bodies -join "`n"));. $FunctionPath
$script:launches=0;Python 'prepare-pki';NativeFixture 'setup'
if($launches -ne 2){throw 'Both actual wrappers must execute.'}
$text=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'))
foreach($action in 'validate','serve'){
 $pattern="@('-I','-B',(Join-Path `$PSScriptRoot 'windows-updater-fixture.py'),'--input',`$inputFile,'--action','"+$action+"')"
 if(!$text.Contains($pattern)){throw 'The extracted package fixture must explicitly disable bytecode.'}
}
'Four actual fixture launch paths checked.'
'''
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'launch-checks.ps1'
            path.write_text(script)
            child = subprocess.run([str(pwsh), '-NoProfile', '-File', str(path), str(HERE.parent), str(Path(temporary) / 'functions.ps1')],
                                   capture_output=True, text=True, timeout=30)
            self.assertEqual(child.returncode, 0, child.stdout + child.stderr)
            self.assertIn('Four actual fixture launch paths checked.', child.stdout)


if __name__ == '__main__':
    unittest.main()
