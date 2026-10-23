# Pure component checks: no network, hosted Collect, SDK build, DLL load or calling.
#Requires -Version 7.4
param([string]$Collector=(Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools/Collect-CorrespondingSource.ps1'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Collector,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Collector source does not parse.'}
foreach($name in 'SourceHash','AssertSourceRelative','AssertSourceUrl','ResolveSourceUrl','ReadSourceModuleMap','ReadSourceGitlinks','ProtectSourceReadme','ReadSourcePeImports','InspectSourceNative','AssertSourceHostedOutput','WriteSourceJson','NewSourceZip','InvokeSourceGit','AssertFirstPartySourceMaterial','AddSourceBytes','ExportSourceRepo'){
 $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($functions.Count -ne 1){throw 'One actual pure collector function is required.'};. ([scriptblock]::Create($functions[0].Extent.Text))
}
$checks=0
function Check([bool]$Pass,[string]$Label){if(!$Pass){throw ('Source component control failed: '+$Label)};$script:checks++}
function Refuse([scriptblock]$Code,[string]$Label){$bad=$false;try{$null=& $Code}catch{$bad=$true};Check $bad $Label}
$generated=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$rebuild'},$true))
Check ($generated.Count -eq 1) 'one candidate rebuild script source'
$strings=@($generated[0].Right.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true))
Check ($strings.Count -eq 1) 'literal generated rebuild script'
$generatedTokens=$null;$generatedErrors=$null;$null=[Management.Automation.Language.Parser]::ParseInput($strings[0].Value,[ref]$generatedTokens,[ref]$generatedErrors)
Check ($generatedErrors.Count -eq 0) 'generated standalone candidate rebuild script parses'

