[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelAttempt.ps1')
$passed=0;$failed=0
function Assert-MA { param([bool]$Ok,[string]$Name) if($Ok){$script:passed++}else{$script:failed++;Write-Host "FAIL $Name"} }
$shape='{"error":{"type":"tool.execution","message":"Model openai/does-not-exist is not available. Use the models tool."}}'
$tool=ConvertFrom-OrchestrationToolError $shape
$attempt=[pscustomobject]@{failure=$tool;task_id='t';attempt_id='a1';requested_model='openai/does-not-exist';session_id=$null;observed_model=$null;execution_started=$false;assistant_messages=0;tool_calls=0;session_evidence_present=$true}
$proof=Test-OrchestrationAttemptNoStartProof $attempt
Assert-MA ($tool.Classification -eq 'MODEL_UNAVAILABLE' -and $tool.Source -eq 'tool_error') 'exact native tool error normalized'
Assert-MA $proof.proven 'correlated attempt record proves no child start regardless of failure source'
$toolSession=ConvertFrom-OrchestrationToolError '{"sessionID":"ses_x","error":{"type":"tool.execution","message":"model unavailable"}}'
$attempt.failure=$toolSession
Assert-MA (-not (Test-OrchestrationAttemptNoStartProof $attempt).proven) 'session id invalidates no-start'
foreach($c in @(@{status=429;want='RATE_LIMIT'},@{status=503;want='PROVIDER_UNAVAILABLE'},@{status=401;want='AUTH_OR_PERMISSION_ERROR'},@{status=403;want='AUTH_OR_PERMISSION_ERROR'})){
 $r=ConvertFrom-OrchestrationProviderFailure @{status=$c.status}
 Assert-MA ($r.Classification -eq $c.want) "provider status $($c.status)"
}
$json='{"type":"error","sessionID":"ses_a","error":{"type":"provider.no-route","message":"Model unavailable: openai/does-not-exist"}}'
$legacy=Get-OrchestrationFailureFromOutput $json ''
Assert-MA ((ConvertFrom-OrchestrationProviderFailure $legacy -Stage pre_dispatch).Classification -eq 'MODEL_UNAVAILABLE') 'legacy provider no-route parse'
$completeAttempt=New-OrchestrationModelAttempt -TaskId 't' -Agent 'coder' -Model 'openai/does-not-exist' -AttemptId 'complete-no-evidence'
$completed=Complete-OrchestrationModelAttempt -Attempt $completeAttempt -ExitCode 1 -FailureOverride @{code='model_unavailable'}
Assert-MA (-not $completed.no_start_proof -and $completed.no_start_reason -eq 'NO_START_PROOF_UNVERIFIED') 'Complete without SessionEvidence cannot prove no-start'
$completeEvidence=@{session_id='';outcome='error';observed_model=$null;execution_started=$false;assistant_messages=0;tool_calls=0}
$completeAttempt=New-OrchestrationModelAttempt -TaskId 't' -Agent 'coder' -Model 'openai/does-not-exist' -AttemptId 'complete-with-evidence'
$completed=Complete-OrchestrationModelAttempt -Attempt $completeAttempt -ExitCode 1 -SessionEvidence $completeEvidence -FailureOverride @{code='model_unavailable'}
Assert-MA ($completed.no_start_proof -and $completed.no_start_reason -eq 'OBSERVED_NO_START') 'Complete with valid SessionEvidence proves no-start'
$badSessionEvidence=@{ok=$false;session_id='ses_missing';execution_started=$false;assistant_messages=0;tool_calls=0}
$completeAttempt=New-OrchestrationModelAttempt -TaskId 't' -Agent 'coder' -Model 'openai/does-not-exist' -AttemptId 'complete-bad-evidence'
$completed=Complete-OrchestrationModelAttempt -Attempt $completeAttempt -ExitCode 1 -SessionEvidence $badSessionEvidence -FailureOverride @{code='model_unavailable'}
Assert-MA (-not $completed.no_start_proof -and $completed.no_start_reason -eq 'NO_START_PROOF_UNVERIFIED') 'Complete with ok=false SessionEvidence cannot prove no-start'
Write-Host "OrchestrationModelAttempt: passed=$passed failed=$failed"
if($failed){exit 1}
