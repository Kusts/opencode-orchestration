[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
$passed = 0
function Assert-GKThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
$TempBase = $env:TEMP
if ([string]::IsNullOrWhiteSpace($TempBase)) { $TempBase = [IO.Path]::GetTempPath() }
$GKStore = Join-Path $TempBase ('gk-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($GKStore)
$GKController = Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1'
$GKPolicyPath = Join-Path $PSScriptRoot '..\..\..\source\registry\goal-policy.json'
# --- NEW: construction and validation.
$n = New-OrchestrationGoal -GoalId 'GK-001' -Objective 'Ship phase 6' -Criteria @('c1', 'c2') -VerificationSurfaces @('suite-new') -SoftCap 10 -HardCap 20 -TotalPhases 3
Assert-GKThat ([bool]$n.ok -and ([string]$n.goal['state'] -ceq 'DRAFT') -and ([long]$n.goal['revision'] -eq 1) -and ([long]$n.goal['schema_version'] -eq 1)) 'NEW constructs DRAFT at revision 1 schema 1'
Assert-GKThat (([long]$n.goal['progress']['total'] -eq 2) -and ([long]$n.goal['progress']['satisfied'] -eq 0) -and ([long]$n.goal['budget']['soft_cap'] -eq 10) -and ([long]$n.goal['budget']['hard_cap'] -eq 20) -and ([long]$n.goal['plan_progress']['total_phases'] -eq 3)) 'NEW seeds progress total budget caps and phases'
$b = New-OrchestrationGoal -GoalId 'bad id!' -Objective 'x'
Assert-GKThat ((-not [bool]$b.ok) -and ([string]$b.reason -ceq 'invalid-goal-id')) 'NEW rejects malformed goal_id'
$b = New-OrchestrationGoal -GoalId 'GK-002' -Objective '   '
Assert-GKThat ((-not [bool]$b.ok) -and ([string]$b.reason -ceq 'invalid-objective')) 'NEW rejects empty objective'
$b = New-OrchestrationGoal -GoalId 'GK-002' -Objective 'x' -HardCap -1
Assert-GKThat ((-not [bool]$b.ok) -and ([string]$b.reason -ceq 'invalid-budget')) 'NEW rejects negative budget cap'
$b = New-OrchestrationGoal -GoalId ('G' * 65) -Objective 'x'
Assert-GKThat ((-not [bool]$b.ok) -and ([string]$b.reason -ceq 'invalid-goal-id')) 'NEW rejects goal_id over 64 chars'
# --- LIFECYCLE: transitions per TDR-F6-01.
$g = $n.goal
$s = Set-OrchestrationGoalState -Goal $g -ToState 'ACTIVE'
Assert-GKThat ([bool]$s.ok -and ([string]$s.goal['state'] -ceq 'ACTIVE') -and ([long]$s.goal['revision'] -eq 2)) 'LIFE DRAFT->ACTIVE ok revision 2'
$s = Set-OrchestrationGoalState -Goal $s.goal -ToState 'COMPLETED'
Assert-GKThat ([bool]$s.ok -and ([string]$s.goal['state'] -ceq 'COMPLETED')) 'LIFE ACTIVE->COMPLETED ok'
$s = Set-OrchestrationGoalState -Goal $s.goal -ToState 'ACTIVE'
Assert-GKThat ((-not [bool]$s.ok) -and ([string]$s.reason -ceq 'illegal-transition')) 'LIFE terminal COMPLETED immutable'
$s = Set-OrchestrationGoalState -Goal $g -ToState 'CANCELLED'
Assert-GKThat ([bool]$s.ok -and ([string]$s.goal['state'] -ceq 'CANCELLED')) 'LIFE CANCELLED from DRAFT ok'
$gb = (Set-OrchestrationGoalState -Goal $g -ToState 'ACTIVE').goal
$gb = (Set-OrchestrationGoalState -Goal $gb -ToState 'BLOCKED').goal
$s = Set-OrchestrationGoalState -Goal $gb -ToState 'COMPLETED'
Assert-GKThat ((-not [bool]$s.ok) -and ([string]$s.reason -ceq 'illegal-transition')) 'LIFE BLOCKED->COMPLETED rejected'
$s = Set-OrchestrationGoalState -Goal $gb -ToState 'ACTIVE'
Assert-GKThat ([bool]$s.ok -and ([string]$s.goal['state'] -ceq 'ACTIVE')) 'LIFE BLOCKED->ACTIVE resume ok'
$gp = (Set-OrchestrationGoalState -Goal $g -ToState 'ACTIVE').goal
$gp = (Set-OrchestrationGoalState -Goal $gp -ToState 'PAUSED').goal
$s = Set-OrchestrationGoalState -Goal $gp -ToState 'ACTIVE'
Assert-GKThat ([bool]$s.ok) 'LIFE PAUSED->ACTIVE resume ok'
$gl = (Set-OrchestrationGoalState -Goal $g -ToState 'ACTIVE').goal
$gl = (Set-OrchestrationGoalState -Goal $gl -ToState 'BUDGET_LIMITED').goal
$s = Set-OrchestrationGoalState -Goal $gl -ToState 'EXHAUSTED'
Assert-GKThat ([bool]$s.ok -and ([string]$s.goal['state'] -ceq 'EXHAUSTED')) 'LIFE BUDGET_LIMITED->EXHAUSTED ok'
$s = Set-OrchestrationGoalState -Goal $gl -ToState 'COMPLETED'
Assert-GKThat ((-not [bool]$s.ok) -and ([string]$s.reason -ceq 'illegal-transition')) 'LIFE BUDGET_LIMITED->COMPLETED rejected'
$s = Set-OrchestrationGoalState -Goal $g -ToState 'BOGUS'
Assert-GKThat ((-not [bool]$s.ok) -and ([string]$s.reason -ceq 'unknown-state')) 'LIFE unknown state rejected'
$s = Set-OrchestrationGoalState -Goal (Set-OrchestrationGoalState -Goal $g -ToState 'ACTIVE').goal -ToState 'ACTIVE'
Assert-GKThat ((-not [bool]$s.ok) -and ([string]$s.reason -ceq 'illegal-transition')) 'LIFE self-transition rejected'
$s = Set-OrchestrationGoalState -Goal 'junk' -ToState 'ACTIVE'
Assert-GKThat ((-not [bool]$s.ok) -and ([string]$s.reason -ceq 'invalid-goal')) 'LIFE garbage goal fails closed'
# --- PERSISTENCE: save/load roundtrip.
$sv = Save-OrchestrationGoal -Goal $n.goal -StoreDir $GKStore
Assert-GKThat ([bool]$sv.ok -and ([string]$sv.goal_id -ceq 'GK-001') -and ([long]$sv.revision -eq 1)) 'STORE save ok revision 1'
$ld = Get-OrchestrationGoal -GoalId 'GK-001' -StoreDir $GKStore
Assert-GKThat ([bool]$ld.ok) 'STORE load ok'
$jA = ConvertTo-Json -InputObject $n.goal -Depth 20 -Compress
$jB = ConvertTo-Json -InputObject $ld.goal -Depth 20 -Compress
Assert-GKThat ($jA -ceq $jB) 'STORE roundtrip preserves every field byte-identical'
$ld = Get-OrchestrationGoal -GoalId 'GK-NOPE' -StoreDir $GKStore
Assert-GKThat ((-not [bool]$ld.ok) -and ([string]$ld.reason -ceq 'goal-not-found')) 'STORE missing goal reports goal-not-found'
$ld = Get-OrchestrationGoal -GoalId 'bad id!' -StoreDir $GKStore
Assert-GKThat ((-not [bool]$ld.ok) -and ([string]$ld.reason -ceq 'invalid-goal-id')) 'STORE malformed id fails closed'
# --- CAS: wrong revision writes nothing.
$u = Update-OrchestrationGoal -GoalId 'GK-001' -ExpectedRevision 1 -Fields @{ budget = @{ soft_cap = 10; hard_cap = 20; spent = 5 } } -StoreDir $GKStore
Assert-GKThat ([bool]$u.ok -and ([long]$u.goal['revision'] -eq 2) -and ([long]$u.goal['budget']['spent'] -eq 5)) 'CAS correct revision updates budget revision 2'
$bad = Update-OrchestrationGoal -GoalId 'GK-001' -ExpectedRevision 1 -Fields @{ budget = @{ soft_cap = 10; hard_cap = 20; spent = 99 } } -StoreDir $GKStore
Assert-GKThat ((-not [bool]$bad.ok) -and ([string]$bad.reason -ceq 'revision-conflict')) 'CAS stale revision rejected'
$disk = Get-OrchestrationGoal -GoalId 'GK-001' -StoreDir $GKStore
Assert-GKThat ([bool]$disk.ok -and ([long]$disk.goal['revision'] -eq 2) -and ([long]$disk.goal['budget']['spent'] -eq 5)) 'CAS conflict wrote nothing to disk'
$u = Update-OrchestrationGoal -GoalId 'GK-001' -ExpectedRevision 2 -Fields @{ progress = @{ satisfied = 1; total = 2; updated_at = '' } } -StoreDir $GKStore
Assert-GKThat ([bool]$u.ok -and ([long]$u.goal['progress']['satisfied'] -eq 1) -and ([long]$u.goal['revision'] -eq 3)) 'CAS progress update ok revision 3'
$prot = Update-OrchestrationGoal -GoalId 'GK-001' -ExpectedRevision 3 -Fields @{ revision = 99 } -StoreDir $GKStore
Assert-GKThat ((-not [bool]$prot.ok) -and ([string]$prot.reason -ceq 'protected-field')) 'CAS protected revision field rejected'
$stv = Update-OrchestrationGoal -GoalId 'GK-001' -ExpectedRevision 3 -Fields @{ state = 'ACTIVE' } -StoreDir $GKStore
Assert-GKThat ((-not [bool]$stv.ok) -and ([string]$stv.reason -ceq 'state-via-transition')) 'CAS state must go through transition'
$ttv = Update-OrchestrationGoal -GoalId 'GK-001' -ExpectedRevision 3 -Fields @{ active_tasks = @('x') } -StoreDir $GKStore
Assert-GKThat ((-not [bool]$ttv.ok) -and ([string]$ttv.reason -ceq 'tasks-via-task-ops')) 'CAS tasks must go through task ops'
# --- IDENTITY: case-insensitive, canonical lowercase filename.
$svA = Save-OrchestrationGoal -Goal (New-OrchestrationGoal -GoalId 'GK-A' -Objective 'case').goal -StoreDir $GKStore
Assert-GKThat ([bool]$svA.ok) 'IDENT seed GK-A saves ok'
$dupCase = New-OrchestrationGoal -GoalId 'gk-a' -Objective 'case clash' -StoreDir $GKStore
Assert-GKThat ((-not [bool]$dupCase.ok) -and ([string]$dupCase.reason -ceq 'duplicate-goal-id')) 'IDENT New rejects case-variant duplicate'
$dupSame = New-OrchestrationGoal -GoalId 'GK-A' -Objective 'same clash' -StoreDir $GKStore
Assert-GKThat ((-not [bool]$dupSame.ok) -and ([string]$dupSame.reason -ceq 'duplicate-goal-id')) 'IDENT New rejects exact duplicate in store'
$ldUp = Get-OrchestrationGoal -GoalId 'GK-A' -StoreDir $GKStore
$ldLo = Get-OrchestrationGoal -GoalId 'gk-a' -StoreDir $GKStore
Assert-GKThat ([bool]$ldUp.ok -and [bool]$ldLo.ok -and ([string]$ldLo.goal['goal_id'] -ceq 'GK-A')) 'IDENT Get is case-insensitive same identity'
$colonA = Save-OrchestrationGoal -Goal (New-OrchestrationGoal -GoalId 'GK:X' -Objective 'colon').goal -StoreDir $GKStore
Assert-GKThat ([bool]$colonA.ok) 'IDENT colon id saves ok'
$colonB = New-OrchestrationGoal -GoalId 'gk:x' -Objective 'colon clash' -StoreDir $GKStore
Assert-GKThat ((-not [bool]$colonB.ok) -and ([string]$colonB.reason -ceq 'duplicate-goal-id')) 'IDENT colon mapping stays injective under case'
# --- IDENT-DEFAULT: New without StoreDir resolves the default store before dup-check.
$GKDefId = ('GK-DEF-' + ([guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()))
$GKDefDir = Get-OrchestrationGoalStoreDir -StoreDir ''
$GKDefPath = Get-GKGoalFilePath -StoreDir $GKDefDir -GoalId $GKDefId
try {
    $defNew = New-OrchestrationGoal -GoalId $GKDefId -Objective 'default dup'
    Assert-GKThat ([bool]$defNew.ok) 'IDENT-DEFAULT constructor without StoreDir ok when absent'
    $defSave = Save-OrchestrationGoal -Goal $defNew.goal
    Assert-GKThat ([bool]$defSave.ok) 'IDENT-DEFAULT seed saves to default store'
    $defDup = New-OrchestrationGoal -GoalId ([string]$GKDefId).ToLowerInvariant() -Objective 'default clash'
    Assert-GKThat ((-not [bool]$defDup.ok) -and ([string]$defDup.reason -ceq 'duplicate-goal-id')) 'IDENT-DEFAULT New without StoreDir rejects case-variant duplicate in default'
}
finally {
    try { Remove-Item -LiteralPath $GKDefPath -Force -ErrorAction SilentlyContinue } catch { }
}
# --- WRITEFAIL: Move-Item failure must surface ok=false even with Continue.
$wfSeed = Save-OrchestrationGoal -Goal (New-OrchestrationGoal -GoalId 'GK-WF' -Objective 'w').goal -StoreDir $GKStore
Assert-GKThat ([bool]$wfSeed.ok) 'WRITEFAIL seed saves ok'
$wfPath = Get-GKGoalFilePath -StoreDir $GKStore -GoalId 'GK-WF'
$wfGoal = (Get-OrchestrationGoal -GoalId 'GK-WF' -StoreDir $GKStore).goal
Assert-GKThat ($null -ne $wfGoal) 'WRITEFAIL preload goal before lock'
$wfHandle = [IO.File]::Open($wfPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$wfOldPref = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $wfRes = Save-OrchestrationGoal -Goal $wfGoal -StoreDir $GKStore
    Assert-GKThat ((-not [bool]$wfRes.ok) -and ([string]$wfRes.reason -ceq 'goal-write-failed')) 'WRITEFAIL locked destination with Continue returns ok=false'
}
finally {
    $ErrorActionPreference = $wfOldPref
    try { $wfHandle.Dispose() } catch { }
}
$wfRetry = Save-OrchestrationGoal -Goal (Get-OrchestrationGoal -GoalId 'GK-WF' -StoreDir $GKStore).goal -StoreDir $GKStore
Assert-GKThat ([bool]$wfRetry.ok) 'WRITEFAIL save succeeds after unlock'
# --- RACE: real concurrent CAS behind a barrier; exactly 1 win + 1 conflict, N=20.
$GKRaceN = 20
$GKRaceClean = 0
$GKRaceLib = Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1'
for ($GKRaceIter = 1; $GKRaceIter -le $GKRaceN; $GKRaceIter++) {
    $GKRaceStore = Join-Path $GKStore ('race-' + $GKRaceIter)
    [void][IO.Directory]::CreateDirectory($GKRaceStore)
    $GKRaceSeed = Save-OrchestrationGoal -Goal (New-OrchestrationGoal -GoalId 'GK-RACE' -Objective 'race').goal -StoreDir $GKRaceStore
    Assert-GKThat ([bool]$GKRaceSeed.ok) "RACE seed iter $GKRaceIter"
    $GKGate = New-Object System.Threading.ManualResetEvent($false)
    $GKRacers = @()
    foreach ($GKTag in @('A', 'B')) {
        $GKPs = [powershell]::Create()
        [void]$GKPs.AddScript({
            param($Lib, $Store, $Gate, $Tag)
            . $Lib
            [void]$Gate.WaitOne(15000)
            $r = Update-OrchestrationGoal -GoalId 'GK-RACE' -ExpectedRevision 1 -Fields @{ objective = ('racer-' + $Tag) } -StoreDir $Store -LockTimeoutMs 15000
            if ([bool]$r.ok) { return 'ok' }
            return ('fail:' + [string]$r.reason)
        })
        [void]$GKPs.AddParameters(@{ Lib = $GKRaceLib; Store = $GKRaceStore; Gate = $GKGate; Tag = $GKTag })
        $GKRacers += [pscustomobject]@{ Ps = $GKPs; Handle = $GKPs.BeginInvoke() }
    }
    Start-Sleep -Milliseconds 300
    [void]$GKGate.Set()
    $GKOutcomes = @()
    $GKErrText = ''
    foreach ($GKRacer in $GKRacers) {
        if (-not $GKRacer.Handle.AsyncWaitHandle.WaitOne(60000)) { throw "FAIL: RACE iter $GKRaceIter timed out" }
        $GKRes = $GKRacer.Ps.EndInvoke($GKRacer.Handle)
        foreach ($GKLine in @($GKRes)) { $GKOutcomes += [string]$GKLine }
        foreach ($GKErr in @($GKRacer.Ps.Streams.Error)) { $GKErrText += [string]$GKErr + ';' }
        $GKRacer.Ps.Dispose()
    }
    [void]$GKGate.Close()
    $GKOk = @($GKOutcomes | Where-Object { $_ -ceq 'ok' }).Count
    $GKConflict = @($GKOutcomes | Where-Object { $_ -ceq 'fail:revision-conflict' }).Count
    if (($GKOk -eq 1) -and ($GKConflict -eq 1)) { $GKRaceClean++ }
    else { throw "FAIL: RACE iter $GKRaceIter outcomes: $($GKOutcomes -join ',') errors: $GKErrText" }
}
Assert-GKThat (($GKRaceClean -eq $GKRaceN)) "RACE barrier 1 win + 1 conflict in all $GKRaceN iters"
# --- TASKS: add 2 complete 1.
$gt = (New-OrchestrationGoal -GoalId 'GK-T' -Objective 'tasks').goal
$r0 = [long]$gt['revision']
$a1 = Add-OrchestrationGoalTask -Goal $gt -TaskId 'CODER-V010-PHASE6'
Assert-GKThat ([bool]$a1.ok -and ([long]$a1.goal['revision'] -eq ($r0 + 1))) 'TASK add 1 bumps revision'
$a2 = Add-OrchestrationGoalTask -Goal $a1.goal -TaskId 'TESTER-V010-PHASE6'
Assert-GKThat ([bool]$a2.ok -and (@($a2.goal['active_tasks']).Count -eq 2) -and ([long]$a2.goal['revision'] -eq ($r0 + 2))) 'TASK add 2 active count 2'
$dup = Add-OrchestrationGoalTask -Goal $a2.goal -TaskId 'CODER-V010-PHASE6'
Assert-GKThat ((-not [bool]$dup.ok) -and ([string]$dup.reason -ceq 'duplicate-task')) 'TASK duplicate rejected'
$badT = Add-OrchestrationGoalTask -Goal $a2.goal -TaskId 'no good!'
Assert-GKThat ((-not [bool]$badT.ok) -and ([string]$badT.reason -ceq 'invalid-task-id')) 'TASK malformed id rejected'
$c1 = Complete-OrchestrationGoalTask -Goal $a2.goal -TaskId 'CODER-V010-PHASE6'
Assert-GKThat ([bool]$c1.ok -and (@($c1.goal['active_tasks']).Count -eq 1) -and (@($c1.goal['completed_tasks']).Count -eq 1) -and ([long]$c1.goal['revision'] -eq ($r0 + 3))) 'TASK complete 1 leaves active 1 completed 1'
$miss = Complete-OrchestrationGoalTask -Goal $c1.goal -TaskId 'GHOST-1'
Assert-GKThat ((-not [bool]$miss.ok) -and ([string]$miss.reason -ceq 'task-not-found')) 'TASK completing unknown task rejected'
# --- NEXT-MOVE: delegation to the controller, never throws.
$noCtl = Get-OrchestrationGoalNextMove -Goal $gt -ControllerPath (Join-Path $GKStore 'no-such-controller.ps1')
Assert-GKThat ((-not [bool]$noCtl.ok) -and ([string]$noCtl.reason -ceq 'controller-unavailable') -and ($null -eq $noCtl.next_move)) 'NEXT absent controller returns no next_move without throw'
$ga = (Set-OrchestrationGoalState -Goal (New-OrchestrationGoal -GoalId 'GK-NM' -Objective 'nm' -Criteria @('c1')).goal -ToState 'ACTIVE').goal
$ga = (Add-OrchestrationGoalTask -Goal $ga -TaskId 'CODER-V010-PHASE6').goal
$mv = Get-OrchestrationGoalNextMove -Goal $ga -ControllerPath $GKController
Assert-GKThat ([bool]$mv.ok -and ([string]$mv.next_move.move -ceq 'CONTINUE')) 'NEXT active goal with tasks continues via controller'
$gc = (Set-OrchestrationGoalState -Goal $ga -ToState 'COMPLETED').goal
$mv = Get-OrchestrationGoalNextMove -Goal $gc -ControllerPath $GKController
Assert-GKThat ([bool]$mv.ok -and ([string]$mv.next_move.move -ceq 'COMPLETE') -and ([string]$mv.next_move.stop_reason -ceq 'OBJECTIVE_COMPLETED')) 'NEXT completed goal completes with OBJECTIVE_COMPLETED'
$gb2 = (Set-OrchestrationGoalState -Goal (New-OrchestrationGoal -GoalId 'GK-NB' -Objective 'nb' -Criteria @('c1')).goal -ToState 'ACTIVE').goal
$gb2 = (Set-OrchestrationGoalState -Goal $gb2 -ToState 'BLOCKED').goal
$mv = Get-OrchestrationGoalNextMove -Goal $gb2 -ControllerPath $GKController
Assert-GKThat ([bool]$mv.ok -and ([string]$mv.next_move.move -ceq 'COMPLETE') -and ([string]$mv.next_move.stop_reason -ceq 'HUMAN_AUTHORITY_REQUIRED')) 'NEXT blocked goal stops for authority'
$ge = (Set-OrchestrationGoalState -Goal (Set-OrchestrationGoalState -Goal (New-OrchestrationGoal -GoalId 'GK-NE' -Objective 'ne').goal -ToState 'ACTIVE').goal -ToState 'BUDGET_LIMITED').goal
$ge = (Set-OrchestrationGoalState -Goal $ge -ToState 'EXHAUSTED').goal
$mv = Get-OrchestrationGoalNextMove -Goal $ge -ControllerPath $GKController
Assert-GKThat ([bool]$mv.ok -and ([string]$mv.next_move.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED')) 'NEXT exhausted goal stops with hard budget reason'
$badG = Get-OrchestrationGoalNextMove -Goal 'junk' -ControllerPath $GKController
Assert-GKThat ((-not [bool]$badG.ok) -and ([string]$badG.reason -ceq 'invalid-goal')) 'NEXT garbage goal fails closed'
# --- POLICY: lib matches goal-policy.json.
$pol = ConvertFrom-Json ([IO.File]::ReadAllText($GKPolicyPath, [Text.Encoding]::UTF8))
Assert-GKThat (([int]$pol.schema_version -eq 1)) 'POLICY schema_version 1'
Assert-GKThat (((@(Get-OrchestrationGoalStates) -join ',') -ceq ((@($pol.states) | ForEach-Object { [string]$_ }) -join ','))) 'POLICY lib states match registry'
Assert-GKThat (((@(Get-OrchestrationGoalTerminalStates) -join ',') -ceq ((@($pol.terminal) | ForEach-Object { [string]$_ }) -join ','))) 'POLICY lib terminal matches registry'
foreach ($st in @(Get-OrchestrationGoalStates)) {
    $libNext = @()
    foreach ($cand in @(Get-OrchestrationGoalStates)) {
        if (Test-OrchestrationGoalTransition -From $st -To $cand) { $libNext += $cand }
    }
    $regNext = @($pol.transitions.$st | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $match = ((($libNext | Sort-Object) -join ',') -ceq ((($regNext | Sort-Object) -join ',')))
    Assert-GKThat $match "POLICY transitions match for $st"
}
try { Remove-Item -LiteralPath $GKStore -Recurse -Force -ErrorAction SilentlyContinue } catch { }
Write-Output "PASS OrchestrationGoalKernel: $passed assertions"