foreach($path in @('','/outside','../outside','a/../b','a//b','a/.git/config','C:/root','a\b','a/CON.txt','a/trailing.','a/file*','a/<bad>')){Refuse {AssertSourceRelative $path} ('unsafe path '+$path)}
foreach($path in @('src/main.c','.gitmodules','lib/COPYING','a-file.txt')){Check ((AssertSourceRelative $path) -ceq $path) 'ordinary source path'}
foreach($url in @('http://github.com/a/b','file:///tmp/x','ssh://github.com/a/b','https://token@github.com/a/b','https://github.com.evil/a','https://github.com/a?token=x','https://gitlab.linphone.org:8443/a','https://github.com/a#fragment')){Refuse {AssertSourceUrl $url} 'foreign URL/credentials/scheme refused'}
Check ((ResolveSourceUrl 'https://gitlab.linphone.org/BC/public/linphone-sdk.git' '../bcg729.git') -ceq 'https://gitlab.linphone.org/BC/public/bcg729.git') 'canonical relative module URL'
$modules=@(ReadSourceModuleMap "[submodule `"sample`"]`n path = external/sample`n url = https://github.com/vendor/sample.git`n")
Check ($modules.Count -eq 1 -and $modules[0].path -ceq 'external/sample') 'actual module parser'
foreach($text in @("[submodule `"a`"]`npath=x`nurl=https://github.com/a/b`npath=y", "[submodule `"a`"]`npath=../escape`nurl=https://github.com/a/b", "[submodule `"a`"]`npath=x")){Refuse {ReadSourceModuleMap $text} 'malformed module mapping'}
$links=@(ReadSourceGitlinks ("160000 commit "+('a'*40)+"`texternal/sample"));Check ($links.Count -eq 1 -and $links[0].commit -ceq ('a'*40)) 'literal commit pin'
Refuse {ReadSourceGitlinks ("160000 commit branch`texternal/sample")} 'moving ref refused'
$bytes=[Text.Encoding]::UTF8.GetBytes("fixture documentation`nuser : gitlab+deploy-token-123`npass : FICTIONAL_ONLY`n")
$after=[Text.Encoding]::UTF8.GetBytes("fixture documentation`nuser : <your registry username>`npass : <your registry token>`n")
$rule=@{before_sha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant());after_sha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($after)).ToLowerInvariant());line_count=4;user_line=2;password_line=3}
$result=ProtectSourceReadme $bytes $rule;Check ([Convert]::ToHexString($result) -ceq [Convert]::ToHexString($after)) 'exact pinned documentation-only redaction'
Refuse {ProtectSourceReadme ([Text.Encoding]::UTF8.GetBytes('changed')) $rule} 'unexpected README hash refused'
$badRule=$rule.Clone();$badRule.user_line=1;Refuse {ProtectSourceReadme $bytes $badRule} 'unexpected README shape refused'
$work=Join-Path ([IO.Path]::GetTempPath()) ('phone-source-pure-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $work
$packet=Join-Path $work 'packet';$null=New-Item -ItemType Directory -Path $packet
$allFiles=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$totalBytes=0L
$clientRoot=Split-Path (Split-Path $Collector -Parent) -Parent;$repositoryRoot=Split-Path (Split-Path $clientRoot -Parent) -Parent
$actualLock=Get-Content (Join-Path $clientRoot 'native/source-lock.json') -Raw|ConvertFrom-Json
$lock=@{bounds=@{max_single_source_bytes=1MB;max_source_files=100;max_source_bytes=10MB;max_git_seconds=30;max_owned_work_bytes=20MB};policy=@{public_material=@($actualLock.policy.public_material)}}
try{
 AddSourceBytes 'client/source.cs' ([Text.Encoding]::UTF8.GetBytes('fictional source'))
 $public=$actualLock.policy.public_material[0];$publicBytes=[IO.File]::ReadAllBytes((Join-Path $repositoryRoot $public.path))
 AddSourceBytes ('client/'+$public.path) $publicBytes
 Check (@($allFiles|Where-Object {$_.path -ceq ('client/'+$public.path) -and $_.sha256 -ceq $public.sha256}).Count -eq 1) 'exact public-only external build source allowed'
 Refuse {AssertFirstPartySourceMaterial 'client/unknown-public.pem' $publicBytes} 'unlisted public key refused'
 $changed=$publicBytes.Clone();$changed[0]=0;Refuse {AssertFirstPartySourceMaterial ('client/'+$public.path) $changed} 'changed public key refused'
 Refuse {AssertFirstPartySourceMaterial 'client/disguised.txt' ([Text.Encoding]::ASCII.GetBytes("-----BEGIN PRIVATE KEY-----`nFICTIONAL_NOT_A_KEY"))} 'private header refused even in renamed source'
 AssertFirstPartySourceMaterial 'client/clients/windows/tools/Collect-CorrespondingSource.ps1' ([IO.File]::ReadAllBytes($Collector));Check $true 'credential marker checks do not mistake source code literals for private key files'

 Refuse {AddSourceBytes 'client/.env' ([byte[]]@(1))} 'tracked first-party credentials refused'
 Refuse {AddSourceBytes 'client/key.pfx' ([byte[]]@(1))} 'private signing material refused'
 Refuse {AddSourceBytes 'vendor/pointer' ([Text.Encoding]::ASCII.GetBytes("version https://git-lfs.github.com/spec/v1`noid sha256:"+('a'*64)+"`nsize 123`n"))} 'LFS pointer cannot count as source'
 Refuse {AddSourceBytes 'CLIENT/SOURCE.CS' ([byte[]]@(1))} 'case-colliding source paths refused'
 $zip1=Join-Path $work 'a.zip';$zip2=Join-Path $work 'b.zip';NewSourceZip $packet $zip1;NewSourceZip $packet $zip2
 Check ((SourceHash $zip1) -ceq (SourceHash $zip2)) 'deterministic archive bytes on identical runtime/input'
 $doc=Join-Path $work 'proof.json';WriteSourceJson $doc @{state='pure_fixture_only'};Refuse {WriteSourceJson $doc @{state='changed'}} 'evidence overwrite refused'
 Check ((AssertSourceHostedOutput (Join-Path $work 'new-output') $work) -ceq (Join-Path $work 'new-output')) 'owned output accepted'
 Refuse {AssertSourceHostedOutput $doc $work} 'existing output refused'
 Refuse {AssertSourceHostedOutput (Join-Path (Split-Path $work -Parent) 'foreign-output') $work} 'outside output refused'
 if(!$IsWindows){$linkParent=Join-Path $work 'link-parent';$null=New-Item -ItemType SymbolicLink -Path $linkParent -Target ([IO.Path]::GetTempPath());Refuse {AssertSourceHostedOutput (Join-Path $linkParent 'output.json') $work} 'reparse output ancestry refused'}

 # Build a minimal inert PE with ordinary and delay import names, never load it.
 $peFile=Join-Path $work 'fixture.dll';[byte[]]$image=New-Object byte[] 1536
 function U16([int]$Offset,[uint16]$Value){[BitConverter]::GetBytes($Value).CopyTo($image,$Offset)}
 function U32([int]$Offset,[uint32]$Value){[BitConverter]::GetBytes($Value).CopyTo($image,$Offset)}
 $image[0]=77;$image[1]=90;U32 60 128;$image[128]=80;$image[129]=69;U16 132 34404;U16 134 1;U16 148 240;U16 150 8226
 $opt=152;U16 $opt 523;U32 ($opt+32) 4096;U32 ($opt+36) 512;U32 ($opt+56) 8192;U32 ($opt+60) 512;U16 ($opt+68) 3;U32 ($opt+108) 16
 U32 ($opt+120) 4096;U32 ($opt+124) 40;U32 ($opt+216) 4160;U32 ($opt+220) 64
 $section=$opt+240;[Text.Encoding]::ASCII.GetBytes('.rdata').CopyTo($image,$section);U32 ($section+8) 1024;U32 ($section+12) 4096;U32 ($section+16) 1024;U32 ($section+20) 512;U32 ($section+36) 1073741888
 U32 524 4352;U32 576 1;U32 580 4384
 [Text.Encoding]::ASCII.GetBytes("KERNEL32.dll`0").CopyTo($image,768);[Text.Encoding]::ASCII.GetBytes("owned-delay.dll`0").CopyTo($image,800)
 [IO.File]::WriteAllBytes($peFile,$image);$pe=ReadSourcePeImports $peFile
 Check ($pe.machine -ceq 'x64' -and !$pe.image_loaded -and !$pe.runtime_resolution_tested -and !$pe.static_linkage_proven -and $pe.imports.Count -eq 2 -and $pe.imports -ccontains 'kernel32.dll' -and $pe.imports -ccontains 'owned-delay.dll') 'actual non-loading PE ordinary/delay parser'
 U32 576 0;[IO.File]::WriteAllBytes($peFile,$image);Refuse {ReadSourcePeImports $peFile} 'unsupported VA delay descriptor refused'
 U32 576 1;U32 ($opt+124) 19;[IO.File]::WriteAllBytes($peFile,$image);Refuse {ReadSourcePeImports $peFile} 'short descriptor directory refused'
 [IO.File]::WriteAllBytes($peFile,[byte[]]@(1,2,3));Refuse {ReadSourcePeImports $peFile} 'malformed PE refused'
 # Actual local Git archive against a sterile worktree must not apply export-ignore/subst.
 $git=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source;$emptyConfig=Join-Path $work 'empty.gitconfig';[IO.File]::WriteAllText($emptyConfig,'');$sterileTree=Join-Path $work 'sterile';$null=New-Item -ItemType Directory $sterileTree
 $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($work));$repository=Join-Path $work 'fake-repository';$null=InvokeSourceGit @('init',$repository)
 [IO.File]::WriteAllText((Join-Path $repository '.gitattributes'),"required.c export-ignore`nversion.txt export-subst`n")
 [IO.File]::WriteAllText((Join-Path $repository 'required.c'),'actual fictional source')
 [IO.File]::WriteAllBytes((Join-Path $repository 'empty-source-file'),[byte[]]@())
 [IO.File]::WriteAllText((Join-Path $repository 'version.txt'),'$Format:%H$')
 $null=InvokeSourceGit @('-C',$repository,'add','.');$null=InvokeSourceGit @('-C',$repository,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','Inert source fixture')
 $commit=(InvokeSourceGit @('-C',$repository,'rev-parse','HEAD')).Trim();ExportSourceRepo $repository $commit 'vendor/fixture'
 Check ([IO.File]::ReadAllText((Join-Path $packet 'vendor/fixture/required.c')) -ceq 'actual fictional source') 'export-ignore cannot silently omit required source'
 Check ((Get-Item -LiteralPath (Join-Path $packet 'vendor/fixture/empty-source-file')).Length -eq 0) 'empty tracked source retained'
 Check ([IO.File]::ReadAllText((Join-Path $packet 'vendor/fixture/version.txt')) -ceq '$Format:%H$') 'export-subst cannot silently rewrite source'
 Check (@($allFiles|Where-Object {$_.path -ceq 'vendor/fixture/required.c' -and $_.git_mode -eq 420}).Count -eq 1) 'Git mode retained for rebuild'
 $targetFile=Join-Path $work 'link-data';[IO.File]::WriteAllText($targetFile,'../../../../foreign-target')
 $blob=(InvokeSourceGit @('-C',$repository,'hash-object','-w',$targetFile)).Trim()
 $null=InvokeSourceGit @('-C',$repository,'update-index','--add','--cacheinfo',('120000,'+$blob+',escape-link'))
 $null=InvokeSourceGit @('-C',$repository,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','Inert escaping link refusal fixture')
 $changed=(InvokeSourceGit @('-C',$repository,'rev-parse','HEAD')).Trim()
 Refuse {ExportSourceRepo $repository $changed 'vendor/escape-fixture'} 'actual Git symbolic link cannot escape source repository'
 Check (!(Test-Path -LiteralPath (Join-Path (Split-Path $work -Parent) 'foreign-target'))) 'no outside target created by source export'

}finally{Remove-Item -LiteralPath $work -Recurse -Force}
[ordered]@{schema=1;state='passed_pure_components_only';checks=$checks;actual_hosted_collection=$false;actual_sdk_source_graph_materialized=$false;binary_source_mapping_verified=$false;native_dll_loaded=$false;store_accepted=$false}|ConvertTo-Json -Compress
