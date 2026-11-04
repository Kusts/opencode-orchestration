<#!
.SYNOPSIS
    Deterministic contract for the claude-agent provider (policy v1.4, no provider calls).
.DESCRIPTION
    Covers positive routes and negatives for the SINGLE existing policy file:
      - claude-agent provider registration (closed dispatch-alias identity:
        model_id + alias, no resolved_model field, no invented models)
      - T2 chain Muse -> Luna -> Haiku, Planner Luna -> Haiku (T2-only, build eligible),
        T3 Terra -> Sonnet, T4 Sol -> Opus, Astra availability (proved pre-execution) -> Fable
      - capability gate (local authenticated 'claude'), remote rejection, proved
        no-start, allowlisted availability reason, exact dispatch-alias identity
      - alias/model_id/policy-linkage tamper rejection, ambiguous failure no-replay,
        no fallback loops
      - no SDK-level retry duplication, UNKNOWN-cost on subscription zero reports
      - T4 only via kernel-owned proof, availability never escalates to T3,
        reviewer/security never downgraded to Haiku
      - context-preserving provider-switch handoff payload
    Productive native dispatch stays HOLD: the test-only DispatchExecutor seam makes
    EXACTLY ONE call (no retry, no automatic fallback). Static tests assert the
    dispatch-alias identity and the runtime-unverified status, NEVER actual version
    resolution (alias -> concrete stays runtime-unverified until a session event
    proves it; an event reporting an unverified concrete ID must stay
    PROOF_ABSENT/UNAUTHORIZED_MISMATCH).
    Run: pwsh -NoProfile -File scripts/v3/lib/OrchestrationModelRouterClaudeAgent.tests.ps1
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationModelExecution.ps1')

