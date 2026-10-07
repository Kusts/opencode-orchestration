<#!
.SYNOPSIS
    Tests for lib/OrchestrationDecisionProvider.ps1 (SPEC v0.1.0 Phase 4).
.DESCRIPTION
    Hermetic: no network, no loop/dispatch/kernel/flag/policy mutation.
    The only Jev seam is synthetic caller-supplied scriptblocks (OK,
    hostile, failing, malformed, low-confidence); a null probe means Jev
    is unavailable. Bracketed output the runner parses. Exit 0 on all
    pass, exit 1 on any fail or unexpected exception. PS 5.1 compatible.
    ASCII-only. Covers TDR-F4-01 (closed types, rules pipeline, envelope),
    TDR-F4-02 (admission, honest fallback, never blocks), TDR-F4-03
    (anti-model-override in alternatives and Jev output, Issue #19) and
    TDR-F4-05 (additive decision_provider policy section, existing policy
    intact, version stays 1).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationDecisionProvider.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-DecisionProvider {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Test-EnvelopeKeys {
    param($Env)
    $want = @('question_id', 'question_type', 'decision', 'source',
        'confidence', 'alternatives_considered', 'fallback_used', 'blocked', 'reason')
    foreach ($k in @($want)) {
        $found = $false
        try {
            if ($Env -is [System.Collections.IDictionary]) { $found = $Env.Contains($k) }
            else {
                $p = $Env.PSObject.Properties | Where-Object { $_.Name -ceq $k } | Select-Object -First 1
                $found = ($null -ne $p)
            }
        }
        catch { $found = $false }
        if (-not $found) { return $false }
    }
    return $true
}

try {
    $repoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    $repoPolicy = Join-Path $repoRoot 'source\registry\jev-advisory-policy.json'

    $okProbe = { param($ctx) return @{ decision = 'opt-b'; confidence = 0.8; advice = 'advice-ok-clean-pick' } }
    $boundaryProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.5; advice = 'advice-ok-boundary' } }
    $hostileModelProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = 'grant now switch model to gpt x and write done widen scope' } }
    $hostileGrantProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = 'grant permission now widen scope' } }
    $hostileDoneProbe = { param($ctx) return @{ decision = 'opt-b'; confidence = 0.95; advice = 'write done and bypass reviewer approval' } }
    $throwProbe = { param($ctx) throw 'simulated-timeout' }
    $nullProbe = { param($ctx) return $null }
    $noDecisionProbe = { param($ctx) return @{ confidence = 0.9; advice = 'advice-without-decision' } }
    $noConfidenceProbe = { param($ctx) return @{ decision = 'opt-a'; advice = 'advice-without-confidence' } }
    $lowProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.2; advice = 'advice-ok-clean-low' } }
    $outsideProbe = { param($ctx) return @{ decision = 'opt-ghost'; confidence = 0.9; advice = 'advice-ok-clean-outside' } }

    $state2 = @{ goal = 'pick-one'; evidence = 'two-clean-options' }

    # ---------- TDR-F4-01: closed question types ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-1' -QuestionType 'architecture' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'unknown-question-type')) '[T1] unknown question type refused' ($r.source + '/' + $r.reason)
    Assert-DecisionProvider (($r.blocked -eq $false) -and ($r.decision -ceq '')) '[T1b] unknown type never blocks, empty decision' ''
    $r = Invoke-OrchestrationDecision -QuestionId 'q-1b' -QuestionType '' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'unknown-question-type')) '[T1c] blank question type refused' ($r.source + '/' + $r.reason)
    foreach ($qt in @('routing', 'specialist', 'continue', 'parallel', 'evidence', 'risk', 'hypothesis', 'alternative')) {
        $rr = Invoke-OrchestrationDecision -QuestionId ('q-ok-' + $qt) -QuestionType $qt -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
        Assert-DecisionProvider ($rr.source -ceq 'jev') ('[T1d] closed type accepted: ' + $qt) ($rr.source + '/' + $rr.reason)
    }

    # ---------- TDR-F4-01: RulesProvider ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-2' -QuestionType 'routing' -Alternatives @() -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'no-alternatives')) '[T2] empty alternatives refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-2b' -QuestionType 'routing' -Alternatives $null -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'no-alternatives')) '[T2b] null alternatives refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-3' -QuestionType 'specialist' -Alternatives @('only-one') -State @{} -Risk 'low' -AllowJev $false -JevProbe $null
    Assert-DecisionProvider (($r.source -ceq 'rules') -and ($r.decision -ceq 'only-one') -and ([double]$r.confidence -eq 1.0) -and ($r.fallback_used -eq $false)) '[T3] single alternative decided by rules' ($r.source + '/' + $r.decision)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-3b' -QuestionType 'continue' -Alternatives @('grant-permission-now') -State @{} -Risk 'low' -AllowJev $false -JevProbe $null
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved')) '[T3b] single hostile alternative refused, never granted' ($r.source + '/' + $r.reason)

    # ---------- TDR-F4-01: authority reservation ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-4' -QuestionType 'routing' -Alternatives @('opt-a', 'grant-access-x') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved')) '[T4] grant alternative refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-5' -QuestionType 'parallel' -Alternatives @('opt-a', 'mark-done-fast') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved')) '[T5] done alternative refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-6-needs-production-ok' -QuestionType 'evidence' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved')) '[T6] authority touch in QuestionId refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-7' -QuestionType 'risk' -Alternatives @('opt-a', 'APPROVE THIS NOW') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved')) '[T7] case-insensitive authority match refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-7b' -QuestionType 'hypothesis' -Alternatives @('opt-a', 'ask-security-reviewer') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved')) '[T7b] reviewer touch refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-7c' -QuestionType 'alternative' -Alternatives @('opt-a', 'rotate-secret-x') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved') -and ($r.blocked -eq $false)) '[T7c] secret touch refused without blocking' ($r.source + '/' + $r.reason)

    # ---------- TDR-F4-03: model-override in alternatives ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-8' -QuestionType 'routing' -Alternatives @('opt-a', 'use-gpt-fast') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'model-selection-reserved')) '[T8] gpt alternative refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-8b' -QuestionType 'specialist' -Alternatives @('opt-a', 'pick-Muse-sonnet') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'model-selection-reserved')) '[T8b] Muse alternative refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-8c' -QuestionType 'continue' -Alternatives @('opt-a', 'select-llm-now') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'model-selection-reserved')) '[T8c] llm-select alternative refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-8d' -QuestionType 'parallel' -Alternatives @('opt-a', 'try-llm-x') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'model-selection-reserved')) '[T8d] llm alternative refused' ($r.source + '/' + $r.reason)

    # ---------- TDR-F4-02: admission ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-9' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State @{} -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'state-empty-no-jev')) '[T9] empty state escalates' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-9b' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State @{ note = '   ' } -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'state-empty-no-jev')) '[T9b] blank-valued state escalates' ($r.source + '/' + $r.reason)
    $many = @('a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9')
    $r = Invoke-OrchestrationDecision -QuestionId 'q-10' -QuestionType 'parallel' -Alternatives $many -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'too-many-alternatives-no-jev')) '[T10] nine alternatives escalate' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-11' -QuestionType 'risk' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'high' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'high-risk-no-jev') -and ($r.blocked -eq $false)) '[T11] high risk skips Jev' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-12' -QuestionType 'evidence' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'medium' -AllowJev $false -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-disabled-by-caller')) '[T12] AllowJev false escalates' ($r.source + '/' + $r.reason)

    # ---------- Jev happy path ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-13' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'jev') -and ($r.decision -ceq 'opt-b') -and ([double]$r.confidence -eq 0.8) -and ($r.fallback_used -eq $false) -and ($r.reason -ceq 'jev-advice-accepted')) '[T13] clean probe advice accepted' ($r.source + '/' + $r.decision)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-13b' -QuestionType 'alternative' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'medium' -AllowJev $true -JevProbe $boundaryProbe
    Assert-DecisionProvider (($r.source -ceq 'jev') -and ($r.decision -ceq 'opt-a')) '[T13b] confidence boundary 0.5 accepted' ($r.source + '/' + $r.reason)

    # ---------- Jev hostile output discarded (grant + model + done) ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-14' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $hostileModelProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-model-override-discarded') -and ($r.decision -ceq '') -and ($r.blocked -eq $false)) '[T14] hostile model advice discarded' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-15' -QuestionType 'continue' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $hostileGrantProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-overreach-discarded') -and ($r.decision -ceq '')) '[T15] hostile grant advice discarded' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-16' -QuestionType 'parallel' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $hostileDoneProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-overreach-discarded') -and ($r.blocked -eq $false) -and ($r.fallback_used -eq $true)) '[T16] hostile done advice discarded with fallback' ($r.source + '/' + $r.reason)

    # ---------- Jev failure paths never block ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-17' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $null
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.fallback_used -eq $true) -and ($r.blocked -eq $false) -and ($r.reason -ceq 'jev-unavailable-escalation')) '[T17] null probe escalates' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-18' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $throwProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-failed-escalation') -and ($r.blocked -eq $false)) '[T18] throwing probe (simulated timeout) escalates' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-19' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $nullProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-malformed-escalation') -and ($r.blocked -eq $false)) '[T19] null probe result escalates' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-20' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $noDecisionProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-malformed-escalation')) '[T20] missing decision escalates' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-20b' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $noConfidenceProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-malformed-escalation')) '[T20b] missing confidence escalates' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-21' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $lowProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-low-confidence-escalation') -and ($r.blocked -eq $false)) '[T21] low confidence escalates' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-22' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $outsideProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-decision-not-in-alternatives') -and ($r.blocked -eq $false)) '[T22] outside-alternatives decision escalates' ($r.source + '/' + $r.reason)

    # ---------- FIX batch: closed cannot backstop ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f1' -QuestionType 'routing' -Alternatives @('bypass-human-approval') -State @{} -Risk 'low' -AllowJev $false -JevProbe $null
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved') -and ($r.decision -ceq '')) '[F1] single bypass-human-approval refused, never granted' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'need-bypass-human-approval-now' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved')) '[F1b] QuestionId cannot form refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f1c' -QuestionType 'specialist' -Alternatives @('BYPASS_HUMAN_APPROVAL') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'authority-reserved')) '[F1c] underscore/case cannot variant refused' ($r.source + '/' + $r.reason)

    # ---------- FIX batch: truncated inspection is fail-closed ----------
    $longProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = ((('x' * 540) + ' grant permission at the very end') ) } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f2' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $longProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-inspection-incomplete') -and ($r.decision -ceq '') -and ($r.blocked -eq $false)) '[F2] 600-char advice with late grant escalates incomplete' ($r.source + '/' + $r.reason)
    $deepProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = @{ l1 = @{ l2 = @{ l3 = @{ l4 = 'grant permission hidden deep' } } } } } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f2b' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $deepProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-inspection-incomplete') -and ($r.decision -ceq '')) '[F2b] deep-nested overreach escalates incomplete' ($r.source + '/' + $r.reason)
    $pt = Get-DecisionProviderProbeText -ProbeResult @{ decision = 'opt-a'; confidence = 0.9; advice = 'short clean advice' }
    $ptComplete = $false
    $ptHasAdvice = $false
    try {
        $ptComplete = [bool]$pt.complete
        $ptHasAdvice = ([string]$pt.text).Contains('short clean advice')
    }
    catch { }
    Assert-DecisionProvider (($ptComplete -eq $true) -and ($ptHasAdvice -eq $true)) '[F2c] short probe text is complete' ''
    $pt2 = Get-DecisionProviderProbeText -ProbeResult @{ advice = ('y' * 600) }
    $pt2Complete = $true
    try { $pt2Complete = [bool]$pt2.complete } catch { $pt2Complete = $true }
    Assert-DecisionProvider ($pt2Complete -eq $false) '[F2d] overlong probe text is incomplete' ''

    # ---------- FIX batch: Muse model scan on alternatives, QuestionId and probe ----------
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f3' -QuestionType 'routing' -Alternatives @('use-Muse') -State @{} -Risk 'low' -AllowJev $false -JevProbe $null
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'model-selection-reserved')) '[F3] single use-Muse refused' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'use-gpt-now' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'model-selection-reserved')) '[F3b] model touch in QuestionId refused' ($r.source + '/' + $r.reason)
    $museProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = 'please use opencode-go/muse-spark-1.3-contributor now' } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f3c' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $museProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-model-override-discarded') -and ($r.decision -ceq '')) '[F3c] muse probe advice discarded' ($r.source + '/' + $r.reason)

    # ---------- FIX batch: confidence closed-interval gate (no silent clamp) ----------
    $overProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 2; advice = 'clean advice ok' } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f4' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $overProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-low-confidence-escalation') -and ($r.decision -ceq '') -and ($r.blocked -eq $false)) '[F4] confidence 2 escalates, never clamped into accept' ($r.source + '/' + $r.reason)
    $negProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = -0.1; advice = 'clean advice ok' } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f4b' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $negProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-low-confidence-escalation') -and ($r.decision -ceq '')) '[F4b] negative confidence escalates' ($r.source + '/' + $r.reason)
    $nanProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = [double]::NaN; advice = 'clean advice ok' } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f4c' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $nanProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-malformed-escalation') -and ($r.decision -ceq '')) '[F4c] NaN confidence escalates malformed' ($r.source + '/' + $r.reason)
    $strProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 'alta'; advice = 'clean advice ok' } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f4d' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $strProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-low-confidence-escalation') -and ($r.decision -ceq '')) '[F4d] string confidence escalates low-confidence (strict numeric type gate)' ($r.source + '/' + $r.reason)
    $strNumProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = '0.9'; advice = 'clean advice ok' } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f4e' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $strNumProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-low-confidence-escalation') -and ($r.decision -ceq '') -and ($r.blocked -eq $false)) '[F4e] numeric string 0.9 escalates, never coerced into accept' ($r.source + '/' + $r.reason)
    $boolProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = $true; advice = 'clean advice ok' } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f4f' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $boolProbe
    Assert-DecisionProvider (($r.source -ceq 'planner-escalation') -and ($r.reason -ceq 'jev-low-confidence-escalation') -and ($r.decision -ceq '')) '[F4f] bool confidence escalates, never coerced into accept' ($r.source + '/' + $r.reason)
    $numProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = 'clean advice ok' } }
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f4g' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $numProbe
    Assert-DecisionProvider (($r.source -ceq 'jev') -and ($r.decision -ceq 'opt-a') -and ($r.reason -ceq 'jev-advice-accepted')) '[F4g] numeric 0.9 still accepted' ($r.source + '/' + $r.reason)
    $r = Invoke-OrchestrationDecision -QuestionId 'q-f4h' -QuestionType 'routing' -Alternatives @('opencode-go/muse-spark-1.3-contributor') -State @{} -Risk 'low' -AllowJev $false -JevProbe $null
    Assert-DecisionProvider (($r.source -ceq 'refused') -and ($r.reason -ceq 'model-selection-reserved') -and ($r.decision -ceq '')) '[F4h] single model-named alternative refused' ($r.source + '/' + $r.reason)

    # ---------- envelope shape on every path ----------
    $e1 = Invoke-OrchestrationDecision -QuestionId 'qe-1' -QuestionType 'routing' -Alternatives @('solo-clean') -State $null -Risk 'low' -AllowJev $true -JevProbe $null
    $e2 = Invoke-OrchestrationDecision -QuestionId 'qe-2' -QuestionType 'bogus' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    $e3 = Invoke-OrchestrationDecision -QuestionId 'qe-3' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -AllowJev $true -JevProbe $okProbe
    $e4 = Invoke-OrchestrationDecision -QuestionId 'qe-4' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'high' -AllowJev $true -JevProbe $okProbe
    Assert-DecisionProvider ((Test-EnvelopeKeys -Env $e1) -and (Test-EnvelopeKeys -Env $e2) -and (Test-EnvelopeKeys -Env $e3) -and (Test-EnvelopeKeys -Env $e4)) '[T23] envelope carries all 9 keys on rules/refused/jev/escalation' ''
    Assert-DecisionProvider (([int]$e3.alternatives_considered -eq 2) -and ([int]$e4.alternatives_considered -eq 2)) '[T23b] alternatives_considered counted' ''
    $allBlocked = @($r.blocked, $e1.blocked, $e2.blocked, $e3.blocked, $e4.blocked)
    $anyBlocked = $false
    foreach ($b in @($allBlocked)) { if ([bool]$b) { $anyBlocked = $true } }
    Assert-DecisionProvider (-not $anyBlocked) '[T24] blocked is always false' ''

    # ---------- TDR-F4-05: additive policy ----------
    Assert-DecisionProvider (Test-Path -LiteralPath $repoPolicy -PathType Leaf) '[P0] policy file exists' $repoPolicy
    $doc = ([IO.File]::ReadAllText($repoPolicy, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $ver = 0
    try { $ver = [int]$doc.version } catch { $ver = -1 }
    Assert-DecisionProvider ($ver -eq 1) '[P1] policy version stays 1' ([string]$ver)
    $dp = $null
    try {
        if ($doc -is [System.Collections.IDictionary]) { $dp = $doc['decision_provider'] }
        else {
            $pp = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'decision_provider' } | Select-Object -First 1
            if ($null -ne $pp) { $dp = $pp.Value }
        }
    }
    catch { $dp = $null }
    Assert-DecisionProvider ($null -ne $dp) '[P2] decision_provider section present' ''
    $qts = @()
    try { foreach ($t in @($dp.question_types)) { $qts += (([string]$t).Trim().ToLowerInvariant()) } } catch { $qts = @() }
    $wantQt = @('routing', 'specialist', 'continue', 'parallel', 'evidence', 'risk', 'hypothesis', 'alternative')
    $dQt = Compare-Object @($qts | Sort-Object) @($wantQt | Sort-Object)
    Assert-DecisionProvider (($null -eq $dQt) -and (@($qts).Count -eq 8)) '[P3] 8 closed question types' ((@($qts) -join ','))
    $maxA = -1
    try { $maxA = [int]$dp.max_alternatives } catch { $maxA = -1 }
    Assert-DecisionProvider ($maxA -eq 8) '[P4] max_alternatives is 8' ([string]$maxA)
    $minC = -1.0
    try { $minC = [double]$dp.min_confidence } catch { $minC = -1.0 }
    Assert-DecisionProvider ([Math]::Abs($minC - 0.5) -lt 0.0001) '[P5] min_confidence is 0.5' ([string]$minC)
    $hr = $false
    try { $hr = [bool]$dp.high_risk_no_jev } catch { $hr = $false }
    Assert-DecisionProvider ($hr -eq $true) '[P6] high_risk_no_jev is true' ''
    $esc = $false
    try { $esc = [bool]$dp.planner_escalation_on_unavailable } catch { $esc = $false }
    Assert-DecisionProvider ($esc -eq $true) '[P7] planner_escalation_on_unavailable is true' ''
    $ark = @()
    try { foreach ($k in @($dp.authority_reserved_keywords)) { $ark += (([string]$k).Trim().ToLowerInvariant()) } } catch { $ark = @() }
    Assert-DecisionProvider ((@($ark).Count -ge 15) -and ($ark -contains 'grant') -and ($ark -contains 'done') -and ($ark -contains 'security') -and ($ark -contains 'model')) '[P8] authority keywords cover grant/done/security/model' ((@($ark) -join ','))
    $mok = @()
    try { foreach ($k in @($dp.model_override_keywords)) { $mok += (([string]$k).Trim().ToLowerInvariant()) } } catch { $mok = @() }
    Assert-DecisionProvider ((($mok -contains 'gpt') -and ($mok -contains 'haiku') -and ($mok -contains 'select-model') -and ($mok -contains 'Muse'))) '[P9] model keywords cover gpt/haiku/select-model/Muse' ((@($mok) -join ','))
    $tools = @()
    try { foreach ($t in @($doc.allowed_tools)) { $tools += (([string]$t).Trim()) } } catch { $tools = @() }
    $dTools = Compare-Object @($tools | Sort-Object) @(@('jev_check', 'jev_gate', 'jev_score', 'jev_decide') | Sort-Object)
    Assert-DecisionProvider ($null -eq $dTools) '[P10] existing allowed_tools untouched' ((@($tools) -join ','))
    $rb = -1
    try { $rb = [int]$doc.request_budget_seconds } catch { $rb = -1 }
    Assert-DecisionProvider ($rb -eq 30) '[P11] existing request budget untouched' ([string]$rb)
    $cannot = @()
    try {
        $auth = $null
        if ($doc -is [System.Collections.IDictionary]) { $auth = $doc['authority'] }
        else {
            $ap = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'authority' } | Select-Object -First 1
            if ($null -ne $ap) { $auth = $ap.Value }
        }
        foreach ($e in @($auth.cannot)) { $cannot += (([string]$e).Trim()) }
    }
    catch { $cannot = @() }
    Assert-DecisionProvider (($cannot -contains 'select-model') -and ($cannot -contains 'write-done')) '[P12] existing authority cannot list untouched' ((@($cannot) -join ','))

    # ---------- hygiene: no network, ASCII-only ----------
    $libText = [IO.File]::ReadAllText($libPath, [Text.UTF8Encoding]::new($false))
    Assert-DecisionProvider ((($libText -notmatch 'Invoke-WebRequest') -and ($libText -notmatch 'Invoke-RestMethod') -and ($libText -notmatch 'HttpClient') -and ($libText -notmatch 'Net\.WebClient') -and ($libText -notmatch 'HttpWebRequest'))) '[NET] provider lib has no network primitives' ''
    Assert-DecisionProvider ((($libText -notmatch '(?m)^\s*\.\s+\S*JevAdvisory') -and ($libText -notmatch '(?m)^\s*\.\s+\S*PlannerLoop') -and ($libText -notmatch 'Import-Module'))) '[ISO] provider composes guards locally, imports no Jev/loop lib' ''
    foreach ($p in @($libPath, $repoPolicy, $PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bad = 0
        foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
        Assert-DecisionProvider ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
    }

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}
