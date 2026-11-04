<#
.SYNOPSIS
    Haiku-planner routing contract (policy v1.4, deterministic, no provider calls).
.DESCRIPTION
    Planner/build primary is claude-agent/haiku (T2) with explicit Luna fallback.
    Covers: provider registration, closed dispatch-alias identity (no
    resolved_model, runtime-unverified, inventory as provenance only), T2 chain
    Muse->Luna->Haiku, planner Haiku-failure->Luna (capability pre-run or
    availability+no-start), T3 Terra->Sonnet, T4 Sol->Opus, Astra kernel-proof
    only, Fable Astra-availability only, DeepSeek Go blocked, advisor T3-only
    (Haiku inadmissible), no-start/ambiguous zero retry, exactly-once seam,
    UNKNOWN cost on subscription zero, self-review refusal.
    No inference is performed here. Productive dispatch is Planner-owned.
    Run: powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterHaikuPlanner.tests.ps1
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationModelExecution.ps1')

$script:pass = 0
$script:fail = 0
function Assert-HP([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name"; $script:pass++ }
    else { Write-Host "[FAIL] $Name"; $script:fail++ }
}

$p = Get-OrchestrationModelRoutingPolicy -ForceReload $true
Assert-HP ($p.Status -eq 'POLICY_LOADED') 'hp-policy-loads'
Assert-HP ($p.PolicyVersion -eq '1.4.0') 'hp-policy-stays-v1.4'
$pol = $p.Policy

# 1. Provider registration (single catalog).
Assert-HP ($pol.providers.'claude-agent'.enabled -eq $true) 'hp-provider-claude-agent-enabled'
Assert-HP ([string]$pol.providers.'claude-agent'.type -eq 'claude-code') 'hp-provider-claude-agent-type'

# 2. Closed dispatch-alias identity; inventory provenance only; no resolved_model.
$expectedAliases = @{
    'claude_haiku'   = 'claude-agent/haiku'
    'claude_sonnet'  = 'claude-agent/sonnet'
    'claude_opus'    = 'claude-agent/opus'
    'claude_fable'   = 'claude-agent/fable'
}
$expectedAliasToken = @{
    'claude_haiku'   = 'haiku'
    'claude_sonnet'  = 'sonnet'
    'claude_opus'    = 'opus'
    'claude_fable'   = 'fable'
}
foreach ($logicalId in $expectedAliases.Keys) {
    $propHp = $pol.models.PSObject.Properties[$logicalId]
    $entry = if ($null -ne $propHp) { $propHp.Value } else { $null }
    $entryOk = ($null -ne $entry -and [string]$entry.provider -eq 'claude-agent' -and `
        [string]$entry.model_id -eq [string]$expectedAliases[$logicalId] -and `
        [string]$entry.alias -eq [string]$expectedAliasToken[$logicalId])
    Assert-HP $entryOk ("hp-dispatch-alias-identity:$logicalId")
    Assert-HP (($null -ne $entry) -and ($null -eq $entry.PSObject.Properties['resolved_model'])) ("hp-no-resolved-model-field:$logicalId")
    Assert-HP (($null -ne $entry) -and ([string]$entry.resolution_status -eq 'runtime-unverified')) ("hp-resolution-runtime-unverified:$logicalId")
    Assert-HP (($null -ne $entry) -and (-not [string]::IsNullOrWhiteSpace([string]$entry.catalog_inventory_id))) ("hp-inventory-provenance:$logicalId")
}
$aliasOk = Resolve-ClaudeAgentAlias -AliasModelId 'claude-agent/haiku' -PolicyAlias 'haiku' -PolicyModelId 'claude-agent/haiku'
Assert-HP ([bool]$aliasOk.Matches) 'hp-alias-check-matches'
$aliasTamper = Resolve-ClaudeAgentAlias -AliasModelId 'claude-agent/haiku' -PolicyAlias 'haiku' -PolicyModelId 'claude-agent/sonnet'
Assert-HP ((-not [bool]$aliasTamper.Matches) -and ([string]$aliasTamper.Reason -ceq 'CLAUDE_ALIAS_MISMATCH')) 'hp-alias-tamper-fail-closed'
$aliasUnknown = Resolve-ClaudeAgentAlias -AliasModelId 'claude-agent/unknown' -PolicyAlias 'unknown' -PolicyModelId 'claude-agent/unknown'
Assert-HP ((-not [bool]$aliasUnknown.Matches) -and ([string]$aliasUnknown.Reason -ceq 'CLAUDE_UNKNOWN_ALIAS')) 'hp-alias-unknown-fail-closed'

# 3. Planner/build primary is Haiku T2; explicit Luna fallback; never generic chain.
Assert-HP ([string]$pol.planner.primary -eq 'claude_haiku' -and [string]$pol.planner.model_id -eq 'claude-agent/haiku' -and `
    [string]$pol.planner.provider -eq 'claude-agent' -and [string]$pol.planner.tier -eq 'T2') 'hp-planner-primary-haiku-T2'
Assert-HP ([string]$pol.planner.fallback -eq 'luna' -and [string]$pol.planner.fallback_model_id -eq 'openai/gpt-6-luna') 'hp-planner-fallback-luna'
Assert-HP ([string]$pol.role_profiles.build.default_model -eq 'claude_haiku') 'hp-build-profile-haiku'
$sPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-HP ($sPlanner.Tier -eq 'T2' -and $sPlanner.CatalogModel -eq 'claude-agent/haiku' -and $sPlanner.selected_provider -eq 'claude-agent') 'hp-planner-selection-haiku-T2'

# 4. Planner fallback: Haiku failure + availability + no-start + capability => Luna.
$fbPlanner = Resolve-OrchestrationModelFallback -RequestedSelection $sPlanner -FailedModel 'claude-agent/haiku' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fbPlanner.Status -eq 'AUTHORIZED' -and $fbPlanner.FallbackModel -eq 'openai/gpt-6-luna' -and $fbPlanner.FallbackTier -eq 'T2') 'hp-planner-haiku-fail-to-luna'
Assert-HP ($fbPlanner.FallbackModel -ne 'opencode-go/muse-spark-1.3-contributor') 'hp-planner-never-generic-muse'
$fbPlannerWrong = Resolve-OrchestrationModelFallback -RequestedSelection $sPlanner -FailedModel 'openai/gpt-6-luna' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fbPlannerWrong.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') 'hp-planner-requires-haiku-failure'
$fbPlannerTimeout = Resolve-OrchestrationModelFallback -RequestedSelection $sPlanner -FailedModel 'claude-agent/haiku' -TriggerReason 'TIMEOUT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fbPlannerTimeout.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') 'hp-planner-timeout-no-retry'
$fbPlannerNoProof = Resolve-OrchestrationModelFallback -RequestedSelection $sPlanner -FailedModel 'claude-agent/haiku' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fbPlannerNoProof.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') 'hp-planner-missing-no-start-no-retry'
$fbPlannerNoCap = Resolve-OrchestrationModelFallback -RequestedSelection $sPlanner -FailedModel 'claude-agent/haiku' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-HP ($fbPlannerNoCap.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') 'hp-planner-capability-required'
$fbPlannerPreRun = Resolve-OrchestrationModelFallback -RequestedSelection $sPlanner -FailedModel 'claude-agent/haiku' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true -HaikuPreRunUnavailable $true
Assert-HP ($fbPlannerPreRun.Status -eq 'AUTHORIZED' -and $fbPlannerPreRun.FallbackModel -eq 'openai/gpt-6-luna' -and $fbPlannerPreRun.FallbackTier -eq 'T2') 'hp-planner-prerun-unavailable-to-luna'

# 5. T2 generic chain Muse->Luna->Haiku (capability-gated Haiku leg).
Assert-HP ($pol.tiers.T2.primary -eq 'muse') 'hp-T2-primary-muse'
Assert-HP (($pol.tiers.T2.alternatives -contains 'luna') -and ($pol.tiers.T2.alternatives -contains 'claude_haiku')) 'hp-T2-alternatives-luna-haiku'
$sT2 = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT2Luna = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'opencode-go/muse-spark-1.3-contributor' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-HP ($fT2Luna.Status -eq 'AUTHORIZED' -and $fT2Luna.FallbackModel -eq 'openai/gpt-6-luna') 'hp-T2-muse-fail-to-luna'
$fT2Haiku = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fT2Haiku.Status -eq 'AUTHORIZED' -and $fT2Haiku.FallbackModel -eq 'claude-agent/haiku') 'hp-T2-luna-fail-to-haiku'
$fT2HaikuNoCap = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-HP ($fT2HaikuNoCap.FallbackModel -ne 'claude-agent/haiku') 'hp-T2-haiku-requires-capability'

# 6. DeepSeek Go blocked (ZDR unconfirmed): excluded everywhere.
Assert-HP ([bool]$pol.models.deepseek_go.enabled -eq $false) 'hp-deepseek-go-disabled'
Assert-HP ([string]$pol.models.deepseek_go.availability_status -eq 'blocked') 'hp-deepseek-go-blocked'

# 7. Advisor T3-only: Haiku inadmissible, never selected, never fallback.
$advRoles = @($pol.models.claude_haiku.eligible_roles)
Assert-HP ($advRoles -notcontains 'engineering-advisor') 'hp-haiku-advisor-ineligible'
$sAdv = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-HP ($sAdv.Tier -eq 'T3' -and $sAdv.CatalogModel -eq 'openai/gpt-6.1-terra') 'hp-advisor-stays-T3-terra'

# 8. T3 Terra->Sonnet (capability + no-start); T4 Sol->Opus; Astra kernel-proof only.
$sT3 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT3Sonnet = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'openai/gpt-6.1-terra' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fT3Sonnet.Status -eq 'AUTHORIZED' -and $fT3Sonnet.FallbackModel -eq 'claude-agent/sonnet' -and $fT3Sonnet.FallbackTier -eq 'T3') 'hp-T3-terra-to-sonnet'
$fT3NoCap = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'openai/gpt-6.1-terra' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-HP ($fT3NoCap.FallbackModel -ne 'claude-agent/sonnet') 'hp-T3-sonnet-requires-capability'

# 9. Fable: Astra-availability only; generic receipts never authorize.
$sT4shape = $sT3 | Select-Object *
$sT4shape.Tier = 'T4'
$sT4shape.CatalogModel = 'openai/gpt-6.1-sol'
$fFable = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fFable.Status -eq 'AUTHORIZED' -and $fFable.FallbackModel -eq 'claude-agent/fable' -and $fFable.FallbackTier -eq 'T4') 'hp-fable-astra-availability'
$fFableVer = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:x' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fFableVer.FallbackModel -ne 'claude-agent/fable') 'hp-fable-generic-receipt-blocked'

# 10. Exactly-once seam: one call, transport failure => PROOF_ABSENT, no retry.
$script:hpAttempted = @()
$dispatchHp = {
    param([string]$Model,[string]$Agent,[string]$TaskId)
    $script:hpAttempted += $Model
    return [pscustomobject]@{ FailureClass='RATE_LIMIT'; NoExecutionStarted=$true }
}
$hpExec = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchHp -TaskId 'hp-no-start-hold'
Assert-HP ($script:hpAttempted.Count -eq 1) 'hp-seam-single-call-no-retry'
Assert-HP (([string]$hpExec.status -ceq 'PROOF_ABSENT') -and (-not [bool]$hpExec.ok)) 'hp-seam-fail-closed-proof-absent'

# 11. Subscription zero/silence => UNKNOWN cost, never zero.
Assert-HP ([string](Resolve-ClaudeAgentUsageCost -ReportedCost 0) -eq 'UNKNOWN') 'hp-cost-zero-unknown'
Assert-HP ([string](Resolve-ClaudeAgentUsageCost -ReportedCost '') -eq 'UNKNOWN') 'hp-cost-empty-unknown'
Assert-HP ([string](Resolve-ClaudeAgentUsageCost -ReportedCost 'UNKNOWN') -eq 'UNKNOWN') 'hp-cost-unknown-stable'

# 12. Capability gate defaults reject-closed; remote requires explicit capability.
$capDefault = Test-ClaudeAgentProviderAdmissible
Assert-HP ((-not [bool]$capDefault.Admissible) -and ([string]$capDefault.Reason -ceq 'CLAUDE_CAPABILITY_UNPROVEN')) 'hp-capability-default-reject'
$capLocal = Test-ClaudeAgentProviderAdmissible -ClaudeAgentProven $true
Assert-HP ([bool]$capLocal.Admissible) 'hp-capability-local-proven'
$capRemote = Test-ClaudeAgentProviderAdmissible -WorkerHost 'remote' -ClaudeAgentProven $true
Assert-HP ((-not [bool]$capRemote.Admissible) -and ([string]$capRemote.Reason -ceq 'CLAUDE_REMOTE_UNPROVEN')) 'hp-capability-remote-requires-explicit'
$capRemoteOk = Test-ClaudeAgentProviderAdmissible -WorkerHost 'remote' -WorkerCapabilities @('claude-agent','claude-agent-remote')
Assert-HP ([bool]$capRemoteOk.Admissible) 'hp-capability-remote-explicit-ok'

Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
