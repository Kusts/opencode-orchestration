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
Assert-V14 ($p.PolicyVersion -eq '1.5.0') 'policy-v1.5'
$pol = $p.Policy
$expectedProviders = @{
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
Assert-V14 ($pol.tiers.T1.primary -eq 'luna') 'T1-luna'
Assert-V14 ($pol.tiers.T1.alternatives -contains 'mimo') 'T1-mimo-fallback'
Assert-V14 ($pol.models.mimo.model_id -eq 'opencode/mimo-v2.6-flash-free') 'mimo-openCode-console-id'
Assert-V14 ($pol.tiers.T2.primary -eq 'luna') 'T2-luna-primary'
Assert-V14 ($pol.tiers.T2.fallback -eq 'muse') 'T2-muse-fallback'
Assert-V14 (([string]$pol.tiers.T2.alternatives[0] -ceq 'deepseek_go') -and ([string]$pol.tiers.T2.alternatives[1] -ceq 'muse') -and ([string]$pol.tiers.T2.alternatives[2] -ceq 'claude_haiku')) 'T2-luna-deepseek_go-muse-haiku-order'
Assert-V14 (([string]$pol.models.deepseek_go.fallback_candidates[0] -ceq 'muse') -and ([string]$pol.models.deepseek_go.fallback_candidates[1] -ceq 'claude_haiku') -and ([string]$pol.models.deepseek_go.fallback_candidates[2] -ceq 'luna')) 'T2-deepseek-model-fallback-order'
Assert-V14 (([string]$pol.models.muse.fallback_candidates[0] -ceq 'claude_haiku') -and ([string]$pol.models.muse.fallback_candidates[1] -ceq 'luna')) 'T2-muse-model-fallback-order'
Assert-V14 ($pol.tiers.T3.primary -eq 'claude_sonnet' -and $pol.tiers.T3.fallback -eq 'terra') 'T3-sonnet-terra-fallback'
Assert-V14 ($pol.tiers.T4.primary -eq 'claude_opus' -and $pol.tiers.T4.fallback -eq 'sol') 'T4-opus-sol-fallback'
Assert-V14 ($pol.tiers.T4.exceptional -eq 'astra') 'T4-astra'
Assert-V14 ($pol.cost_policy.t4_requires_authorization -eq $false) 'T4-auto-no-manual-cost-authorization'
Assert-V14 ([bool]$pol.cost_policy.astra_requires_exceptional_authorization -eq $true) 'astra-requires-exceptional-budget-authorization'
Assert-V14 ([bool]$pol.models.astra.cost_profile.exceptional_budget_required -eq $true) 'astra-cost-profile-exceptional-budget-required'
Assert-V14 ([bool]$pol.models.astra.cost_profile.requires_authorization -eq $false) 'astra-no-generic-per-call-auth'
Assert-V14 (@($pol.advisor.exceptional_conditions) -contains 'budget_authorized') 'advisor-exceptional-conditions-include-budget-authorized'
Assert-V14 ($pol.planner.primary -eq 'deepseek_go' -and $pol.planner.model_id -eq 'opencode-go/deepseek-v4.1-flash' -and $pol.planner.provider -eq 'opencode-go' -and $pol.planner.tier -eq 'T2' -and $null -eq $pol.planner.fallback_model_id) 'planner-deepseek-T2-no-auto-fallback'
Assert-V14 ($pol.role_profiles.tester.admissible_tiers -contains 'T1') 'tester-T1-allowed'
Assert-V14 ($pol.models.deepseek_go.model_id -eq 'opencode-go/deepseek-v4.1-flash') 'deepseek-Go-not-Console'
Assert-V14 ([bool]$pol.models.deepseek_go.enabled -eq $true -and [string]$pol.models.deepseek_go.availability_status -eq 'active') 'deepseek-go-operator-enabled-active'
Assert-V14 ([string]$pol.models.deepseek_go.data_policy.zdr_status -eq 'expired-unconfirmed' -and ([string]$pol.models.deepseek_go.data_policy.zdr_note -match '2026-11-04') -and ([string]$pol.models.deepseek_go.data_policy.zdr_note -match 'renewal')) 'deepseek-go-zdr-note-operator-selected-no-renewal-claim'
Assert-V14 ([string]$pol.models.claude_haiku.resolution_status -eq 'runtime-unverified' -and [string]$pol.models.claude_sonnet.resolution_status -eq 'runtime-unverified' -and [string]$pol.models.claude_opus.resolution_status -eq 'runtime-unverified' -and [string]$pol.models.claude_fable.resolution_status -eq 'runtime-unverified') 'alias-resolution-runtime-unverified'

$sPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sPlanner.Tier -eq 'T2' -and $sPlanner.CatalogModel -eq 'opencode-go/deepseek-v4.1-flash' -and $sPlanner.selected_provider -eq 'opencode-go') 'planner-runtime-deepseek-T2'
# T2 primary Luna: catalog default; DeepSeek/Muse/Haiku remain ordered candidates.
$catT2 = Resolve-CatalogModel -Tier 'T2' -IgnoreUserConfig $true
Assert-V14 ($catT2.CatalogModel -eq 'openai/gpt-6-luna' -and $catT2.Provider -eq 'openai') 'T2-catalog-default-luna-provider'
$fcT2 = @($catT2.FallbackCandidates)
Assert-V14 (($fcT2 -contains 'opencode-go/deepseek-v4.1-flash') -and ($fcT2 -contains 'opencode-go/muse-spark-1.3-contributor') -and ([Array]::IndexOf($fcT2,'opencode-go/deepseek-v4.1-flash') -lt [Array]::IndexOf($fcT2,'opencode-go/muse-spark-1.3-contributor'))) 'T2-candidates-deepseek-before-muse'
Assert-V14 ([string]$pol.role_profiles.coder.default_model -eq 'luna' -and [string]$pol.role_profiles.'frontend-engineer'.default_model -eq 'luna') 'T2-roles-default-luna'
Assert-V14 ([string]$pol.models.deepseek_go.provider -eq 'opencode-go' -and $pol.models.deepseek.enabled -eq $false) 'legacy-console-free-disabled-go-enabled'
$loopModels = @('deepseek_go','muse','claude_haiku','luna')
$loopOk = $true
foreach ($lm in $loopModels) { $fb = @($pol.models.$lm.fallback_candidates); if ($fb -contains $lm) { $loopOk = $false } }
Assert-V14 ($loopOk -and (@($pol.models.luna.fallback_candidates).Count -eq 0)) 'T2-fallback-no-self-loop-luna-terminal'
$sT3 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sT3.Tier -eq 'T3' -and $sT3.CatalogModel -eq 'claude-agent/sonnet') 'T3-runtime-sonnet'
$sT4Hold = Resolve-OrchestrationModelSelection -AgentName 'coder' -FailureCount 3 -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sT4Hold.Tier -ne 'T4') 'no-unproven-T3-failure-escalation'
# DEPRECATED_UNTRUSTED: arbitrary bool/string never authorizes T4 without kernel-owned proof.
# Complexity=complex keeps T3 via role policy (not via FailureCount/receipt).
$sT4 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 3 -T3FailureVerified $true -T3FailureReceipt 'verified:task-id-1' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sT4.Tier -ne 'T4') 'arbitrary-T3-receipt-does-not-escalate-T4'
Assert-V14 ($sT4.Tier -eq 'T3') 'arbitrary-T3-receipt-fail-closed-T3'
# v1.4 matrix: FailureCount never promotes Coder/Advisor; T2 exhaustion never upgrades to T3.
$sCoderLowFc5 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'low' -Complexity 'simple' -FailureCount 5 -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sCoderLowFc5.Tier -eq 'T2' -and $sCoderLowFc5.CatalogModel -eq 'openai/gpt-6-luna') 'failurecount-never-promotes-coder'
$sAdvLowFc5 = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple' -FailureCount 5 -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sAdvLowFc5.Tier -eq 'T3' -and $sAdvLowFc5.CatalogModel -eq 'claude-agent/sonnet') 'failurecount-never-promotes-advisor'
# ROUTER-V14-ADVISOR-T3-ONLY: advisor remains T3-minimum; new matrix starts at
# Sonnet and keeps Terra as fallback. T2 remains prohibited; T4 proof-gated.
# Canonical registry contract (catches drift): role profile must pin
# default_model=claude_sonnet/default_tier=T3 with admissible exactly T3/T4 (no T2).
$advProfile = $pol.role_profiles.PSObject.Properties['engineering-advisor'].Value
$advAdmissible = @($advProfile.admissible_tiers)
$advProhibited = @($advProfile.prohibited_tiers)
Assert-V14 ([string]$advProfile.default_model -eq 'claude_sonnet' -and [string]$advProfile.default_tier -eq 'T3' -and ($advAdmissible -contains 'T3') -and ($advAdmissible -contains 'T4') -and -not ($advAdmissible -contains 'T2') -and $advAdmissible.Count -eq 2 -and ($advProhibited -contains 'T2')) 'advisor-registry-T3-sonnet-only-no-T2'
$sAdvSimpleFc0 = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple' -FailureCount 0 -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sAdvSimpleFc0.Tier -eq 'T3' -and $sAdvSimpleFc0.CatalogModel -eq 'claude-agent/sonnet') 'advisor-simple-low-always-T3-sonnet'
$sT2Base = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT2Exhausted = Resolve-OrchestrationModelFallback -RequestedSelection $sT2Base -FailedModel 'opencode-go/deepseek-v4.1-flash' -AttemptedModels @('opencode-go/deepseek-v4.1-flash','opencode-go/muse-spark-1.3-contributor','claude-agent/haiku','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fT2Exhausted.Status -in @('FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF','EXHAUSTED_NO_ELIGIBLE_FALLBACK') -and $fT2Exhausted.FallbackModel -eq $null -and -not [bool]$fT2Exhausted.IsAuthorized) 't2-exhausted-no-replay-without-no-start-proof'

# ROUTER-V14-FALLBACK-POLICY-METADATA (reviewer MEDIUM): canonical registry must
# explicitly record no T1/T2 upward transport rule and T3/T4 eligible-role-only T2 downgrade.
$fbProhibitionsV14 = @($pol.fallback_policy.prohibitions)
$fbProhibitedDownV14 = @($pol.fallback_policy.prohibited_downgrades)
Assert-V14 (($fbProhibitionsV14 -contains 't1_transport_escalation_prohibited') -and ($fbProhibitionsV14 -contains 't2_transport_escalation_prohibited')) 'fallback-prohibitions-t1-t2-no-upward-escalation'
Assert-V14 (($fbProhibitedDownV14 -contains 'reviewer_high_critical') -and ($fbProhibitedDownV14 -notcontains 'reviewer') -and ($fbProhibitedDownV14 -contains 'security-reviewer') -and ($fbProhibitedDownV14 -contains 'engineering-advisor') -and ($fbProhibitedDownV14 -contains 'architect')) 'fallback-prohibited-downgrades-risk-qualified-reviewer-plus-architect'
Assert-V14 ([double]$pol.tiers.T2.relative_cost -eq 0.15 -and [double]$pol.models.deepseek_go.cost_profile.relative_cost -eq 0.15) 'T2-relative-cost-matches-deepseek-primary'
Assert-V14 (([string]$pol.tiers.T1.description -match 'never') -and ([string]$pol.tiers.T1.description -match 'upgrade') -and ([string]$pol.tiers.T1.description -match 'same-tier')) 'T1-description-no-upward-transport'
Assert-V14 (([string]$pol.tiers.T2.description -match 'never') -and ([string]$pol.tiers.T2.description -match 'upgrade') -and ([string]$pol.tiers.T2.description -match 'same-tier')) 'T2-description-no-upward-transport'
Assert-V14 (([string]$pol.tiers.T3.description -match 'only') -and ([string]$pol.tiers.T3.description -match 'admissible') -and ([string]$pol.tiers.T3.description -match 'T2')) 'T3-description-eligible-role-only-T2'
Assert-V14 (([string]$pol.tiers.T4.description -match 'Opus') -and ([string]$pol.tiers.T4.description -match 'Sol') -and ([string]$pol.tiers.T4.description -match 'DeepSeek') -and ([string]$pol.tiers.T4.description -match 'Muse') -and ([string]$pol.tiers.T4.description -match 'audit-only')) 'T4-description-Opus-Sol-plus-audit-only-T2-candidates'

$sTesterT1 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial' -Risk 'low' -RequiresLlm $true -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sTesterT1.Tier -eq 'T1' -and $sTesterT1.CatalogModel -eq 'openai/gpt-6-luna') 'tester-trivial-LLM-uses-T1'
$sT1 = Resolve-OrchestrationModelSelection -AgentName 'explorer' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT1 = Resolve-OrchestrationModelFallback -RequestedSelection $sT1 -FailedModel 'openai/gpt-6-luna' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fT1.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT1.FallbackModel -eq $null -and $fT1.CandidateModel -eq 'opencode/mimo-v2.6-flash-free') 'T1-mimo-order-audit-only-hold'
$sT2 = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT2 = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -ClaudeAgentProven $true -IgnoreUserConfig $true
Assert-V14 ($fT2.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT2.FallbackModel -eq $null -and $fT2.CandidateModel -eq 'opencode-go/muse-spark-1.3-contributor') 'T2-muse-order-audit-only-hold'
$fT3 = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'claude-agent/sonnet' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -ClaudeAgentProven $true -IgnoreUserConfig $true
Assert-V14 ($fT3.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT3.FallbackModel -eq $null -and $fT3.CandidateModel -eq 'openai/gpt-6.1-terra') 'T3-terra-order-audit-only-hold'
$fT3Go = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'claude-agent/sonnet' -AttemptedModels @('claude-agent/sonnet','openai/gpt-6.1-terra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT3Go.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT3Go.FallbackModel -eq $null -and $fT3Go.CandidateModel -eq 'opencode-go/deepseek-v4.1-flash') 'T3-deepseek-first-before-muse'
$fT3GoCap = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'claude-agent/sonnet' -AttemptedModels @('claude-agent/sonnet','openai/gpt-6.1-terra','opencode-go/deepseek-v4.1-flash') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT3GoCap.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT3GoCap.FallbackModel -eq $null -and $fT3GoCap.CandidateModel -eq 'opencode-go/muse-spark-1.3-contributor') 'T3-muse-second-after-deepseek'
# Debugger is T2-admissible: T3 Sonnet/Terra exhaustion yields DeepSeek Go T2 HOLD.
$sT3Dbg = Resolve-OrchestrationModelSelection -AgentName 'debugger' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT3Dbg = Resolve-OrchestrationModelFallback -RequestedSelection $sT3Dbg -FailedModel 'claude-agent/sonnet' -AttemptedModels @('claude-agent/sonnet','openai/gpt-6.1-terra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT3Dbg.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT3Dbg.FallbackModel -eq $null -and -not [bool]$fT3Dbg.IsAuthorized -and $fT3Dbg.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $fT3Dbg.FallbackTier -ceq 'T2') 'T3-debugger-deepseek-audit-only'
# Debugger T4 Opus/Sol exhaustion likewise yields DeepSeek Go T2 HOLD.
$sT4DbgShape = $sT3Dbg | Select-Object *
$sT4DbgShape.Tier = 'T4'; $sT4DbgShape.CatalogModel = 'claude-agent/opus'
$fT4Dbg = Resolve-OrchestrationModelFallback -RequestedSelection $sT4DbgShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT4Dbg.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT4Dbg.FallbackModel -eq $null -and -not [bool]$fT4Dbg.IsAuthorized -and $fT4Dbg.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $fT4Dbg.FallbackTier -ceq 'T2') 'T4-debugger-deepseek-audit-only'
Assert-V14 ((@($pol.role_profiles.debugger.admissible_tiers) -contains 'T2') -and (@($pol.role_profiles.debugger.prohibited_tiers) -notcontains 'T2')) 'debugger-profile-contains-T2'
$sT3MedRev = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk medium -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT3MedRev = Resolve-OrchestrationModelFallback -RequestedSelection $sT3MedRev -FailedModel 'claude-agent/sonnet' -AttemptedModels @('claude-agent/sonnet','openai/gpt-6.1-terra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT3MedRev.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT3MedRev.FallbackModel -eq $null -and -not [bool]$fT3MedRev.IsAuthorized -and $fT3MedRev.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $fT3MedRev.FallbackTier -ceq 'T2') 'T3-medium-reviewer-deepseek-audit-only'
$vT3MedRevHold = Test-ExecutedModelVerification -RequestedSelection $sT3MedRev -ExecutedModelEvent @{ Model = $fT3MedRev.CandidateModel; AuthorizedFallback = $fT3MedRev } -NativeModelOverrideProven $true
Assert-V14 ($vT3MedRevHold.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and -not [bool]$vT3MedRevHold.VerifiedMatch) 'reviewer-medium-hold-candidate-never-verifies-authorized-fallback'
$sT4shape = $sT3 | Select-Object *
$sT4shape.Tier = 'T4'
$sT4shape.CatalogModel = 'claude-agent/opus'
$fSolTransport = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'claude-agent/opus' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fSolTransport.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fSolTransport.FallbackModel -eq $null -and $fSolTransport.CandidateModel -eq 'openai/gpt-6.1-sol') 'T4-sol-order-audit-only-hold'
$fSolOpus = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'claude-agent/opus' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fSolOpus.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fSolOpus.FallbackModel -eq $null) 'T4-caller-no-start-boolean-not-proof'
# 2026-11-04 addendum: T4 transport may enumerate policy-level T2 candidates
# (DeepSeek Go then Muse) strictly audit/HOLD for T2-admissible roles; never
# executes/replays; critical reviewer and T2-prohibited roles still fail closed.
$sT4CoderShape = $sT3 | Select-Object *
$sT4CoderShape.Tier = 'T4'; $sT4CoderShape.CatalogModel = 'claude-agent/opus'
$fT4Deep = Resolve-OrchestrationModelFallback -RequestedSelection $sT4CoderShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT4Deep.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT4Deep.FallbackModel -eq $null -and -not [bool]$fT4Deep.IsAuthorized -and $fT4Deep.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $fT4Deep.FallbackTier -ceq 'T2') 'T4-deepseek-first-audit-only-for-admissible-coder'
$fT4Muse = Resolve-OrchestrationModelFallback -RequestedSelection $sT4CoderShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol','opencode-go/deepseek-v4.1-flash') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT4Muse.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT4Muse.FallbackModel -eq $null -and -not [bool]$fT4Muse.IsAuthorized -and $fT4Muse.CandidateModel -ceq 'opencode-go/muse-spark-1.3-contributor' -and $fT4Muse.FallbackTier -ceq 'T2') 'T4-muse-second-audit-only-for-admissible-coder'
$sT4CritRev = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk high -IgnoreUserConfig $true -NativeModelOverrideProven $true
$sT4CritRevShape = $sT4CritRev | Select-Object *
$sT4CritRevShape.Tier = 'T4'; $sT4CritRevShape.CatalogModel = 'claude-agent/opus'
$fT4CritRev = Resolve-OrchestrationModelFallback -RequestedSelection $sT4CritRevShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT4CritRev.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $fT4CritRev.FallbackModel) 'T4-critical-reviewer-never-produces-T2-candidate'
$sT4AdvShape = $sT4CoderShape | Select-Object *
$sT4AdvShape.Agent = 'engineering-advisor'
$fT4Adv = Resolve-OrchestrationModelFallback -RequestedSelection $sT4AdvShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT4Adv.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $fT4Adv.FallbackModel) 'T4-advisor-never-produces-T2-candidate'
$sT4SecShape = $sT4CoderShape | Select-Object *
$sT4SecShape.Agent = 'security-reviewer'
$fT4Sec = Resolve-OrchestrationModelFallback -RequestedSelection $sT4SecShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT4Sec.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $fT4Sec.FallbackModel) 'T4-security-never-produces-T2-candidate'
$sT4LowRev = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk low -Complexity simple -IgnoreUserConfig $true -NativeModelOverrideProven $true
$sT4LowRevShape = $sT4LowRev | Select-Object *
$sT4LowRevShape.Tier = 'T4'; $sT4LowRevShape.CatalogModel = 'claude-agent/opus'
$fT4LowRev = Resolve-OrchestrationModelFallback -RequestedSelection $sT4LowRevShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT4LowRev.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT4LowRev.FallbackModel -eq $null -and -not [bool]$fT4LowRev.IsAuthorized -and $fT4LowRev.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $fT4LowRev.FallbackTier -ceq 'T2') 'T4-low-reviewer-deepseek-audit-only'
$sT4MedRev = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk medium -IgnoreUserConfig $true -NativeModelOverrideProven $true
$sT4MedRevShape = $sT4MedRev | Select-Object *
$sT4MedRevShape.Tier = 'T4'; $sT4MedRevShape.CatalogModel = 'claude-agent/opus'
$fT4MedRev = Resolve-OrchestrationModelFallback -RequestedSelection $sT4MedRevShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fT4MedRev.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fT4MedRev.FallbackModel -eq $null -and -not [bool]$fT4MedRev.IsAuthorized -and $fT4MedRev.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $fT4MedRev.FallbackTier -ceq 'T2') 'T4-medium-reviewer-deepseek-audit-only'
# Forged-input guard: synthetic contradictory reviewer T2 selection (canonical
# selection is T3 for high/critical) must reject before same-tier enumeration.
$selForgedT2High = [pscustomobject]@{ Agent='reviewer'; Tier='T2'; CatalogModel='opencode-go/deepseek-v4.1-flash'; Risk='high'; Provider='opencode-go'; RequestedModel='opencode-go/deepseek-v4.1-flash' }
$fForgedT2High = Resolve-OrchestrationModelFallback -RequestedSelection $selForgedT2High -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fForgedT2High.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $fForgedT2High.FallbackModel -and $null -eq $fForgedT2High.CandidateModel -and -not [bool]$fForgedT2High.IsAuthorized) 'forged-reviewer-T2-high-rejected-no-candidate'
$selForgedT2Crit = [pscustomobject]@{ Agent='reviewer'; Tier='T2'; CatalogModel='opencode-go/deepseek-v4.1-flash'; Risk='critical'; Provider='opencode-go'; RequestedModel='opencode-go/deepseek-v4.1-flash' }
$fForgedT2Crit = Resolve-OrchestrationModelFallback -RequestedSelection $selForgedT2Crit -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-V14 ($fForgedT2Crit.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $fForgedT2Crit.FallbackModel -and $null -eq $fForgedT2Crit.CandidateModel -and -not [bool]$fForgedT2Crit.IsAuthorized) 'forged-reviewer-T2-critical-rejected-no-candidate'
Assert-V14 (([bool]$pol.models.deepseek_go.data_policy.sensitive_data_allowed -eq $false) -and ([string]$pol.models.deepseek_go.data_policy.zdr_note -match 'non-sensitive') -and ([string]$pol.models.deepseek_go.data_policy.zdr_note -match 'requires ZDR')) 'deepseek-go-sensitive-data-not-allowed-zdr-unconfirmed'
# Defensive catalog (missing/invalid policy) still audits the ordered T2
# candidates without enabling dispatch: DeepSeek, Muse, Haiku, Luna.
$badPolPathV14 = Join-Path ([IO.Path]::GetTempPath()) ('v14-missing-policy-' + [guid]::NewGuid().ToString('N') + '.json')
$selT2BadPol = [pscustomobject]@{ Agent='coder'; Tier='T2'; CatalogModel='opencode-go/deepseek-v4.1-flash'; Risk='medium'; Provider='opencode-go'; RequestedModel='opencode-go/deepseek-v4.1-flash' }
$fBadPol = Resolve-OrchestrationModelFallback -RequestedSelection $selT2BadPol -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -PolicyPath $badPolPathV14
Assert-V14 ($fBadPol.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fBadPol.FallbackModel -eq $null -and -not [bool]$fBadPol.IsAuthorized -and $fBadPol.CandidateModel -ceq 'opencode-go/muse-spark-1.3-contributor') 'defensive-catalog-T2-muse-second-audit-only'
$catBadPol = Resolve-CatalogModel -Tier 'T2' -PolicyPath $badPolPathV14 -IgnoreUserConfig $true
Assert-V14 ((@($catBadPol.FallbackCandidates)[0] -ceq 'openai/gpt-6-luna') -and (@($catBadPol.FallbackCandidates)[1] -ceq 'opencode-go/deepseek-v4.1-flash') -and (@($catBadPol.FallbackCandidates)[2] -ceq 'opencode-go/muse-spark-1.3-contributor') -and (@($catBadPol.FallbackCandidates)[3] -ceq 'claude-agent/haiku')) 'defensive-catalog-T2-order-luna-deepseek-muse-haiku'
Assert-V14 ((@($pol.models.deepseek_go.eligible_roles) -contains 'build') -and (@($pol.models.deepseek_go.eligible_roles) -notcontains 'engineering-advisor')) 'deepseek-eligible-build-not-advisor'
Assert-V14 ((@($pol.models.muse.eligible_roles) -notcontains 'build') -and (@($pol.models.muse.eligible_roles) -notcontains 'engineering-advisor')) 'muse-not-eligible-build-advisor'
Assert-V14 ((@($pol.models.deepseek_go.eligible_roles) -contains 'coder') -and (@($pol.models.deepseek_go.eligible_roles) -contains 'reviewer') -and (@($pol.models.deepseek_go.eligible_roles) -contains 'debugger') -and (@($pol.models.deepseek_go.eligible_roles) -contains 'skeptic')) 'deepseek-eligible-coder-reviewer-debugger-skeptic'
Assert-V14 ((@($pol.models.muse.eligible_roles) -contains 'coder') -and (@($pol.models.muse.eligible_roles) -contains 'reviewer') -and (@($pol.models.muse.eligible_roles) -contains 'debugger') -and (@($pol.models.muse.eligible_roles) -contains 'skeptic')) 'muse-eligible-coder-reviewer-debugger-skeptic'
# Astra technical fallback stays audit HOLD whether or not the dedicated
# exceptional budget authorization is present: no caller boolean is proof
# and setting the authorization never yields an executable fallback.
$prevAstraHold = [string]$env:OPENCODE_ASTRA_AUTHORIZED
try {
    Remove-Item Env:\OPENCODE_ASTRA_AUTHORIZED -ErrorAction SilentlyContinue
    $fAstraHoldOff = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'claude-agent/opus' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true -ClaudeAgentProven $true
    Assert-V14 ($fAstraHoldOff.FallbackModel -eq $null -and -not [bool]$fAstraHoldOff.IsAuthorized) 'astra-technical-fallback-hold-without-exceptional-auth'
    $env:OPENCODE_ASTRA_AUTHORIZED = 'true'
    $fAstraHoldOn = Resolve-OrchestrationModelFallback -RequestedSelection $sT4shape -FailedModel 'claude-agent/opus' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true -ClaudeAgentProven $true
    Assert-V14 ($fAstraHoldOn.FallbackModel -eq $null -and -not [bool]$fAstraHoldOn.IsAuthorized) 'astra-technical-fallback-hold-with-exceptional-auth'
} finally {
    if (-not [string]::IsNullOrEmpty($prevAstraHold)) { $env:OPENCODE_ASTRA_AUTHORIZED = $prevAstraHold } else { Remove-Item Env:\OPENCODE_ASTRA_AUTHORIZED -ErrorAction SilentlyContinue }
}
$fSolQuality = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -AttemptedModels @('openai/gpt-6.1-sol') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:task-id-1' -IgnoreUserConfig $true
Assert-V14 ($fSolQuality.Status -eq 'KERNEL_MODEL_SELECT_REQUIRED' -and $fSolQuality.FallbackModel -ne 'openai/gpt-6-astra') 'functional-failure-requires-kernel-model-select-not-receipt'
$fSolUnproven = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'VERIFIED_TASK_FAILURE' -IgnoreUserConfig $true
Assert-V14 ($fSolUnproven.Status -eq 'KERNEL_MODEL_SELECT_REQUIRED' -and $fSolUnproven.FallbackModel -ne 'openai/gpt-6-astra') 'functional-failure-held-for-task-kernel-proof'
$sSec = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -T3FailureVerified $true -T3FailureReceipt 'verified:security-task-1' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sSec.Tier -eq 'T3') 'security-arbitrary-receipt-stays-T3'
$fSec = Resolve-OrchestrationModelFallback -RequestedSelection $sSec -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fSec.FallbackModel -notin @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash')) 'security-critical-no-T2-downgrade'
# No-start boolean from the seam is an untrusted caller signal, never proof.
# No retry, no automatic fallback: exactly one call, PROOF_ABSENT hold.
. (Join-Path $PSScriptRoot 'OrchestrationModelExecution.ps1')
$script:attemptedDispatch = @()
$dispatchWithSafeFailure = {
    param([string]$Model,[string]$Agent,[string]$TaskId)
    $script:attemptedDispatch += $Model
    return [pscustomobject]@{ FailureClass='RATE_LIMIT'; NoExecutionStarted=$true }
}
$noStartHold = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchWithSafeFailure -TaskId 'v14-no-start-hold'
Assert-V14 ($script:attemptedDispatch.Count -eq 1) 'no-start-boolean-single-call-no-retry'
Assert-V14 ($noStartHold.status -ceq 'PROOF_ABSENT' -and $noStartHold.status -cne 'EXECUTED_VERIFIED') 'no-start-boolean-no-executed-verified'
Assert-V14 (([string]$noStartHold.reason -ceq 'transport-failure-no-proof') -and (-not [bool]$noStartHold.ok)) 'no-start-boolean-hold-fail-closed'
$script:attemptedDispatch = @()
$dispatchAmbiguous = {
    param([string]$Model,[string]$Agent,[string]$TaskId)
    $script:attemptedDispatch += $Model
    return [pscustomobject]@{ FailureClass='RATE_LIMIT'; NoExecutionStarted=$false }
}
$ambiguous = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchAmbiguous -TaskId 'v14-ambiguous'
Assert-V14 ($script:attemptedDispatch.Count -eq 1 -and $ambiguous.status -ne 'EXECUTED_VERIFIED') 'ambiguous-failure-no-retry'
# model-select error classes (ROUTER-V14-NO-START-FAIL-CLOSED): import failure
# => MODEL_ROUTER_LOAD_FAILED, selection failure => MODEL_SELECTION_FAILED,
# never INTERNAL_ERROR collapse and never an exception body/path. Live CLI
# divergent PolicyPath is refused before IO (read-only, no store mutation);
# static scan pins the structured codes in the CLI source (no dispatch).
$cliPs1V14 = Join-Path (Split-Path -Parent $PSScriptRoot) 'task-kernel.ps1'
$altPolV14 = Join-Path ([IO.Path]::GetTempPath()) ('v14-alt-model-policy-' + [guid]::NewGuid().ToString('N') + '.json')
[IO.File]::WriteAllText($altPolV14, '{}', [Text.UTF8Encoding]::new($false))
$cliRawAltPolV14 = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1V14 -Action model-select -TaskId 'v14-no-such-task' -AttemptRole coder -PolicyPath $altPolV14 2>&1
$codeAltPolV14 = $LASTEXITCODE
$cliOutAltPolV14 = ($cliRawAltPolV14 | Out-String)
$cliDocAltPolV14 = ($cliOutAltPolV14 | ConvertFrom-Json -ErrorAction Stop)
Assert-V14 ((([string]$cliDocAltPolV14.error -ceq 'TRUSTED_PATH_MISMATCH') -and ([string]$cliDocAltPolV14.path_role -ceq 'model_policy') -and ($cliOutAltPolV14 -notmatch [regex]::Escape($altPolV14)) -and ([int]$codeAltPolV14 -ne 0))) 'model-select-divergent-policypath-refused-before-io'
try { Remove-Item -LiteralPath $altPolV14 -Force -ErrorAction SilentlyContinue } catch { }
$routerFailureRootV14 = Join-Path ([IO.Path]::GetTempPath()) ('v14-router-load-failure-' + [guid]::NewGuid().ToString('N'))
try {
    $routerFailureV3V14 = Join-Path $routerFailureRootV14 'scripts\v3'
    $routerFailureLibV14 = Join-Path $routerFailureV3V14 'lib'
    $routerFailureTasksV14 = Join-Path $routerFailureRootV14 'cache\runtime\tasks'
    New-Item -ItemType Directory -Path $routerFailureLibV14,$routerFailureTasksV14 -Force | Out-Null
    Copy-Item -LiteralPath $cliPs1V14 -Destination $routerFailureV3V14
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1') -Destination $routerFailureLibV14
    $routerFailureTaskV14 = [ordered]@{ task_id='v14-router-load-001'; revision=1; state='DISCOVERING'; runtime=[ordered]@{ profile='v2'; version='2.2.5' } }
    [IO.File]::WriteAllText((Join-Path $routerFailureTasksV14 'v14-router-load-001.json'), ($routerFailureTaskV14 | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    # Deliberately omit OrchestrationModelRouter.ps1 from this isolated CLI root.
    $routerFailureRawV14 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $routerFailureV3V14 'task-kernel.ps1') -Action model-select -TaskId 'v14-router-load-001' -AttemptRole coder 2>&1
    $routerFailureExitV14 = $LASTEXITCODE
    $routerFailureOutV14 = ($routerFailureRawV14 | Out-String)
    $routerFailureDocV14 = ($routerFailureOutV14 | ConvertFrom-Json -ErrorAction Stop)
    Assert-V14 ((([string]$routerFailureDocV14.error -ceq 'MODEL_ROUTER_LOAD_FAILED') -and ([int]$routerFailureExitV14 -ne 0) -and ($routerFailureOutV14 -notmatch [regex]::Escape($routerFailureRootV14)))) 'model-select-router-import-failure-structured-and-sanitized'
} finally {
    try { if (Test-Path -LiteralPath $routerFailureRootV14) { Remove-Item -LiteralPath $routerFailureRootV14 -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
# PR207-COST-POLICY-FALLBACK-GATE: cost_profile fail-closed (no provider calls).
# Temp policy copy flips luna.requires_authorization and deepseek_go.exceptional flag;
# committed registry stays all-false. Both gates must exclude without AUTHORIZED.
$costGatePolPath = Join-Path ([IO.Path]::GetTempPath()) ('v14-cost-gate-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    # Resolve from the script location, not the cwd: CI invokes this suite from other directories.
    $costBasePolPathV14 = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json'))
    $costBaseRaw = [IO.File]::ReadAllText($costBasePolPathV14, [Text.UTF8Encoding]::UTF8)
    $costBasePol = ($costBaseRaw | ConvertFrom-Json -ErrorAction Stop)
    $costBasePol.models.luna.cost_profile.requires_authorization = $true
    # Operator-selected DeepSeek Go primary: enable only the isolated test copy
    # for the exceptional-budget gate exercise.
    $costBasePol.models.deepseek_go.enabled = $true
    $costBasePol.models.deepseek_go.availability_status = 'active'
    if ($null -ne $costBasePol.models.deepseek_go.PSObject.Properties['availability_reason']) { $costBasePol.models.deepseek_go.PSObject.Properties.Remove('availability_reason') }
    $costBasePol.models.deepseek_go.cost_profile.requires_authorization = $false
    $costBasePol.models.deepseek_go.cost_profile | Add-Member -NotePropertyName 'exceptional_budget_required' -NotePropertyValue $true -Force
    [IO.File]::WriteAllText($costGatePolPath, ($costBasePol | ConvertTo-Json -Depth 16 -Compress), [Text.UTF8Encoding]::new($false))
    $sCostGate = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
    $prevT4Auth = [string]$env:OPENCODE_T4_AUTHORIZED
    $prevAstraAuth = [string]$env:OPENCODE_ASTRA_AUTHORIZED
    try {
        Remove-Item Env:\OPENCODE_T4_AUTHORIZED -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENCODE_ASTRA_AUTHORIZED -ErrorAction SilentlyContinue
        $fCostReq = Resolve-OrchestrationModelFallback -RequestedSelection $sCostGate -FailedModel 'opencode-go/muse-spark-1.3-contributor' -TriggerReason 'RATE_LIMIT' -ProviderCostAuthorized $false -IgnoreUserConfig $true -PolicyPath $costGatePolPath
        $costExcl = @($fCostReq.PreventivelyExcluded | Where-Object { [string]$_.Model -eq 'openai/gpt-6-luna' -and [string]$_.Reason -ceq 'COST_AUTHORIZATION_REQUIRED' })
        Assert-V14 (($fCostReq.FallbackModel -ne 'openai/gpt-6-luna' -and $costExcl.Count -ge 1) -and -not ($fCostReq.Status -eq 'AUTHORIZED' -and [bool]$fCostReq.ProviderCostAuthorized -and [string]$fCostReq.FallbackModel -eq 'openai/gpt-6-luna')) 'cost-profile-requires-authorization-excluded-fail-closed'
        $fExcReq = Resolve-OrchestrationModelFallback -RequestedSelection $sCostGate -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -ProviderCostAuthorized $false -IgnoreUserConfig $true -PolicyPath $costGatePolPath
        $excExcl = @($fExcReq.PreventivelyExcluded | Where-Object { [string]$_.Model -eq 'opencode-go/deepseek-v4.1-flash' -and [string]$_.Reason -ceq 'EXCEPTIONAL_BUDGET_AUTHORIZATION_REQUIRED' })
        Assert-V14 (($fExcReq.FallbackModel -ne 'opencode-go/deepseek-v4.1-flash' -and $excExcl.Count -ge 1) -and -not ($fExcReq.Status -eq 'AUTHORIZED' -and [bool]$fExcReq.ProviderCostAuthorized -and [string]$fExcReq.FallbackModel -eq 'opencode-go/deepseek-v4.1-flash')) 'exceptional-budget-required-excluded-fail-closed'
        # PR207-EXCEPTIONAL-COST-AUTH-REGRESSION: ProviderCostAuthorized must not
        # bypass the exceptional budget gate. Astra env stays unset here; only
        # the general cost flag is true, and deepseek_go requires_authorization
        # is false so the RequiresCost gate cannot explain the exclusion.
        $fExcCostOnly = Resolve-OrchestrationModelFallback -RequestedSelection $sCostGate -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -ProviderCostAuthorized $true -IgnoreUserConfig $true -PolicyPath $costGatePolPath
        $excCostOnlyExcl = @($fExcCostOnly.PreventivelyExcluded | Where-Object { [string]$_.Model -eq 'opencode-go/deepseek-v4.1-flash' -and [string]$_.Reason -ceq 'EXCEPTIONAL_BUDGET_AUTHORIZATION_REQUIRED' })
        Assert-V14 (($fExcCostOnly.FallbackModel -ne 'opencode-go/deepseek-v4.1-flash' -and $excCostOnlyExcl.Count -ge 1) -and -not ($fExcCostOnly.Status -eq 'AUTHORIZED' -and [string]$fExcCostOnly.FallbackModel -eq 'opencode-go/deepseek-v4.1-flash')) 'exceptional-budget-provider-cost-does-not-authorize'
    } finally {
        if (-not [string]::IsNullOrEmpty($prevT4Auth)) { $env:OPENCODE_T4_AUTHORIZED = $prevT4Auth } else { Remove-Item Env:\OPENCODE_T4_AUTHORIZED -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrEmpty($prevAstraAuth)) { $env:OPENCODE_ASTRA_AUTHORIZED = $prevAstraAuth } else { Remove-Item Env:\OPENCODE_ASTRA_AUTHORIZED -ErrorAction SilentlyContinue }
    }
} finally {
    try { if (Test-Path -LiteralPath $costGatePolPath) { Remove-Item -LiteralPath $costGatePolPath -Force -ErrorAction SilentlyContinue } } catch { }
}
Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
