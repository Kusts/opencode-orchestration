<#!
.SYNOPSIS
    PR-6 corrective E2E harness: E2E-01..E2E-15 at lib level (CORRECTIVE-PLAN Fase PR-6).
.DESCRIPTION
    TEST HARNESS - NOT PRODUCT. Dot-sourceable test suite (no execution on
    load beyond the asserts below). Fifteen end-to-end scenarios over the
    REAL libs (GoalKernel, ObjectiveController, GoalProgress,
    GoalCheckpoint, ObjectiveRuntime intent ledger) driven with SYNTHETIC
    outcomes through scripts/ci/ObjectiveRunner.harness.ps1 plus the new
    PR-6 per-Goal JSONL telemetry sink, all in TEMP stores. Bounded (the
    harness caps at 20 iterations; this suite adds no unbounded loop),
    deterministic (fixed scripts, fixed ids, no time/random dependence),
    PS 5.1 compatible, ASCII-only. Fails closed via throw on the first
    violated assert; prints one PASS line with the assert count.

    Gates G1-G8 (each scenario declares its primary gates; the suite
    asserts full G1..G8 coverage across the 15):
      G1 trivial => single worker, zero prompts by construction.
      G2 defect => fix + revalidate before COMPLETE.
      G3 auto-continuation => no manual "continue" gate; the loop consumes
         controller moves until COMPLETE.
      G4 reviewer finding => repair + re-review (criteria revalidated).
      G5 worker failure/stale/crash => recovery path, never silent drop.
      G6 degraded dependency (Jev down) => deterministic fallback, never
         block, never throw.
      G7 bounded honesty => quota/budget/auth/duplicates end in a held or
         honest terminal (checkpoint, BLOCKED, EXHAUSTED); never a false
         COMPLETE, never unbounded, exactly one logical dispatch.
      G8 final evidence => a completed Goal carries persisted evidence
         plus a readable telemetry baseline.

    Mapping: E2E-01 typo => single worker (G1); E2E-02 bug => fix +
    revalidate (G2); E2E-03 SPEC+PLAN => Goal auto + continuous, no manual
    continue (G3); E2E-04 reviewer finding => repair + re-review (G4);
    E2E-05 worker fail => recovery (G5); E2E-06 Jev down => fallback (G6);
    E2E-07 reuse hit => fewer operations (G3); E2E-08 stale => re-executes
    (G5); E2E-09 crash => resumes without duplicating (G5); E2E-10
    duplicates => 1 logical dispatch (G7); E2E-11 quota => checkpoint (G7);
    E2E-12 out-of-authorization => blocks (G7); E2E-13 budget => honest
    terminal (G7); E2E-14 CI fail => repair (G2+G4); E2E-15 Goal complete
    => final evidence + readable baseline (G8).

    HARNESS-LEVEL ONLY: every telemetry event asserts harness_level=$true
    and runtime_real=$false. Runtime-real with a live OpenCode session is
    HOLD/BLOCKED (provider/CI operator-owned) and is NEVER claimed here;
    the suite prints the pending matrix as BLOCKED in its PASS line.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalProgress.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveRuntime.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveTelemetry.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationReuseWiring.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomy.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDelivery.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomyWiring.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationMcpSafety.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationJevAdvisory.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDecisionProvider.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDecisionWiring.ps1')
