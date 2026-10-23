"""QA-only one-invocation bridge; installed backup control and its inputs stay exact."""
import json
import os
from pathlib import Path
import uuid

OPERATIONS = frozenset({'plan', 'hold', 'recover-startup', 'resume-factory'})
SOURCES = frozenset({'Backup-Control.ps1', 'CallRecords.Common.ps1', 'UpgradeRecovery.Common.ps1', 'Write-PrivateState.ps1', 'File-Security.ps1', 'windows-backup-control-observer.ps1', 'external_component'})
TYPES = frozenset('System.Exception System.IO.IOException System.IO.FileNotFoundException System.IO.DirectoryNotFoundException System.UnauthorizedAccessException System.ArgumentException System.ArgumentNullException System.InvalidOperationException System.FormatException System.ComponentModel.Win32Exception System.Security.SecurityException System.DllNotFoundException System.EntryPointNotFoundException System.Management.Automation.RuntimeException System.Management.Automation.MethodInvocationException System.Management.Automation.ActionPreferenceStopException System.Management.Automation.CommandNotFoundException System.Management.Automation.ParameterBindingException System.Management.Automation.ParameterBindingValidationException System.Management.Automation.ItemNotFoundException System.Management.Automation.ProviderInvocationException Microsoft.PowerShell.Commands.ServiceCommandException other unavailable'.split())
FIELDS = frozenset('schema producer operation phase exit_code source_pins_verified invocations original_error_observed error_type inner_error_type hresult source_basename source_line caller_basename caller_line'.split())

def closed(value, operation):
    if type(value) is not dict or set(value) != FIELDS:
        raise ValueError('The control observation shape is invalid')
    if type(value['schema']) is not int or value['schema'] != 1 or value['producer'] != 'windows-backup-control-observer.ps1' or operation not in OPERATIONS or value['operation'] != operation or value['phase'] not in {'bootstrap', 'operation', 'observer_preflight'}:
        raise ValueError('The control observation producer/scope is invalid')
    for name in ('source_pins_verified', 'original_error_observed'):
        if type(value[name]) is not bool: raise ValueError('The control flags must be actual Booleans')
    for name, low, high in [('exit_code', -2147483648, 2147483647), ('hresult', 0, 4294967295), ('source_line', 0, 999999), ('caller_line', 0, 999999), ('invocations', 0, 1)]:
        if type(value[name]) is not int or not low <= value[name] <= high: raise ValueError('The control observation count is invalid')
    if value['exit_code'] == 0 or value['error_type'] not in TYPES or value['inner_error_type'] not in TYPES or value['source_basename'] not in SOURCES or value['caller_basename'] not in SOURCES:
        raise ValueError('The control failure classification is invalid')
    if value['phase'] == 'observer_preflight':
        if value['invocations'] != 0 or value['source_pins_verified'] or value['original_error_observed']: raise ValueError('A refused observer cannot claim a product invocation')
    elif value['invocations'] != 1 or not value['source_pins_verified']:
        raise ValueError('The original product invocation was not manifest-pinned')
    return dict(value)

def install(module, source_root, package_root, evidence):
    source_root, package_root, evidence = map(Path, (source_root, package_root, evidence))
    launcher = source_root / 'tests/windows-backup-control-observer.ps1'
    if launcher.is_symlink() or not launcher.is_file() or not evidence.is_dir():
        raise ValueError('The exact QA launcher/private evidence are unavailable')
    expected = str(module.CONTROL)
    native_executable = str(Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')
    original = module.run
    module.qa_backup_control_failure = None
    def observed(command, **kwargs):
        # Keep the real control() temp-request writer, native environment,
        # timeout and unlink-finally. Change only this one executable script.
        actual = list(map(str, command))
        target = len(actual) == 11 and actual[0] == native_executable and actual[1:6] == ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File'] and actual[6] == expected and actual[7] == '-Operation' and actual[9] == '-Request'
        if not target: return original(command, **kwargs)
        operation = actual[8]
        if operation not in OPERATIONS: return original(command, **kwargs)
        diagnostic = evidence / ('backup-control-'+uuid.uuid4().hex+'.json')
        redirected = actual[:6] + [str(launcher)] + actual[7:] + ['-PackageRoot', str(package_root), '-DiagnosticPath', str(diagnostic)]
        try:
            return original(redirected, **kwargs)
        except BaseException:
            try:
                if not diagnostic.is_symlink() and diagnostic.is_file() and diagnostic.stat().st_nlink == 1 and diagnostic.stat().st_size <= 8192:
                    module.qa_backup_control_failure = closed(json.loads(diagnostic.read_text(encoding='utf-8-sig')), operation)
            except Exception: pass # Preserve the actual original Python BackupError.
            raise
    module.run = observed
