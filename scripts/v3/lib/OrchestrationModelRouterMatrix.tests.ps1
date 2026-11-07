<#
.SYNOPSIS
    Operator T0-T4 model matrix contract (deterministic, no provider calls).
.DESCRIPTION
    Covers model order, per-role starting tiers, Planner Luna override, Claude
    alias resolution status, operator-selected DeepSeek Go T2 primary (ZDR expired-unconfirmed, no renewal claim), and no replay on technical
    failures without an independent no-start proof.
    Run: powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterMatrix.tests.ps1
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')

$script:pass = 0
$script:fail = 0
function Assert-MX([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name"; $script:pass++ }
    else { Write-Host "[FAIL] $Name"; $script:fail++ }
}

$p = Get-OrchestrationModelRoutingPolicy -ForceReload $true
Assert-MX ($p.Status -ceq 'POLICY_LOADED') 'mx-policy-loads'
$pol = $p.Policy

# 1. Declarative primary and same-tier fallback order.
Assert-MX ([string]$pol.planner.model_id -ceq 'opencode-go/deepseek-v4.1-flash' -and [string]$pol.planner.tier -ceq 'T2' -and [string]$pol.planner.primary -ceq 'deepseek_go') 'mx-planner-deepseek-t2'
Assert-MX ([string]$pol.role_profiles.build.default_model -ceq 'deepseek_go' -and @($pol.role_profiles.build.alternatives).Count -eq 0) 'mx-build-pinned-deepseek-no-sonnet-alt'
Assert-MX (([string]$pol.tiers.T1.primary -ceq 'iceman') -and ([string]$pol.tiers.T1.fallback -ceq 'mimo')) 'mx-T1-iceman-to-mimo'
Assert-MX (([string]$pol.tiers.T2.primary -ceq 'luna') -and ([string]$pol.tiers.T2.fallback -ceq 'muse')) 'mx-T2-luna-primary'
Assert-MX (([string]$pol.models.deepseek_go.fallback_candidates[0] -ceq 'muse') -and ([string]$pol.models.deepseek_go.fallback_candidates[1] -ceq 'claude_haiku') -and ([string]$pol.models.deepseek_go.fallback_candidates[2] -ceq 'luna') -and ([string]$pol.models.muse.fallback_candidates[0] -ceq 'claude_haiku') -and ([string]$pol.models.muse.fallback_candidates[1] -ceq 'luna') -and (@($pol.models.luna.fallback_candidates).Count -eq 0)) 'mx-T2-chain-deepseek-first-no-cycle'
Assert-MX (([string]$pol.tiers.T3.primary -ceq 'claude_sonnet') -and ([string]$pol.tiers.T3.fallback -ceq 'terra') -and ([string]$pol.models.claude_sonnet.fallback_candidates[0] -ceq 'terra')) 'mx-T3-sonnet-terra-order'
Assert-MX (([string]$pol.tiers.T4.primary -ceq 'claude_opus') -and ([string]$pol.tiers.T4.fallback -ceq 'sol') -and ([string]$pol.models.claude_opus.fallback_candidates[0] -ceq 'sol')) 'mx-T4-opus-sol-order'
# T4 same-tier list is Opus->Sol only (no T2 entries in alternatives);
# downgraded audit-only DeepSeek Go->Muse T2 recovery is documented in the
# T4 description and gated by T2 admissibility at fallback time, never executed.
Assert-MX ((@($pol.tiers.T4.alternatives) -notcontains 'muse') -and (@($pol.tiers.T4.alternatives) -notcontains 'deepseek_go')) 'mx-T4-same-tier-opus-sol-only-no-T2-in-alternatives'
Assert-MX (([string]$pol.tiers.T4.description -match 'DeepSeek') -and ([string]$pol.tiers.T4.description -match 'Muse') -and ([string]$pol.tiers.T4.description -match 'audit-only')) 'mx-T4-description-documents-audit-only-T2-recovery'
Assert-MX ([bool]$pol.models.deepseek_go.enabled -and [string]$pol.models.deepseek_go.availability_status -ceq 'active' -and [string]$pol.models.deepseek_go.data_policy.zdr_status -ceq 'expired-unconfirmed') 'mx-deepseek-operator-selected-active-zdr-unconfirmed'

# 2. Claude alias identities are catalog labels only until a session proves runtime resolution.
foreach ($id in @('claude_haiku','claude_sonnet','claude_opus','claude_fable')) {
    Assert-MX ([string]$pol.models.$id.resolution_status -ceq 'runtime-unverified' -and $null -eq $pol.models.$id.PSObject.Properties['resolved_model']) ("mx-$id-not-concrete-pinned")
}

# 3. Per-role start tiers and admissibility.
$build = Resolve-OrchestrationModelSelection -AgentName 'build' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($build.Status -ceq 'SELECTED' -and $build.Tier -ceq 'T2' -and $build.CatalogModel -ceq 'opencode-go/deepseek-v4.1-flash') 'mx-build-selection-deepseek'
$res = Resolve-OrchestrationModelSelection -AgentName 'researcher' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($res.Tier -ceq 'T1' -and $res.CatalogModel -ceq 'opencode-go/iceman-contributor-free') 'mx-researcher-starts-T1'
$resT2 = Resolve-OrchestrationModelSelection -AgentName 'researcher' -Complexity 'complex' -Risk low -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($resT2.Tier -ceq 'T2' -and $resT2.CatalogModel -ceq 'openai/gpt-6-luna') 'mx-researcher-complex-escalates-T2'
$exp = Resolve-OrchestrationModelSelection -AgentName 'explorer' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($exp.Tier -ceq 'T1' -and $exp.CatalogModel -ceq 'opencode-go/iceman-contributor-free') 'mx-explorer-starts-T1'
$expT2 = Resolve-OrchestrationModelSelection -AgentName 'explorer' -Complexity 'complex' -Risk low -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($expT2.Tier -ceq 'T2' -and $expT2.CatalogModel -ceq 'openai/gpt-6-luna') 'mx-explorer-complex-escalates-T2'
$docs = Resolve-OrchestrationModelSelection -AgentName 'docs-manager' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($docs.Tier -ceq 'T1' -and $docs.CatalogModel -ceq 'opencode-go/iceman-contributor-free') 'mx-docs-manager-starts-T1'
$docsT2 = Resolve-OrchestrationModelSelection -AgentName 'docs-manager' -Complexity 'complex' -Risk low -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($docsT2.Tier -ceq 'T2' -and $docsT2.CatalogModel -ceq 'openai/gpt-6-luna') 'mx-docs-manager-complex-escalates-T2'
$testT0 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial' -Risk 'low' -RequiresLlm $false -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($testT0.Tier -ceq 'T0' -and $testT0.CatalogModel -like '*deterministic*') 'mx-tester-deterministic-T0'
$testT1 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'simple' -Risk 'low' -RequiresLlm $true -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($testT1.Tier -ceq 'T1' -and $testT1.CatalogModel -ceq 'opencode-go/iceman-contributor-free') 'mx-tester-simple-LLM-T1'
$testT2 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'medium' -Risk 'medium' -RequiresLlm $true -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($testT2.Tier -ceq 'T2' -and $testT2.CatalogModel -ceq 'openai/gpt-6-luna') 'mx-tester-needed-LLM-T2'
Assert-MX (@($pol.role_profiles.researcher.admissible_tiers) -notcontains 'T3' -and @($pol.role_profiles.researcher.prohibited_tiers) -contains 'T3') 'mx-researcher-no-auto-T3'
$docsProfile = $pol.role_profiles.PSObject.Properties['docs-manager'].Value
Assert-MX (@($pol.role_profiles.explorer.admissible_tiers) -notcontains 'T3' -and @($docsProfile.admissible_tiers) -notcontains 'T3' -and @($pol.role_profiles.tester.admissible_tiers) -notcontains 'T3') 'mx-T1-roles-not-admissible-T3'
$coderT3 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($coderT3.Tier -ceq 'T3' -and $coderT3.CatalogModel -ceq 'claude-agent/sonnet') 'mx-complex-coder-starts-sonnet-T3'
$advisor = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($advisor.Tier -ceq 'T3' -and $advisor.CatalogModel -ceq 'claude-agent/sonnet') 'mx-advisor-min-T3-sonnet'
Assert-MX (@($pol.role_profiles.'engineering-advisor'.admissible_tiers) -notcontains 'T2' -and @($pol.role_profiles.'engineering-advisor'.prohibited_tiers) -contains 'T2') 'mx-advisor-T2-prohibited'

# 4. Kernel proof canonical IDs follow the policy primaries (no stale Terra/Sol anchors).
$canonT3 = Get-TaskKernelCanonicalModelForTier -Policy $pol -Tier 'T3'
$canonT4 = Get-TaskKernelCanonicalModelForTier -Policy $pol -Tier 'T4'
Assert-MX ([bool]$canonT3.ok -and $canonT3.model_id -ceq 'claude-agent/sonnet' -and $canonT3.provider -ceq 'claude-agent') 'mx-kernel-proof-primary-T3-sonnet'
Assert-MX ([bool]$canonT4.ok -and $canonT4.model_id -ceq 'claude-agent/opus' -and $canonT4.provider -ceq 'claude-agent') 'mx-kernel-proof-primary-T4-opus'
$tierSonnet = Get-TaskKernelTierForModelId -Policy $pol -ModelId 'claude-agent/sonnet'
$tierOpus = Get-TaskKernelTierForModelId -Policy $pol -ModelId 'claude-agent/opus'
Assert-MX ([bool]$tierSonnet.ok -and $tierSonnet.tier -ceq 'T3' -and [bool]$tierOpus.ok -and $tierOpus.tier -ceq 'T4') 'mx-kernel-infers-Claude-tier-from-policy'

# 5. No automatic replay: caller booleans and ambiguous/transport classes are
# not an independent no-start proof. The productive fallback resolver stays HOLD.
$t2sel = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t1sel = Resolve-OrchestrationModelSelection -AgentName 'explorer' -Complexity simple -Risk low -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t1fb = Resolve-OrchestrationModelFallback -RequestedSelection $t1sel -FailedModel 'opencode-go/iceman-contributor-free' -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-MX ($t1fb.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $null -eq $t1fb.FallbackModel -and $t1fb.CandidateModel -eq 'opencode/mimo-v2.6-flash-free' -and $t1fb.FallbackTier -ceq 'T1') 'mx-T1-Mimo-is-same-tier-audit-candidate-only'
$t2Haiku = Resolve-OrchestrationModelFallback -RequestedSelection $t2sel -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason RATE_LIMIT -NoExecutionStarted $true -ClaudeAgentProven $true -IgnoreUserConfig $true
$t2Luna = Resolve-OrchestrationModelFallback -RequestedSelection $t2sel -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode-go/deepseek-v4.1-flash','opencode-go/muse-spark-1.3-contributor') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -ClaudeAgentProven $true -IgnoreUserConfig $true
Assert-MX ($t2Haiku.CandidateModel -ceq 'opencode-go/muse-spark-1.3-contributor' -and $t2Haiku.FallbackModel -eq $null -and -not [bool]$t2Haiku.IsAuthorized) 'mx-T2-Muse-first-audit-only'
Assert-MX ($t2Luna.CandidateModel -ceq 'claude-agent/haiku' -and $t2Luna.FallbackModel -eq $null -and -not [bool]$t2Luna.IsAuthorized) 'mx-T2-Haiku-second-audit-only'
$t3Coder = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity complex -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t3Down = Resolve-OrchestrationModelFallback -RequestedSelection $t3Coder -FailedModel 'claude-agent/sonnet' -AttemptedModels @('claude-agent/sonnet','openai/gpt-6.1-terra') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true
$t3Reviewer = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk high -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t3ReviewerDown = Resolve-OrchestrationModelFallback -RequestedSelection $t3Reviewer -FailedModel 'claude-agent/sonnet' -AttemptedModels @('claude-agent/sonnet','openai/gpt-6.1-terra') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-MX ($t3Down.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $t3Down.FallbackTier -ceq 'T2' -and $null -eq $t3Down.FallbackModel) 'mx-T3-T2-candidate-audit-only-for-admissible-coder'
Assert-MX ($t3ReviewerDown.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $t3ReviewerDown.FallbackModel) 'mx-T3-reviewer-high-never-downgrades-T2'
$t4sel = Resolve-OrchestrationModelSelection -AgentName 'coder' -TaskId 'no-such-task-matrix' -TasksDir 'missing-tasks-matrix' -RepoRoot 'missing-repo-matrix' -Complexity complex -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t4shape = $t4sel | Select-Object *
$t4shape.Tier = 'T4'; $t4shape.CatalogModel = 'claude-agent/opus'
$t4Down = Resolve-OrchestrationModelFallback -RequestedSelection $t4shape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-MX ($t4Down.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $t4Down.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $t4Down.FallbackTier -ceq 'T2' -and $null -eq $t4Down.FallbackModel -and -not [bool]$t4Down.IsAuthorized) 'mx-T4-T2-deepseek-audit-only-for-admissible-coder'
$t4Down2 = Resolve-OrchestrationModelFallback -RequestedSelection $t4shape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol','opencode-go/deepseek-v4.1-flash') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-MX ($t4Down2.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $t4Down2.CandidateModel -ceq 'opencode-go/muse-spark-1.3-contributor' -and $t4Down2.FallbackTier -ceq 'T2' -and $null -eq $t4Down2.FallbackModel -and -not [bool]$t4Down2.IsAuthorized) 'mx-T4-T2-muse-second-audit-only-for-admissible-coder'
$t4CritRevSel = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk high -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t4CritRevShape = $t4CritRevSel | Select-Object *
$t4CritRevShape.Tier = 'T4'; $t4CritRevShape.CatalogModel = 'claude-agent/opus'
$t4CritRevDown = Resolve-OrchestrationModelFallback -RequestedSelection $t4CritRevShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-MX ($t4CritRevDown.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $t4CritRevDown.FallbackModel -and $null -eq $t4CritRevDown.CandidateModel) 'mx-T4-critical-reviewer-never-downgrades-T2'
$t4MedRevSel = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk medium -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t4MedRevShape = $t4MedRevSel | Select-Object *
$t4MedRevShape.Tier = 'T4'; $t4MedRevShape.CatalogModel = 'claude-agent/opus'
$t4MedRevDown = Resolve-OrchestrationModelFallback -RequestedSelection $t4MedRevShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-MX ($t4MedRevDown.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $t4MedRevDown.CandidateModel -ceq 'opencode-go/deepseek-v4.1-flash' -and $t4MedRevDown.FallbackTier -ceq 'T2' -and $null -eq $t4MedRevDown.FallbackModel -and -not [bool]$t4MedRevDown.IsAuthorized) 'mx-T4-medium-reviewer-deepseek-audit-only'
Assert-MX (([bool]$pol.models.deepseek_go.data_policy.sensitive_data_allowed -eq $false) -and ([string]$pol.models.deepseek_go.data_policy.zdr_note -match 'non-sensitive') -and ([string]$pol.models.deepseek_go.data_policy.zdr_note -match 'requires ZDR')) 'mx-deepseek-go-sensitive-data-not-allowed'
$selForgedMx = [pscustomobject]@{ Agent='reviewer'; Tier='T2'; CatalogModel='opencode-go/deepseek-v4.1-flash'; Risk='critical'; Provider='opencode-go'; RequestedModel='opencode-go/deepseek-v4.1-flash' }
$fForgedMx = Resolve-OrchestrationModelFallback -RequestedSelection $selForgedMx -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-MX ($fForgedMx.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $fForgedMx.FallbackModel -and $null -eq $fForgedMx.CandidateModel -and -not [bool]$fForgedMx.IsAuthorized) 'mx-forged-reviewer-T2-critical-rejected-no-candidate'
$t4AdvSel = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk low -Complexity simple -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t4AdvShape = $t4AdvSel | Select-Object *
$t4AdvShape.Tier = 'T4'; $t4AdvShape.CatalogModel = 'claude-agent/opus'
$t4AdvDown = Resolve-OrchestrationModelFallback -RequestedSelection $t4AdvShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-MX ($t4AdvDown.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $t4AdvDown.FallbackModel) 'mx-T4-advisor-never-downgrades-T2'
$t4SecSel = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk low -IgnoreUserConfig $true -NativeModelOverrideProven $true
$t4SecShape = $t4SecSel | Select-Object *
$t4SecShape.Tier = 'T4'; $t4SecShape.CatalogModel = 'claude-agent/opus'
$t4SecDown = Resolve-OrchestrationModelFallback -RequestedSelection $t4SecShape -FailedModel 'claude-agent/opus' -AttemptedModels @('claude-agent/opus','openai/gpt-6.1-sol') -TriggerReason RATE_LIMIT -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-MX ($t4SecDown.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $t4SecDown.FallbackModel) 'mx-T4-security-never-downgrades-T2'
foreach ($case in @(
    @{ name='mx-T1-mimo-fallback-held'; agent='explorer'; failed='opencode-go/iceman-contributor-free'; tier='T1'; model='opencode-go/iceman-contributor-free'; reason='RATE_LIMIT' },
    @{ name='mx-T2-deepseek-muse-haiku-luna-fallback-held'; agent='coder'; failed='opencode-go/deepseek-v4.1-flash'; tier='T2'; model='opencode-go/deepseek-v4.1-flash'; reason='RATE_LIMIT' },
    @{ name='mx-T3-terra-fallback-held'; agent='coder'; failed='claude-agent/sonnet'; tier='T3'; model='claude-agent/sonnet'; reason='RATE_LIMIT' },
    @{ name='mx-T4-sol-fallback-held'; agent='coder'; failed='claude-agent/opus'; tier='T4'; model='claude-agent/opus'; reason='RATE_LIMIT' },
    @{ name='mx-timeout-ambiguous-held'; agent='coder'; failed='opencode-go/deepseek-v4.1-flash'; tier='T2'; model='opencode-go/deepseek-v4.1-flash'; reason='TIMEOUT' },
    @{ name='mx-unknown-trigger-held'; agent='coder'; failed='opencode-go/deepseek-v4.1-flash'; tier='T2'; model='opencode-go/deepseek-v4.1-flash'; reason='PROVIDER_STATE_UNKNOWN' }
)) {
    $sel = [pscustomobject]@{ Agent=$case.agent; Tier=$case.tier; CatalogModel=$case.model; Risk='medium'; Provider=(Get-ModelProviderFromId $case.model); RequestedModel=$case.model }
    $fb = Resolve-OrchestrationModelFallback -RequestedSelection $sel -FailedModel $case.failed -TriggerReason $case.reason -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
    Assert-MX (([string]$fb.Status -match 'HOLD|EXHAUSTED|PROOF_ABSENT') -and (-not [bool]$fb.IsAuthorized) -and $null -eq $fb.FallbackModel) $case.name
}

# 6. Functional incapacity remains proof-gated: arbitrary receipt/count cannot promote T2/T3.
$coderNoProof = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 99 -T3FailureVerified $true -T3FailureReceipt 'verified:fake' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-MX ($coderNoProof.Tier -ceq 'T3') 'mx-arbitrary-receipt-does-not-promote-to-T4'

Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
