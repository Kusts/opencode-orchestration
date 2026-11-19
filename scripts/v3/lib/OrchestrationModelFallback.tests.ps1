[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelFallback.ps1')
$passed=0;$failed=0
function Assert-MF { param([bool]$Ok,[string]$Name) if($Ok){$script:passed++}else{$script:failed++;Write-Host "FAIL $Name"} }
function New-NoStartEvidence { param([string]$Task,[string]$Attempt,[string]$Model,[string]$Source='dispatcher') @{source=$Source;stage='pre_dispatch';task_id=$Task;attempt_id=$Attempt;requested_model=$Model;session_id='';execution_started=$false;assistant_messages=0;tool_calls=0} }
$role='coder';$task='fallback-test';$policy=Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json'
if(-not (Test-Path $policy)){$policy=''}
$attemptedCsv=ConvertFrom-OrchestrationAttemptedModels @('openai/gpt-6.1-terra,  openai/gpt-6.1-sol')
Assert-MF ($attemptedCsv.Count -eq 2 -and $attemptedCsv[0] -ceq 'openai/gpt-6.1-terra' -and $attemptedCsv[1] -ceq 'openai/gpt-6.1-sol' -and -not ('openai/gpt-6.1-sol' -notin $attemptedCsv)) 'CSV attempted models trim prevents second candidate reauthorization'
$attemptedArray=@('model-a','model-b');$preservedArray=ConvertFrom-OrchestrationAttemptedModels $attemptedArray
Assert-MF ($preservedArray.Count -eq 2 -and $preservedArray[1] -ceq 'model-b') 'attempted models array remains unchanged'
$tool='{"error":{"type":"tool.execution","message":"Model openai/does-not-exist is not available."}}'
$cases=@(
 @{name='native model unavailable';fail=$tool;model='openai/does-not-exist'},
 @{name='429';fail='{"status":429,"message":"rate limit"}';model='opencode-go/deepseek-v4.1-flash'},
 @{name='resource exhausted';fail='{"code":"resource_exhausted","message":"quota"}';model='opencode-go/deepseek-v4.1-flash'},
 @{name='503';fail='{"status":503,"message":"unavailable"}';model='opencode-go/deepseek-v4.1-flash'}
)
foreach($c in $cases){
 $ev=New-NoStartEvidence $task ('attempt-'+$c.model) $c.model 'provider'
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -Risk low -Complexity simple -FailedModel $c.model -AttemptedModels @($c.model) -Failure $c.fail -AttemptEvidence $ev -AttemptId $ev.attempt_id -PolicyPath $policy
 Assert-MF ($d.Status -in @('FALLBACK_AUTHORIZED','EXHAUSTED')) "$($c.name) classified $($d.Classification)"
 Assert-MF ($null -eq $d.NextModel -or ($d.NextModel -cne $c.model -and $d.NextModel -notin @($c.model))) "$($c.name) no repeated model"
}
$withoutEvidence=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -FailedModel 'opencode-go/deepseek-v4.1-flash' -Failure '{"status":429,"message":"rate limit"}' -PolicyPath $policy
Assert-MF ($withoutEvidence.Classification -eq 'RATE_LIMIT' -and $withoutEvidence.Status -eq 'HOLD_NO_START_PROOF_UNVERIFIED' -and $null -eq $withoutEvidence.NextModel) 'provider without evidence holds'
foreach($item in @(@{s=401;c='AUTH_OR_PERMISSION_ERROR'},@{s=403;c='AUTH_OR_PERMISSION_ERROR'})){
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -FailedModel 'opencode-go/deepseek-v4.1-flash' -Failure (@{status=$item.s}|ConvertTo-Json -Compress)
 Assert-MF ($d.Status -eq 'HOLD_TERMINAL' -and $null -eq $d.NextModel) "auth $($item.s) terminal"
}
foreach($f in @('{"code":"invalid_request","message":"context too large"}','{"code":"timeout"}')){
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -FailedModel 'opencode-go/deepseek-v4.1-flash' -Failure $f
 Assert-MF ($d.Status -eq 'HOLD_TERMINAL' -and -not $d.NoStartProof) 'invalid/ambiguous terminal'
}
$sessionFailure='{"sessionID":"ses_x","error":{"type":"tool.execution","message":"model not available"}}'
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -FailedModel 'opencode-go/deepseek-v4.1-flash' -Failure $sessionFailure
Assert-MF (-not $d.NoStartProof -and $d.Status -eq 'HOLD_AMBIGUOUS_EXECUTION') 'tool session blocks proof'
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -FailedModel 'openai/does-not-exist' -Failure $tool -SessionId 'ses_child-error'
Assert-MF ($d.Status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and -not $d.NoStartProof -and $null -eq $d.NextModel -and $d.SessionId -eq 'ses_child-error') 'explicit child session prevents duplicate'
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -FailedModel 'openai/does-not-exist' -Failure '{"code":"timeout"}'
Assert-MF ($d.Status -eq 'HOLD_TERMINAL' -and $d.Classification -eq 'EXECUTION_UNKNOWN' -and $null -eq $d.NextModel) 'timeout without session holds'
$chain=Get-OrchestrationModelFallbackChain -AttemptRole $role -TaskId $task -PolicyPath $policy
Assert-MF ($chain.Count -gt 0) 'auditable chain'
$already=@($chain);$last=[string]$chain[-1]
$exhaustEv=New-NoStartEvidence $task 'attempt-exhausted' $last
$exhausted=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -FailedModel $last -AttemptedModels $already -Failure $tool -AttemptEvidence $exhaustEv -AttemptId 'attempt-exhausted' -PolicyPath $policy
Assert-MF ($exhausted.Status -eq 'EXHAUSTED' -or $exhausted.Status -eq 'HOLD_TERMINAL') 'chain exhaustion readable'
Assert-MF ((ConvertFrom-OrchestrationToolError '{"error":{"type":"tool.execution","message":"Model not available"}}').Classification -eq (ConvertFrom-OrchestrationProviderFailure @{code='model_unavailable'}).Classification) 'cross-provider semantic equivalence'

# Acceptance cases use the repository policy; do not replace it with test routing.
$ev=New-NoStartEvidence $task 'attempt-explorer' 'opencode-go/hy4-flash-free' 'provider'
$providerCases=@(
 @{name='explorer 429';failure='{"status":429,"message":"rate limit"}';class='RATE_LIMIT';model='opencode-go/hy4-flash-free';next='opencode/mimo-v2.6-flash-free'},
 @{name='explorer quota';failure='{"code":"resource_exhausted","message":"quota"}';class='QUOTA_EXCEEDED';model='opencode-go/hy4-flash-free';next='opencode/mimo-v2.6-flash-free'},
 @{name='explorer 503';failure='{"status":503,"message":"unavailable"}';class='PROVIDER_UNAVAILABLE';model='opencode-go/hy4-flash-free';next='opencode/mimo-v2.6-flash-free'}
)
foreach($c in $providerCases){
 $ev=New-NoStartEvidence $task 'attempt-explorer' 'opencode-go/hy4-flash-free' 'provider'
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -Risk low -FailedModel $c.model -Failure $c.failure -AttemptEvidence $ev -AttemptId 'attempt-explorer' -PolicyPath $policy
 Assert-MF ($d.Classification -eq $c.class) "$($c.name) exact classification"
 Assert-MF ($d.Status -eq 'FALLBACK_AUTHORIZED') "$($c.name) exact status"
 Assert-MF ($d.NextModel -eq $c.next) "$($c.name) exact next"
 Assert-MF ($d.NoStartProof) "$($c.name) proof true"
}
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429,"message":"rate limit"}' -PolicyPath $policy
Assert-MF ($d.Classification -eq 'RATE_LIMIT' -and $d.Status -eq 'HOLD_NO_START_PROOF_UNVERIFIED' -and $null -eq $d.NextModel -and -not $d.NoStartProof) '429 without evidence exact hold'
 $badEvidence=@()
 $badEvidence+=,(New-NoStartEvidence $task 'bad-1' 'opencode-go/hy4-flash-free' 'provider');$badEvidence[-1].session_id='ses_x'
 $badEvidence+=,(New-NoStartEvidence $task 'bad-2' 'opencode-go/hy4-flash-free' 'provider');$badEvidence[-1].execution_started=$true
 $badEvidence+=,(New-NoStartEvidence $task 'bad-3' 'opencode-go/hy4-flash-free' 'provider');$badEvidence[-1].stage='post_dispatch'
 $badEvidence+=,(New-NoStartEvidence $task 'bad-4' 'opencode-go/hy4-flash-free' 'provider');$badEvidence[-1].assistant_messages=1
 $badEvidence+=,(New-NoStartEvidence $task 'bad-5' 'opencode-go/hy4-flash-free' 'provider');$badEvidence[-1].tool_calls=1
 $badEvidence+=,(New-NoStartEvidence $task 'bad-6' 'opencode-go/hy4-flash-free' 'provider');$badEvidence[-1].execution_started='false'
 $badEvidence+=,@{source='provider';stage='pre_dispatch';task_id=$task;attempt_id='bad-7';requested_model='opencode-go/hy4-flash-free';session_id='';execution_started=$false;assistant_messages=0}