$script:pass = 0
$script:fail = 0
function Assert-CA([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name"; $script:pass++ }
    else { Write-Host "[FAIL] $Name"; $script:fail++ }
}

# T4-shaped request helper: kernel-owned selection is the only way to ENTER T4
# (OrchestrationModelRouterKernelProof / OrchestrationTaskKernelModelProof prove
# that path). This only shapes a fallback REQUEST without trusting any receipt.
function New-CaT4Request($Selection) {
    $shaped = $Selection | Select-Object *
    $shaped.Tier = 'T4'
    $shaped.CatalogModel = 'openai/gpt-6.1-sol'
    return $shaped
}

$p = Get-OrchestrationModelRoutingPolicy -ForceReload $true
Assert-CA ($p.Status -eq 'POLICY_LOADED') 'policy-loads'
Assert-CA ($p.PolicyVersion -eq '1.4.0') 'policy-stays-v1.4'
$pol = $p.Policy

# 1. Provider registration (single catalog, no second catalog).
Assert-CA ($pol.providers.'claude-agent'.enabled -eq $true) 'provider-claude-agent-enabled'
Assert-CA ([string]$pol.providers.'claude-agent'.type -eq 'claude-code') 'provider-claude-agent-type'

# 2. Closed dispatch-alias identity recorded (model_id + alias); catalog
#    inventory IDs are local-CLI listing provenance only, never a mapping; the
#    policy must not carry any resolved_model field (no runtime resolution claim).
$expectedAliases = @{
    'claude_haiku'   = @{ Model = 'claude-agent/haiku';   Alias = 'haiku' }
    'claude_sonnet'  = @{ Model = 'claude-agent/sonnet';  Alias = 'sonnet' }
    'claude_opus'    = @{ Model = 'claude-agent/opus';    Alias = 'opus' }
    'claude_fable'   = @{ Model = 'claude-agent/fable';   Alias = 'fable' }
}
foreach ($logicalId in $expectedAliases.Keys) {
    $entry = $pol.models.PSObject.Properties[$logicalId].Value
    $exp = $expectedAliases[$logicalId]
    Assert-CA ($null -ne $entry -and [string]$entry.provider -eq 'claude-agent' -and
        [string]$entry.model_id -eq [string]$exp.Model -and
        [string]$entry.alias -eq [string]$exp.Alias) ("dispatch-alias-identity:$logicalId")
    Assert-CA ($null -eq $entry.PSObject.Properties['resolved_model']) ("no-resolved-model-field:$logicalId")
    Assert-CA (-not [string]::IsNullOrWhiteSpace([string]$entry.catalog_inventory_id) -and
        ($null -ne $entry.PSObject.Properties['resolution_note'])) ("catalog-inventory-listed-as-provenance:$logicalId")
}
# 2b. Helper validates ONLY the closed dispatch-alias identity; a concrete
#     inventory ID is never an alias and any linkage tamper fails closed.
$aliasOk = Resolve-ClaudeAgentAlias -AliasModelId 'claude-agent/haiku' -PolicyAlias 'haiku' -PolicyModelId 'claude-agent/haiku'
Assert-CA ([bool]$aliasOk.Matches -and [string]$aliasOk.Expected -eq 'haiku') 'helper-matches-exact-dispatch-alias'
$aliasConcreteId = Resolve-ClaudeAgentAlias -AliasModelId 'claude-haiku-4-5-20251001' -PolicyAlias 'haiku' -PolicyModelId 'claude-agent/haiku'
Assert-CA ((-not [bool]$aliasConcreteId.Matches) -and [string]$aliasConcreteId.Reason -eq 'CLAUDE_UNKNOWN_ALIAS') 'helper-rejects-concrete-inventory-id-as-alias'
$aliasTokenTamper = Resolve-ClaudeAgentAlias -AliasModelId 'claude-agent/haiku' -PolicyAlias 'sonnet' -PolicyModelId 'claude-agent/haiku'
Assert-CA ((-not [bool]$aliasTokenTamper.Matches) -and [string]$aliasTokenTamper.Reason -eq 'CLAUDE_ALIAS_MISMATCH') 'helper-rejects-alias-token-tamper'
$aliasLinkTamper = Resolve-ClaudeAgentAlias -AliasModelId 'claude-agent/haiku' -PolicyAlias 'haiku' -PolicyModelId 'claude-agent/sonnet'
Assert-CA ((-not [bool]$aliasLinkTamper.Matches) -and [string]$aliasLinkTamper.Reason -eq 'CLAUDE_ALIAS_MISMATCH') 'helper-rejects-model-id-linkage-tamper'
$aliasMissing = Resolve-ClaudeAgentAlias -AliasModelId 'claude-agent/haiku' -PolicyAlias '' -PolicyModelId 'claude-agent/haiku'
Assert-CA ((-not [bool]$aliasMissing.Matches) -and [string]$aliasMissing.Reason -eq 'CLAUDE_ALIAS_MISSING') 'helper-rejects-missing-policy-alias'
foreach ($logicalId in @('claude_haiku', 'claude_sonnet', 'claude_opus', 'claude_fable')) {
    $entry = $pol.models.PSObject.Properties[$logicalId].Value
    Assert-CA ([string]$entry.resolution_status -eq 'runtime-unverified') ("resolution-runtime-unverified:$logicalId")
    $eff = @($entry.effort_variants)
    Assert-CA (($eff -contains 'low') -and ($eff -contains 'medium') -and ($eff -contains 'high') -and ($eff -contains 'xhigh') -and ($eff -contains 'max')) ("effort-variants:$logicalId")
    Assert-CA ($null -eq $entry.smoke_variant) ("no-smoke-variant-recorded:$logicalId")
}

# 3. Provider namespace mapping (alias and bare claude model names).
Assert-CA ((Get-ModelProviderFromId 'claude-agent/sonnet') -eq 'claude-agent') 'provider-map-alias'
Assert-CA ((Get-ModelProviderFromId 'claude-haiku') -eq 'claude-agent') 'provider-map-bare-claude-name'
Assert-CA ((Get-ModelProviderFromId 'openai/gpt-6-luna') -eq 'openai') 'provider-map-openai-untouched'
Assert-CA ((Get-ModelProviderFromId 'opencode-go/muse-spark-1.3-contributor') -eq 'opencode-go') 'provider-map-opencode-go-untouched'

# 4. OpenAI remains the provider of Luna/Terra/Sol/Astra.
Assert-CA ($pol.models.luna.provider -eq 'openai' -and $pol.models.terra.provider -eq 'openai' -and
    $pol.models.sol.provider -eq 'openai' -and $pol.models.astra.provider -eq 'openai') 'openai-keeps-luna-terra-sol-astra'

# 5. T2 availability: Muse+Luna exhausted -> Haiku (capability + proved no-start).
$sT2 = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fHaiku = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fHaiku.Status -eq 'AUTHORIZED' -and $fHaiku.FallbackModel -eq 'claude-agent/haiku' -and $fHaiku.FallbackTier -eq 'T2') 'T2-availability-to-haiku'
Assert-CA ($fHaiku.FallbackProvider -eq 'claude-agent' -and $fHaiku.IsCrossProvider -eq $true -and $fHaiku.IsDowngrade -eq $false) 'haiku-cross-provider-not-downgrade'

