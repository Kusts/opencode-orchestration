<#!
.SYNOPSIS
    Fable gate contract: Astra availability only, proved pre-execution (CA-FABLE-FIX).
.DESCRIPTION
    Fable is only an Astra-ordered audit candidate (HOLD, never dispatched).
    Astra is reached only after kernel-owned T4 Opus failure proof plus the
    dedicated exceptional budget authorization; technical fallback stays HOLD.
    A raw non-empty VerifiedFailureReceipt plus AttemptedModels containing
    Astra is NOT proof. VERIFIED_TASK_FAILURE never authorizes Fable; the
    functional path requires read-only task-kernel model-select with sticky proof.
    Productive native dispatch stays HOLD: the test-only DispatchExecutor seam
    makes EXACTLY ONE call (no retry, no automatic fallback).
    Run: pwsh -NoProfile -File scripts/v3/lib/OrchestrationModelRouterFableGate.tests.ps1
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationModelExecution.ps1')

$script:pass = 0
$script:fail = 0
function Assert-FG([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name"; $script:pass++ }
    else { Write-Host "[FAIL] $Name"; $script:fail++ }
}

# Kernel-owned selection is the only way to ENTER T4 (positive kernel->router
# selection lives in OrchestrationTaskKernelModelProof.tests.ps1). This shapes a
# fallback REQUEST only and never trusts a caller receipt.
$sT3Sel = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
$sT4 = $sT3Sel | Select-Object *
$sT4.Tier = 'T4'
$sT4.CatalogModel = 'claude-agent/opus'
Assert-FG ($sT4.Tier -eq 'T4' -and $sT4.CatalogModel -eq 'claude-agent/opus') 'fg-setup-T4-shape'
Assert-FG ([string]$sT3Sel.Tier -ne 'T4') 'fg-raw-receipts-never-enter-T4'

# 1. Astra availability with proved pre-execution evidence surfaces Fable as a
#    non-authorizing audit candidate (HOLD): ordered first, never dispatched.
$fPos = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fPos.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fPos.FallbackModel -eq $null -and $fPos.CandidateModel -eq 'claude-agent/fable') 'fg-positive-astra-availability-to-fable'
Assert-FG ($fPos.FallbackTier -eq 'T4' -and -not [bool]$fPos.IsAuthorized) 'fg-positive-tier-T4'

# 2. Opus must not jump ahead when Astra was the failed model; Fable is the
#    ordered audit candidate (never a generic dispatched fallback).
Assert-FG ($fPos.FallbackModel -ne 'claude-agent/opus') 'fg-no-opus-jump-ahead'
Assert-FG ($fPos.CandidateModel -eq 'claude-agent/fable' -and $fPos.FallbackModel -eq $null) 'fg-fable-before-generic'

# 3. VERIFIED_TASK_FAILURE with generic receipt is NOT proof (even with no-start flag).
$fVer = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra','claude-agent/opus') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:ca-fable' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fVer.FallbackModel -ne 'claude-agent/fable') 'fg-negative-verified-task-failure-blocked'
Assert-FG ($fVer.Status -eq 'KERNEL_MODEL_SELECT_REQUIRED' -and $fVer.FallbackModel -eq $null) 'fg-verified-failure-requires-kernel'

# 4. Mismatched task receipt still blocked.
$fMisTask = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:other-task-9' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fMisTask.FallbackModel -ne 'claude-agent/fable') 'fg-negative-mismatched-task-receipt'

# 5. Mismatched model receipt still blocked (Sol receipt does not prove Astra failure).
$fMisModel = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:sol-task-1' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fMisModel.FallbackModel -ne 'claude-agent/fable') 'fg-negative-mismatched-model-receipt'

# 6. Missing no-start proof blocked (availability reason but flag false/missing).
$fNoFlag = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fNoFlag.FallbackModel -ne 'claude-agent/fable') 'fg-negative-missing-no-start-proof'
Assert-FG ($fNoFlag.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') 'fg-missing-proof-exhausts'
$fFalseFlag = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $false -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fFalseFlag.FallbackModel -ne 'claude-agent/fable') 'fg-negative-explicit-false-no-start'

# 7. Ambiguous timeout: no replay, no Fable (both flag values).
$fTimeout = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'TIMEOUT' -NoExecutionStarted $false -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fTimeout.FallbackModel -ne 'claude-agent/fable') 'fg-negative-timeout-ambiguous'
Assert-FG ($fTimeout.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and $fTimeout.FallbackModel -eq $null) 'fg-timeout-holds-no-replay'
$fTimeoutTrue = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'TIMEOUT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fTimeoutTrue.FallbackModel -ne 'claude-agent/fable') 'fg-negative-timeout-even-with-flag'