foreach($badEv in $badEvidence){
  $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $badEv -AttemptId $badEv.attempt_id -PolicyPath $policy
  Assert-MF ($d.Classification -eq 'RATE_LIMIT' -and $d.Status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and $null -eq $d.NextModel -and -not [string]::IsNullOrWhiteSpace($d.Reason)) 'ambiguous/inconsistent evidence exact hold'
 }
$toolNoSession=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"error":{"type":"tool.execution","message":"model not available"}}' -PolicyPath $policy
Assert-MF ($toolNoSession.Status -eq 'HOLD_NO_START_PROOF_UNVERIFIED' -and -not $toolNoSession.NoStartProof) 'tool_error without evidence holds'
$toolAttemptId='attempt-tool'
$toolEvidence=New-NoStartEvidence $task $toolAttemptId 'opencode-go/hy4-flash-free'
$toolAuthorized=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"error":{"type":"tool.execution","message":"model not available"}}' -AttemptEvidence $toolEvidence -AttemptId $toolAttemptId -PolicyPath $policy
Assert-MF ($toolAuthorized.Status -eq 'FALLBACK_AUTHORIZED' -and $toolAuthorized.NextModel -eq 'opencode/mimo-v2.6-flash-free') 'correlated dispatcher evidence authorizes tool fallback'
$sessionProof=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $toolEvidence -AttemptId $toolAttemptId -SessionId 'ses_1' -PolicyPath $policy
Assert-MF ($sessionProof.Status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and -not $sessionProof.NoStartProof) 'session suppresses no-start proof even with valid evidence'
$toolAttemptIdBad=New-NoStartEvidence 'other' $toolAttemptId 'opencode-go/hy4-flash-free'
$toolMismatch=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"error":{"type":"tool.execution","message":"model not available"}}' -AttemptEvidence $toolAttemptIdBad -AttemptId $toolAttemptId -PolicyPath $policy
Assert-MF ($toolMismatch.Status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and $toolMismatch.Reason -eq 'NO_START_PROOF_INVALID') 'mismatched task evidence holds'
$toolSession=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"sessionID":"ses_child","error":{"type":"tool.execution","message":"model not available"}}' -PolicyPath $policy
Assert-MF ($toolSession.Status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and $toolSession.Reason -eq 'EXECUTION_MAY_HAVE_STARTED' -and $null -eq $toolSession.NextModel) 'tool_error session holds'
$missing=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -PolicyPath $policy
Assert-MF ($missing.Status -eq 'HOLD_NO_START_PROOF_UNVERIFIED' -and $missing.Reason -eq 'NO_START_PROOF_UNVERIFIED') 'missing evidence stable hold reason'
$invalidFailure=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure 'not-json' -AttemptEvidence $ev -AttemptId 'attempt-explorer' -PolicyPath $policy
Assert-MF ($invalidFailure.Status -eq 'HOLD_INVALID_FAILURE' -and $invalidFailure.Reason -eq 'FAILURE_SHAPE_UNRECOGNIZED' -and -not $invalidFailure.FallbackEligible) 'unrecognized failure shape holds'
foreach($failure in @('{"code":"timeout"}','{"code":"invalid_request"}','{"status":401}')){
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure $failure -AttemptEvidence $ev -AttemptId 'attempt-explorer' -PolicyPath $policy
 Assert-MF ($d.Status -eq 'HOLD_TERMINAL' -and $d.Reason -eq 'FAILURE_NOT_ELIGIBLE' -and $null -eq $d.NextModel -and -not $d.NoStartProof) "ineligible $failure stays terminal"
}
$ineligibleEvidence=New-NoStartEvidence $task 'ineligible-attempt' 'opencode-go/hy4-flash-free'
$ineligibleWithProof=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":401}' -AttemptEvidence $ineligibleEvidence -AttemptId 'ineligible-attempt' -PolicyPath $policy
Assert-MF ($ineligibleWithProof.Status -eq 'HOLD_TERMINAL' -and -not $ineligibleWithProof.NoStartProof) 'ineligible failure with valid evidence has no proof'
$mismatchAttempt=New-NoStartEvidence $task 'attempt-expected' 'opencode-go/hy4-flash-free'
$mismatchAttempt.attempt_id='attempt-other'
$attemptMismatch=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $mismatchAttempt -AttemptId 'attempt-expected' -PolicyPath $policy
$mismatchModel=New-NoStartEvidence $task 'model-attempt' 'openai/other'
$modelMismatch=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $mismatchModel -AttemptId 'model-attempt' -PolicyPath $policy
Assert-MF ($attemptMismatch.Status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and $modelMismatch.Status -eq 'HOLD_AMBIGUOUS_EXECUTION') 'attempt and requested-model mismatches hold'
foreach($source in @('tool_error','bogus')){
 $badSource=New-NoStartEvidence $task 'source-attempt' 'opencode-go/hy4-flash-free' $source
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $badSource -AttemptId 'source-attempt' -PolicyPath $policy
 Assert-MF ($d.Status -eq 'HOLD_AMBIGUOUS_EXECUTION') "source $source rejected"
}
$caseSource=New-NoStartEvidence $task 'source-case' 'opencode-go/hy4-flash-free' 'Dispatcher'
$sourceAccepted=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $caseSource -AttemptId 'source-case' -PolicyPath $policy
$upperToolSource=New-NoStartEvidence $task 'source-tool' 'opencode-go/hy4-flash-free' 'TOOL_ERROR'
$sourceRejected=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $upperToolSource -AttemptId 'source-tool' -PolicyPath $policy
Assert-MF ($sourceAccepted.Status -eq 'FALLBACK_AUTHORIZED' -and $sourceRejected.Status -eq 'HOLD_AMBIGUOUS_EXECUTION') 'source comparison is case-insensitive but rejects tool_error'
$missingTask=New-NoStartEvidence $task 'missing-task' 'opencode-go/hy4-flash-free';$missingTask.Remove('task_id')
$missingModel=New-NoStartEvidence $task 'missing-model' 'opencode-go/hy4-flash-free';$missingModel.Remove('requested_model')
$blankAttempt=New-NoStartEvidence $task '' 'opencode-go/hy4-flash-free'
foreach($badCorrelation in @(@{e=$missingTask;a='missing-task'},@{e=$missingModel;a='missing-model'},@{e=$blankAttempt;a=''})){
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $badCorrelation.e -AttemptId $badCorrelation.a -PolicyPath $policy
 Assert-MF ($d.Status -eq 'HOLD_AMBIGUOUS_EXECUTION') 'missing/blank correlation field rejected'
}
foreach($counter in @('0',[double]0.0)){
 $badCount=New-NoStartEvidence $task 'count-attempt' 'opencode-go/hy4-flash-free';$badCount.assistant_messages=$counter
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $badCount -AttemptId 'count-attempt' -PolicyPath $policy
 Assert-MF ($d.Status -eq 'HOLD_AMBIGUOUS_EXECUTION') "non-integer counter $counter rejected"
}
$ineligibleTool=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"error":{"type":"tool.execution","message":"timeout"}}' -AttemptEvidence @{source='invalid';stage='pre_dispatch';session_id='';execution_started=$false;assistant_messages=0;tool_calls=0} -PolicyPath $policy
Assert-MF ($ineligibleTool.Status -eq 'HOLD_TERMINAL' -and $ineligibleTool.Reason -eq 'FAILURE_NOT_ELIGIBLE') 'ineligible tool error remains terminal with invalid evidence'
$stringFalse=@{source='provider';stage='pre_dispatch';session_id='';execution_started='false';assistant_messages=0;tool_calls=0}
$stringFalseDecision=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $stringFalse -PolicyPath $policy
Assert-MF ($stringFalseDecision.Status -like 'HOLD_*' -and -not $stringFalseDecision.FallbackEligible) 'execution_started string false cannot authorize'