# 6. Same T2 chain without Claude capability -> fail-closed exhaustion; availability
#    NEVER escalates to Terra/T3 (capability escalation needs bound incapacity proof).
$fNoProof = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-CA ($fNoProof.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fNoProof.FallbackModel -eq $null) 'T2-exhausted-without-proof-fails-closed'
Assert-CA ($fNoProof.FallbackModel -ne 'openai/gpt-6.1-terra' -and $fNoProof.FallbackTier -ne 'T3') 'availability-never-escalates-to-terra-T3'
$haikuUnproven = @($fNoProof.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' -and $_.Reason -eq 'CLAUDE_CAPABILITY_UNPROVEN' })
Assert-CA ($haikuUnproven.Count -ge 1) 'claude-provider-unavailable-without-proof'
$t3BlockedCa = @($fNoProof.PreventivelyExcluded | Where-Object { $_.Reason -eq 'T3_ESCALATION_REQUIRES_INCAPACITY_PROOF' })
Assert-CA ($t3BlockedCa.Count -ge 1) 'T3-escalation-blocked-on-availability-recorded'

# 7. Planner records capability + effective model: Luna primary, Haiku only fallback (T2-only).
# Static assertions check the dispatch-alias identity and the runtime-unverified
# status, NOT actual runtime version resolution (alias->concrete stays
# runtime-unverified until a successful session event; static tests never prove
# version resolution and never validate an old concrete inventory ID as mapping).
$sPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-CA ($sPlanner.Tier -eq 'T2' -and $sPlanner.CatalogModel -eq 'openai/gpt-6-luna') 'planner-stays-luna-T2'
Assert-CA ((@($sPlanner.fallback_candidates).Count -eq 1) -and (@($sPlanner.fallback_candidates)[0] -eq 'claude-agent/haiku')) 'planner-fallback-haiku-only'
Assert-CA ([string]$pol.planner.fallback -eq 'claude_haiku' -and [string]$pol.planner.fallback_model_id -eq 'claude-agent/haiku' -and [string]$pol.planner.fallback_requires_capability_proof -eq 'True') 'planner-policy-records-capability-proof'
Assert-CA ([string]$pol.planner.fallback_alias -eq 'haiku' -and $null -eq $pol.planner.PSObject.Properties['fallback_resolved_model']) 'planner-fallback-alias-without-resolved-field'
Assert-CA ([string]$pol.models.claude_haiku.resolution_status -eq 'runtime-unverified' -and -not [string]::IsNullOrWhiteSpace([string]$pol.models.claude_haiku.catalog_inventory_id)) 'planner-fallback-runtime-unverified-listed-inventory-provenance'
Assert-CA ((@($pol.planner.fallback_effort_variants) -contains 'max') -and ($null -eq $pol.planner.fallback_smoke_variant)) 'planner-policy-records-effort-metadata-no-variant'
Assert-CA (@($pol.role_profiles.build.alternatives).Count -eq 1 -and @($pol.role_profiles.build.alternatives)[0] -eq 'claude_haiku') 'build-alternatives-haiku-only'

# 8. Reviewer never downgraded to Haiku: role-ineligible, fail-closed (no T3 on
#    availability either).
$sRevLow = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fRev = Resolve-OrchestrationModelFallback -RequestedSelection $sRevLow -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fRev.FallbackModel -ne 'claude-agent/haiku') 'reviewer-never-haiku'
$haikuInelig = @($fRev.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' -and $_.Reason -eq 'AGENT_NOT_ELIGIBLE' })
Assert-CA ($haikuInelig.Count -ge 1) 'haiku-ineligible-for-reviewer'

# 9. Haiku only T2-admissible roles (policy level, double protection with eligibility).
Assert-CA (@($pol.models.claude_haiku.tier_profiles).Count -eq 1 -and @($pol.models.claude_haiku.tier_profiles)[0] -eq 'T2') 'haiku-T2-only'
$haikuRoles = @($pol.models.claude_haiku.eligible_roles)
Assert-CA (($haikuRoles -notcontains 'reviewer') -and ($haikuRoles -notcontains 'security-reviewer') -and ($haikuRoles -notcontains 'architect')) 'haiku-excludes-review-security-architect'
Assert-CA ($haikuRoles -contains 'build') 'haiku-build-eligible'

# 10. T3 availability: Terra -> Sonnet (proven), same tier before any T2 downgrade.
$sT3 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-CA ($sT3.Tier -eq 'T3' -and $sT3.CatalogModel -eq 'openai/gpt-6.1-terra') 'T3-runtime-terra'
$fSonnet = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'openai/gpt-6.1-terra' -AttemptedModels @('openai/gpt-6.1-terra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fSonnet.Status -eq 'AUTHORIZED' -and $fSonnet.FallbackModel -eq 'claude-agent/sonnet' -and $fSonnet.FallbackTier -eq 'T3') 'T3-availability-to-sonnet'

# 11. Quota exhaustion is an availability class -> Sonnet as well.
$fQuota = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'openai/gpt-6.1-terra' -AttemptedModels @('openai/gpt-6.1-terra') -TriggerReason 'QUOTA_EXCEEDED' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fQuota.Status -eq 'AUTHORIZED' -and $fQuota.FallbackModel -eq 'claude-agent/sonnet') 'quota-exceeded-is-availability'

# 12. Offline is an availability class -> Haiku on the T2 chain.
$fOffline = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'OFFLINE' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fOffline.Status -eq 'AUTHORIZED' -and $fOffline.FallbackModel -eq 'claude-agent/haiku') 'offline-is-availability'

