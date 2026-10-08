[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationRuntimeAdapterContract.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveRuntime.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationProductiveActivation.ps1')
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
Assert-PAThat (([bool]$resT.ok -and [bool]$resT.dispatched) -and ([string]$resT.decision -ceq 'dispatched')) 'E2E productive dispatches'
Assert-PAThat (([string]$resT.intent_state -ceq 'advanced') -and ($null -ne $resT.receipt) -and ([string]$resT.receipt.idempotency_key -ceq $keyT)) 'E2E intent advanced with receipt bound to key'
Assert-PAThat (([string]$resT.receipt.destination -ceq 'task-kernel') -and ([string]$resT.receipt.action -ceq 'start-attempt') -and ([string]$resT.receipt.task_id -ceq 'pa-task-e2e-1') -and (-not [string]::IsNullOrWhiteSpace([string]$resT.receipt.run_id)) -and ([long]$resT.receipt.generation -eq 1) -and (-not [string]::IsNullOrWhiteSpace([string]$resT.receipt.result))) 'E2E receipt carries destination action task run generation result'
Assert-PAThat (($null -ne $resT.next_move) -and (-not [string]::IsNullOrWhiteSpace([string]$resT.checkpoint_id))) 'E2E checkpoint and next_move present'
Assert-PAThat ((([long]$resT.productive_dispatch_calls -eq 1) -and ([long]$resT.productive_settle_calls -eq 1)) -and ([long]$resT.productive_checkpoint_calls -ge 1)) 'E2E one dispatch one settle checkpoint recorded'
Assert-PAThat (([string]$resT.productive -ceq 'engaged') -and (-not [bool]$resT.grants_authority) -and (-not [bool]$resT.done_approved) -and (-not [bool]$resT.verified_pass)) 'E2E engaged claims no grants DONE or verified pass'
$ldT = Load-OrchestrationGoalCheckpoint -CheckpointId ([string]$resT.checkpoint_id) -StoreDir $rt.ckpt
Assert-PAThat ([bool]$ldT.ok) 'E2E checkpoint save/load real round-trip'
Assert-PAThat (((Get-PATaskRev 'pa-task-e2e-1' $rt.tasks) -eq 5) -and (Test-PAWorkerResult 'pa-task-e2e-1' $rt.tasks)) 'E2E exactly one kernel start plus one worker result (rev 3 to 5)'
# --- Duplicate same key => original receipt, no new effect.
$resD = Invoke-ProductiveObjectiveEvent -Event $evT -GoalStoreDir $rt.goal -DispatchStoreDir $rt.dispatch -CheckpointStoreDir $rt.ckpt -TasksDir $rt.tasks -FlagsPath $rt.flags -TelemetryRoot $rt.tele -TaskId 'pa-task-e2e-1' -AttemptRole 'coder' -SessionId 'pa-session-e2e' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revT -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Tracker $trk -Productive
Assert-PAThat ([bool]$resD.ok -and [bool]$resD.duplicate) 'DUP same key returns duplicate'
Assert-PAThat ((([long]$resD.productive_dispatch_calls -eq 1) -and ([long]$resD.productive_settle_calls -eq 1)) -and ((Get-PATaskRev 'pa-task-e2e-1' $rt.tasks) -eq 5)) 'DUP no new kernel effect'
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
Assert-PAThat (([bool]$resR.ok -and ([long]$resR.reconciled -eq 1)) -and (([long]$resR.settled -eq 1) -and ([long]$resR.redispatched -eq 0))) 'CRASH reconcile settles without redispatch'
Assert-PAThat ((([long]$resR.productive_reconcile_calls -eq 1) -and ([long]$resR.productive_settle_calls -eq 1)) -and ((Get-PATaskRev 'pa-task-crash-1' $rc.tasks) -eq 5)) 'CRASH recovery adds settle only, no new attempt (rev 4 to 5)'
$afterC = Get-OrchestrationDispatchIntent -GoalId 'PA-CRASH-1' -WorkItemId 'w-pa-crash-1' -ActionRevision 1 -StoreDir $rc.dispatch
Assert-PAThat (([bool]$afterC.ok -and ([string]$afterC.intent['state'] -ceq 'settled')) -and ([string]$afterC.intent['receipt'].idempotency_key -ceq $keyC)) 'CRASH intent settled with original dispatch receipt'
$trkR2 = New-PATracker $null
$resR2 = Invoke-ProductiveObjectiveReconcile -GoalId 'PA-CRASH-1' -GoalStoreDir $rc.goal -DispatchStoreDir $rc.dispatch -TasksDir $rc.tasks -FlagsPath $rc.flags -TelemetryRoot $rc.tele -TaskId 'pa-task-crash-1' -SessionId 'pa-session-crash' -OwnerId 'owner-pa-1' -Generation 1 -ExpectedRevision $revC -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Tracker $trkR2 -SettleProof $sProofC -Productive
Assert-PAThat (((-not [bool]$resR2.ok) -and ([string]$resR2.reason -ceq 'reconcile-no-admitted-intent')) -and (([long]$resR2.settled -eq 0) -and ([long]$resR2.productive_settle_calls -eq 0))) 'CRASH second recovery is an empty sweep (no re-effect)'
Assert-PAThat ((Get-PATaskRev 'pa-task-crash-1' $rc.tasks) -eq 5) 'CRASH second recovery leaves task rev 5'
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
Assert-PAThat (([bool]$resN5.ok -and ([long]$resN5.reconciled -eq 1)) -and ([long]$resN5.settled -eq 1)) 'NEG crash2 reconcile settles from destination record'
Assert-PAThat ((Get-PATaskRev 'pa-task-crash2' $rn5.tasks) -eq 5) 'NEG crash2 task rev 4 to 5 via recovery'
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
Assert-PAThat (([bool]$resO.ok -and ([string]$resO.intent_state -ceq 'advanced')) -and ([string]$resO.settlement -ceq 'settled')) 'R1 oldresult fixture settled'
$snapO = Get-OrchestrationDispatchIntent -GoalId 'PA-OLDRES-1' -WorkItemId 'w-oldres' -ActionRevision 1 -StoreDir $ro.dispatch
$liveO = Get-OrchestrationGoal -GoalId 'PA-OLDRES-1' -StoreDir $ro.goal
$authSO = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource 'w-oldres' -Decision 'settlement'
$stOld = New-ProductiveSettleImpl -TaskId 'pa-task-oldres-1' -AttemptRole 'coder' -SessionId 'pa-session-oldres' -TasksDir $ro.tasks -FlagsPath $ro.flags -TelemetryRoot $ro.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $ro.goal -DispatchStoreDir $ro.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:9:other-evidence') -Productive
Assert-PAThat ([bool]$stOld.ok) 'R1 oldresult divergent-evidence ctor ok'
$rOld = & $stOld.impl $snapO.intent $snapO.intent['receipt'] $liveO.goal $authSO
Assert-PAThat ($null -eq $rOld) 'R1 old result same status different evidence => no recovery'
$stSame = New-ProductiveSettleImpl -TaskId 'pa-task-oldres-1' -AttemptRole 'coder' -SessionId 'pa-session-oldres' -TasksDir $ro.tasks -FlagsPath $ro.flags -TelemetryRoot $ro.tele -OwnerId 'owner-pa-1' -Generation 1 -GoalStoreDir $ro.goal -DispatchStoreDir $ro.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:1:productive-settle') -Productive
Assert-PAThat ([bool]$stSame.ok) 'R1 oldresult same-evidence ctor ok'
$rSame = & $stSame.impl $snapO.intent $snapO.intent['receipt'] $liveO.goal $authSO
Assert-PAThat ((($null -ne $rSame) -and [bool]$rSame.ok) -and ([string]$rSame.reason -ceq 'productive-settle-recovered')) 'R1 same evidence recovers without new effect'
Assert-PAThat ((Get-PATaskRev 'pa-task-oldres-1' $ro.tasks) -eq 5) 'R1 recovery adds no new revision'
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
'PASS: {0}' -f $passed
