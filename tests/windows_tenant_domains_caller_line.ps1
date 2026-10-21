# Exercise the actual assertion caller and bounded projection without Windows/IIS.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-tenant-domains-native.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The native fixture must parse.'}
foreach($name in 'Check','CheckSourceLine'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'The actual assertion and projector must be unique.'}
 Invoke-Expression $nodes[0].Extent.Text
}
$checks=[Collections.Generic.List[string]]::new();$controls=0
function Assert([bool]$Value){if(!$Value){throw 'The bounded assertion caller control failed.'};$script:controls++}
$own=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)
$calls=@($own.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Check' -and $node.CommandElements.Count -eq 3 -and $node.CommandElements[2].Value -ceq 'PRIVATE_NEVER_PUBLISH'},$true))
Assert ($calls.Count -eq 1)
Check $true 'Owned successful assertion'
Assert ($checks.Count -eq 1)
$failure=$null
try{
 Check $false 'PRIVATE_NEVER_PUBLISH'
}catch{$failure=$_}
Assert ($null -ne $failure)
Assert ($failure.Exception.Data['OpenWebTenantCheckSourceLine'] -is [int])
Assert ((CheckSourceLine $failure) -eq $calls[0].Extent.StartLineNumber)
Assert ((CheckSourceLine $failure) -is [int])
Assert (([string](CheckSourceLine $failure)) -cnotmatch 'PRIVATE_NEVER_PUBLISH')
foreach($bad in $null,$true,'123',1.5,-1,0,100000,@(123)){
 $exception=[InvalidOperationException]::new('PRIVATE_NEVER_PUBLISH');$exception.Data['OpenWebTenantCheckSourceLine']=$bad
 $record=[pscustomobject]@{Exception=$exception;InvocationInfo=[pscustomobject]@{ScriptLineNumber=321}}
 Assert ((CheckSourceLine $record) -eq 321)
}
$inner=[InvalidOperationException]::new('PRIVATE_NEVER_PUBLISH');$inner.Data['OpenWebTenantCheckSourceLine']=456
$outer=[InvalidOperationException]::new('PRIVATE_NEVER_PUBLISH',$inner)
$record=[pscustomobject]@{Exception=$outer;InvocationInfo=[pscustomobject]@{ScriptLineNumber=321}}
Assert ((CheckSourceLine $record) -eq 456)
$outer.Data['OpenWebTenantCheckSourceLine']='PRIVATE_NEVER_PUBLISH'
Assert ((CheckSourceLine $record) -eq 456)
Write-Output ('PASS '+$controls+' actual assertion caller-line and privacy controls; no PBX invoked')