# 8. FailedModel must be exactly canonical Astra ID.
$fWrongCase = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'OPENAI/GPT-6-ASTRA' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fWrongCase.FallbackModel -ne 'claude-agent/fable') 'fg-negative-noncanonical-failed-model'
$fWrongModel = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'claude-agent/opus' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra','claude-agent/opus') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fWrongModel.FallbackModel -ne 'claude-agent/fable') 'fg-negative-opus-failed-not-fable'

# 9. Fable without Claude capability proof blocked (honors order: falls to muse or exhausts, never Fable).
$fNoProof = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true
Assert-FG ($fNoProof.FallbackModel -ne 'claude-agent/fable') 'fg-negative-no-claude-proof'
$capExcl = @($fNoProof.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/fable' })
Assert-FG ($capExcl.Count -ge 1) 'fg-no-proof-exclusion-recorded'

# 10. Remote worker without claude-agent-remote blocked for Fable.
$fRemote = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -WorkerHost 'remote'
Assert-FG ($fRemote.FallbackModel -ne 'claude-agent/fable') 'fg-negative-remote-without-capability'
$remoteExclFg = @($fRemote.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/fable' -and $_.Reason -eq 'CLAUDE_REMOTE_UNPROVEN' })
Assert-FG ($remoteExclFg.Count -ge 1) 'fg-remote-exclusion-recorded'

# 11. Fable disabled via temp policy: never Fable (honors order to next or exhausts).
$tmpPol = Join-Path ([System.IO.Path]::GetTempPath()) ("fg-fable-disabled-" + [Guid]::NewGuid().ToString('N') + ".json")
try {
    $rawPol = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json') -Raw
    $j = ConvertFrom-Json -InputObject $rawPol
    $j.models.claude_fable.enabled = $false
    Set-Content -LiteralPath $tmpPol -Value (ConvertTo-Json -InputObject $j -Depth 20) -Encoding UTF8
    $fDis = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -PolicyPath $tmpPol
    Assert-FG ($fDis.FallbackModel -ne 'claude-agent/fable') 'fg-negative-fable-disabled'
} finally {
    if (Test-Path -LiteralPath $tmpPol) { Remove-Item -LiteralPath $tmpPol -Force -ErrorAction SilentlyContinue }
}

# 12. Dispatch-alias tamper: fable alias/model_id linkage mismatch never yields Fable.
$tmpPol2 = Join-Path ([System.IO.Path]::GetTempPath()) ("fg-fable-tamper-" + [Guid]::NewGuid().ToString('N') + ".json")
try {
    $rawPol2 = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json') -Raw
    $j2 = ConvertFrom-Json -InputObject $rawPol2
    $j2.models.claude_fable.alias = 'fable-tampered'
    Set-Content -LiteralPath $tmpPol2 -Value (ConvertTo-Json -InputObject $j2 -Depth 20) -Encoding UTF8
    $fTamper = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -PolicyPath $tmpPol2
    Assert-FG ($fTamper.FallbackModel -ne 'claude-agent/fable') 'fg-negative-alias-tamper'
    $tamperExclFg = @($fTamper.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/fable' -and $_.Reason -eq 'CLAUDE_ALIAS_MISMATCH' })
    Assert-FG ($tamperExclFg.Count -ge 1) 'fg-alias-mismatch-recorded'
} finally {
    if (Test-Path -LiteralPath $tmpPol2) { Remove-Item -LiteralPath $tmpPol2 -Force -ErrorAction SilentlyContinue }
}

# 12b. model_id linkage tamper: a fable entry pointing at another known alias
#      fails closed (no concrete mapping, no silent substitution).
$tmpPol3 = Join-Path ([System.IO.Path]::GetTempPath()) ("fg-fable-link-tamper-" + [Guid]::NewGuid().ToString('N') + ".json")
try {
    $rawPol3 = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\source\registry\model-routing-policy.json') -Raw
    $j3 = ConvertFrom-Json -InputObject $rawPol3
    $j3.models.claude_fable.model_id = 'claude-agent/opus'
    Set-Content -LiteralPath $tmpPol3 -Value (ConvertTo-Json -InputObject $j3 -Depth 20) -Encoding UTF8
    $fTamper3 = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true -PolicyPath $tmpPol3
    Assert-FG ($fTamper3.FallbackModel -ne 'claude-agent/fable') 'fg-negative-model-id-linkage-tamper'
    $tamperExclFg3 = @($fTamper3.PreventivelyExcluded | Where-Object { $_.Model -eq 'claude-agent/opus' -and $_.Reason -eq 'CLAUDE_ALIAS_MISMATCH' })
    Assert-FG ($tamperExclFg3.Count -ge 1) 'fg-model-id-linkage-mismatch-recorded'
} finally {
    if (Test-Path -LiteralPath $tmpPol3) { Remove-Item -LiteralPath $tmpPol3 -Force -ErrorAction SilentlyContinue }
}

# 13. Loop already attempted: Fable in attempted set never re-selected.
$fLoop = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra','claude-agent/fable','opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fLoop.FallbackModel -ne 'claude-agent/fable') 'fg-negative-loop-attempted'
Assert-FG ($fLoop.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') 'fg-loop-exhausts'

# 14. Role admissibility still enforced: tester cannot receive Fable (T4 prohibited).
$sTester = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'simple' -Risk 'low' -RequiresLlm $true -IgnoreUserConfig $true -NativeModelOverrideProven $true
$fTesterRole = Resolve-OrchestrationModelFallback -RequestedSelection $sTester -FailedModel 'openai/gpt-6-astra' -AttemptedModels @('openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fTesterRole.FallbackModel -ne 'claude-agent/fable') 'fg-negative-role-ineligible'

# 15. Fable is never a primary: selection yields Sol/Terra, never Fable.
Assert-FG ([string]$sT4.CatalogModel -ne 'claude-agent/fable') 'fg-fable-not-a-primary'
$sFablePrimary = Resolve-OrchestrationModelSelection -AgentName 'coder' -FailureCount 3 -IgnoreUserConfig $true -NativeModelOverrideProven $true
Assert-FG ([string]$sFablePrimary.CatalogModel -ne 'claude-agent/fable' -and [string]$sFablePrimary.Tier -ne 'T4') 'fg-no-kernel-proof-no-t4-no-fable'

# 16. T4/Astra still require kernel-owned proof: Sol transport never yields Astra;
#     an unproven capability claim never yields T4/Astra.
$fSolTrans = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fSolTrans.FallbackModel -ne 'openai/gpt-6-astra') 'fg-sol-transport-not-astra'
$fSolUnproven = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -TriggerReason 'VERIFIED_TASK_FAILURE' -IgnoreUserConfig $true -ClaudeAgentProven $true
Assert-FG ($fSolUnproven.FallbackModel -ne 'openai/gpt-6-astra') 'fg-unproven-no-astra'
$fSolKernelClaim = Resolve-OrchestrationModelFallback -RequestedSelection $sT4 -FailedModel 'openai/gpt-6.1-sol' -AttemptedModels @('openai/gpt-6.1-sol') -TriggerReason 'VERIFIED_TASK_FAILURE' -VerifiedFailureReceipt 'verified:fg-any' -TaskId 'fg-no-such-task' -TasksDir 'fg-no-such-dir' -RepoRoot 'fg-no-such-repo' -IgnoreUserConfig $true
Assert-FG ($fSolKernelClaim.FallbackModel -ne 'openai/gpt-6-astra') 'fg-caller-receipt-no-kernel-proof-no-astra'

# 17. ModelExecution seam: EXACTLY ONE call, no retry, no automatic fallback
#     (native pre-dispatch fallback stays HOLD).
$script:fgSeq = @()
$dispatchSingle = {
    param([string]$Model, [string]$Agent, [string]$TaskId)
    $script:fgSeq += $Model
    return [pscustomobject]@{ Model = $Model }
}
$execSingle = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchSingle -TaskId 'fg-exec-single'
Assert-FG (($script:fgSeq.Count -eq 1) -and ([string]$execSingle.status -eq 'EXECUTED_VERIFIED')) 'fg-exec-single-call-verified'
$script:fgAmb = @()
$dispatchAmb = {
    param([string]$Model, [string]$Agent, [string]$TaskId)
    $script:fgAmb += $Model
    return [pscustomobject]@{ FailureClass = 'TIMEOUT'; NoExecutionStarted = $false }
}
$execAmb = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchAmb -TaskId 'fg-exec-amb'
Assert-FG (($script:fgAmb.Count -eq 1) -and ([string]$execAmb.status -ne 'EXECUTED_VERIFIED')) 'fg-exec-ambiguous-no-replay'
$script:fgHold = @()
$dispatchHold = {
    param([string]$Model, [string]$Agent, [string]$TaskId)
    $script:fgHold += $Model
    return [pscustomobject]@{ FailureClass = 'RATE_LIMIT'; NoExecutionStarted = $true }
}
$execHold = Invoke-OrchestrationModelExecution -AgentName 'coder' -NativeModelOverrideProven $true -DispatchExecutor $dispatchHold -TaskId 'fg-exec-hold'
Assert-FG (($script:fgHold.Count -eq 1) -and ([string]$execHold.status -ceq 'PROOF_ABSENT')) 'fg-exec-no-start-hold-no-retry'

Write-Host ("RESULTS " + $script:pass + " PASS, " + $script:fail + " FAIL")
if ($script:fail -gt 0) { exit 1 }
exit 0
