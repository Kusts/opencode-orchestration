<#
.SYNOPSIS
    Claude alias/model-tier routing contract (policy v1.4; deterministic, no provider calls).
.DESCRIPTION
    Planner/build primary is opencode-go/deepseek-v4.1-flash (T2, DeepSeek Go-only). Covers provider
    registration, closed Claude dispatch-alias identity (no resolved_model,
    runtime-unverified, catalog inventory provenance only), T2 Luna->DeepSeek Go->Muse->Haiku,
    T3 Sonnet->Terra, T4 Opus->Sol, technical fallbacks held absent independent
    no-start proof, functional escalation through the Task Kernel only, Astra/Fable
    exceptional gates, DeepSeek Go T2 alternative (ZDR expired-unconfirmed, no renewal claim), advisor T3 minimum, exactly-once
    execution seam, UNKNOWN subscription cost, and capability rejection.
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
Assert-HP ($p.PolicyVersion -eq '1.5.0') 'hp-policy-stays-v1.5'
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

# 3. Planner/build is DeepSeek Go T2 and has no automatic model fallback.
Assert-HP ([string]$pol.planner.primary -eq 'deepseek_go' -and [string]$pol.planner.model_id -eq 'opencode-go/deepseek-v4.1-flash' -and `
    [string]$pol.planner.provider -eq 'opencode-go' -and [string]$pol.planner.tier -eq 'T2') 'hp-planner-primary-deepseek-T2'
Assert-HP (($null -eq $pol.planner.fallback_model_id) -and (-not [bool]$pol.planner.fallback_requires_capability_proof)) 'hp-planner-no-automatic-fallback'
Assert-HP ([string]$pol.role_profiles.build.default_model -eq 'deepseek_go') 'hp-build-profile-deepseek'
$sPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-HP ($sPlanner.Tier -eq 'T2' -and $sPlanner.CatalogModel -eq 'opencode-go/deepseek-v4.1-flash' -and $sPlanner.selected_provider -eq 'opencode-go') 'hp-planner-selection-deepseek-T2'

# 4. Planner failure has no fallback ladder; caller booleans do not authorize replay.
$fbPlanner = Resolve-OrchestrationModelFallback -RequestedSelection $sPlanner -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fbPlanner.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $null -eq $fbPlanner.FallbackModel -and -not [bool]$fbPlanner.IsAuthorized) 'hp-planner-deepseek-failure-no-replay'
$fbPlannerTimeout = Resolve-OrchestrationModelFallback -RequestedSelection $sPlanner -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason 'TIMEOUT' -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-HP ($fbPlannerTimeout.FallbackModel -eq $null -and -not [bool]$fbPlannerTimeout.IsAuthorized) 'hp-planner-timeout-no-replay'

# 5. T2 generic chain Luna primary->DeepSeek Go->Muse->Haiku; ordered candidates remain audit-only HOLD.
Assert-HP ($pol.tiers.T2.primary -eq 'luna') 'hp-T2-primary-luna'
Assert-HP (([string]$pol.tiers.T2.alternatives[0] -ceq 'deepseek_go') -and ([string]$pol.tiers.T2.alternatives[1] -ceq 'muse') -and ([string]$pol.tiers.T2.alternatives[2] -ceq 'claude_haiku')) 'hp-T2-alternatives-luna-deepseek_go-muse-haiku-order'
Assert-HP ($pol.tiers.T2.fallback -eq 'muse') 'hp-T2-fallback-muse'
$sT2 = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-HP ($sT2.Tier -eq 'T2' -and $sT2.CatalogModel -eq 'openai/gpt-6-luna') 'hp-T2-default-luna'
$fT2DeepSeek = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fT2DeepSeek.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $null -eq $fT2DeepSeek.FallbackModel -and $fT2DeepSeek.CandidateModel -eq 'opencode-go/deepseek-v4.1-flash') 'hp-T2-deepseek-first-candidate-held'
$fT2Muse = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'opencode-go/deepseek-v4.1-flash' -AttemptedModels @('openai/gpt-6-luna','opencode-go/deepseek-v4.1-flash') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fT2Muse.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $null -eq $fT2Muse.FallbackModel -and $fT2Muse.CandidateModel -eq 'opencode-go/muse-spark-1.3-contributor') 'hp-T2-muse-second-candidate-held'
$fT2Haiku = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('openai/gpt-6-luna','opencode-go/deepseek-v4.1-flash','opencode-go/muse-spark-1.3-contributor') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fT2Haiku.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $null -eq $fT2Haiku.FallbackModel -and $fT2Haiku.CandidateModel -eq 'claude-agent/haiku') 'hp-T2-haiku-third-candidate-held'
$fT2Exhausted = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'claude-agent/haiku' -AttemptedModels @('openai/gpt-6-luna','opencode-go/deepseek-v4.1-flash','opencode-go/muse-spark-1.3-contributor','claude-agent/haiku') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fT2Exhausted.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $null -eq $fT2Exhausted.FallbackModel -and $null -eq $fT2Exhausted.CandidateModel -and (-not [bool]$fT2Exhausted.IsAuthorized)) 'hp-T2-alternatives-exhausted-after-primary'
$fT2Timeout = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason 'TIMEOUT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($null -eq $fT2Timeout.FallbackModel -and -not [bool]$fT2Timeout.IsAuthorized) 'hp-T2-timeout-never-replays'

# 6. DeepSeek Go remains enabled as a T2 alternative (ZDR expired-unconfirmed, no renewal claim).
Assert-HP ([bool]$pol.models.deepseek_go.enabled -eq $true) 'hp-deepseek-go-enabled'
Assert-HP ([string]$pol.models.deepseek_go.availability_status -eq 'active' -and [string]$pol.models.deepseek_go.data_policy.zdr_status -eq 'expired-unconfirmed') 'hp-deepseek-go-active-zdr-unconfirmed'

# 7. Advisor T3 minimum, Sonnet primary / Terra fallback; T2 remains inadmissible.
$advRoles = @($pol.models.claude_haiku.eligible_roles)
Assert-HP ($advRoles -notcontains 'engineering-advisor') 'hp-haiku-advisor-ineligible'
$sAdv = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-HP ($sAdv.Tier -eq 'T3' -and $sAdv.CatalogModel -eq 'claude-agent/sonnet') 'hp-advisor-starts-sonnet-T3'

# 8. T3 Sonnet->Terra candidate; T4 Opus->Sol candidate; both HOLD absent safe no-start.
$sT3 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT3Terra = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'claude-agent/sonnet' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fT3Terra.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $null -eq $fT3Terra.FallbackModel -and $fT3Terra.CandidateModel -eq 'openai/gpt-6.1-terra') 'hp-T3-terra-candidate-held'
$fT3Timeout = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'claude-agent/sonnet' -TriggerReason 'TIMEOUT' -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-HP ($null -eq $fT3Timeout.FallbackModel -and -not [bool]$fT3Timeout.IsAuthorized) 'hp-T3-timeout-never-replays'

# 9. Fable: Astra-availability only; generic receipts never authorize.
$sT4shape = $sT3 | Select-Object *
$sT4shape.Tier = 'T4'
$sT4shape.CatalogModel = 'claude-agent/opus'
$fSol = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'claude-agent/opus' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fSol.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $null -eq $fSol.FallbackModel -and $fSol.CandidateModel -eq 'openai/gpt-6.1-sol') 'hp-T4-sol-candidate-held'
$fFable = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($fFable.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $null -eq $fFable.FallbackModel -and $fFable.CandidateModel -eq 'claude-agent/fable') 'hp-fable-candidate-held-until-independent-no-start-proof'
$fFableVer = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:x' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-HP ($null -eq $fFableVer.FallbackModel -and -not [bool]$fFableVer.IsAuthorized) 'hp-fable-functional-failure-requires-kernel-model-select'

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