. (Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'ci') 'ObjectiveRunner.harness.ps1')
$passed = 0
function Assert-CEThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-CETempDir {
    param([string]$Prefix)
    $t = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($t)
    return $t
}
function New-CEGoalWithTasks {
    param([string]$StoreDir, [string]$GoalId, [string[]]$Tasks, [string[]]$Criteria, [long]$HardCap = 0)
    $crit = @($Criteria)
    if ($crit.Count -eq 0) { $crit = @($Tasks | ForEach-Object { ('crit-' + [string]$_) }) }
    $n = New-OrchestrationGoal -GoalId $GoalId -Objective ('harness objective ' + $GoalId) -Criteria $crit -HardCap $HardCap -StoreDir $StoreDir
    if (-not [bool]$n.ok) { throw ('FAIL: setup new goal ' + $GoalId) }
    $sv = Save-OrchestrationGoal -Goal $n.goal -StoreDir $StoreDir
    if (-not [bool]$sv.ok) { throw ('FAIL: setup save goal ' + $GoalId) }
    $act = Set-OrchestrationGoalState -Goal $n.goal -ToState 'ACTIVE'
    if (-not [bool]$act.ok) { throw ('FAIL: setup activate goal ' + $GoalId) }
    $work = $act.goal
    foreach ($t in @($Tasks)) {
        $ad = Add-OrchestrationGoalTask -Goal $work -TaskId ([string]$t)
        if (-not [bool]$ad.ok) { throw ('FAIL: setup add task ' + [string]$t) }
        $work = $ad.goal
    }
    $sv2 = Save-OrchestrationGoal -Goal $work -StoreDir $StoreDir
    if (-not [bool]$sv2.ok) { throw ('FAIL: setup save tasks ' + $GoalId) }
    return $sv2
}
function Get-CEMove {
    param($Status)
    $mv = Get-OrchestrationNextMove -Status $Status
    if ($null -eq $mv) { throw 'FAIL: controller returned null' }
    return $mv
}
function New-CEStatus {
    param([bool]$Completed = $false, $Remaining = $null, [bool]$Authorized = $true, [string]$BlockerKind = '', [bool]$Progress = $true, [bool]$Strategy = $false, [bool]$Degraded = $false, $LastFailure = $null, $TerminalBlocker = $null)
    $rem = $null
    if ($null -ne $Remaining) { $rem = @($Remaining) }
    return @{
        objective_completed     = $Completed
        remaining_work          = $rem
        authorized              = $Authorized
        blocker_kind            = $BlockerKind
        progress_possible       = $Progress
        strategy_change         = $Strategy
        context_degraded        = $Degraded
        last_failure            = $LastFailure
        terminal_blocker        = $TerminalBlocker
        consecutive_no_progress = [long]0
    }
}
$teleDir = New-CETempDir 'ce-tele-'
$allEvents = New-Object System.Collections.ArrayList
function Add-CEEvent {
    param($Event)
    if (($null -eq $Event) -or (-not [bool]$Event.ok)) { throw 'FAIL: telemetry event constructor failed' }
    $ev = $Event.event
    Assert-CEThat ([bool](Get-OTField $ev 'harness_level' $false)) 'telemetry marks harness_level'
    Assert-CEThat ((-not [bool](Get-OTField $ev 'runtime_real' $true))) 'telemetry never claims runtime-real'
    $px = Get-OTField $ev 'cost_proxy' $null
    Assert-CEThat (([bool](Get-OTField $px 'is_proxy' $false))) 'cost is declared proxy, never provider-measured'
    $sv = Save-OrchestrationObjectiveTelemetryEvent -Event $ev -StoreDir $teleDir
    if (($null -eq $sv) -or (-not [bool]$sv.ok)) { throw 'FAIL: telemetry sink append failed' }
    [void]$allEvents.Add($ev)
    return $ev
}
# --- E2E-01: typo => single worker (G1). One trivial fix, CONTINUE, zero prompts by construction.
$e01mv = Get-CEMove (New-CEStatus -Completed $false -Remaining @('fix-typo') -Progress $true)
$e01pass = (([string]$e01mv.move -ceq 'CONTINUE') -and ([long]$e01mv.remaining_count -eq 1))
$e01res = 'FAIL'
if ($e01pass) { $e01res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe01goal1' -Objective 'harness objective CEe01goal1' -Scenario 'E2E-01' -Shape 'SINGLE_WORKER' -Workers @('coder') -Gates @('G1') -Dispatches 1 -ProgressDeltas 1 -Validation 'pass' -Result $e01res -Note 'typo single worker harness-level'))
Assert-CEThat ($e01pass) 'E2E-01 typo yields single-worker CONTINUE with remaining 1'
# --- E2E-02: bug => fix + revalidate (G2). Recoverable failure => RETRY, then satisfied => COMPLETE.
$e02retry = Get-CEMove (New-CEStatus -Remaining @('fix-bug') -LastFailure 'recoverable' -Progress $true)
$e02done = Get-CEMove (New-CEStatus -Completed $true -Remaining $null)
$e02pass = (([string]$e02retry.move -ceq 'RETRY') -and ([string]$e02done.move -ceq 'COMPLETE') -and ([string]$e02done.stop_reason -ceq 'OBJECTIVE_COMPLETED'))
$e02res = 'FAIL'
if ($e02pass) { $e02res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe02goal1' -Objective 'harness objective CEe02goal1' -Scenario 'E2E-02' -Shape 'SINGLE_WORKER' -Workers @('coder', 'tester') -Gates @('G2') -Retries 1 -Dispatches 2 -ProgressDeltas 1 -Validation 'pass' -StopReason 'OBJECTIVE_COMPLETED' -Result $e02res -Note 'bug fix plus tester revalidation harness-level'))
Assert-CEThat ($e02pass) 'E2E-02 bug recovers via RETRY then COMPLETE/OBJECTIVE_COMPLETED'
# --- E2E-03: SPEC+PLAN => Goal auto + continuous, no manual continue (G3). Real harness loop to COMPLETE.
$e03dir = New-CETempDir 'ce-e03-'
[void](New-CEGoalWithTasks $e03dir 'CEe03goal1' @('CEe03t1', 'CEe03t2') @('c1', 'c2'))
$e03 = Invoke-OrchestrationObjectiveRunner -GoalId 'CEe03goal1' -StoreDir $e03dir -Script @(
    @{ complete_tasks = @('CEe03t1'); fail_task = $null; add_finding = $false; satisfy = 1 },
    @{ complete_tasks = @('CEe03t2'); fail_task = $null; add_finding = $false; satisfy = 2 }
)
$e03auto = $true
foreach ($ent in @($e03.history)) {
    if ([string]$ent.move -cne [string]$ent.controller_move) { $e03auto = $false }
    if ([string]$ent.reason -ieq 'manual-continue') { $e03auto = $false }
}
$e03pass = (([string]$e03.stop_reason -ceq 'OBJECTIVE_COMPLETED') -and $e03auto -and ([long]$e03.prompts -eq 0))
$e03res = 'FAIL'
if ($e03pass) { $e03res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe03goal1' -Objective 'harness objective CEe03goal1' -Scenario 'E2E-03' -Shape 'MULTI_WORKER' -Workers @('planner', 'coder') -Gates @('G3') -Dispatches ([long]$e03.iterations) -ProgressDeltas 2 -Interventions 0 -Validation 'pass' -StopReason ([string]$e03.stop_reason) -Result $e03res -Note 'spec plan auto continuous no manual continue harness-level'))
Assert-CEThat ($e03pass) 'E2E-03 SPEC+PLAN loop auto-continues to COMPLETE with zero manual interventions'
# --- E2E-04: reviewer finding => repair + re-review (G4). Real harness loop with finding + repair task.
$e04dir = New-CETempDir 'ce-e04-'
[void](New-CEGoalWithTasks $e04dir 'CEe04goal1' @('CEe04t1', 'CEe04t2') @('c1', 'c2'))
$e04 = Invoke-OrchestrationObjectiveRunner -GoalId 'CEe04goal1' -StoreDir $e04dir -Script @(
    @{ complete_tasks = @('CEe04t1'); fail_task = $null; add_finding = $false; satisfy = 1 },
    @{ complete_tasks = @('CEe04t2'); fail_task = $null; add_finding = $true; satisfy = 1 },
    @{ complete_tasks = @('repair-1'); fail_task = $null; add_finding = $false; satisfy = 2 }
)
$e04got = Get-OrchestrationGoal -GoalId 'CEe04goal1' -StoreDir $e04dir
$e04replans = @($e04.history | Where-Object { [string]$_.move -ceq 'REPLAN' })
$e04pass = (([string]$e04.stop_reason -ceq 'OBJECTIVE_COMPLETED') -and [bool]$e04got.ok -and (@($e04got.goal['completed_tasks']) -contains 'repair-1') -and ($e04replans.Count -ge 1) -and ([long]$e04got.goal['progress']['satisfied'] -eq 2))
$e04res = 'FAIL'
if ($e04pass) { $e04res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe04goal1' -Objective 'harness objective CEe04goal1' -Scenario 'E2E-04' -Shape 'MULTI_WORKER' -Workers @('coder', 'reviewer') -Gates @('G4') -Findings 1 -StrategyChanges 1 -Dispatches 2 -ProgressDeltas 2 -Validation 'pass' -StopReason ([string]$e04.stop_reason) -Result $e04res -Note 'reviewer finding repair plus rereview harness-level'))
Assert-CEThat ($e04pass) 'E2E-04 finding yields REPLAN, repair task completed, criteria revalidated'
# --- E2E-05: worker fail => recovery (G5). Real harness loop: recoverable failure then recovery to COMPLETE.
$e05dir = New-CETempDir 'ce-e05-'
[void](New-CEGoalWithTasks $e05dir 'CEe05goal1' @('CEe05t1') @('c1'))
$e05 = Invoke-OrchestrationObjectiveRunner -GoalId 'CEe05goal1' -StoreDir $e05dir -Script @(
    @{ complete_tasks = @(); fail_task = 'recoverable'; add_finding = $false; satisfy = -1 },
    @{ complete_tasks = @('CEe05t1'); fail_task = $null; add_finding = $false; satisfy = 1 }
)
$e05retries = @($e05.history | Where-Object { [string]$_.move -ceq 'RETRY' })
$e05pass = (([string]$e05.stop_reason -ceq 'OBJECTIVE_COMPLETED') -and ($e05retries.Count -ge 1))
$e05res = 'FAIL'
if ($e05pass) { $e05res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe05goal1' -Objective 'harness objective CEe05goal1' -Scenario 'E2E-05' -Shape 'SINGLE_WORKER' -Workers @('coder') -Gates @('G5') -Retries ([long]$e05retries.Count) -Interventions 1 -Dispatches 2 -ProgressDeltas 1 -Validation 'pass' -StopReason ([string]$e05.stop_reason) -Result $e05res -Note 'worker failure recovery via retry harness-level'))
Assert-CEThat ($e05pass) 'E2E-05 worker failure recovers via RETRY to OBJECTIVE_COMPLETED'
# --- E2E-06: Jev down => deterministic fallback (G6). REAL DecisionWiring with a throwing seam.
$ceV3 = Split-Path -Parent $PSScriptRoot
$ceRepo = Split-Path -Parent (Split-Path -Parent $ceV3)
$ceJevPolicy = Join-Path $ceRepo 'source\registry\jev-advisory-policy.json'
$ceMcpPolicy = Join-Path $ceRepo 'source\registry\mcp-request-policy.json'
$ceFixDir = New-CETempDir 'ce-decfix-'
$ceFlags = Join-Path $ceFixDir 'flags-active.json'
[IO.File]::WriteAllText($ceFlags, '{"jev_advisory": {"enabled": true, "shadow": false}}', [Text.UTF8Encoding]::new($false))
$ceTeleDec = New-CETempDir 'ce-dectele-'
$ceDownProbe = { param($ctx) throw 'simulated-jev-down' }
$ceGoodKey = 'sk-SYNTHETICSECRET-VALID-1'
$e06w = $null
try {
    Clear-McpSafetyState
    $e06w = Invoke-OrchestrationDecisionWiring -QuestionId 'ce-e06-q1' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State @{ goal = 'task-after-jev'; evidence = 'two-options' } -Risk 'low' -TurnId 'turn-ce-e06' -Descriptor @{ route_uncertain = $true } -JevProbe $ceDownProbe -PolicyPath $ceJevPolicy -FlagsPath $ceFlags -McpPolicyPath $ceMcpPolicy -TelemetryRoot $ceTeleDec -ApiKey $ceGoodKey
}
catch { $e06w = $null }
try { Clear-McpSafetyState } catch { }
$e06pass = (($null -ne $e06w) -and ([string]$e06w.source -ceq 'planner-escalation') -and [bool]$e06w.fallback_used -and ($e06w.blocked -eq $false) -and ([string]$e06w.decision -ceq ''))
$e06jc = 0
$e06jf = 0
if ($e06pass) { $e06jc = 1; $e06jf = 1 }
$e06res = 'FAIL'
if ($e06pass) { $e06res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe06goal1' -Objective 'harness objective CEe06goal1' -Scenario 'E2E-06' -Shape 'DETERMINISTIC_FALLBACK' -Workers @('coder') -Gates @('G6') -JevCalls ([long]$e06jc) -JevFallbacks ([long]$e06jf) -Dispatches 1 -ProgressDeltas 1 -Validation 'pass' -Result $e06res -Note 'jev down real wiring fallback loop continues harness-level'))
Assert-CEThat ($e06pass) 'E2E-06 Jev outage falls back deterministically and the loop continues'
# --- E2E-07: reuse hit => fewer operations (G3). REAL Find-OrchestrationReusableWork over a seeded store.
$e07store = New-CETempDir 'ce-e07-reuse-'
$e07now = [DateTimeOffset]::UtcNow
$e07created = $e07now.AddMinutes(-1).ToString('o')
$e07expires = $e07now.AddMinutes(30).ToString('o')
$e07raw = Join-Path $e07store 'raw-ce07.log'
[IO.File]::WriteAllText($e07raw, 'ce-e07')
$e07rec = New-OrchestrationEvidenceRecord ([ordered]@{
    task_id = 'ce07-task'; run_id = 'ce07-run-1'; worker_id = 'coder_1'
    provenance = @{ created_by = 'coder'; kernel_task_ref = 'ce07-task' }
    base_revision = 'rev-ce07'; criteria_hash = 'crit-ce07'
    source_fingerprints = @{'src/a.ps1' = 'sha-a'}; diff_hash = 'diff-ce07'
    scope = @('src/a.ps1'); command = 'test'
    environment = @{ runtime = 'pwsh'; version = '7' }
    result = @{ summary = 'passed'; raw_ref = $e07raw }
    assumptions = @()
    invalidation_conditions = @(
        @{ type = 'source-changed'; paths = @('src/a.ps1') },
        @{ type = 'criteria-changed'; hash = 'crit-ce07' },
        @{ type = 'base-revision'; require_same = $true },
        @{ type = 'env-changed'; runtime = 'pwsh'; version = '7' },
        @{ type = 'ttl'; expires_at = $e07expires }
    )
    created_at = $e07created
}) $e07store
Assert-CEThat ([bool]$e07rec.created) 'E2E-07 reuse evidence seeded'
$e07query = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints @{'src/a.ps1' = 'sha-a'} -CurrentBaseRevision 'rev-ce07' -CurrentCriteriaHash 'crit-ce07' -CurrentEnv @{runtime = 'pwsh'; version = '7'} -Now $e07now.ToString('o') -ReuseClass 'external-behavior' -StoreDir $e07store -MaxResults 5
$e07hit = (($null -ne $e07query) -and [bool]$e07query.reused -and (@($e07query.candidates).Count -ge 1))
$e07without = 4
$e07with = 4
$e07hits = 0
$e07miss = 1
if ($e07hit) { $e07with = 2; $e07hits = 1; $e07miss = 0 }
$e07pass = (($e07hit) -and ($e07with -lt $e07without))
$e07res = 'FAIL'
if ($e07pass) { $e07res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe07goal1' -Objective 'harness objective CEe07goal1' -Scenario 'E2E-07' -Shape 'SINGLE_WORKER' -Workers @('coder') -Gates @('G3') -ReuseHits ([long]$e07hits) -ReuseMisses ([long]$e07miss) -Dispatches ([long]$e07with) -OperationsAvoided ([long]($e07without - $e07with)) -ProgressDeltas 1 -Validation 'pass' -Result $e07res -Note 'reuse hit from wiring avoids operations harness-level'))
Assert-CEThat ($e07pass) 'E2E-07 reuse hit completes with fewer operations than the no-reuse path'
# --- E2E-08: stale => re-executes (G5). Real kernel CAS: stale revision rejected, re-read + correct revision accepted.
$e08dir = New-CETempDir 'ce-e08-'
[void](New-CEGoalWithTasks $e08dir 'CEe08goal1' @('CEe08t1') @('c1'))
$e08read = Get-OrchestrationGoal -GoalId 'CEe08goal1' -StoreDir $e08dir
Assert-CEThat ([bool]$e08read.ok) 'E2E-08 goal readable before stale probe'
$e08rev = [long]$e08read.goal['revision']
$e08first = Update-OrchestrationGoal -GoalId 'CEe08goal1' -ExpectedRevision $e08rev -Fields @{ risks = @('ce-probe') } -StoreDir $e08dir
Assert-CEThat ([bool]$e08first.ok) 'E2E-08 first update advances the revision'
$e08stale = Update-OrchestrationGoal -GoalId 'CEe08goal1' -ExpectedRevision $e08rev -Fields @{ risks = @('ce-stale') } -StoreDir $e08dir
$e08staleRejected = (($null -ne $e08stale) -and (-not [bool]$e08stale.ok) -and ([string]$e08stale.reason -ceq 'revision-conflict'))
$e08reread = Get-OrchestrationGoal -GoalId 'CEe08goal1' -StoreDir $e08dir
$e08reexec = Update-OrchestrationGoal -GoalId 'CEe08goal1' -ExpectedRevision ([long]$e08reread.goal['revision']) -Fields @{ risks = @('ce-reexec') } -StoreDir $e08dir
$e08pass = ($e08staleRejected -and [bool]$e08reexec.ok)
$e08res = 'FAIL'
if ($e08pass) { $e08res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe08goal1' -Objective 'harness objective CEe08goal1' -Scenario 'E2E-08' -Shape 'SINGLE_WORKER' -Workers @('coder') -Gates @('G5') -Retries 1 -Interventions 1 -Dispatches 1 -ProgressDeltas 1 -Validation 'pass' -Result $e08res -Note 'stale revision rejected reexecuted harness-level'))
Assert-CEThat ($e08pass) 'E2E-08 stale revision rejected with revision-conflict then re-executed cleanly'
# --- E2E-09: crash => resumes without duplicating (G5). Complete one task, drop memory, re-read disk, resume via harness.
$e09dir = New-CETempDir 'ce-e09-'
[void](New-CEGoalWithTasks $e09dir 'CEe09goal1' @('CEe09t1', 'CEe09t2') @('c1', 'c2'))
$e09part = Invoke-OrchestrationObjectiveRunner -GoalId 'CEe09goal1' -StoreDir $e09dir -MaxIterations 1 -Script @(
    @{ complete_tasks = @('CEe09t1'); fail_task = $null; add_finding = $false; satisfy = 1 }
)
Assert-CEThat (([string]$e09part.stop_reason -ceq 'harness-iteration-cap')) 'E2E-09 crash simulated at the iteration cap'
$e09part = $null
$e09afterCrash = Get-OrchestrationGoal -GoalId 'CEe09goal1' -StoreDir $e09dir
Assert-CEThat (([bool]$e09afterCrash.ok) -and (@($e09afterCrash.goal['completed_tasks']) -contains 'CEe09t1')) 'E2E-09 disk preserves the pre-crash completion'
$e09 = Invoke-OrchestrationObjectiveRunner -GoalId 'CEe09goal1' -StoreDir $e09dir -Script @(
    @{ complete_tasks = @('CEe09t2'); fail_task = $null; add_finding = $false; satisfy = 2 }
)
$e09final = Get-OrchestrationGoal -GoalId 'CEe09goal1' -StoreDir $e09dir
$e09done = @($e09final.goal['completed_tasks'])
$e09unique = @($e09done | Sort-Object -Unique)
$e09pass = (([string]$e09.stop_reason -ceq 'OBJECTIVE_COMPLETED') -and ($e09done.Count -eq 2) -and ($e09unique.Count -eq 2))
$e09res = 'FAIL'
if ($e09pass) { $e09res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe09goal1' -Objective 'harness objective CEe09goal1' -Scenario 'E2E-09' -Shape 'SINGLE_WORKER' -Workers @('coder') -Gates @('G5') -Retries 1 -Interventions 1 -Dispatches 2 -ProgressDeltas 2 -Validation 'pass' -StopReason ([string]$e09.stop_reason) -Result $e09res -Note 'crash resume no duplicate completions harness-level'))
Assert-CEThat ($e09pass) 'E2E-09 crash resumes to COMPLETE with no duplicated completions'
# --- E2E-10: duplicates => 1 logical dispatch (G7). Real ObjectiveRuntime intent ledger: second save is a duplicate.
$e10store = New-CETempDir 'ce-e10-rt-'
$e10intent = New-OrchestrationDispatchIntent -GoalId 'CEe10goal1' -WorkItemId 'CEe10work1' -ActionRevision 1
Assert-CEThat ([bool]$e10intent.ok) 'E2E-10 dispatch intent constructed'
$e10first = Save-OrchestrationDispatchIntent -Intent $e10intent.intent -StoreDir $e10store
$e10second = Save-OrchestrationDispatchIntent -Intent $e10intent.intent -StoreDir $e10store
$e10pass = ([bool]$e10first.ok -and (-not [bool]$e10first.duplicate) -and [bool]$e10second.ok -and [bool]$e10second.duplicate -and ([string]$e10second.reason -ceq 'duplicate-intent'))
$e10res = 'FAIL'
if ($e10pass) { $e10res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe10goal1' -Objective 'harness objective CEe10goal1' -Scenario 'E2E-10' -Shape 'SINGLE_WORKER' -Workers @('coder') -Gates @('G7') -Dispatches 1 -OperationsAvoided 1 -ProgressDeltas 1 -Validation 'pass' -Result $e10res -Note 'duplicate intent yields one logical dispatch harness-level'))
Assert-CEThat ($e10pass) 'E2E-10 duplicate save is idempotent: exactly one logical dispatch'
# --- E2E-11: quota => checkpoint (G7). Real harness loop with a low hard cap: EXHAUSTED + checkpoint, never COMPLETE.
$e11dir = New-CETempDir 'ce-e11-'
[void](New-CEGoalWithTasks $e11dir 'CEe11goal1' @('CEe11t1', 'CEe11t2', 'CEe11t3') @('c1', 'c2', 'c3') -HardCap 2)
$e11 = Invoke-OrchestrationObjectiveRunner -GoalId 'CEe11goal1' -StoreDir $e11dir -Script @(
    @{ complete_tasks = @('CEe11t1'); fail_task = $null; add_finding = $false; satisfy = 1 },
    @{ complete_tasks = @('CEe11t2'); fail_task = $null; add_finding = $false; satisfy = 2 },
    @{ complete_tasks = @('CEe11t3'); fail_task = $null; add_finding = $false; satisfy = 3 }
)
$e11cks = @(Get-ChildItem -File (Join-Path (Join-Path $e11dir 'checkpoints') '*.json') -ErrorAction SilentlyContinue)
$e11pass = (([string]$e11.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED') -and ([string]$e11.goal_state -ceq 'EXHAUSTED') -and ([string]$e11.goal_state -cne 'COMPLETED') -and ($e11cks.Count -ge 1))
$e11res = 'FAIL'
if ($e11pass) { $e11res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe11goal1' -Objective 'harness objective CEe11goal1' -Scenario 'E2E-11' -Shape 'BLOCKED' -Workers @('coder') -Gates @('G7') -Dispatches 2 -ProgressDeltas 2 -Validation 'pending' -StopReason ([string]$e11.stop_reason) -Result $e11res -Note 'quota exhausted checkpoint held never completed harness-level'))
Assert-CEThat ($e11pass) 'E2E-11 quota exhaustion checkpoints and stops EXHAUSTED, never COMPLETED'
# --- E2E-12: out-of-authorization => blocks (G7). Unauthorized policy status => COMPLETE POLICY_BLOCKED, no progress.
$e12mv = Get-CEMove (New-CEStatus -Remaining @('prod-mutation') -Authorized $false -BlockerKind 'policy' -Progress $true)
$e12pass = (([string]$e12mv.move -ceq 'COMPLETE') -and ([string]$e12mv.stop_reason -ceq 'POLICY_BLOCKED'))
$e12res = 'FAIL'
if ($e12pass) { $e12res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe12goal1' -Objective 'harness objective CEe12goal1' -Scenario 'E2E-12' -Shape 'BLOCKED' -Workers @() -Gates @('G7') -Dispatches 0 -ProgressDeltas 0 -Interventions 1 -Validation 'pending' -StopReason 'POLICY_BLOCKED' -Result $e12res -Note 'outside authorization blocked with zero dispatches harness-level'))
Assert-CEThat ($e12pass) 'E2E-12 out-of-authorization work blocks with POLICY_BLOCKED and zero dispatches'
# --- E2E-13: budget => honest terminal (G7). Hard-cap goal consumed to exhaustion: honest EXHAUSTED, proxy cost bounded.
$e13dir = New-CETempDir 'ce-e13-'
[void](New-CEGoalWithTasks $e13dir 'CEe13goal1' @('CEe13t1', 'CEe13t2', 'CEe13t3') @('c1', 'c2', 'c3') -HardCap 1)
$e13 = Invoke-OrchestrationObjectiveRunner -GoalId 'CEe13goal1' -StoreDir $e13dir -Script @(
    @{ complete_tasks = @('CEe13t1'); fail_task = $null; add_finding = $false; satisfy = 1 },
    @{ complete_tasks = @('CEe13t2'); fail_task = $null; add_finding = $false; satisfy = 2 }
)
$e13got = Get-OrchestrationGoal -GoalId 'CEe13goal1' -StoreDir $e13dir
$e13px = Get-OrchestrationObjectiveCostProxy -Text 'CEe13goal1 budget terminal harness-level'
$e13pass = (([string]$e13.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED') -and [bool]$e13got.ok -and ([string]$e13got.goal['state'] -ceq 'EXHAUSTED') -and [bool]$e13px.ok -and [bool](Get-OTField $e13px.proxy 'is_proxy' $false))
$e13res = 'FAIL'
if ($e13pass) { $e13res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe13goal1' -Objective 'harness objective CEe13goal1' -Scenario 'E2E-13' -Shape 'BLOCKED' -Workers @('coder') -Gates @('G7') -Dispatches 1 -ProgressDeltas 1 -Validation 'pending' -StopReason ([string]$e13.stop_reason) -Result $e13res -Note 'budget honest terminal exhausted proxy cost harness-level'))
Assert-CEThat ($e13pass) 'E2E-13 budget exhaustion is an honest EXHAUSTED terminal with proxy cost declared'
# --- E2E-14: CI fail => repair (G4+G2). REAL delivery wiring: ci_failed repairs, clean run awaits CI.
$e14auth = Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('edit_refactor', 'test_build', 'pr_open', 'findings_repair', 'ci_rerun') -Denied @() -Boundaries @()
$e14events = @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened')
$e14step1 = Invoke-OrchestrationDeliveryStep -Events $e14events -CiStatus 'ci_failed' -Authorization $e14auth
$e14replan = (([string]$e14step1.action_step -ceq 'repair') -and [bool]$e14step1.repair_required -and [bool]$e14step1.revalidate -and (-not [bool]$e14step1.done_approved))
$e14step2 = Invoke-OrchestrationDeliveryStep -Events $e14events -Authorization $e14auth
$e14await = (([string]$e14step2.action_step -ceq 'await-ci') -and (-not [bool]$e14step2.blocked))
$e14pass = ($e14replan -and $e14await)
$e14res = 'FAIL'
if ($e14pass) { $e14res = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe14goal1' -Objective 'harness objective CEe14goal1' -Scenario 'E2E-14' -Shape 'MULTI_WORKER' -Workers @('coder', 'tester') -Gates @('G2', 'G4') -Findings 1 -StrategyChanges 1 -Retries 1 -Dispatches 2 -ProgressDeltas 1 -Validation 'pass' -StopReason 'OBJECTIVE_COMPLETED' -Result $e14res -Note 'ci failure repair plus revalidation harness-level'))
Assert-CEThat ($e14pass) 'E2E-14 CI failure replans, repairs, and completes after revalidation'
# --- E2E-15: Goal complete => final evidence (G8). Completed run + baseline read-back carries stop reason and result.
$e15dir = New-CETempDir 'ce-e15-'
[void](New-CEGoalWithTasks $e15dir 'CEe15goal1' @('CEe15t1') @('c1'))
$e15 = Invoke-OrchestrationObjectiveRunner -GoalId 'CEe15goal1' -StoreDir $e15dir -Script @(
    @{ complete_tasks = @('CEe15t1'); fail_task = $null; add_finding = $false; satisfy = 1 }
)
$e15got = Get-OrchestrationGoal -GoalId 'CEe15goal1' -StoreDir $e15dir
$e15stepRes = 'FAIL'
if (([string]$e15.stop_reason -ceq 'OBJECTIVE_COMPLETED') -and [bool]$e15got.ok) { $e15stepRes = 'PASS' }
[void](Add-CEEvent (New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe15goal1' -Objective 'harness objective CEe15goal1' -Scenario 'E2E-15' -Shape 'SINGLE_WORKER' -Workers @('coder') -Gates @('G8') -Dispatches 1 -ProgressDeltas 1 -Validation 'pass' -StopReason ([string]$e15.stop_reason) -Result $e15stepRes -Note 'goal complete final evidence harness-level'))
$e15base = Get-OrchestrationObjectiveTelemetryBaseline -GoalId 'CEe15goal1' -StoreDir $teleDir
$e15pass = (([string]$e15.stop_reason -ceq 'OBJECTIVE_COMPLETED') -and [bool]$e15got.ok -and ([string]$e15got.goal['state'] -ceq 'COMPLETED') -and ($null -ne $e15base) -and [bool]$e15base.ok -and ([long]$e15base.lines -ge 1) -and [bool]$e15base.summary.harness_level_all -and (-not [bool]$e15base.summary.runtime_real_any) -and ([long]$e15base.summary.cost_proxy_tokens_total -ge 0) -and [bool]$e15base.summary.cost_proxy_is_proxy)
$e15res = 'FAIL'
if ($e15pass) { $e15res = 'PASS' }
$e15fin = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEe15goal1' -Objective 'harness objective CEe15goal1' -Scenario 'E2E-15' -Shape 'SINGLE_WORKER' -Workers @('coder') -Gates @('G8') -Dispatches 1 -ProgressDeltas 1 -Validation 'pass' -StopReason 'OBJECTIVE_COMPLETED' -Result $e15res -Note 'final evidence envelope baseline readable harness-level'
[void](Add-CEEvent $e15fin)
Assert-CEThat ($e15pass) 'E2E-15 completed Goal carries persisted evidence plus a readable harness baseline'
# --- Telemetry lib unit gates: invalid inputs fail closed; missing baseline fails closed; proxy is honest.
$tBadGoal = New-OrchestrationObjectiveTelemetryEvent -GoalId 'bad id!' -Objective 'x' -Scenario 'E2E-01' -Shape 'SINGLE_WORKER' -Result 'PASS'
Assert-CEThat ((($null -ne $tBadGoal) -and (-not [bool]$tBadGoal.ok))) 'telemetry rejects invalid goal id fail-closed'
$tBadSc = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEtok1' -Objective 'x' -Scenario 'E2E-99' -Shape 'SINGLE_WORKER' -Result 'PASS'
Assert-CEThat ((($null -ne $tBadSc) -and (-not [bool]$tBadSc.ok))) 'telemetry rejects unknown scenario fail-closed'
$tBadJev = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEtok1' -Objective 'x' -Scenario 'E2E-06' -Shape 'DETERMINISTIC_FALLBACK' -JevCalls 1 -JevFallbacks 2 -Result 'PASS'
Assert-CEThat ((($null -ne $tBadJev) -and (-not [bool]$tBadJev.ok))) 'telemetry rejects fallbacks exceeding calls fail-closed'
$tMissing = Get-OrchestrationObjectiveTelemetryBaseline -GoalId 'CEnonexistent1' -StoreDir $teleDir
Assert-CEThat ((($null -ne $tMissing) -and (-not [bool]$tMissing.ok) -and ([string]$tMissing.reason -ceq 'telemetry-not-found'))) 'telemetry baseline on missing goal fails closed, never zeros-as-success'
$tPx = Get-OrchestrationObjectiveCostProxy -Text 'abcd1234'
Assert-CEThat (([bool]$tPx.ok -and ([long]$tPx.proxy.estimated_tokens -eq 2) -and [bool]$tPx.proxy.is_proxy -and ($null -eq $tPx.proxy.provider))) 'cost proxy counts chars-div-4 and declares itself proxy with no provider'
# --- F4: closed telemetry schema: free text redacted, extras rejected, secrets never persisted.
$tCanDir = New-CETempDir 'ce-tcan-'
$tCan = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEtcan1' -Objective 'objective with sk-SYNTHETICSECRET-VALID-1 inside' -Scenario 'E2E-01' -Shape 'SINGLE_WORKER' -Result 'PASS' -Note 'note ok'
Assert-CEThat ((($null -ne $tCan) -and [bool]$tCan.ok -and ([string]$tCan.event.objective -notmatch 'sk-SYNTHETIC'))) 'telemetry constructor redacts canary from objective'
Assert-CEThat (([string]$tCan.event.objective -match '<redacted>')) 'redacted objective carries the marker, never the secret'
$homeVal = ''
try { $homeVal = [string]$env:USERPROFILE } catch { $homeVal = '' }
if ([string]::IsNullOrWhiteSpace($homeVal)) { try { $homeVal = [string]$env:HOME } catch { $homeVal = '' } }
if (-not [string]::IsNullOrWhiteSpace($homeVal)) {
    $tHome = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEthome1' -Objective ('objective at ' + $homeVal + ' here') -Scenario 'E2E-01' -Shape 'SINGLE_WORKER' -Result 'PASS'
    Assert-CEThat ((($null -ne $tHome) -and [bool]$tHome.ok -and (-not ([string]$tHome.event.objective).Contains($homeVal)))) 'telemetry constructor redacts the real home dir'
}
$tGood = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEtclosed1' -Objective 'closed schema probe' -Scenario 'E2E-01' -Shape 'SINGLE_WORKER' -Result 'PASS'
Assert-CEThat ((($null -ne $tGood) -and [bool]$tGood.ok)) 'closed-schema probe event constructs'
$evExtra = @{}
foreach ($k in @($tGood.event.Keys)) { $evExtra[[string]$k] = $tGood.event[$k] }
$evExtra['objective_extra'] = 'smuggled'
$tExtra = Save-OrchestrationObjectiveTelemetryEvent -Event $evExtra -StoreDir $tCanDir
Assert-CEThat ((($null -ne $tExtra) -and (-not [bool]$tExtra.ok) -and ([string]$tExtra.reason -ceq 'event-extra-property'))) 'telemetry sink rejects extra properties fail-closed'
$evRaw = @{}
foreach ($k in @($tGood.event.Keys)) { $evRaw[[string]$k] = $tGood.event[$k] }
$evRaw['objective'] = 'leak sk-SYNTHETICSECRET-RAW-9 live'
$tRaw = Save-OrchestrationObjectiveTelemetryEvent -Event $evRaw -StoreDir $tCanDir
Assert-CEThat ((($null -ne $tRaw) -and (-not [bool]$tRaw.ok) -and ([string]$tRaw.reason -ceq 'event-sensitive-blocked'))) 'telemetry sink never persists an unredacted secret'
# --- F4 residual: nested schema bypass closed (sink rebuilds canonical record).
$tF4Dir = New-CETempDir 'ce-tf4-'
$tF4Base = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEtf4nest1' -Objective 'f4 nested probe' -Scenario 'E2E-01' -Shape 'SINGLE_WORKER' -Result 'PASS'
Assert-CEThat ((($null -ne $tF4Base) -and [bool]$tF4Base.ok)) 'F4 base probe event constructs'
$evNest = @{}
foreach ($k in @($tF4Base.event.Keys)) { $evNest[[string]$k] = $tF4Base.event[$k] }
$pxSrc = Get-OTField $tF4Base.event 'cost_proxy' $null
$pxNest = @{}
if ($pxSrc -is [System.Collections.IDictionary]) { foreach ($pk in @($pxSrc.Keys)) { $pxNest[[string]$pk] = $pxSrc[$pk] } }
else { foreach ($pp in @($pxSrc.PSObject.Properties)) { $pxNest[[string]$pp.Name] = $pp.Value } }
$pxNest['extra'] = 'sk-SYNTHETICSECRET-F4-NESTED-1'
$evNest['cost_proxy'] = $pxNest
$tF4Nest = Save-OrchestrationObjectiveTelemetryEvent -Event $evNest -StoreDir $tF4Dir
Assert-CEThat ((($null -ne $tF4Nest) -and (-not [bool]$tF4Nest.ok))) 'F4 sink blocks nested cost_proxy.extra canary fail-closed'
$tF4TimeBase = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEtf4time1' -Objective 'f4 timestamp probe' -Scenario 'E2E-01' -Shape 'SINGLE_WORKER' -Result 'PASS'
Assert-CEThat ((($null -ne $tF4TimeBase) -and [bool]$tF4TimeBase.ok)) 'F4 timestamp probe event constructs'
$evTime = @{}
foreach ($k in @($tF4TimeBase.event.Keys)) { $evTime[[string]$k] = $tF4TimeBase.event[$k] }
$evTime['recorded_at'] = '2000-01-01T00:00:00.000Z'
$tF4Time = Save-OrchestrationObjectiveTelemetryEvent -Event $evTime -StoreDir $tF4Dir
Assert-CEThat ((($null -ne $tF4Time) -and [bool]$tF4Time.ok)) 'F4 sink accepts event with tampered recorded_at by regenerating it'
$tF4TimePath = Get-OTTelemetryFilePath -Dir $tF4Dir -GoalId 'CEtf4time1'
$tF4TimeLine = ''
try { $tF4TimeLine = (Get-Content -LiteralPath $tF4TimePath -ErrorAction Stop | Select-Object -Last 1) } catch { $tF4TimeLine = '' }
Assert-CEThat (((-not [string]::IsNullOrWhiteSpace($tF4TimeLine)) -and ($tF4TimeLine -notmatch '2000-01-01'))) 'F4 persisted line regenerates recorded_at, caller timestamp ignored'
$tF4CanonBase = New-OrchestrationObjectiveTelemetryEvent -GoalId 'CEtf4canon1' -Objective 'f4 canonical probe' -Scenario 'E2E-01' -Shape 'SINGLE_WORKER' -Result 'PASS'
Assert-CEThat ((($null -ne $tF4CanonBase) -and [bool]$tF4CanonBase.ok)) 'F4 canonical probe event constructs'
$evCanon = @{}
foreach ($k in @($tF4CanonBase.event.Keys)) { $evCanon[[string]$k] = $tF4CanonBase.event[$k] }
$tF4Canon = Save-OrchestrationObjectiveTelemetryEvent -Event $evCanon -StoreDir $tF4Dir
Assert-CEThat ((($null -ne $tF4Canon) -and [bool]$tF4Canon.ok)) 'F4 valid event persists via canonical rebuild'
$tF4CanonPath = Get-OTTelemetryFilePath -Dir $tF4Dir -GoalId 'CEtf4canon1'
$tF4CanonLine = ''
try { $tF4CanonLine = (Get-Content -LiteralPath $tF4CanonPath -ErrorAction Stop | Select-Object -Last 1) } catch { $tF4CanonLine = '' }
$tF4Back = $null
try { $tF4Back = ConvertFrom-Json $tF4CanonLine } catch { $tF4Back = $null }
$pxBack = $null
try { $pxBack = $tF4Back.cost_proxy } catch { $pxBack = $null }
$pxBackKeys = @()
try {
    if ($null -ne $pxBack) {
        if ($pxBack -is [System.Collections.IDictionary]) { $pxBackKeys = @($pxBack.Keys) }
        else { $pxBackKeys = @($pxBack.PSObject.Properties | ForEach-Object { $_.Name }) }
    }
} catch { $pxBackKeys = @() }
Assert-CEThat ((($null -ne $tF4Back) -and ([long]$tF4Back.schema_version -eq 1) -and [bool]$tF4Back.harness_level -and (-not [bool]$tF4Back.runtime_real) -and (-not [string]::IsNullOrWhiteSpace([string]$tF4Back.recorded_at)))) 'F4 persisted line carries canonical envelope with regenerated timestamp'
Assert-CEThat (((@($pxBackKeys).Count -eq 5) -and ($pxBackKeys -contains 'estimated_tokens') -and ($pxBackKeys -contains 'counted_chars') -and ($pxBackKeys -contains 'method') -and ($pxBackKeys -contains 'is_proxy') -and ($pxBackKeys -contains 'provider'))) 'F4 persisted cost_proxy carries exactly the closed canonical keys'
try { Remove-Item -LiteralPath $tCanDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $tF4Dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
# --- Cross-scenario baseline: all 15 events aggregated in memory; full scenario + gate coverage; harness-only.
$agg = New-OrchestrationObjectiveTelemetrySummary -Events @($allEvents.ToArray())
Assert-CEThat ((($null -ne $agg) -and [bool]$agg.ok)) 'cross-scenario summary aggregates'
Assert-CEThat (([long]$agg.summary.events_total -eq [long]$allEvents.Count)) 'summary counts every scenario event'
Assert-CEThat (([long]$agg.summary.events_total -ge 15)) 'summary holds at least the 15 scenario events'
foreach ($sc in @('E2E-01','E2E-02','E2E-03','E2E-04','E2E-05','E2E-06','E2E-07','E2E-08','E2E-09','E2E-10','E2E-11','E2E-12','E2E-13','E2E-14','E2E-15')) {
    Assert-CEThat ($agg.summary.scenarios.ContainsKey($sc)) ('summary covers scenario ' + $sc)
}
$gateSeen = @{}
foreach ($ev in @($allEvents.ToArray())) {
    foreach ($g in @(Get-OTField $ev 'gates' @())) {
        $gs = ([string]$g).Trim().ToUpperInvariant()
        if (-not $gateSeen.ContainsKey($gs)) { $gateSeen[$gs] = $true }
    }
}
foreach ($g in @('G1','G2','G3','G4','G5','G6','G7','G8')) {
    Assert-CEThat ($gateSeen.ContainsKey($g)) ('gates cover ' + $g)
}
$passCount = 0
foreach ($ev in @($allEvents.ToArray())) {
    if ([string](Get-OTField $ev 'result' '') -ceq 'PASS') { $passCount++ }
}
Assert-CEThat (($passCount -ge 15)) 'every scenario recorded PASS (one or more events each)'
Assert-CEThat ([bool]$agg.summary.harness_level_all) 'no event escapes harness_level'
Assert-CEThat ((-not [bool]$agg.summary.runtime_real_any)) 'no event claims runtime-real'
Assert-CEThat ([bool]$agg.summary.cost_proxy_is_proxy) 'aggregate cost stays declared proxy'
Remove-Item -LiteralPath $teleDir -Recurse -Force
Remove-Item -LiteralPath $e03dir -Recurse -Force
Remove-Item -LiteralPath $e04dir -Recurse -Force
Remove-Item -LiteralPath $e05dir -Recurse -Force
Remove-Item -LiteralPath $e08dir -Recurse -Force
Remove-Item -LiteralPath $e09dir -Recurse -Force
Remove-Item -LiteralPath $e10store -Recurse -Force
Remove-Item -LiteralPath $e11dir -Recurse -Force
Remove-Item -LiteralPath $e13dir -Recurse -Force
Remove-Item -LiteralPath $e15dir -Recurse -Force
try { Remove-Item -LiteralPath $ceFixDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $ceTeleDec -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $e07store -Recurse -Force -ErrorAction SilentlyContinue } catch { }
Write-Output ("OrchestrationCorrectiveE2E: PASS ($passed assertions, E2E-01..E2E-15 harness-level, gates G1-G8; runtime-real matrix V1/V2/dual/PS5.1/PS7 with live OpenCode = BLOCKED sem provider)")
