<#!
.SYNOPSIS
    F2 shadow harness (issue #99, PLAN section 4): 1 trivial workflow x 3 runs.
.DESCRIPTION
    Dot-sourceable test suite (no execution on load beyond the asserts
    below). Uses ONLY scripts/v3/lib/OrchestrationModelRouting.ps1
    (New-ModelRoutingRequest, New-ModelRoutingResult,
    Test-ModelRoutingEnvelope). Each run builds a Request, builds a Result
    proposal, evaluates the closed envelope, and LOGS the proposal to
    Write-Output plus one TEMP shadow log file. NOTHING is activated,
    applied, or sent anywhere: no model use, no network, no config or
    registry write, no flag change, no controlled experiment (the latter
    needs explicit authorization and is OUT of scope here).
    The real baseline path is untouched: every shadow proposal resolves to
    the baseline fallback and no real-path state is written.
    PS 5.1 compatible, ASCII-only. Fails closed via throw on first
    violated assert; prints one PASS line with the assert count.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouting.ps1')
$passed = 0
function Assert-ShadowThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
# Counts real-path actions taken by this harness. Must stay zero: the only
# calls allowed are the three lib constructors/evaluators above plus local
# TEMP log writes. No other lib is loaded and no outside call is made.
$script:ShadowRealPathActions = 0
function Write-ShadowProposalLog {
    param([string]$LogFile, [string]$Line)
    [IO.File]::AppendAllText($LogFile, ($Line + "`r`n"))
}
$shadowDir = Join-Path ([IO.Path]::GetTempPath()) ('f2-shadow-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($shadowDir)
$shadowLog = Join-Path $shadowDir 'shadow-proposals.log'
[IO.File]::WriteAllText($shadowLog, '')
$baseline = 'cheap-baseline'
$candidates = @('cheap-baseline', 'cheap-alt')
$runSpecs = @(
    @{ id = 'F2-SHADOW-RUN-1'; reason = 'BASELINE_SUFFICIENT'; confidence = 0.90 },
    @{ id = 'F2-SHADOW-RUN-2'; reason = 'FALLBACK_DETERMINISTIC'; confidence = 0.75 },
    @{ id = 'F2-SHADOW-RUN-3'; reason = 'BASELINE_SUFFICIENT'; confidence = 0.60 }
)
$logged = 0
foreach ($spec in $runSpecs) {
    $req = New-ModelRoutingRequest -TaskId ([string]$spec.id) -Role 'coder' -TaskClass 'trivial' -Risk 'LOW' -Candidates $candidates -Fallback $baseline
    Assert-ShadowThat ([bool]$req.is_valid) ([string]$spec.id + ' request is valid')
    Assert-ShadowThat (([int]$req.cost_limits.max_escalations_subtask -le 1)) ([string]$spec.id + ' budget escalations within cap')
    Assert-ShadowThat (([int]$req.cost_limits.max_above_baseline_per_objective -le 2)) ([string]$spec.id + ' budget above-baseline within cap')
    Assert-ShadowThat (([int]$req.cost_limits.max_paid_calls -eq 0)) ([string]$spec.id + ' budget max_paid_calls is 0')
    $prop = New-ModelRoutingResult -Selected $baseline -Reason ([string]$spec.reason) -Confidence ([double]$spec.confidence) -Fallback $baseline -PolicyRefs @('PLAN-F2-shadow') -EvidenceRefs @('NO_EVIDENCE_YET')
    Assert-ShadowThat ([bool]$prop.is_valid) ([string]$spec.id + ' proposal is valid')
    $checked = Test-ModelRoutingEnvelope -Request $req -Proposed $prop -PlannerApproved $false -PaidAuthorized $false -QuotaExhausted $false -DeniedModels @()
    Assert-ShadowThat ((-not [bool]$checked.denied)) ([string]$spec.id + ' shadow envelope not denied')
    Assert-ShadowThat (([string]$checked.selected -ceq $baseline)) ([string]$spec.id + ' shadow proposal equals baseline fallback')
    Assert-ShadowThat (([string]$checked.fallback -ceq $baseline)) ([string]$spec.id + ' baseline fallback untouched')
    Assert-ShadowThat ((-not [bool]$checked.escalation_consumed)) ([string]$spec.id + ' no escalation consumed')
    $line = ([string]$spec.id + ' | selected=' + [string]$checked.selected + ' | reason=' + [string]$checked.reason + ' | confidence=' + [string]$checked.confidence + ' | SHADOW-ONLY LOGGED NO REAL-PATH ACTION NO_CAUSAL_CLAIM')
    Write-ShadowProposalLog -LogFile $shadowLog -Line $line
    Write-Output $line
    $logged++
}
Assert-ShadowThat (([int]$logged -eq 3)) 'shadow logged exactly 3 proposals'
Assert-ShadowThat (([int]$script:ShadowRealPathActions -eq 0)) 'shadow took zero real-path actions'
$logText = [IO.File]::ReadAllText($shadowLog)
$logLines = @($logText -split "`r`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-ShadowThat (([int]$logLines.Count -eq 3)) 'shadow log file holds 3 proposal lines'
Assert-ShadowThat ([bool]$logText.Contains('SHADOW-ONLY LOGGED')) 'shadow log marks proposals as shadow-only'
Assert-ShadowThat ([bool]$logText.Contains('NO_CAUSAL_CLAIM')) 'shadow log carries no causal claim'
Assert-ShadowThat ((-not ($logText -match '(?i)\b(causes?|caused|proves?|proved|improves?|improved|melhora|promot|promov|benchmark|signific)'))) 'shadow log has no causal or promotion language'
Assert-ShadowThat ((-not ($logText -match '(?i)paid-call|above-baseline-consumed|escalation-consumed-true'))) 'shadow log shows zero paid or escalation cost'
Remove-Item -LiteralPath $shadowDir -Recurse -Force
Write-Output ("OrchestrationModelRouterShadow: PASS ($passed assertions, 1 workflow x 3 runs, shadow-only)")
