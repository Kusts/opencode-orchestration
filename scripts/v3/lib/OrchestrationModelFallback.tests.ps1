[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelFallback.ps1')
$passed=0;$failed=0
function Assert-MF { param([bool]$Ok,[string]$Name) if($Ok){$script:passed++}else{$script:failed++;Write-Host "FAIL $Name"} }
$role='coder';$task='fallback-test';$policy=Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json'
if(-not (Test-Path $policy)){$policy=''}
$tool='{"error":{"type":"tool.execution","message":"Model openai/does-not-exist is not available."}}'
$cases=@(
 @{name='native model unavailable';fail=$tool;model='openai/does-not-exist'},
 @{name='429';fail='{"status":429,"message":"rate limit"}';model='opencode-go/deepseek-v4.1-flash'},
 @{name='resource exhausted';fail='{"code":"resource_exhausted","message":"quota"}';model='opencode-go/deepseek-v4.1-flash'},
 @{name='503';fail='{"status":503,"message":"unavailable"}';model='opencode-go/deepseek-v4.1-flash'}
)
foreach($c in $cases){
 $ev=@{source='provider';stage='pre_dispatch';session_id='';execution_started=$false;assistant_messages=0;tool_calls=0}
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -Risk low -Complexity simple -FailedModel $c.model -AttemptedModels @($c.model) -Failure $c.fail -AttemptEvidence $ev -PolicyPath $policy
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
$exhausted=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole $role -FailedModel $last -AttemptedModels $already -Failure $tool -PolicyPath $policy
Assert-MF ($exhausted.Status -eq 'EXHAUSTED' -or $exhausted.Status -eq 'HOLD_TERMINAL') 'chain exhaustion readable'
Assert-MF ((ConvertFrom-OrchestrationToolError '{"error":{"type":"tool.execution","message":"Model not available"}}').Classification -eq (ConvertFrom-OrchestrationProviderFailure @{code='model_unavailable'}).Classification) 'cross-provider semantic equivalence'

# Acceptance cases use the repository policy; do not replace it with test routing.
$ev=@{source='provider';stage='pre_dispatch';session_id='';execution_started=$false;assistant_messages=0;tool_calls=0}
$providerCases=@(
 @{name='explorer 429';failure='{"status":429,"message":"rate limit"}';class='RATE_LIMIT';model='openai/does-not-exist';next='opencode/mimo-v2.6-flash-free'},
 @{name='explorer quota';failure='{"code":"resource_exhausted","message":"quota"}';class='QUOTA_EXCEEDED';model='openai/does-not-exist';next='opencode/mimo-v2.6-flash-free'},
 @{name='explorer 503';failure='{"status":503,"message":"unavailable"}';class='PROVIDER_UNAVAILABLE';model='openai/does-not-exist';next='opencode/mimo-v2.6-flash-free'}
)
foreach($c in $providerCases){
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -Risk low -FailedModel $c.model -Failure $c.failure -AttemptEvidence $ev -PolicyPath $policy
 Assert-MF ($d.Classification -eq $c.class) "$($c.name) exact classification"
 Assert-MF ($d.Status -eq 'FALLBACK_AUTHORIZED') "$($c.name) exact status"
 Assert-MF ($d.NextModel -eq $c.next) "$($c.name) exact next"
 Assert-MF ($d.NoStartProof) "$($c.name) proof true"
}
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'openai/does-not-exist' -Failure '{"status":429,"message":"rate limit"}' -PolicyPath $policy
Assert-MF ($d.Classification -eq 'RATE_LIMIT' -and $d.Status -eq 'HOLD_NO_START_PROOF_UNVERIFIED' -and $null -eq $d.NextModel -and -not $d.NoStartProof) '429 without evidence exact hold'
foreach($badEv in @(
  @{source='provider';stage='pre_dispatch';session_id='ses_x';execution_started=$false;assistant_messages=0;tool_calls=0},
  @{source='provider';stage='pre_dispatch';session_id='';execution_started=$true;assistant_messages=0;tool_calls=0},
  @{source='provider';stage='post_dispatch';session_id='';execution_started=$false;assistant_messages=0;tool_calls=0},
  @{source='provider';stage='pre_dispatch';session_id='';execution_started=$false;assistant_messages=1;tool_calls=0},
  @{source='provider';stage='pre_dispatch';session_id='';execution_started=$false;assistant_messages=0;tool_calls=1},
  @{source='provider';stage='pre_dispatch';session_id='';execution_started=$false;assistant_messages=0}
)){
  $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'openai/does-not-exist' -Failure '{"status":429}' -AttemptEvidence $badEv -PolicyPath $policy
  Assert-MF ($d.Classification -eq 'RATE_LIMIT' -and $d.Status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and $null -eq $d.NextModel -and -not [string]::IsNullOrWhiteSpace($d.Reason)) 'ambiguous/inconsistent evidence exact hold'
 }
$toolNoSession=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'openai/does-not-exist' -Failure '{"error":{"type":"tool.execution","message":"model not available"}}' -PolicyPath $policy
Assert-MF ($toolNoSession.Status -eq 'FALLBACK_AUTHORIZED' -and $toolNoSession.NoStartProof) 'tool_error without session authorizes'
$toolSession=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'openai/does-not-exist' -Failure '{"sessionID":"ses_child","error":{"type":"tool.execution","message":"model not available"}}' -PolicyPath $policy
Assert-MF ($toolSession.Status -eq 'HOLD_AMBIGUOUS_EXECUTION' -and $toolSession.Reason -eq 'EXECUTION_MAY_HAVE_STARTED' -and $null -eq $toolSession.NextModel) 'tool_error session holds'
$missing=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'openai/does-not-exist' -Failure '{"status":429}' -PolicyPath $policy
Assert-MF ($missing.Status -eq 'HOLD_NO_START_PROOF_UNVERIFIED' -and $missing.Reason -eq 'NO_START_PROOF_UNVERIFIED') 'missing evidence stable hold reason'
$invalidFailure=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'openai/does-not-exist' -Failure 'not-json' -AttemptEvidence $ev -PolicyPath $policy
Assert-MF ($invalidFailure.Status -eq 'HOLD_INVALID_FAILURE' -and $invalidFailure.Reason -eq 'FAILURE_SHAPE_UNRECOGNIZED' -and -not $invalidFailure.FallbackEligible) 'unrecognized failure shape holds'
foreach($failure in @('{"code":"timeout"}','{"code":"invalid_request"}','{"status":401}')){
 $d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'openai/does-not-exist' -Failure $failure -AttemptEvidence $ev -PolicyPath $policy
 Assert-MF ($d.Status -ne 'FALLBACK_AUTHORIZED' -and $null -eq $d.NextModel) "ineligible $failure never authorizes"
}
$high=Resolve-OrchestrationModelSelection -AgentName reviewer -TaskId $task -Risk high -Complexity simple -PolicyPath $policy -IgnoreUserConfig $true
Assert-MF ($high.Tier -eq 'T3' -and $high.CatalogModel -eq 'claude-agent/sonnet') 'reviewer high selects T3 Sonnet'
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole reviewer -Risk high -FailedModel 'claude-agent/sonnet' -Failure '{"error":{"type":"tool.execution","message":"Model claude-agent/sonnet is not available"}}' -PolicyPath $policy
# The policy's next candidate is asserted directly; this is not a risk-low routing override.
Assert-MF ($d.Status -eq 'FALLBACK_AUTHORIZED' -and $d.NextModel -eq 'openai/gpt-6.1-terra') 'reviewer high next Terra'
$low=Resolve-OrchestrationModelSelection -AgentName reviewer -TaskId $task -Risk low -Complexity simple -PolicyPath $policy -IgnoreUserConfig $true
Assert-MF ($low.Tier -eq 'T2' -and $low.CatalogModel -eq 'openai/gpt-6-luna') 'reviewer low selects Luna T2'
$coderChain=Get-OrchestrationModelFallbackChain -AttemptRole coder -TaskId $task -PolicyPath $policy
Assert-MF ($coderChain.Count -eq 3 -and $coderChain[0] -eq 'openai/gpt-6-luna' -and $coderChain[1] -eq 'opencode-go/deepseek-v4.1-flash' -and $coderChain[2] -eq 'opencode-go/muse-spark-1.3-contributor') 'coder chain exact three distinct'
$evidenceDir=Join-Path ([IO.Path]::GetTempPath()) ('model-fallback-tests-'+[guid]::NewGuid().ToString('N'))
$d=Get-OrchestrationModelFallbackDecision -TaskId $task -AttemptRole explorer -FailedModel 'openai/does-not-exist' -Failure '{"status":429}' -AttemptEvidence $ev -PolicyPath $policy -EvidenceDir $evidenceDir
$line=Get-Content (Join-Path $evidenceDir 'fallback-decisions.jsonl') -Raw | ConvertFrom-Json
Assert-MF ($line.decision -eq $d.Status -and $line.no_start_reason -and $line.attempt_id -eq $d.AttemptId -and $line.classification -eq $d.Classification -and $line.next_model -eq $d.NextModel) 'JSONL decision evidence fields'
$recordOutput=& (Join-Path $PSScriptRoot '..\model-fallback.ps1') -Action record -AttemptId 'record-separate' -AttemptRole explorer -Model 'openai/gpt-6-luna' -SessionId 'ses_record' -EvidenceDir $evidenceDir
$modelRecords=@(Get-Content (Join-Path $evidenceDir 'model-attempts.jsonl') | ForEach-Object { ConvertFrom-Json $_ })
Assert-MF ($modelRecords.Count -eq 1 -and $modelRecords[0].attempt_id -eq 'record-separate' -and (Test-Path (Join-Path $evidenceDir 'fallback-decisions.jsonl'))) 'record remains separate from fallback/kernel model_attempts'
Remove-Item -LiteralPath $evidenceDir -Recurse -Force
Write-Host "OrchestrationModelFallback: passed=$passed failed=$failed"
if($failed){exit 1}
