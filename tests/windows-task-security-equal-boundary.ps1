# QA-only AST admission. Generic equality must never normalize task security.
function Test-GenericEqualTaskSecurityBoundary($Node,[bool]$AllowTaskFailureObservation=$false){
 if($Node -isnot [Management.Automation.Language.FunctionDefinitionAst] -or $Node.Name -cne 'Equal'){return $false}
 if(!$AllowTaskFailureObservation){return ($Node.Extent.Text -notmatch 'TaskSecurity|TaskSnapshot|security')}
 $parameters=@($Node.Parameters|ForEach-Object {$_.Extent.Text})
 if($parameters.Count -ne 3 -or $parameters[0] -cne '$Before' -or $parameters[1] -cne '$After' -or $parameters[2] -cne '[string]$Label'){return $false}
 if($Node.Body.BeginBlock -or $Node.Body.ProcessBlock -or $Node.Body.DynamicParamBlock -or $Node.Body.ParamBlock -or $Node.Body.EndBlock.Traps){return $false}
 # The signed harness gained separately reviewed protected-file-only lock-ACL
 # comparison and bounded read-only failure observers after this original AST
 # guard was written. Admit only that complete unchanged body (LF or CRLF). Unknown calls,
 # branch labels, argument/order changes or consumed failures change this pin
 # and still refuse; task comparisons themselves retain their raw maps.
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$current=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Node.Extent.Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($current -cin @('5be41a811b9774df0ef01aa6ebd3bef35a9b9cf94d9dcd1dbdae265ef1b148ba','a318b9af12f7f8fbb021c9c396019ff29798ab239ebd8df30264942439f98348')){return $true}
 $statements=@($Node.Body.EndBlock.Statements)
 $before=@('$script:qualificationComparisonFailure=$null',"`$a=Join-Path `$work (`$Label+'-before.json')","`$b=Join-Path `$work (`$Label+'-after.json')",'WriteJson $a $Before','WriteJson $b $After')
 if($statements.Count -ne 6){return $false}
 for($index=0;$index -lt $before.Count;$index++){if($statements[$index].Extent.Text -cne $before[$index]){return $false}}
 $strict=$statements[5]
 if($strict -isnot [Management.Automation.Language.TryStatementAst] -or $strict.Finally -or $strict.CatchClauses.Count -ne 1 -or $strict.CatchClauses[0].CatchTypes.Count -ne 0 -or $strict.Body.Statements.Count -ne 1){return $false}
 $command=$strict.Body.Statements[0]
 $expected='CheckedProcess "$root\backup-runtime\python.exe" @(''-I'',''-B'',(Join-Path $PSScriptRoot ''windows-compare-json.py''),$a,$b) (''compare-''+$Label)'
 if($command -isnot [Management.Automation.Language.PipelineAst] -or $command.Extent.Text -cne $expected){return $false}
 $caught=@($strict.CatchClauses[0].Body.Statements)
 if($caught.Count -ne 6 -or $caught[2].Extent.Text -cne '$script:qualificationComparisonFailure=@{label=$Label;report=$report}' -or $caught[5] -isnot [Management.Automation.Language.ThrowStatementAst] -or $caught[5].Extent.Text -cne 'throw'){return $false}
 $observer=$caught[3]
 $expectedObserver='if($Label -ceq ''normal-task-contract-security'' -and $report.comparison_result -ceq ''different''){try{$task=QualificationTaskDifference $Before $After;if($task){$script:qualificationComparisonFailure.task=$task}}catch{}}'
 if($observer -isnot [Management.Automation.Language.IfStatementAst] -or $observer.Extent.Text -cne $expectedObserver -or $observer.Parent -ne $strict.CatchClauses[0].Body){return $false}
 # Only this exact direct child of the original comparator's catch is admitted.
 # Its read-only observer cannot run on success or consume the primary failure.
 $transfers=@($Node.FindAll({param($n)$n -is [Management.Automation.Language.ThrowStatementAst] -or $n -is [Management.Automation.Language.ReturnStatementAst] -or $n -is [Management.Automation.Language.ExitStatementAst] -or $n -is [Management.Automation.Language.BreakStatementAst] -or $n -is [Management.Automation.Language.ContinueStatementAst]},$true))
 if($transfers.Count -ne 1 -or $transfers[0] -ne $caught[5]){return $false}
 $start=$observer.Extent.StartOffset-$Node.Extent.StartOffset;$length=$observer.Extent.EndOffset-$observer.Extent.StartOffset
 $withoutObserver=$Node.Extent.Text.Remove($start,$length)
 return ($withoutObserver -notmatch 'TaskSecurity|TaskSnapshot|security')
}
