#!/usr/bin/env python3
"""Exercise the exact fault XML statements and PHP child-exit branch without a PBX."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--powershell', default='pwsh')
parser.add_argument('--php', default='php')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = (root / 'tests/windows-upgrade-acceptance.ps1').read_text()
php = source.split(" $fault=@'\n", 1)[1].split("\n'@", 1)[0]
fragment = php[php.index("passthru("):]
assert fragment.count("passthru(") == 1 and fragment.endswith("exit(73);")
assert "if($code!==0)exit(74);" in fragment
checks = 2

with tempfile.TemporaryDirectory(prefix="openweb task's fault ") as temporary:
    work = Path(temporary)
    control = work / 'control.ps1'
    extracted = work / 'fault.php.txt'
    control.write_text(r'''
param([string]$SourceRoot,[string]$Output)
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Task XML control failed at line '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:checks++}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq 'faultPs'},$true))
Check ($nodes.Count -eq 1)
$literals=@($nodes[0].Right.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuotedHereString'},$true))
Check ($literals.Count -eq 1);$fault=$literals[0].Value
$statements=[Management.Automation.Language.Parser]::ParseInput($fault,[ref]$tokens,[ref]$errors).EndBlock.Statements
Check ($errors.Count -eq 0)
$start=-1;$end=-1
for($i=0;$i -lt $statements.Count;$i++){
 if($statements[$i].Extent.Text.StartsWith('[xml]$task=Export-ScheduledTask')){$start=$i}
 if($start -ge 0 -and $statements[$i].Extent.Text.StartsWith('Register-ScheduledTask -TaskName OpenWebPBX-Backups')){$end=$i;break}
}
Check ($start -ge 0 -and $end -gt $start)
$actual=(@($statements[$start..$end]|ForEach-Object {$_.Extent.Text}) -join [Environment]::NewLine)
# Only these two source commands are substituted. No native task is accessed.
function Export-ScheduledTask([string]$TaskName){Check ($TaskName -ceq 'OpenWebPBX-Backups');return $script:inputXml}
function Register-ScheduledTask([string]$TaskName,[string]$Xml,[switch]$Force){Check ($TaskName -ceq 'OpenWebPBX-Backups' -and $Force);$script:captured=$Xml}
$uri='http://schemas.microsoft.com/windows/2004/02/mit/task'
$cases=@(
 '<Task><RegistrationInfo><Description>preserve</Description></RegistrationInfo><Settings><!-- keep --><Hidden>false</Hidden><Enabled>false</Enabled></Settings><Actions Context="Author"><Exec><Command>fictional-owned-only</Command></Exec></Actions></Task>',
 '<Task><Settings><!-- keep --><Enabled>true</Enabled><ExecutionTimeLimit>PT1H</ExecutionTimeLimit></Settings><Actions><Exec><Command>fictional-owned-only</Command></Exec></Actions></Task>',
 ('<Task xmlns="'+$uri+'"><Settings><!-- keep --><Hidden>false</Hidden><Enabled>false</Enabled></Settings><Actions><Exec><Command>fictional-owned-only</Command></Exec></Actions></Task>'),
 ('<Task xmlns="'+$uri+'"><Settings><!-- keep --><Enabled>true</Enabled></Settings><Actions><Exec><Command>fictional-owned-only</Command></Exec></Actions></Task>'),
 ('<t:Task xmlns:t="'+$uri+'"><t:Settings><!-- keep --><t:Enabled>true</t:Enabled></t:Settings><t:Actions><t:Exec><t:Command>fictional-owned-only</t:Command></t:Exec></t:Actions></t:Task>')
)
foreach($input in $cases){
 $script:inputXml=$input;$script:captured=$null
 [xml]$before=$input
 $oldHidden=$before.SelectSingleNode('/*[local-name()="Task"]/*[local-name()="Settings"]/*[local-name()="Hidden"]')
 if($oldHidden){[void]$oldHidden.ParentNode.RemoveChild($oldHidden)}
 $expected=$before.OuterXml
 Invoke-Expression $actual
 Check ($null -ne $captured)
 [xml]$after=$captured
 $hiddenNodes=$after.SelectNodes('/*[local-name()="Task"]/*[local-name()="Settings"]/*[local-name()="Hidden"]')
 Check ($hiddenNodes.Count -eq 1 -and $hiddenNodes[0].InnerText -ceq 'true' -and $hiddenNodes[0].NamespaceURI -ceq $after.DocumentElement.NamespaceURI)
 [void]$hiddenNodes[0].ParentNode.RemoveChild($hiddenNodes[0])
 Check ($after.OuterXml -ceq $expected)
}
$script:inputXml=$cases[1];$script:captured=$null
$oldFailed=$false
try{[xml]$task=Export-ScheduledTask -TaskName OpenWebPBX-Backups;$task.Task.Settings.Hidden='true'}catch{$oldFailed=$_.Exception -is [Management.Automation.SetValueInvocationException]}
Check ($oldFailed -and $null -eq $captured)
$script:inputXml='<Task><Actions/></Task>';$script:captured=$null;$refused=$false
try{Invoke-Expression $actual}catch{$refused=$_.Exception.Message -ceq 'The owned task settings are unavailable.'}
Check ($refused -and $null -eq $captured)
$phpNodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq 'fault'},$true))
Check ($phpNodes.Count -eq 1)
$literals=@($phpNodes[0].Right.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuotedHereString'},$true))
Check ($literals.Count -eq 1)
[IO.File]::WriteAllText($Output,$literals[0].Value,[Text.UTF8Encoding]::new($false))
Write-Output ('PASS '+$checks+' actual task-fault XML namespace/preservation/refusal controls')
''')
    result = subprocess.run(
        [args.powershell, '-NoProfile', '-NonInteractive', '-File', str(control),
         '-SourceRoot', str(root), '-Output', str(extracted)],
        capture_output=True, text=True, check=True)
    print(result.stdout.strip())
    assert extracted.read_text() == php
    checks += 1
    child = work / 'owned-child.php'
    child.write_text("<?php exit((int)getenv('OW_TASK_FAULT_CHILD_EXIT'));")
    # Execute the exact PHP branch. Namespace only the external launcher, so
    # its reported code comes from a real isolated PHP child, not a PBX/PowerShell.
    wrapper = '''<?php
namespace OpenWebTaskFaultControls;
function passthru($command,&$code) {
 if(!str_starts_with($command,'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '))throw new \\RuntimeException('Unexpected source child command');
 \\passthru(\\escapeshellarg(PHP_BINARY).' '.\\escapeshellarg(__DIR__.'/owned-child.php'),$code);
}
'''
    for variant in ['current', 'old']:
        body = fragment if variant == 'current' else fragment.replace("if($code!==0)exit(74);\n", '')
        script = work / (variant + '.php')
        script.write_text(wrapper + body)
        for code in [0, 7, 1]:
            process = subprocess.run(
                [args.php, '-n', str(script)],
                env=os.environ | {'OW_TASK_FAULT_CHILD_EXIT': str(code)}, capture_output=True)
            expected = 73 if variant == 'old' or code == 0 else 74
            assert process.returncode == expected and process.stdout == b'' and process.stderr == b''
            checks += 1
print(f'PASS {checks} actual PHP source/real-child failure-refusal controls; no task or PBX accessed')
