<#!
.SYNOPSIS
    F3.2 fixture suite: one objective, three dependent phases, integrated
    Planner -> NativeDispatch -> TaskKernel -> GoalKernel path.
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; the repo tree is never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn, no model provider.

    FACTS are read back from kernel stores (receipt phases, task revisions and
    states, goal revisions and states, effective grants, advance records).
    The only SIMULATION is the worker effect: one deterministic artifact per
    phase, written between CLAIM and SETTLE. Groups:

      [FIX] fixture bootstrap (env, grants, goal ACTIVE + ownership, tasks)
      [N1]   failure before dispatch (isolated subject: not attached /
             denied auth / scope)
      [BAR]  successor barrier (successor refused while predecessor is
             pending, settled-but-unverified, or failed; barrier opens only
             after verification+review+DONE+goal progress; the kernel
             contract does NOT enforce order - harness discipline, declared)
      [P1-P3]  integrated phases, barrier opened post-verification by the
             harness, advance recorded per settlement
      [PROG] invalid artifact (verification fails, progress untouched,
             completion refused, total preserved)
      [OBJ]  TASK_DONE / PHASE_DONE != OBJECTIVE_DONE; CAS-only completion
      [N2]   failure after execution before ack (ambiguous, no replay)
      [N3]   retry allowed and limited (attempt budget)
      [N4]   stale lease + fencing (takeover)
      [N5]   cancellation (goal and task)
      [N6]   budget exhausted (objective and task)
      [N7]   no double execution, no false DONE
      [H]    hygiene (no spawn/network, ASCII, repo tree untouched)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationF3ThreePhaseFixture.ps1')

$script:passed = 0
$script:failed = 0

