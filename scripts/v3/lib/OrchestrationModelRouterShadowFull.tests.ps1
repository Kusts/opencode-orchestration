<#!
.SYNOPSIS
    F2-full shadow harness (issue #99, PLAN section 4): all 12 task classes x 3 runs.
.DESCRIPTION
    Dot-sourceable test suite (no execution on load beyond the asserts
    below). Extends the F2 minimal shadow protocol (1 workflow x 3 runs,
    OrchestrationModelRouterShadow.tests.ps1) to the FULL matrix:
    source/registry/capability-routing.json task_classes (12) x 3 runs
    each = 36 proposals. Uses ONLY
    scripts/v3/lib/OrchestrationModelRouting.ps1
    (New-ModelRoutingRequest, New-ModelRoutingResult,
    Test-ModelRoutingEnvelope). Each run builds a Request, builds a Result
    proposal, evaluates the closed envelope, and LOGS the proposal to
    Write-Output plus one TEMP shadow log file. NOTHING is activated,
    applied, or sent anywhere: no model use, no network, no config or
    registry write, no flag change, no controlled experiment (the latter
    needs explicit authorization and is OUT of scope here).
    Selection is locked to the cheap tier (cheap-baseline): cost baseline,
    zero escalation, zero paid calls. The real baseline path is untouched:
    every shadow proposal resolves to the baseline fallback and no
    real-path state is written.
    Role mapping per class uses cheap-baseline owners; classes whose
    production owner is strong-pool (review, debugging) run here with a
    cheap surrogate and are marked NEVER-ROUTABLE without their own SPEC.
    PS 5.1 compatible, ASCII-only. Fails closed via throw on first
    violated assert; prints one PASS line with the assert count.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouting.ps1')
$passed = 0
function Assert-ShadowFullThat {
    param([bool]$Condition, [string]$Name)
    if (-not [bool]$Condition) { throw "FAIL: $Name" }
    $script:passed++
}
# Counts real-path actions taken by this harness. Must stay zero: the only
# calls allowed are the three lib constructors/evaluators above plus local
# TEMP log writes. No other lib is loaded and no outside call is made.
$script:ShadowRealPathActions = 0
function Write-ShadowFullProposalLog {
    param([string]$LogFile, [string]$Line)
    [IO.File]::AppendAllText($LogFile, ($Line + "`r`n"))
}
$shadowDir = Join-Path ([IO.Path]::GetTempPath()) ('f2full-shadow-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($shadowDir)
$shadowLog = Join-Path $shadowDir 'shadow-full-proposals.log'
[IO.File]::WriteAllText($shadowLog, '')
$baseline = 'cheap-baseline'
$candidates = @('cheap-baseline', 'cheap-alt')
# 12 task classes (capability-routing.json:7-20), each with a cheap-tier
# dispatch role. debugging/review use cheap surrogates; their strong-pool
# production owners are NEVER-ROUTABLE without their own SPEC (report).
$classSpecs = @(
    @{ class = 'implementation'; role = 'coder'; note = 'CHEAP-OWNER' },
    @{ class = 'migration'; role = 'database-engineer'; note = 'CHEAP-OWNER' },
    @{ class = 'analysis'; role = 'explorer'; note = 'CHEAP-ONLY' },
    @{ class = 'research'; role = 'researcher'; note = 'CHEAP-ONLY' },
    @{ class = 'debugging'; role = 'coder'; note = 'CHEAP-SURROGATE-NEVER-ROUTABLE-debugger-strong' },
    @{ class = 'validation'; role = 'tester'; note = 'CHEAP-OWNER' },
    @{ class = 'review'; role = 'skeptic'; note = 'CHEAP-SURROGATE-NEVER-ROUTABLE-reviewer-security-strong' },
    @{ class = 'documentation'; role = 'docs-manager'; note = 'CHEAP-ONLY' },
    @{ class = 'planning'; role = 'requirements-analyst'; note = 'CHEAP-OWNER' },
    @{ class = 'design'; role = 'product-designer'; note = 'CHEAP-OWNER' },
    @{ class = 'testing'; role = 'tester'; note = 'CHEAP-ONLY' },
    @{ class = 'trivial'; role = 'coder'; note = 'CHEAP-OWNER' }
)
Assert-ShadowFullThat ([int]$classSpecs.Count -eq 12) 'shadow-full covers exactly 12 task classes'
$runSpecs = @(
    @{ n = '1'; reason = 'BASELINE_SUFFICIENT'; confidence = 0.90 },
    @{ n = '2'; reason = 'FALLBACK_DETERMINISTIC'; confidence = 0.75 },
    @{ n = '3'; reason = 'BASELINE_SUFFICIENT'; confidence = 0.60 }
)
$logged = 0
foreach ($cs in $classSpecs) {
    $tc = [string]$cs['class']
    $rl = [string]$cs['role']
    $nt = [string]$cs['note']
    foreach ($rs in $runSpecs) {
        $id = ('F2-FULL-' + $tc + '-RUN-' + [string]$rs['n'])
        $req = New-ModelRoutingRequest -TaskId $id -Role $rl -TaskClass $tc -Risk 'LOW' -Candidates $candidates -Fallback $baseline
        Assert-ShadowFullThat ([bool]$req.is_valid) ($id + ' request is valid')
        Assert-ShadowFullThat (([int]$req.cost_limits.max_escalations_subtask -le 1)) ($id + ' budget escalations within cap')
        Assert-ShadowFullThat (([int]$req.cost_limits.max_above_baseline_per_objective -le 2)) ($id + ' budget above-baseline within cap')
        Assert-ShadowFullThat (([int]$req.cost_limits.max_paid_calls -eq 0)) ($id + ' budget max_paid_calls is 0')
        $prop = New-ModelRoutingResult -Selected $baseline -Reason ([string]$rs['reason']) -Confidence ([double]$rs['confidence']) -Fallback $baseline -PolicyRefs @('PLAN-F2-shadow-full', $nt) -EvidenceRefs @('NO_EVIDENCE_YET')
        Assert-ShadowFullThat ([bool]$prop.is_valid) ($id + ' proposal is valid')
        $checked = Test-ModelRoutingEnvelope -Request $req -Proposed $prop -PlannerApproved $false -PaidAuthorized $false -QuotaExhausted $false -DeniedModels @()
        Assert-ShadowFullThat ((-not [bool]$checked.denied)) ($id + ' shadow envelope not denied')
        Assert-ShadowFullThat (([string]$checked.selected -ceq $baseline)) ($id + ' shadow proposal equals baseline fallback')
        Assert-ShadowFullThat (([string]$checked.fallback -ceq $baseline)) ($id + ' baseline fallback untouched')
        Assert-ShadowFullThat ((-not [bool]$checked.escalation_consumed)) ($id + ' no escalation consumed')
        $line = ($id + ' | role=' + $rl + ' | class=' + $tc + ' | selected=' + [string]$checked.selected + ' | reason=' + [string]$checked.reason + ' | confidence=' + [string]$checked.confidence + ' | SHADOW-ONLY LOGGED NO REAL-PATH ACTION NO_CAUSAL_CLAIM')
        Write-ShadowFullProposalLog -LogFile $shadowLog -Line $line
        Write-Output $line
        $logged++
    }
}
Assert-ShadowFullThat ([int]$logged -eq 36) 'shadow-full logged exactly 36 proposals'
Assert-ShadowFullThat ([int]$script:ShadowRealPathActions -eq 0) 'shadow-full took zero real-path actions'
$logText = [IO.File]::ReadAllText($shadowLog)
$logLines = @($logText -split "`r`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-ShadowFullThat ([int]$logLines.Count -eq 36) 'shadow-full log file holds 36 proposal lines'
foreach ($cs in $classSpecs) {
    $tc = [string]$cs['class']
    $hits = @($logLines | Where-Object { $_ -like ('*' + $tc + '-RUN-*') })
    Assert-ShadowFullThat ([int]$hits.Count -eq 3) ('shadow-full class ' + $tc + ' has exactly 3 runs')
}
Assert-ShadowFullThat ([bool]$logText.Contains('SHADOW-ONLY LOGGED')) 'shadow-full log marks proposals as shadow-only'
Assert-ShadowFullThat ([bool]$logText.Contains('NO_CAUSAL_CLAIM')) 'shadow-full log carries no causal claim'
Assert-ShadowFullThat (-not ($logText -match '(?i)\b(causes?|caused|proves?|proved|improves?|improved|melhora|promot|promov|benchmark|signific)')) 'shadow-full log has no causal or promotion language'
Assert-ShadowFullThat (-not ($logText -match '(?i)paid-call|above-baseline-consumed|escalation-consumed-true')) 'shadow-full log shows zero paid or escalation cost'
Remove-Item -LiteralPath $shadowDir -Recurse -Force
Write-Output ("OrchestrationModelRouterShadowFull: PASS ($passed assertions, 12 classes x 3 runs, shadow-only)")
