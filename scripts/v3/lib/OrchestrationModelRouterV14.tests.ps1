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
# DEPRECATED_UNTRUSTED: arbitrary bool/string never authorizes T4 without kernel-owned proof.
$sT4 = Resolve-OrchestrationModelSelection -AgentName 'coder' -FailureCount 3 -T3FailureVerified $true -T3FailureReceipt 'verified:task-id-1' -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-V14 ($sT4.Tier -ne 'T4') 'arbitrary-T3-receipt-does-not-escalate-T4'
Assert-V14 ($sT4.Tier -eq 'T3') 'arbitrary-T3-receipt-fail-closed-T3'

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
# DeepSeek Go is BLOCKED (ZDR_EXPIRED_UNCONFIRMED): the chain exhausts instead of
# silently substituting it, while other admissible routes stay operational.
Assert-V14 ($fT3Go.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fT3Go.FallbackModel -eq $null) 'T3-transport-exhausts-deepseek-blocked'
$dsGoExcl = @($fT3Go.PreventivelyExcluded | Where-Object { $_.Model -eq 'opencode-go/deepseek-v4.1-flash' -and $_.Reason -eq 'MODEL_DISABLED' })
Assert-V14 ($dsGoExcl.Count -ge 1) 'deepseek-go-model-disabled'
Assert-V14 ($pol.models.deepseek_go.enabled -eq $false -and [string]$pol.models.deepseek_go.availability_reason -eq 'ZDR_EXPIRED_UNCONFIRMED') 'deepseek-go-blocked-ZDR-unconfirmed'
# Planner policy: Luna primary, Haiku the only recorded fallback (T2, build eligible).
Assert-V14 ([string]$pol.planner.fallback -eq 'claude_haiku' -and [string]$pol.planner.fallback_model_id -eq 'claude-agent/haiku') 'planner-fallback-haiku-policy'
Assert-V14 ((@($pol.role_profiles.build.alternatives).Count -eq 1) -and (@($pol.role_profiles.build.alternatives)[0] -eq 'claude_haiku')) 'build-alternatives-haiku-only'
# Privacy: training consent recorded per project (2026-11-03); Muse workspace
# requirement is required but UNVERIFIED (never claim it is enabled).
Assert-V14 ([string]$pol.models.muse.data_policy.user_consent -eq 'accepted-training-2026-11-03' -and [string]$pol.models.iceman.data_policy.user_consent -eq 'accepted-training-2026-11-03') 'training-consent-recorded-project'
Assert-V14 ([string]$pol.models.muse.data_policy.workspace_requirement_status -eq 'unverified-required') 'muse-workspace-setting-unverified'
# Alias->concrete runtime resolution stays unresolved; only the recorded
# inventory expectation is asserted (never actual version resolution).
Assert-V14 ([string]$pol.models.claude_haiku.resolution_status -eq 'runtime-unverified' -and [string]$pol.models.claude_sonnet.resolution_status -eq 'runtime-unverified') 'alias-resolution-runtime-unverified'
# Availability never escalates tier: a T2 availability chain that is fully
# attempted (and has no Claude capability/no-start proof) exhausts and never
# picks Terra/T3. T3/T4 entry still requires the kernel-owned incapacity proof.
$sT2Chain = Resolve-OrchestrationModelSelection -AgentName 'coder' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fT2NoEsc = Resolve-OrchestrationModelFallback -RequestedSelection $sT2Chain -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor','openai/gpt-6-luna') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fT2NoEsc.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK' -and $fT2NoEsc.FallbackModel -eq $null -and $fT2NoEsc.FallbackTier -ne 'T3') 'availability-never-escalates-to-T3'
$t3Blocked = @($fT2NoEsc.PreventivelyExcluded | Where-Object { $_.Reason -eq 'T3_ESCALATION_REQUIRES_INCAPACITY_PROOF' })
Assert-V14 ($t3Blocked.Count -ge 1) 'T3-escalation-blocked-on-availability'
# T4-shaped request: kernel-owned selection is the only way to ENTER T4 (covered
# by KernelProof/ModelProof suites); this shapes the request to exercise the T4
# transport route without trusting any caller receipt.
$sT4Shape = $sT4 | Select-Object *
$sT4Shape.Tier = 'T4'
$sT4Shape.CatalogModel = 'openai/gpt-6.1-sol'
$fSolTransport = Resolve-OrchestrationModelFallback -RequestedSelection $sT4Shape -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-V14 ($fSolTransport.Status -eq 'AUTHORIZED' -and $fSolTransport.FallbackModel -eq 'opencode-go/muse-spark-1.3-contributor') 'T4-transport-failure-to-muse-not-astra'
$fSolQuality = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -AttemptedModels @('openai/gpt-6.1-sol') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:task-id-1' -IgnoreUserConfig $true
Assert-V14 ($fSolQuality.FallbackModel -ne 'openai/gpt-6-astra') 'arbitrary-quality-receipt-does-not-use-astra'
$fSolUnproven = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'VERIFIED_TASK_FAILURE' -IgnoreUserConfig $true
Assert-V14 ($fSolUnproven.FallbackModel -ne 'openai/gpt-6-astra') 'unproven-quality-failure-does-not-use-astra'
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
Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