function Assert-F3 {
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

# Environment + goal + phase tasks of one objective, ready for the walk.
function New-F3Subject {
    param([string]$Label = 'main', [string]$GoalId = '', [int]$Phases = 3, [int]$AttemptBudget = 3, [long]$LeaseTtlMs = 300000)
    $e = New-F3Environment -Label $Label
    $g = New-F3Goal -Environment $e -GoalId $GoalId -Criteria @('crit-p1', 'crit-p2', 'crit-p3') -LeaseTtlMs $LeaseTtlMs
    if (-not [bool]$g.ok) { return [pscustomobject]@{ env = $e; goal = $null; tasks = @{}; error = [string]$g.reason } }
    $gid = [string]$g.data.goal_id
    $tasks = @{}
    foreach ($n in 1..$Phases) {
        $t = New-F3PhaseTask -Environment $e -GoalId $gid -PhaseIndex $n -AttemptBudget $AttemptBudget
        if (-not [bool]$t.ok) { return [pscustomobject]@{ env = $e; goal = $null; tasks = @{}; error = ('task' + $n + ':' + [string]$t.reason) } }
        $tasks[$n] = $t.data
    }
    return [pscustomobject]@{
        env   = $e
        goal  = $g.data
        tasks = $tasks
        error = ''
    }
}

# One full phase: attach (phase1 only) -> four receipt phases (settle-only)
# -> task settlement (verification+review+DONE) -> goal task completion
# with walk+settlement guards and a live DONE+verified re-read -> attach
# the successor (barrier opens HERE, never before) -> causal advance.
# The successor is therefore never dispatchable while its predecessor is
# pending, failed, or unverified: admission refuses it with
# task-not-in-goal until the attach above runs.
function Invoke-F3FullPhase {
    param($Subject = $null, [int]$Phase = 1, $Counter = $null, $Total = 3)
    $e = $Subject.env
    $goalId = [string]$Subject.goal.goal_id
    $gen = [long]$Subject.goal.gen
    $auth = $Subject.goal.auth
    $td = $Subject.tasks[$Phase]

    $intentSlot = New-F3DispatchIntent -GoalId $goalId -TaskId ([string]$td.task_id) `
        -TaskExpectedRevision ([long]$td.revision) -Gen $gen -Scope ([string]$td.scope) -PhaseIndex $Phase
    $nextIntent = $null
    $nextTaskId = ''
    if ($Phase -lt $Total) {
        $nt = $Subject.tasks[$Phase + 1]
        $nextTaskId = [string]$nt.task_id
        $ni = New-F3DispatchIntent -GoalId $goalId -TaskId $nextTaskId -TaskExpectedRevision ([long]$nt.revision) `
            -Gen $gen -Scope ([string]$nt.scope) -PhaseIndex ($Phase + 1)
        $nextIntent = $ni.data.intent
    }
    if ($Phase -eq 1) {
        $null = Add-F3TaskToGoal -Environment $e -GoalId $goalId -TaskId ([string]$td.task_id) -Gen $gen
    }
    $live = Get-F3LiveGoal -Environment $e -GoalId $goalId
    $walk = Invoke-F3ReceiptWalk -Environment $e -Goal $live -Authorization $auth -Intent $intentSlot.data.intent `
        -TaskId ([string]$td.task_id) -ArtifactPath ([string]$td.artifact) -PhaseIndex $Phase -Counter $Counter `
        -CallId ('call_f3_p' + [string]$Phase) -MessageId ('msg_f3_p' + [string]$Phase) `
        -ChildSessionId ('ses_f3_child_p' + [string]$Phase)
    $exp = Get-F3ExpectedArtifactContent -GoalId $goalId -TaskId ([string]$td.task_id) -PhaseIndex $Phase
    $ts = Invoke-F3TaskSettlement -Environment $e -TaskId ([string]$td.task_id) -ArtifactPath ([string]$td.artifact) `
        -PhaseIndex $Phase -ExpectedContent $exp
    if ([bool]$walk.ok -and [bool]$ts.ok) {
        $ct = Complete-F3GoalTask -Environment $e -GoalId $goalId -TaskId ([string]$td.task_id) -Gen $gen -PhaseIndex $Phase -Walk $walk -Settlement $ts
    }
    else {
        $ct = New-F3Envelope -Ok $false -Reason 'predecessor-not-verified'
    }
    $attachNext = $null
    $advance = $null
    $settledKey = [string](Get-F3Value (Get-F3Value $walk 'data' $null) 'key' '')
    if (($Phase -lt $Total) -and [bool]$walk.ok -and [bool]$ts.ok -and ($null -ne $ct) -and [bool]$ct.ok) {
        $attachNext = Add-F3TaskToGoal -Environment $e -GoalId $goalId -TaskId $nextTaskId -Gen $gen
        if (($null -ne $attachNext) -and [bool]$attachNext.ok) {
            $advance = Invoke-F3CausalAdvance -Environment $e -Goal $live -Authorization $auth `
                -NextIntent $nextIntent -SettledKey $settledKey
        }
    }
    return [pscustomobject]@{
        phase    = $Phase
        intent   = $intentSlot
        walk     = $walk
        settle   = $ts
        goal_task = $ct
        attach_next = $attachNext
        advance  = $advance
        key      = $settledKey
    }
}

$tempRoot = ''
try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('f3-suite-' + [guid]::NewGuid().ToString('N'))
    Register-F3OwnedRoot -Root $tempRoot
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $repoProbe = Join-Path $tempRoot 'repo-probe'
    New-Item -ItemType Directory -Path $repoProbe -Force | Out-Null

    # ================= [FIX] bootstrap =================
    $s = New-F3Subject -Label 'main' -GoalId 'f3-goal-main'
    Assert-F3 ([string]::IsNullOrWhiteSpace([string]$s.error)) '[FIX] objective fixture with three phase tasks' ([string]$s.error)
    $e = $s.env
    $goalId = [string]$s.goal.goal_id
    $gen = [long]$s.goal.gen
    $auth = $s.goal.auth
    $counter = @{ executions = 0 }

    $lg0 = Get-F3LiveGoal -Environment $e -GoalId $goalId
    Assert-F3 (([string]$lg0['state'] -ceq 'ACTIVE')) '[FIX] objective is ACTIVE before any dispatch' ([string]$lg0['state'])
    Assert-F3 (([long]$lg0['progress']['total'] -eq 3)) '[FIX] objective carries three criteria' ([string]$lg0['progress']['total'])
    Assert-F3 (([long]$s.goal.gen -ge 1)) '[FIX] ownership generation allocated by the GoalKernel' ([string]$s.goal.gen)

    $eff = Get-F3EffectiveGrants
    Assert-F3 ((@($eff).Count -eq 2) -and (@($eff) -contains 'fs.read') -and (@($eff) -contains 'fs.write')) '[FIX] effective grants are the baseline/task/runtime/env intersection' (@($eff) -join ',')
    $effNone = Get-F3EffectiveGrants -Role 'role-inexistente'
    Assert-F3 (@($effNone).Count -eq 0) '[FIX] an unknown role yields an empty grant set (fail closed)' (@($effNone) -join ',')
    $effNarrow = Get-F3EffectiveGrants -EnvironmentGrants @('fs.read')
    Assert-F3 ((@($effNarrow).Count -eq 1) -and (@($effNarrow) -contains 'fs.read')) '[FIX] grants intersect, never union (fs.write dropped by the environment set)' (@($effNarrow) -join ',')

    $t1 = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir ([string]$e.tasks_dir)
    Assert-F3 (([string]$t1['state'] -ceq 'IMPLEMENTING') -and ([long]$t1['revision'] -eq 3)) '[FIX] phase task is IMPLEMENTING with the expected revision' ('state=' + [string]$t1['state'] + ' rev=' + [string]$t1['revision'])

    # ================= [N1] failure before dispatch (isolated subject) =================
    # N1 runs on its OWN objective: attaching probe tasks here must never
    # leak into the main happy-path subject below (no cross-goal attach).
    $sN1 = New-F3Subject -Label 'n1' -GoalId 'f3-goal-n1'
    Assert-F3 ([string]::IsNullOrWhiteSpace([string]$sN1.error)) '[N1] isolated subject for pre-dispatch refusals' ([string]$sN1.error)
    $eN1 = $sN1.env
    $gidN1 = [string]$sN1.goal.goal_id
    $genN1 = [long]$sN1.goal.gen
    $authN1 = $sN1.goal.auth
    $pre = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gidN1 -TaskId 'f3-p2' -TaskExpectedRevision 3 -Gen $genN1 -Scope 'artifacts/phase2.txt' -PhaseIndex 2).data.intent `
        -Authorization $authN1 -SessionId 'ses_f3_parent' -ReceiptDir ([string]$eN1.receipt_dir) `
        -GoalStoreDir ([string]$eN1.goal_dir) -TasksDir ([string]$eN1.tasks_dir) -FlagsPath ([string]$eN1.flags)
    Assert-F3 ((-not [bool]$pre.ok) -and ([string]$pre.reason -ceq 'task-not-in-goal')) '[N1] a phase task not attached to the live goal is refused before any dispatch' ([string]$pre.reason)
    Assert-F3 (([int]$pre.executor_calls -eq 0)) '[N1] the pre-dispatch refusal has zero effects' ([string]$pre.executor_calls)
    Assert-F3 ($null -eq (Get-F3ReceiptRaw -Environment $eN1 -GoalId $gidN1 -Key (Get-F3PreparedKey -Prepare $pre))) '[N1] the pre-dispatch refusal wrote no receipt' ''

    $denyAuth = @{ explicit_allow = $false; goal_id = $gidN1; owner = 'planner-1'; generation = $genN1; source = 'planner' }
    $null = Add-F3TaskToGoal -Environment $eN1 -GoalId $gidN1 -TaskId 'f3-p2' -Gen $genN1
    $deny = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gidN1 -TaskId 'f3-p2' -TaskExpectedRevision 3 -Gen $genN1 -Scope 'artifacts/phase2.txt' -PhaseIndex 2).data.intent `
        -Authorization $denyAuth -SessionId 'ses_f3_parent' -ReceiptDir ([string]$eN1.receipt_dir) `
        -GoalStoreDir ([string]$eN1.goal_dir) -TasksDir ([string]$eN1.tasks_dir) -FlagsPath ([string]$eN1.flags)
    Assert-F3 ((-not [bool]$deny.ok) -and ([string]$deny.reason -ceq 'explicit-allow-required')) '[N1] a non-explicit authorization is refused before dispatch' ([string]$deny.reason)
    Assert-F3 (([int]$deny.executor_calls -eq 0)) '[N1] the denied authorization has zero effects' ([string]$deny.executor_calls)

    $scopeDenied = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gidN1 -TaskId 'f3-p2' -TaskExpectedRevision 3 -Gen $genN1 -Scope 'artifacts/phase9.txt' -PhaseIndex 2).data.intent `
        -Authorization $authN1 -SessionId 'ses_f3_parent' -ReceiptDir ([string]$eN1.receipt_dir) `
        -GoalStoreDir ([string]$eN1.goal_dir) -TasksDir ([string]$eN1.tasks_dir) -FlagsPath ([string]$eN1.flags)
    Assert-F3 ((-not [bool]$scopeDenied.ok) -and ([string]$scopeDenied.reason -ceq 'scope-not-granted')) '[N1] a scope outside the task grants is refused before dispatch' ([string]$scopeDenied.reason)
    Remove-F3Environment -Environment $eN1

    # ================= [BAR] successor barrier =================
    # The kernel attach contract (CAS + fencing) does NOT check predecessor
    # state, so the barrier below is HARNESS discipline, declared as such:
    # the successor is attached (and becomes dispatchable) only after the
    # predecessor is settled AND verified AND reviewed AND DONE AND recorded
    # as goal progress. Every early open/dispatch attempt must refuse.
    $sB = New-F3Subject -Label 'bar' -GoalId 'f3-goal-bar' -Phases 2
    Assert-F3 ([string]::IsNullOrWhiteSpace([string]$sB.error)) '[BAR] barrier subject with two phase tasks' ([string]$sB.error)
    $eB = $sB.env
    $gidB = [string]$sB.goal.goal_id
    $genB = [long]$sB.goal.gen
    $authB = $sB.goal.auth
    $tdB1 = $sB.tasks[1]
    $tdB2 = $sB.tasks[2]
    $ctrB = @{ executions = 0 }

    $preB0 = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gidB -TaskId 'f3-p2' -TaskExpectedRevision ([long]$tdB2.revision) -Gen $genB -Scope ([string]$tdB2.scope) -PhaseIndex 2).data.intent `
        -Authorization $authB -SessionId 'ses_f3_parent' -ReceiptDir ([string]$eB.receipt_dir) `
        -GoalStoreDir ([string]$eB.goal_dir) -TasksDir ([string]$eB.tasks_dir) -FlagsPath ([string]$eB.flags)
    Assert-F3 ((-not [bool]$preB0.ok) -and ([string]$preB0.reason -ceq 'task-not-in-goal') -and ([int]$preB0.executor_calls -eq 0)) '[BAR] the successor is refused while the predecessor is still pending' ([string]$preB0.reason)

    $null = Add-F3TaskToGoal -Environment $eB -GoalId $gidB -TaskId 'f3-p1' -Gen $genB
    $liveB = Get-F3LiveGoal -Environment $eB -GoalId $gidB
    $intentB1 = (New-F3DispatchIntent -GoalId $gidB -TaskId 'f3-p1' -TaskExpectedRevision ([long]$tdB1.revision) -Gen $genB -Scope ([string]$tdB1.scope) -PhaseIndex 1).data.intent
    $walkB1 = Invoke-F3ReceiptWalk -Environment $eB -Goal $liveB -Authorization $authB -Intent $intentB1 `
        -TaskId 'f3-p1' -ArtifactPath ([string]$tdB1.artifact) -PhaseIndex 1 -Counter $ctrB `
        -CallId 'call_bar_1' -MessageId 'msg_bar_1' -ChildSessionId 'ses_bar_1'
    Assert-F3 ([bool]$walkB1.ok) '[BAR] the predecessor settles' ([string]$walkB1.reason)
    $preB1 = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gidB -TaskId 'f3-p2' -TaskExpectedRevision ([long]$tdB2.revision) -Gen $genB -Scope ([string]$tdB2.scope) -PhaseIndex 2).data.intent `
        -Authorization $authB -SessionId 'ses_f3_parent' -ReceiptDir ([string]$eB.receipt_dir) `
        -GoalStoreDir ([string]$eB.goal_dir) -TasksDir ([string]$eB.tasks_dir) -FlagsPath ([string]$eB.flags)
    Assert-F3 ((-not [bool]$preB1.ok) -and ([string]$preB1.reason -ceq 'task-not-in-goal')) '[BAR] the successor is still refused after settlement but before verification/review/DONE' ([string]$preB1.reason)

    $ctEarly = Complete-F3GoalTask -Environment $eB -GoalId $gidB -TaskId 'f3-p1' -Gen $genB -PhaseIndex 1 -Walk $walkB1
    Assert-F3 ((-not [bool]$ctEarly.ok)) '[BAR] goal progress without task settlement (verification/review/DONE) is refused' ([string]$ctEarly.reason)
    $lgB0 = Get-F3LiveGoal -Environment $eB -GoalId $gidB
    Assert-F3 (([long]$lgB0['progress']['satisfied'] -eq 0) -and ([long]$lgB0['progress']['total'] -eq 3)) '[BAR] the refused promotion leaves progress at 0 of 3 (total preserved)' ('sat=' + [string]$lgB0['progress']['satisfied'] + ' total=' + [string]$lgB0['progress']['total'])

    $expB1 = Get-F3ExpectedArtifactContent -GoalId $gidB -TaskId 'f3-p1' -PhaseIndex 1
    $tsB1 = Invoke-F3TaskSettlement -Environment $eB -TaskId 'f3-p1' -ArtifactPath ([string]$tdB1.artifact) `
        -PhaseIndex 1 -ExpectedContent $expB1
    Assert-F3 ([bool]$tsB1.ok) '[BAR] the predecessor completes verification+review+DONE' ([string]$tsB1.reason)
    $ctB1 = Complete-F3GoalTask -Environment $eB -GoalId $gidB -TaskId 'f3-p1' -Gen $genB -PhaseIndex 1 -Walk $walkB1 -Settlement $tsB1
    Assert-F3 ([bool]$ctB1.ok) '[BAR] goal progress after verification+review+DONE succeeds' ([string]$ctB1.reason)
    $lgB1 = Get-F3LiveGoal -Environment $eB -GoalId $gidB
    Assert-F3 (([long]$lgB1['progress']['satisfied'] -eq 1) -and ([long]$lgB1['progress']['total'] -eq 3)) '[BAR] verified progress reads 1 of 3 (never 1/1)' ('sat=' + [string]$lgB1['progress']['satisfied'] + ' total=' + [string]$lgB1['progress']['total'])
    $attB2 = Add-F3TaskToGoal -Environment $eB -GoalId $gidB -TaskId 'f3-p2' -Gen $genB
    Assert-F3 ([bool]$attB2.ok) '[BAR] the barrier opens only now: the successor attaches after predecessor DONE+progress' ([string]$attB2.reason)
    $preB2 = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gidB -TaskId 'f3-p2' -TaskExpectedRevision ([long]$tdB2.revision) -Gen $genB -Scope ([string]$tdB2.scope) -PhaseIndex 2).data.intent `
        -Authorization $authB -SessionId 'ses_f3_parent' -ReceiptDir ([string]$eB.receipt_dir) `
        -GoalStoreDir ([string]$eB.goal_dir) -TasksDir ([string]$eB.tasks_dir) -FlagsPath ([string]$eB.flags)
    Assert-F3 ([bool]$preB2.ok) '[BAR] the successor is dispatchable only after the barrier opened' ([string]$preB2.reason)
    Remove-F3Environment -Environment $eB

    # A failed predecessor never opens the barrier: the failed settlement
    # completes no DONE, the guarded promotion refuses, progress stays 0/3.
    $sBF = New-F3Subject -Label 'barfail' -GoalId 'f3-goal-barfail' -Phases 2
    Assert-F3 ([string]::IsNullOrWhiteSpace([string]$sBF.error)) '[BAR] failed-predecessor subject ready' ([string]$sBF.error)
    $eBF = $sBF.env
    $gidBF = [string]$sBF.goal.goal_id
    $genBF = [long]$sBF.goal.gen
    $authBF = $sBF.goal.auth
    $tdBF1 = $sBF.tasks[1]
    $tdBF2 = $sBF.tasks[2]
    $ctrBF = @{ executions = 0 }
    $null = Add-F3TaskToGoal -Environment $eBF -GoalId $gidBF -TaskId 'f3-p1' -Gen $genBF
    $liveBF = Get-F3LiveGoal -Environment $eBF -GoalId $gidBF
    $intentBF1 = (New-F3DispatchIntent -GoalId $gidBF -TaskId 'f3-p1' -TaskExpectedRevision ([long]$tdBF1.revision) -Gen $genBF -Scope ([string]$tdBF1.scope) -PhaseIndex 1).data.intent
    $walkBF1 = Invoke-F3ReceiptWalk -Environment $eBF -Goal $liveBF -Authorization $authBF -Intent $intentBF1 `
        -TaskId 'f3-p1' -ArtifactPath ([string]$tdBF1.artifact) -PhaseIndex 1 -Counter $ctrBF `
        -CallId 'call_barfail_1' -MessageId 'msg_barfail_1' -ChildSessionId 'ses_barfail_1' `
        -Result @{ status = 'failed'; claimed_evidence = @('criterion:0') }
    Assert-F3 ([bool]$walkBF1.ok) '[BAR] a failed worker result still settles the attempt honestly' ([string]$walkBF1.reason)
    $expBF1 = Get-F3ExpectedArtifactContent -GoalId $gidBF -TaskId 'f3-p1' -PhaseIndex 1
    $tsBF1 = Invoke-F3TaskSettlement -Environment $eBF -TaskId 'f3-p1' -ArtifactPath ([string]$tdBF1.artifact) `
        -PhaseIndex 1 -ExpectedContent $expBF1
    Assert-F3 ((-not [bool]$tsBF1.ok)) '[BAR] the failed predecessor cannot finish the DONE chain' ([string]$tsBF1.reason)
    $ctBF1 = Complete-F3GoalTask -Environment $eBF -GoalId $gidBF -TaskId 'f3-p1' -Gen $genBF -PhaseIndex 1 -Walk $walkBF1 -Settlement $tsBF1
    Assert-F3 ((-not [bool]$ctBF1.ok)) '[BAR] goal progress after a failed predecessor is refused' ([string]$ctBF1.reason)
    $lgBF = Get-F3LiveGoal -Environment $eBF -GoalId $gidBF
    Assert-F3 (([long]$lgBF['progress']['satisfied'] -eq 0) -and ([long]$lgBF['progress']['total'] -eq 3)) '[BAR] a failed predecessor leaves progress at 0 of 3' ('sat=' + [string]$lgBF['progress']['satisfied'])
    $preBF2 = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gidBF -TaskId 'f3-p2' -TaskExpectedRevision ([long]$tdBF2.revision) -Gen $genBF -Scope ([string]$tdBF2.scope) -PhaseIndex 2).data.intent `
        -Authorization $authBF -SessionId 'ses_f3_parent' -ReceiptDir ([string]$eBF.receipt_dir) `
        -GoalStoreDir ([string]$eBF.goal_dir) -TasksDir ([string]$eBF.tasks_dir) -FlagsPath ([string]$eBF.flags)
    Assert-F3 ((-not [bool]$preBF2.ok) -and ([string]$preBF2.reason -ceq 'task-not-in-goal')) '[BAR] the successor of a failed predecessor stays refused' ([string]$preBF2.reason)
    Remove-F3Environment -Environment $eBF

    # ================= [P1-P3] integrated phases =================
    $r1 = Invoke-F3FullPhase -Subject $s -Phase 1 -Counter $counter
    Assert-F3 ([bool]$r1.walk.ok) '[P1] phase1 walks prepare/claim/effect/settle' ([string]$r1.walk.reason)
    $rc1 = Get-F3ReceiptRaw -Environment $e -GoalId $goalId -Key $r1.key
    Assert-F3 (([string]$rc1.phase -ceq 'settled') -and ([string]$rc1.handoff_state -ceq 'SETTLED')) '[P1] phase1 receipt is settled/SETTLED' ('phase=' + [string]$rc1.phase + ' handoff=' + [string]$rc1.handoff_state)
    Assert-F3 (([int]$r1.walk.data.step.prepare.executor_calls -eq 0) -and ([int]$r1.walk.data.step.claim.executor_calls -eq 0)) '[P1] PREPARE and CLAIM never count an execution' ''
    Assert-F3 (([int]$counter.executions -eq 1)) '[P1] exactly one simulated worker execution in phase1' ([string]$counter.executions)
    Assert-F3 (($null -ne $r1.attach_next) -and [bool]$r1.attach_next.ok) '[P1] the successor attached only after phase1 DONE+progress (barrier opened post-verification)' ([string]$r1.attach_next.reason)
    $adv1 = $r1.advance
    Assert-F3 (([bool]$adv1.ok) -and ([bool]$adv1.prepared) -and ([string]$adv1.move -ceq 'CONTINUE')) '[P1] the causal advance prepares the next phase' ([string]$adv1.reason)
    Assert-F3 (([int]$adv1.executor_calls -eq 0)) '[P1] the advance is a decision, never an effect' ([string]$adv1.executor_calls)
    $advRec1 = Get-F3AdvanceRecord -Environment $e -GoalId $goalId -SettledKey $r1.key
    Assert-F3 (($null -ne $advRec1) -and ([bool]$advRec1.prepared)) '[P1] the advance decision is persisted with the settlement key' ''
    Assert-F3 ([bool]$r1.settle.ok) '[P1] phase1 task settlement (verification+review+DONE) succeeded' ([string]$r1.settle.reason)
    $liveT1 = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir ([string]$e.tasks_dir)
    Assert-F3 (([string]$liveT1['state'] -ceq 'DONE')) '[P1] phase1 task is DONE in the TaskKernel' ([string]$liveT1['state'])
    Assert-F3 ([bool]$r1.goal_task.ok) '[P1] phase1 task completed on the objective (GoalKernel CAS)' ([string]$r1.goal_task.reason)
    $liveG1 = Get-F3LiveGoal -Environment $e -GoalId $goalId
    Assert-F3 (([long]$liveG1['progress']['satisfied'] -eq 1) -and ([long]$liveG1['progress']['total'] -eq 3)) '[P1] verified progress advanced to 1 of 3 (total preserved)' ('sat=' + [string]$liveG1['progress']['satisfied'] + ' total=' + [string]$liveG1['progress']['total'])
    Assert-F3 (([string]$liveG1['state'] -ceq 'ACTIVE')) '[P1] the objective stays ACTIVE after phase1' ([string]$liveG1['state'])

    $r2 = Invoke-F3FullPhase -Subject $s -Phase 2 -Counter $counter
    Assert-F3 ([bool]$r2.walk.ok) '[P2] phase2 walks after the phase1 barrier opened' ([string]$r2.walk.reason)
    Assert-F3 (([int]$counter.executions -eq 2)) '[P2] the second execution happened exactly once' ([string]$counter.executions)
    $advRec2 = Get-F3AdvanceRecord -Environment $e -GoalId $goalId -SettledKey $r2.key
    Assert-F3 (($null -ne $advRec2) -and ([string]$advRec2.next_idempotency_key -ceq (New-F3DispatchIntent -GoalId $goalId -TaskId 'f3-p3' -TaskExpectedRevision 3 -Gen $gen -Scope 'artifacts/phase3.txt' -PhaseIndex 3).data.key)) '[P2] the advance carries the phase3 idempotency key' ([string]$advRec2.next_idempotency_key)
    $liveT2 = Get-OrchestrationTask -TaskId 'f3-p2' -TasksDir ([string]$e.tasks_dir)
    Assert-F3 (([string]$liveT2['state'] -ceq 'DONE')) '[P2] phase2 task is DONE in the TaskKernel' ([string]$liveT2['state'])
    $liveG2 = Get-F3LiveGoal -Environment $e -GoalId $goalId
    Assert-F3 (([long]$liveG2['progress']['satisfied'] -eq 2) -and ([long]$liveG2['progress']['total'] -eq 3) -and ([long]$liveG2['plan_progress']['phase'] -eq 2)) '[P2] verified progress advanced to 2 of 3 and phase to 2' ('sat=' + [string]$liveG2['progress']['satisfied'] + ' total=' + [string]$liveG2['progress']['total'] + ' phase=' + [string]$liveG2['plan_progress']['phase'])

    $r3 = Invoke-F3FullPhase -Subject $s -Phase 3 -Counter $counter
    Assert-F3 ([bool]$r3.walk.ok) '[P3] phase3 walks after the phase2 barrier opened' ([string]$r3.walk.reason)
    Assert-F3 (($null -eq $r3.advance) -and ($null -eq $r3.attach_next)) '[P3] the last phase opens no next phase' ''
    Assert-F3 (([int]$counter.executions -eq 3)) '[P3] exactly three simulated executions across the objective' ([string]$counter.executions)
    $liveT3 = Get-OrchestrationTask -TaskId 'f3-p3' -TasksDir ([string]$e.tasks_dir)
    Assert-F3 (([string]$liveT3['state'] -ceq 'DONE')) '[P3] phase3 task is DONE in the TaskKernel' ([string]$liveT3['state'])

    foreach ($n in 1..3) {
        $pth = ([string]$s.tasks[$n].artifact)
        $txt = [IO.File]::ReadAllText($pth, [Text.Encoding]::UTF8)
        $exp = Get-F3ExpectedArtifactContent -GoalId $goalId -TaskId ([string]$s.tasks[$n].task_id) -PhaseIndex $n
        Assert-F3 (($txt -ceq $exp)) ('[P' + [string]$n + '] phase artifact carries the deterministic content') ([string]$txt)
    }

    # ================= [PROG] invalid artifact: no verification, no progress =================
    $sP = New-F3Subject -Label 'badart' -GoalId 'f3-goal-badart' -Phases 1
    Assert-F3 ([string]::IsNullOrWhiteSpace([string]$sP.error)) '[PROG] invalid-artifact subject ready' ([string]$sP.error)
    $eP = $sP.env
    $gidP = [string]$sP.goal.goal_id
    $genP = [long]$sP.goal.gen
    $authP = $sP.goal.auth
    $tdP = $sP.tasks[1]
    $ctrP = @{ executions = 0 }
    $null = Add-F3TaskToGoal -Environment $eP -GoalId $gidP -TaskId 'f3-p1' -Gen $genP
    $liveP = Get-F3LiveGoal -Environment $eP -GoalId $gidP
    $intentP = (New-F3DispatchIntent -GoalId $gidP -TaskId 'f3-p1' -TaskExpectedRevision ([long]$tdP.revision) -Gen $genP -Scope ([string]$tdP.scope) -PhaseIndex 1).data.intent
    $walkP = Invoke-F3ReceiptWalk -Environment $eP -Goal $liveP -Authorization $authP -Intent $intentP `
        -TaskId 'f3-p1' -ArtifactPath ([string]$tdP.artifact) -PhaseIndex 1 -Counter $ctrP `
        -CallId 'call_badart' -MessageId 'msg_badart' -ChildSessionId 'ses_badart_child'
    Assert-F3 ([bool]$walkP.ok) '[PROG] the attempt settles (settlement is not the verifier)' ([string]$walkP.reason)
    [IO.File]::WriteAllText(([string]$tdP.artifact), "tampered-content`n", [Text.UTF8Encoding]::new($false))
    $expP = Get-F3ExpectedArtifactContent -GoalId $gidP -TaskId 'f3-p1' -PhaseIndex 1
    $tsP = Invoke-F3TaskSettlement -Environment $eP -TaskId 'f3-p1' -ArtifactPath ([string]$tdP.artifact) `
        -PhaseIndex 1 -ExpectedContent $expP
    Assert-F3 ((-not [bool]$tsP.ok)) '[PROG] verification of a tampered artifact fails (real file read-back)' ([string]$tsP.reason)
    $ctP = Complete-F3GoalTask -Environment $eP -GoalId $gidP -TaskId 'f3-p1' -Gen $genP -PhaseIndex 1 -Walk $walkP -Settlement $tsP
    Assert-F3 ((-not [bool]$ctP.ok)) '[PROG] goal progress on an unverified task is refused' ([string]$ctP.reason)
    $lgP = Get-F3LiveGoal -Environment $eP -GoalId $gidP
    Assert-F3 (([long]$lgP['progress']['satisfied'] -eq 0) -and ([long]$lgP['progress']['total'] -eq 3)) '[PROG] an invalid artifact leaves progress at 0 of 3' ('sat=' + [string]$lgP['progress']['satisfied'] + ' total=' + [string]$lgP['progress']['total'])
    $liveTP = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir ([string]$eP.tasks_dir)
    Assert-F3 (([string]$liveTP['state'] -cne 'DONE')) '[PROG] the tampered task never reaches DONE' ([string]$liveTP['state'])
    Remove-F3Environment -Environment $eP

    # ================= [OBJ] TASK_DONE / PHASE_DONE != OBJECTIVE_DONE =================
    $liveG3 = Get-F3LiveGoal -Environment $e -GoalId $goalId
    $revBeforeAnyCas = [long]$liveG3['revision']
    Assert-F3 (([string]$liveG3['state'] -ceq 'ACTIVE')) '[OBJ] three TASK_DONEs never complete the objective' ([string]$liveG3['state'])
    $mv3 = Get-F3NextMove -Environment $e -GoalId $goalId
    Assert-F3 (([string]$mv3.data.move -cne 'COMPLETE') -and ([string]$mv3.data.stop_reason -cne 'OBJECTIVE_COMPLETED')) '[OBJ] the read-only controller cannot announce OBJECTIVE_COMPLETED' ('move=' + [string]$mv3.data.move + ' stop=' + [string]$mv3.data.stop_reason)

    # in-memory transition is NOT a completion: the store must stay ACTIVE
    $inMemory = Set-OrchestrationGoalState -Goal $liveG3 -ToState 'COMPLETED'
    Assert-F3 (([string]$inMemory.goal['state'] -ceq 'COMPLETED')) '[OBJ] an in-memory transition produces a COMPLETED record' ''
    $afterInMemory = Get-F3LiveGoal -Environment $e -GoalId $goalId
    Assert-F3 (([string]$afterInMemory['state'] -ceq 'ACTIVE') -and ([long]$afterInMemory['revision'] -eq $revBeforeAnyCas)) '[OBJ] the in-memory transition persists nothing (no CAS, no completion)' ('state=' + [string]$afterInMemory['state'])

    # CAS without the expected revision is refused (no compare-and-swap bypass)
    $staleCas = Set-OrchestrationGoalStatePersisted -GoalId $goalId -ToState 'COMPLETED' `
        -ExpectedRevision ($revBeforeAnyCas - 1) -StoreDir ([string]$e.goal_dir) -OwnerId 'planner-1' -OwnershipGeneration $gen
    Assert-F3 ((-not [bool]$staleCas.ok) -and ([string]$staleCas.reason -ceq 'revision-conflict')) '[OBJ] a CAS with a stale expected revision is refused' ([string]$staleCas.reason)

    # CAS without ownership fencing is refused
    $noFenceCas = Set-OrchestrationGoalStatePersisted -GoalId $goalId -ToState 'COMPLETED' `
        -ExpectedRevision $revBeforeAnyCas -StoreDir ([string]$e.goal_dir) -OwnerId 'planner-1' -OwnershipGeneration ($gen + 5)
    Assert-F3 ((-not [bool]$noFenceCas.ok)) '[OBJ] a CAS without the live fencing token is refused' ([string]$noFenceCas.reason)
    $afterRefused = Get-F3LiveGoal -Environment $e -GoalId $goalId
    Assert-F3 (([string]$afterRefused['state'] -ceq 'ACTIVE') -and ([long]$afterRefused['revision'] -eq $revBeforeAnyCas)) '[OBJ] the refused CAS attempts left the store untouched' ('state=' + [string]$afterRefused['state'])

    # the gate: progress verified, then the authorized CAS completes it
    $gate3 = Test-ObjectiveCompletionAllowed -Goal $afterRefused
    Assert-F3 ([bool]$gate3.allowed) '[OBJ] the completion gate opens only with all criteria verified' ([string]$gate3.reason)
    $cas3 = Invoke-F3ObjectiveCasComplete -Environment $e -GoalId $goalId -Gen $gen
    Assert-F3 ([bool]$cas3.ok) '[OBJ] the objective completes through the GoalKernel CAS' ([string]$cas3.reason)
    $afterCas = Get-F3LiveGoal -Environment $e -GoalId $goalId
    Assert-F3 (([string]$afterCas['state'] -ceq 'COMPLETED') -and ([long]$afterCas['revision'] -eq ($revBeforeAnyCas + 1))) '[OBJ] the store shows COMPLETED with revision+1 from the CAS' ('state=' + [string]$afterCas['state'])
    $mvFinal = Get-F3NextMove -Environment $e -GoalId $goalId
    Assert-F3 (([string]$mvFinal.data.move -ceq 'COMPLETE') -and ([string]$mvFinal.data.stop_reason -ceq 'OBJECTIVE_COMPLETED')) '[OBJ] only after the CAS does the controller report OBJECTIVE_COMPLETED' ('stop=' + [string]$mvFinal.data.stop_reason)
    $casAgain = Invoke-F3ObjectiveCasComplete -Environment $e -GoalId $goalId -Gen $gen
    Assert-F3 ((-not [bool]$casAgain.ok)) '[OBJ] a second completion attempt on a terminal objective is refused' ([string]$casAgain.reason)

    Remove-F3Environment -Environment $e

    # ================= [N2] failure after execution before ack =================
    $s2 = New-F3Subject -Label 'n2' -GoalId 'f3-goal-n2' -Phases 1
    $e2 = $s2.env
    $gid2 = [string]$s2.goal.goal_id
    $gen2 = [long]$s2.goal.gen
    $auth2 = $s2.goal.auth
    $td2 = $s2.tasks[1]
    $null = Add-F3TaskToGoal -Environment $e2 -GoalId $gid2 -TaskId 'f3-p1' -Gen $gen2
    $live2 = Get-F3LiveGoal -Environment $e2 -GoalId $gid2
    $intent2 = (New-F3DispatchIntent -GoalId $gid2 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$td2.revision) -Gen $gen2 -Scope ([string]$td2.scope) -PhaseIndex 1).data.intent
    $ctr2 = @{ executions = 0 }
    $crash = Invoke-F3ReceiptWalk -Environment $e2 -Goal $live2 -Authorization $auth2 -Intent $intent2 `
        -TaskId 'f3-p1' -ArtifactPath ([string]$td2.artifact) -PhaseIndex 1 -Counter $ctr2 `
        -CallId 'call_n2' -MessageId 'msg_n2' -ChildSessionId 'ses_n2_child' -SkipSettle
    Assert-F3 (([string]$crash.reason -ceq 'ack-withheld') -and ([int]$ctr2.executions -eq 1)) '[N2] the effect ran once and the acknowledgement was withheld' ([string]$crash.reason)
    $rc2 = Get-F3ReceiptRaw -Environment $e2 -GoalId $gid2 -Key ([string]$crash.data.key)
    Assert-F3 (([string]$rc2.phase -ceq 'claimed') -and ([string]$rc2.handoff_state -ceq 'DISPATCH_UNCERTAIN')) '[N2] the receipt stays claimed/DISPATCH_UNCERTAIN (ambiguous, not settled)' ('phase=' + [string]$rc2.phase + ' handoff=' + [string]$rc2.handoff_state)
    $sha2 = (Get-FileHash -LiteralPath ([string]$td2.artifact) -Algorithm SHA256).Hash

    $replaySame = Invoke-OrchestrationNativeDispatchPrepare -Intent $intent2 -Authorization $auth2 -SessionId 'ses_f3_parent' `
        -ReceiptDir ([string]$e2.receipt_dir) -GoalStoreDir ([string]$e2.goal_dir) -TasksDir ([string]$e2.tasks_dir) -FlagsPath ([string]$e2.flags)
    Assert-F3 ((-not [bool]$replaySame.ok) -and ([string]$replaySame.reason -ceq 'prepare-already-claimed') -and ([int]$replaySame.executor_calls -eq 0)) '[N2] the ambiguous claim is never re-prepared automatically' ([string]$replaySame.reason)

    # PREPARE is documented as NOT an effect (only CLAIM crosses the boundary),
    # so an extra key may prepare; the exclusion of a SECOND EFFECT lives at
    # CLAIM. Asserting both keeps the fact and the boundary apart.
    $replayExt = (New-F3DispatchIntent -GoalId $gid2 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$td2.revision) -Gen $gen2 -Scope ([string]$td2.scope) -PhaseIndex 1 -ExternalIdempotent -ExternalIdempotencyProof 'fixture-external-idempotent').data.intent
    $replayExtPrep = Invoke-OrchestrationNativeDispatchPrepare -Intent $replayExt -Authorization $auth2 -SessionId 'ses_f3_parent' `
        -ReceiptDir ([string]$e2.receipt_dir) -GoalStoreDir ([string]$e2.goal_dir) -TasksDir ([string]$e2.tasks_dir) -FlagsPath ([string]$e2.flags)
    Assert-F3 (([bool]$replayExtPrep.ok) -and ([int]$replayExtPrep.executor_calls -eq 0)) '[N2] an upgraded idempotency key may prepare (PREPARE creates no effect)' ('reason=' + [string]$replayExtPrep.reason)
    $claimExt2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey (Get-F3PreparedKey -Prepare $replayExtPrep) -Authorization $auth2 `
        -SessionId 'ses_f3_parent' -MessageId 'msg_n2_ext' -CallId 'call_n2_ext' -CallerAgent 'planner' -TargetAgent 'coder' `
        -PreparedFingerprint ([string]$replayExtPrep.prepared_fingerprint) -ReceiptDir ([string]$e2.receipt_dir) `
        -GoalStoreDir ([string]$e2.goal_dir) -TasksDir ([string]$e2.tasks_dir) -FlagsPath ([string]$e2.flags)
    Assert-F3 ((-not [bool]$claimExt2.ok) -and ([string]$claimExt2.reason -ceq 'claim-task-already-claimed')) '[N2] an upgraded idempotency key cannot claim a second effect on the unresolved task' ([string]$claimExt2.reason)

    $otherKey = (New-F3DispatchIntent -GoalId $gid2 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$td2.revision) -Gen $gen2 -Scope ([string]$td2.scope) -PhaseIndex 7).data.intent
    $otherPrep = Invoke-OrchestrationNativeDispatchPrepare -Intent $otherKey -Authorization $auth2 -SessionId 'ses_f3_parent' `
        -ReceiptDir ([string]$e2.receipt_dir) -GoalStoreDir ([string]$e2.goal_dir) -TasksDir ([string]$e2.tasks_dir) -FlagsPath ([string]$e2.flags)
    $otherClaim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey (Get-F3PreparedKey -Prepare $otherPrep) -Authorization $auth2 `
        -SessionId 'ses_f3_parent' -MessageId 'msg_n2_other' -CallId 'call_n2_other' -CallerAgent 'planner' -TargetAgent 'coder' `
        -PreparedFingerprint ([string]$otherPrep.prepared_fingerprint) -ReceiptDir ([string]$e2.receipt_dir) `
        -GoalStoreDir ([string]$e2.goal_dir) -TasksDir ([string]$e2.tasks_dir) -FlagsPath ([string]$e2.flags)
    Assert-F3 ((-not [bool]$otherClaim.ok) -and ([string]$otherClaim.reason -ceq 'claim-task-already-claimed')) '[N2] a second key on the same task is refused at the effect boundary' ([string]$otherClaim.reason)
    Assert-F3 (([int]$otherClaim.executor_calls -eq 0)) '[N2] the refused claim has zero effects' ([string]$otherClaim.executor_calls)
    Assert-F3 (([int]$counter.executions -eq 3)) '[N2] the unresolved claim did not produce a second effect on the main subject' ([string]$counter.executions)
    Assert-F3 (([int]$ctr2.executions -eq 1)) '[N2] the scenario counter proves exactly one effect across every refused replay (no second execution)' ([string]$ctr2.executions)
    Assert-F3 (((Get-FileHash -LiteralPath ([string]$td2.artifact) -Algorithm SHA256).Hash -ceq $sha2)) '[N2] the artifact bytes are unchanged after every refused replay (secondary check; the counter above is the no-second-effect proof)' ''

    $wrongLineage = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey ([string]$crash.data.key) -Authorization $auth2 `
        -ChildSessionId 'ses_n2_child' -SessionId 'ses_f3_parent' -MessageId 'msg_n2' -CallId 'call_never_made' `
        -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$crash.data.prepared_fingerprint) `
        -Reference ([string]$crash.data.reference) -TaskId 'f3-p1' -Result @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } `
        -ReceiptDir ([string]$e2.receipt_dir) -GoalStoreDir ([string]$e2.goal_dir) -EvidenceStoreDir ([string]$e2.ev_dir) `
        -TasksDir ([string]$e2.tasks_dir) -FlagsPath ([string]$e2.flags)
    Assert-F3 ((-not [bool]$wrongLineage.ok) -and ([int]$wrongLineage.executor_calls -eq 0)) '[N2] a settlement with a divergent host call lineage is refused' ([string]$wrongLineage.reason)
    $rc2b = Get-F3ReceiptRaw -Environment $e2 -GoalId $gid2 -Key ([string]$crash.data.key)
    Assert-F3 (([string]$rc2b.phase -ceq 'claimed')) '[N2] the refused settlement left the claim unresolved' ([string]$rc2b.phase)

    $rightLineage = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey ([string]$crash.data.key) -Authorization $auth2 `
        -ChildSessionId 'ses_n2_child' -SessionId 'ses_f3_parent' -MessageId 'msg_n2' -CallId 'call_n2' `
        -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$crash.data.prepared_fingerprint) `
        -Reference ([string]$crash.data.reference) -TaskId 'f3-p1' -Result @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } `
        -ReceiptDir ([string]$e2.receipt_dir) -GoalStoreDir ([string]$e2.goal_dir) -EvidenceStoreDir ([string]$e2.ev_dir) `
        -TasksDir ([string]$e2.tasks_dir) -FlagsPath ([string]$e2.flags)
    Assert-F3 (([bool]$rightLineage.ok) -and ([bool]$rightLineage.settled)) '[N2] the exact original lineage settles the ambiguous claim' ([string]$rightLineage.reason)
    Assert-F3 (([int]$counter.executions -eq 3)) '[N2] settling the ambiguous claim re-ran no effect on the main subject' ([string]$counter.executions)
    Assert-F3 (([int]$ctr2.executions -eq 1)) '[N2] settling the ambiguous claim re-ran no effect in this scenario (counter still 1)' ([string]$ctr2.executions)
    Remove-F3Environment -Environment $e2

    # ================= [N3] retry allowed and limited =================
    # The real retry path: a worker result of `failed` is what the TaskKernel
    # counts as an attempt, and the limit is enforced as task EXHAUSTION when
    # attempts reach the budget. Both facts are asserted as read back from the
    # kernel, never simulated.
    $s3 = New-F3Subject -Label 'n3' -GoalId 'f3-goal-n3' -Phases 1 -AttemptBudget 3
    $e3 = $s3.env
    $gid3 = [string]$s3.goal.goal_id
    $gen3 = [long]$s3.goal.gen
    $auth3 = $s3.goal.auth
    $td3 = $s3.tasks[1]
    $tasksDir3 = [string]$e3.tasks_dir
    $flags3 = [string]$e3.flags
    $null = Add-F3TaskToGoal -Environment $e3 -GoalId $gid3 -TaskId 'f3-p1' -Gen $gen3
    $liveT3a = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir $tasksDir3
    $budget0 = Test-NDTaskAttemptBudget -TaskId 'f3-p1' -TasksDir $tasksDir3
    Assert-F3 (([bool]$budget0.ok) -and ([int]$budget0.attempts -le [int]$budget0.budget) -and ([int]$budget0.budget -ge 1)) '[N3] the attempt budget gate admits the first dispatch' ('attempts=' + [string]$budget0.attempts + ' budget=' + [string]$budget0.budget)
    $ctr3 = @{ executions = 0 }
    $live3 = Get-F3LiveGoal -Environment $e3 -GoalId $gid3

    # attempt 1: the worker reports failure -> one attempt is spent
    $i3a = (New-F3DispatchIntent -GoalId $gid3 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$liveT3a.revision) -Gen $gen3 -Scope ([string]$td3.scope) -PhaseIndex 1).data.intent
    $w3a = Invoke-F3ReceiptWalk -Environment $e3 -Goal $live3 -Authorization $auth3 -Intent $i3a -TaskId 'f3-p1' `
        -ArtifactPath ([string]$td3.artifact) -PhaseIndex 1 -Counter $ctr3 -CallId 'call_n3_a' -MessageId 'msg_n3_a' -ChildSessionId 'ses_n3_a' `
        -Result @{ status = 'failed'; claimed_evidence = @('criterion:0') }
    Assert-F3 ([bool]$w3a.ok) '[N3] a failed worker result settles the attempt honestly' ([string]$w3a.reason)
    $liveT3b = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir $tasksDir3
    $budget1 = Test-NDTaskAttemptBudget -TaskId 'f3-p1' -TasksDir $tasksDir3
    Assert-F3 (([int]$budget1.attempts -ge 1) -and ([bool]$budget1.ok)) '[N3] the failed attempt is counted and the budget still allows a retry' ('attempts=' + [string]$budget1.attempts + ' reason=' + [string]$budget1.reason)

    # attempt 2: still inside the budget -> admitted
    $i3b = (New-F3DispatchIntent -GoalId $gid3 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$liveT3b.revision) -Gen $gen3 -Scope ([string]$td3.scope) -PhaseIndex 2).data.intent
    $prep3b = Invoke-OrchestrationNativeDispatchPrepare -Intent $i3b -Authorization $auth3 -SessionId 'ses_f3_parent' `
        -ReceiptDir ([string]$e3.receipt_dir) -GoalStoreDir ([string]$e3.goal_dir) -TasksDir $tasksDir3 -FlagsPath $flags3
    Assert-F3 ([bool]$prep3b.ok) '[N3] a retry is admitted while the attempt budget lasts' ([string]$prep3b.reason)
    $claim3b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey (Get-F3PreparedKey -Prepare $prep3b) -Authorization $auth3 `
        -SessionId 'ses_f3_parent' -MessageId 'msg_n3_b' -CallId 'call_n3_b' -CallerAgent 'planner' -TargetAgent 'coder' `
        -PreparedFingerprint ([string]$prep3b.prepared_fingerprint) -ReceiptDir ([string]$e3.receipt_dir) `
        -GoalStoreDir ([string]$e3.goal_dir) -TasksDir $tasksDir3 -FlagsPath $flags3
    Assert-F3 ([bool]$claim3b.ok) '[N3] the retry claim commits' ([string]$claim3b.reason)
    # The effect boundary is post-CLAIM, pre-SETTLE: every accepted claim
    # runs the instrumented effect exactly once, on this scenario counter.
    $eff3b = Invoke-F3SimulatedWorkerEffect -Counter $ctr3 -ArtifactPath ([string]$td3.artifact) -TaskId 'f3-p1' `
        -PhaseIndex 2 -GoalId $gid3
    Assert-F3 ([bool]$eff3b.ok) '[N3] the admitted retry runs its effect once' ([string]$eff3b.reason)
    $settle3b = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey (Get-F3PreparedKey -Prepare $prep3b) -Authorization $auth3 `
        -ChildSessionId 'ses_n3_b' -SessionId 'ses_f3_parent' -MessageId 'msg_n3_b' -CallId 'call_n3_b' `
        -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$prep3b.prepared_fingerprint) `
        -Reference ([string]$prep3b.reference) -TaskId 'f3-p1' -Result @{ status = 'failed'; claimed_evidence = @('criterion:0') } `
        -ReceiptDir ([string]$e3.receipt_dir) -GoalStoreDir ([string]$e3.goal_dir) -EvidenceStoreDir ([string]$e3.ev_dir) `
        -TasksDir $tasksDir3 -FlagsPath $flags3
    Assert-F3 ([bool]$settle3b.ok) '[N3] the second failed attempt settles' ([string]$settle3b.reason)

    # the limit: keep failing until the kernel exhausts the task
    $exhaustedAt = 0
    $stopReason = ''
    $gateRefusal = $null
    $execsBeforeGate = [int]$ctr3.executions
    for ($k = 3; $k -le 6; $k++) {
        $cur = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir $tasksDir3
        if ([string]$cur['state'] -ceq 'EXHAUSTED') { $exhaustedAt = $k - 1; $stopReason = 'exhausted'; break }
        $ik = (New-F3DispatchIntent -GoalId $gid3 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$cur.revision) -Gen $gen3 -Scope ([string]$td3.scope) -PhaseIndex $k).data.intent
        $pk = Invoke-OrchestrationNativeDispatchPrepare -Intent $ik -Authorization $auth3 -SessionId 'ses_f3_parent' `
            -ReceiptDir ([string]$e3.receipt_dir) -GoalStoreDir ([string]$e3.goal_dir) -TasksDir $tasksDir3 -FlagsPath $flags3
        if (-not [bool]$pk.ok) { $stopReason = 'prepare:' + [string]$pk.reason; break }
        $ck = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey (Get-F3PreparedKey -Prepare $pk) -Authorization $auth3 `
            -SessionId 'ses_f3_parent' -MessageId ('msg_n3_' + [string]$k) -CallId ('call_n3_' + [string]$k) `
            -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pk.prepared_fingerprint) `
            -ReceiptDir ([string]$e3.receipt_dir) -GoalStoreDir ([string]$e3.goal_dir) -TasksDir $tasksDir3 -FlagsPath $flags3
        if (-not [bool]$ck.ok) { $stopReason = 'claim:' + [string]$ck.reason; break }
        $effK = Invoke-F3SimulatedWorkerEffect -Counter $ctr3 -ArtifactPath ([string]$td3.artifact) -TaskId 'f3-p1' `
            -PhaseIndex $k -GoalId $gid3
        if (-not [bool]$effK.ok) { $stopReason = 'effect-failed'; break }
        $sk = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey (Get-F3PreparedKey -Prepare $pk) -Authorization $auth3 `
            -ChildSessionId ('ses_n3_' + [string]$k) -SessionId 'ses_f3_parent' -MessageId ('msg_n3_' + [string]$k) -CallId ('call_n3_' + [string]$k) `
            -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pk.prepared_fingerprint) `
            -Reference ([string]$pk.reference) -TaskId 'f3-p1' -Result @{ status = 'failed'; claimed_evidence = @('criterion:0') } `
            -ReceiptDir ([string]$e3.receipt_dir) -GoalStoreDir ([string]$e3.goal_dir) -EvidenceStoreDir ([string]$e3.ev_dir) `
            -TasksDir $tasksDir3 -FlagsPath $flags3
        if (-not [bool]$sk.ok) { $stopReason = 'settle:' + [string]$sk.reason; $gateRefusal = $sk; break }
    }
    $liveT3c = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir $tasksDir3
    # The retry limit that actually binds on this path is the ATTEMPT GATE:
    # from the second failure on, the TaskKernel marks the attempt
    # debugger_required + requires_new_evidence, and the native SETTLE path
    # carries no way to re-authorize it. That is the honest limit, and it is
    # enforced kernel-side with the receipt left unresolved (no replay).
    Assert-F3 (($null -ne $gateRefusal) -and ([string]$gateRefusal.reason -like '*ATTEMPT_GATE_FAILED*')) ('[N3] a third failing attempt is refused by the attempt gate (retry limited); stopped at ' + $stopReason) ('reason=' + [string]$gateRefusal.reason)
    Assert-F3 (([string]$liveT3c['state'] -ceq 'IMPLEMENTING')) '[N3] the gated task never reaches DONE or EXHAUSTED by dispatch alone' ([string]$liveT3c['state'])
    $sub3 = Get-NDGoalReceiptDir -RootDir ([string]$e3.receipt_dir) -GoalId $gid3
    $receipts3 = @(Get-ChildItem -LiteralPath $sub3 -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $claimed3 = @($receipts3 | Where-Object { [string]$_.Name -ne 'activations.jsonl' })
    $unresolved = @($claimed3 | Where-Object { (ConvertFrom-Json ([IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8))).phase -eq 'claimed' })
    Assert-F3 (@($unresolved).Count -ge 1) '[N3] the gated attempt left a durable claimed receipt (reservation held, never silently dropped)' ([string]@($unresolved).Count)
    Assert-F3 (([int]$ctr3.executions -eq ($execsBeforeGate + 1))) '[N3] the gated key ran its post-claim effect once, then the settlement was refused (post-execution refusal: no DONE, no progress)' ([string]$ctr3.executions)
    $execsAtGateRefusal = [int]$ctr3.executions
    $prep3z = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gid3 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$liveT3c.revision) -Gen $gen3 -Scope ([string]$td3.scope) -PhaseIndex 9).data.intent `
        -Authorization $auth3 -SessionId 'ses_f3_parent' -ReceiptDir ([string]$e3.receipt_dir) `
        -GoalStoreDir ([string]$e3.goal_dir) -TasksDir $tasksDir3 -FlagsPath $flags3
    Assert-F3 ([bool]$prep3z.ok) '[N3] a fresh key may still prepare after the gate (PREPARE is not an effect)' ([string]$prep3z.reason)
    $claim3z = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey (Get-F3PreparedKey -Prepare $prep3z) -Authorization $auth3 `
        -SessionId 'ses_f3_parent' -MessageId 'msg_n3_z' -CallId 'call_n3_z' -CallerAgent 'planner' -TargetAgent 'coder' `
        -PreparedFingerprint ([string]$prep3z.prepared_fingerprint) -ReceiptDir ([string]$e3.receipt_dir) `
        -GoalStoreDir ([string]$e3.goal_dir) -TasksDir $tasksDir3 -FlagsPath $flags3
    Assert-F3 ((-not [bool]$claim3z.ok) -and ([int]$claim3z.executor_calls -eq 0)) '[N3] the unresolved attempt reserves the task: no second effect, zero executions' ([string]$claim3z.reason)
    Assert-F3 (([int]$ctr3.executions -eq $execsAtGateRefusal)) '[N3] the refused claim added zero executions (pre-effect refusal, counter untouched)' ([string]$ctr3.executions)
    $budget2 = Test-NDTaskAttemptBudget -TaskId 'f3-p1' -TasksDir $tasksDir3
    Assert-F3 (([bool]$budget2.ok) -and ([int]$budget2.attempts -le [int]$budget2.budget)) '[N3] the budget gate itself is not the limiter: the terminal task state is' ('attempts=' + [string]$budget2.attempts + ' budget=' + [string]$budget2.budget)
    $doneGated = Complete-OrchestrationTask -TaskId 'f3-p1' -Actor 'planner-1' -ExpectedRevision ([int]$liveT3c.revision) `
        -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' `
        -TasksDir $tasksDir3 -FlagsPath $flags3 -TelemetryRoot ([string]$e3.telemetry)
    Assert-F3 ((-not [bool]$doneGated.ok)) '[N3] a gated task cannot be completed as DONE' ([string]$doneGated.error)
    $lg3 = Get-F3LiveGoal -Environment $e3 -GoalId $gid3
    Assert-F3 (([string]$lg3['state'] -ceq 'ACTIVE') -and ([long]$lg3['progress']['satisfied'] -eq 0) -and ([long]$lg3['progress']['total'] -eq 3)) '[N3] a limited retry never advances verified objective progress' ('state=' + [string]$lg3['state'] + ' sat=' + [string]$lg3['progress']['satisfied'])
    Remove-F3Environment -Environment $e3

    # ================= [N4] stale lease + fencing =================
    # The fencing under test is the PROMOTION fencing (GoalKernel CAS):
    # the full task chain (walk -> settlement -> DONE + verified) completes
    # FIRST under the live lease; only then the lease lapses and a rival
    # takes over. The superseded generation must then be refused at the
    # GoalKernel with an explicit fencing reason (never a task-state
    # reason), while the live generation still promotes (positive control).
    $s4 = New-F3Subject -Label 'n4' -GoalId 'f3-goal-n4' -Phases 1
    Assert-F3 ([string]::IsNullOrWhiteSpace([string]$s4.error)) '[N4] fenced-promotion subject ready' ([string]$s4.error)
    $e4 = $s4.env
    $gid4 = [string]$s4.goal.goal_id
    $gen4 = [long]$s4.goal.gen
    $auth4 = $s4.goal.auth
    $td4 = $s4.tasks[1]
    $att4 = Add-F3TaskToGoal -Environment $e4 -GoalId $gid4 -TaskId 'f3-p1' -Gen $gen4
    Assert-F3 ([bool]$att4.ok) '[N4] the phase task attaches under the live lease' ([string]$att4.reason)
    $live4 = Get-F3LiveGoal -Environment $e4 -GoalId $gid4
    $ctr4 = @{ executions = 0 }
    $intent4 = (New-F3DispatchIntent -GoalId $gid4 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$td4.revision) -Gen $gen4 -Scope ([string]$td4.scope) -PhaseIndex 1).data.intent
    $walk4 = Invoke-F3ReceiptWalk -Environment $e4 -Goal $live4 -Authorization $auth4 -Intent $intent4 `
        -TaskId 'f3-p1' -ArtifactPath ([string]$td4.artifact) -PhaseIndex 1 -Counter $ctr4 `
        -CallId 'call_n4' -MessageId 'msg_n4' -ChildSessionId 'ses_n4_child'
    Assert-F3 ([bool]$walk4.ok) '[N4] the phase settles under the live lease' ([string]$walk4.reason)
    $exp4 = Get-F3ExpectedArtifactContent -GoalId $gid4 -TaskId 'f3-p1' -PhaseIndex 1
    $ts4 = Invoke-F3TaskSettlement -Environment $e4 -TaskId 'f3-p1' -ArtifactPath ([string]$td4.artifact) `
        -PhaseIndex 1 -ExpectedContent $exp4
    Assert-F3 ([bool]$ts4.ok) '[N4] the task completes verification+review+DONE before any takeover' ([string]$ts4.reason)
    $liveT4 = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir ([string]$e4.tasks_dir)
    Assert-F3 (([string]$liveT4['state'] -ceq 'DONE')) '[N4] the task reads back DONE before the takeover' ([string]$liveT4['state'])
    # Lapse the lease without touching task state: the live holder shortens
    # its own lease, then a rival takes over on the provably expired lease.
    $short4 = Renew-OrchestrationGoalOwnership -GoalId $gid4 -OwnerId 'planner-1' -Generation $gen4 -StoreDir ([string]$e4.goal_dir) -LeaseTtlMs 1
    Assert-F3 ([bool]$short4.ok) '[N4] the live holder shortens its own lease' ([string]$short4.reason)
    Start-Sleep -Milliseconds 150
    $take = Takeover-OrchestrationGoalOwnership -GoalId $gid4 -OwnerId 'planner-2' -StoreDir ([string]$e4.goal_dir)
    Assert-F3 ([bool]$take.ok) '[N4] an expired lease is superseded by an explicit takeover' ([string]$take.reason)
    $gen4new = [long]$take.ownership['generation']
    Assert-F3 (($gen4new -eq ($gen4 + 1)) -and ([string]$take.ownership['owner_id'] -ceq 'planner-2')) '[N4] the takeover allocates predecessor+1 to the new owner' ('gen=' + [string]$gen4new)
    $base4 = Get-F3LiveGoal -Environment $e4 -GoalId $gid4
    $revBase4 = [long]$base4['revision']
    $satBase4 = [long]$base4['progress']['satisfied']
    $totBase4 = [long]$base4['progress']['total']
    # No second dispatch after DONE: refused with zero effects (terminal
    # guard; the fencing proof lives in the promotion asserts below).
    $liveT4b = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir ([string]$e4.tasks_dir)
    $prepStale = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gid4 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$liveT4b.revision) -Gen $gen4 -Scope ([string]$td4.scope) -PhaseIndex 9).data.intent `
        -Authorization $auth4 -SessionId 'ses_f3_parent' -ReceiptDir ([string]$e4.receipt_dir) `
        -GoalStoreDir ([string]$e4.goal_dir) -TasksDir ([string]$e4.tasks_dir) -FlagsPath ([string]$e4.flags)
    Assert-F3 ((-not [bool]$prepStale.ok) -and ([int]$prepStale.executor_calls -eq 0)) '[N4] no second dispatch after DONE (zero effects)' ([string]$prepStale.reason)
    # THE fencing under test: the superseded generation reaches the
    # GoalKernel (chain guards pass) and is refused with an explicit
    # fencing reason, never a task-state reason.
    $commitStale = Complete-F3GoalTask -Environment $e4 -GoalId $gid4 -TaskId 'f3-p1' -Gen $gen4 -PhaseIndex 1 -Walk $walk4 -Settlement $ts4
    Assert-F3 ((-not [bool]$commitStale.ok) -and (([string]$commitStale.reason -like '*owner-conflict*') -or ([string]$commitStale.reason -like '*owner-obsolete*')) -and ([string]$commitStale.reason -cne 'task-not-done')) '[N4] the superseded generation cannot commit goal progress (explicit fencing reason)' ([string]$commitStale.reason)
    $after4 = Get-F3LiveGoal -Environment $e4 -GoalId $gid4
    Assert-F3 (([long]$after4['progress']['satisfied'] -eq $satBase4) -and ([long]$after4['progress']['total'] -eq $totBase4) -and ([long]$after4['revision'] -eq $revBase4)) '[N4] the refused promotion writes nothing (progress and revision untouched)' ('sat=' + [string]$after4['progress']['satisfied'] + ' rev=' + [string]$after4['revision'])
    # Positive control: the live generation promotes over the same chain.
    $commitLive = Complete-F3GoalTask -Environment $e4 -GoalId $gid4 -TaskId 'f3-p1' -Gen $gen4new -OwnerId 'planner-2' -PhaseIndex 1 -Walk $walk4 -Settlement $ts4
    Assert-F3 ([bool]$commitLive.ok) '[N4] the live generation commits goal progress after the same chain' ([string]$commitLive.reason)
    $live4after = Get-F3LiveGoal -Environment $e4 -GoalId $gid4
    Assert-F3 (([long]$live4after['progress']['satisfied'] -eq ($satBase4 + 1)) -and ([long]$live4after['progress']['total'] -eq $totBase4)) '[N4] the live promotion advances verified progress (total preserved)' ('sat=' + [string]$live4after['progress']['satisfied'])
    $casStale = Set-OrchestrationGoalStatePersisted -GoalId $gid4 -ToState 'COMPLETED' `
        -ExpectedRevision ([long](Get-F3LiveGoal -Environment $e4 -GoalId $gid4)['revision']) -StoreDir ([string]$e4.goal_dir) -OwnerId 'planner-1' -OwnershipGeneration $gen4
    Assert-F3 ((-not [bool]$casStale.ok) -and (([string]$casStale.reason -like '*owner-conflict*') -or ([string]$casStale.reason -like '*owner-obsolete*'))) '[N4] the superseded generation cannot complete the objective (explicit fencing reason)' ([string]$casStale.reason)
    Remove-F3Environment -Environment $e4

    # ================= [N5] cancellation =================
    $s5 = New-F3Subject -Label 'n5' -GoalId 'f3-goal-n5' -Phases 1
    $e5 = $s5.env
    $gid5 = [string]$s5.goal.goal_id
    $gen5 = [long]$s5.goal.gen
    $auth5 = $s5.goal.auth
    $td5 = $s5.tasks[1]
    $null = Add-F3TaskToGoal -Environment $e5 -GoalId $gid5 -TaskId 'f3-p1' -Gen $gen5
    $slot5 = Get-OrchestrationGoal -GoalId $gid5 -StoreDir ([string]$e5.goal_dir)
    $cancelGoal = Set-OrchestrationGoalStatePersisted -GoalId $gid5 -ToState 'CANCELLED' `
        -ExpectedRevision ([long]$slot5.goal['revision']) -StoreDir ([string]$e5.goal_dir) -OwnerId 'planner-1' -OwnershipGeneration $gen5
    Assert-F3 ([bool]$cancelGoal.ok) '[N5] the objective cancels through the GoalKernel CAS' ([string]$cancelGoal.reason)
    $prepCancel = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gid5 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$td5.revision) -Gen $gen5 -Scope ([string]$td5.scope) -PhaseIndex 1).data.intent `
        -Authorization $auth5 -SessionId 'ses_f3_parent' -ReceiptDir ([string]$e5.receipt_dir) `
        -GoalStoreDir ([string]$e5.goal_dir) -TasksDir ([string]$e5.tasks_dir) -FlagsPath ([string]$e5.flags)
    Assert-F3 ((-not [bool]$prepCancel.ok) -and ([int]$prepCancel.executor_calls -eq 0)) '[N5] a cancelled objective refuses dispatch with zero effects' ([string]$prepCancel.reason)
    $mv5 = Get-F3NextMove -Environment $e5 -GoalId $gid5
    Assert-F3 (([string]$mv5.data.move -ceq 'COMPLETE') -and ([string]$mv5.data.stop_reason -ceq 'CANCELLED')) '[N5] the controller reports CANCELLED as the terminal stop reason' ('stop=' + [string]$mv5.data.stop_reason)
    Remove-F3Environment -Environment $e5

    $s5b = New-F3Subject -Label 'n5b' -GoalId 'f3-goal-n5b' -Phases 1
    $e5b = $s5b.env
    $gid5b = [string]$s5b.goal.goal_id
    $gen5b = [long]$s5b.goal.gen
    $auth5b = $s5b.goal.auth
    $td5b = $s5b.tasks[1]
    $null = Add-F3TaskToGoal -Environment $e5b -GoalId $gid5b -TaskId 'f3-p1' -Gen $gen5b
    $liveT5 = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir ([string]$e5b.tasks_dir)
    $cancelTask = Cancel-OrchestrationTask -TaskId 'f3-p1' -Actor 'planner-1' -ExpectedRevision ([int]$liveT5.revision) `
        -Reason 'fixture-cancellation' -ActorIdentitySource 'explicit-cli' -TasksDir ([string]$e5b.tasks_dir) -FlagsPath ([string]$e5b.flags) -TelemetryRoot ([string]$e5b.telemetry)
    Assert-F3 ([bool]$cancelTask.ok) '[N5] a phase task cancels in the TaskKernel' ([string]$cancelTask.error)
    $prepCancelTask = Invoke-OrchestrationNativeDispatchPrepare `
        -Intent (New-F3DispatchIntent -GoalId $gid5b -TaskId 'f3-p1' -TaskExpectedRevision ([long]$td5b.revision) -Gen $gen5b -Scope ([string]$td5b.scope) -PhaseIndex 1).data.intent `
        -Authorization $auth5b -SessionId 'ses_f3_parent' -ReceiptDir ([string]$e5b.receipt_dir) `
        -GoalStoreDir ([string]$e5b.goal_dir) -TasksDir ([string]$e5b.tasks_dir) -FlagsPath ([string]$e5b.flags)
    Assert-F3 ((-not [bool]$prepCancelTask.ok) -and ([string]$prepCancelTask.reason -ceq 'task-terminal')) '[N5] a cancelled task is refused as terminal at admission' ([string]$prepCancelTask.reason)
    Remove-F3Environment -Environment $e5b

    # ================= [N6] budget exhausted =================
    $s6 = New-F3Subject -Label 'n6' -GoalId 'f3-goal-n6' -Phases 1
    $e6 = $s6.env
    $gid6 = [string]$s6.goal.goal_id
    $live6 = Get-F3LiveGoal -Environment $e6 -GoalId $gid6
    $budWorker = Test-OrchestrationObjectiveBudget -Goal $live6 -Scope 'worker' -Exhausted $true
    Assert-F3 (([bool]$budWorker.ok) -and ([string]$budWorker.decision -ceq 'replan')) '[N6] an exhausted worker budget blocks further dispatch (replan, no dispatch)' ('decision=' + [string]$budWorker.decision)
    $budProceed = Test-OrchestrationObjectiveBudget -Goal $live6 -Scope 'worker'
    Assert-F3 (([bool]$budProceed.ok) -and ([string]$budProceed.decision -ceq 'proceed')) '[N6] the same budget admits work while it lasts' ('decision=' + [string]$budProceed.decision)
    $budBad = Test-OrchestrationObjectiveBudget -Goal $live6 -Scope 'escopo-inexistente'
    Assert-F3 ((-not [bool]$budBad.ok) -and ([string]$budBad.decision -ceq 'block')) '[N6] an unknown budget scope fails closed' ([string]$budBad.reason)
    Remove-F3Environment -Environment $e6

    # ================= [N7] no double execution, no false DONE =================
    $s7 = New-F3Subject -Label 'n7' -GoalId 'f3-goal-n7' -Phases 1
    $e7 = $s7.env
    $gid7 = [string]$s7.goal.goal_id
    $gen7 = [long]$s7.goal.gen
    $auth7 = $s7.goal.auth
    $td7 = $s7.tasks[1]
    $null = Add-F3TaskToGoal -Environment $e7 -GoalId $gid7 -TaskId 'f3-p1' -Gen $gen7
    $live7 = Get-F3LiveGoal -Environment $e7 -GoalId $gid7
    $ctr7 = @{ executions = 0 }
    $intent7 = (New-F3DispatchIntent -GoalId $gid7 -TaskId 'f3-p1' -TaskExpectedRevision ([long]$td7.revision) -Gen $gen7 -Scope ([string]$td7.scope) -PhaseIndex 1).data.intent
    $walk7 = Invoke-F3ReceiptWalk -Environment $e7 -Goal $live7 -Authorization $auth7 -Intent $intent7 `
        -TaskId 'f3-p1' -ArtifactPath ([string]$td7.artifact) -PhaseIndex 1 -Counter $ctr7 `
        -CallId 'call_n7' -MessageId 'msg_n7' -ChildSessionId 'ses_n7_child'
    Assert-F3 ([bool]$walk7.ok) '[N7] the phase settled once' ([string]$walk7.reason)
    $sha7 = (Get-FileHash -LiteralPath ([string]$td7.artifact) -Algorithm SHA256).Hash

    $dupClaim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey ([string]$walk7.data.key) -Authorization $auth7 `
        -SessionId 'ses_f3_parent' -MessageId 'msg_n7' -CallId 'call_n7' -CallerAgent 'planner' -TargetAgent 'coder' `
        -PreparedFingerprint ([string]$walk7.data.prepared_fingerprint) -ReceiptDir ([string]$e7.receipt_dir) `
        -GoalStoreDir ([string]$e7.goal_dir) -TasksDir ([string]$e7.tasks_dir) -FlagsPath ([string]$e7.flags)
    Assert-F3 ((-not [bool]$dupClaim.ok) -and ([int]$dupClaim.executor_calls -eq 0)) '[N7] a second claim on a settled key is refused' ([string]$dupClaim.reason)

    $dupSettle = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey ([string]$walk7.data.key) -Authorization $auth7 `
        -ChildSessionId 'ses_n7_child' -SessionId 'ses_f3_parent' -MessageId 'msg_n7' -CallId 'call_n7' `
        -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$walk7.data.prepared_fingerprint) `
        -Reference ([string]$walk7.data.reference) -TaskId 'f3-p1' -Result @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } `
        -ReceiptDir ([string]$e7.receipt_dir) -GoalStoreDir ([string]$e7.goal_dir) -EvidenceStoreDir ([string]$e7.ev_dir) `
        -TasksDir ([string]$e7.tasks_dir) -FlagsPath ([string]$e7.flags)
    Assert-F3 (([bool]$dupSettle.ok) -and ([bool]$dupSettle.duplicate) -and ([int]$dupSettle.executor_calls -eq 0)) '[N7] an identical settlement is an idempotent duplicate' ([string]$dupSettle.reason)
    Assert-F3 (([int]$ctr7.executions -eq 1)) '[N7] exactly one execution across every duplicate attempt (the counter is the no-rewrite proof)' ([string]$ctr7.executions)
    Assert-F3 (((Get-FileHash -LiteralPath ([string]$td7.artifact) -Algorithm SHA256).Hash -ceq $sha7)) '[N7] the duplicate settlement changed no artifact byte (secondary check)' ''

    $conflicting = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey ([string]$walk7.data.key) -Authorization $auth7 `
        -ChildSessionId 'ses_n7_child' -SessionId 'ses_f3_parent' -MessageId 'msg_n7' -CallId 'call_n7' `
        -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$walk7.data.prepared_fingerprint) `
        -Reference ([string]$walk7.data.reference) -TaskId 'f3-p1' -Result @{ status = 'failed'; claimed_evidence = @('criterion:0') } `
        -ReceiptDir ([string]$e7.receipt_dir) -GoalStoreDir ([string]$e7.goal_dir) -EvidenceStoreDir ([string]$e7.ev_dir) `
        -TasksDir ([string]$e7.tasks_dir) -FlagsPath ([string]$e7.flags)
    Assert-F3 ((-not [bool]$conflicting.ok) -and ([int]$conflicting.executor_calls -eq 0)) '[N7] a divergent settlement on the same claim is a conflict, never an overwrite' ([string]$conflicting.reason)

    $shape = Test-OrchestrationDispatchResultShape -Result @{ status = 'verified_pass'; claimed_evidence = @('criterion:0') }
    Assert-F3 ((-not [bool]$shape.ok) -and ([string]$shape.reason -ceq 'status-not-allowed-from-worker')) '[N7] a worker-declared verified_pass is rejected by the result shape gate' ([string]$shape.reason)
    $shapeDone = Test-OrchestrationDispatchResultShape -Result @{ status = 'done'; claimed_evidence = @('criterion:0') }
    Assert-F3 ((-not [bool]$shapeDone.ok)) '[N7] a worker-declared done is rejected by the result shape gate' ([string]$shapeDone.reason)

    # false DONE: the task can only reach DONE through the settlement chain
    $liveT7 = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir ([string]$e7.tasks_dir)
    Assert-F3 (([string]$liveT7['state'] -ceq 'IMPLEMENTING')) '[N7] a settled worker result alone leaves the task IMPLEMENTING (no false DONE)' ([string]$liveT7['state'])
    $earlyDone = Complete-OrchestrationTask -TaskId 'f3-p1' -Actor 'planner-1' -ExpectedRevision ([int]$liveT7.revision) `
        -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' `
        -TasksDir ([string]$e7.tasks_dir) -FlagsPath ([string]$e7.flags) -TelemetryRoot ([string]$e7.telemetry)
    Assert-F3 ((-not [bool]$earlyDone.ok) -and ([string]$earlyDone.error -ceq 'ILLEGAL_COMPLETION_STATE')) '[N7] completion outside REVIEWING is refused' ([string]$earlyDone.error)
    $badVerify = Set-OrchestrationTaskVerification -TaskId 'f3-p1' -VerifierEvidenceJson '{"ok":true,"no_status_here":1}' -ExpectedRevision ([int]$liveT7.revision) -TasksDir ([string]$e7.tasks_dir) -FlagsPath ([string]$e7.flags)
    Assert-F3 ((-not [bool]$badVerify.ok)) '[N7] verification without a verifier status is refused (never self-attested)' ([string]$badVerify.error)
    $lg7 = Get-F3LiveGoal -Environment $e7 -GoalId $gid7
    Assert-F3 (([string]$lg7['state'] -ceq 'ACTIVE') -and ([long]$lg7['progress']['satisfied'] -eq 0)) '[N7] the objective records no verified progress without a completed settlement' ('sat=' + [string]$lg7['progress']['satisfied'])
    $gate7 = Test-ObjectiveCompletionAllowed -Goal $lg7
    Assert-F3 ((-not [bool]$gate7.allowed)) '[N7] the completion gate stays closed while no criterion is verified' ([string]$gate7.reason)
    $cas7 = Invoke-F3ObjectiveCasComplete -Environment $e7 -GoalId $gid7 -Gen $gen7
    Assert-F3 ((-not [bool]$cas7.ok) -and ([string]$cas7.reason -like 'completion-gate:*')) '[N7] the objective cannot be completed while the progress gate is closed' ([string]$cas7.reason)
    Remove-F3Environment -Environment $e7

    # ================= [H] hygiene =================
    $libText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OrchestrationF3ThreePhaseFixture.ps1'), [Text.UTF8Encoding]::new($false))
    Assert-F3 ((($libText -notmatch 'Start-Process') -and ($libText -notmatch 'Invoke-WebRequest') -and ($libText -notmatch 'HttpClient') -and ($libText -notmatch 'while\s*\(\s*\$true'))) '[H] the fixture driver has no spawn, no network and no busy loop' ''
    foreach ($p in @((Join-Path $PSScriptRoot 'OrchestrationF3ThreePhaseFixture.ps1'), (Join-Path $PSScriptRoot 'OrchestrationF3ThreePhaseFixture.tests.ps1'))) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bad = 0
        foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
        Assert-F3 ($bad -eq 0) ('[H] ASCII-only ' + [IO.Path]::GetFileName($p)) ([string]$bad)
    }

    $thisFile = $MyInvocation.MyCommand.Path
    $thisDir = [IO.Path]::GetDirectoryName($thisFile)
    $stray = @(Get-ChildItem -LiteralPath $thisDir -File | Where-Object { $_.Name -notlike '*.ps1' })
    Assert-F3 ($stray.Count -eq 0) '[H] the fixture directory holds only PowerShell sources' (@($stray.Name) -join ',')

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Unregister-F3OwnedRoot -Root $tempRoot
}
finally {
    # Exclusive cleanup: ONLY the roots this run created (ownership
    # registry). Foreign f3-fixture-*/f3-suite-* directories from other
    # runs or checkouts are never enumerated or removed.
    try { Remove-F3OwnedEnvironments } catch { }
    if ((-not [string]::IsNullOrWhiteSpace($tempRoot)) -and (Test-Path -LiteralPath $tempRoot)) {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Write-Host ''
Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
if ($script:failed -ne 0) { exit 1 }
exit 0