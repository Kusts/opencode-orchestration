<#!
.SYNOPSIS
    Tests for lib/OrchestrationAutonomyWiring.ps1 (PR-5).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for the goal-budget store,
    cleanup in finally; the repo tree is never written. Bracketed output
    the runner parses. Exit 0 on all pass, exit 1 on any fail or
    unexpected exception. PS 5.1 compatible. ASCII-only. No network, no
    spawn, no secrets. Covers PR-5 acceptance: (1) wave capacity plans
    with Tester/Reviewer reserve, Explorer reduction, reuse priority
    and checkpoint+HOLD without quota; (2) per-Goal budget ledger with
    worker/task replan and Goal hard-budget terminal without DONE;
    (3) delivery wiring through OrchestrationDelivery eligibility with
    PR-opened never DONE, CI/P1 repair and blocked-merge preservation;
    (4) closed stop reasons, rest to control plane; (5) hygiene.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationAutonomy.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDelivery.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomyWiring.ps1')

$script:passed = 0
$script:failed = 0

function Assert-AutonomyWiring {
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

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-autonomywiring-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $budgetStore = Join-Path $tempRoot 'goal-budgets'
    New-Item -ItemType Directory -Path $budgetStore -Force | Out-Null

    try {
        # ---------- version / contract ----------
        $v = Get-OrchestrationAutonomyWiringVersion
        Assert-AutonomyWiring (([int]$v.schema_version -eq 1) -and ([string]$v.phase -ceq 'PR-5')) '[W0] wiring version schema 1 phase PR-5' ''

        # ---------- C1: full dispatch fits quota ----------
        $p = New-OrchestrationWaveCapacityPlan -RequestedCoders 2 -RequestedExplorers 2 -RequestedTesters 1 -RequestedReviewers 1 -AvailableSlots 8
        Assert-AutonomyWiring (([string]$p.decision -ceq 'dispatch-full') -and (-not [bool]$p.hold) -and (-not [bool]$p.checkpoint)) '[C1] quota fits dispatches full' ([string]$p.decision)
        Assert-AutonomyWiring (([int]$p.dispatched.testers -ge 1) -and ([int]$p.dispatched.reviewers -ge 1) -and ([bool]$p.validation_preserved)) '[C1] tester/reviewer reserve present' ''
        Assert-AutonomyWiring ((-not [bool]$p.planner_assumes_all) -and (-not [bool]$p.done_approved) -and (-not [bool]$p.grants_authority)) '[C1] planner never assumes all, no grant, no DONE' ''

        # ---------- C2: tight quota shrinks explorers, keeps validation ----------
        $p = New-OrchestrationWaveCapacityPlan -RequestedCoders 2 -RequestedExplorers 4 -RequestedTesters 1 -RequestedReviewers 1 -AvailableSlots 5
        Assert-AutonomyWiring (([string]$p.decision -ceq 'dispatch-reduced') -and (-not [bool]$p.hold)) '[C2] tight quota reduces instead of holding' ([string]$p.decision)
        Assert-AutonomyWiring (([bool]$p.explorers_reduced) -and ([int]$p.dispatched.explorers -lt 4)) '[C2] explorer fan-out reduced' ([string]$p.dispatched.explorers)
        Assert-AutonomyWiring (([int]$p.dispatched.testers -ge 1) -and ([int]$p.dispatched.reviewers -ge 1) -and ([bool]$p.validation_preserved)) '[C2] validation never sacrificed to fit' ''

        # ---------- C3: reuse prioritized before dispatch ----------
        $p = New-OrchestrationWaveCapacityPlan -RequestedCoders 3 -RequestedExplorers 1 -RequestedTesters 1 -RequestedReviewers 1 -AvailableSlots 6 -ReuseCandidateCount 2
        Assert-AutonomyWiring (([bool]$p.reuse_applied) -and ([int]$p.dispatched.coders -eq 1)) '[C3] reuse candidates reduce coder demand first' ([string]$p.dispatched.coders)

        # ---------- C4a: no quota for reserve => checkpoint + HOLD, planner never takes all ----------
        $p = New-OrchestrationWaveCapacityPlan -RequestedCoders 2 -RequestedExplorers 1 -RequestedTesters 1 -RequestedReviewers 1 -AvailableSlots 1
        Assert-AutonomyWiring (([string]$p.decision -ceq 'checkpoint-hold') -and ([bool]$p.hold) -and ([bool]$p.checkpoint)) '[C4a] quota below reserve checkpoints and holds' ([string]$p.decision)
        Assert-AutonomyWiring (([int]$p.dispatched.testers -ge 1) -and ([int]$p.dispatched.reviewers -ge 1) -and ([bool]$p.validation_preserved)) '[C4a] short quota preserves validation reserve plus checkpoint' ''
        Assert-AutonomyWiring ((-not [bool]$p.planner_assumes_all)) '[C4a] hold never means planner assumes everything' ''

        # ---------- C4b: coder demand alone exceeds quota => checkpoint + HOLD ----------
        $p = New-OrchestrationWaveCapacityPlan -RequestedCoders 6 -RequestedExplorers 0 -RequestedTesters 1 -RequestedReviewers 1 -AvailableSlots 3
        Assert-AutonomyWiring (([string]$p.decision -ceq 'checkpoint-hold') -and ([bool]$p.hold) -and ([bool]$p.checkpoint)) '[C4b] unshrinkable demand checkpoints' ([string]$p.decision)

        # ---------- C5: invalid input fails closed to checkpoint ----------
        $p = New-OrchestrationWaveCapacityPlan -RequestedCoders 'many' -RequestedExplorers 1 -RequestedTesters 1 -RequestedReviewers 1 -AvailableSlots 8
        Assert-AutonomyWiring (([string]$p.decision -ceq 'checkpoint-hold') -and ([bool]$p.hold)) '[C5] non-integer input fails closed to checkpoint' ([string]$p.decision)

        # ---------- B1: worker exhaustion means replan, never terminal ----------
        $led = New-OrchestrationGoalBudgetLedger -GoalId 'goal-1' -WorkerLimit 2 -TaskLimit 5 -GoalHardLimit 10
        Assert-AutonomyWiring ([bool]$led.ok) '[B1] ledger created' ([string]$led.reason)
        $o = Add-OrchestrationBudgetConsumption -Ledger $led -WorkerCost 3 -TaskCost 0 -GoalCost 1
        Assert-AutonomyWiring (([string]$o.decision -ceq 'replan') -and (-not [bool]$o.terminal) -and ([string]$o.reason -ceq 'worker-budget-exhausted-replan')) '[B1] worker exhaustion replans' ([string]$o.decision + '/' + [string]$o.reason)
        Assert-AutonomyWiring ((-not [bool]$o.done_approved)) '[B1] replan claims no DONE' ''

        # ---------- B2: task exhaustion means replan ----------
        $o = Add-OrchestrationBudgetConsumption -Ledger $led -WorkerCost 0 -TaskCost 6 -GoalCost 1
        Assert-AutonomyWiring (([string]$o.decision -ceq 'replan') -and (-not [bool]$o.terminal)) '[B2] task exhaustion replans' ([string]$o.decision)

        # ---------- B3: only Goal hard budget is terminal, honest, resumable ----------
        $o = Add-OrchestrationBudgetConsumption -Ledger $led -WorkerCost 0 -TaskCost 0 -GoalCost 11
        Assert-AutonomyWiring (([string]$o.decision -ceq 'terminal') -and ([bool]$o.terminal) -and ([string]$o.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED')) '[B3] goal hard budget terminates honestly' ([string]$o.decision)
        Assert-AutonomyWiring ((-not [bool]$o.done_approved) -and (-not [bool]$o.ledger.done_approved) -and ([bool]$o.resumable)) '[B3] terminal without false DONE, resumable when applicable' ''

        # ---------- B3s: simultaneous worker+goal exhaustion is terminal (goal hard first) ----------
        $ledS = New-OrchestrationGoalBudgetLedger -GoalId 'goal-sim' -WorkerLimit 2 -TaskLimit 5 -GoalHardLimit 10
        $oS = Add-OrchestrationBudgetConsumption -Ledger $ledS -WorkerCost 3 -TaskCost 0 -GoalCost 11
        Assert-AutonomyWiring (([string]$oS.decision -ceq 'terminal') -and ([bool]$oS.terminal) -and ([string]$oS.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED')) '[B3s] simultaneous worker+goal exhaustion terminates on goal hard first' ([string]$oS.decision + '/' + [string]$oS.reason)
        Assert-AutonomyWiring ((-not [bool]$oS.done_approved) -and ([bool]$oS.resumable)) '[B3s] simultaneous terminal claims no DONE and stays resumable' ''

        # ---------- B4: within budget continues ----------
        $o = Add-OrchestrationBudgetConsumption -Ledger $led -WorkerCost 1 -TaskCost 1 -GoalCost 1
        Assert-AutonomyWiring (([string]$o.decision -ceq 'continue') -and (-not [bool]$o.terminal)) '[B4] consumption within limits continues' ([string]$o.decision)

        # ---------- B5: ledger persists per Goal and reloads ----------
        $save = Save-OrchestrationGoalBudgetLedger -Ledger $o.ledger -StoreDir $budgetStore
        Assert-AutonomyWiring ([bool]$save.ok) '[B5] ledger persisted' ([string]$save.reason)
        $back = Read-OrchestrationGoalBudgetLedger -GoalId 'goal-1' -StoreDir $budgetStore
        Assert-AutonomyWiring (([bool]$back.ok) -and ([long]$back.ledger.goal_consumed -eq [long]$o.ledger.goal_consumed) -and ([long]$back.ledger.worker_consumed -eq [long]$o.ledger.worker_consumed)) '[B5] reload preserves accumulated consumption' ''
        $missing = Read-OrchestrationGoalBudgetLedger -GoalId 'goal-absent' -StoreDir $budgetStore
        Assert-AutonomyWiring (((-not [bool]$missing.ok) -and ($null -eq $missing.ledger))) '[B5] unknown goal fails closed' ([string]$missing.reason)

        # ---------- B7: writer conflict fails closed, partial file never parses ----------
        $ledC = New-OrchestrationGoalBudgetLedger -GoalId 'goal-cas' -WorkerLimit 5 -TaskLimit 5 -GoalHardLimit 10
        $s1 = Save-OrchestrationGoalBudgetLedger -Ledger $ledC -StoreDir $budgetStore
        Assert-AutonomyWiring ([bool]$s1.ok) '[B7] first writer persists' ([string]$s1.reason)
        $r1 = Read-OrchestrationGoalBudgetLedger -GoalId 'goal-cas' -StoreDir $budgetStore
        Assert-AutonomyWiring ([bool]$r1.ok) '[B7] first revision readable' ''
        $staleCopy = New-OrchestrationGoalBudgetLedger -GoalId 'goal-cas' -WorkerLimit 5 -TaskLimit 5 -GoalHardLimit 10
        $sStale = Save-OrchestrationGoalBudgetLedger -Ledger $staleCopy -StoreDir $budgetStore
        Assert-AutonomyWiring (((-not [bool]$sStale.ok) -and ([string]$sStale.reason -ceq 'revision-conflict'))) '[B7] stale writer conflicts fail-closed' ([string]$sStale.reason)
        $freshSave = Save-OrchestrationGoalBudgetLedger -Ledger $r1.ledger -StoreDir $budgetStore
        Assert-AutonomyWiring ([bool]$freshSave.ok) '[B7] fresh revision advances atomically' ([string]$freshSave.reason)
        $casPath = Join-Path $budgetStore 'goal-cas.budget.json'
        [IO.File]::WriteAllText($casPath, '{"goal_id":"goal-cas","worker_limit":', [Text.UTF8Encoding]::new($false))
        $rPartial = Read-OrchestrationGoalBudgetLedger -GoalId 'goal-cas' -StoreDir $budgetStore
        Assert-AutonomyWiring (((-not [bool]$rPartial.ok) -and ($null -eq $rPartial.ledger))) '[B7] partial file recovers fail-closed' ([string]$rPartial.reason)

        # ---------- B6: invalid ledger input fails closed ----------
        $bad = New-OrchestrationGoalBudgetLedger -GoalId '../escape' -WorkerLimit 2 -TaskLimit 5 -GoalHardLimit 10
        Assert-AutonomyWiring ((-not [bool]$bad.ok)) '[B6] travelling goal id rejected' ([string]$bad.reason)
        $bad2 = New-OrchestrationGoalBudgetLedger -GoalId 'goal-2' -WorkerLimit 'lots' -TaskLimit 5 -GoalHardLimit 10
        Assert-AutonomyWiring ((-not [bool]$bad2.ok)) '[B6] non-integer limit rejected' ''

        # ---------- A1: outside authorization blocks, invents nothing ----------
        $locked = Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('research') -Denied @() -Boundaries @()
        $g = Test-OrchestrationAutonomyActionAllowed -Action 'pr_open' -Authorization $locked
        Assert-AutonomyWiring (((-not [bool]$g.allowed) -and ([bool]$g.blocked) -and ([string]$g.reason -ceq 'outside-authorization-blocked'))) '[A1] action outside envelope blocks' ([string]$g.reason)
        $g = Test-OrchestrationAutonomyActionAllowed -Action 'research' -Authorization $locked
        Assert-AutonomyWiring (([bool]$g.allowed) -and (-not [bool]$g.blocked)) '[A1] envelope action stays allowed' ''
        $g = Test-OrchestrationAutonomyActionAllowed -Action 'mystery_action' -Authorization $locked
        Assert-AutonomyWiring (((-not [bool]$g.allowed) -and ([bool]$g.blocked))) '[A1] unknown action never admitted' ''

        # ---------- D1: early delivery states route forward ----------
        $wide = Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('edit_refactor', 'test_build', 'pr_open', 'findings_repair', 'ci_rerun') -Denied @() -Boundaries @()
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created') -Authorization $wide
        Assert-AutonomyWiring (([string]$d.state -ceq 'IMPLEMENTATION') -and ([string]$d.action_step -ceq 'implement')) '[D1] implementation routes to implement' ([string]$d.state + '/' + [string]$d.action_step)
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'implemented') -Authorization $wide
        Assert-AutonomyWiring (([string]$d.state -ceq 'TESTING') -and ([string]$d.action_step -ceq 'run-tests')) '[D1] testing routes to run-tests' ([string]$d.action_step)
        Assert-AutonomyWiring ((-not [bool]$d.done_approved) -and (-not [bool]$d.grants_authority) -and (-not [bool]$d.branch_protection_bypass)) '[D1] routing grants nothing and bypasses nothing' ''

        # ---------- D2: PR_READY needs pr_open; PR created is not DONE ----------
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved') -Authorization $wide
        Assert-AutonomyWiring (([string]$d.state -ceq 'PR_READY') -and ([string]$d.action_step -ceq 'open-pr')) '[D2] PR_READY routes to open-pr' ([string]$d.action_step)
        Assert-AutonomyWiring (([bool]$d.pr_is_not_done) -and (-not [bool]$d.done_approved)) '[D2] PR created is never DONE' ''
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved') -Authorization $locked
        Assert-AutonomyWiring (([bool]$d.blocked) -and ([string]$d.reason -ceq 'outside-authorization-blocked') -and ([bool]$d.state_preserved)) '[D2] pr_open outside authorization blocks with state preserved' ([string]$d.reason)

        # ---------- D3: CI failure means repair plus revalidation, never conclusion ----------
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened') -CiStatus 'ci_failed' -Authorization $wide
        Assert-AutonomyWiring (([string]$d.action_step -ceq 'repair') -and ([bool]$d.repair_required) -and ([bool]$d.revalidate)) '[D3] CI failure routes to repair plus revalidate' ([string]$d.action_step)
        Assert-AutonomyWiring ((-not [bool]$d.done_approved) -and (-not [bool]$d.eligible)) '[D3] CI failure never concludes' ([string]$d.reason)

        # ---------- D2b/F2: no envelope never opens a PR (fail-closed) ----------
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved') -Authorization $null
        Assert-AutonomyWiring (([bool]$d.blocked) -and ([string]$d.reason -ceq 'outside-authorization-blocked') -and ([bool]$d.state_preserved) -and ([string]$d.action_step -cne 'open-pr')) '[D2b] missing envelope blocks instead of open-pr' ([string]$d.reason + '/' + [string]$d.action_step)

        # ---------- D3b/F2: PR_OPEN checks the effective action (repair needs findings_repair) ----------
        $rerunOnly = Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('ci_rerun') -Denied @() -Boundaries @()
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened') -CiStatus 'ci_failed' -Authorization $rerunOnly
        Assert-AutonomyWiring (([bool]$d.blocked) -and ([string]$d.reason -ceq 'outside-authorization-blocked') -and ([bool]$d.state_preserved)) '[D3b] CI failure without repair auth blocks' ([string]$d.reason)
        $repairOnly = Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('findings_repair') -Denied @() -Boundaries @()
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened') -CiStatus 'ci_failed' -Authorization $repairOnly
        Assert-AutonomyWiring (([string]$d.action_step -ceq 'repair') -and ([bool]$d.repair_required) -and (-not [bool]$d.blocked)) '[D3b] CI failure with repair auth repairs' ([string]$d.action_step)
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened') -Authorization $rerunOnly
        Assert-AutonomyWiring ((-not [bool]$d.blocked) -and ([string]$d.action_step -ceq 'await-ci')) '[D3b] clean PR_OPEN with rerun auth awaits CI' ([string]$d.action_step)

        # ---------- D4: merge gate consumes eligibility; P1 means repair ----------
        $v3 = Split-Path -Parent $PSScriptRoot
        $repo = Split-Path -Parent (Split-Path -Parent $v3)
        $reqPath = Join-Path $repo 'source\registry\delivery-policy.json'
        $reqText = [IO.File]::ReadAllText($reqPath, [Text.Encoding]::UTF8)
        $reqDoc = ($reqText | ConvertFrom-Json)
        $reqChecks = @()
        foreach ($n in @($reqDoc.required_checks)) {
            $reqChecks += [pscustomobject]@{ name = ([string]$n); conclusion = 'success' }
        }
        $gateEvents = @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened', 'ci_passed')
        $d = Invoke-OrchestrationDeliveryStep -Events $gateEvents -Checks $reqChecks -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low' -Authorization $wide
        Assert-AutonomyWiring (([string]$d.state -ceq 'MERGE_GATE') -and ([string]$d.action_step -ceq 'await-merge-gate') -and ([bool]$d.eligible)) '[D4] eligible gate waits at merge gate (merge stays external)' ([string]$d.action_step)
        Assert-AutonomyWiring ((-not [bool]$d.branch_protection_bypass) -and (-not [bool]$d.done_approved)) '[D4] eligible gate bypasses nothing and claims no DONE' ''
        $d = Invoke-OrchestrationDeliveryStep -Events $gateEvents -Checks $reqChecks -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 1 -Risk 'low' -Authorization $wide
        Assert-AutonomyWiring (([string]$d.action_step -ceq 'repair') -and ([bool]$d.repair_required) -and ([bool]$d.revalidate) -and (-not [bool]$d.eligible)) '[D4] unresolved P1 returns to repair plus revalidate' ([string]$d.reason)

        # ---------- D5: blocked merge preserves state and surfaces blocker ----------
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'blocked') -Authorization $wide
        Assert-AutonomyWiring (([string]$d.state -ceq 'DELIVERY_BLOCKED') -and ([bool]$d.blocked) -and ([bool]$d.state_preserved) -and (-not [string]::IsNullOrWhiteSpace([string]$d.blocker))) '[D5] blocked merge preserves state plus blocker' ([string]$d.state)
        Assert-AutonomyWiring ((-not [bool]$d.done_approved)) '[D5] blocked merge claims no DONE' ''

        # ---------- D6: invalid delivery event fails closed ----------
        $d = Invoke-OrchestrationDeliveryStep -Events @('branch_created', 'launched_rocket') -Authorization $wide
        Assert-AutonomyWiring (([bool]$d.blocked) -and ([bool]$d.state_preserved)) '[D6] unknown event preserves instead of advancing' ([string]$d.reason)

        # ---------- S1: closed stop reasons terminate; rest returns to control plane ----------
        foreach ($stop in @('OBJECTIVE_COMPLETED', 'HUMAN_AUTHORITY_REQUIRED', 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE', 'GOAL_HARD_BUDGET_EXHAUSTED', 'POLICY_BLOCKED', 'CANCELLED')) {
            $s = Resolve-OrchestrationStopDecision -Reason $stop -Detail 'test-detail'
            Assert-AutonomyWiring (([bool]$s.terminal) -and ([string]$s.stop_reason -ceq $stop) -and (-not [bool]$s.done_approved)) ('[S1] closed stop terminates: ' + $stop) ''
        }
        $s = Resolve-OrchestrationStopDecision -Reason 'TASK_DONE' -Detail 'test-detail'
        Assert-AutonomyWiring (((-not [bool]$s.terminal) -and ([string]$s.return_to -ceq 'control-plane'))) '[S1] open reason returns to control plane' ([string]$s.reason)
        $s = Resolve-OrchestrationStopDecision -Reason '' -Detail 'test-detail'
        Assert-AutonomyWiring (((-not [bool]$s.terminal) -and ([string]$s.return_to -ceq 'control-plane'))) '[S1] empty reason returns to control plane' ''

        # ---------- hygiene: no network/spawn/secrets, ASCII-only ----------
        $wiringPath = Join-Path $PSScriptRoot 'OrchestrationAutonomyWiring.ps1'
        $wiringText = [IO.File]::ReadAllText($wiringPath, [Text.Encoding]::UTF8)
        Assert-AutonomyWiring ((($wiringText -notmatch 'Invoke-WebRequest') -and ($wiringText -notmatch 'Invoke-RestMethod') -and ($wiringText -notmatch 'HttpClient') -and ($wiringText -notmatch 'Net\.WebClient') -and ($wiringText -notmatch 'HttpWebRequest') -and ($wiringText -notmatch 'Start-Process'))) '[NET] autonomy wiring owns no network/spawn' ''
        Assert-AutonomyWiring (($wiringText -notmatch '(?i)sk-[A-Za-z0-9]')) '[SEC] autonomy wiring carries no secret value' ''
        foreach ($p in @($wiringPath, (Join-Path $PSScriptRoot 'OrchestrationAutonomyWiring.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-AutonomyWiring ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
    }
    finally {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
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
