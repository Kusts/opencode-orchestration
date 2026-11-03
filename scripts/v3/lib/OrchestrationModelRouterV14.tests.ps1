<#
.SYNOPSIS
    Regression contract for model router policy v1.4 (deterministic, no provider calls).
.DESCRIPTION
    New behavior assertions are intentionally independent of legacy v1.3 scenarios.
    Run: powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterV14.tests.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
$script:pass = 0; $script:fail = 0
function Assert-V14([bool]$Condition,[string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name"; $script:pass++ }
    else { Write-Host "[FAIL] $Name"; $script:fail++ }
}
$p = Get-OrchestrationModelRoutingPolicy -ForceReload $true
Assert-V14 ($p.Status -eq 'POLICY_LOADED') 'policy-loads'
Assert-V14 ($p.PolicyVersion -eq '1.4.0') 'policy-v1.4'
$pol = $p.Policy
$expectedProviders = @{
    'iceman' = @{ Provider='opencode-go'; Model='opencode-go/iceman-contributor-free' }
    'mimo' = @{ Provider='opencode'; Model='opencode/mimo-v2.6-flash-free' }
    'muse' = @{ Provider='opencode-go'; Model='opencode-go/muse-spark-1.3-contributor' }
    'deepseek_go' = @{ Provider='opencode-go'; Model='opencode-go/deepseek-v4.1-flash' }
    'luna' = @{ Provider='openai'; Model='openai/gpt-6-luna' }
    'terra' = @{ Provider='openai'; Model='openai/gpt-6.1-terra' }
    'sol' = @{ Provider='openai'; Model='openai/gpt-6.1-sol' }
    'astra' = @{ Provider='openai'; Model='openai/gpt-6-astra' }
}
foreach ($modelName in $expectedProviders.Keys) {
    $actual = $pol.models.PSObject.Properties[$modelName].Value
    $expected = $expectedProviders[$modelName]
    Assert-V14 ($null -ne $actual -and
        [string]$actual.provider -eq [string]$expected.Provider -and
        [string]$actual.model_id -eq [string]$expected.Model -and
        [string](Get-ModelProviderFromId $actual.model_id) -eq [string]$expected.Provider) "provider-and-model-id:$modelName"
}
# Disabled legacy Console DeepSeek must not be selected instead of Go DeepSeek.
Assert-V14 ($pol.models.deepseek.enabled -eq $false -and
    $pol.models.deepseek.model_id -eq 'opencode/deepseek-v4.1-flash-free') 'legacy-console-deepseek-disabled'
Assert-V14 ($pol.tiers.T1.primary -eq 'iceman') 'T1-iceman'
Assert-V14 ($pol.tiers.T1.alternatives -contains 'mimo') 'T1-mimo-fallback'
Assert-V14 ($pol.models.mimo.model_id -eq 'opencode/mimo-v2.6-flash-free') 'mimo-openCode-console-id'
Assert-V14 ($pol.tiers.T2.primary -eq 'muse') 'T2-muse'
Assert-V14 ($pol.tiers.T2.alternatives -contains 'luna') 'T2-luna-fallback'
Assert-V14 ($pol.tiers.T3.primary -eq 'terra') 'T3-terra'
Assert-V14 ($pol.tiers.T4.primary -eq 'sol') 'T4-sol'
Assert-V14 ($pol.tiers.T4.exceptional -eq 'astra') 'T4-astra'
Assert-V14 ($pol.cost_policy.t4_requires_authorization -eq $false) 'T4-auto-no-manual-cost-authorization'
Assert-V14 ($pol.planner.model_id -eq 'openai/gpt-6-luna' -and $pol.planner.tier -eq 'T2') 'planner-luna-T2'
Assert-V14 ($pol.role_profiles.tester.admissible_tiers -contains 'T1') 'tester-T1-allowed'
Assert-V14 ($pol.models.deepseek_go.model_id -eq 'opencode-go/deepseek-v4.1-flash') 'deepseek-Go-not-Console'

$sPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sPlanner.Tier -eq 'T2' -and $sPlanner.CatalogModel -eq 'openai/gpt-6-luna') 'planner-runtime-luna-T2'
$sT3 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sT3.Tier -eq 'T3' -and $sT3.CatalogModel -eq 'openai/gpt-6.1-terra') 'T3-runtime-terra'
$sT4Hold = Resolve-OrchestrationModelSelection -AgentName 'coder' -FailureCount 3 -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sT4Hold.Tier -ne 'T4') 'no-unproven-T3-failure-escalation'
$sT4 = Resolve-OrchestrationModelSelection -AgentName 'coder' -FailureCount 3 -T3FailureVerified $true -T3FailureReceipt 'verified:task-id-1' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sT4.Tier -eq 'T4' -and $sT4.CatalogModel -eq 'openai/gpt-6.1-sol') 'T3-verified-failure-auto-escalates-T4'
Assert-V14 ($sT4.Authorized -eq $true) 'T4-authorized-by-policy'