# Exercise actual CLI process exit codes and JSON payload, on the active PowerShell edition.
$cli=Join-Path $PSScriptRoot '..\model-fallback.ps1'
$cliTemp=Join-Path ([IO.Path]::GetTempPath()) ('model-fallback-cli-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($cliTemp)
$failureFile=Join-Path $cliTemp 'failure.json';$evidenceFile=Join-Path $cliTemp 'evidence.json'
[IO.File]::WriteAllText($failureFile,$providerCases[0].failure,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($evidenceFile,($ev|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
$psExe=(Get-Process -Id $PID).Path
function Invoke-FallbackCli {
 param([string[]]$Arguments)
 $stdout=Join-Path $cliTemp ([guid]::NewGuid().ToString('N')+'.out')
 $stderr=Join-Path $cliTemp ([guid]::NewGuid().ToString('N')+'.err')
 $quoted=@($Arguments|ForEach-Object{'"'+([string]$_).Replace('"','\"')+'"'})
 $proc=Start-Process -FilePath $psExe -ArgumentList $quoted -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
 $text=Get-Content -LiteralPath $stdout -Raw
 $json=$null;try{$json=ConvertFrom-Json -InputObject $text -ErrorAction Stop}catch{}
 return @{code=$proc.ExitCode;json=$json;stdout=$text}
}
$ev=New-NoStartEvidence $task 'cli-attempt' 'opencode-go/hy4-flash-free' 'provider'
[IO.File]::WriteAllText($evidenceFile,($ev|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
$baseArgs=@('-NoProfile','-File',$cli,'-Action','next','-AttemptId','cli-attempt','-TaskId',$task,'-AttemptRole','explorer','-FailedModel','opencode-go/hy4-flash-free','-FailureJson',"@$failureFile")
$cliAuthorized=Invoke-FallbackCli ($baseArgs+@('-AttemptEvidenceJson',"@$evidenceFile"))
Assert-MF ($cliAuthorized.code -eq 0 -and $cliAuthorized.json.status -eq 'FALLBACK_AUTHORIZED') 'CLI exit 0 on authorized fallback'
$cliFallbackTask=Invoke-FallbackCli ($baseArgs+@('-TaskId','fallback','-AttemptEvidenceJson',"@$evidenceFile"))
Assert-MF ($cliFallbackTask.code -ne 2) 'literal fallback is accepted as explicit TaskId'
$cliSession=Invoke-FallbackCli ($baseArgs+@('-SessionId','ses_child','-AttemptEvidenceJson',"@$evidenceFile"))
Assert-MF ($cliSession.code -eq 3 -and $cliSession.json.status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and -not $cliSession.json.no_start_proof) 'CLI session blocks redispatch and proof'
$exhaustEv=New-NoStartEvidence $task 'cli-exhausted' 'opencode-go/muse-spark-1.3-contributor' 'provider'
$exhaustEvidenceFile=Join-Path $cliTemp 'exhaust-evidence.json'
[IO.File]::WriteAllText($exhaustEvidenceFile,($exhaustEv|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
$exhaustedArgs=@('-NoProfile','-File',$cli,'-Action','next','-AttemptId','cli-exhausted','-TaskId',$task,'-AttemptRole','coder','-FailedModel','opencode-go/muse-spark-1.3-contributor','-AttemptedModels','openai/gpt-6-luna,opencode-go/deepseek-v4.1-flash,opencode-go/muse-spark-1.3-contributor','-FailureJson',"@$failureFile",'-AttemptEvidenceJson',"@$exhaustEvidenceFile")
$cliExhausted=Invoke-FallbackCli $exhaustedArgs
Assert-MF ($cliExhausted.code -eq 0 -and $cliExhausted.json.status -eq 'EXHAUSTED') 'CLI exit 0 on exhausted fallback'
$cliHold=Invoke-FallbackCli $baseArgs
Assert-MF ($cliHold.code -eq 3 -and $cliHold.json.status -eq 'HOLD_NO_START_PROOF_UNVERIFIED') 'CLI exit 3 on HOLD'
$cliUsage=Invoke-FallbackCli @('-NoProfile','-File',$cli,'-Action','next')
Assert-MF ($cliUsage.code -eq 2 -and $null -eq $cliUsage.json) 'CLI exit 2 on usage error'
$cliNoAttempt=Invoke-FallbackCli ($baseArgs|Where-Object {$_ -ne 'cli-attempt' -and $_ -ne '-AttemptId'})
$cliNoTask=Invoke-FallbackCli @('-NoProfile','-File',$cli,'-Action','next','-AttemptId','x','-AttemptRole','explorer','-FailedModel','opencode-go/hy4-flash-free','-FailureJson',"@$failureFile")
Assert-MF ($cliNoAttempt.code -eq 2 -and $cliNoTask.code -eq 2) 'CLI requires nonblank AttemptId and TaskId'
[IO.File]::WriteAllText($evidenceFile,'{malformed',[Text.UTF8Encoding]::new($false))
$cliBadEvidence=Invoke-FallbackCli ($baseArgs+@('-AttemptEvidenceJson',"@$evidenceFile"))
Assert-MF ($cliBadEvidence.code -eq 3 -and $cliBadEvidence.json.status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and $cliBadEvidence.json.reason -eq 'NO_START_PROOF_INVALID') 'malformed CLI evidence returns JSON HOLD and exit 3'
Remove-Item -LiteralPath $cliTemp -Recurse -Force
$high=Resolve-OrchestrationModelSelection -AgentName reviewer -TaskId $task -Risk high -Complexity simple -PolicyPath $policy -IgnoreUserConfig $true
Assert-MF ($high.Tier -eq 'T3' -and $high.CatalogModel -eq 'claude-agent/sonnet') 'reviewer high selects T3 Sonnet'
$reviewEvidence=New-NoStartEvidence $task 'reviewer-attempt' 'claude-agent/sonnet'
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole reviewer -Risk high -FailedModel 'claude-agent/sonnet' -Failure '{"error":{"type":"tool.execution","message":"Model claude-agent/sonnet is not available"}}' -AttemptEvidence $reviewEvidence -AttemptId 'reviewer-attempt' -PolicyPath $policy
# The policy's next candidate is asserted directly; this is not a risk-low routing override.
Assert-MF ($d.Status -eq 'FALLBACK_AUTHORIZED' -and $d.NextModel -eq 'openai/gpt-6.1-terra') 'reviewer high next Terra'
$low=Resolve-OrchestrationModelSelection -AgentName reviewer -TaskId $task -Risk low -Complexity simple -PolicyPath $policy -IgnoreUserConfig $true
Assert-MF ($low.Tier -eq 'T2' -and $low.CatalogModel -eq 'openai/gpt-6-luna') 'reviewer low selects Luna T2'
$coderChain=Get-OrchestrationModelFallbackChain -AttemptRole coder -TaskId $task -PolicyPath $policy
Assert-MF ($coderChain.Count -eq 3 -and $coderChain[0] -eq 'openai/gpt-6-luna' -and $coderChain[1] -eq 'opencode-go/deepseek-v4.1-flash' -and $coderChain[2] -eq 'opencode-go/muse-spark-1.3-contributor') 'coder chain exact three distinct'
$seqA=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole coder -FailedModel $coderChain[0] -Failure '{"status":429}' -AttemptEvidence (New-NoStartEvidence $task 'seq-a' $coderChain[0]) -AttemptId 'seq-a' -PolicyPath $policy
$seqB=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole coder -FailedModel $coderChain[1] -AttemptedModels @($coderChain[0],$coderChain[1]) -Failure '{"status":429}' -AttemptEvidence (New-NoStartEvidence $task 'seq-b' $coderChain[1]) -AttemptId 'seq-b' -PolicyPath $policy
$seqC=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole coder -FailedModel $coderChain[2] -AttemptedModels @($coderChain) -Failure '{"status":429}' -AttemptEvidence (New-NoStartEvidence $task 'seq-c' $coderChain[2]) -AttemptId 'seq-c' -PolicyPath $policy
Assert-MF ($seqA.Status -eq 'FALLBACK_AUTHORIZED' -and $seqA.NextModel -eq $coderChain[1] -and $seqB.Status -eq 'FALLBACK_AUTHORIZED' -and $seqB.NextModel -eq $coderChain[2] -and $seqC.Status -eq 'EXHAUSTED' -and $null -eq $seqC.NextModel) 'A to B to C is authorized once then exhausted'
$evidenceDir=Join-Path ([IO.Path]::GetTempPath()) ('model-fallback-tests-'+[guid]::NewGuid().ToString('N'))
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -AttemptEvidence $ev -AttemptId $ev.attempt_id -PolicyPath $policy -EvidenceDir $evidenceDir
$line=Get-Content (Join-Path $evidenceDir 'fallback-decisions.jsonl') -Raw | ConvertFrom-Json
Assert-MF ($line.decision -eq $d.Status -and $line.no_start_reason -and $line.attempt_id -eq $d.AttemptId -and $line.classification -eq $d.Classification -and $line.next_model -eq $d.NextModel) 'JSONL decision evidence fields'
$holdDir=Join-Path ([IO.Path]::GetTempPath()) ('model-fallback-hold-'+[guid]::NewGuid().ToString('N'))
$holdDecision=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'opencode-go/hy4-flash-free' -Failure '{"status":429}' -PolicyPath $policy -EvidenceDir $holdDir
$holdLine=Get-Content (Join-Path $holdDir 'fallback-decisions.jsonl') -Raw | ConvertFrom-Json
Assert-MF ($holdLine.status -like 'HOLD_*' -and -not $holdLine.no_start_proof) 'JSONL HOLD records no_start_proof false'
Remove-Item -LiteralPath $holdDir -Recurse -Force
$recordOutput=& (Join-Path $PSScriptRoot '..\model-fallback.ps1') -Action record -AttemptId 'cli-attempt' -TaskId $task -AttemptRole explorer -Model $cliAuthorized.json.next_model -SessionId 'ses_child-authorized' -EvidenceDir $evidenceDir
$modelRecords=@(Get-Content (Join-Path $evidenceDir 'model-attempts.jsonl') | ForEach-Object { ConvertFrom-Json $_ })
Assert-MF ($cliAuthorized.json.status -eq 'FALLBACK_AUTHORIZED' -and $modelRecords.Count -eq 1 -and $modelRecords[0].attempt_id -eq $cliAuthorized.json.attempt_id -and $modelRecords[0].task_id -eq $task -and $modelRecords[0].session_id -eq 'ses_child-authorized' -and (Test-Path (Join-Path $evidenceDir 'fallback-decisions.jsonl'))) 'authorized fallback records same task/attempt with child session'
Remove-Item -LiteralPath $evidenceDir -Recurse -Force
Write-Host "OrchestrationModelFallback: passed=$passed failed=$failed"
if($failed){exit 1}
