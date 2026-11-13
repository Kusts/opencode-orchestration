[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. 'D:\projetos\_wt\orch-fallback\scripts\v3\lib\OrchestrationProviderError.ps1'
$passed = 0
$failed = 0
function Assert-ProviderError {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:passed++; Write-Host "PASS $Name" }
    else { $script:failed++; Write-Host "FAIL $Name" }
}
$cases = @(
    @('429', @{status=429}, 'RATE_LIMIT'),
    @('rate limit', @{code='rate_limit_exceeded'}, 'RATE_LIMIT'),
    @('too many', @{code='too_many_requests'}, 'RATE_LIMIT'),
    @('overloaded', @{code='overloaded'}, 'RATE_LIMIT'),
    @('slow down', @{code='slow_down'}, 'RATE_LIMIT'),
    @('quota exceeded', @{code='quota_exceeded'}, 'QUOTA_EXCEEDED'),
    @('usage limit', @{code='usage_limit'}, 'QUOTA_EXCEEDED'),
    @('usage phrase', @{message='reached your usage limit'}, 'QUOTA_EXCEEDED'),
    @('resource underscore', @{code='resource_exhausted'}, 'QUOTA_EXCEEDED'),
    @('resource phrase', @{message='resource exhausted'}, 'QUOTA_EXCEEDED'),
    @('model unavailable', @{code='model_unavailable'}, 'MODEL_UNAVAILABLE'),
    @('model not found', @{code='model_not_found'}, 'MODEL_UNAVAILABLE'),
    @('model unsupported', @{code='model_not_supported'}, 'MODEL_UNAVAILABLE'),
    @('model decommissioned', @{code='model_decommissioned'}, 'MODEL_UNAVAILABLE'),
    @('no such model', @{message='no such model'}, 'MODEL_UNAVAILABLE'),
    @('502', @{status=502}, 'PROVIDER_UNAVAILABLE'),
    @('503', @{status=503}, 'PROVIDER_UNAVAILABLE'),
    @('504', @{status=504}, 'PROVIDER_UNAVAILABLE'),
    @('service unavailable', @{code='service_unavailable'}, 'PROVIDER_UNAVAILABLE'),
    @('server overloaded', @{code='server_overloaded'}, 'PROVIDER_UNAVAILABLE'),
    @('bad gateway', @{code='bad_gateway'}, 'PROVIDER_UNAVAILABLE'),
    @('500', @{status=500}, 'PROVIDER_ERROR'),
    @('internal error', @{code='internal_error'}, 'PROVIDER_ERROR'),
    @('internal server error', @{message='internal server error'}, 'PROVIDER_ERROR'),
    @('401', @{status=401}, 'AUTH_OR_PERMISSION_ERROR'),
    @('403', @{status=403}, 'AUTH_OR_PERMISSION_ERROR'),
    @('invalid key', @{message='invalid api key'}, 'AUTH_OR_PERMISSION_ERROR'),
    @('unauthorized', @{code='unauthorized'}, 'AUTH_OR_PERMISSION_ERROR'),
    @('forbidden', @{code='forbidden'}, 'AUTH_OR_PERMISSION_ERROR'),
    @('permission denied', @{message='permission denied'}, 'AUTH_OR_PERMISSION_ERROR'),
    @('insufficient permissions', @{message='insufficient permissions'}, 'AUTH_OR_PERMISSION_ERROR'),
    @('400', @{status=400}, 'REQUEST_INVALID'),
    @('413', @{status=413}, 'REQUEST_INVALID'),
    @('context length', @{code='context_length_exceeded'}, 'REQUEST_INVALID'),
    @('context too large', @{message='context too large'}, 'REQUEST_INVALID'),
    @('invalid request', @{code='invalid_request'}, 'REQUEST_INVALID'),
    @('invalid input', @{message='invalid input'}, 'REQUEST_INVALID'),
    @('timeout', @{message='timeout'}, 'EXECUTION_UNKNOWN'),
    @('timed out', @{message='timed out'}, 'EXECUTION_UNKNOWN'),
    @('ETIMEDOUT', @{code='ETIMEDOUT'}, 'EXECUTION_UNKNOWN'),
    @('connection reset', @{message='connection reset'}, 'EXECUTION_UNKNOWN'),
    @('ECONNRESET', @{code='ECONNRESET'}, 'EXECUTION_UNKNOWN'),
    @('aborted', @{message='aborted'}, 'EXECUTION_UNKNOWN'),
    @('stream interrupted', @{message='stream interrupted'}, 'EXECUTION_UNKNOWN'),
    @('unknown result', @{message='unknown result'}, 'EXECUTION_UNKNOWN'),
    @('408', @{status=408}, 'EXECUTION_UNKNOWN'),
    @('409', @{status=409}, 'PROVIDER_ERROR'),
    @('529 overload', @{status=529; message='overloaded'}, 'RATE_LIMIT'),
    @('529 plain', @{status=529}, 'PROVIDER_UNAVAILABLE')
)
foreach ($case in $cases) {
    $result = ConvertFrom-OrchestrationProviderFailure -Failure $case[1]
    Assert-ProviderError ($result.Classification -ceq $case[2]) "map $($case[0])"
}
$r = ConvertFrom-OrchestrationProviderFailure @{status=429;message='invalid api key'}
Assert-ProviderError ($r.Classification -eq 'RATE_LIMIT' -and $r.Signals.source -eq 'http_status') 'status beats contradictory message'
$oa = ConvertFrom-OrchestrationProviderFailure '{"error":{"type":"rate_limit_error","code":"rate_limit_exceeded"}}'
$other = ConvertFrom-OrchestrationProviderFailure '{"status":429,"code":"too_many_requests"}'
Assert-ProviderError ($oa.Classification -eq $other.Classification -and $oa.Availability -eq $other.Availability) 'cross-provider equivalence'
$anthropic = ConvertFrom-OrchestrationProviderFailure '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}'
$google = ConvertFrom-OrchestrationProviderFailure '{"error":{"code":503,"status":"UNAVAILABLE","message":"service unavailable"}}'
Assert-ProviderError ($anthropic.Classification -eq 'RATE_LIMIT') 'Anthropic nested error'
Assert-ProviderError ($google.Classification -eq 'PROVIDER_UNAVAILABLE') 'Google-like nested error'
$r = ConvertFrom-OrchestrationProviderFailure @{status=413}
Assert-ProviderError ($r.Classification -eq 'REQUEST_INVALID' -and -not $r.FallbackEligible) '413 not eligible'
$r = ConvertFrom-OrchestrationProviderFailure @{status=401}
Assert-ProviderError ($r.Classification -eq 'AUTH_OR_PERMISSION_ERROR' -and -not $r.FallbackEligible) '401 not eligible'
$r = ConvertFrom-OrchestrationProviderFailure @{message='timeout'}
Assert-ProviderError ($r.Classification -eq 'EXECUTION_UNKNOWN' -and -not $r.FallbackEligible -and $r.Ambiguous) 'timeout ambiguous, not eligible'
$r = ConvertFrom-OrchestrationProviderFailure @{status=503} -Stage pre_dispatch
Assert-ProviderError ($r.Availability -and $r.RetrySafePreExecution) '503 pre dispatch policy'
$r = ConvertFrom-OrchestrationProviderFailure @{status=503} -Stage post_dispatch
Assert-ProviderError ($r.Availability -and -not $r.RetrySafePreExecution) '503 post dispatch policy'
$r = ConvertFrom-OrchestrationProviderFailure ''
Assert-ProviderError ($r.Classification -eq 'NONE') 'empty string'
$r = ConvertFrom-OrchestrationProviderFailure @{message='unknown quota'}
Assert-ProviderError ($r.Classification -eq 'NONE' -and -not $r.Availability) 'unknown quota is not quota'
$r = ConvertFrom-OrchestrationProviderFailure @{code='resource_exhausted'}
Assert-ProviderError ($r.Classification -eq 'QUOTA_EXCEEDED') 'resource_exhausted alias'
$r = ConvertFrom-OrchestrationProviderFailure @{code='usage_limit'}
Assert-ProviderError ($r.Classification -eq 'QUOTA_EXCEEDED') 'usage_limit alias'
$r = ConvertFrom-OrchestrationProviderFailure @{code='model_not_found'}
Assert-ProviderError ($r.Classification -eq 'MODEL_UNAVAILABLE') 'model_not_found alias'
$r = ConvertFrom-OrchestrationProviderFailure @{status=503} -Stage pre_dispatch
Assert-ProviderError ($r.Signals.stage -eq 'pre_dispatch') 'normalized stage signal'
$r = ConvertFrom-OrchestrationProviderFailure ([pscustomobject]@{statusCode='503';provider='sample';model='m';attemptId='a';message='x'})
Assert-ProviderError ($r.Classification -eq 'PROVIDER_UNAVAILABLE' -and $r.Signals.provider -eq 'sample' -and $r.Signals.model -eq 'm' -and $r.Signals.attempt_id -eq 'a') 'alternate object fields'
$r = ConvertFrom-OrchestrationProviderFailure ([pscustomobject]@{code='rate_limit_exceeded';type='invalid_request'})
Assert-ProviderError ($r.Classification -eq 'RATE_LIMIT' -and $r.Signals.source -eq 'structured_code') 'code beats error type'
$r = ConvertFrom-OrchestrationProviderFailure ([pscustomobject]@{type='rate_limit_error'})
Assert-ProviderError ($r.Classification -eq 'RATE_LIMIT' -and $r.Signals.source -eq 'error_type') 'error type classification'
$r = ConvertFrom-OrchestrationProviderFailure ([pscustomobject]@{message=('x' * 600)})
Assert-ProviderError ($r.Classification -eq 'NONE' -and $r.Reason.Length -le 64 -and $null -eq $r.Signals.code) 'bounded unknown result'
$r = ConvertFrom-OrchestrationProviderFailure ([pscustomobject]@{code='rate_limit_exceeded';message='x' * 900})
Assert-ProviderError ($r.Signals.code -eq 'rate_limit_exceeded' -and $r.Reason.Length -le 64) 'normalized fields only'
$r = ConvertFrom-OrchestrationProviderFailure ([pscustomobject]@{})
Assert-ProviderError ($r.Classification -eq 'NONE' -and -not $r.Availability -and -not $r.Configuration) 'empty object safe'
Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