# 13. T4 selection requires kernel-owned proof (never bare count, risk or raw receipt).
$sT4Bare = Resolve-OrchestrationModelSelection -AgentName 'coder' -FailureCount 3 -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-CA ($sT4Bare.Tier -ne 'T4') 'T4-without-kernel-proof-refused'
$sT4Raw = Resolve-OrchestrationModelSelection -AgentName 'coder' -FailureCount 3 -T3FailureVerified $true -T3FailureReceipt 'verified:ca-t4' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-CA ($sT4Raw.Tier -ne 'T4') 'raw-bool-string-T3-receipt-never-selects-T4'
$sT4TaskIdNoProof = Resolve-OrchestrationModelSelection -AgentName 'coder' -TaskId 'ca-no-such-task-001' -TasksDir 'ca-no-such-dir' -RepoRoot 'ca-no-such-repo' -FailureCount 3 -T3FailureVerified $true -T3FailureReceipt 'verified:ca-t4' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-CA ($sT4TaskIdNoProof.Tier -ne 'T4') 'taskid-without-persisted-proof-never-selects-T4'
$sT4 = New-CaT4Request $sT3

# 14. T4 availability: Sol -> Opus (proven), never Astra on transport faults.
$fOpus = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -AttemptedModels @('openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fOpus.Status -eq 'AUTHORIZED' -and $fOpus.FallbackModel -eq 'claude-agent/opus' -and $fOpus.FallbackTier -eq 'T4') 'T4-availability-to-opus'
Assert-CA ($fOpus.FallbackProvider -eq 'claude-agent') 'opus-provider-recorded'

# 15. VERIFIED_TASK_FAILURE with a generic receipt NEVER authorizes Fable: the
#     kernel proves T3/T4 Sol, never Astra, and incapacity is not availability.
$fFable = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra','claude-agent/opus') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:ca-fable' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fFable.FallbackModel -ne 'claude-agent/fable') 'fable-blocked-on-verified-task-failure-generic-receipt'
Assert-CA ($fFable.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') 'fable-verified-failure-exhausts'

# 16. Fable unreachable without capability: excluded, never silently substituted.
$fFableNoPath = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra','claude-agent/opus') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:ca-fable' -IgnoreUserConfig $true
Assert-CA ($fFableNoPath.FallbackModel -ne 'claude-agent/fable') 'fable-unavailable-without-capability'
$fableGate = @($fFableNoPath.PreventivelyExcluded | Where-Object { ($_.Model -eq 'claude-agent/fable' -and $_.Reason -eq 'FABLE_REQUIRES_ASTRA_FAILURE') -or ($_.Model -eq 'claude-agent/fable' -and $_.Reason -eq 'CLAUDE_CAPABILITY_UNPROVEN') })
Assert-CA ($fableGate.Count -ge 1) 'fable-gated'

# 17. Incapacity claim without kernel-owned proof authorizes NOTHING (never by
#     message count and never by an availability substitute).
$fNoReceipt = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -AttemptedModels @('openai/gpt-6.1-sol') -TriggerReason 'VERIFIED_TASK_FAILURE' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fNoReceipt.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fNoReceipt.FallbackModel -eq $null) 'incapacity-without-kernel-proof-exhausts'
$availBlockedCa = @($fNoReceipt.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/opus' -and $_.Reason -eq 'CLAUDE_AVAILABILITY_REQUIRED' })
Assert-CA ($availBlockedCa.Count -ge 1) 'claude-opus-not-used-as-incapacity-substitute'

# 18. Dispatch-alias tamper (alias token, model_id linkage) is rejected
#     fail-closed: never a concrete mapping, never a silent substitution.
$tmpPolicy = Join-Path ([System.IO.Path]::GetTempPath()) ("ca-tamper-" + [Guid]::NewGuid().ToString('N') + ".json")
try {
    $rawPol = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json') -Raw
    $tampered = ConvertFrom-Json -InputObject $rawPol
    $tampered.models.claude_sonnet.alias = 'sonnet-tampered'
    Set-Content -LiteralPath $tmpPolicy -Value (ConvertTo-Json -InputObject $tampered -Depth 20) -Encoding UTF8
    $fTamper = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'openai/gpt-6.1-terra' -AttemptedModels @('openai/gpt-6.1-terra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -PolicyPath $tmpPolicy
    Assert-CA ($fTamper.FallbackModel -eq 'opencode-go/muse-spark-1.3-contributor') 'alias-tamper-falls-back-to-muse'
    $tamperExcl = @($fTamper.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/sonnet' -and $_.Reason -eq 'CLAUDE_ALIAS_MISMATCH' })
    Assert-CA ($tamperExcl.Count -ge 1) 'alias-mismatch-recorded'
} finally {
    if (Test-Path -LiteralPath $tmpPolicy) { Remove-Item -LiteralPath $tmpPolicy -Force -ErrorAction SilentlyContinue }
}

# 18b. model_id tamper: a claude_sonnet entry pointing at another known alias
#      keeps the exact closed-map check authoritative (alias/model_id linkage
#      must agree) and fails closed instead of dispatching the wrong alias.
$tmpPolicyLink = Join-Path ([System.IO.Path]::GetTempPath()) ("ca-link-tamper-" + [Guid]::NewGuid().ToString('N') + ".json")
try {
    $rawPolLink = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json') -Raw
    $tamperedLink = ConvertFrom-Json -InputObject $rawPolLink
    $tamperedLink.models.claude_sonnet.model_id = 'claude-agent/haiku'
    Set-Content -LiteralPath $tmpPolicyLink -Value (ConvertTo-Json -InputObject $tamperedLink -Depth 20) -Encoding UTF8
    $fTamperLink = Resolve-OrchestrationModelFallback -RequestedSelection $sT3 -FailedModel 'openai/gpt-6.1-terra' -AttemptedModels @('openai/gpt-6.1-terra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -PolicyPath $tmpPolicyLink
    Assert-CA ($fTamperLink.FallbackModel -eq 'opencode-go/muse-spark-1.3-contributor') 'model-id-linkage-tamper-falls-back-to-muse'
    $linkExcl = @($fTamperLink.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' -and $_.Reason -eq 'CLAUDE_ALIAS_MISMATCH' })
    Assert-CA ($linkExcl.Count -ge 1) 'model-id-linkage-mismatch-recorded'
} finally {
    if (Test-Path -LiteralPath $tmpPolicyLink) { Remove-Item -LiteralPath $tmpPolicyLink -Force -ErrorAction SilentlyContinue }
}

# 19. Remote worker without proven capability is rejected for this provider.
$fRemote = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -WorkerHost 'remote'
Assert-CA ($fRemote.FallbackModel -ne 'claude-agent/haiku') 'remote-without-capability-rejected'
$remoteExcl = @($fRemote.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' -and $_.Reason -eq 'CLAUDE_REMOTE_UNPROVEN' })
Assert-CA ($remoteExcl.Count -ge 1) 'remote-rejection-recorded'
$fRemoteOk = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -WorkerHost 'remote' -WorkerCapabilities @('claude-agent-remote')
Assert-CA ($fRemoteOk.Status -eq 'AUTHORIZED' -and $fRemoteOk.FallbackModel -eq 'claude-agent/haiku') 'remote-with-capability-allowed'

# 20. Proved no-start is necessary: capability alone never unlocks a claude route.
$fNoStart = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $false -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fNoStart.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fNoStart.FallbackModel -eq $null) 'no-start-proof-required-to-exhaust'
$noStartExcl = @($fNoStart.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' -and $_.Reason -eq 'CLAUDE_NO_START_PROOF_REQUIRED' })
Assert-CA ($noStartExcl.Count -ge 1) 'no-start-exclusion-recorded'

# 21. Only allowlisted availability reasons unlock a claude route.
$fIncCapacity = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'VERIFIED_TASK_FAILURE' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fIncCapacity.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fIncCapacity.FallbackModel -eq $null) 'incapacity-claim-never-unlocks-haiku'
$availExclCa = @($fIncCapacity.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' -and $_.Reason -eq 'CLAUDE_AVAILABILITY_REQUIRED' })
Assert-CA ($availExclCa.Count -ge 1) 'availability-reason-required-recorded'

# 22. Real dispatch seam: EXACTLY ONE call, no SDK-level retry, no auto fallback.
$script:attemptedDispatch = @()
$dispatchObservedModel = {
    param([string]$Model, [string]$Agent, [string]$TaskId)
    $script:attemptedDispatch += $Model
    return [pscustomobject]@{ Model = $Model }
}
$execOk = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchObservedModel -TaskId 'ca-exec-single'
Assert-CA ($execOk.status -eq 'EXECUTED_VERIFIED' -and $execOk.verification.ProofStatus -eq 'EXACT_MATCH') 'dispatch-single-call-exact-match'
Assert-CA ($script:attemptedDispatch.Count -eq 1) 'dispatch-exactly-one-call-no-retry'

# 23. Transport-failure envelope: one call only, PROOF_ABSENT hold (HOLD of the
#     native pre-dispatch fallback), never EXECUTED_VERIFIED and never a loop.
$script:attemptedBounded = @()
$dispatchTransportFail = {
    param([string]$Model, [string]$Agent, [string]$TaskId)
    $script:attemptedBounded += $Model
    return [pscustomobject]@{ FailureClass = 'RATE_LIMIT'; NoExecutionStarted = $true }
}
$execBounded = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchTransportFail -TaskId 'ca-exec-bounded'
Assert-CA (($script:attemptedBounded.Count -eq 1) -and (@($script:attemptedBounded | Sort-Object -Unique).Count -eq 1)) 'bounded-no-loop-single-call'
Assert-CA ([string]$execBounded.status -ceq 'PROOF_ABSENT' -and [string]$execBounded.reason -ceq 'transport-failure-no-proof') 'bounded-exhaustion-fail-closed'
Assert-CA (-not [bool]$execBounded.ok) 'transport-failure-never-approved'

# 24. Ambiguous failure/timeout without an observed model: UNKNOWN, no replay.
$script:attemptedAmb = @()
$dispatchAmbiguous = {
    param([string]$Model, [string]$Agent, [string]$TaskId)
    $script:attemptedAmb += $Model
    return [pscustomobject]@{ FailureClass = 'TIMEOUT'; NoExecutionStarted = $false }
}
$execAmb = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchAmbiguous -TaskId 'ca-exec-amb'
Assert-CA (($script:attemptedAmb.Count -eq 1) -and ([string]$execAmb.status -ne 'EXECUTED_VERIFIED')) 'ambiguous-timeout-no-retry'

# 25. Router-authorized Haiku fallback verifies post-execution as AUTHORIZED_FALLBACK.
#     The exact runtime event stays the alias (the only identity a real session
#     proved); an event reporting an unverified concrete ID must never verify.
$verHaiku = Test-ExecutedModelVerification -RequestedSelection $sT2 -ExecutedModelEvent @{ Model = 'claude-agent/haiku'; AuthorizedFallback = $fHaiku } -NativeModelOverrideProven $true
Assert-CA ($verHaiku.ProofStatus -eq 'AUTHORIZED_FALLBACK' -and $verHaiku.IsAuthorizedFallback -eq $true) 'haiku-fallback-verifies-authorized'
$verHaikuNoAuth = Test-ExecutedModelVerification -RequestedSelection $sT2 -ExecutedModelEvent @{ Model = 'claude-agent/haiku' } -NativeModelOverrideProven $true
Assert-CA ($verHaikuNoAuth.ProofStatus -eq 'UNAUTHORIZED_MISMATCH') 'haiku-without-decision-is-mismatch'
$verConcrete = Test-ExecutedModelVerification -RequestedSelection $sT2 -ExecutedModelEvent @{ Model = 'claude-haiku-4-5-20251001'; AuthorizedFallback = $fHaiku } -NativeModelOverrideProven $true
Assert-CA ($verConcrete.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and -not [bool]$verConcrete.VerifiedMatch) 'unverified-concrete-event-never-verifies'
$verConcreteNoProof = Test-ExecutedModelVerification -RequestedSelection $sT2 -ExecutedModelEvent @{ Model = 'claude-haiku-4-5-20251001' } -NativeModelOverrideProven $false
Assert-CA ($verConcreteNoProof.ProofStatus -eq 'PROOF_ABSENT' -and -not [bool]$verConcreteNoProof.VerifiedMatch) 'unverified-concrete-event-without-runtime-proof-absent'
$verAliasExact = Test-ExecutedModelVerification -RequestedSelection $sT2 -ExecutedModelEvent @{ Model = 'claude-agent/haiku'; AuthorizedFallback = $fHaiku } -NativeModelOverrideProven $false
Assert-CA ($verAliasExact.ProofStatus -eq 'PROOF_ABSENT') 'alias-event-without-runtime-proof-stays-proof-absent'

# 26. Fallback loop protection: everything attempted -> EXHAUSTED, exact attempt count, no repeat.
$fLoop = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6.1-sol' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna','claude-agent/haiku','opencode-go/deepseek-v4.1-flash','openai/gpt-6.1-terra','claude-agent/sonnet','openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fLoop.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fLoop.IsAuthorized -eq $false) 'loop-exhausts'
Assert-CA ($fLoop.AttemptsCount -eq 7) 'loop-exact-attempt-count'
$loopUniq = @($fLoop.ReallyAttemptedModels | Sort-Object -Unique)
Assert-CA ($loopUniq.Count -eq $fLoop.ReallyAttemptedModels.Count) 'loop-no-repeat'

# 27. Context-preserving provider-switch handoff carries objective/task id/attempt history.
$handoff = New-ClaudeAgentProviderSwitchHandoff -TaskId 'TASK-CA-1' -Objective 'Migrate retry helper to bounded fallback' -FromModel 'openai/gpt-6-luna' -ToModel 'claude-agent/haiku' -FailureClass 'RATE_LIMIT' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -PolicyHash 'deadbeef' -PolicyVersion '1.4.0'
Assert-CA ([bool]$handoff.ok -and [string]$handoff.handoff.task_id -eq 'TASK-CA-1') 'handoff-task-id'
Assert-CA ([string]$handoff.handoff.objective -eq 'Migrate retry helper to bounded fallback') 'handoff-objective'
Assert-CA ((@($handoff.handoff.attempted_models).Count -eq 2) -and ([int]$handoff.handoff.attempt_count -eq 2)) 'handoff-attempt-history'
Assert-CA ([string]$handoff.handoff.to_provider -eq 'claude-agent' -and [string]$handoff.handoff.from_provider -eq 'openai') 'handoff-provider-switch-recorded'
$handoffBad = New-ClaudeAgentProviderSwitchHandoff -TaskId 'TASK-CA-1' -Objective '' -ToModel 'claude-agent/haiku'
Assert-CA ((-not [bool]$handoffBad.ok) -and ([string]$handoffBad.reason -eq 'invalid-objective')) 'handoff-rejects-empty-objective'

# 28. Subscription quota: reported 0 is recorded as UNKNOWN cost, never zero.
Assert-CA ((Resolve-ClaudeAgentUsageCost -ReportedCost 0) -eq 'UNKNOWN') 'zero-cost-becomes-unknown'
Assert-CA ((Resolve-ClaudeAgentUsageCost -ReportedCost '') -eq 'UNKNOWN') 'empty-cost-becomes-unknown'
Assert-CA ((Resolve-ClaudeAgentUsageCost -ReportedCost 'subscription') -eq 'UNKNOWN') 'non-numeric-cost-becomes-unknown'
Assert-CA ((Resolve-ClaudeAgentUsageCost -ReportedCost '1.25') -eq '1.25') 'nonzero-cost-preserved'

# 29. Planner (build) dedicated path: Luna primary, Haiku specialized fallback,
#     T2-only (policy-level until the productive native dispatcher calls it).
$sPlannerSel = Resolve-OrchestrationModelSelection -AgentName 'build' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-CA ($sPlannerSel.CatalogModel -eq 'openai/gpt-6-luna' -and $sPlannerSel.Tier -eq 'T2') 'planner-repro-selects-luna-T2'
$fPlannerRepro = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'OFFLINE' -NoExecutionStarted $true -ClaudeAgentProven $true
Assert-CA ($fPlannerRepro.Status -eq 'AUTHORIZED' -and $fPlannerRepro.FallbackModel -eq 'claude-agent/haiku' -and $fPlannerRepro.FallbackTier -eq 'T2') 'planner-repro-luna-offline-to-haiku'
Assert-CA ($fPlannerRepro.FallbackModel -notin @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash','claude-agent/sonnet') -and $fPlannerRepro.FallbackTier -ne 'T4') 'planner-repro-never-generic-sonnet-muse-deepseek-T4'
Assert-CA (@($fPlannerRepro.ReallyAttemptedModels) -contains 'openai/gpt-6-luna') 'planner-repro-preserves-attempt-history'

# 30. Planner negatives fail closed with no generic Muse/DeepSeek fallback, never Sonnet, never T4.
$fPlannerNoCap = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'OFFLINE' -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-CA ($fPlannerNoCap.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fPlannerNoCap.FallbackModel -eq $null) 'planner-no-capability-exhausts'
Assert-CA ($fPlannerNoCap.FallbackModel -notin @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash','claude-agent/sonnet')) 'planner-no-capability-no-generic'
$fPlannerNoStart = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'OFFLINE' -NoExecutionStarted $false -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fPlannerNoStart.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fPlannerNoStart.FallbackModel -eq $null) 'planner-no-start-proof-exhausts'
$fPlannerWrong = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor') -TriggerReason 'OFFLINE' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fPlannerWrong.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fPlannerWrong.FallbackModel -eq $null) 'planner-wrong-model-exhausts'
Assert-CA ($fPlannerWrong.FallbackModel -notin @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash','claude-agent/haiku','claude-agent/sonnet')) 'planner-wrong-model-no-fallback'
$fPlannerAmb = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'TIMEOUT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fPlannerAmb.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fPlannerAmb.FallbackModel -eq $null) 'planner-ambiguous-timeout-exhausts'
$fPlannerVer = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:task-1' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fPlannerVer.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fPlannerVer.FallbackModel -eq $null) 'planner-verified-failure-not-availability'
$fPlannerSonnet = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'OFFLINE' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -AllowedProviders @('openai')
Assert-CA ($fPlannerSonnet.FallbackModel -ne 'claude-agent/sonnet' -and $fPlannerSonnet.FallbackTier -ne 'T3') 'planner-never-sonnet-T3'

# 31. Planner loop protection: Haiku already attempted exhausts exactly, no repeat, no generic.
$fPlannerLoop = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna','claude-agent/haiku') -TriggerReason 'OFFLINE' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fPlannerLoop.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fPlannerLoop.FallbackModel -eq $null) 'planner-haiku-attempted-exhausts'
Assert-CA ($fPlannerLoop.AttemptsCount -eq 2) 'planner-loop-exact-attempt-count'
$plannerLoopUniq = @($fPlannerLoop.ReallyAttemptedModels | Sort-Object -Unique)
Assert-CA ($plannerLoopUniq.Count -eq $fPlannerLoop.ReallyAttemptedModels.Count) 'planner-loop-no-repeat'
Assert-CA ($fPlannerLoop.FallbackModel -notin @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash','claude-agent/sonnet')) 'planner-loop-no-generic'

# 32. Planner Haiku dispatch-alias tamper fails closed (no silent Muse): entry
#     alias, entry model_id linkage, planner fallback_alias and the
#     runtime-unverified metadata are each mutated in isolation.
function Invoke-PlannerAliasTamperCase {
    param([string]$CaseName, [scriptblock]$Mutate, [string]$ExpectedReason)
    $tmpPol = Join-Path ([System.IO.Path]::GetTempPath()) ("ca-planner-tamper-" + $CaseName + "-" + [Guid]::NewGuid().ToString('N') + ".json")
    try {
        $rawPlannerPol = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json') -Raw
        $tamperedPlanner = ConvertFrom-Json -InputObject $rawPlannerPol
        & $Mutate $tamperedPlanner
        Set-Content -LiteralPath $tmpPol -Value (ConvertTo-Json -InputObject $tamperedPlanner -Depth 20) -Encoding UTF8
        $fPlannerTamper = Resolve-OrchestrationModelFallback -RequestedSelection $sPlannerSel -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna') -TriggerReason 'OFFLINE' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -PolicyPath $tmpPol
        Assert-CA ($fPlannerTamper.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fPlannerTamper.FallbackModel -eq $null) ("planner-tamper-" + $CaseName + "-exhausts")
        Assert-CA ($fPlannerTamper.FallbackModel -notin @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash','claude-agent/sonnet')) ("planner-tamper-" + $CaseName + "-no-generic")
        $ptExcl = @($fPlannerTamper.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/haiku' -and $_.Reason -eq $ExpectedReason })
        Assert-CA ($ptExcl.Count -ge 1) ("planner-tamper-" + $CaseName + "-reason-recorded")
    } finally {
        if (Test-Path -LiteralPath $tmpPol) { Remove-Item -LiteralPath $tmpPol -Force -ErrorAction SilentlyContinue }
    }
}
Invoke-PlannerAliasTamperCase 'entry-alias' { param($j) $j.models.claude_haiku.alias = 'sonnet' } 'CLAUDE_ALIAS_MISMATCH'
Invoke-PlannerAliasTamperCase 'entry-model-id' { param($j) $j.models.claude_haiku.model_id = 'claude-agent/sonnet' } 'CLAUDE_ALIAS_MISMATCH'
Invoke-PlannerAliasTamperCase 'fallback-alias' { param($j) $j.planner.fallback_alias = 'sonnet' } 'CLAUDE_ALIAS_MISMATCH'
Invoke-PlannerAliasTamperCase 'resolution-status' { param($j) $j.models.claude_haiku.resolution_status = 'runtime-verified' } 'CLAUDE_RESOLUTION_STATUS_INVALID'

# 33. DeepSeek Go blocked (ZDR_EXPIRED_UNCONFIRMED): excluded while the T2 chain
#     keeps running through the admissible Haiku route.
Assert-CA ($pol.models.deepseek_go.enabled -eq $false -and [string]$pol.models.deepseek_go.availability_reason -eq 'ZDR_EXPIRED_UNCONFIRMED') 'deepseek-go-blocked-policy'
$fDsRoute = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fDsRoute.Status -eq 'AUTHORIZED' -and $fDsRoute.FallbackModel -eq 'claude-agent/haiku') 'T2-route-continues-without-deepseek'
$fDsAll = Resolve-OrchestrationModelFallback -RequestedSelection $sT2 -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna','claude-agent/haiku') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-CA ($fDsAll.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fDsAll.FallbackModel -ne 'opencode-go/deepseek-v4.1-flash') 'deepseek-go-never-silently-substituted'
$dsExcl = @($fDsAll.PreventivelyExcluded | Where-Object { $_.Model -eq 'opencode-go/deepseek-v4.1-flash' -and $_.Reason -eq 'MODEL_DISABLED' })
Assert-CA ($dsExcl.Count -ge 1) 'deepseek-go-excluded-model-disabled'

# 34. Training consent recorded for this project; workspace setting unverified; no global toggle.
Assert-CA ([string]$pol.models.muse.data_policy.user_consent -eq 'accepted-training-2026-11-03' -and [string]$pol.models.muse.data_policy.training -match 'Meta') 'muse-training-consent-recorded'
Assert-CA ([string]$pol.models.muse.data_policy.workspace_requirement -eq 'Allow paid endpoints that train on request data') 'muse-workspace-requirement-named'
Assert-CA ([string]$pol.models.muse.data_policy.workspace_requirement_status -eq 'unverified-required') 'muse-workspace-setting-unverified'
Assert-CA ([string]$pol.models.iceman.data_policy.user_consent -eq 'accepted-training-2026-11-03' -and [string]$pol.models.iceman.data_policy.zdr -eq 'False') 'iceman-training-consent-recorded'

Write-Host ("RESULTS " + $script:pass + " PASS, " + $script:fail + " FAIL")
if ($script:fail -gt 0) { exit 1 }
exit 0
