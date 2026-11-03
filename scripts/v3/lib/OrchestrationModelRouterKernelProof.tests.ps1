<#!
.SYNOPSIS
    Kernel-proof regression: arbitrary bool/string must never authorize T4/Astra.
.DESCRIPTION
    Deterministic, no provider calls. PS 5.1, ASCII-only.
    Negative-only: caller claims (bool/string receipts, FailureCount,
    TaskId without persisted proof) never authorize T4/Astra. Positive
    Kernel->Router selection is proven only with a real persisted task
    store in OrchestrationTaskKernelModelProof.tests.ps1 (no stubs of
    Get-OrchestrationTaskModelFailureProof anywhere).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
$script:pass = 0; $script:fail = 0
function Assert-KP([bool]$c,[string]$n,[string]$d='') {
    if ($c) { Write-Host "[PASS] $n"; $script:pass++ }
    else { if ($d -eq '') { Write-Host "[FAIL] $n" } else { Write-Host "[FAIL] $n -- $d" }; $script:fail++ }
}
# 1. Arbitrary T3FailureVerified + receipt must NOT select T4 without TaskId/proof
$s1 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 3 -T3FailureVerified $true -T3FailureReceipt 'verified:task-id-1' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-KP ([string]$s1.Tier -ne 'T4') 'KP1-arbitrary-bool-receipt-no-T4' ("tier=" + [string]$s1.Tier)
# 2. FailureCount alone must NOT select T4
$s2 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 5 -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-KP ([string]$s2.Tier -ne 'T4') 'KP2-failurecount-alone-no-T4' ("tier=" + [string]$s2.Tier)
# 3. Arbitrary VerifiedFailureReceipt must NOT authorize Astra fallback
$sT4 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
# Force a T4-shaped request for fallback test without trusting receipt
$reqT4 = $sT4 | Select-Object *
$reqT4.Tier = 'T4'
$reqT4.CatalogModel = 'openai/gpt-6.1-sol'
$f1 = Resolve-OrchestrationModelFallback -RequestedSelection $reqT4 -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:task-id-1' -AttemptedModels @('openai/gpt-6.1-sol') -IgnoreUserConfig $true
Assert-KP ([string]$f1.FallbackModel -ne 'openai/gpt-6-astra') 'KP3-arbitrary-receipt-no-astra' ("fallback=" + [string]$f1.FallbackModel + " status=" + [string]$f1.Status)
# 4. Deprecated params documented as untrusted (function help/param still present for compat but ignored)
$selParams = (Get-Command Resolve-OrchestrationModelSelection).Parameters
$fbParams = (Get-Command Resolve-OrchestrationModelFallback).Parameters
Assert-KP ($selParams.ContainsKey('TaskId') -and $fbParams.ContainsKey('TaskId')) 'KP4-taskid-params-present' 'TaskId required for kernel proof'
# 5. Negative: caller claims with a TaskId but no persisted proof must NOT select T4
$s5 = Resolve-OrchestrationModelSelection -AgentName 'coder' -TaskId 'no-such-task-xyz-001' -TasksDir 'no-such-tasks-dir' -RepoRoot 'no-such-repo' -Complexity 'complex' -FailureCount 9 -T3FailureVerified $true -T3FailureReceipt 'verified:no-such-task-xyz-001' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-KP ([string]$s5.Tier -ne 'T4') 'KP5-caller-claims-with-taskid-no-proof-no-T4' ("tier=" + [string]$s5.Tier)
Assert-KP ([string]::IsNullOrWhiteSpace([string]$s5.KernelProofReference)) 'KP5-no-proof-no-kernel-ref' ("ref=" + [string]$s5.KernelProofReference)
# 6. Negative: caller-claimed Astra fallback without kernel T4 proof is never AUTHORIZED
$reqT4b = $sT4 | Select-Object *
$reqT4b.Tier = 'T4'
$reqT4b.CatalogModel = 'openai/gpt-6.1-sol'
$f6 = Resolve-OrchestrationModelFallback -RequestedSelection $reqT4b -FailedModel 'openai/gpt-6.1-sol' -AttemptedModels @('openai/gpt-6.1-sol') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:task-id-1' -TaskId 'no-such-task-xyz-001' -TasksDir 'no-such-tasks-dir' -RepoRoot 'no-such-repo' -IgnoreUserConfig $true
Assert-KP (([string]$f6.Status -cne 'AUTHORIZED') -or ([string]$f6.FallbackModel -cne 'openai/gpt-6-astra')) 'KP6-caller-claims-no-kernel-T4-no-astra' ("fallback=" + [string]$f6.FallbackModel + " status=" + [string]$f6.Status)
Write-Host ("RESULTS {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
