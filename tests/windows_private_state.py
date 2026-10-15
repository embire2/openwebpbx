"""Exercise the real private-state writer; only owned temporary files are touched."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'packaging/windows/Write-PrivateState.ps1'
HARNESS = r'''
param([string]$Product,[string]$Destination,[string]$InputPath,[switch]$Locked)
$ErrorActionPreference='Stop'
. $Product
$value=[IO.File]::ReadAllText($InputPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
if(!$Locked){Write-OpenWebPrivateState -Path $Destination -Value $value;exit 0}
$before=[IO.File]::ReadAllBytes($Destination)
$handle=[IO.File]::Open($Destination,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$failed=$false;$code=0
try{
 try{Write-OpenWebPrivateState -Path $Destination -Value $value}
 catch{$failed=$true;$errorObject=$_.Exception;while($errorObject.InnerException){$errorObject=$errorObject.InnerException};$code=$errorObject.HResult -band 65535}
}finally{$handle.Dispose()}
$after=[IO.File]::ReadAllBytes($Destination)
[Console]::Out.Write((@{failed=$failed;native_code=$code;bytes_equal=([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String($after))}|ConvertTo-Json -Compress))
'''


class PrivateState(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        native = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        cls.powershell = os.environ.get('OPENWEB_TEST_PWSH') or (str(native) if os.name == 'nt' else shutil.which('pwsh'))
        if not cls.powershell:
            raise RuntimeError('Set OPENWEB_TEST_PWSH to run the actual private-state writer.')

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='openweb-private-state-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.script = self.work / 'control.ps1'
        self.script.write_text(HARNESS, encoding='utf-8')
        self.destination = self.work / 'private.json'

    def write(self, value, *, locked=False):
        input_path = self.work / 'input.json'
        input_path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
        arguments = [self.powershell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                     '-File', str(self.script), '-Product', str(SOURCE),
                     '-Destination', str(self.destination), '-InputPath', str(input_path)]
        if locked:
            arguments.append('-Locked')
        environment = os.environ.copy()
        if os.name == 'nt':
            environment['PSModulePath'] = (str(Path(environment['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/Modules')
                                           + ';' + str(Path(environment['ProgramFiles']) / 'WindowsPowerShell/Modules'))
        result = subprocess.run(arguments, capture_output=True, timeout=30, env=environment)
        self.assertEqual(result.returncode, 0, 'The actual private-state writer control failed.')
        self.assertEqual(result.stderr, b'')
        self.assertEqual(list(self.work.glob('*.new')), [])
        return result

    def assert_value(self, expected):
        data = self.destination.read_bytes()
        self.assertFalse(data.startswith(b'\xef\xbb\xbf'))
        self.assertEqual(json.loads(data.decode('utf-8', errors='strict')), expected)
        return data

    def test_fresh_utf8_json_nested_state(self):
        expected = {'schema': 1, 'hostname': 'caf\u00e9.example.invalid', 'nested': {'name': '\u65e5\u672c\u8a9e', 'enabled': True, 'items': [1, None, '\u00df']}}
        self.write(expected)
        self.assert_value(expected)

    def test_repeated_replacement_exact_utf8_values_and_no_temporary_residue(self):
        self.write({'schema': 1, 'obsolete': 'must disappear'})
        for index, text in enumerate(('Za\u017c\u00f3\u0142\u0107', '\u039a\u03b1\u03bb\u03b7\u03bc\u03ad\u03c1\u03b1', '\u96fb\u8a71')):
            expected = {'schema': 1, 'revision': index, 'nested': {'text': text, 'rows': [{'value': text, 'number': index}]}}
            self.write(expected)
            data = self.assert_value(expected)
            self.assertIn(text.encode('utf-8'), data)

    @unittest.skipUnless(os.name == 'nt', 'Windows DeleteShare semantics are required for deterministic replacement refusal.')
    def test_locked_destination_failure_retains_original_bytes(self):
        self.write({'schema': 1, 'nested': {'original': '\u00c4\u00f6\u00fc'}})
        before = self.destination.read_bytes()
        result = self.write({'schema': 2, 'nested': {'replacement': '\u65b0'}}, locked=True)
        observation = json.loads(result.stdout)
        self.assertEqual(observation, {'failed': True, 'native_code': 32, 'bytes_equal': True})
        self.assertEqual(self.destination.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
