[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationRuntimeAdapterContract.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveRuntime.ps1')
$passed = 0
function Assert-ORThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
$TempBase = [IO.Path]::GetTempPath()
$ORGoalStore = Join-Path $TempBase ('or-goal-' + [guid]::NewGuid().ToString('N'))
$ORDispatchStore = Join-Path $TempBase ('or-dispatch-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($ORGoalStore)
[void][IO.Directory]::CreateDirectory($ORDispatchStore)
$script:dispatchCalls = 0
$script:settleCalls = 0
# D5 full grant set: one explicit allow per decision (dispatch, settlement,
# checkpoint, advance, terminalize, reconcile). No allow token => denied.
$script:GFull = 'ops allow:dispatch allow:settlement allow:checkpoint allow:advance allow:terminalize allow:reconcile'
function New-ORProof {
    param([string]$Key = '', [string]$Owner = '', [long]$Gen = 0, [string]$Dst = 'dest-stub', [string]$Act = 'act-stub')
    return @{ destination = $Dst; action = $Act; fencing_owner = $Owner; fencing_generation = $Gen; idempotency_key = $Key }
}
$script:fakeGen = 1
$FakeDispatch = { param($intent, $goal, $auth) $script:dispatchCalls++; return [pscustomobject]@{ ok = $true; dispatched = $true; task_id = 'fake-task'; run_id = 'fake-run'; destination = 'dest-stub'; action = 'act-stub'; operation = 'dispatch'; generation = $intent['generation']; result = 'fake-result'; idempotency_key = $intent['key']; reason = 'fake-dispatched' } }
$FakeSettle = { param($intent, $dispatch, $goal) $script:settleCalls++; $g = $intent['generation']; if ([long]$g -lt 1) { $g = $script:fakeGen }; return [pscustomobject]@{ ok = $true; task_id = 'fake-task'; run_id = 'fake-run'; destination = 'dest-stub'; action = 'act-stub'; operation = 'settlement'; generation = $g; result = 'fake-settled'; idempotency_key = $intent['key']; reason = 'fake-settled' } }
$FakeReconcile = { param($intent) return [pscustomobject]@{ ok = $true; effect_observed = $true; reason = 'fake-observed' } }
$FakeReconcileClean = { param($intent) return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $true; no_capable_request = $true; reason = 'fake-clean' } }
$FakeReconcileInconclusive = { param($intent) return [pscustomobject]@{ ok = $true; effect_observed = $false; reason = 'fake-inconclusive' } }
$FakeNoReceipt = { param($intent, $goal, $auth) $script:dispatchCalls++; return [pscustomobject]@{ ok = $true; dispatched = $true; reason = 'self-declared-only' } }
function New-ORActiveGoal {
    param([string]$Id)
    $n = New-OrchestrationGoal -GoalId $Id -Objective 'objective runtime' -Criteria @('c1', 'c2') -VerificationSurfaces @('suite-x') -SoftCap 10 -HardCap 20 -TotalPhases 2
    if (-not [bool]$n.ok) { throw "FAIL: setup new goal $Id" }
    $act = Set-OrchestrationGoalState -Goal $n.goal -ToState 'ACTIVE'
    if (-not [bool]$act.ok) { throw "FAIL: setup activate $Id" }
    $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $ORGoalStore
    if (-not [bool]$sv.ok) { throw "FAIL: setup save $Id" }
    return $sv
}
# --- VERSION: PR-2 contract identity.
$v = Get-OrchestrationObjectiveRuntimeVersion
Assert-ORThat (([long]$v.schema_version -eq 1) -and ([string]$v.phase -ceq 'PR-2')) 'VERSION schema 1 phase PR-2'
# --- EVENTS: constructor gates type and ids.
$e = New-OrchestrationObjectiveEvent -GoalId 'G2-001' -Type 'task-settled' -WorkItemId 'w-001' -ActionRevision 1
Assert-ORThat ([bool]$e.ok -and ([string]$e.event['type'] -ceq 'task-settled')) 'EVENT task-settled accepted'
$e = New-OrchestrationObjectiveEvent -GoalId 'G2-001' -Type 'busy-poll' -WorkItemId 'w-001' -ActionRevision 1
Assert-ORThat ((-not [bool]$e.ok) -and ([string]$e.reason -ceq 'unknown-event')) 'EVENT unknown type rejected (no polling event)'
$e = New-OrchestrationObjectiveEvent -GoalId 'bad id!' -Type 'task-settled' -WorkItemId 'w-001' -ActionRevision 1
Assert-ORThat ((-not [bool]$e.ok) -and ([string]$e.reason -ceq 'invalid-goal-id')) 'EVENT malformed goal rejected'
# --- (a) Task DONE event drives the next execution (G2).
$svA = New-ORActiveGoal 'G2-A'
$keyA = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-A' -WorkItemId 'task-done-1' -ActionRevision 1
$proofA = New-ORProof -Key $keyA -Owner 'owner-1' -Gen 1
$evA = (New-OrchestrationObjectiveEvent -GoalId 'G2-A' -Type 'task-settled' -WorkItemId 'task-done-1' -ActionRevision 1).event
$rA = Invoke-OrchestrationObjectiveEvent -Event $evA -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svA.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofA -SettleProof $proofA -TestCallback
Assert-ORThat ([bool]$rA.ok -and ([bool]$rA.dispatched) -and ([string]$rA.decision -ceq 'dispatched')) 'G2 task-settled dispatches next execution'
Assert-ORThat (($script:dispatchCalls -eq 1) -and ($script:settleCalls -eq 1)) 'G2 dispatch and settle each ran once'
Assert-ORThat (([string]$rA.settlement -ceq 'settled') -and ($null -ne $rA.next_move) -and ([string]$rA.next_move.move -ceq 'CONTINUE')) 'G2 settled task yields controller CONTINUE move'
Assert-ORThat (($null -ne $rA.consumed_move) -and (-not [string]::IsNullOrWhiteSpace([string]$rA.checkpoint_id))) 'G2 records consumed prior move and checkpoint'
Assert-ORThat ((-not [bool]$rA.grants_authority) -and (-not [bool]$rA.done_approved) -and (-not [bool]$rA.verified_pass)) 'G2 executor claims no grants DONE or verified pass'
Assert-ORThat (([string]$rA.intent_state -ceq 'advanced') -and ($null -ne $rA.receipt) -and ([string]$rA.receipt.idempotency_key -ceq $keyA)) 'G2 intent advanced with durable receipt bound to the key'
# --- (b) Duplicate events collapse to one logical dispatch.
$rB = Invoke-OrchestrationObjectiveEvent -Event $evA -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svA.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofA -SettleProof $proofA -TestCallback
Assert-ORThat ([bool]$rB.ok -and ([bool]$rB.duplicate) -and (-not [bool]$rB.dispatched) -and ($null -ne $rB.next_move)) 'DUPLICATE second event returns duplicate with the persisted replayed move (F5)'
Assert-ORThat (($script:dispatchCalls -eq 1) -and ($script:settleCalls -eq 1)) 'DUPLICATE dispatch impl not re-entered'
Assert-ORThat (($null -ne $rB.task_result) -and ([string]$rB.task_result.idempotency_key -ceq $keyA)) 'DUPLICATE same key and request returns the original receipt'
# --- Ownership: stale owner rejected, conflict rejected.
$rOld = Invoke-OrchestrationObjectiveEvent -Event (New-OrchestrationObjectiveEvent -GoalId 'G2-A' -Type 'worker-result' -WorkItemId 'task-done-9' -ActionRevision 1).event -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 0 -ExpectedRevision ([long]$svA.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -TestCallback
Assert-ORThat ((-not [bool]$rOld.ok) -and ([string]$rOld.reason -ceq 'invalid-generation')) 'OWNERSHIP bad generation rejected before store'
$ownA = Acquire-OrchestrationObjectiveOwnership -GoalId 'G2-A' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svA.revision) -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$ownA.ok) 'OWNERSHIP current owner re-acquires ok'
$ownStale = Acquire-OrchestrationObjectiveOwnership -GoalId 'G2-A' -OwnerId 'owner-1' -Generation 0 -ExpectedRevision ([long]$svA.revision) -StoreDir $ORDispatchStore
Assert-ORThat ((-not [bool]$ownStale.ok) -and ([string]$ownStale.reason -ceq 'invalid-generation')) 'OWNERSHIP generation zero rejected'
$gateStale = Test-OrchestrationObjectiveOwnership -Current @{ owner_id = 'owner-1'; generation = [long]2 } -Claimant @{ owner_id = 'owner-1'; generation = [long]1 }
Assert-ORThat ((-not [bool]$gateStale.ok) -and ([string]$gateStale.reason -ceq 'owner-obsolete')) 'OWNERSHIP obsolete generation rejected'
$gateConflict = Test-OrchestrationObjectiveOwnership -Current @{ owner_id = 'owner-1'; generation = [long]1 } -Claimant @{ owner_id = 'owner-2'; generation = [long]1 }
Assert-ORThat ((-not [bool]$gateConflict.ok) -and ([string]$gateConflict.reason -ceq 'owner-conflict')) 'OWNERSHIP foreign owner rejected'
# --- (c) Crash between dispatch and settlement reconciles without duplicating effect.
$svC = New-ORActiveGoal 'G2-C'
$seedC = New-OrchestrationDispatchIntent -GoalId 'G2-C' -WorkItemId 'task-crash-1' -ActionRevision 1
Assert-ORThat ([bool]$seedC.ok) 'CRASH intent constructed'
$saveC = Save-OrchestrationDispatchIntent -Intent $seedC.intent -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$saveC.ok -and (-not [bool]$saveC.duplicate)) 'CRASH intent persisted before effect'
$pendC = Set-OrchestrationDispatchState -GoalId 'G2-C' -WorkItemId 'task-crash-1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$pendC.ok) 'CRASH intent left PENDING (simulated crash)'
$script:dispatchCalls = 0
$script:settleCalls = 0
$keyC = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-C' -WorkItemId 'task-crash-1' -ActionRevision 1
$proofC = New-ORProof -Key $keyC -Owner 'owner-1' -Gen 1
$rC = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-C' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svC.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofC -TestCallback
Assert-ORThat ([bool]$rC.ok -and ([long]$rC.reconciled -eq 1) -and ([long]$rC.settled -eq 1) -and ([long]$rC.redispatched -eq 0)) 'CRASH reconcile settles pending without redispatch'
Assert-ORThat (($script:dispatchCalls -eq 0) -and ($script:settleCalls -eq 1)) 'CRASH no duplicate effect, single settle'
$afterC = Get-OrchestrationDispatchIntent -GoalId 'G2-C' -WorkItemId 'task-crash-1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$afterC.ok -and ([string]$afterC.intent['state'] -ceq 'settled')) 'CRASH intent now settled'
# --- (d) Budget: worker exhaustion => replan, hard => terminal, never false DONE.
$svD = New-ORActiveGoal 'G2-D'
$keyD = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D' -WorkItemId 'task-d-1' -ActionRevision 1
$proofD = New-ORProof -Key $keyD -Owner 'owner-1' -Gen 1
$evD = (New-OrchestrationObjectiveEvent -GoalId 'G2-D' -Type 'wave-barrier' -WorkItemId 'task-d-1' -ActionRevision 1).event
$rD = Invoke-OrchestrationObjectiveEvent -Event $evD -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -BudgetScope 'worker' -BudgetExhausted $true -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofD -SettleProof $proofD -TestCallback
Assert-ORThat ([bool]$rD.ok -and ([string]$rD.decision -ceq 'replan') -and (-not [bool]$rD.dispatched)) 'BUDGET worker exhaustion replans without dispatch'
$upD = Update-OrchestrationGoal -GoalId 'G2-D' -ExpectedRevision ([long]$svD.revision) -Fields @{ budget = @{ soft_cap = 10; hard_cap = 20; spent = 20 } } -StoreDir $ORGoalStore
Assert-ORThat ([bool]$upD.ok) 'BUDGET hard cap reached persisted on goal'
$evH = (New-OrchestrationObjectiveEvent -GoalId 'G2-D' -Type 'task-settled' -WorkItemId 'task-d-2' -ActionRevision 1).event
$keyH = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D' -WorkItemId 'task-d-2' -ActionRevision 1
$proofH = New-ORProof -Key $keyH -Owner 'owner-1' -Gen 1
$rH = Invoke-OrchestrationObjectiveEvent -Event $evH -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$upD.goal['revision']) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofH -SettleProof $proofH -TestCallback
Assert-ORThat ([bool]$rH.ok -and ([string]$rH.decision -ceq 'terminal') -and ([string]$rH.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED')) 'BUDGET hard exhaustion is the only terminal budget'
Assert-ORThat ((-not [bool]$rH.dispatched) -and ($null -eq $rH.next_move) -and (-not [bool]$rH.done_approved) -and (-not [bool]$rH.verified_pass)) 'BUDGET terminal carries no dispatch move or false DONE'
$reD = Get-OrchestrationGoal -GoalId 'G2-D' -StoreDir $ORGoalStore
Assert-ORThat ([bool]$reD.ok -and ([string]$reD.goal['state'] -ceq 'EXHAUSTED')) 'BUDGET terminal persisted on goal record'
# --- (e) Native HOLD adapter => typed safe fallback, never presumed spawn.
$svE = New-ORActiveGoal 'G2-E'
$evE = (New-OrchestrationObjectiveEvent -GoalId 'G2-E' -Type 'task-settled' -WorkItemId 'task-e-1' -ActionRevision 1).event
$rE = Invoke-OrchestrationObjectiveEvent -Event $evE -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svE.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull
Assert-ORThat ([bool]$rE.ok -and (-not [bool]$rE.dispatched) -and ([string]$rE.fallback -like 'hold-dispatchWorker*')) 'HOLD adapter falls back typed without spawn'
$heldE = Get-OrchestrationDispatchIntent -GoalId 'G2-E' -WorkItemId 'task-e-1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$heldE.ok -and ([string]$heldE.intent['state'] -ceq 'held')) 'HOLD intent parked as held, not pending'
# --- Policy envelope: outside intersection blocks fail-closed.
$rP = Invoke-OrchestrationObjectiveEvent -Event (New-OrchestrationObjectiveEvent -GoalId 'G2-E' -Type 'task-settled' -WorkItemId 'task-e-2' -ActionRevision 1).event -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svE.revision) -User '' -Project 'p' -Runtime 'V1' -Grants 'fs.read' -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -TestCallback
Assert-ORThat ((-not [bool]$rP.ok) -and ([string]$rP.stop_reason -ceq 'POLICY_BLOCKED') -and (-not [bool]$rP.dispatched)) 'POLICY missing user blocks fail-closed'
# --- (f) Hygiene: no secret reads, no self-attested verification, no process or network primitives.
$LibText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OrchestrationObjectiveRuntime.ps1'), [Text.Encoding]::UTF8)
$envToken = ('$' + 'env:')
Assert-ORThat (-not $LibText.Contains($envToken)) 'HYGIENE executor never reads process environment'
$badSelfVerify = $false
$badGrant = $false
foreach ($ln in @($LibText -split "`r?`n")) {
    if ($ln -match 'verified_pass\s*=\s*\$true') { $badSelfVerify = $true }
    if (($ln -match 'grants_authority\s*=\s*\$true') -or ($ln -match 'done_approved\s*=\s*\$true')) { $badGrant = $true }
}
Assert-ORThat ((-not $badSelfVerify) -and (-not $badGrant)) 'HYGIENE no self-attested verified pass or grant approval'
foreach ($token in @('Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Stop-Process', 'Start-Job', 'Complete-OrchestrationTask', 'New-Net', 'DownloadString')) {
    Assert-ORThat (-not $LibText.Contains($token)) ('HYGIENE executor has no ' + $token)
}
$wd = Get-OrchestrationObjectiveWatchdogReference
Assert-ORThat ((-not [bool]$wd.drives_watchdog) -and ([string]$wd.mode -ceq 'referenced-not-driven')) 'HYGIENE watchdog referenced, never driven'
# --- PR2-FIX-01 regressions (REV-PR1PR2-01 + SEC-PR2-01).
# R1: ownership with real mutual exclusion (CAS on the REAL goal revision,
# verifiable lease expiry, fencing token on every mutation).
$svR1 = New-ORActiveGoal 'G2-R1'
$script:dispatchCalls = 0
$script:settleCalls = 0
$keyR1a = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R1' -WorkItemId 'r1-w1' -ActionRevision 1
$proofR1 = New-ORProof -Key $keyR1a -Owner 'owner-1' -Gen 1
$evR1a = (New-OrchestrationObjectiveEvent -GoalId 'G2-R1' -Type 'task-settled' -WorkItemId 'r1-w1' -ActionRevision 1).event
$rR1a = Invoke-OrchestrationObjectiveEvent -Event $evR1a -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svR1.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR1 -SettleProof $proofR1 -TestCallback
Assert-ORThat ([bool]$rR1a.ok -and ([string]$rR1a.decision -ceq 'dispatched')) 'R1 first generation dispatches'
$takeR1 = Acquire-OrchestrationObjectiveOwnership -GoalId 'G2-R1' -OwnerId 'owner-1' -Generation 2 -ExpectedRevision ([long]$svR1.revision) -StoreDir $ORDispatchStore -GoalStoreDir $ORGoalStore
Assert-ORThat ([bool]$takeR1.ok) 'R1 same owner advances generation'
$evR1b = (New-OrchestrationObjectiveEvent -GoalId 'G2-R1' -Type 'task-settled' -WorkItemId 'r1-w2' -ActionRevision 1).event
$keyR1b = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R1' -WorkItemId 'r1-w2' -ActionRevision 1
$proofR1b = New-ORProof -Key $keyR1b -Owner 'owner-1' -Gen 1
$rR1b = Invoke-OrchestrationObjectiveEvent -Event $evR1b -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svR1.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR1b -SettleProof $proofR1b -TestCallback
Assert-ORThat ((-not [bool]$rR1b.dispatched) -and ([string]$rR1b.reason -ceq 'owner-obsolete') -and ($null -eq $rR1b.next_move)) 'R1 obsolete generation rejected, superseded generation never dispatches'
Assert-ORThat ($script:dispatchCalls -eq 1) 'R1 stale owner caused no new effect'
# R1: stale ExpectedRevision conflicts against the REAL goal revision.
$evR1c = (New-OrchestrationObjectiveEvent -GoalId 'G2-R1' -Type 'task-settled' -WorkItemId 'r1-w3' -ActionRevision 1).event
$keyR1c = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R1' -WorkItemId 'r1-w3' -ActionRevision 1
$proofR1c = New-ORProof -Key $keyR1c -Owner 'owner-1' -Gen 2
$rR1c = Invoke-OrchestrationObjectiveEvent -Event $evR1c -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 2 -ExpectedRevision ([long]([long]$svR1.revision + 99)) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR1c -SettleProof $proofR1c -TestCallback
Assert-ORThat ((-not [bool]$rR1c.dispatched) -and ([string]$rR1c.reason -ceq 'revision-conflict')) 'R1 stale revision CAS-conflicts on the real goal'
# R1: lease expiry is verifiable (expired lease + higher generation takes over; lower does not).
$svR1B = New-ORActiveGoal 'G2-R1B'
$ownerPathR1B = Get-OROwnerFilePath -Dir $ORDispatchStore -GoalId 'G2-R1B'
$expiredRec = [ordered]@{ schema_version = 1; goal_id = 'G2-R1B'; owner_id = 'owner-9'; generation = [long]5; goal_revision = [long]$svR1B.revision; acquired_at = '2026-01-01T00:00:00.0000000Z'; expires_at = '2026-01-01T00:01:00.0000000Z'; lease_ttl_ms = [long]60000; updated_at = '2026-01-01T00:00:00.0000000Z' }
[IO.File]::WriteAllText($ownerPathR1B, (ConvertTo-Json -InputObject $expiredRec -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
$gateExpiredLow = Test-OrchestrationObjectiveOwnership -Current @{ owner_id = 'owner-9'; generation = [long]5; expires_at = '2026-01-01T00:01:00.0000000Z' } -Claimant @{ owner_id = 'owner-1'; generation = [long]1 }
Assert-ORThat ((-not [bool]$gateExpiredLow.ok) -and ([string]$gateExpiredLow.reason -ceq 'owner-obsolete')) 'R1 expired lease still rejects a lower generation'
$gateExpiredHigh = Test-OrchestrationObjectiveOwnership -Current @{ owner_id = 'owner-9'; generation = [long]5; expires_at = '2026-01-01T00:01:00.0000000Z' } -Claimant @{ owner_id = 'owner-2'; generation = [long]6 }
Assert-ORThat ([bool]$gateExpiredHigh.ok) 'R1 expired lease allows strictly-higher-generation takeover'
$gateActiveRival = Test-OrchestrationObjectiveOwnership -Current @{ owner_id = 'owner-9'; generation = [long]5; expires_at = '2099-01-01T00:00:00.0000000Z' } -Claimant @{ owner_id = 'owner-2'; generation = [long]6 }
Assert-ORThat ((-not [bool]$gateActiveRival.ok) -and ([string]$gateActiveRival.reason -ceq 'owner-conflict')) 'R1 active lease keeps mutual exclusion against a rival'
$evR1d = (New-OrchestrationObjectiveEvent -GoalId 'G2-R1B' -Type 'task-settled' -WorkItemId 'r1-w4' -ActionRevision 1).event
$keyR1d = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R1B' -WorkItemId 'r1-w4' -ActionRevision 1
$proofR1d = New-ORProof -Key $keyR1d -Owner 'owner-2' -Gen 6
$rR1d = Invoke-OrchestrationObjectiveEvent -Event $evR1d -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-2' -Generation 6 -ExpectedRevision ([long]$svR1B.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR1d -SettleProof $proofR1d -TestCallback
Assert-ORThat ([bool]$rR1d.ok -and ([string]$rR1d.decision -ceq 'dispatched')) 'R1 takeover generation dispatches after expiry'
# R1: fencing token enforced on mutations (wrong owner cannot rewrite state).
$svR1F = New-ORActiveGoal 'G2-R1F'
$evR1f = (New-OrchestrationObjectiveEvent -GoalId 'G2-R1F' -Type 'task-settled' -WorkItemId 'r1-wf' -ActionRevision 1).event
$keyR1f = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R1F' -WorkItemId 'r1-wf' -ActionRevision 1
$proofR1f = New-ORProof -Key $keyR1f -Owner 'owner-f' -Gen 1
$rR1f = Invoke-OrchestrationObjectiveEvent -Event $evR1f -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-f' -Generation 1 -ExpectedRevision ([long]$svR1F.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR1f -SettleProof $proofR1f -TestCallback
Assert-ORThat ([bool]$rR1f.ok) 'R1 fencing setup dispatched'
$fenceBad = Set-OrchestrationDispatchState -GoalId 'G2-R1F' -WorkItemId 'r1-wf' -ActionRevision 1 -State 'held' -StoreDir $ORDispatchStore -OwnerId 'intruder' -Generation 1
Assert-ORThat ((-not [bool]$fenceBad.ok) -and ([string]$fenceBad.reason -ceq 'owner-lost-no-advance')) 'R1 foreign fencing token cannot mutate intent state'
# R1: terminal persistence requires ownership (stale owner persists nothing).
$svR1T = New-ORActiveGoal 'G2-R1T'
$upR1T = Update-OrchestrationGoal -GoalId 'G2-R1T' -ExpectedRevision ([long]$svR1T.revision) -Fields @{ budget = @{ soft_cap = 10; hard_cap = 20; spent = 20 } } -StoreDir $ORGoalStore
Assert-ORThat ([bool]$upR1T.ok) 'R1 terminal setup persisted hard-cap budget'
$evR1t = (New-OrchestrationObjectiveEvent -GoalId 'G2-R1T' -Type 'task-settled' -WorkItemId 'r1-wt' -ActionRevision 1).event
$keyR1t = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R1T' -WorkItemId 'r1-wt' -ActionRevision 1
$proofR1tBad = New-ORProof -Key $keyR1t -Owner 'owner-t' -Gen 0
$rR1tBad = Invoke-OrchestrationObjectiveEvent -Event $evR1t -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-t' -Generation 0 -ExpectedRevision ([long]$upR1T.goal['revision']) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR1tBad -SettleProof $proofR1tBad -TestCallback
Assert-ORThat ((-not [bool]$rR1tBad.ok) -and ([string]$rR1tBad.decision -ceq 'blocked')) 'R1 terminal without ownership is blocked'
$reR1T = Get-OrchestrationGoal -GoalId 'G2-R1T' -StoreDir $ORGoalStore
Assert-ORThat ([bool]$reR1T.ok -and ([string]$reR1T.goal['state'] -ceq 'ACTIVE')) 'R1 blocked terminal persisted nothing'
$proofR1tGood = New-ORProof -Key $keyR1t -Owner 'owner-t' -Gen 1
$rR1tGood = Invoke-OrchestrationObjectiveEvent -Event $evR1t -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-t' -Generation 1 -ExpectedRevision ([long]$upR1T.goal['revision']) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR1tGood -SettleProof $proofR1tGood -TestCallback
Assert-ORThat ([bool]$rR1tGood.ok -and ([string]$rR1tGood.decision -ceq 'terminal')) 'R1 terminal with ownership persists'
# R2: no next_move without confirmed settlement (failed or absent settlement => no new move, controller not consulted).
$svR2 = New-ORActiveGoal 'G2-R2'
$script:nextMoveCalls = 0
$FakeSettleFail = { param($intent, $dispatch, $goal, $auth) return [pscustomobject]@{ ok = $false; reason = 'fake-settle-failed' } }
$NextMoveSpy = { param($goal) $script:nextMoveCalls++; return [pscustomobject]@{ move = 'CONTINUE'; reason = 'spy'; remaining_count = 1 } }
$evR2a = (New-OrchestrationObjectiveEvent -GoalId 'G2-R2' -Type 'task-settled' -WorkItemId 'r2-w1' -ActionRevision 1).event
$keyR2a = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R2' -WorkItemId 'r2-w1' -ActionRevision 1
$proofR2a = New-ORProof -Key $keyR2a -Owner 'owner-1' -Gen 1
$rR2a = Invoke-OrchestrationObjectiveEvent -Event $evR2a -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svR2.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettleFail -CheckpointImpl $null -NextMoveImpl $NextMoveSpy -DispatchProof $proofR2a -SettleProof $proofR2a -TestCallback
Assert-ORThat ([bool]$rR2a.ok -and ([string]$rR2a.decision -ceq 'settlement-pending') -and ([string]$rR2a.settlement -ceq 'pending-reconciliation') -and ($null -eq $rR2a.next_move) -and ([string]$rR2a.checkpoint_id -ceq '')) 'R2 failed settlement yields no next_move and no checkpoint'
Assert-ORThat ($script:nextMoveCalls -eq 0) 'R2 controller never consulted without settlement'
$afterR2a = Get-OrchestrationDispatchIntent -GoalId 'G2-R2' -WorkItemId 'r2-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$afterR2a.ok -and ([string]$afterR2a.intent['state'] -ceq 'pending')) 'R2 unsettled intent stays pending, never reconciled-away'
$evR2b = (New-OrchestrationObjectiveEvent -GoalId 'G2-R2' -Type 'task-settled' -WorkItemId 'r2-w2' -ActionRevision 1).event
$keyR2b = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R2' -WorkItemId 'r2-w2' -ActionRevision 1
$proofR2b = New-ORProof -Key $keyR2b -Owner 'owner-1' -Gen 1
$rR2b = Invoke-OrchestrationObjectiveEvent -Event $evR2b -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svR2.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -NextMoveImpl $NextMoveSpy -DispatchProof $proofR2b -SettleProof $proofR2b -TestCallback
Assert-ORThat (($null -eq $rR2b.next_move) -and ([string]$rR2b.decision -ceq 'settlement-pending') -and ($script:nextMoveCalls -eq 0)) 'R2 absent settlement yields no next_move either'
# R2: checkpoint failure also blocks advancement (settlement stays, move waits).
$svR2C = New-ORActiveGoal 'G2-R2C'
$BadCheckpoint = { param($goal) return '' }
$evR2c = (New-OrchestrationObjectiveEvent -GoalId 'G2-R2C' -Type 'task-settled' -WorkItemId 'r2-w3' -ActionRevision 1).event
$keyR2c = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R2C' -WorkItemId 'r2-w3' -ActionRevision 1
$proofR2c = New-ORProof -Key $keyR2c -Owner 'owner-1' -Gen 1
$rR2c = Invoke-OrchestrationObjectiveEvent -Event $evR2c -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svR2C.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -CheckpointImpl $BadCheckpoint -NextMoveImpl $NextMoveSpy -DispatchProof $proofR2c -SettleProof $proofR2c -TestCallback
Assert-ORThat (([string]$rR2c.settlement -ceq 'settled') -and ($null -eq $rR2c.next_move) -and ([string]$rR2c.reason -ceq 'checkpoint-failed-no-advance') -and ($script:nextMoveCalls -eq 0)) 'R2 checkpoint failure blocks the next move while settlement stands'
# R3: crash in intended is reconcilable; failed settlement stays pending and idempotent.
$svR3 = New-ORActiveGoal 'G2-R3'
$seedR3 = New-OrchestrationDispatchIntent -GoalId 'G2-R3' -WorkItemId 'task-r3-1' -ActionRevision 1
$saveR3 = Save-OrchestrationDispatchIntent -Intent $seedR3.intent -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$saveR3.ok -and (-not [bool]$saveR3.duplicate)) 'R3 intended persisted before the effect (orphan seed)'
$script:settleCalls = 0
$keyR3 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R3' -WorkItemId 'task-r3-1' -ActionRevision 1
$proofR3 = New-ORProof -Key $keyR3 -Owner 'owner-1' -Gen 1
$rR3 = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-R3' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svR3.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofR3 -TestCallback
Assert-ORThat ([bool]$rR3.ok -and ([long]$rR3.reconciled -eq 1) -and ([long]$rR3.settled -eq 1) -and ([long]$rR3.redispatched -eq 0)) 'R3 crash in intended reconciles to settled without redispatch'
$svR3B = New-ORActiveGoal 'G2-R3B'
$seedR3B = New-OrchestrationDispatchIntent -GoalId 'G2-R3B' -WorkItemId 'task-r3-2' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedR3B.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-R3B' -WorkItemId 'task-r3-2' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$script:settleCalls = 0
$keyR3B = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R3B' -WorkItemId 'task-r3-2' -ActionRevision 1
$proofR3B = New-ORProof -Key $keyR3B -Owner 'owner-1' -Gen 1
$rR3B = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-R3B' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svR3B.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettleFail -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofR3B -TestCallback
Assert-ORThat ([bool]$rR3B.ok -and ([long]$rR3B.reconciled -eq 1) -and ([long]$rR3B.settled -eq 0) -and ([long]$rR3B.redispatched -eq 0)) 'R3 failed settlement counts investigation but no settlement and no redispatch'
$afterR3B = Get-OrchestrationDispatchIntent -GoalId 'G2-R3B' -WorkItemId 'task-r3-2' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$afterR3B.ok -and ([string]$afterR3B.intent['state'] -ceq 'pending')) 'R3 failed settlement stays pending, eligible and idempotent (never reconciled-away)'
$rR3C = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-R3B' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svR3B.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofR3B -TestCallback
Assert-ORThat ([bool]$rR3C.ok -and ([long]$rR3C.settled -eq 1)) 'R3 retry after failure settles the same intent once'
# R4: standalone clean session (no pre-loading) resolves every sibling command.
$childPs = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $childPs -PathType Leaf)) { $childPs = 'powershell.exe' }
$libOnly = Join-Path $PSScriptRoot 'OrchestrationObjectiveRuntime.ps1'
$probeCmd = ". '" + $libOnly + "'; " + '$c = @(Get-Command Get-OrchestrationGoal,Get-OrchestrationGoalNextMove,New-OrchestrationGoalCheckpoint,New-OrchestrationAdapterAuthEnvelope -ErrorAction SilentlyContinue); if ($c.Count -eq 4) { ''OR-STANDALONE-OK'' } else { ''OR-STANDALONE-MISSING:'' + $c.Count }'
$probeOut = (& $childPs -NoProfile -NonInteractive -Command $probeCmd 2>&1 | Out-String)
Assert-ORThat ($probeOut -match 'OR-STANDALONE-OK') 'R4 clean session with only the runtime lib resolves sibling commands'
Assert-ORThat ($LibText -match 'OrchestrationGoalKernel\.ps1') 'R4 sibling imports live in module scope'
# R5: ambiguous triples no longer share a file; stored-key validation stands.
$pathR5a = Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'a__b' -WorkItemId 'c' -ActionRevision 1
$pathR5b = Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'a' -WorkItemId 'b__c' -ActionRevision 1
Assert-ORThat (($pathR5a -cne $pathR5b) -and (-not [string]::IsNullOrWhiteSpace($pathR5a)) -and (-not [string]::IsNullOrWhiteSpace($pathR5b))) 'R5 ambiguous triples map to distinct files'
$svR5 = New-ORActiveGoal 'G2-R5'
$script:dispatchCalls = 0
$evR5a = (New-OrchestrationObjectiveEvent -GoalId 'G2-R5' -Type 'task-settled' -WorkItemId 'w5a__x' -ActionRevision 1).event
$evR5b = (New-OrchestrationObjectiveEvent -GoalId 'G2-R5' -Type 'task-settled' -WorkItemId 'w5b' -ActionRevision 1).event
$keyR5a = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R5' -WorkItemId 'w5a__x' -ActionRevision 1
$keyR5b = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-R5' -WorkItemId 'w5b' -ActionRevision 1
$proofR5a = New-ORProof -Key $keyR5a -Owner 'owner-5' -Gen 1
$proofR5b = New-ORProof -Key $keyR5b -Owner 'owner-5' -Gen 1
$rR5a = Invoke-OrchestrationObjectiveEvent -Event $evR5a -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-5' -Generation 1 -ExpectedRevision ([long]$svR5.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR5a -SettleProof $proofR5a -TestCallback
$rR5b = Invoke-OrchestrationObjectiveEvent -Event $evR5b -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-5' -Generation 1 -ExpectedRevision ([long]$svR5.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofR5b -SettleProof $proofR5b -TestCallback
Assert-ORThat ([bool]$rR5a.ok -and [bool]$rR5b.ok -and ($script:dispatchCalls -eq 2)) 'R5 colliding-looking work items both dispatch independently'
$dupR5 = Save-OrchestrationDispatchIntent -Intent (New-OrchestrationDispatchIntent -GoalId 'G2-R5' -WorkItemId 'w5a__x' -ActionRevision 1).intent -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$dupR5.ok -and ([bool]$dupR5.duplicate)) 'R5 same canonical key is still an idempotent duplicate'
# R5: a file whose stored key differs is a collision, never a duplicate.
$foreignIntent = New-OrchestrationDispatchIntent -GoalId 'G2-R5' -WorkItemId 'w5foreign' -ActionRevision 1
$foreignSave = Save-OrchestrationDispatchIntent -Intent $foreignIntent.intent -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$foreignSave.ok) 'R5 foreign intent setup saved'
$foreignPath = Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'G2-R5' -WorkItemId 'w5foreign' -ActionRevision 1
$victimPath = Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'G2-R5' -WorkItemId 'w5a__x' -ActionRevision 1
[IO.File]::WriteAllText($victimPath, ([IO.File]::ReadAllText($foreignPath, [Text.Encoding]::UTF8)), [Text.UTF8Encoding]::new($false))
$collR5 = Save-OrchestrationDispatchIntent -Intent (New-OrchestrationDispatchIntent -GoalId 'G2-R5' -WorkItemId 'w5a__x' -ActionRevision 1).intent -StoreDir $ORDispatchStore
Assert-ORThat ((-not [bool]$collR5.ok) -and ([string]$collR5.reason -ceq 'key-collision') -and (-not [bool]$collR5.duplicate)) 'R5 differing stored key fails closed as collision, not duplicate'
# S1: structured authorization (deny-wins fail-closed; reconcile/settlement verify the envelope before any effect).
$denyEnv = New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'deny' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert-ORThat ((-not [bool]$denyEnv.admitted) -and ([string]$denyEnv.reason -ceq 'POLICY-BLOCKED:grants-deny') -and (-not [bool]$denyEnv.grants_authority) -and (-not [bool]$denyEnv.done_approved)) 'S1 contract denies Grants=deny fail-closed'
$denyMix = New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'fs.read, deny, allow:dispatch' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert-ORThat (-not [bool]$denyMix.admitted) 'S1 deny wins over allow tokens'
$allowEnv = New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'fs.read allow:dispatch' -Operation 'dispatchWorker' -Resource 'w-1' -Decision 'dispatch'
Assert-ORThat ([bool]$allowEnv.admitted -and ([string]$allowEnv.operation -ceq 'dispatchWorker') -and ([bool]$allowEnv.explicit_allow) -and (-not [string]::IsNullOrWhiteSpace([string]$allowEnv.grant_ref))) 'S1 allow envelope carries operation/resource/decision plus verifiable grant ref, without authority'
$noRefEnv = New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'fs.read' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert-ORThat ((-not [bool]$noRefEnv.admitted) -and ([string]$noRefEnv.reason -ceq 'POLICY-BLOCKED:operation-not-authorized')) 'S1 capability tokens without explicit allow deny'
$selfEnv = New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'fs.read' -Operation 'dispatch' -Resource 'w-1' -Decision 'allow'
Assert-ORThat ((-not [bool]$selfEnv.admitted) -and ([string]$selfEnv.reason -ceq 'POLICY-BLOCKED:self-grant-rejected')) 'S1 caller Decision=allow is never a self-grant'
$badOpEnv = New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch' -Operation 'invented' -Resource 'w-1' -Decision 'dispatch'
Assert-ORThat ((-not [bool]$badOpEnv.admitted) -and ([string]$badOpEnv.reason -ceq 'POLICY-BLOCKED:operation-not-allowed')) 'S1 unknown operation denies fail-closed'
$svS1 = New-ORActiveGoal 'G2-S1'
$script:dispatchCalls = 0
$evS1 = (New-OrchestrationObjectiveEvent -GoalId 'G2-S1' -Type 'task-settled' -WorkItemId 's1-w1' -ActionRevision 1).event
$keyS1 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-S1' -WorkItemId 's1-w1' -ActionRevision 1
$proofS1 = New-ORProof -Key $keyS1 -Owner 'owner-1' -Gen 1
$rS1 = Invoke-OrchestrationObjectiveEvent -Event $evS1 -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svS1.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants 'deny' -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofS1 -SettleProof $proofS1 -TestCallback
Assert-ORThat ((-not [bool]$rS1.dispatched) -and ([string]$rS1.stop_reason -ceq 'POLICY_BLOCKED') -and ($null -eq $rS1.next_move) -and ($script:dispatchCalls -eq 0)) 'S1 deny envelope blocks dispatch with no effect'
$rS1N = Invoke-OrchestrationObjectiveEvent -Event (New-OrchestrationObjectiveEvent -GoalId 'G2-S1' -Type 'task-settled' -WorkItemId 's1-w9' -ActionRevision 1).event -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svS1.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants 'fs.read' -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofS1 -SettleProof $proofS1 -TestCallback
Assert-ORThat ((-not [bool]$rS1N.dispatched) -and ([string]$rS1N.stop_reason -ceq 'POLICY_BLOCKED') -and ([string]$rS1N.reason -ceq 'POLICY-BLOCKED:operation-not-authorized') -and ($script:dispatchCalls -eq 0)) 'S1 capability tokens without explicit dispatch allow block with no effect'
$svS1B = New-ORActiveGoal 'G2-S1B'
$seedS1 = New-OrchestrationDispatchIntent -GoalId 'G2-S1B' -WorkItemId 'task-s1-1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedS1.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-S1B' -WorkItemId 'task-s1-1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$script:settleCalls = 0
$rS1B = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-S1B' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svS1B.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -TestCallback
Assert-ORThat ((-not [bool]$rS1B.ok) -and ([long]$rS1B.reconciled -eq 0) -and ([long]$rS1B.settled -eq 0) -and ($script:settleCalls -eq 0)) 'S1 reconcile without envelope causes no effect'
$afterS1B = Get-OrchestrationDispatchIntent -GoalId 'G2-S1B' -WorkItemId 'task-s1-1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$afterS1B.ok -and ([string]$afterS1B.intent['state'] -ceq 'pending')) 'S1 blocked reconcile leaves the intent pending'
$rS1C = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-S1B' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svS1B.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants 'deny' -TestCallback
Assert-ORThat ((-not [bool]$rS1C.ok) -and ([long]$rS1C.settled -eq 0) -and ($script:settleCalls -eq 0)) 'S1 reconcile with deny causes no settlement'
# --- D2 identity: canonical key, display preserved, legacy HOLD.
$kFoldA = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-Case' -WorkItemId 'W-Case' -ActionRevision 1
$kFoldB = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'g2-case' -WorkItemId 'w-case' -ActionRevision 1
Assert-ORThat (($kFoldA -ceq $kFoldB) -and (-not [string]::IsNullOrWhiteSpace($kFoldA))) 'D2 canonical key folds case'
$pFoldA = Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'G2-Case' -WorkItemId 'W-Case' -ActionRevision 1
$pFoldB = Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'g2-case' -WorkItemId 'w-case' -ActionRevision 1
Assert-ORThat ($pFoldA -ceq $pFoldB) 'D2 case folds share the canonical file'
$oFoldA = Get-OROwnerFilePath -Dir $ORDispatchStore -GoalId 'G2-Case'
$oFoldB = Get-OROwnerFilePath -Dir $ORDispatchStore -GoalId 'g2-case'
Assert-ORThat ($oFoldA -ceq $oFoldB) 'D2 owner file keyed by canonical identity'
$svID = New-ORActiveGoal 'G2-Hold2'
$seedID = New-OrchestrationDispatchIntent -GoalId 'g2-hold2' -WorkItemId 'h-w2' -ActionRevision 1
Assert-ORThat ([string]$seedID.intent['goal_id'] -ceq 'g2-hold2') 'D2 display spelling preserved on the record'
$saveID = Save-OrchestrationDispatchIntent -Intent $seedID.intent -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$saveID.ok) 'D2 legacy-spelling seed persisted'
$evID = (New-OrchestrationObjectiveEvent -GoalId 'G2-Hold2' -Type 'task-settled' -WorkItemId 'H-W2' -ActionRevision 1).event
$rID = Invoke-OrchestrationObjectiveEvent -Event $evID -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svID.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -TestCallback
Assert-ORThat ((-not [bool]$rID.ok) -and ([string]$rID.reason -ceq 'identity-hold-case-divergence') -and ([string]$rID.decision -ceq 'blocked')) 'D2 legacy case divergence holds without rename or merge'
$fHold = Confirm-OROwnershipHeld -Dir $ORDispatchStore -GoalId 'G2-A' -OwnerId 'OWNER-1' -Generation 1
Assert-ORThat ((-not [bool]$fHold.held) -and ([string]$fHold.reason -ceq 'identity-hold-case-divergence')) 'D2 owner case divergence holds under fencing'
$gateHold = Test-OrchestrationObjectiveOwnership -Current @{ owner_id = 'owner-1'; generation = [long]1 } -Claimant @{ owner_id = 'OWNER-1'; generation = [long]1 }
Assert-ORThat ((-not [bool]$gateHold.ok) -and ([string]$gateHold.reason -ceq 'identity-hold-case-divergence')) 'D2 ownership gate holds on case divergence'
# --- D5 settlement owns its envelope (never the dispatch one).
$svD5 = New-ORActiveGoal 'G2-D5'
$keyD5 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D5' -WorkItemId 'd5-w1' -ActionRevision 1
$proofD5 = New-ORProof -Key $keyD5 -Owner 'owner-1' -Gen 1
$evD5 = (New-OrchestrationObjectiveEvent -GoalId 'G2-D5' -Type 'task-settled' -WorkItemId 'd5-w1' -ActionRevision 1).event
$script:settleCalls = 0
$rD5 = Invoke-OrchestrationObjectiveEvent -Event $evD5 -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD5.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofD5 -SettleProof $proofD5 -TestCallback
Assert-ORThat ([bool]$rD5.ok -and ([string]$rD5.decision -ceq 'settlement-pending') -and ([string]$rD5.settlement -ceq 'pending-reconciliation') -and ($script:settleCalls -eq 0) -and ($null -eq $rD5.next_move)) 'D5 settlement without its own allow never invokes SettleImpl'
$afterD5 = Get-OrchestrationDispatchIntent -GoalId 'G2-D5' -WorkItemId 'd5-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$afterD5.ok -and ([string]$afterD5.intent['state'] -ceq 'pending') -and ([string]$rD5.intent_state -ceq 'pending')) 'D5 unsettled intent waits pending with receipt stored'
# --- D5 checkpoint and advance own their decisions (settled/ checkpointed/ advanced stay distinct).
$svD5C = New-ORActiveGoal 'G2-D5C'
$keyD5C = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D5C' -WorkItemId 'd5c-w1' -ActionRevision 1
$proofD5C = New-ORProof -Key $keyD5C -Owner 'owner-1' -Gen 1
$evD5C = (New-OrchestrationObjectiveEvent -GoalId 'G2-D5C' -Type 'task-settled' -WorkItemId 'd5c-w1' -ActionRevision 1).event
$script:settleCalls = 0
$rD5C = Invoke-OrchestrationObjectiveEvent -Event $evD5C -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD5C.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch allow:settlement allow:advance' -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofD5C -SettleProof $proofD5C -TestCallback
Assert-ORThat (([string]$rD5C.settlement -ceq 'settled') -and ([string]$rD5C.decision -ceq 'checkpoint-blocked') -and ($null -eq $rD5C.next_move) -and ([string]$rD5C.intent_state -ceq 'settled') -and ($script:settleCalls -eq 1)) 'D5 checkpoint without its own allow blocks advancement while settlement stands'
$svD5D = New-ORActiveGoal 'G2-D5D'
$keyD5D = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D5D' -WorkItemId 'd5d-w1' -ActionRevision 1
$proofD5D = New-ORProof -Key $keyD5D -Owner 'owner-1' -Gen 1
$evD5D = (New-OrchestrationObjectiveEvent -GoalId 'G2-D5D' -Type 'task-settled' -WorkItemId 'd5d-w1' -ActionRevision 1).event
$rD5D = Invoke-OrchestrationObjectiveEvent -Event $evD5D -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD5D.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch allow:settlement allow:checkpoint' -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofD5D -SettleProof $proofD5D -TestCallback
Assert-ORThat (([string]$rD5D.settlement -ceq 'settled') -and (-not [string]::IsNullOrWhiteSpace([string]$rD5D.checkpoint_id)) -and ([string]$rD5D.decision -ceq 'advance-blocked') -and ($null -eq $rD5D.next_move) -and ([string]$rD5D.intent_state -ceq 'checkpointed')) 'D5 advance without its own allow keeps the checkpoint without issuing a move'
$dcD5D = $script:dispatchCalls
$scD5D = $script:settleCalls
$rD5D2 = Invoke-OrchestrationObjectiveEvent -Event $evD5D -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD5D.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofD5D -SettleProof $proofD5D -TestCallback
Assert-ORThat ([bool]$rD5D2.ok -and ([string]$rD5D2.decision -ceq 'dispatched') -and ($null -ne $rD5D2.next_move) -and ([string]$rD5D2.intent_state -ceq 'advanced')) 'D5 checkpointed duplicate resumes only the advance stage'
Assert-ORThat (($script:dispatchCalls -eq $dcD5D) -and ($script:settleCalls -eq $scD5D)) 'D5 resume replays no dispatch and no settlement'
Assert-ORThat (([string]$rD5.intent_state -cne [string]$rD5C.intent_state) -and ([string]$rD5C.intent_state -cne [string]$rD5D.intent_state) -and ([string]$rD5D.intent_state -cne [string]$rD5D2.intent_state)) 'D5 pending, settled, checkpointed and advanced are distinct stages'
# --- D5 terminalization owns its decision.
$svD5T = New-ORActiveGoal 'G2-D5T'
$upD5T = Update-OrchestrationGoal -GoalId 'G2-D5T' -ExpectedRevision ([long]$svD5T.revision) -Fields @{ budget = @{ soft_cap = 10; hard_cap = 20; spent = 20 } } -StoreDir $ORGoalStore
Assert-ORThat ([bool]$upD5T.ok) 'D5 terminal setup persisted hard-cap budget'
$evD5T = (New-OrchestrationObjectiveEvent -GoalId 'G2-D5T' -Type 'task-settled' -WorkItemId 'd5t-w1' -ActionRevision 1).event
$keyD5T = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D5T' -WorkItemId 'd5t-w1' -ActionRevision 1
$proofD5T = New-ORProof -Key $keyD5T -Owner 'owner-1' -Gen 1
$rD5T = Invoke-OrchestrationObjectiveEvent -Event $evD5T -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$upD5T.goal['revision']) -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofD5T -SettleProof $proofD5T -TestCallback
Assert-ORThat ((-not [bool]$rD5T.ok) -and ([string]$rD5T.decision -ceq 'blocked') -and ([string]$rD5T.stop_reason -ceq 'POLICY_BLOCKED')) 'D5 terminalization without its own allow is blocked'
# --- D5 reconcile is per intent (resource-scoped allow admits one work item only).
$svD5R = New-ORActiveGoal 'G2-D5R'
$seedRa = New-OrchestrationDispatchIntent -GoalId 'G2-D5R' -WorkItemId 'ra-wa' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedRa.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-D5R' -WorkItemId 'ra-wa' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$seedRb = New-OrchestrationDispatchIntent -GoalId 'G2-D5R' -WorkItemId 'ra-wb' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedRb.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-D5R' -WorkItemId 'ra-wb' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyD5Ra = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D5R' -WorkItemId 'ra-wa' -ActionRevision 1
$proofD5Ra = New-ORProof -Key $keyD5Ra -Owner 'owner-1' -Gen 1
$script:settleCalls = 0
$rD5R = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-D5R' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD5R.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:reconcile:ra-wa allow:settlement' -SettleProof $proofD5Ra -TestCallback
Assert-ORThat ([bool]$rD5R.ok -and ([long]$rD5R.settled -eq 1) -and ($script:settleCalls -eq 1)) 'D5 resource-scoped reconcile settles only the admitted intent'
$afterRa = Get-OrchestrationDispatchIntent -GoalId 'G2-D5R' -WorkItemId 'ra-wa' -ActionRevision 1 -StoreDir $ORDispatchStore
$afterRb = Get-OrchestrationDispatchIntent -GoalId 'G2-D5R' -WorkItemId 'ra-wb' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat (([string]$afterRa.intent['state'] -ceq 'settled') -and ([string]$afterRb.intent['state'] -ceq 'pending')) 'D5 denied intent stays pending untouched'
# --- D3/D6 unproven callbacks are blocked pre-call (HOLD, never invoked).
$svD3 = New-ORActiveGoal 'G2-D3'
$evD3 = (New-OrchestrationObjectiveEvent -GoalId 'G2-D3' -Type 'task-settled' -WorkItemId 'd3-w1' -ActionRevision 1).event
$dcD3 = $script:dispatchCalls
$rD3 = Invoke-OrchestrationObjectiveEvent -Event $evD3 -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD3.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -TestCallback
Assert-ORThat ([bool]$rD3.ok -and ([string]$rD3.reason -like 'hold-unproven-effect*') -and (-not [bool]$rD3.dispatched) -and ($script:dispatchCalls -eq $dcD3)) 'D3 callback without fencing/idempotency proof is held before the call'
$heldD3 = Get-OrchestrationDispatchIntent -GoalId 'G2-D3' -WorkItemId 'd3-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([bool]$heldD3.ok -and ([string]$heldD3.intent['state'] -ceq 'held')) 'D3 unproven intent parked as held, never invoked'
# --- D3 a self-declared ok/dispatched without receipt proves no commit.
$svD3B = New-ORActiveGoal 'G2-D3B'
$keyD3B = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D3B' -WorkItemId 'd3b-w1' -ActionRevision 1
$proofD3B = New-ORProof -Key $keyD3B -Owner 'owner-1' -Gen 1
$evD3B = (New-OrchestrationObjectiveEvent -GoalId 'G2-D3B' -Type 'task-settled' -WorkItemId 'd3b-w1' -ActionRevision 1).event
$scD3B = $script:settleCalls
$rD3B = Invoke-OrchestrationObjectiveEvent -Event $evD3B -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD3B.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeNoReceipt -SettleImpl $FakeSettle -DispatchProof $proofD3B -SettleProof $proofD3B -TestCallback
Assert-ORThat ([bool]$rD3B.ok -and ([string]$rD3B.decision -ceq 'settlement-pending') -and ($null -eq $rD3B.next_move) -and ($script:settleCalls -eq $scD3B)) 'D3 ok without durable receipt stays pending with no settlement and no move'
$afterD3B = Get-OrchestrationDispatchIntent -GoalId 'G2-D3B' -WorkItemId 'd3b-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$afterD3B.intent['state'] -ceq 'dispatched-unknown') 'D3 unproven effect stays reconcilable, never held-away'
# --- D3 same key with a different request is a conflict.
$svD3C = New-ORActiveGoal 'G2-D3C'
$keyD3C = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D3C' -WorkItemId 'd3c-w1' -ActionRevision 1
$proofD3C = New-ORProof -Key $keyD3C -Owner 'owner-1' -Gen 1
$evD3C = (New-OrchestrationObjectiveEvent -GoalId 'G2-D3C' -Type 'task-settled' -WorkItemId 'd3c-w1' -ActionRevision 1).event
$rD3C = Invoke-OrchestrationObjectiveEvent -Event $evD3C -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD3C.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofD3C -SettleProof $proofD3C -TestCallback
Assert-ORThat ([bool]$rD3C.ok -and ([string]$rD3C.intent_state -ceq 'advanced')) 'D3 conflict setup dispatched'
$confD3 = Set-ORDispatchReceiptCAS -GoalId 'G2-D3C' -WorkItemId 'd3c-w1' -ActionRevision 1 -RequestHash 'deadbeef-dead-beef-dead-beefdeadbeef' -Receipt $rD3C.receipt -StoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1
Assert-ORThat ((-not [bool]$confD3.ok) -and ([string]$confD3.reason -ceq 'receipt-conflict')) 'D3 same key with a different request conflicts fail-closed'
# --- D4 post-settlement failure resumes only the checkpoint, then only the advance.
$svD4 = New-ORActiveGoal 'G2-D4'
$keyD4 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D4' -WorkItemId 'd4-w1' -ActionRevision 1
$proofD4 = New-ORProof -Key $keyD4 -Owner 'owner-1' -Gen 1
$evD4 = (New-OrchestrationObjectiveEvent -GoalId 'G2-D4' -Type 'task-settled' -WorkItemId 'd4-w1' -ActionRevision 1).event
$rD4a = Invoke-OrchestrationObjectiveEvent -Event $evD4 -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD4.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -CheckpointImpl $BadCheckpoint -NextMoveImpl $NextMoveSpy -DispatchProof $proofD4 -SettleProof $proofD4 -TestCallback
Assert-ORThat (([string]$rD4a.settlement -ceq 'settled') -and ([string]$rD4a.reason -ceq 'checkpoint-failed-no-advance')) 'D4 post-settlement failure parks at settled'
$stD4 = Get-OrchestrationDispatchIntent -GoalId 'G2-D4' -WorkItemId 'd4-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$stD4.intent['state'] -ceq 'settled') 'D4 settled stage recorded distinctly'
$dcD4 = $script:dispatchCalls
$scD4 = $script:settleCalls
$nmD4 = $script:nextMoveCalls
$rD4b = Invoke-OrchestrationObjectiveEvent -Event $evD4 -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD4.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -CheckpointImpl $null -NextMoveImpl $NextMoveSpy -DispatchProof $proofD4 -SettleProof $proofD4 -TestCallback
Assert-ORThat ([bool]$rD4b.ok -and ([string]$rD4b.decision -ceq 'dispatched') -and ($null -ne $rD4b.next_move) -and (-not [string]::IsNullOrWhiteSpace([string]$rD4b.checkpoint_id)) -and ([string]$rD4b.intent_state -ceq 'advanced')) 'D4 duplicate resumes checkpoint then advance with no new move source'
Assert-ORThat (($script:dispatchCalls -eq $dcD4) -and ($script:settleCalls -eq $scD4) -and ($script:nextMoveCalls -eq ($nmD4 + 1))) 'D4 resume replays no dispatch and no settlement, only the missing advance'
# --- D4 reconciled only with conclusive destination proof; inconclusive stays pending.
$svD4B = New-ORActiveGoal 'G2-D4B'
$seedD4B = New-OrchestrationDispatchIntent -GoalId 'G2-D4B' -WorkItemId 'd4b-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedD4B.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-D4B' -WorkItemId 'd4b-w1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyD4B = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D4B' -WorkItemId 'd4b-w1' -ActionRevision 1
$proofD4B = New-ORProof -Key $keyD4B -Owner 'owner-1' -Gen 1
$rD4B = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-D4B' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD4B.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcileInconclusive -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofD4B -TestCallback
Assert-ORThat ([bool]$rD4B.ok -and ([long]$rD4B.reconciled -eq 0) -and ([long]$rD4B.settled -eq 0)) 'D4 inconclusive observation reconciles nothing'
$afterD4B = Get-OrchestrationDispatchIntent -GoalId 'G2-D4B' -WorkItemId 'd4b-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$afterD4B.intent['state'] -ceq 'pending') 'D4 unknown stays pending'
$svD4C = New-ORActiveGoal 'G2-D4C'
$seedD4C = New-OrchestrationDispatchIntent -GoalId 'G2-D4C' -WorkItemId 'd4c-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedD4C.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-D4C' -WorkItemId 'd4c-w1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyD4C = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D4C' -WorkItemId 'd4c-w1' -ActionRevision 1
$proofD4C = New-ORProof -Key $keyD4C -Owner 'owner-1' -Gen 1
$rD4C = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-D4C' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD4C.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcileClean -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofD4C -TestCallback
Assert-ORThat ([bool]$rD4C.ok -and ([long]$rD4C.reconciled -eq 1) -and ([long]$rD4C.settled -eq 0)) 'D4 conclusive no-effect proof closes as reconciled without settlement'
$afterD4C = Get-OrchestrationDispatchIntent -GoalId 'G2-D4C' -WorkItemId 'd4c-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$afterD4C.intent['state'] -ceq 'reconciled') 'D4 proven-absent effect recorded reconciled'
# --- D4 terminal Goal: prior-effect settlement OK, new dispatch prohibited.
$svD4T = New-ORActiveGoal 'G2-D4T'
$gotD4T = Get-OrchestrationGoal -GoalId 'G2-D4T' -StoreDir $ORGoalStore
$termD4T = Set-OrchestrationGoalState -Goal $gotD4T.goal -ToState 'COMPLETED'
$saveD4T = Save-OrchestrationGoal -Goal $termD4T.goal -StoreDir $ORGoalStore
Assert-ORThat ([bool]$saveD4T.ok) 'D4 terminal fixture completed'
$seedD4T = New-OrchestrationDispatchIntent -GoalId 'G2-D4T' -WorkItemId 'd4t-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedD4T.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-D4T' -WorkItemId 'd4t-w1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyD4T = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D4T' -WorkItemId 'd4t-w1' -ActionRevision 1
$proofD4T = New-ORProof -Key $keyD4T -Owner 'owner-1' -Gen 1
$rD4T = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-D4T' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$saveD4T.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofD4T -TestCallback
Assert-ORThat ([bool]$rD4T.ok -and ([long]$rD4T.settled -eq 1)) 'D4 terminal goal still settles a prior effect'
$evD4T = (New-OrchestrationObjectiveEvent -GoalId 'G2-D4T' -Type 'task-settled' -WorkItemId 'd4t-w2' -ActionRevision 1).event
$keyD4T2 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D4T' -WorkItemId 'd4t-w2' -ActionRevision 1
$proofD4T2 = New-ORProof -Key $keyD4T2 -Owner 'owner-1' -Gen 1
$rD4T2 = Invoke-OrchestrationObjectiveEvent -Event $evD4T -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$saveD4T.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofD4T2 -SettleProof $proofD4T2 -TestCallback
Assert-ORThat (([string]$rD4T2.reason -ceq 'goal-terminal') -and ([string]$rD4T2.decision -ceq 'terminal') -and (-not [bool]$rD4T2.dispatched)) 'D4 terminal goal prohibits new dispatch'
# --- D4 transition guard: no re-entry, no generic settle/hold/checkpoint.
$svD4F = New-ORActiveGoal 'G2-D4F'
$seedD4F = New-OrchestrationDispatchIntent -GoalId 'G2-D4F' -WorkItemId 'd4f-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedD4F.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-D4F' -WorkItemId 'd4f-w1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$tF1 = Set-OrchestrationDispatchState -GoalId 'G2-D4F' -WorkItemId 'd4f-w1' -ActionRevision 1 -State 'held' -StoreDir $ORDispatchStore
Assert-ORThat ((-not [bool]$tF1.ok) -and ([string]$tF1.reason -ceq 'invalid-transition')) 'D4 pending never parks as held generically'
$tF2 = Set-OrchestrationDispatchState -GoalId 'G2-D4F' -WorkItemId 'd4f-w1' -ActionRevision 1 -State 'settled' -StoreDir $ORDispatchStore
Assert-ORThat ((-not [bool]$tF2.ok) -and ([string]$tF2.reason -ceq 'invalid-transition')) 'D4 generic setter never settles (CAS only)'
$tF3 = Set-OrchestrationDispatchState -GoalId 'G2-D4F' -WorkItemId 'd4f-w1' -ActionRevision 1 -State 'checkpointed' -StoreDir $ORDispatchStore
Assert-ORThat ((-not [bool]$tF3.ok) -and ([string]$tF3.reason -ceq 'invalid-transition')) 'D4 generic setter never checkpoints (stage CAS only)'
$tF4 = Set-ORDispatchStageCAS -GoalId 'G2-D4F' -WorkItemId 'd4f-w1' -ActionRevision 1 -ToStage 'advanced' -StoreDir $ORDispatchStore
Assert-ORThat ((-not [bool]$tF4.ok) -and ([string]$tF4.reason -ceq 'invalid-transition')) 'D4 advance requires the checkpointed stage first'
# --- D1 ledger diary: productive acquisition HOLD documented, local acquire still diary-scoped.
Assert-ORThat ($LibText -match 'GoalKernel extension') 'D1 productive acquisition HOLD documented on the ledger'
Assert-ORThat (-not $LibText.Contains('verification-policy')) 'HYGIENE verification policy is never an authorizer here'
# --- D6 observation-only callbacks stay blocked without effects: null reconcile touches nothing.
$svD6 = New-ORActiveGoal 'G2-D6'
$seedD6 = New-OrchestrationDispatchIntent -GoalId 'G2-D6' -WorkItemId 'd6-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedD6.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-D6' -WorkItemId 'd6-w1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyD6 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-D6' -WorkItemId 'd6-w1' -ActionRevision 1
$proofD6 = New-ORProof -Key $keyD6 -Owner 'owner-1' -Gen 1
$rD6 = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-D6' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svD6.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $null -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofD6 -TestCallback
Assert-ORThat ([bool]$rD6.ok -and ([long]$rD6.reconciled -eq 0) -and ([long]$rD6.settled -eq 0)) 'D6 null observation callback leaves every intent untouched'
$afterD6 = Get-OrchestrationDispatchIntent -GoalId 'G2-D6' -WorkItemId 'd6-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$afterD6.intent['state'] -ceq 'pending') 'D6 unobserved intent stays pending'
# --- F1 (P1, REV+SEC): productive HOLD ENFORCED by construction.
# Without -TestCallback no effect seam is ever invoked (spy 0 calls).
$svF1 = New-ORActiveGoal 'G2-F1'
$evF1 = (New-OrchestrationObjectiveEvent -GoalId 'G2-F1' -Type 'task-settled' -WorkItemId 'f1-w1' -ActionRevision 1).event
$script:dispatchCalls = 0
$script:settleCalls = 0
$rF1 = Invoke-OrchestrationObjectiveEvent -Event $evF1 -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svF1.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle
Assert-ORThat ([bool]$rF1.ok -and ([string]$rF1.reason -ceq 'hold-productive-disabled:test-callback-absent') -and ([string]$rF1.intent_state -ceq 'held') -and (-not [bool]$rF1.dispatched)) 'F1 dispatch seam without -TestCallback is held by construction'
Assert-ORThat (($script:dispatchCalls -eq 0) -and ($script:settleCalls -eq 0)) 'F1 no productive callback invoked without -TestCallback (spy 0)'
$seedF1 = New-OrchestrationDispatchIntent -GoalId 'G2-F1' -WorkItemId 'f1-w2' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedF1.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-F1' -WorkItemId 'f1-w2' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$script:settleCalls = 0
$keyF1 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-F1' -WorkItemId 'f1-w2' -ActionRevision 1
$proofF1 = New-ORProof -Key $keyF1 -Owner 'owner-1' -Gen 1
$rF1R = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-F1' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svF1.revision) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofF1
Assert-ORThat (([long]$rF1R.settled -eq 0) -and ($script:settleCalls -eq 0)) 'F1 reconcile/settle seams without -TestCallback never invoked'
$afterF1 = Get-OrchestrationDispatchIntent -GoalId 'G2-F1' -WorkItemId 'f1-w2' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$afterF1.intent['state'] -ceq 'pending') 'F1 unobserved intent stays pending'
# --- F2 (P1 REV-2): settlement pre-callback revalidation (no window).
# Expired lease / live takeover => callback never invoked (spy 0).
$svF2 = New-ORActiveGoal 'G2-F2'
$seedF2 = New-OrchestrationDispatchIntent -GoalId 'G2-F2' -WorkItemId 'f2-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedF2.intent -StoreDir $ORDispatchStore
$ownerPathF2 = Get-OROwnerFilePath -Dir $ORDispatchStore -GoalId 'G2-F2'
$expiredF2 = [ordered]@{ schema_version = 1; goal_id = 'G2-F2'; owner_id = 'owner-1'; generation = [long]1; goal_revision = [long]$svF2.revision; acquired_at = '2026-01-01T00:00:00.0000000Z'; expires_at = '2026-01-01T00:01:00.0000000Z'; lease_ttl_ms = [long]60000; updated_at = '2026-01-01T00:00:00.0000000Z' }
[IO.File]::WriteAllText($ownerPathF2, (ConvertTo-Json -InputObject $expiredF2 -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
$script:settleCalls = 0
$keyF2 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-F2' -WorkItemId 'f2-w1' -ActionRevision 1
$proofF2 = New-ORProof -Key $keyF2 -Owner 'owner-1' -Gen 1
$authF2 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'settlement' -Resource 'f2-w1' -Decision 'settlement'
Assert-ORThat ([bool](Get-ORFieldValue $authF2 'admitted' $false)) 'F2 settlement auth envelope admitted for the fence probe'
$dirF2 = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $ORDispatchStore
$slF2 = Invoke-ORSettleUnderStoreLock -Dir $dirF2 -GoalId 'G2-F2' -WorkItemId 'f2-w1' -ActionRevision 1 -Key $keyF2 -OwnerId 'owner-1' -Generation 1 -Mark 'f2-mark' -SettleProof $proofF2 -SettleScript $FakeSettle -IntentSnapshot $seedF2.intent -DispatchReceipt $null -Goal $null -SettleAuth $authF2 -TestCallback
Assert-ORThat ((-not [bool]$slF2.ok) -and (-not [bool]$slF2.invoked) -and ($script:settleCalls -eq 0)) 'F2 expired lease never invokes the settlement callback'
$takeF2 = [ordered]@{ schema_version = 1; goal_id = 'G2-F2'; owner_id = 'owner-2'; generation = [long]6; goal_revision = [long]$svF2.revision; acquired_at = '2099-01-01T00:00:00.0000000Z'; expires_at = '2099-01-01T01:00:00.0000000Z'; lease_ttl_ms = [long]60000; updated_at = '2099-01-01T00:00:00.0000000Z' }
[IO.File]::WriteAllText($ownerPathF2, (ConvertTo-Json -InputObject $takeF2 -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
$slF2b = Invoke-ORSettleUnderStoreLock -Dir $dirF2 -GoalId 'G2-F2' -WorkItemId 'f2-w1' -ActionRevision 1 -Key $keyF2 -OwnerId 'owner-1' -Generation 1 -Mark 'f2-mark' -SettleProof $proofF2 -SettleScript $FakeSettle -IntentSnapshot $seedF2.intent -DispatchReceipt $null -Goal $null -SettleAuth $authF2 -TestCallback
Assert-ORThat ((-not [bool]$slF2b.ok) -and (-not [bool]$slF2b.invoked) -and ($script:settleCalls -eq 0)) 'F2 live takeover never invokes the settlement callback'
# --- F3 (P1 REV-3 + SEC-3): receipt bound to proof + operation-scoped + persisted.
$keyF3 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-F3' -WorkItemId 'f3-w1' -ActionRevision 1
$proofF3 = New-ORProof -Key $keyF3 -Owner 'owner-1' -Gen 1 -Dst 'dest-stub' -Act 'act-stub'
$swappedF3 = [pscustomobject]@{ destination = 'fake-dest'; action = 'fake-act'; operation = 'dispatch'; task_id = 'fake-task'; run_id = 'fake-run'; generation = [long]1; result = 'x'; idempotency_key = $keyF3 }
$rcF3swap = Test-OREffectReceipt -Receipt $swappedF3 -Key $keyF3 -Generation 1 -Proof $proofF3 -Operation 'dispatch'
Assert-ORThat ((-not [bool]$rcF3swap.ok) -and (([string]$rcF3swap.reason -ceq 'receipt-destination-mismatch') -or ([string]$rcF3swap.reason -ceq 'receipt-action-mismatch'))) 'F3 swapped destination/action against the proof is rejected'
$dispatchRcF3 = [pscustomobject]@{ destination = 'dest-stub'; action = 'act-stub'; operation = 'dispatch'; task_id = 'fake-task'; run_id = 'fake-run'; generation = [long]1; result = 'fake-result'; idempotency_key = $keyF3 }
$rcF3op = Test-OREffectReceipt -Receipt $dispatchRcF3 -Key $keyF3 -Generation 1 -Proof $proofF3 -Operation 'settlement'
Assert-ORThat ((-not [bool]$rcF3op.ok) -and ([string]$rcF3op.reason -ceq 'receipt-operation-mismatch')) 'F3 dispatch receipt never satisfies the settlement gate'
$svF3 = New-ORActiveGoal 'G2-F3S'
$keyF3S = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-F3S' -WorkItemId 'f3s-w1' -ActionRevision 1
$proofF3S = New-ORProof -Key $keyF3S -Owner 'owner-1' -Gen 1
$evF3S = (New-OrchestrationObjectiveEvent -GoalId 'G2-F3S' -Type 'task-settled' -WorkItemId 'f3s-w1' -ActionRevision 1).event
$rF3S = Invoke-OrchestrationObjectiveEvent -Event $evF3S -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svF3.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofF3S -SettleProof $proofF3S -TestCallback
Assert-ORThat ([bool]$rF3S.ok -and ([string]$rF3S.intent_state -ceq 'advanced')) 'F3 full dispatch setup advanced'
$storedF3S = Get-OrchestrationDispatchIntent -GoalId 'G2-F3S' -WorkItemId 'f3s-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat (($null -ne (Get-ORFieldValue $storedF3S.intent 'settlement_receipt' $null)) -and ([string](Get-ORFieldValue (Get-ORFieldValue $storedF3S.intent 'settlement_receipt' $null) 'operation' '') -ceq 'settlement')) 'F3 settlement receipt persisted atomically with the transition (crash-durable)'
# --- F4 (P2 REV-4): identity before any write (grafia divergente => HOLD, registro preservado).
$svF4 = New-ORActiveGoal 'G2-F4X'
$acF4 = Acquire-OrchestrationObjectiveOwnership -GoalId 'G2-F4X' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svF4.revision) -StoreDir $ORDispatchStore -GoalStoreDir $ORGoalStore
Assert-ORThat ([bool]$acF4.ok) 'F4 baseline acquire ok'
$acF4div = Acquire-OrchestrationObjectiveOwnership -GoalId 'g2-f4x' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svF4.revision) -StoreDir $ORDispatchStore -GoalStoreDir $ORGoalStore
Assert-ORThat ((-not [bool]$acF4div.ok) -and ([string]$acF4div.reason -ceq 'identity-hold-case-divergence')) 'F4 divergent grafia with same owner/revision is HOLD'
$ownerPathF4 = Get-OROwnerFilePath -Dir $ORDispatchStore -GoalId 'G2-F4X'
$rawF4 = ConvertFrom-Json ([IO.File]::ReadAllText($ownerPathF4, [Text.Encoding]::UTF8))
Assert-ORThat ([string](Get-ORFieldValue $rawF4 'goal_id' '') -ceq 'G2-F4X') 'F4 stored record preserved untouched (no rename, no overwrite)'
# --- F5 (P2 REV-5): advanced persists next_move; replay recovers after crash-before-delivery.
$storedF5 = Get-OrchestrationDispatchIntent -GoalId 'G2-F3S' -WorkItemId 'f3s-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat (($null -ne (Get-ORFieldValue $storedF5.intent 'next_move' $null)) -and ([string](Get-ORFieldValue (Get-ORFieldValue $storedF5.intent 'next_move' $null) 'move' '') -ceq 'CONTINUE')) 'F5 continuation move persisted atomically with advanced'
$rF5replay = Invoke-OrchestrationObjectiveEvent -Event $evF3S -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svF3.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofF3S -SettleProof $proofF3S -TestCallback
Assert-ORThat ([bool]$rF5replay.duplicate -and ($null -ne $rF5replay.next_move) -and ([string]$rF5replay.next_move.move -ceq 'CONTINUE')) 'F5 crash-before-delivery replay recovers the persisted move'
# --- F6 (P2 REV-6): N->N+1 -- reconcile of a pending N intent after the Goal moved to N+1 recovers without new dispatch.
$svF6 = New-ORActiveGoal 'G2-F6'
$keyF6 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-F6' -WorkItemId 'f6-w1' -ActionRevision 1
$proofF6 = New-ORProof -Key $keyF6 -Owner 'owner-1' -Gen 1
$evF6 = (New-OrchestrationObjectiveEvent -GoalId 'G2-F6' -Type 'task-settled' -WorkItemId 'f6-w1' -ActionRevision 1).event
$script:dispatchCalls = 0
$script:settleCalls = 0
$rF6pend = Invoke-OrchestrationObjectiveEvent -Event $evF6 -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svF6.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofF6 -SettleProof $proofF6 -TestCallback
Assert-ORThat (([string]$rF6pend.intent_state -ceq 'pending') -and ([string]$rF6pend.settlement -ceq 'pending-reconciliation')) 'F6 N intent waits pending (settlement gate closed)'
$upF6 = Update-OrchestrationGoal -GoalId 'G2-F6' -ExpectedRevision ([long]$svF6.revision) -Fields @{ budget = @{ soft_cap = 10; hard_cap = 20; spent = 1 } } -StoreDir $ORGoalStore
Assert-ORThat ([bool]$upF6.ok) 'F6 goal advanced N->N+1'
$dcF6 = $script:dispatchCalls
$rF6rec = Invoke-OrchestrationObjectiveReconcile -GoalId 'G2-F6' -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$upF6.goal['revision']) -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -SettleProof $proofF6 -TestCallback
Assert-ORThat ([bool]$rF6rec.ok -and ([long]$rF6rec.settled -eq 1) -and ([long]$rF6rec.redispatched -eq 0)) 'F6 N+1 reconcile settles the prior N effect with no new dispatch'
Assert-ORThat ($script:dispatchCalls -eq $dcF6) 'F6 no duplicate effect across the revision move'
$afterF6 = Get-OrchestrationDispatchIntent -GoalId 'G2-F6' -WorkItemId 'f6-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$afterF6.intent['state'] -ceq 'settled') 'F6 prior intent settled at N+1'
# --- F7 (SEC-2 media, runtime fallback mirror): strict grammar.
$scopedDenyF7 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch:w1;deny:dispatch:w1' -Operation 'dispatch' -Resource 'w1' -Decision 'dispatch'
Assert-ORThat (-not [bool]$scopedDenyF7.admitted) 'F7 scoped deny prevails over allow in any order (fallback)'
$decDenyF7 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch' -Operation 'dispatch' -Resource 'w1' -Decision 'deny'
Assert-ORThat (-not [bool]$decDenyF7.admitted) 'F7 negative Decision vetoes an allow (fallback)'
$malformedF7 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch allow:dispatch:' -Operation 'dispatch' -Resource 'w1' -Decision 'dispatch'
Assert-ORThat (-not [bool]$malformedF7.admitted) 'F7 malformed grant token denies (fallback)'
# --- M1 (SEC-PR2-04): -TestCallback gate on EVERY callback path (spy 0 without switch).
$script:settleCalls = 0
$slM1a = Invoke-ORSettleUnderStoreLock -Dir $dirF2 -GoalId 'G2-F2' -WorkItemId 'f2-w1' -ActionRevision 1 -Key $keyF2 -OwnerId 'owner-1' -Generation 1 -Mark 'm1-mark' -SettleProof $proofF2 -SettleScript $FakeSettle -IntentSnapshot $seedF2.intent -DispatchReceipt $null -Goal $null -SettleAuth $authF2
Assert-ORThat ((-not [bool]$slM1a.ok) -and ([string]$slM1a.reason -ceq 'hold-productive-disabled:test-callback-absent') -and (-not [bool]$slM1a.invoked) -and ($script:settleCalls -eq 0)) 'M1 settle helper without -TestCallback never invokes (spy 0)'
$slM1b = Invoke-ORSettleUnderStoreLock -Dir $dirF2 -GoalId 'G2-F2' -WorkItemId 'f2-w1' -ActionRevision 1 -Key $keyF2 -OwnerId 'owner-1' -Generation 1 -Mark 'm1-mark' -SettleProof $proofF2 -SettleScript $FakeSettle -IntentSnapshot $seedF2.intent -DispatchReceipt $null -Goal $null -SettleAuth $null -TestCallback
Assert-ORThat ((-not [bool]$slM1b.ok) -and ([string]$slM1b.reason -ceq 'settlement-auth-denied') -and (-not [bool]$slM1b.invoked) -and ($script:settleCalls -eq 0)) 'M1 settle helper without settlement auth never invokes (spy 0)'
$authM1bad = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -Operation 'dispatch' -Resource 'f2-w1' -Decision 'dispatch'
$slM1c = Invoke-ORSettleUnderStoreLock -Dir $dirF2 -GoalId 'G2-F2' -WorkItemId 'f2-w1' -ActionRevision 1 -Key $keyF2 -OwnerId 'owner-1' -Generation 1 -Mark 'm1-mark' -SettleProof $proofF2 -SettleScript $FakeSettle -IntentSnapshot $seedF2.intent -DispatchReceipt $null -Goal $null -SettleAuth $authM1bad -TestCallback
Assert-ORThat ((-not [bool]$slM1c.ok) -and ([string]$slM1c.reason -ceq 'settlement-auth-denied') -and (-not [bool]$slM1c.invoked) -and ($script:settleCalls -eq 0)) 'M1 settle helper with a non-settlement envelope never invokes (spy 0)'
$script:ckptCalls = 0
$script:moveCalls = 0
$CkptSpy = { param($goal) $script:ckptCalls++; return @{ checkpoint_id = 'ck-spy' } }
$MoveSpy = { param($goal) $script:moveCalls++; return @{ move = 'SPY' } }
$m1d = Invoke-ORCheckpoint $null $CkptSpy
Assert-ORThat (([string]$m1d -ceq '') -and ($script:ckptCalls -eq 0)) 'M1 checkpoint impl without -TestCallback never invoked (spy 0)'
$m1e = Invoke-ORControllerMove $null $MoveSpy
Assert-ORThat (($null -eq $m1e) -and ($script:moveCalls -eq 0)) 'M1 next-move impl without -TestCallback never invoked (spy 0)'
$m1f = Invoke-ORCheckpoint $null $CkptSpy -TestCallback
Assert-ORThat (([string]$m1f -ceq 'ck-spy') -and ($script:ckptCalls -eq 1)) 'M1 checkpoint impl with -TestCallback invoked once'
$m1g = Invoke-ORControllerMove $null $MoveSpy -TestCallback
Assert-ORThat (($null -ne $m1g) -and ($script:moveCalls -eq 1)) 'M1 next-move impl with -TestCallback invoked once'
# --- M2 (SEC-PR2-04): mandatory bound receipt in the settled CAS.
$svM2 = New-ORActiveGoal 'G2-M2'
$seedM2 = New-OrchestrationDispatchIntent -GoalId 'G2-M2' -WorkItemId 'm2-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedM2.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-M2' -WorkItemId 'm2-w1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyM2 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-M2' -WorkItemId 'm2-w1' -ActionRevision 1
$proofM2 = New-ORProof -Key $keyM2 -Owner 'owner-1' -Gen 1
$rcM2 = @{ destination = 'dest-stub'; action = 'act-stub'; operation = 'settlement'; task_id = 'fake-task'; run_id = 'fake-run'; generation = [long]1; result = 'fake-settled'; idempotency_key = $keyM2 }
$tM2a = Set-ORDispatchSettledCAS -GoalId 'G2-M2' -WorkItemId 'm2-w1' -ActionRevision 1 -ConsumedFrom 'm2-mark' -StoreDir $ORDispatchStore -Generation 1 -SettlementReceipt $null -SettleProof $proofM2
Assert-ORThat ((-not [bool]$tM2a.ok) -and ([string]$tM2a.reason -ceq 'settlement-receipt-missing')) 'M2 null settlement receipt rejected'
$tM2b = Set-ORDispatchSettledCAS -GoalId 'G2-M2' -WorkItemId 'm2-w1' -ActionRevision 1 -ConsumedFrom 'm2-mark' -StoreDir $ORDispatchStore -Generation 1 -SettlementReceipt $rcM2
Assert-ORThat ((-not [bool]$tM2b.ok) -and ([string]$tM2b.reason -ceq 'settlement-proof-missing')) 'M2 settlement without proof rejected'
$seedM2b = New-OrchestrationDispatchIntent -GoalId 'G2-M2' -WorkItemId 'm2-w2' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedM2b.intent -StoreDir $ORDispatchStore
$keyM2b = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-M2' -WorkItemId 'm2-w2' -ActionRevision 1
$proofM2b = New-ORProof -Key $keyM2b -Owner 'owner-1' -Gen 1
$rcM2b = @{ destination = 'dest-stub'; action = 'act-stub'; operation = 'settlement'; task_id = 'fake-task'; run_id = 'fake-run'; generation = [long]1; result = 'fake-settled'; idempotency_key = $keyM2b }
$tM2c = Set-ORDispatchSettledCAS -GoalId 'G2-M2' -WorkItemId 'm2-w2' -ActionRevision 1 -ConsumedFrom 'm2-mark' -StoreDir $ORDispatchStore -Generation 1 -SettlementReceipt $rcM2b -SettleProof $proofM2b
Assert-ORThat ((-not [bool]$tM2c.ok) -and ([string]$tM2c.reason -ceq 'invalid-transition')) 'M2 intended->settled direct rejected'
$seedM2c = New-OrchestrationDispatchIntent -GoalId 'G2-M2' -WorkItemId 'm2-w3' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedM2c.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-M2' -WorkItemId 'm2-w3' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyM2c = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-M2' -WorkItemId 'm2-w3' -ActionRevision 1
$proofM2c = New-ORProof -Key $keyM2c -Owner 'owner-1' -Gen 1
$rcM2dispatch = @{ destination = 'dest-stub'; action = 'act-stub'; operation = 'dispatch'; task_id = 'fake-task'; run_id = 'fake-run'; generation = [long]1; result = 'fake-result'; idempotency_key = $keyM2c }
$tM2d = Set-ORDispatchSettledCAS -GoalId 'G2-M2' -WorkItemId 'm2-w3' -ActionRevision 1 -ConsumedFrom 'm2-mark' -StoreDir $ORDispatchStore -Generation 1 -SettlementReceipt $rcM2dispatch -SettleProof $proofM2c
Assert-ORThat ((-not [bool]$tM2d.ok) -and ([string]$tM2d.reason -ceq 'receipt-operation-mismatch')) 'M2 dispatch receipt never satisfies the settlement CAS'
$tM2e = Set-ORDispatchSettledCAS -GoalId 'G2-M2' -WorkItemId 'm2-w1' -ActionRevision 1 -ConsumedFrom 'm2-mark' -StoreDir $ORDispatchStore -Generation 1 -SettlementReceipt $rcM2 -SettleProof $proofM2
Assert-ORThat ([bool]$tM2e.ok -and ([string]$tM2e.intent['state'] -ceq 'settled')) 'M2 pending->settled with bound receipt settles'
$afterM2 = Get-OrchestrationDispatchIntent -GoalId 'G2-M2' -WorkItemId 'm2-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat (([string](Get-ORFieldValue (Get-ORFieldValue $afterM2.intent 'settlement_receipt' $null) 'operation' '') -ceq 'settlement')) 'M2 settlement receipt persisted with the transition'
# --- M2 residual (SEC-PR2-05): empty/incomplete SettleProof rejected by the proof gate before the transition.
$seedM2e2 = New-OrchestrationDispatchIntent -GoalId 'G2-M2' -WorkItemId 'm2-w4' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedM2e2.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-M2' -WorkItemId 'm2-w4' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyM2e2 = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-M2' -WorkItemId 'm2-w4' -ActionRevision 1
$rcM2e2 = @{ destination = 'dest-stub'; action = 'act-stub'; operation = 'settlement'; task_id = 'fake-task'; run_id = 'fake-run'; generation = [long]1; result = 'fake-settled'; idempotency_key = $keyM2e2 }
$tM2empty = Set-ORDispatchSettledCAS -GoalId 'G2-M2' -WorkItemId 'm2-w4' -ActionRevision 1 -ConsumedFrom 'm2-mark' -StoreDir $ORDispatchStore -Generation 1 -SettlementReceipt $rcM2e2 -SettleProof @{}
Assert-ORThat ((-not [bool]$tM2empty.ok)) 'M2 empty SettleProof @{} rejected'
$afterM2empty = Get-OrchestrationDispatchIntent -GoalId 'G2-M2' -WorkItemId 'm2-w4' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$afterM2empty.intent['state'] -ceq 'pending') 'M2 empty proof leaves intent pending'
$proofM2noact = @{ destination = 'dest-stub'; fencing_owner = 'owner-1'; fencing_generation = [long]1; idempotency_key = $keyM2e2 }
$tM2noact = Set-ORDispatchSettledCAS -GoalId 'G2-M2' -WorkItemId 'm2-w4' -ActionRevision 1 -ConsumedFrom 'm2-mark' -StoreDir $ORDispatchStore -Generation 1 -SettlementReceipt $rcM2e2 -SettleProof $proofM2noact
Assert-ORThat ((-not [bool]$tM2noact.ok)) 'M2 proof without action rejected'
$proofM2e2 = New-ORProof -Key $keyM2e2 -Owner 'owner-1' -Gen 1
$tM2oke2 = Set-ORDispatchSettledCAS -GoalId 'G2-M2' -WorkItemId 'm2-w4' -ActionRevision 1 -ConsumedFrom 'm2-mark' -StoreDir $ORDispatchStore -Generation 1 -SettlementReceipt $rcM2e2 -SettleProof $proofM2e2
Assert-ORThat ([bool]$tM2oke2.ok -and ([string]$tM2oke2.intent['state'] -ceq 'settled')) 'M2 valid proof + bound receipt settles'
# --- M2 replay: settled without a valid receipt returns to pending, never advances.
$svM2R = New-ORActiveGoal 'G2-M2R'
$seedM2R = New-OrchestrationDispatchIntent -GoalId 'G2-M2R' -WorkItemId 'm2r-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedM2R.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-M2R' -WorkItemId 'm2r-w1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$pathM2R = Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'G2-M2R' -WorkItemId 'm2r-w1' -ActionRevision 1
$rawM2R = ConvertFrom-Json ([IO.File]::ReadAllText($pathM2R, [Text.Encoding]::UTF8))
$rawM2R.state = 'settled'
[IO.File]::WriteAllText($pathM2R, (ConvertTo-Json -InputObject $rawM2R -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
$keyM2R = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-M2R' -WorkItemId 'm2r-w1' -ActionRevision 1
$proofM2R = New-ORProof -Key $keyM2R -Owner 'owner-1' -Gen 1
$evM2R = (New-OrchestrationObjectiveEvent -GoalId 'G2-M2R' -Type 'task-settled' -WorkItemId 'm2r-w1' -ActionRevision 1).event
$script:dispatchCalls = 0
$script:settleCalls = 0
$rM2R = Invoke-OrchestrationObjectiveEvent -Event $evM2R -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svM2R.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -CheckpointImpl $CkptSpy -NextMoveImpl $MoveSpy -DispatchProof $proofM2R -SettleProof $proofM2R -TestCallback
Assert-ORThat (([string]$rM2R.decision -ceq 'settlement-pending') -and ([string]$rM2R.intent_state -ceq 'pending') -and (-not [bool]$rM2R.dispatched)) 'M2 receipt-less settled replay never advances'
Assert-ORThat (($script:dispatchCalls -eq 0) -and ($script:settleCalls -eq 0) -and ($script:ckptCalls -eq 1) -and ($script:moveCalls -eq 1)) 'M2 receipt-less replay invokes no callback on the demote path'
$afterM2R = Get-OrchestrationDispatchIntent -GoalId 'G2-M2R' -WorkItemId 'm2r-w1' -ActionRevision 1 -StoreDir $ORDispatchStore
Assert-ORThat ([string]$afterM2R.intent['state'] -ceq 'pending') 'M2 receipt-less settled returns to pending'
# --- M1 replay: settled WITH a valid receipt but WITHOUT -TestCallback never forwards impls.
$svM2S = New-ORActiveGoal 'G2-M2S'
$seedM2S = New-OrchestrationDispatchIntent -GoalId 'G2-M2S' -WorkItemId 'm2s-w1' -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedM2S.intent -StoreDir $ORDispatchStore
$null = Set-OrchestrationDispatchState -GoalId 'G2-M2S' -WorkItemId 'm2s-w1' -ActionRevision 1 -State 'pending' -StoreDir $ORDispatchStore
$keyM2S = Get-OrchestrationObjectiveIdempotencyKey -GoalId 'G2-M2S' -WorkItemId 'm2s-w1' -ActionRevision 1
$rawM2S = ConvertFrom-Json ([IO.File]::ReadAllText((Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'G2-M2S' -WorkItemId 'm2s-w1' -ActionRevision 1), [Text.Encoding]::UTF8))
$rawM2S.state = 'settled'
$rawM2S.generation = [long]1
$rawM2S | Add-Member -NotePropertyName 'settlement_receipt' -NotePropertyValue ([pscustomobject]@{ destination = 'dest-stub'; action = 'act-stub'; operation = 'settlement'; task_id = 'fake-task'; run_id = 'fake-run'; generation = [long]1; result = 'fake-settled'; idempotency_key = $keyM2S }) -Force
[IO.File]::WriteAllText((Get-ORIntentFilePath -Dir $ORDispatchStore -GoalId 'G2-M2S' -WorkItemId 'm2s-w1' -ActionRevision 1), (ConvertTo-Json -InputObject $rawM2S -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
$proofM2S = New-ORProof -Key $keyM2S -Owner 'owner-1' -Gen 1
$evM2S = (New-OrchestrationObjectiveEvent -GoalId 'G2-M2S' -Type 'task-settled' -WorkItemId 'm2s-w1' -ActionRevision 1).event
$script:ckptCalls = 0
$script:moveCalls = 0
$rM2S = Invoke-OrchestrationObjectiveEvent -Event $evM2S -GoalStoreDir $ORGoalStore -DispatchStoreDir $ORDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$svM2S.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -CheckpointImpl $CkptSpy -NextMoveImpl $MoveSpy -DispatchProof $proofM2S -SettleProof $proofM2S
Assert-ORThat (([string]$rM2S.decision -ceq 'settlement-pending') -and ($script:ckptCalls -eq 0) -and ($script:moveCalls -eq 0)) 'M1 settled replay without -TestCallback never forwards impls (spy 0)'
try { Remove-Item -LiteralPath $ORGoalStore -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $ORDispatchStore -Recurse -Force -ErrorAction SilentlyContinue } catch { }
'PASS: {0}' -f $passed
