[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationRuntimeAdapterContract.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveRuntime.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationProductiveActivation.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')
$passed = 0
function Assert-PAThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Write-PAFile {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n")
    $lf = ($lf -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}
function New-PARoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('pa-act01-' + [guid]::NewGuid().ToString('N'))
    $goal = Join-Path $root 'goals'
    $dispatch = Join-Path $root 'dispatch'
    $ckpt = Join-Path $root 'checkpoints'
    $tasks = Join-Path $root 'tasks'
    $tele = Join-Path $root 'telemetry'
    $flags = Join-Path $root 'flags.json'
    New-Item -ItemType Directory -Path $goal -Force | Out-Null
    New-Item -ItemType Directory -Path $dispatch -Force | Out-Null
    New-Item -ItemType Directory -Path $ckpt -Force | Out-Null
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    New-Item -ItemType Directory -Path $tele -Force | Out-Null
    Write-PAFile -Path $flags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    return @{ root = $root; goal = $goal; dispatch = $dispatch; ckpt = $ckpt; tasks = $tasks; tele = $tele; flags = $flags }
}
function New-PAActiveGoal {
    param([string]$Id, [string]$GoalDir)
    $n = New-OrchestrationGoal -GoalId $Id -Objective 'productive activation' -Criteria @('c1', 'c2') -VerificationSurfaces @('suite-x') -SoftCap 10 -HardCap 20 -TotalPhases 2
    if (-not [bool]$n.ok) { throw "FAIL: setup new goal $Id" }
    $act = Set-OrchestrationGoalState -Goal $n.goal -ToState 'ACTIVE'
    if (-not [bool]$act.ok) { throw "FAIL: setup activate $Id" }
    $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $GoalDir
    if (-not [bool]$sv.ok) { throw "FAIL: setup save $Id" }
    return $sv
}
function New-PAImplementingTask {
    param([string]$Id, [string]$TasksDir, [string]$FlagsPath, [string]$TeleDir)
    $t = New-OrchestrationTask -TaskId $Id -Objective 'productive fixture work' -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TeleDir
    if (-not [bool]$t.ok) { throw ("FAIL: setup new task " + $Id + " " + [string]$t.error) }
    $r1 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision ([int]$t.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TeleDir
    if (-not [bool]$r1.ok) { throw ("FAIL: setup task planning " + $Id + " " + [string]$r1.error) }
    $r2 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision ([int]$r1.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TeleDir
    if (-not [bool]$r2.ok) { throw ("FAIL: setup task implementing " + $Id + " " + [string]$r2.error) }
    return $r2
}
function Get-PATaskRev {
    param([string]$Id, [string]$TasksDir)
    try {
        $rec = Get-OrchestrationTask -TaskId $Id -TasksDir $TasksDir
        if (($null -eq $rec) -or (-not ($rec -is [System.Collections.IDictionary]))) { return -1 }
        if (-not $rec.Contains('revision')) { return -1 }
        return ([int]$rec['revision'])
    }
    catch { return -1 }
}
function Test-PAWorkerResult {
    param([string]$Id, [string]$TasksDir)
    try {
        $rec = Get-OrchestrationTask -TaskId $Id -TasksDir $TasksDir
        if (($null -eq $rec) -or (-not ($rec -is [System.Collections.IDictionary]))) { return $false }
        if (-not $rec.Contains('worker_result')) { return $false }
        return ($null -ne $rec['worker_result'])
    }
    catch { return $false }
}
$script:GFull = 'ops allow:dispatch allow:settlement allow:checkpoint allow:advance allow:terminalize allow:reconcile'
$v = Get-ProductiveActivationVersion
Assert-PAThat (([long]$v.schema_version -eq 1) -and ([string]$v.phase -ceq 'ACT-01')) 'VERSION schema 1 phase ACT-01'
# --- Gate constructors refuse without -Productive (no impl, never invoked).
$g0 = New-ProductiveDispatchImpl -TaskId 'pa-task-x' -OwnerId 'owner-pa-1' -Generation 1
Assert-PAThat ((($null -eq $g0) -or (-not [bool]$g0.ok)) -and ($null -eq $g0.impl)) 'GATE dispatch ctor without -Productive returns no impl'
$s0 = New-ProductiveSettleImpl -TaskId 'pa-task-x' -OwnerId 'owner-pa-1' -Generation 1
Assert-PAThat ((($null -eq $s0) -or (-not [bool]$s0.ok)) -and ($null -eq $s0.impl)) 'GATE settle ctor without -Productive returns no impl'
$c0 = New-ProductiveReconcileImpl
Assert-PAThat ((($null -eq $c0) -or (-not [bool]$c0.ok)) -and ($null -eq $c0.impl)) 'GATE reconcile ctor without -Productive returns no impl'
$k0 = New-ProductiveCheckpointImpl -CheckpointStoreDir 'X'
Assert-PAThat ((($null -eq $k0) -or (-not [bool]$k0.ok)) -and ($null -eq $k0.impl)) 'GATE checkpoint ctor without -Productive returns no impl'
# --- E2E productive: dispatch -> receipt -> settle -> checkpoint -> next_move.
$rt = New-PARoot
$svT = New-PAActiveGoal 'PA-E2E-1' $rt.goal
$ownT = Acquire-OrchestrationGoalOwnership -GoalId 'PA-E2E-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svT.revision) -StoreDir $rt.goal
Assert-PAThat ([bool]$ownT.ok) 'E2E goal ownership acquired gen 1'
$revT = [long]$ownT.revision
$tkT = New-PAImplementingTask 'pa-task-e2e-1' $rt.tasks $rt.flags $rt.tele
$trk = New-PATracker $null
$keyT = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-E2E-1' -WorkItemId 'w-pa-e2e-1' -ActionRevision 1
$evT = (New-OrchestrationObjectiveEvent -GoalId 'PA-E2E-1' -Type 'task-settled' -WorkItemId 'w-pa-e2e-1' -ActionRevision 1).event
$resT = Invoke-ProductiveObjectiveEvent -Event $evT -GoalStoreDir $rt.goal -DispatchStoreDir $rt.dispatch -CheckpointStoreDir $rt.ckpt -TasksDir $rt.tasks -FlagsPath $rt.flags -TelemetryRoot $rt.tele -TaskId 'pa-task-e2e-1' -AttemptRole 'coder' -SessionId 'pa-session-e2e' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revT -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -Tracker $trk -Productive
Assert-PAThat (([bool]$resT.ok -and [bool]$resT.dispatched) -and ([string]$resT.decision -ceq 'settlement-pending')) 'E2E productive dispatches; settle HOLDS without native context'
Assert-PAThat (([string]$resT.intent_state -ceq 'pending') -and ([string]$resT.settlement -ceq 'pending-reconciliation') -and ($null -ne $resT.receipt) -and ([string]$resT.receipt.idempotency_key -ceq $keyT)) 'E2E intent pending with dispatch receipt bound to key (0 settle)'
Assert-PAThat (([string]$resT.receipt.destination -ceq 'task-kernel') -and ([string]$resT.receipt.action -ceq 'start-attempt') -and ([string]$resT.receipt.task_id -ceq 'pa-task-e2e-1') -and (-not [string]::IsNullOrWhiteSpace([string]$resT.receipt.run_id)) -and ([long]$resT.receipt.generation -eq 1) -and (-not [string]::IsNullOrWhiteSpace([string]$resT.receipt.result))) 'E2E receipt carries destination action task run generation result'
Assert-PAThat (([long]$resT.productive_dispatch_calls -eq 1) -and ([long]$resT.productive_settle_calls -eq 1)) 'E2E one dispatch one settle-HOLD recorded'
Assert-PAThat (([string]$resT.productive -ceq 'engaged') -and (-not [bool]$resT.grants_authority) -and (-not [bool]$resT.done_approved) -and (-not [bool]$resT.verified_pass)) 'E2E engaged claims no grants DONE or verified pass'
Assert-PAThat (((Get-PATaskRev 'pa-task-e2e-1' $rt.tasks) -eq 4) -and (-not (Test-PAWorkerResult 'pa-task-e2e-1' $rt.tasks))) 'E2E exactly one kernel start, zero settle writes (rev 3 to 4)'
# --- Duplicate same key => original receipt, no new effect.
$resD = Invoke-ProductiveObjectiveEvent -Event $evT -GoalStoreDir $rt.goal -DispatchStoreDir $rt.dispatch -CheckpointStoreDir $rt.ckpt -TasksDir $rt.tasks -FlagsPath $rt.flags -TelemetryRoot $rt.tele -TaskId 'pa-task-e2e-1' -AttemptRole 'coder' -SessionId 'pa-session-e2e' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revT -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Tracker $trk -Productive
Assert-PAThat ([bool]$resD.ok -and [bool]$resD.duplicate) 'DUP same key returns duplicate'
Assert-PAThat ((([long]$resD.productive_dispatch_calls -eq 1) -and ([long]$resD.productive_settle_calls -eq 1)) -and ((Get-PATaskRev 'pa-task-e2e-1' $rt.tasks) -eq 4)) 'DUP no new kernel effect'
# --- Crash: settlement denied => pending; reconcile recovers without re-effect.
$rc = New-PARoot
$svC = New-PAActiveGoal 'PA-CRASH-1' $rc.goal
$ownC = Acquire-OrchestrationGoalOwnership -GoalId 'PA-CRASH-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svC.revision) -StoreDir $rc.goal
Assert-PAThat ([bool]$ownC.ok) 'CRASH goal ownership acquired'
$revC = [long]$ownC.revision
$tkC = New-PAImplementingTask 'pa-task-crash-1' $rc.tasks $rc.flags $rc.tele
$trkC = New-PATracker $null
$evC = (New-OrchestrationObjectiveEvent -GoalId 'PA-CRASH-1' -Type 'task-settled' -WorkItemId 'w-pa-crash-1' -ActionRevision 1).event
$resC = Invoke-ProductiveObjectiveEvent -Event $evC -GoalStoreDir $rc.goal -DispatchStoreDir $rc.dispatch -CheckpointStoreDir $rc.ckpt -TasksDir $rc.tasks -FlagsPath $rc.flags -TelemetryRoot $rc.tele -TaskId 'pa-task-crash-1' -AttemptRole 'coder' -SessionId 'pa-session-crash' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revC -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Tracker $trkC -Productive
Assert-PAThat (([bool]$resC.ok -and [bool]$resC.dispatched) -and ([string]$resC.decision -ceq 'settlement-pending')) 'CRASH dispatch without settlement stays pending (crash shape)'
Assert-PAThat ((([long]$resC.productive_dispatch_calls -eq 1) -and ([long]$resC.productive_settle_calls -eq 0)) -and ((Get-PATaskRev 'pa-task-crash-1' $rc.tasks) -eq 4)) 'CRASH one dispatch zero settles (rev 3 to 4)'
$keyC = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-CRASH-1' -WorkItemId 'w-pa-crash-1' -ActionRevision 1
$sProofC = @{ destination = 'task-kernel'; action = 'worker-result'; fencing_owner = 'owner-pa-1'; fencing_generation = [long]1; idempotency_key = $keyC }
$trkR = New-PATracker $null
$resR = Invoke-ProductiveObjectiveReconcile -GoalId 'PA-CRASH-1' -GoalStoreDir $rc.goal -DispatchStoreDir $rc.dispatch -TasksDir $rc.tasks -FlagsPath $rc.flags -TelemetryRoot $rc.tele -TaskId 'pa-task-crash-1' -SessionId 'pa-session-crash' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revC -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -Tracker $trkR -SettleProof $sProofC -Productive
Assert-PAThat (([bool]$resR.ok -and ([long]$resR.reconciled -eq 1)) -and ([long]$resR.settled -eq 0)) 'CRASH reconcile observes dispatch; settle HOLDS without native context'
Assert-PAThat ((([long]$resR.productive_reconcile_calls -eq 1) -and ([long]$resR.productive_settle_calls -eq 1)) -and ((Get-PATaskRev 'pa-task-crash-1' $rc.tasks) -eq 4)) 'CRASH recovery observes only, no settle write (rev stays 4)'
$afterC = Get-OrchestrationDispatchIntent -GoalId 'PA-CRASH-1' -WorkItemId 'w-pa-crash-1' -ActionRevision 1 -StoreDir $rc.dispatch
Assert-PAThat (([bool]$afterC.ok -and ([string]$afterC.intent['state'] -cne 'settled')) -and ([string]$afterC.intent['receipt'].idempotency_key -ceq $keyC)) 'CRASH intent pending with original dispatch receipt'
$trkR2 = New-PATracker $null
$resR2 = Invoke-ProductiveObjectiveReconcile -GoalId 'PA-CRASH-1' -GoalStoreDir $rc.goal -DispatchStoreDir $rc.dispatch -TasksDir $rc.tasks -FlagsPath $rc.flags -TelemetryRoot $rc.tele -TaskId 'pa-task-crash-1' -SessionId 'pa-session-crash' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revC -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Tracker $trkR2 -SettleProof $sProofC -Productive
Assert-PAThat (([bool]$resR2.ok -and ([long]$resR2.reconciled -eq 1)) -and ([long]$resR2.settled -eq 0)) 'CRASH second recovery still observes with no settle write'
Assert-PAThat ((Get-PATaskRev 'pa-task-crash-1' $rc.tasks) -eq 4) 'CRASH second recovery leaves task rev 4'
# --- Without -Productive => HOLD, zero invocations, current path intact.
$rh = New-PARoot
$svH = New-PAActiveGoal 'PA-HOLD-1' $rh.goal
$tkH = New-PAImplementingTask 'pa-task-hold-1' $rh.tasks $rh.flags $rh.tele
$trkH = New-PATracker $null
$evH = (New-OrchestrationObjectiveEvent -GoalId 'PA-HOLD-1' -Type 'task-settled' -WorkItemId 'w-pa-hold-1' -ActionRevision 1).event
$resH = Invoke-ProductiveObjectiveEvent -Event $evH -GoalStoreDir $rh.goal -DispatchStoreDir $rh.dispatch -CheckpointStoreDir $rh.ckpt -TasksDir $rh.tasks -FlagsPath $rh.flags -TelemetryRoot $rh.tele -TaskId 'pa-task-hold-1' -AttemptRole 'coder' -SessionId 'pa-session-hold' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision ([long]$svH.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Tracker $trkH
Assert-PAThat ((([long]$resH.productive_dispatch_calls -eq 0) -and ([long]$resH.productive_settle_calls -eq 0)) -and (([long]$resH.productive_checkpoint_calls -eq 0) -and ([long]$resH.productive_reconcile_calls -eq 0))) 'HOLD zero impl invocations without -Productive'
Assert-PAThat (([string]$resH.productive).StartsWith('hold-productive-disabled')) 'HOLD mode reported'
Assert-PAThat ((Get-PATaskRev 'pa-task-hold-1' $rh.tasks) -eq 3) 'HOLD zero kernel effects (rev stays 3)'
# --- Denied envelope with -Productive => HOLD, zero effects.
$rd = New-PARoot
$svD = New-PAActiveGoal 'PA-DENY-1' $rd.goal
$ownD = Acquire-OrchestrationGoalOwnership -GoalId 'PA-DENY-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svD.revision) -StoreDir $rd.goal
Assert-PAThat ([bool]$ownD.ok) 'DENY goal ownership acquired'
$tkD = New-PAImplementingTask 'pa-task-deny-1' $rd.tasks $rd.flags $rd.tele
$trkD = New-PATracker $null
$evD = (New-OrchestrationObjectiveEvent -GoalId 'PA-DENY-1' -Type 'task-settled' -WorkItemId 'w-pa-deny-1' -ActionRevision 1).event
$resDenied = Invoke-ProductiveObjectiveEvent -Event $evD -GoalStoreDir $rd.goal -DispatchStoreDir $rd.dispatch -CheckpointStoreDir $rd.ckpt -TasksDir $rd.tasks -FlagsPath $rd.flags -TelemetryRoot $rd.tele -TaskId 'pa-task-deny-1' -AttemptRole 'coder' -SessionId 'pa-session-deny' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision ([long]$ownD.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops' -Tracker $trkD -Productive
Assert-PAThat ((([long]$resDenied.productive_dispatch_calls -eq 0) -and ([long]$resDenied.productive_settle_calls -eq 0)) -and ((Get-PATaskRev 'pa-task-deny-1' $rd.tasks) -eq 3)) 'DENY zero effects on denied envelope (rev stays 3)'
# --- Terminal goal with -Productive => no dispatch.
$rterm = New-PARoot
$svX = New-PAActiveGoal 'PA-TERM-1' $rterm.goal
$ownX = Acquire-OrchestrationGoalOwnership -GoalId 'PA-TERM-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svX.revision) -StoreDir $rterm.goal
Assert-PAThat ([bool]$ownX.ok) 'TERM goal ownership acquired'
$finX = Set-OrchestrationGoalStatePersisted -GoalId 'PA-TERM-1' -ToState 'COMPLETED' -ExpectedRevision ([long]$ownX.revision) -StoreDir $rterm.goal -OwnerId 'owner-pa-1' -OwnershipGeneration 1
Assert-PAThat ([bool]$finX.ok) 'TERM goal completed persisted'
$tkX = New-PAImplementingTask 'pa-task-term-1' $rterm.tasks $rterm.flags $rterm.tele
$trkX = New-PATracker $null
$evX = (New-OrchestrationObjectiveEvent -GoalId 'PA-TERM-1' -Type 'task-settled' -WorkItemId 'w-pa-term-1' -ActionRevision 1).event
$resX = Invoke-ProductiveObjectiveEvent -Event $evX -GoalStoreDir $rterm.goal -DispatchStoreDir $rterm.dispatch -CheckpointStoreDir $rterm.ckpt -TasksDir $rterm.tasks -FlagsPath $rterm.flags -TelemetryRoot $rterm.tele -TaskId 'pa-task-term-1' -AttemptRole 'coder' -SessionId 'pa-session-term' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision ([long]$finX.goal['revision']) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Tracker $trkX -Productive
Assert-PAThat ((([long]$resX.productive_dispatch_calls -eq 0) -and (-not [bool]$resX.dispatched)) -and ((Get-PATaskRev 'pa-task-term-1' $rterm.tasks) -eq 3)) 'TERM terminal goal never dispatches (rev stays 3)'
# --- NEG-EXP: expired ownership denies INSIDE the dispatch callback (gate-to-callback loss).
$rn1 = New-PARoot
$svN1 = New-PAActiveGoal 'PA-NEG-EXP' $rn1.goal
$ownN1 = Acquire-OrchestrationGoalOwnership -GoalId 'PA-NEG-EXP' -OwnerId 'owner-neg-1' -ExpectedRevision ([long]$svN1.revision) -StoreDir $rn1.goal -LeaseTtlMs 1
Assert-PAThat ([bool]$ownN1.ok) 'NEG expired ownership acquired with short lease'
$tkN1 = New-PAImplementingTask 'pa-task-neg-exp' $rn1.tasks $rn1.flags $rn1.tele
$dN1 = New-ProductiveDispatchImpl -TaskId 'pa-task-neg-exp' -AttemptRole 'coder' -SessionId 'pa-session-neg-exp' -TasksDir $rn1.tasks -FlagsPath $rn1.flags -TelemetryRoot $rn1.tele -OwnerId 'owner-neg-1' -Generation 1 -GoalStoreDir $rn1.goal -DispatchStoreDir $rn1.dispatch -Productive
Assert-PAThat ([bool]$dN1.ok) 'NEG expired dispatch ctor ok'
Start-Sleep -Milliseconds 200
$keyN1 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-NEG-EXP' -WorkItemId 'w-neg-exp' -ActionRevision 1
$liveN1 = Get-OrchestrationGoal -GoalId 'PA-NEG-EXP' -StoreDir $rn1.goal
$authN1 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'dispatch' -Resource 'w-neg-exp' -Decision 'dispatch'
$intentN1 = @{ key = $keyN1; generation = [long]1; goal_id = 'PA-NEG-EXP'; work_item_id = 'w-neg-exp'; action_revision = [long]1 }
$rExpN1 = & $dN1.impl $intentN1 $liveN1.goal $authN1
Assert-PAThat ($null -eq $rExpN1) 'NEG expired ownership denies inside dispatch callback'
Assert-PAThat ((Get-PATaskRev 'pa-task-neg-exp' $rn1.tasks) -eq 3) 'NEG expired leaves task rev 3'
# --- NEG-OWN: wrong owner / obsolete generation / missing proof deny direct invocation.
$rn2 = New-PARoot
$svN2 = New-PAActiveGoal 'PA-NEG-OWN' $rn2.goal
$ownN2 = Acquire-OrchestrationGoalOwnership -GoalId 'PA-NEG-OWN' -OwnerId 'owner-neg-1' -ExpectedRevision ([long]$svN2.revision) -StoreDir $rn2.goal
Assert-PAThat ([bool]$ownN2.ok) 'NEG owner goal ownership acquired'
$tkN2 = New-PAImplementingTask 'pa-task-neg-own' $rn2.tasks $rn2.flags $rn2.tele
$keyN2 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-NEG-OWN' -WorkItemId 'w-neg-own' -ActionRevision 1
$liveN2 = Get-OrchestrationGoal -GoalId 'PA-NEG-OWN' -StoreDir $rn2.goal
$authN2 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'dispatch' -Resource 'w-neg-own' -Decision 'dispatch'
$intentN2 = @{ key = $keyN2; generation = [long]1; goal_id = 'PA-NEG-OWN'; work_item_id = 'w-neg-own'; action_revision = [long]1 }
$dWrong = New-ProductiveDispatchImpl -TaskId 'pa-task-neg-own' -AttemptRole 'coder' -SessionId 'pa-session-neg-own' -TasksDir $rn2.tasks -FlagsPath $rn2.flags -TelemetryRoot $rn2.tele -OwnerId 'owner-neg-rogue' -Generation 1 -GoalStoreDir $rn2.goal -DispatchStoreDir $rn2.dispatch -Productive
Assert-PAThat ([bool]$dWrong.ok) 'NEG wrong-owner dispatch ctor ok'
$rWrong = & $dWrong.impl $intentN2 $liveN2.goal $authN2
Assert-PAThat ($null -eq $rWrong) 'NEG wrong owner denies inside dispatch callback'
$dStale = New-ProductiveDispatchImpl -TaskId 'pa-task-neg-own' -AttemptRole 'coder' -SessionId 'pa-session-neg-own' -TasksDir $rn2.tasks -FlagsPath $rn2.flags -TelemetryRoot $rn2.tele -OwnerId 'owner-neg-1' -Generation 99 -GoalStoreDir $rn2.goal -DispatchStoreDir $rn2.dispatch -Productive
Assert-PAThat ([bool]$dStale.ok) 'NEG obsolete-generation dispatch ctor ok'
$intentN2b = @{ key = $keyN2; generation = [long]99; goal_id = 'PA-NEG-OWN'; work_item_id = 'w-neg-own'; action_revision = [long]1 }
$rStale = & $dStale.impl $intentN2b $liveN2.goal $authN2
Assert-PAThat ($null -eq $rStale) 'NEG obsolete generation denies inside dispatch callback'
$dGood = New-ProductiveDispatchImpl -TaskId 'pa-task-neg-own' -AttemptRole 'coder' -SessionId 'pa-session-neg-own' -TasksDir $rn2.tasks -FlagsPath $rn2.flags -TelemetryRoot $rn2.tele -OwnerId 'owner-neg-1' -Generation 1 -GoalStoreDir $rn2.goal -DispatchStoreDir $rn2.dispatch -Productive
Assert-PAThat ([bool]$dGood.ok) 'NEG good dispatch ctor ok'
$rNoProof = & $dGood.impl $intentN2 $liveN2.goal $null
Assert-PAThat ($null -eq $rNoProof) 'NEG direct invocation without proof denies'
$authDeny = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops' -Operation 'dispatch' -Resource 'w-neg-own' -Decision 'dispatch'
$rDenyAuth = & $dGood.impl $intentN2 $liveN2.goal $authDeny
Assert-PAThat ($null -eq $rDenyAuth) 'NEG denied envelope denies inside dispatch callback'
Assert-PAThat ((Get-PATaskRev 'pa-task-neg-own' $rn2.tasks) -eq 3) 'NEG owner attacks leave task rev 3'
# --- NEG-DIV: settle for a divergent task is denied against binding + original receipt.
$rn4 = New-PARoot
$svN4 = New-PAActiveGoal 'PA-NEG-DIV' $rn4.goal
$ownN4 = Acquire-OrchestrationGoalOwnership -GoalId 'PA-NEG-DIV' -OwnerId 'owner-neg-1' -ExpectedRevision ([long]$svN4.revision) -StoreDir $rn4.goal
Assert-PAThat ([bool]$ownN4.ok) 'NEG divergent goal ownership acquired'
$revN4 = [long]$ownN4.revision
$tkN4a = New-PAImplementingTask 'pa-task-div-a' $rn4.tasks $rn4.flags $rn4.tele
$tkN4b = New-PAImplementingTask 'pa-task-div-b' $rn4.tasks $rn4.flags $rn4.tele
$evN4 = (New-OrchestrationObjectiveEvent -GoalId 'PA-NEG-DIV' -Type 'task-settled' -WorkItemId 'w-neg-div' -ActionRevision 1).event
$resN4 = Invoke-ProductiveObjectiveEvent -Event $evN4 -GoalStoreDir $rn4.goal -DispatchStoreDir $rn4.dispatch -CheckpointStoreDir $rn4.ckpt -TasksDir $rn4.tasks -FlagsPath $rn4.flags -TelemetryRoot $rn4.tele -TaskId 'pa-task-div-a' -AttemptRole 'coder' -SessionId 'pa-session-div' -OwnerId 'owner-neg-1' -Generation 1 -ExpectedRevision $revN4 -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Productive
Assert-PAThat (([bool]$resN4.ok -and [bool]$resN4.dispatched) -and ([string]$resN4.decision -ceq 'settlement-pending')) 'NEG divergent dispatch-only stays pending'
$snapN4 = Get-OrchestrationDispatchIntent -GoalId 'PA-NEG-DIV' -WorkItemId 'w-neg-div' -ActionRevision 1 -StoreDir $rn4.dispatch
Assert-PAThat ([bool]$snapN4.ok) 'NEG divergent intent readable'
$liveN4 = Get-OrchestrationGoal -GoalId 'PA-NEG-DIV' -StoreDir $rn4.goal
$authSetN4 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource 'w-neg-div' -Decision 'settlement'
$rogue = New-ProductiveSettleImpl -TaskId 'pa-task-div-b' -AttemptRole 'coder' -SessionId 'pa-session-div' -TasksDir $rn4.tasks -FlagsPath $rn4.flags -TelemetryRoot $rn4.tele -OwnerId 'owner-neg-1' -Generation 1 -GoalStoreDir $rn4.goal -DispatchStoreDir $rn4.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:rogue') -Productive
Assert-PAThat ([bool]$rogue.ok) 'NEG divergent rogue settle ctor ok'
$rRogue = & $rogue.impl $snapN4.intent $snapN4.intent['receipt'] $liveN4.goal $authSetN4
Assert-PAThat ($null -eq $rRogue) 'NEG divergent task settle denied'
Assert-PAThat (((Get-PATaskRev 'pa-task-div-a' $rn4.tasks) -eq 4) -and ((Get-PATaskRev 'pa-task-div-b' $rn4.tasks) -eq 3)) 'NEG divergent leaves both task revs intact'
# --- NEG-CRASH2: crash between effect and receipt recovers via the destination record.
$rn5 = New-PARoot
$svN5 = New-PAActiveGoal 'PA-NEG-CRASH2' $rn5.goal
$ownN5 = Acquire-OrchestrationGoalOwnership -GoalId 'PA-NEG-CRASH2' -OwnerId 'owner-neg-1' -ExpectedRevision ([long]$svN5.revision) -StoreDir $rn5.goal
Assert-PAThat ([bool]$ownN5.ok) 'NEG crash2 goal ownership acquired'
$revN5 = [long]$ownN5.revision
$tkN5 = New-PAImplementingTask 'pa-task-crash2' $rn5.tasks $rn5.flags $rn5.tele
$keyN5 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-NEG-CRASH2' -WorkItemId 'w-crash2' -ActionRevision 1
$saN5 = Start-OrchestrationTaskAttempt -TaskId 'pa-task-crash2' -AttemptRole 'coder' -SessionId 'pa-session-crash2' -Actor 'planner' -ExpectedRevision 3 -ActorIdentitySource 'explicit-cli' -StrategyApproach 'productive-dispatch' -StrategyTool 'task-kernel-record' -StrategyParams @($keyN5) -TasksDir $rn5.tasks -FlagsPath $rn5.flags -TelemetryRoot $rn5.tele
Assert-PAThat ([bool]$saN5.ok) 'NEG crash2 kernel attempt started without diary receipt'
$inN5 = New-OrchestrationDispatchIntent -GoalId 'PA-NEG-CRASH2' -WorkItemId 'w-crash2' -ActionRevision 1
$inN5.intent['owner'] = 'owner-neg-1'
$inN5.intent['generation'] = [long]1
$inN5.intent['request_hash'] = (Get-OrchestrationObjectiveRequestHash -Key $keyN5 -ExpectedRevision $revN5)
$inN5.intent['goal_revision_origin'] = [long]$revN5
$svN5i = Save-OrchestrationDispatchIntent -Intent $inN5.intent -StoreDir $rn5.dispatch
Assert-PAThat ([bool]$svN5i.ok) 'NEG crash2 bare intent persisted'
$stN5 = Set-OrchestrationDispatchState -GoalId 'PA-NEG-CRASH2' -WorkItemId 'w-crash2' -ActionRevision 1 -State 'dispatched-unknown' -StoreDir $rn5.dispatch
Assert-PAThat ([bool]$stN5.ok) 'NEG crash2 intent marked dispatched-unknown'
$bindN5 = @{ key = $keyN5; goal_id = 'PA-NEG-CRASH2'; work_item_id = 'w-crash2'; action_revision = [long]1; task_id = 'pa-task-crash2'; run_id = 'pa-session-crash2'; attempt_role = 'coder'; owner = 'owner-neg-1'; generation = [long]1; idempotency_key = $keyN5 }
Assert-PAThat ([bool](Save-PABinding -Binding $bindN5 -Dir $rn5.dispatch)) 'NEG crash2 binding persisted without receipt'
$sProofN5 = @{ destination = 'task-kernel'; action = 'worker-result'; fencing_owner = 'owner-neg-1'; fencing_generation = [long]1; idempotency_key = $keyN5 }
$resN5 = Invoke-ProductiveObjectiveReconcile -GoalId 'PA-NEG-CRASH2' -GoalStoreDir $rn5.goal -DispatchStoreDir $rn5.dispatch -TasksDir $rn5.tasks -FlagsPath $rn5.flags -TelemetryRoot $rn5.tele -TaskId 'pa-task-crash2' -AttemptRole 'coder' -SessionId 'pa-session-crash2' -OwnerId 'owner-neg-1' -Generation 1 -ExpectedRevision $revN5 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -SettleProof $sProofN5 -Productive
Assert-PAThat (([bool]$resN5.ok -and ([long]$resN5.reconciled -eq 1)) -and ([long]$resN5.settled -eq 0)) 'NEG crash2 reconcile observes destination record; settle HOLDS without native context'
Assert-PAThat ((Get-PATaskRev 'pa-task-crash2' $rn5.tasks) -eq 4) 'NEG crash2 task rev stays 4 (no settle write)'
# --- NEG-INDET: receipt absent + destination without record stays INDETERMINATE.
$rn6 = New-PARoot
$svN6 = New-PAActiveGoal 'PA-NEG-INDET' $rn6.goal
$ownN6 = Acquire-OrchestrationGoalOwnership -GoalId 'PA-NEG-INDET' -OwnerId 'owner-neg-1' -ExpectedRevision ([long]$svN6.revision) -StoreDir $rn6.goal
Assert-PAThat ([bool]$ownN6.ok) 'NEG indet goal ownership acquired'
$revN6 = [long]$ownN6.revision
$evN6 = (New-OrchestrationObjectiveEvent -GoalId 'PA-NEG-INDET' -Type 'task-settled' -WorkItemId 'w-neg-indet' -ActionRevision 1).event
$resN6 = Invoke-ProductiveObjectiveEvent -Event $evN6 -GoalStoreDir $rn6.goal -DispatchStoreDir $rn6.dispatch -CheckpointStoreDir $rn6.ckpt -TasksDir $rn6.tasks -FlagsPath $rn6.flags -TelemetryRoot $rn6.tele -TaskId 'pa-task-ghost' -AttemptRole 'coder' -SessionId 'pa-session-indet' -OwnerId 'owner-neg-1' -Generation 1 -ExpectedRevision $revN6 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -Productive
Assert-PAThat (([bool]$resN6.ok -and [bool]$resN6.dispatched) -and ([string]$resN6.decision -ceq 'settlement-pending')) 'NEG indet ghost dispatch stays pending'
$keyN6 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-NEG-INDET' -WorkItemId 'w-neg-indet' -ActionRevision 1
$sProofN6 = @{ destination = 'task-kernel'; action = 'worker-result'; fencing_owner = 'owner-neg-1'; fencing_generation = [long]1; idempotency_key = $keyN6 }
$resR6 = Invoke-ProductiveObjectiveReconcile -GoalId 'PA-NEG-INDET' -GoalStoreDir $rn6.goal -DispatchStoreDir $rn6.dispatch -TasksDir $rn6.tasks -FlagsPath $rn6.flags -TelemetryRoot $rn6.tele -TaskId 'pa-task-ghost' -AttemptRole 'coder' -SessionId 'pa-session-indet' -OwnerId 'owner-neg-1' -Generation 1 -ExpectedRevision $revN6 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -SettleProof $sProofN6 -Productive
Assert-PAThat (([long]$resR6.settled -eq 0) -and ([long]$resR6.reconciled -eq 0)) 'NEG indet recovery settles nothing'
$afterN6 = Get-OrchestrationDispatchIntent -GoalId 'PA-NEG-INDET' -WorkItemId 'w-neg-indet' -ActionRevision 1 -StoreDir $rn6.dispatch
Assert-PAThat (([bool]$afterN6.ok -and ([string]$afterN6.intent['state'] -cne 'settled')) -and ([string]$afterN6.intent['state'] -cne 'reconciled')) 'NEG indet intent never closed without destination proof'
# --- R3-NEW: constructors deny empty stores with -Productive (live-only).
$dNoGoal = New-ProductiveDispatchImpl -TaskId 'pa-task-x' -OwnerId 'owner-pa-1' -Generation 1 -DispatchStoreDir 'D' -Productive
Assert-PAThat ((($null -eq $dNoGoal) -or (-not [bool]$dNoGoal.ok)) -and ($null -eq $dNoGoal.impl)) 'R3 dispatch ctor empty GoalStoreDir holds with no impl'
$dNoBindDir = New-ProductiveDispatchImpl -TaskId 'pa-task-x' -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir 'G' -Productive
Assert-PAThat ((($null -eq $dNoBindDir) -or (-not [bool]$dNoBindDir.ok)) -and ($null -eq $dNoBindDir.impl)) 'R3 dispatch ctor empty DispatchStoreDir holds with no impl'
$sNoGoal = New-ProductiveSettleImpl -TaskId 'pa-task-x' -OwnerId 'owner-pa-1' -Generation 1 -DispatchStoreDir 'D' -Productive
Assert-PAThat ((($null -eq $sNoGoal) -or (-not [bool]$sNoGoal.ok)) -and ($null -eq $sNoGoal.impl)) 'R3 settle ctor empty GoalStoreDir holds with no impl'
$sNoBindDir = New-ProductiveSettleImpl -TaskId 'pa-task-x' -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir 'G' -Productive
Assert-PAThat ((($null -eq $sNoBindDir) -or (-not [bool]$sNoBindDir.ok)) -and ($null -eq $sNoBindDir.impl)) 'R3 settle ctor empty DispatchStoreDir holds with no impl'
$rNoGoal = New-ProductiveReconcileImpl -DispatchStoreDir 'D' -TasksDir 'T' -OwnerId 'owner-pa-1' -Generation 1 -Productive
Assert-PAThat ((($null -eq $rNoGoal) -or (-not [bool]$rNoGoal.ok)) -and ($null -eq $rNoGoal.impl)) 'R3 reconcile ctor empty GoalStoreDir holds with no impl'
$rNoBindDir = New-ProductiveReconcileImpl -GoalStoreDir 'G' -TasksDir 'T' -OwnerId 'owner-pa-1' -Generation 1 -Productive
Assert-PAThat ((($null -eq $rNoBindDir) -or (-not [bool]$rNoBindDir.ok)) -and ($null -eq $rNoBindDir.impl)) 'R3 reconcile ctor empty DispatchStoreDir holds with no impl'
$rNoTasks = New-ProductiveReconcileImpl -GoalStoreDir 'G' -DispatchStoreDir 'D' -OwnerId 'owner-pa-1' -Generation 1 -Productive
Assert-PAThat ((($null -eq $rNoTasks) -or (-not [bool]$rNoTasks.ok)) -and ($null -eq $rNoTasks.impl)) 'R3 reconcile ctor empty TasksDir holds with no impl'
$kNoGoal = New-ProductiveCheckpointImpl -CheckpointStoreDir 'C' -Productive
Assert-PAThat ((($null -eq $kNoGoal) -or (-not [bool]$kNoGoal.ok)) -and ($null -eq $kNoGoal.impl)) 'R3 checkpoint ctor empty GoalStoreDir holds with no impl'
$gNoStore = Test-PAInCallbackGate -GoalSnapshot @{ goal_id = 'x' } -GoalStoreDir '' -OwnerId 'o' -Generation 1 -Auth $null -ExpectedOperation 'dispatch' -WorkItemId 'w'
Assert-PAThat (-not [bool](Get-PAFieldValue $gNoStore 'ok' $false)) 'R3 callback gate empty GoalStoreDir denies (no snapshot-as-live)'
# --- R1-NEW: incomplete binding never persists; conflicting/concurrent bindings keep one chain; write failure => 0 Start.
$rb = New-PARoot
$svB = New-PAActiveGoal 'PA-BIND-1' $rb.goal
$ownB = Acquire-OrchestrationGoalOwnership -GoalId 'PA-BIND-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svB.revision) -StoreDir $rb.goal
Assert-PAThat ([bool]$ownB.ok) 'R1 bind goal ownership acquired'
$tkBa = New-PAImplementingTask 'pa-task-bind-a' $rb.tasks $rb.flags $rb.tele
$tkBb = New-PAImplementingTask 'pa-task-bind-b' $rb.tasks $rb.flags $rb.tele
$keyB = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-BIND-1' -WorkItemId 'w-bind' -ActionRevision 1
$incBind = @{ key = $keyB; goal_id = 'PA-BIND-1'; work_item_id = 'w-bind'; action_revision = [long]1; task_id = 'pa-task-bind-a'; run_id = 'pa-session-bind'; owner = 'owner-pa-1'; generation = [long]1; idempotency_key = $keyB }
Assert-PAThat (-not (Save-PABinding -Binding $incBind -Dir $rb.dispatch)) 'R1 incomplete binding (role absent) never persists'
$badPathB = Get-PABindingPath -Dir $rb.dispatch -Key $keyB
Write-PAFile -Path $badPathB -Text (ConvertTo-Json -InputObject $incBind -Depth 10 -Compress)
$dBindA = New-ProductiveDispatchImpl -TaskId 'pa-task-bind-a' -AttemptRole 'coder' -SessionId 'pa-session-bind' -TasksDir $rb.tasks -FlagsPath $rb.flags -TelemetryRoot $rb.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $rb.goal -DispatchStoreDir $rb.dispatch -Productive
Assert-PAThat ([bool]$dBindA.ok) 'R1 bind dispatch ctor ok'
$liveB = Get-OrchestrationGoal -GoalId 'PA-BIND-1' -StoreDir $rb.goal
$authB = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'dispatch' -Resource 'w-bind' -Decision 'dispatch'
$intentB = @{ key = $keyB; generation = [long]1; goal_id = 'PA-BIND-1'; work_item_id = 'w-bind'; action_revision = [long]1 }
$rBindBad = & $dBindA.impl $intentB $liveB.goal $authB
Assert-PAThat ($null -eq $rBindBad) 'R1 incomplete pre-existing binding denies before Start'
Assert-PAThat ((Get-PATaskRev 'pa-task-bind-a' $rb.tasks) -eq 3) 'R1 incomplete binding leaves task rev 3 (0 Start)'
try { Remove-Item -LiteralPath $badPathB -Force -ErrorAction SilentlyContinue } catch { }
$bindA = [ordered]@{ schema_version = 1; key = $keyB; goal_id = 'PA-BIND-1'; work_item_id = 'w-bind'; action_revision = [long]1; task_id = 'pa-task-bind-a'; run_id = 'pa-session-bind'; attempt_role = 'coder'; owner = 'owner-pa-1'; generation = [long]1; idempotency_key = $keyB; created_at = 't' }
Assert-PAThat ([bool](Save-PABinding -Binding $bindA -Dir $rb.dispatch)) 'R1 first binding wins'
$bindB2 = [ordered]@{ schema_version = 1; key = $keyB; goal_id = 'PA-BIND-1'; work_item_id = 'w-bind'; action_revision = [long]1; task_id = 'pa-task-bind-b'; run_id = 'pa-session-bind'; attempt_role = 'coder'; owner = 'owner-pa-1'; generation = [long]1; idempotency_key = $keyB; created_at = 't' }
Assert-PAThat (-not (Save-PABinding -Binding $bindB2 -Dir $rb.dispatch)) 'R1 concurrent second binding same key conflicts'
$readB = Get-PABinding -Dir $rb.dispatch -Key $keyB
Assert-PAThat (([string](Get-PAFieldValue $readB 'task_id' '') -ceq 'pa-task-bind-a') -and ([string](Get-PAFieldValue $readB 'attempt_role' '') -ceq 'coder')) 'R1 one chain survives concurrent bindings'
$dBindB = New-ProductiveDispatchImpl -TaskId 'pa-task-bind-b' -AttemptRole 'coder' -SessionId 'pa-session-bind' -TasksDir $rb.tasks -FlagsPath $rb.flags -TelemetryRoot $rb.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $rb.goal -DispatchStoreDir $rb.dispatch -Productive
Assert-PAThat ([bool]$dBindB.ok) 'R1 bind divergent dispatch ctor ok'
$rBindDiv = & $dBindB.impl $intentB $liveB.goal $authB
Assert-PAThat ($null -eq $rBindDiv) 'R1 divergent binding denies before Start'
Assert-PAThat ((Get-PATaskRev 'pa-task-bind-b' $rb.tasks) -eq 3) 'R1 divergent binding leaves task rev 3 (0 Start)'
$fileAsDir = Join-Path $rb.root 'afile.txt'
Write-PAFile -Path $fileAsDir -Text 'x'
$keyB2 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-BIND-1' -WorkItemId 'w-bind-2' -ActionRevision 1
$dBindF = New-ProductiveDispatchImpl -TaskId 'pa-task-bind-b' -AttemptRole 'coder' -SessionId 'pa-session-bind2' -TasksDir $rb.tasks -FlagsPath $rb.flags -TelemetryRoot $rb.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $rb.goal -DispatchStoreDir $fileAsDir -Productive
Assert-PAThat ([bool]$dBindF.ok) 'R1 bind write-failure dispatch ctor ok'
$authB2 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'dispatch' -Resource 'w-bind-2' -Decision 'dispatch'
$intentB2 = @{ key = $keyB2; generation = [long]1; goal_id = 'PA-BIND-1'; work_item_id = 'w-bind-2'; action_revision = [long]1 }
$rBindF = & $dBindF.impl $intentB2 $liveB.goal $authB2
Assert-PAThat ($null -eq $rBindF) 'R1 binding write failure denies before Start'
Assert-PAThat ((Get-PATaskRev 'pa-task-bind-b' $rb.tasks) -eq 3) 'R1 write failure leaves task rev 3 (0 Start)'
# --- R1-NEW: every chain field absent/divergent => 0 settle; receipt provenance exact required.
$rs = New-PARoot
$svS = New-PAActiveGoal 'PA-SETTLE-1' $rs.goal
$ownS = Acquire-OrchestrationGoalOwnership -GoalId 'PA-SETTLE-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svS.revision) -StoreDir $rs.goal
Assert-PAThat ([bool]$ownS.ok) 'R1 settle goal ownership acquired'
$revS = [long]$ownS.revision
$tkS = New-PAImplementingTask 'pa-task-settle-1' $rs.tasks $rs.flags $rs.tele
$evS = (New-OrchestrationObjectiveEvent -GoalId 'PA-SETTLE-1' -Type 'task-settled' -WorkItemId 'w-settle' -ActionRevision 1).event
$resS = Invoke-ProductiveObjectiveEvent -Event $evS -GoalStoreDir $rs.goal -DispatchStoreDir $rs.dispatch -CheckpointStoreDir $rs.ckpt -TasksDir $rs.tasks -FlagsPath $rs.flags -TelemetryRoot $rs.tele -TaskId 'pa-task-settle-1' -AttemptRole 'coder' -SessionId 'pa-session-settle' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revS -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Productive
Assert-PAThat (([bool]$resS.ok -and [bool]$resS.dispatched) -and ([string]$resS.decision -ceq 'settlement-pending')) 'R1 settle fixture dispatch-only stays pending'
$snapS = Get-OrchestrationDispatchIntent -GoalId 'PA-SETTLE-1' -WorkItemId 'w-settle' -ActionRevision 1 -StoreDir $rs.dispatch
Assert-PAThat ([bool]$snapS.ok) 'R1 settle fixture intent readable'
$liveS = Get-OrchestrationGoal -GoalId 'PA-SETTLE-1' -StoreDir $rs.goal
$authSS = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource 'w-settle' -Decision 'settlement'
$keyS = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-SETTLE-1' -WorkItemId 'w-settle' -ActionRevision 1
$stS = New-ProductiveSettleImpl -TaskId 'pa-task-settle-1' -AttemptRole 'coder' -SessionId 'pa-session-settle' -TasksDir $rs.tasks -FlagsPath $rs.flags -TelemetryRoot $rs.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $rs.goal -DispatchStoreDir $rs.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -Productive
Assert-PAThat ([bool]$stS.ok) 'R1 settle fixture ctor ok'
$bindPathS = Get-PABindingPath -Dir $rs.dispatch -Key $keyS
$baseBindS = Get-PABinding -Dir $rs.dispatch -Key $keyS
Assert-PAThat ((Test-PABindingComplete $baseBindS)) 'R1 settle fixture binding complete'
function Set-RSMutatedBinding {
    param($Base, [string]$Path, [string]$Field, $Value, [switch]$Remove)
    $h = [ordered]@{}
    foreach ($kk in @('schema_version', 'key', 'goal_id', 'work_item_id', 'action_revision', 'task_id', 'run_id', 'attempt_role', 'owner', 'generation', 'idempotency_key', 'created_at')) {
        $h[$kk] = (Get-PAFieldValue $Base $kk $null)
    }
    if ([bool]$Remove) { $h.Remove($Field) } else { $h[$Field] = $Value }
    Write-PAFile -Path $Path -Text (ConvertTo-Json -InputObject $h -Depth 10 -Compress)
}
$rcptS = $snapS.intent['receipt']
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'task_id' -Value 'pa-task-other'
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies divergent binding task'
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'run_id' -Value 'pa-session-other'
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies divergent binding run'
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'attempt_role' -Remove
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies binding role absent'
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'owner' -Value 'owner-rogue'
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies divergent binding owner'
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'generation' -Value ([long]99)
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies divergent binding generation'
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'goal_id' -Value 'PA-OTHER'
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies divergent binding goal'
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'work_item_id' -Value 'w-other'
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies divergent binding work item'
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'action_revision' -Value ([long]2)
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies divergent binding action revision'
Set-RSMutatedBinding -Base $baseBindS -Path $bindPathS -Field 'key' -Value 'other-key'
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies divergent binding key'
Write-PAFile -Path $bindPathS -Text (ConvertTo-Json -InputObject $baseBindS -Depth 10 -Compress)
$rcptOp = @{ operation = 'settlement'; destination = 'task-kernel'; action = 'start-attempt'; task_id = 'pa-task-settle-1'; run_id = 'pa-session-settle'; generation = [long]1; idempotency_key = $keyS; result = 'x' }
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptOp $liveS.goal $authSS))) 'R1 settle denies receipt wrong operation (status alone insufficient)'
$rcptNoDst = @{ operation = 'dispatch'; destination = ''; action = 'start-attempt'; task_id = 'pa-task-settle-1'; run_id = 'pa-session-settle'; generation = [long]1; idempotency_key = $keyS; result = 'x' }
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptNoDst $liveS.goal $authSS))) 'R1 settle denies receipt missing destination'
$rcptDiv = @{ operation = 'dispatch'; destination = 'task-kernel'; action = 'start-attempt'; task_id = 'pa-task-other'; run_id = 'pa-session-settle'; generation = [long]1; idempotency_key = $keyS; result = 'x' }
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptDiv $liveS.goal $authSS))) 'R1 settle denies receipt divergent task'
$rcptNoKey = @{ operation = 'dispatch'; destination = 'task-kernel'; action = 'start-attempt'; task_id = 'pa-task-settle-1'; run_id = 'pa-session-settle'; generation = [long]1; result = 'x' }
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptNoKey $liveS.goal $authSS))) 'R1 settle denies receipt missing key'
Assert-PAThat (((Get-PATaskRev 'pa-task-settle-1' $rs.tasks) -eq 4) -and (-not (Test-PAWorkerResult 'pa-task-settle-1' $rs.tasks))) 'R1 denied settles leave rev 4 with no worker result (0 settle)'
# --- R1-K2: live attempt with role absent denies settle before recover/write.
$taskFileS = Get-TaskKernelFilePath -TaskId 'pa-task-settle-1' -TasksDir $rs.tasks
$origTaskS = [IO.File]::ReadAllText($taskFileS, [Text.Encoding]::UTF8)
$mutS = ConvertFrom-Json $origTaskS
[void]$mutS.execution_runtime.PSObject.Properties.Remove('attempt_role')
Write-PAFile -Path $taskFileS -Text (ConvertTo-Json -InputObject $mutS -Depth 20 -Compress)
Assert-PAThat (($null -eq (& $stS.impl $snapS.intent $rcptS $liveS.goal $authSS))) 'R1 settle denies live attempt with role absent'
Write-PAFile -Path $taskFileS -Text $origTaskS
$restoredS = Get-OrchestrationTask -TaskId 'pa-task-settle-1' -TasksDir $rs.tasks
Assert-PAThat (([string]$restoredS['execution_runtime']['attempt_role'] -ceq 'coder') -and ((Get-PATaskRev 'pa-task-settle-1' $rs.tasks) -eq 4)) 'R1 task file restored with role intact and rev 4'
# --- R1-NEW: old result same status but different evidence => no recovery; same evidence recovers.
$ro = New-PARoot
$svO = New-PAActiveGoal 'PA-OLDRES-1' $ro.goal
$ownO = Acquire-OrchestrationGoalOwnership -GoalId 'PA-OLDRES-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svO.revision) -StoreDir $ro.goal
Assert-PAThat ([bool]$ownO.ok) 'R1 oldresult goal ownership acquired'
$revO = [long]$ownO.revision
$tkO = New-PAImplementingTask 'pa-task-oldres-1' $ro.tasks $ro.flags $ro.tele
$evO = (New-OrchestrationObjectiveEvent -GoalId 'PA-OLDRES-1' -Type 'task-settled' -WorkItemId 'w-oldres' -ActionRevision 1).event
$resO = Invoke-ProductiveObjectiveEvent -Event $evO -GoalStoreDir $ro.goal -DispatchStoreDir $ro.dispatch -CheckpointStoreDir $ro.ckpt -TasksDir $ro.tasks -FlagsPath $ro.flags -TelemetryRoot $ro.tele -TaskId 'pa-task-oldres-1' -AttemptRole 'coder' -SessionId 'pa-session-oldres' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revO -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -Productive
Assert-PAThat (([bool]$resO.ok -and ([string]$resO.decision -ceq 'settlement-pending')) -and ([string]$resO.settlement -ceq 'pending-reconciliation')) 'R1 oldresult fixture dispatch-only stays pending (no native context, no recovery)'
$snapO = Get-OrchestrationDispatchIntent -GoalId 'PA-OLDRES-1' -WorkItemId 'w-oldres' -ActionRevision 1 -StoreDir $ro.dispatch
$liveO = Get-OrchestrationGoal -GoalId 'PA-OLDRES-1' -StoreDir $ro.goal
$authSO = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource 'w-oldres' -Decision 'settlement'
$stOld = New-ProductiveSettleImpl -TaskId 'pa-task-oldres-1' -AttemptRole 'coder' -SessionId 'pa-session-oldres' -TasksDir $ro.tasks -FlagsPath $ro.flags -TelemetryRoot $ro.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $ro.goal -DispatchStoreDir $ro.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:9:other-evidence') -Productive
Assert-PAThat ([bool]$stOld.ok) 'R1 oldresult divergent-evidence ctor ok'
$rOld = & $stOld.impl $snapO.intent $snapO.intent['receipt'] $liveO.goal $authSO
Assert-PAThat ($null -eq $rOld) 'R1 old result without native context => HOLD, never recovery-by-equality'
$stSame = New-ProductiveSettleImpl -TaskId 'pa-task-oldres-1' -AttemptRole 'coder' -SessionId 'pa-session-oldres' -TasksDir $ro.tasks -FlagsPath $ro.flags -TelemetryRoot $ro.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $ro.goal -DispatchStoreDir $ro.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -Productive
Assert-PAThat ([bool]$stSame.ok) 'R1 oldresult same-evidence ctor ok'
$rSame = & $stSame.impl $snapO.intent $snapO.intent['receipt'] $liveO.goal $authSO
Assert-PAThat ($null -eq $rSame) 'R1 same evidence without native context => HOLD, recovery path removed'
Assert-PAThat ((Get-PATaskRev 'pa-task-oldres-1' $ro.tasks) -eq 4) 'R1 HOLD writes nothing (rev stays 4)'
# --- R2-NEW: worker_result of another session/role/key => INDETERMINATE; consult without settle grants => no new effect.
$rr = New-PARoot
$svR = New-PAActiveGoal 'PA-RECO-1' $rr.goal
$ownR = Acquire-OrchestrationGoalOwnership -GoalId 'PA-RECO-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svR.revision) -StoreDir $rr.goal
Assert-PAThat ([bool]$ownR.ok) 'R2 reco goal ownership acquired'
$revR = [long]$ownR.revision
$tkR = New-PAImplementingTask 'pa-task-reco-1' $rr.tasks $rr.flags $rr.tele
$evR = (New-OrchestrationObjectiveEvent -GoalId 'PA-RECO-1' -Type 'task-settled' -WorkItemId 'w-reco' -ActionRevision 1).event
$resR0 = Invoke-ProductiveObjectiveEvent -Event $evR -GoalStoreDir $rr.goal -DispatchStoreDir $rr.dispatch -CheckpointStoreDir $rr.ckpt -TasksDir $rr.tasks -FlagsPath $rr.flags -TelemetryRoot $rr.tele -TaskId 'pa-task-reco-1' -AttemptRole 'coder' -SessionId 'pa-session-reco' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revR -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Productive
Assert-PAThat (([bool]$resR0.ok -and [bool]$resR0.dispatched) -and ([string]$resR0.decision -ceq 'settlement-pending')) 'R2 reco fixture dispatch-only stays pending'
$keyR = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-RECO-1' -WorkItemId 'w-reco' -ActionRevision 1
$recR = (Get-OrchestrationDispatchIntent -GoalId 'PA-RECO-1' -WorkItemId 'w-reco' -ActionRevision 1 -StoreDir $rr.dispatch).intent
$authRR = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'reconcile' -Resource 'w-reco' -Decision 'reconcile'
$rcR = New-ProductiveReconcileImpl -GoalStoreDir $rr.goal -DispatchStoreDir $rr.dispatch -TasksDir $rr.tasks -OwnerId 'owner-pa-1' -Generation 1 -Productive
Assert-PAThat ([bool]$rcR.ok) 'R2 reco ctor ok'
$obsBase = & $rcR.impl $recR $authRR
Assert-PAThat ((($null -ne $obsBase) -and [bool]$obsBase.ok) -and [bool]$obsBase.effect_observed) 'R2 reco baseline observes dispatch from binding+live attempt'
$bindPathR = Get-PABindingPath -Dir $rr.dispatch -Key $keyR
$baseBindR = Get-PABinding -Dir $rr.dispatch -Key $keyR
Set-RSMutatedBinding -Base $baseBindR -Path $bindPathR -Field 'run_id' -Value 'pa-session-other'
$obsSess = & $rcR.impl $recR $authRR
Assert-PAThat ((($null -ne $obsSess) -and [bool]$obsSess.ok) -and ((-not [bool]$obsSess.effect_observed) -and ((-not [bool]$obsSess.no_effect_proven) -and (-not [bool]$obsSess.no_capable_request)))) 'R2 worker_result of another session => INDETERMINATE'
Set-RSMutatedBinding -Base $baseBindR -Path $bindPathR -Field 'attempt_role' -Value 'reviewer'
$obsRole = & $rcR.impl $recR $authRR
Assert-PAThat ((($null -ne $obsRole) -and [bool]$obsRole.ok) -and ((-not [bool]$obsRole.effect_observed) -and ((-not [bool]$obsRole.no_effect_proven) -and (-not [bool]$obsRole.no_capable_request)))) 'R2 worker_result of another role => INDETERMINATE'
Write-PAFile -Path $bindPathR -Text (ConvertTo-Json -InputObject $baseBindR -Depth 10 -Compress)
$obsFix = & $rcR.impl $recR $authRR
Assert-PAThat ((($null -ne $obsFix) -and [bool]$obsFix.ok) -and [bool]$obsFix.effect_observed) 'R2 restored binding observes again'
$resRQ = Invoke-ProductiveObjectiveReconcile -GoalId 'PA-RECO-1' -GoalStoreDir $rr.goal -DispatchStoreDir $rr.dispatch -TasksDir $rr.tasks -FlagsPath $rr.flags -TelemetryRoot $rr.tele -TaskId 'pa-task-reco-1' -AttemptRole 'coder' -SessionId 'pa-session-reco' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revR -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:reconcile' -Productive
Assert-PAThat (([bool]$resRQ.ok -and ([long]$resRQ.reconciled -eq 1)) -and ([long]$resRQ.settled -eq 0)) 'R2 consult without settle grants observes with no new effect'
Assert-PAThat ((Get-PATaskRev 'pa-task-reco-1' $rr.tasks) -eq 4) 'R2 consult leaves task rev 4 (no redispatch)'
# --- R2-K1: binding chain divergent from the record => INDETERMINATE.
Set-RSMutatedBinding -Base $baseBindR -Path $bindPathR -Field 'owner' -Value 'owner-rogue'
$obsChain = & $rcR.impl $recR $authRR
Assert-PAThat ((($null -ne $obsChain) -and [bool]$obsChain.ok) -and ((-not [bool]$obsChain.effect_observed) -and ((-not [bool]$obsChain.no_effect_proven) -and (-not [bool]$obsChain.no_capable_request)))) 'R2 binding owner divergent from record => INDETERMINATE'
Assert-PAThat (([string]$obsChain.reason -ceq 'productive-reconcile-indeterminate:binding-fencing-mismatch') -and ((Get-PATaskRev 'pa-task-reco-1' $rr.tasks) -eq 4)) 'R2 binding fencing mismatch reason exact with no new effect'
Write-PAFile -Path $bindPathR -Text (ConvertTo-Json -InputObject $baseBindR -Depth 10 -Compress)
# --- R2-K1: same task/session/role but attempt persisted under another key => INDETERMINATE.
$taskFileR = Get-TaskKernelFilePath -TaskId 'pa-task-reco-1' -TasksDir $rr.tasks
$origTaskR = [IO.File]::ReadAllText($taskFileR, [Text.Encoding]::UTF8)
$otherFpR = [string](Resolve-TaskKernelStrategyFingerprint -Approach 'productive-dispatch' -ToolOrPath 'task-kernel-record' -KeyParams @('pa-reco-1|w-other|1')).fingerprint
$mutR = ConvertFrom-Json $origTaskR
$mutR.execution_runtime.gate_evidence.strategy_fingerprint = $otherFpR
Write-PAFile -Path $taskFileR -Text (ConvertTo-Json -InputObject $mutR -Depth 20 -Compress)
$obsKey = & $rcR.impl $recR $authRR
Assert-PAThat ((($null -ne $obsKey) -and [bool]$obsKey.ok) -and ((-not [bool]$obsKey.effect_observed) -and ((-not [bool]$obsKey.no_effect_proven) -and (-not [bool]$obsKey.no_capable_request)))) 'R2 same task/session/role different attempt key => INDETERMINATE'
Assert-PAThat (([string]$obsKey.reason -ceq 'productive-reconcile-indeterminate:attempt-key-mismatch') -and ((Get-PATaskRev 'pa-task-reco-1' $rr.tasks) -eq 4)) 'R2 attempt key mismatch reason exact with no new effect'
Write-PAFile -Path $taskFileR -Text $origTaskR
$obsKeyFix = & $rcR.impl $recR $authRR
Assert-PAThat ((($null -ne $obsKeyFix) -and [bool]$obsKeyFix.ok) -and [bool]$obsKeyFix.effect_observed) 'R2 restored attempt key observes again'
# --- R3-NEW: snapshot pre-troca denied (stale ACTIVE snapshot vs live terminal; foreign snapshot).
$rp = New-PARoot
$svP = New-PAActiveGoal 'PA-PREX-1' $rp.goal
$ownP = Acquire-OrchestrationGoalOwnership -GoalId 'PA-PREX-1' -OwnerId 'owner-pa-1' -ExpectedRevision ([long]$svP.revision) -StoreDir $rp.goal
Assert-PAThat ([bool]$ownP.ok) 'R3 prex goal ownership acquired'
$tkP = New-PAImplementingTask 'pa-task-prex-1' $rp.tasks $rp.flags $rp.tele
$staleP = (Get-OrchestrationGoal -GoalId 'PA-PREX-1' -StoreDir $rp.goal).goal
$finP = Set-OrchestrationGoalStatePersisted -GoalId 'PA-PREX-1' -ToState 'COMPLETED' -ExpectedRevision ([long]$ownP.revision) -StoreDir $rp.goal -OwnerId 'owner-pa-1' -OwnershipGeneration 1
Assert-PAThat ([bool]$finP.ok) 'R3 prex goal completed persisted'
$keyP = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-PREX-1' -WorkItemId 'w-prex' -ActionRevision 1
$dPrex = New-ProductiveDispatchImpl -TaskId 'pa-task-prex-1' -AttemptRole 'coder' -SessionId 'pa-session-prex' -TasksDir $rp.tasks -FlagsPath $rp.flags -TelemetryRoot $rp.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $rp.goal -DispatchStoreDir $rp.dispatch -Productive
Assert-PAThat ([bool]$dPrex.ok) 'R3 prex dispatch ctor ok'
$authP = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'dispatch' -Resource 'w-prex' -Decision 'dispatch'
$intentP = @{ key = $keyP; generation = [long]1; goal_id = 'PA-PREX-1'; work_item_id = 'w-prex'; action_revision = [long]1 }
$rPrex = & $dPrex.impl $intentP $staleP $authP
Assert-PAThat ($null -eq $rPrex) 'R3 stale snapshot pre-troca denied by live read'
$svP2 = New-PAActiveGoal 'PA-PREX-2' $rp.goal
$foreignP = (Get-OrchestrationGoal -GoalId 'PA-PREX-2' -StoreDir $rp.goal).goal
$rForeign = & $dPrex.impl $intentP $foreignP $authP
Assert-PAThat ($null -eq $rForeign) 'R3 foreign snapshot denied by intent/snapshot cross-check'
Assert-PAThat ((Get-PATaskRev 'pa-task-prex-1' $rp.tasks) -eq 3) 'R3 snapshot attacks leave task rev 3 (0 Start)'
# --- F1-S2: canonical settle owner (PA delegates ONCE to ND-Settle; HOLD without context).
function New-S2Root {
    $r = New-PARoot
    $receipt = Join-Path $r.root 'receipts'
    $evidence = Join-Path $r.root 'evidence'
    New-Item -ItemType Directory -Path $receipt -Force | Out-Null
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
    return @{ root = $r.root; goal = $r.goal; dispatch = $r.dispatch; ckpt = $r.ckpt; tasks = $r.tasks; tele = $r.tele; flags = $r.flags; receipt = $receipt; evidence = $evidence }
}
function New-S2Fixture {
    param([string]$Tag, [string]$Policy = 'canonical-native-settle')
    $f = New-S2Root
    $gid = ('PA-S2-' + $Tag)
    $tid = ('pa-task-s2-' + $Tag).ToLowerInvariant()
    $wid = ('w-s2-' + $Tag)
    $sess = ('pa-session-s2-' + $Tag)
    $sv = New-PAActiveGoal $gid $f.goal
    if (-not [bool]$sv.ok) { throw "FAIL: S2 setup goal $gid" }
    $own = Acquire-OrchestrationGoalOwnership -GoalId $gid -OwnerId 'owner-s2' -ExpectedRevision ([long]$sv.revision) -StoreDir $f.goal
    if (-not [bool]$own.ok) { throw "FAIL: S2 setup ownership $gid" }
    $gen = [long]$own.ownership['generation']
    $t = New-OrchestrationTask -TaskId $tid -Objective 's2 canonical settle fixture' -Actor 'owner-s2' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -BaseRevision 'rev-a' -ReadScopes @('scope-a') -SettlementPolicy $Policy -AttemptBudget 3 -TasksDir $f.tasks -FlagsPath $f.flags -TelemetryRoot $f.tele
    if (-not [bool]$t.ok) { throw ("FAIL: S2 setup task " + $tid + " " + [string]$t.error) }
    $r1 = Invoke-OrchestrationTaskTransition -TaskId $tid -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision ([int]$t.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $f.tasks -FlagsPath $f.flags -TelemetryRoot $f.tele
    if (-not [bool]$r1.ok) { throw "FAIL: S2 setup planning $tid" }
    $r2 = Invoke-OrchestrationTaskTransition -TaskId $tid -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision ([int]$r1.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $f.tasks -FlagsPath $f.flags -TelemetryRoot $f.tele
    if (-not [bool]$r2.ok) { throw "FAIL: S2 setup implementing $tid" }
    $grev = [long](Get-OrchestrationGoal -GoalId $gid -StoreDir $f.goal).goal['revision']
    $add = Add-OrchestrationGoalTaskPersisted -GoalId $gid -TaskId $tid -ExpectedRevision $grev -StoreDir $f.goal -OwnerId 'owner-s2' -OwnershipGeneration $gen
    if (-not [bool]$add.ok) { throw "FAIL: S2 setup attach $tid" }
    $ev = (New-OrchestrationObjectiveEvent -GoalId $gid -Type 'task-settled' -WorkItemId $wid -ActionRevision 1).event
    $grevLive = [long](Get-OrchestrationGoal -GoalId $gid -StoreDir $f.goal).goal['revision']
    $res = Invoke-ProductiveObjectiveEvent -Event $ev -GoalStoreDir $f.goal -DispatchStoreDir $f.dispatch -CheckpointStoreDir $f.ckpt -TasksDir $f.tasks -FlagsPath $f.flags -TelemetryRoot $f.tele -TaskId $tid -AttemptRole 'coder' -SessionId $sess -OwnerId 'owner-s2' -Generation $gen -ExpectedRevision $grevLive -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Productive
    if ((-not [bool]$res.ok) -or (-not [bool]$res.dispatched) -or ([string]$res.decision -cne 'settlement-pending')) { throw "FAIL: S2 setup dispatch $tid" }
    $ndk = Get-NativeDispatchHash32 ('s2-key-' + $Tag)
    $ph = Get-NativeDispatchHash32 ('s2-prompt-' + $Tag)
    $ni = New-OrchestrationNativeDispatchIntent -TaskId $tid -TaskExpectedRevision 4 -Agent 'coder' -PromptHash $ph -Scope @('scope-a') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $ndk -Owner 'owner-s2' -OwnershipGeneration $gen -BaseRevision 'rev-a'
    if (-not [bool]$ni.ok) { throw ("FAIL: S2 setup intent " + $tid + " " + [string]$ni.reason) }
    $authND = @{ explicit_allow = $true; goal_id = $gid; owner = 'owner-s2'; generation = $gen; source = 'planner' }
    $p = Invoke-OrchestrationNativeDispatchPrepare -Intent $ni.intent -Authorization $authND -SessionId $sess -ReceiptDir $f.receipt -GoalStoreDir $f.goal -TasksDir $f.tasks -FlagsPath $f.flags
    if (-not [bool]$p.ok) { throw ("FAIL: S2 setup prepare " + $tid + " " + [string]$p.reason) }
    $msg = ('msg-s2-' + $Tag)
    $call = ('call-s2-' + $Tag)
    $child = ('ses-s2-' + $Tag + '-child')
    $c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $ndk -Authorization $authND -SessionId $sess -MessageId $msg -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p.prepared_fingerprint) -ReceiptDir $f.receipt -GoalStoreDir $f.goal -TasksDir $f.tasks -FlagsPath $f.flags
    if (-not [bool]$c.ok) { throw ("FAIL: S2 setup claim " + $tid + " " + [string]$c.reason) }
    $goalRev = [long](Get-OrchestrationGoal -GoalId $gid -StoreDir $f.goal).goal['revision']
    $ctx = @{
        task_id = $tid; receipt_root = $f.receipt; idempotency_key = $ndk
        prepared_fingerprint = ([string]$p.prepared_fingerprint)
        parent_session_id = $sess; message_id = $msg; call_id = $call
        caller_agent = 'planner'; target_agent = 'coder'; child_session_id = $child
        goal_id = $gid; owner = 'owner-s2'; generation = $gen
        goal_store_dir = $f.goal; evidence_store_dir = $f.evidence
        reference = ([string]$p.reference); goal_revision = $goalRev
        status = 'candidate_pass'; produced_by = 'coder'; claimed_evidence = @('criterion:0')
        authorization = @{ explicit_allow = $true; goal_id = $gid; owner = 'owner-s2'; generation = $gen; source = 'planner' }
    }
    return @{ f = $f; gid = $gid; tid = $tid; wid = $wid; sess = $sess; gen = $gen; ndk = $ndk; msg = $msg; call = $call; child = $child; prep = $p; claim = $c; ctx = $ctx }
}
# S2-1: delegation to the canonical owner with a real receipt fixture.
$fx1 = New-S2Fixture -Tag 'f1'
$snap1 = Get-OrchestrationDispatchIntent -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -StoreDir $fx1.f.dispatch
Assert-PAThat ([bool]$snap1.ok) 'S2 canonical fixture intent readable'
$live1 = Get-OrchestrationGoal -GoalId $fx1.gid -StoreDir $fx1.f.goal
$authS1 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource $fx1.wid -Decision 'settlement'
$trk1 = New-PATracker $null
$st1 = New-ProductiveSettleImpl -TaskId $fx1.tid -AttemptRole 'coder' -SessionId $fx1.sess -TasksDir $fx1.f.tasks -FlagsPath $fx1.f.flags -TelemetryRoot $fx1.f.tele -OwnerId 'owner-s2' -Generation $fx1.gen -GoalStoreDir $fx1.f.goal -DispatchStoreDir $fx1.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker $trk1 -NativeSettlement $fx1.ctx -Productive
Assert-PAThat ([bool]$st1.ok) 'S2 canonical settle ctor ok'
$revBefore1 = Get-PATaskRev $fx1.tid $fx1.f.tasks
Assert-PAThat ($revBefore1 -eq 4) 'S2 fixture pre-settle rev 4'
$r1 = & $st1.impl $snap1.intent $snap1.intent['receipt'] $live1.goal $authS1
Assert-PAThat ((($null -ne $r1) -and [bool]$r1.ok) -and ([string]$r1.reason -ceq 'productive-settle-canonical')) 'S2 PA delegates once to ND-Settle (canonical receipt)'
Assert-PAThat (([bool]$r1.native_settled -and (-not [bool]$r1.native_duplicate)) -and ([string]$r1.worker_status -ceq 'candidate_pass')) 'S2 settle returns canonical ND lineage'
Assert-PAThat (((Get-PATaskRev $fx1.tid $fx1.f.tasks) -eq ($revBefore1 + 1)) -and (Test-PAWorkerResult $fx1.tid $fx1.f.tasks)) 'S2 kernel receives the single canonical write'
Assert-PAThat ([long]$trk1['settle'] -eq 1) 'S2 exactly one settle invocation'
# S2-2: identical retry is an idempotent duplicate; divergent candidate is conflict.
$r1dup = & $st1.impl $snap1.intent $snap1.intent['receipt'] $live1.goal $authS1
Assert-PAThat ((($null -ne $r1dup) -and [bool]$r1dup.ok) -and ([string]$r1dup.reason -ceq 'productive-settle-canonical-duplicate')) 'S2 identical retry is idempotent duplicate'
Assert-PAThat ((Get-PATaskRev $fx1.tid $fx1.f.tasks) -eq ($revBefore1 + 1)) 'S2 duplicate adds no revision'
$st1d = New-ProductiveSettleImpl -TaskId $fx1.tid -AttemptRole 'coder' -SessionId $fx1.sess -TasksDir $fx1.f.tasks -FlagsPath $fx1.f.flags -TelemetryRoot $fx1.f.tele -OwnerId 'owner-s2' -Generation $fx1.gen -GoalStoreDir $fx1.f.goal -DispatchStoreDir $fx1.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1') -Tracker (New-PATracker $null) -NativeSettlement $fx1.ctx -Productive
$r1d = & $st1d.impl $snap1.intent $snap1.intent['receipt'] $live1.goal $authS1
Assert-PAThat ($null -eq $r1d) 'S2 divergent candidate for same claim is conflict, never overwrite'
Assert-PAThat ((Get-PATaskRev $fx1.tid $fx1.f.tasks) -eq ($revBefore1 + 1)) 'S2 conflict writes nothing'
# S2-3: verification stays separate; projection observes candidate/persisted/verified/advanced.
$ver1 = Set-OrchestrationTaskVerification -TaskId $fx1.tid -VerifierEvidenceJson @{ status = 'verified_pass'; evidence = @('criterion:0:verified'); command_classes = @() } -ExpectedRevision ($revBefore1 + 1) -TasksDir $fx1.f.tasks -FlagsPath $fx1.f.flags
Assert-PAThat ([bool]$ver1.ok) 'S2 verification stays separate and writable'
$proj1 = Get-ProductiveSettlementProjection -TaskId $fx1.tid -TasksDir $fx1.f.tasks -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -ObjectiveStoreDir $fx1.f.dispatch
Assert-PAThat (([string]$proj1.candidate.state -ceq 'present') -and ([string]$proj1.persisted.state -ceq 'present')) 'S2 projection: candidate+persisted present'
Assert-PAThat (([string]$proj1.verified.state -ceq 'present') -and ([string]$proj1.advanced.state -ceq 'absent')) 'S2 projection: verified present, advanced absent (no advance-requires-verified rule)'
$advDirS = Get-NDAdvanceDir -RootDir $fx1.f.receipt -GoalId $fx1.gid
Assert-PAThat ([bool]$advDirS.ok) 'S2 advance dir resolves'
$advNextS = Get-NativeDispatchHash32 's2-f1-next'
$advW = Write-NDAdvanceRecord -AdvanceDir ([string]$advDirS.dir) -Ident ([string]$advDirS.ident) -Key $fx1.ndk -Record @{ schema_version = 1; ok = $true; reason = ''; goal_id = $fx1.gid; settled_key = $fx1.ndk; move = 'CONTINUE'; move_reason = ''; stop_reason = ''; prepared = $true; next_idempotency_key = $advNextS; next_task_id = 'pa-task-s2-next'; next_agent = 'coder'; goal_state = 'ACTIVE' }
Assert-PAThat ([bool]$advW) 'S2 advance record persists via real writer'
$proj1b = Get-ProductiveSettlementProjection -TaskId $fx1.tid -TasksDir $fx1.f.tasks -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -ObjectiveStoreDir $fx1.f.dispatch -AdvanceDir ([string]$advDirS.dir) -AdvanceKey $fx1.ndk
Assert-PAThat (([string]$proj1b.advanced.state -ceq 'present') -and ([string]$proj1b.advanced.ref -ceq 'nd-advance:CONTINUE:prepared')) 'S2 projection: advanced present from prepared CONTINUE record'
$advKeyPend = Get-NativeDispatchHash32 's2-f1-pend'
$advWP = Write-NDAdvanceRecord -AdvanceDir ([string]$advDirS.dir) -Ident ([string]$advDirS.ident) -Key $advKeyPend -Record @{ schema_version = 1; ok = $true; reason = ''; goal_id = $fx1.gid; settled_key = $advKeyPend; move = 'RETRY'; move_reason = 'retry'; stop_reason = ''; prepared = $false; goal_state = 'ACTIVE' }
Assert-PAThat ([bool]$advWP) 'S2 pending advance record persists'
$projPend = Get-ProductiveSettlementProjection -TaskId $fx1.tid -TasksDir $fx1.f.tasks -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -ObjectiveStoreDir $fx1.f.dispatch -AdvanceDir ([string]$advDirS.dir) -AdvanceKey $advKeyPend
Assert-PAThat (([string]$projPend.advanced.state -ceq 'pending') -and ([string]$projPend.advanced.ref -ceq 'nd-advance:RETRY:unprepared')) 'S2 projection: unprepared RETRY is pending, never present'
$advKeyBlk = Get-NativeDispatchHash32 's2-f1-block'
$advWB = Write-NDAdvanceRecord -AdvanceDir ([string]$advDirS.dir) -Ident ([string]$advDirS.ident) -Key $advKeyBlk -Record @{ schema_version = 1; goal_id = $fx1.gid; settled_key = $advKeyBlk; move = 'BLOCKED'; move_reason = 'admit-x'; prepared = $false; goal_state = 'ACTIVE' }
Assert-PAThat ([bool]$advWB) 'S2 blocked advance record persists'
$projBlk = Get-ProductiveSettlementProjection -TaskId $fx1.tid -TasksDir $fx1.f.tasks -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -ObjectiveStoreDir $fx1.f.dispatch -AdvanceDir ([string]$advDirS.dir) -AdvanceKey $advKeyBlk
Assert-PAThat (([string]$projBlk.advanced.state -ceq 'blocked') -and ([string]$projBlk.advanced.ref -ceq 'nd-advance:blocked:admit-x')) 'S2 projection: BLOCKED is blocked, never present'
$advKeyFail = Get-NativeDispatchHash32 's2-f1-fail'
$advWF = Write-NDAdvanceRecord -AdvanceDir ([string]$advDirS.dir) -Ident ([string]$advDirS.ident) -Key $advKeyFail -Record @{ schema_version = 1; ok = $false; reason = 'advance-prepare-refused:x'; goal_id = $fx1.gid; settled_key = $advKeyFail; move = 'CONTINUE'; prepared = $false; goal_state = 'ACTIVE' }
Assert-PAThat ([bool]$advWF) 'S2 failed advance record persists'
$projFail = Get-ProductiveSettlementProjection -TaskId $fx1.tid -TasksDir $fx1.f.tasks -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -ObjectiveStoreDir $fx1.f.dispatch -AdvanceDir ([string]$advDirS.dir) -AdvanceKey $advKeyFail
Assert-PAThat (([string]$projFail.advanced.state -ceq 'failed') -and ([string]$projFail.advanced.ref -ceq 'nd-advance:failed:advance-prepare-refused:x')) 'S2 projection: failed advance is failed, never present'
$advKeyDone = Get-NativeDispatchHash32 's2-f1-done'
$advWD = Write-NDAdvanceRecord -AdvanceDir ([string]$advDirS.dir) -Ident ([string]$advDirS.ident) -Key $advKeyDone -Record @{ schema_version = 1; ok = $true; reason = ''; goal_id = $fx1.gid; settled_key = $advKeyDone; move = 'COMPLETE'; prepared = $false; finalize_reason = 'goal-finalization-not-requested'; goal_state = 'ACTIVE' }
Assert-PAThat ([bool]$advWD) 'S2 COMPLETE advance record persists'
$projDone = Get-ProductiveSettlementProjection -TaskId $fx1.tid -TasksDir $fx1.f.tasks -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -ObjectiveStoreDir $fx1.f.dispatch -AdvanceDir ([string]$advDirS.dir) -AdvanceKey $advKeyDone
Assert-PAThat (([string]$projDone.advanced.state -ceq 'present') -and ([string]$projDone.advanced.ref -ceq 'nd-advance:COMPLETE:goal-finalization-not-requested')) 'S2 projection: COMPLETE is present'
$advKeyOther = Get-NativeDispatchHash32 's2-f1-other'
$advWO = Write-NDAdvanceRecord -AdvanceDir ([string]$advDirS.dir) -Ident ([string]$advDirS.ident) -Key $advKeyOther -Record @{ schema_version = 1; ok = $true; reason = ''; goal_id = 'PA-S2-OTHER'; settled_key = $advKeyOther; move = 'CONTINUE'; prepared = $true; next_idempotency_key = $advNextS; next_task_id = 't'; next_agent = 'coder'; goal_state = 'ACTIVE' }
Assert-PAThat ([bool]$advWO) 'S2 foreign-goal advance record persists'
$projOther = Get-ProductiveSettlementProjection -TaskId $fx1.tid -TasksDir $fx1.f.tasks -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -ObjectiveStoreDir $fx1.f.dispatch -AdvanceDir ([string]$advDirS.dir) -AdvanceKey $advKeyOther
Assert-PAThat (([string]$projOther.advanced.state -ceq 'unknown') -and ([string]$projOther.advanced.ref -ceq 'nd-advance:correlation-mismatch')) 'S2 projection: foreign-goal record is unknown, never present'
$orKey = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'PA-S2-ORADV' -WorkItemId 'w-s2-oradv' -ActionRevision 1
$orPath = Get-ORIntentFilePath -Dir $fx1.f.dispatch -GoalId 'PA-S2-ORADV' -WorkItemId 'w-s2-oradv' -ActionRevision 1
Write-PAFile -Path $orPath -Text (ConvertTo-Json -InputObject @{ schema_version = 1; key = $orKey; goal_id = 'PA-S2-ORADV'; work_item_id = 'w-s2-oradv'; action_revision = [long]1; state = 'advanced'; generation = [long]1 } -Depth 10 -Compress)
$projOR = Get-ProductiveSettlementProjection -TaskId $fx1.tid -TasksDir $fx1.f.tasks -GoalId 'PA-S2-ORADV' -WorkItemId 'w-s2-oradv' -ActionRevision 1 -ObjectiveStoreDir $fx1.f.dispatch
Assert-PAThat (([string]$projOR.advanced.state -ceq 'present') -and ([string]$projOR.advanced.ref -ceq 'objective-runtime:advanced')) 'S2 projection: OR advanced intent stays present'
$projU = Get-ProductiveSettlementProjection -TaskId 'pa-task-s2-ghost' -TasksDir $fx1.f.tasks
Assert-PAThat (([string]$projU.candidate.state -ceq 'unknown') -and ([string]$projU.advanced.state -ceq 'unknown')) 'S2 projection: unknown with no legible proof'
# S2-4: HOLD without native context, zero writes.
$fx2 = New-S2Fixture -Tag 'f2'
$snap2 = Get-OrchestrationDispatchIntent -GoalId $fx2.gid -WorkItemId $fx2.wid -ActionRevision 1 -StoreDir $fx2.f.dispatch
$live2 = Get-OrchestrationGoal -GoalId $fx2.gid -StoreDir $fx2.f.goal
$authS2 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource $fx2.wid -Decision 'settlement'
$st2 = New-ProductiveSettleImpl -TaskId $fx2.tid -AttemptRole 'coder' -SessionId $fx2.sess -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags -TelemetryRoot $fx2.f.tele -OwnerId 'owner-s2' -Generation $fx2.gen -GoalStoreDir $fx2.f.goal -DispatchStoreDir $fx2.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -Productive
$r2 = & $st2.impl $snap2.intent $snap2.intent['receipt'] $live2.goal $authS2
Assert-PAThat ($null -eq $r2) 'S2 HOLD without native context'
Assert-PAThat (((Get-PATaskRev $fx2.tid $fx2.f.tasks) -eq 4) -and (-not (Test-PAWorkerResult $fx2.tid $fx2.f.tasks))) 'S2 HOLD writes zero to the kernel'
# S2-5: divergent native context => HOLD/recusa, zero writes, zero ND calls surtindo efeito.
$fx3 = New-S2Fixture -Tag 'f3'
$snap3 = Get-OrchestrationDispatchIntent -GoalId $fx3.gid -WorkItemId $fx3.wid -ActionRevision 1 -StoreDir $fx3.f.dispatch
$live3 = Get-OrchestrationGoal -GoalId $fx3.gid -StoreDir $fx3.f.goal
$authS3 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource $fx3.wid -Decision 'settlement'
function Copy-S2Ctx {
    param($Src)
    $d = @{}
    foreach ($kk in @($Src.Keys)) { $d[$kk] = $Src[$kk] }
    return $d
}
function Add-S2ReceiptLoc {
    param($Ctx, [string]$ReceiptRoot = '', [string]$GoalId = '')
    $d = Copy-S2Ctx $Ctx
    try {
        $st = Resolve-NDGoalReceiptDir -RootDir $ReceiptRoot -GoalId $GoalId
        $d['receipt_dir'] = [string](Get-PAFieldValue $st 'dir' '')
        $d['receipt_ident'] = [string](Get-PAFieldValue $st 'created_utc' '')
    }
    catch { }
    return $d
}
$ctxTaskDiv = Copy-S2Ctx $fx3.ctx
$ctxTaskDiv['task_id'] = 'pa-task-s2-other'
$st3a = New-ProductiveSettleImpl -TaskId $fx3.tid -AttemptRole 'coder' -SessionId $fx3.sess -TasksDir $fx3.f.tasks -FlagsPath $fx3.f.flags -TelemetryRoot $fx3.f.tele -OwnerId 'owner-s2' -Generation $fx3.gen -GoalStoreDir $fx3.f.goal -DispatchStoreDir $fx3.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -NativeSettlement $ctxTaskDiv -Productive
Assert-PAThat ($null -eq (& $st3a.impl $snap3.intent $snap3.intent['receipt'] $live3.goal $authS3)) 'S2 divergent context task => HOLD before any ND call'
$ctxSessDiv = Copy-S2Ctx $fx3.ctx
$ctxSessDiv['parent_session_id'] = 'pa-session-s2-other'
$st3b = New-ProductiveSettleImpl -TaskId $fx3.tid -AttemptRole 'coder' -SessionId $fx3.sess -TasksDir $fx3.f.tasks -FlagsPath $fx3.f.flags -TelemetryRoot $fx3.f.tele -OwnerId 'owner-s2' -Generation $fx3.gen -GoalStoreDir $fx3.f.goal -DispatchStoreDir $fx3.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -NativeSettlement $ctxSessDiv -Productive
Assert-PAThat ($null -eq (& $st3b.impl $snap3.intent $snap3.intent['receipt'] $live3.goal $authS3)) 'S2 divergent context run/session => HOLD before any ND call'
$ctxFpDiv = Copy-S2Ctx $fx3.ctx
$ctxFpDiv['prepared_fingerprint'] = Get-NativeDispatchHash32 's2-other-fingerprint'
$st3c = New-ProductiveSettleImpl -TaskId $fx3.tid -AttemptRole 'coder' -SessionId $fx3.sess -TasksDir $fx3.f.tasks -FlagsPath $fx3.f.flags -TelemetryRoot $fx3.f.tele -OwnerId 'owner-s2' -Generation $fx3.gen -GoalStoreDir $fx3.f.goal -DispatchStoreDir $fx3.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -NativeSettlement $ctxFpDiv -Productive
Assert-PAThat ($null -eq (& $st3c.impl $snap3.intent $snap3.intent['receipt'] $live3.goal $authS3)) 'S2 divergent fingerprint => ND refuses, zero kernel writes'
Assert-PAThat (((Get-PATaskRev $fx3.tid $fx3.f.tasks) -eq 4) -and (-not (Test-PAWorkerResult $fx3.tid $fx3.f.tasks))) 'S2 divergent contexts leave rev 4 with no worker result'
# S2-6: marked task refuses non-canonical writers; canonical context writes once.
$fx4 = New-S2Fixture -Tag 'f4'
$wNoCtx = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele
Assert-PAThat ((($null -ne $wNoCtx) -and (-not [bool]$wNoCtx.ok)) -and ([string]$wNoCtx.error -ceq 'SETTLEMENT_CONTEXT_MISSING')) 'S2 marked task refuses writer without context'
Assert-PAThat ((Get-PATaskRev $fx4.tid $fx4.f.tasks) -eq 4) 'S2 context-missing refusal writes zero'
$wEmpty = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele -SettlementContext @{}
Assert-PAThat ((($null -ne $wEmpty) -and (-not [bool]$wEmpty.ok)) -and ([string]$wEmpty.error -ceq 'SETTLEMENT_CONTEXT_INCOMPLETE')) 'S2 marked task refuses incomplete context'
$ctxDiv4 = Add-S2ReceiptLoc (Copy-S2Ctx $fx4.ctx) -ReceiptRoot $fx4.f.receipt -GoalId $fx4.gid
$ctxDiv4['target_agent'] = 'reviewer'
$wDiv = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele -SettlementContext $ctxDiv4
Assert-PAThat ((($null -ne $wDiv) -and (-not [bool]$wDiv.ok)) -and ([string]$wDiv.error -ceq 'SETTLEMENT_CONTEXT_UNVERIFIED')) 'S2 marked task refuses divergent context (no matching claim proof)'
Assert-PAThat (([string]$wDiv.detail -ceq 'proof-intent-mismatch') -and ((Get-PATaskRev $fx4.tid $fx4.f.tasks) -eq 4)) 'S2 divergent-context refusal writes zero'
$wCanon = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele -SettlementContext $fx4.ctx
Assert-PAThat ((($null -ne $wCanon) -and (-not [bool]$wCanon.ok)) -and ([string]$wCanon.error -ceq 'SETTLEMENT_CONTEXT_UNVERIFIED')) 'S2 fabricated context without receipt location is refused'
Assert-PAThat (((Get-PATaskRev $fx4.tid $fx4.f.tasks) -eq 4) -and (-not (Test-PAWorkerResult $fx4.tid $fx4.f.tasks))) 'S2 fabricated-context refusal writes zero'
# S2-6b: real claimed receipt but WITHOUT attempt/evidence markers => no proof.
$ctxNoMark = Add-S2ReceiptLoc (Copy-S2Ctx $fx4.ctx) -ReceiptRoot $fx4.f.receipt -GoalId $fx4.gid
$wNoMark = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele -SettlementContext $ctxNoMark
Assert-PAThat ((($null -ne $wNoMark) -and (-not [bool]$wNoMark.ok)) -and ([string]$wNoMark.error -ceq 'SETTLEMENT_CONTEXT_UNVERIFIED')) 'S2 claimed receipt without attempt markers proves nothing'
Assert-PAThat (([string]$wNoMark.detail -ceq 'proof-attempt-mismatch') -and ((Get-PATaskRev $fx4.tid $fx4.f.tasks) -eq 4)) 'S2 markerless receipt writes zero'
# S2-6c: transplanted key/fingerprint/goal/receipt => proof fails, zero writes.
$ctxNoKey = Add-S2ReceiptLoc (Copy-S2Ctx $fx4.ctx) -ReceiptRoot $fx4.f.receipt -GoalId $fx4.gid
$ctxNoKey['idempotency_key'] = Get-NativeDispatchHash32 's2-no-such-claim'
$wNoKey = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele -SettlementContext $ctxNoKey
Assert-PAThat ((($null -ne $wNoKey) -and (-not [bool]$wNoKey.ok)) -and ([string]$wNoKey.error -ceq 'SETTLEMENT_CONTEXT_UNVERIFIED')) 'S2 transplanted key without receipt is refused'
Assert-PAThat (([string]$wNoKey.detail -ceq 'proof-receipt-absent') -and ((Get-PATaskRev $fx4.tid $fx4.f.tasks) -eq 4)) 'S2 absent-receipt proof writes zero'
$ctxFpNo = Add-S2ReceiptLoc (Copy-S2Ctx $fx4.ctx) -ReceiptRoot $fx4.f.receipt -GoalId $fx4.gid
$ctxFpNo['prepared_fingerprint'] = Get-NativeDispatchHash32 's2-other-fingerprint'
$wFpNo = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele -SettlementContext $ctxFpNo
Assert-PAThat ((($null -ne $wFpNo) -and (-not [bool]$wFpNo.ok)) -and ([string]$wFpNo.error -ceq 'SETTLEMENT_CONTEXT_UNVERIFIED')) 'S2 divergent fingerprint is refused'
Assert-PAThat (([string]$wFpNo.detail -ceq 'proof-intent-mismatch') -and ((Get-PATaskRev $fx4.tid $fx4.f.tasks) -eq 4)) 'S2 fingerprint-mismatch proof writes zero'
$ctxGoalNo = Copy-S2Ctx $fx4.ctx
$ctxGoalNo['goal_id'] = 'PA-S2-OTHER'
$wGoalNo = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele -SettlementContext $ctxGoalNo
Assert-PAThat ((($null -ne $wGoalNo) -and (-not [bool]$wGoalNo.ok)) -and ([string]$wGoalNo.error -ceq 'SETTLEMENT_GOAL_READ_FAILED')) 'S2 transplanted goal fails the live goal read'
Assert-PAThat ((Get-PATaskRev $fx4.tid $fx4.f.tasks) -eq 4) 'S2 transplanted-goal refusal writes zero'
$ctxXTask = Add-S2ReceiptLoc (Copy-S2Ctx $fx3.ctx) -ReceiptRoot $fx3.f.receipt -GoalId $fx3.gid
$wXTask = Set-OrchestrationTaskWorkerResult -TaskId $fx4.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx4.f.tasks -FlagsPath $fx4.f.flags -TelemetryRoot $fx4.f.tele -SettlementContext $ctxXTask
Assert-PAThat ((($null -ne $wXTask) -and (-not [bool]$wXTask.ok)) -and ([string]$wXTask.error -ceq 'SETTLEMENT_CONTEXT_UNVERIFIED')) 'S2 receipt transplanted from another task fails the proof'
Assert-PAThat (([string]$wXTask.detail -ceq 'proof-intent-mismatch') -and ((Get-PATaskRev $fx4.tid $fx4.f.tasks) -eq 4)) 'S2 cross-task transplant writes zero'
# S2-7: fencing/lease stale => HOLD, zero writes.
$fx5a = New-S2Fixture -Tag 'f5a'
$snap5a = Get-OrchestrationDispatchIntent -GoalId $fx5a.gid -WorkItemId $fx5a.wid -ActionRevision 1 -StoreDir $fx5a.f.dispatch
$liveRev5a = [long](Get-OrchestrationGoal -GoalId $fx5a.gid -StoreDir $fx5a.f.goal).goal['revision']
$fin5a = Set-OrchestrationGoalStatePersisted -GoalId $fx5a.gid -ToState 'COMPLETED' -ExpectedRevision $liveRev5a -StoreDir $fx5a.f.goal -OwnerId 'owner-s2' -OwnershipGeneration $fx5a.gen
Assert-PAThat ([bool]$fin5a.ok) 'S2 fencing fixture goal completed persisted'
$live5a = Get-OrchestrationGoal -GoalId $fx5a.gid -StoreDir $fx5a.f.goal
$authS5a = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource $fx5a.wid -Decision 'settlement'
$st5a = New-ProductiveSettleImpl -TaskId $fx5a.tid -AttemptRole 'coder' -SessionId $fx5a.sess -TasksDir $fx5a.f.tasks -FlagsPath $fx5a.f.flags -TelemetryRoot $fx5a.f.tele -OwnerId 'owner-s2' -Generation $fx5a.gen -GoalStoreDir $fx5a.f.goal -DispatchStoreDir $fx5a.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -NativeSettlement $fx5a.ctx -Productive
Assert-PAThat ($null -eq (& $st5a.impl $snap5a.intent $snap5a.intent['receipt'] $live5a.goal $authS5a)) 'S2 terminal goal => fencing HOLD, zero writes'
Assert-PAThat (((Get-PATaskRev $fx5a.tid $fx5a.f.tasks) -eq 4) -and (-not (Test-PAWorkerResult $fx5a.tid $fx5a.f.tasks))) 'S2 terminal fencing leaves rev 4 with no worker result'
$fx5b = New-S2Fixture -Tag 'f5b'
$snap5b = Get-OrchestrationDispatchIntent -GoalId $fx5b.gid -WorkItemId $fx5b.wid -ActionRevision 1 -StoreDir $fx5b.f.dispatch
$live5b0 = Get-OrchestrationGoal -GoalId $fx5b.gid -StoreDir $fx5b.f.goal
$authS5b = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource $fx5b.wid -Decision 'settlement'
$ren5b = Renew-OrchestrationGoalOwnership -GoalId $fx5b.gid -OwnerId 'owner-s2' -Generation $fx5b.gen -StoreDir $fx5b.f.goal -LeaseTtlMs 1
Assert-PAThat ([bool]$ren5b.ok) 'S2 lease fixture renewed with minimal TTL'
Start-Sleep -Milliseconds 300
$st5b = New-ProductiveSettleImpl -TaskId $fx5b.tid -AttemptRole 'coder' -SessionId $fx5b.sess -TasksDir $fx5b.f.tasks -FlagsPath $fx5b.f.flags -TelemetryRoot $fx5b.f.tele -OwnerId 'owner-s2' -Generation $fx5b.gen -GoalStoreDir $fx5b.f.goal -DispatchStoreDir $fx5b.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -NativeSettlement $fx5b.ctx -Productive
Assert-PAThat ($null -eq (& $st5b.impl $snap5b.intent $snap5b.intent['receipt'] $live5b0.goal $authS5b)) 'S2 expired lease => HOLD, zero writes'
Assert-PAThat (((Get-PATaskRev $fx5b.tid $fx5b.f.tasks) -eq 4) -and (-not (Test-PAWorkerResult $fx5b.tid $fx5b.f.tasks))) 'S2 lease expiry leaves rev 4 with no worker result'
# S2-8: ambiguous kernel commit => fail-closed, never advance.
# Simulates an ND-Settle interrupted between the kernel write and the
# 'settled' transition: attempt + evidence markers persisted on the
# still-claimed receipt (exactly what ND-Settle writes before the
# kernel), so the direct write passes the durable proof and lands.
$fx6 = New-S2Fixture -Tag 'f6'
$snap6 = Get-OrchestrationDispatchIntent -GoalId $fx6.gid -WorkItemId $fx6.wid -ActionRevision 1 -StoreDir $fx6.f.dispatch
$live6 = Get-OrchestrationGoal -GoalId $fx6.gid -StoreDir $fx6.f.goal
$authS6 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource $fx6.wid -Decision 'settlement'
$rp6dir = Get-NDGoalReceiptDir -RootDir $fx6.f.receipt -GoalId $fx6.gid
Assert-PAThat (-not [string]::IsNullOrWhiteSpace([string]$rp6dir)) 'S2 ambiguous fixture receipt dir resolves'
$rp6 = Join-Path ([string]$rp6dir) ($fx6.ndk + '.json')
$raw6 = ConvertFrom-Json ([IO.File]::ReadAllText($rp6, [Text.Encoding]::UTF8))
Add-Member -InputObject $raw6 -Name 'settle_attempt_status' -Value 'candidate_pass' -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_attempt_claimed_evidence' -Value @('criterion:0') -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_attempt_child_session_id' -Value ([string]$fx6.child) -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_attempt_session_id' -Value ([string]$fx6.sess) -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_attempt_message_id' -Value ([string]$fx6.msg) -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_attempt_call_id' -Value ([string]$fx6.call) -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_attempt_caller_agent' -Value 'planner' -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_attempt_target_agent' -Value 'coder' -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_attempt_at' -Value ([DateTime]::UtcNow.ToString('o')) -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_evidence_created' -Value $true -MemberType NoteProperty -Force
Add-Member -InputObject $raw6 -Name 'settle_evidence_id' -Value (Get-NativeDispatchHash32 's2-f6-evidence') -MemberType NoteProperty -Force
Write-PAFile -Path $rp6 -Text (ConvertTo-Json -InputObject $raw6 -Depth 20 -Compress)
$ctx6 = Add-S2ReceiptLoc (Copy-S2Ctx $fx6.ctx) -ReceiptRoot $fx6.f.receipt -GoalId $fx6.gid
$wAmb = Set-OrchestrationTaskWorkerResult -TaskId $fx6.tid -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $fx6.f.tasks -FlagsPath $fx6.f.flags -TelemetryRoot $fx6.f.tele -SettlementContext $ctx6
Assert-PAThat ((($null -ne $wAmb) -and [bool]$wAmb.ok) -and ([long]$wAmb.revision -eq 5)) 'S2 ambiguous fixture: proven kernel write lands (rev 5, receipt still claimed)'
$st6 = New-ProductiveSettleImpl -TaskId $fx6.tid -AttemptRole 'coder' -SessionId $fx6.sess -TasksDir $fx6.f.tasks -FlagsPath $fx6.f.flags -TelemetryRoot $fx6.f.tele -OwnerId 'owner-s2' -Generation $fx6.gen -GoalStoreDir $fx6.f.goal -DispatchStoreDir $fx6.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -NativeSettlement $fx6.ctx -Productive
Assert-PAThat ($null -eq (& $st6.impl $snap6.intent $snap6.intent['receipt'] $live6.goal $authS6)) 'S2 ambiguous commit stays fail-closed/manual (no advance, no rewrite)'
Assert-PAThat ((Get-PATaskRev $fx6.tid $fx6.f.tasks) -eq 5) 'S2 ambiguous commit writes nothing new'
# S2-9: unmarked task keeps the legacy contract (context ignored).
$f7 = New-S2Root
$sv7 = New-PAActiveGoal 'PA-S2-F7' $f7.goal
$own7 = Acquire-OrchestrationGoalOwnership -GoalId 'PA-S2-F7' -OwnerId 'owner-s2' -ExpectedRevision ([long]$sv7.revision) -StoreDir $f7.goal
Assert-PAThat ([bool]$own7.ok) 'S2 legacy goal ownership acquired'
$t7 = New-OrchestrationTask -TaskId 'pa-task-s2-f7' -Objective 's2 legacy task' -Actor 'owner-s2' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -TasksDir $f7.tasks -FlagsPath $f7.flags -TelemetryRoot $f7.tele
Assert-PAThat ([bool]$t7.ok) 'S2 legacy task created unmarked'
$r71 = Invoke-OrchestrationTaskTransition -TaskId 'pa-task-s2-f7' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision ([int]$t7.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $f7.tasks -FlagsPath $f7.flags -TelemetryRoot $f7.tele
$r72 = Invoke-OrchestrationTaskTransition -TaskId 'pa-task-s2-f7' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision ([int]$r71.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $f7.tasks -FlagsPath $f7.flags -TelemetryRoot $f7.tele
Assert-PAThat ([bool]$r72.ok) 'S2 legacy task implementing'
$wLeg = Set-OrchestrationTaskWorkerResult -TaskId 'pa-task-s2-f7' -Status 'failed' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $f7.tasks -FlagsPath $f7.flags -TelemetryRoot $f7.tele
Assert-PAThat ((($null -ne $wLeg) -and [bool]$wLeg.ok) -and ([long]$wLeg.revision -eq 4)) 'S2 unmarked task keeps legacy direct write'
$wLegCtx = Set-OrchestrationTaskWorkerResult -TaskId 'pa-task-s2-f7' -Status 'blocked' -ClaimedEvidence @('criterion:1') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $f7.tasks -FlagsPath $f7.flags -TelemetryRoot $f7.tele -SettlementContext @{ task_id = 'x' }
Assert-PAThat ((($null -ne $wLegCtx) -and [bool]$wLegCtx.ok) -and ([long]$wLegCtx.revision -eq 5)) 'S2 unmarked task ignores stray context (legacy contract)'
# S2-10: reconcile entry point threads the native context to the canonical owner.
$fx8 = New-S2Fixture -Tag 'f8'
$key8 = Get-OrchestrationObjectiveIdempotencyKey -GoalId $fx8.gid -WorkItemId $fx8.wid -ActionRevision 1
$sProof8 = @{ destination = 'task-kernel'; action = 'worker-result'; fencing_owner = 'owner-s2'; fencing_generation = $fx8.gen; idempotency_key = $key8 }
$revLive8 = [long](Get-OrchestrationGoal -GoalId $fx8.gid -StoreDir $fx8.f.goal).goal['revision']
$trk8 = New-PATracker $null
$res8 = Invoke-ProductiveObjectiveReconcile -GoalId $fx8.gid -GoalStoreDir $fx8.f.goal -DispatchStoreDir $fx8.f.dispatch -TasksDir $fx8.f.tasks -FlagsPath $fx8.f.flags -TelemetryRoot $fx8.f.tele -TaskId $fx8.tid -AttemptRole 'coder' -SessionId $fx8.sess -OwnerId 'owner-s2' -Generation $fx8.gen -ExpectedRevision $revLive8 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker $trk8 -SettleProof $sProof8 -NativeSettlementContext $fx8.ctx -Productive
Assert-PAThat (([bool]$res8.ok -and ([long]$res8.reconciled -eq 1)) -and ([long]$res8.settled -eq 1)) 'S2 reconcile entry point settles once via canonical owner'
Assert-PAThat (((Get-PATaskRev $fx8.tid $fx8.f.tasks) -eq 5) -and (Test-PAWorkerResult $fx8.tid $fx8.f.tasks)) 'S2 entry-point settle writes the single canonical worker result (rev 4 to 5)'
$after8 = Get-OrchestrationDispatchIntent -GoalId $fx8.gid -WorkItemId $fx8.wid -ActionRevision 1 -StoreDir $fx8.f.dispatch
Assert-PAThat (([bool]$after8.ok -and ([string]$after8.intent['state'] -ceq 'settled')) -and ([string]$after8.intent['settlement_receipt'].idempotency_key -ceq $key8)) 'S2 entry-point settle persists bound settlement receipt in the diary'
# S2-11: GoalStoreDir omitido no ND-Settle => resolve o default e liquida.
$defGoal = Get-OrchestrationGoalStoreDir -StoreDir ''
Assert-PAThat (-not [string]::IsNullOrWhiteSpace($defGoal)) 'S2 default goal store resolves non-empty'
$f9 = New-S2Root
$gid9 = ('PA-S2-G3-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)).ToUpperInvariant())
$tid9 = ('pa-task-s2-g3-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)).ToLowerInvariant())
$wid9 = 'w-s2-g3'
$sess9 = 'pa-session-s2-g3'
$sv9 = New-PAActiveGoal $gid9 $defGoal
Assert-PAThat ([bool]$sv9.ok) 'S2 default-store goal created'
$own9 = Acquire-OrchestrationGoalOwnership -GoalId $gid9 -OwnerId 'owner-s2' -ExpectedRevision ([long]$sv9.revision) -StoreDir $defGoal
Assert-PAThat ([bool]$own9.ok) 'S2 default-store ownership acquired'
$gen9 = [long]$own9.ownership['generation']
$t9 = New-OrchestrationTask -TaskId $tid9 -Objective 's2 default store fixture' -Actor 'owner-s2' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -BaseRevision 'rev-a' -ReadScopes @('scope-a') -SettlementPolicy 'canonical-native-settle' -AttemptBudget 3 -TasksDir $f9.tasks -FlagsPath $f9.flags -TelemetryRoot $f9.tele
Assert-PAThat ([bool]$t9.ok) 'S2 default-store task created marked'
$r91 = Invoke-OrchestrationTaskTransition -TaskId $tid9 -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision ([int]$t9.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $f9.tasks -FlagsPath $f9.flags -TelemetryRoot $f9.tele
$r92 = Invoke-OrchestrationTaskTransition -TaskId $tid9 -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision ([int]$r91.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $f9.tasks -FlagsPath $f9.flags -TelemetryRoot $f9.tele
Assert-PAThat ([bool]$r92.ok) 'S2 default-store task implementing'
$grev9 = [long](Get-OrchestrationGoal -GoalId $gid9 -StoreDir $defGoal).goal['revision']
$add9 = Add-OrchestrationGoalTaskPersisted -GoalId $gid9 -TaskId $tid9 -ExpectedRevision $grev9 -StoreDir $defGoal -OwnerId 'owner-s2' -OwnershipGeneration $gen9
Assert-PAThat ([bool]$add9.ok) 'S2 default-store task attached'
$ev9 = (New-OrchestrationObjectiveEvent -GoalId $gid9 -Type 'task-settled' -WorkItemId $wid9 -ActionRevision 1).event
$grevLive9 = [long](Get-OrchestrationGoal -GoalId $gid9 -StoreDir $defGoal).goal['revision']
$res9 = Invoke-ProductiveObjectiveEvent -Event $ev9 -GoalStoreDir $defGoal -DispatchStoreDir $f9.dispatch -CheckpointStoreDir $f9.ckpt -TasksDir $f9.tasks -FlagsPath $f9.flags -TelemetryRoot $f9.tele -TaskId $tid9 -AttemptRole 'coder' -SessionId $sess9 -OwnerId 'owner-s2' -Generation $gen9 -ExpectedRevision $grevLive9 -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Productive
Assert-PAThat (([bool]$res9.ok -and [bool]$res9.dispatched) -and ([string]$res9.decision -ceq 'settlement-pending')) 'S2 default-store dispatch stays pending'
$ndk9 = Get-NativeDispatchHash32 ('s2-key-g3-' + $gid9)
$ph9 = Get-NativeDispatchHash32 ('s2-prompt-g3-' + $gid9)
$ni9 = New-OrchestrationNativeDispatchIntent -TaskId $tid9 -TaskExpectedRevision 4 -Agent 'coder' -PromptHash $ph9 -Scope @('scope-a') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $ndk9 -Owner 'owner-s2' -OwnershipGeneration $gen9 -BaseRevision 'rev-a'
Assert-PAThat ([bool]$ni9.ok) 'S2 default-store intent ok'
$authND9 = @{ explicit_allow = $true; goal_id = $gid9; owner = 'owner-s2'; generation = $gen9; source = 'planner' }
$p9 = Invoke-OrchestrationNativeDispatchPrepare -Intent $ni9.intent -Authorization $authND9 -SessionId $sess9 -ReceiptDir $f9.receipt -TasksDir $f9.tasks -FlagsPath $f9.flags
Assert-PAThat ([bool]$p9.ok) 'S2 default-store prepare ok without GoalStoreDir'
$msg9 = 'msg-s2-g3'
$call9 = 'call-s2-g3'
$child9 = 'ses-s2-g3-child'
$c9 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $ndk9 -Authorization $authND9 -SessionId $sess9 -MessageId $msg9 -CallId $call9 -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p9.prepared_fingerprint) -ReceiptDir $f9.receipt -TasksDir $f9.tasks -FlagsPath $f9.flags
Assert-PAThat ([bool]$c9.ok) 'S2 default-store claim ok without GoalStoreDir'
$s9 = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $ndk9 -Authorization $authND9 -ChildSessionId $child9 -SessionId $sess9 -MessageId $msg9 -CallId $call9 -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p9.prepared_fingerprint) -TaskId $tid9 -Result @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } -ReceiptDir $f9.receipt -EvidenceStoreDir $f9.evidence -TasksDir $f9.tasks -FlagsPath $f9.flags
Assert-PAThat ((($null -ne $s9) -and [bool]$s9.ok) -and [bool]$s9.settled) 'S2 settle succeeds with omitted GoalStoreDir (resolved default in context)'
Assert-PAThat (((Get-PATaskRev $tid9 $f9.tasks) -eq 5) -and (Test-PAWorkerResult $tid9 $f9.tasks)) 'S2 omitted-store settle writes the canonical worker result'
try { $gf9 = Get-GKGoalFilePath -StoreDir $defGoal -GoalId $gid9; if (-not [string]::IsNullOrWhiteSpace($gf9)) { Remove-Item -LiteralPath $gf9 -Force -ErrorAction SilentlyContinue } } catch { }
try { Remove-Item -LiteralPath $f9.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rt.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rc.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rh.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rd.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rterm.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rn1.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rn2.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rn4.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rn5.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rn6.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rb.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rs.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $ro.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rr.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $rp.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx1.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx2.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx3.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx4.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx5a.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx5b.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx6.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $f7.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx8.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
'PASS: {0}' -f $passed
