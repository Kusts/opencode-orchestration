[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalPromotion.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationRuntimeAdapterContract.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveRuntime.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalPromotionWiring.ps1')
$passed = 0
function Assert-GPWThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
$TempBase = [IO.Path]::GetTempPath()
$GPWGoalStore = Join-Path $TempBase ('gpw-goal-' + [guid]::NewGuid().ToString('N'))
$GPWDispatchStore = Join-Path $TempBase ('gpw-dispatch-' + [guid]::NewGuid().ToString('N'))
$GPWCheckpointStore = Join-Path $TempBase ('gpw-ckpt-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($GPWGoalStore)
[void][IO.Directory]::CreateDirectory($GPWDispatchStore)
[void][IO.Directory]::CreateDirectory($GPWCheckpointStore)
$script:GFull = 'ops allow:dispatch allow:settlement allow:checkpoint allow:advance allow:terminalize allow:reconcile'
$script:dispatchCalls = 0
$script:settleCalls = 0
function New-GPWProof {
    param([string]$Key = '', [string]$Owner = '', [long]$Gen = 0)
    return @{ destination = 'dest-stub'; action = 'act-stub'; fencing_owner = $Owner; fencing_generation = $Gen; idempotency_key = $Key }
}
$FakeDispatch = { param($intent, $goal, $auth) $script:dispatchCalls++; return [pscustomobject]@{ ok = $true; dispatched = $true; task_id = 'fake-task'; run_id = 'fake-run'; destination = 'dest-stub'; action = 'act-stub'; operation = 'dispatch'; generation = $intent['generation']; result = 'fake-result'; idempotency_key = $intent['key']; reason = 'fake-dispatched' } }
$FakeSettle = { param($intent, $dispatch, $goal) $script:settleCalls++; $g = $intent['generation']; if ([long]$g -lt 1) { $g = [long]1 }; return [pscustomobject]@{ ok = $true; task_id = 'fake-task'; run_id = 'fake-run'; destination = 'dest-stub'; action = 'act-stub'; operation = 'settlement'; generation = $g; result = 'fake-settled'; idempotency_key = $intent['key']; reason = 'fake-settled' } }
$FakeReconcile = { param($intent) return [pscustomobject]@{ ok = $true; effect_observed = $true; reason = 'fake-observed' } }
function New-GPWSpecSignals {
    return @{
        has_spec_plan = $true; phase_count = 3; expected_waves = 3; criteria_count = 3
        likely_cross_session = $true; iterative_verification = $true; explicit_continuation = $false
    }
}
function New-GPWTaskSignals {
    return @{
        has_spec_plan = $false; phase_count = 0; expected_waves = 0; criteria_count = 0
        likely_cross_session = $false; iterative_verification = $false; explicit_continuation = $false
    }
}
# --- VERSION: PR-3 wiring identity.
$v = Get-OrchestrationGoalPromotionWiringVersion
Assert-GPWThat (([long]$v.schema_version -eq 1) -and ([string]$v.phase -ceq 'PR-3')) 'VERSION schema 1 phase PR-3'
# --- Deterministic promotion key: same inputs map to the same goal_id.
$idA = Get-GPWGoalId -Objective 'PR-3 wiring objective alpha' -Criteria @('c1', 'c2', 'c3')
$idB = Get-GPWGoalId -Objective 'PR-3 wiring objective alpha' -Criteria @('c1', 'c2', 'c3')
$idC = Get-GPWGoalId -Objective 'PR-3 wiring objective beta' -Criteria @('c1', 'c2', 'c3')
Assert-GPWThat ((-not [string]::IsNullOrWhiteSpace($idA)) -and ($idA -ceq $idB) -and ($idA -cne $idC)) 'KEY same promotion key yields the same goal_id, other objective differs'
Assert-GPWThat ($idA -cmatch '^[A-Za-z0-9._:-]{1,64}$') 'KEY goal_id respects the kernel charset'
# --- (a) SPEC+PLAN promotes exactly once under duplicated promotion calls.
$p1 = Invoke-OrchestrationGoalAutoPromotion -Signals (New-GPWSpecSignals) -Objective 'PR-3 wiring objective alpha' -Criteria @('c1', 'c2', 'c3') -VerificationSurfaces @('suite-x') -GoalStoreDir $GPWGoalStore
Assert-GPWThat ([bool]$p1.ok -and [bool]$p1.promoted -and (-not [bool]$p1.duplicate) -and ([string]$p1.shape -ceq 'persistent-goal') -and (-not [bool]$p1.dispatched)) 'PROMOTE SPEC+PLAN creates one ACTIVE-track Goal without dispatch'
Assert-GPWThat ((-not [bool]$p1.grants_authority) -and (-not [bool]$p1.done_approved) -and (-not [bool]$p1.verified_pass)) 'PROMOTE claims no authority DONE or verified pass'
$p2 = Invoke-OrchestrationGoalAutoPromotion -Signals (New-GPWSpecSignals) -Objective 'PR-3 wiring objective alpha' -Criteria @('c1', 'c2', 'c3') -VerificationSurfaces @('suite-x') -GoalStoreDir $GPWGoalStore
Assert-GPWThat ([bool]$p2.ok -and [bool]$p2.promoted -and [bool]$p2.duplicate -and ([string]$p2.goal_id -ceq [string]$p1.goal_id) -and ([long]$p2.revision -eq [long]$p1.revision)) 'PROMOTE retry maps to the same goal_id as duplicate, same revision'
$goalFiles = @(Get-ChildItem -LiteralPath $GPWGoalStore -File -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-GPWThat (([long]$goalFiles.Count -eq 1)) 'PROMOTE duplicated retry leaves exactly one Goal record'
$liveA = Get-OrchestrationGoal -GoalId ([string]$p1.goal_id) -StoreDir $GPWGoalStore
Assert-GPWThat ([bool]$liveA.ok -and ([string]$liveA.goal['state'] -ceq 'ACTIVE') -and ([long](@($liveA.goal['active_tasks'])).Count -eq 3)) 'LIFECYCLE Goal is ACTIVE with one derived work item per phase'
# --- (a2) Repeated executor events on a derived work item collapse to one logical dispatch.
$wid1 = ([string]$p1.goal_id + ':phase-1')
$key1 = Get-OrchestrationObjectiveIdempotencyKey -GoalId ([string]$p1.goal_id) -WorkItemId $wid1 -ActionRevision 1
$proof1 = New-GPWProof -Key $key1 -Owner 'owner-1' -Gen 1
$ev1 = (New-OrchestrationObjectiveEvent -GoalId ([string]$p1.goal_id) -Type 'task-settled' -WorkItemId $wid1 -ActionRevision 1).event
$script:dispatchCalls = 0
$script:settleCalls = 0
$r1 = Invoke-OrchestrationObjectiveEvent -Event $ev1 -GoalStoreDir $GPWGoalStore -DispatchStoreDir $GPWDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$liveA.goal['revision']) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proof1 -SettleProof $proof1 -TestCallback
Assert-GPWThat ([bool]$r1.ok -and [bool]$r1.dispatched -and ([string]$r1.intent_state -ceq 'advanced')) 'EVENT first work-item event dispatches once via the restricted executor'
$r1dup = Invoke-OrchestrationObjectiveEvent -Event $ev1 -GoalStoreDir $GPWGoalStore -DispatchStoreDir $GPWDispatchStore -OwnerId 'owner-1' -Generation 1 -ExpectedRevision ([long]$liveA.goal['revision']) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proof1 -SettleProof $proof1 -TestCallback
Assert-GPWThat ([bool]$r1dup.ok -and [bool]$r1dup.duplicate -and (-not [bool]$r1dup.dispatched)) 'EVENT repeated event is a duplicate with no second dispatch'
Assert-GPWThat (([long]$script:dispatchCalls -eq 1) -and ([long]$script:settleCalls -eq 1)) 'EVENT executor seams ran exactly once across the duplicate'
# --- (b) Common task never creates a Goal.
$before = @((Get-ChildItem -LiteralPath $GPWGoalStore -File -Filter '*.json' -ErrorAction SilentlyContinue)).Count
$t1 = Invoke-OrchestrationGoalAutoPromotion -Signals (New-GPWTaskSignals) -Objective 'PR-3 trivial task' -Criteria @() -GoalStoreDir $GPWGoalStore
Assert-GPWThat ([bool]$t1.ok -and (-not [bool]$t1.promoted) -and ([string]$t1.goal_id -ceq '') -and ([string]$t1.shape -ceq 'task')) 'TASK below-threshold signals stay task with no Goal'
$after = @((Get-ChildItem -LiteralPath $GPWGoalStore -File -Filter '*.json' -ErrorAction SilentlyContinue)).Count
Assert-GPWThat ([long]$after -eq [long]$before) 'TASK no Goal record is written for a common task'
# --- (c) Resume retakes a pending intent exactly once (no duplicate settlement).
$pC = Invoke-OrchestrationGoalAutoPromotion -Signals (New-GPWSpecSignals) -Objective 'PR-3 resume objective' -Criteria @('c1') -VerificationSurfaces @('suite-x') -GoalStoreDir $GPWGoalStore
Assert-GPWThat ([bool]$pC.ok -and [bool]$pC.promoted) 'RESUME promotion fixture created'
$widC = ([string]$pC.goal_id + ':phase-1')
$seedC = New-OrchestrationDispatchIntent -GoalId ([string]$pC.goal_id) -WorkItemId $widC -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedC.intent -StoreDir $GPWDispatchStore
$null = Set-OrchestrationDispatchState -GoalId ([string]$pC.goal_id) -WorkItemId $widC -ActionRevision 1 -State 'pending' -StoreDir $GPWDispatchStore
$keyC = Get-OrchestrationObjectiveIdempotencyKey -GoalId ([string]$pC.goal_id) -WorkItemId $widC -ActionRevision 1
$proofC = New-GPWProof -Key $keyC -Owner 'owner-9' -Gen 1
$script:settleCalls = 0
$s1 = Resume-OrchestrationGoalSession -GoalId ([string]$pC.goal_id) -GoalStoreDir $GPWGoalStore -DispatchStoreDir $GPWDispatchStore -CheckpointStoreDir $GPWCheckpointStore -OwnerId 'owner-9' -Generation 1 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -SettleProof $proofC -TestCallback
Assert-GPWThat ([bool]$s1.ok -and [bool]$s1.resumed -and (-not [bool]$s1.session_missing) -and ([long]$s1.settled -eq 1) -and [bool]$s1.restored -and (-not [string]::IsNullOrWhiteSpace([string]$s1.checkpoint_id))) 'RESUME first pass settles the pending intent and restores a checkpoint'
Assert-GPWThat ((-not [bool]$s1.dispatched) -and ([string]$s1.decision -ceq 'continue') -and (-not [bool]$s1.grants_authority) -and (-not [bool]$s1.done_approved)) 'RESUME continues non-concluded work claiming no authority and no dispatch'
Assert-GPWThat ([long]$script:settleCalls -eq 1) 'RESUME settlement seam ran once'
$s2 = Resume-OrchestrationGoalSession -GoalId ([string]$pC.goal_id) -GoalStoreDir $GPWGoalStore -DispatchStoreDir $GPWDispatchStore -CheckpointStoreDir $GPWCheckpointStore -OwnerId 'owner-9' -Generation 1 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -SettleProof $proofC -TestCallback
Assert-GPWThat ([bool]$s2.ok -and [bool]$s2.resumed -and ([long]$s2.settled -eq 0) -and ([string]$s2.checkpoint_id -ceq [string]$s1.checkpoint_id)) 'RESUME second pass settles nothing new and restores the same checkpoint'
Assert-GPWThat ([long]$script:settleCalls -eq 1) 'RESUME no duplicate settlement across resume passes'
# --- (c2) Missing session is never a failure.
$sMissing = Resume-OrchestrationGoalSession -GoalId 'gp-deadbeefdeadbeef' -GoalStoreDir $GPWGoalStore -DispatchStoreDir $GPWDispatchStore -CheckpointStoreDir $GPWCheckpointStore -OwnerId 'owner-9' -Generation 1 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -TestCallback
Assert-GPWThat ([bool]$sMissing.ok -and (-not [bool]$sMissing.resumed) -and [bool]$sMissing.session_missing) 'RESUME missing session returns ok with session-missing, never a failure'
# --- (c3) Without -TestCallback no seam is ever invoked (spy 0, HOLD).
$script:settleCalls = 0
$sHold = Resume-OrchestrationGoalSession -GoalId ([string]$pC.goal_id) -GoalStoreDir $GPWGoalStore -DispatchStoreDir $GPWDispatchStore -CheckpointStoreDir $GPWCheckpointStore -OwnerId 'owner-9' -Generation 1 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -SettleProof $proofC
Assert-GPWThat ([bool]$sHold.ok -and ([string]$sHold.reason -ceq 'hold-productive-disabled:test-callback-absent') -and ([long]$script:settleCalls -eq 0)) 'HOLD resume without -TestCallback never invokes seams (spy 0)'
# --- (d) Terminal Goal blocks new dispatch; prior-effect settlement still OK.
$term = Move-OrchestrationGoalLifecycle -GoalId ([string]$pC.goal_id) -ToState 'CANCELLED' -StoreDir $GPWGoalStore
Assert-GPWThat ([bool]$term.ok -and ([string]$term.state -ceq 'CANCELLED')) 'LIFECYCLE ACTIVE transitions to CANCELLED per the kernel table'
$gate = Test-OrchestrationGoalDispatchAllowed -GoalId ([string]$pC.goal_id) -StoreDir $GPWGoalStore
Assert-GPWThat ((-not [bool]$gate.allowed) -and ([string]$gate.reason -ceq 'terminal-goal-no-dispatch')) 'LIFECYCLE terminal Goal denies new dispatch'
$widT = ([string]$pC.goal_id + ':phase-2')
$evT = (New-OrchestrationObjectiveEvent -GoalId ([string]$pC.goal_id) -Type 'task-settled' -WorkItemId $widT -ActionRevision 1).event
$keyT = Get-OrchestrationObjectiveIdempotencyKey -GoalId ([string]$pC.goal_id) -WorkItemId $widT -ActionRevision 1
$proofT = New-GPWProof -Key $keyT -Owner 'owner-9' -Gen 1
$script:dispatchCalls = 0
$script:settleCalls = 0
$rT = Invoke-OrchestrationObjectiveEvent -Event $evT -GoalStoreDir $GPWGoalStore -DispatchStoreDir $GPWDispatchStore -OwnerId 'owner-9' -Generation 1 -ExpectedRevision ([long]$term.revision) -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -DispatchImpl $FakeDispatch -SettleImpl $FakeSettle -DispatchProof $proofT -SettleProof $proofT -TestCallback
Assert-GPWThat (([string]$rT.reason -ceq 'goal-terminal') -and (-not [bool]$rT.dispatched) -and ([long]$script:dispatchCalls -eq 0) -and ([long]$script:settleCalls -eq 0)) 'TERMINAL executor admits no new dispatch on a CANCELLED Goal (spy 0)'
$seedT = New-OrchestrationDispatchIntent -GoalId ([string]$pC.goal_id) -WorkItemId $widT -ActionRevision 1
$null = Save-OrchestrationDispatchIntent -Intent $seedT.intent -StoreDir $GPWDispatchStore
$null = Set-OrchestrationDispatchState -GoalId ([string]$pC.goal_id) -WorkItemId $widT -ActionRevision 1 -State 'pending' -StoreDir $GPWDispatchStore
$sT = Resume-OrchestrationGoalSession -GoalId ([string]$pC.goal_id) -GoalStoreDir $GPWGoalStore -DispatchStoreDir $GPWDispatchStore -CheckpointStoreDir $GPWCheckpointStore -OwnerId 'owner-9' -Generation 1 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:GFull -ReconcileImpl $FakeReconcile -SettleImpl $FakeSettle -SettleProof $proofT -TestCallback
Assert-GPWThat ([bool]$sT.ok -and ([long]$sT.settled -eq 1) -and (-not [bool]$sT.dispatched) -and ([string]$sT.decision -ceq 'terminal') -and ([string]$sT.stop_reason -ceq 'CANCELLED')) 'TERMINAL resume settles the prior effect with no new dispatch'
# --- (e) Hygiene: test-only seams, no productive claims, no foreign authority.
$LibText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OrchestrationGoalPromotionWiring.ps1'), [Text.Encoding]::UTF8)
Assert-GPWThat ($LibText -match 'hold-productive-disabled:test-callback-absent') 'HYGIENE productive HOLD is enforced by construction'
Assert-GPWThat ($LibText -match 'PR-3') 'HYGIENE wiring declares the PR-3 phase'
Assert-GPWThat (-not ($LibText -match 'verification-policy')) 'HYGIENE verification policy is never an authorizer here'
Assert-GPWThat ((-not ($LibText -match 'Start-Process')) -and (-not ($LibText -match 'Invoke-WebRequest')) -and (-not ($LibText -match 'Invoke-RestMethod'))) 'HYGIENE no network or process surface'
try { Remove-Item -LiteralPath $GPWGoalStore -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $GPWDispatchStore -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $GPWCheckpointStore -Recurse -Force -ErrorAction SilentlyContinue } catch { }
'PASS: {0}' -f $passed
