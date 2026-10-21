$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'windows_runtime_import_diagnostics.ps1'
$tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Diagnostic source must parse.'}
foreach($name in 'RuntimeSnapshot','AddedKinds'){
 $nodes=@($tree.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false));if($nodes.Count -ne 1){throw 'One tested function is required.'};. ([scriptblock]::Create($nodes[0].Extent.Text))
}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
$checks=0
function Check([bool]$Value){if(!$Value){throw 'The exact-runtime diagnostic control failed.'};$script:checks++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('openweb-import-control-'+[Guid]::NewGuid().ToString('N'))
try{
 New-Item -ItemType Directory $root|Out-Null
 [IO.File]::WriteAllText((Join-Path $root 'original.py'),'unchanged')
 $before=RuntimeSnapshot $root
 Check ($before.files.Count -eq 1 -and $before.directories.Count -eq 0)
 foreach($directory in '__pycache__','new-directory'){New-Item -ItemType Directory (Join-Path $root $directory)|Out-Null}
 foreach($name in '__pycache__/original.cpython-313.pyc','bytecode.pyo','module.dll','module.pyd','new.txt'){[IO.File]::WriteAllText((Join-Path $root $name),'public fixture')}
 $after=RuntimeSnapshot $root;$kinds=AddedKinds $before $after
 Check ($kinds.Count -eq 6)
 Check ($kinds.python_bytecode -eq 2)
 Check ($kinds.dll -eq 1)
 Check ($kinds.pyd -eq 1)
 Check ($kinds.other_file -eq 1)
 Check ($kinds.python_cache_directory -eq 1)
 Check ($kinds.other_directory -eq 1)
 Check ((($kinds|ConvertTo-Json -Compress) -notmatch 'original|module|new-directory|public fixture'))
 [IO.File]::WriteAllText((Join-Path $root 'original.py'),'changed')
 $refused=$false;try{AddedKinds $before (RuntimeSnapshot $root)|Out-Null}catch{$refused=$true};Check $refused
 Remove-Item -LiteralPath (Join-Path $root 'original.py')
 $refused=$false;try{AddedKinds $before (RuntimeSnapshot $root)|Out-Null}catch{$refused=$true};Check $refused
 $text=[IO.File]::ReadAllText($source)
 foreach($pin in '12363212748','584781060','584780668','d97df9e8e579d6cad0f98fe1f675f8e3074dd540','78de3f0c159900ce937b0be52aa6378273ab03633352b0b636ecf054e1baf029','e0b76f1ad2ffcd39188620195d1e00146b85ba3fa3b6cd1414aeb4ca57d29ea1'){Check $text.Contains($pin)}
 foreach($fence in 'github-hosted','DisposableHostedRunner','RUNNER_OS','GITHUB_REPOSITORY','45000','5000','PYTHONDONTWRITEBYTECODE','isolated_no_bytecode'){Check $text.Contains($fence)}
 Check (!$text.Contains('C:\OpenWebPBX'))
 Check ($text.Contains("Artifact '39634074138' 'replay_candidate'"))
 Check ($text.Contains("if(`$count -ne 199)"))
 Check ($text.Contains("`$arguments+='-B'"))
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
Write-Host ("Exact-runtime diagnostic controls passed: "+$checks)