$sTesterT1 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial' -Risk 'low' -RequiresLlm $true -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sTesterT1.Tier -eq 'T1' -and $sTesterT1.CatalogModel -eq 'opencode-go/iceman-contributor-free') 'tester-trivial-LLM-uses-T1'
$sT1 = Resolve-OrchestrationModelSelection -AgentName 'explorer' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT1 = Resolve-OrchestrationModelFallback -RequestedSelection $sT1 -FailedModel 'opencode-go/iceman-contributor-free' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fT1.Status -eq 'AUTHORIZED' -and $fT1.FallbackModel -eq 'opencode/mimo-v2.6-flash-free') 'T1-on-failure-mimo'
$sT2 = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT2 = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'opencode-go/muse-spark-1.3-contributor' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fT2.Status -eq 'AUTHORIZED' -and $fT2.FallbackModel -eq 'openai/gpt-6-luna') 'T2-on-failure-luna'
$fT3 = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'openai/gpt-6.1-terra' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fT3.Status -eq 'AUTHORIZED' -and $fT3.FallbackModel -eq 'opencode-go/muse-spark-1.3-contributor' -and $fT3.FallbackTier -eq 'T2') 'T3-transport-failure-to-muse'
$fT3Go = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'openai/gpt-6.1-terra' -AttemptedModels @('openai/gpt-6.1-terra','opencode-go/muse-spark-1.3-contributor') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fT3Go.Status -eq 'AUTHORIZED' -and $fT3Go.FallbackModel -eq 'opencode-go/deepseek-v4.1-flash') 'T3-transport-failure-to-deepseek-go'
$fSolTransport = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fSolTransport.Status -eq 'AUTHORIZED' -and $fSolTransport.FallbackModel -eq 'opencode-go/muse-spark-1.3-contributor') 'T4-transport-failure-to-muse-not-astra'
$fSolQuality = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:task-id-1' -IgnoreUserConfig $true
Assert-V14 ($fSolQuality.Status -eq 'AUTHORIZED' -and $fSolQuality.FallbackModel -eq 'openai/gpt-6-astra') 'T4-proven-sol-failure-to-astra'
$fSolUnproven = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'VERIFIED_TASK_FAILURE' -IgnoreUserConfig $true
Assert-V14 ($fSolUnproven.FallbackModel -ne 'openai/gpt-6-astra') 'unproven-quality-failure-does-not-use-astra'
$sSec = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -T3FailureVerified $true -T3FailureReceipt 'verified:security-task-1' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fSec = Resolve-OrchestrationModelFallback -RequestedSelection $sSec -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fSec.FallbackModel -notin @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash')) 'security-critical-no-T2-downgrade'
# Real dispatch path: fallback only after typed proof that no execution started.
. (Join-Path $PSScriptRoot 'OrchestrationModelExecution.ps1')
$script:attemptedDispatch = @()
$dispatchWithSafeFailure = {
    param([string]$Model,[string]$Agent,[string]$TaskId)
    $script:attemptedDispatch += $Model
    if ($Model -eq 'opencode-go/muse-spark-1.3-contributor') {
        return [pscustomobject]@{ FailureClass='RATE_LIMIT'; NoExecutionStarted=$true }
    }
    return [pscustomobject]@{ Model=$Model }
}
$executedFallback = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchWithSafeFailure -TaskId 'v14-safe'
Assert-V14 ($executedFallback.status -eq 'EXECUTED_VERIFIED' -and $executedFallback.verification.ProofStatus -eq 'AUTHORIZED_FALLBACK') 'real-dispatch-verified-fallback'
Assert-V14 ($script:attemptedDispatch.Count -eq 2 -and $script:attemptedDispatch[1] -eq 'openai/gpt-6-luna') 'dispatch-uses-Luna-as-fallback'
$script:attemptedDispatch = @()
$dispatchAmbiguous = {
    param([string]$Model,[string]$Agent,[string]$TaskId)
    $script:attemptedDispatch += $Model
    return [pscustomobject]@{ FailureClass='RATE_LIMIT'; NoExecutionStarted=$false }
}
$ambiguous = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchAmbiguous -TaskId 'v14-ambiguous'
Assert-V14 ($script:attemptedDispatch.Count -eq 1 -and $ambiguous.status -ne 'EXECUTED_VERIFIED') 'ambiguous-failure-no-retry'
Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
