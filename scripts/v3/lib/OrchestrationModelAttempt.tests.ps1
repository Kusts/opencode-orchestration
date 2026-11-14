[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelAttempt.ps1')
$passed=0;$failed=0
function Assert-MA { param([bool]$Ok,[string]$Name) if($Ok){$script:passed++}else{$script:failed++;Write-Host "FAIL $Name"} }
$shape='{"error":{"type":"tool.execution","message":"Model openai/does-not-exist is not available. Use the models tool."}}'
$tool=ConvertFrom-OrchestrationToolError $shape
$attempt=[pscustomobject]@{failure=$tool;session_id=$null;observed_model=$null;execution_started=$false;assistant_messages=0;tool_calls=0}
$proof=Test-OrchestrationAttemptNoStartProof $attempt
Assert-MA ($tool.Classification -eq 'MODEL_UNAVAILABLE' -and $tool.Source -eq 'tool_error') 'exact native tool error normalized'
Assert-MA $proof.proven 'native tool error proves no child start'
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
Write-Host "OrchestrationModelAttempt: passed=$passed failed=$failed"
if($failed){exit 1}
