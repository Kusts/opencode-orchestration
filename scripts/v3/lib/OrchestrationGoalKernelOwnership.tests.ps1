[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
$passed = 0
function Assert-GKOThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
$TempBase = $env:TEMP
if ([string]::IsNullOrWhiteSpace($TempBase)) { $TempBase = [IO.Path]::GetTempPath() }
$GKOStore = Join-Path $TempBase ('gko-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($GKOStore)
function New-GKOSeed {
    param([string]$Id, [string]$Objective = 'owned work')
    $n = New-OrchestrationGoal -GoalId $Id -Objective $Objective
    if (-not [bool]$n.ok) { throw "FAIL: seed constructor $Id" }
    $sv = Save-OrchestrationGoal -Goal $n.goal -StoreDir $GKOStore
    if (-not [bool]$sv.ok) { throw "FAIL: seed save $Id" }
    return $sv
}
# --- ACQUIRE: fresh unmanaged record gains generation 1 with revision bump.
New-GKOSeed -Id 'GKO-ACQ' | Out-Null
$a = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-ACQ' -OwnerId 'exec-1' -ExpectedRevision 1 -StoreDir $GKOStore -LeaseTtlMs 60000
Assert-GKOThat ([bool]$a.ok -and ([long]$a.ownership['generation'] -eq 1) -and ([long]$a.revision -eq 2) -and ([string]$a.ownership['owner_id'] -ceq 'exec-1')) 'ACQUIRE fresh allocates generation 1 at revision 2'
$d = Get-OrchestrationGoal -GoalId 'GKO-ACQ' -StoreDir $GKOStore
Assert-GKOThat ([bool]$d.ok -and ([long]$d.goal['revision'] -eq 2) -and ([long]$d.goal['ownership']['generation'] -eq 1)) 'ACQUIRE persisted with revision under same lock'
# --- ACQUIRE: stale revision writes nothing.
New-GKOSeed -Id 'GKO-STALE' | Out-Null
$u0 = Update-OrchestrationGoal -GoalId 'GKO-STALE' -ExpectedRevision 1 -Fields @{ objective = 'bumped' } -StoreDir $GKOStore
Assert-GKOThat ([bool]$u0.ok -and ([long]$u0.goal['revision'] -eq 2)) 'ACQUIRE prerequisite unmanaged bump ok'
$aBad = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-STALE' -OwnerId 'exec-1' -ExpectedRevision 1 -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$aBad.ok) -and ([string]$aBad.reason -ceq 'revision-conflict')) 'ACQUIRE stale revision rejected against real revision'
$d = Get-OrchestrationGoal -GoalId 'GKO-STALE' -StoreDir $GKOStore
Assert-GKOThat ($null -eq $d.goal['ownership']) 'ACQUIRE conflict left record unmanaged'
# --- ACQUIRE: second acquire on managed record is a conflict, never a new generation.
$a2 = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-ACQ' -OwnerId 'exec-1' -ExpectedRevision 2 -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$a2.ok) -and ([string]$a2.reason -ceq 'owner-conflict')) 'ACQUIRE same owner while held is conflict (use renew)'
$a3 = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-ACQ' -OwnerId 'exec-2' -ExpectedRevision 2 -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$a3.ok) -and ([string]$a3.reason -ceq 'owner-conflict')) 'ACQUIRE rival while held is conflict'
# --- GENERATION != REVISION: revision advances during the lease, fencing token unchanged.
$u1 = Update-OrchestrationGoal -GoalId 'GKO-ACQ' -ExpectedRevision 2 -Fields @{ objective = 'step 1' } -StoreDir $GKOStore -OwnerId 'exec-1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$u1.ok -and ([long]$u1.goal['revision'] -eq 3) -and ([long]$u1.goal['ownership']['generation'] -eq 1)) 'GATED update advances revision, generation stays 1'
$u2 = Update-OrchestrationGoal -GoalId 'GKO-ACQ' -ExpectedRevision 3 -Fields @{ objective = 'step 2' } -StoreDir $GKOStore -OwnerId 'exec-1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$u2.ok -and ([long]$u2.goal['revision'] -eq 4)) 'GATED second update still held at generation 1'
$t = Test-OrchestrationGoalOwnership -Goal $u2.goal -OwnerId 'exec-1' -Generation 1
Assert-GKOThat ([bool]$t.ok -and [bool]$t.held) 'FENCING token survives revision drift'
# --- GATED: managed record without fencing is an explicit denial, never silent bypass.
$noF = Update-OrchestrationGoal -GoalId 'GKO-ACQ' -ExpectedRevision 4 -Fields @{ objective = 'sneak' } -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$noF.ok) -and ([string]$noF.reason -ceq 'ownership-required')) 'GATED unmanaged write on managed record denied'
$d = Get-OrchestrationGoal -GoalId 'GKO-ACQ' -StoreDir $GKOStore
Assert-GKOThat (([long]$d.goal['revision'] -eq 4) -and ([string]$d.goal['objective'] -ceq 'step 2')) 'GATED denied write persisted nothing'
$wrongF = Update-OrchestrationGoal -GoalId 'GKO-ACQ' -ExpectedRevision 4 -Fields @{ objective = 'sneak' } -StoreDir $GKOStore -OwnerId 'exec-2' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$wrongF.ok) -and ([string]$wrongF.reason -ceq 'owner-conflict')) 'GATED rival fencing denied at commit'
$oldF = Update-OrchestrationGoal -GoalId 'GKO-ACQ' -ExpectedRevision 4 -Fields @{ objective = 'sneak' } -StoreDir $GKOStore -OwnerId 'exec-1' -OwnershipGeneration 99
Assert-GKOThat ((-not [bool]$oldF.ok) -and ([string]$oldF.reason -ceq 'owner-obsolete')) 'GATED stale generation denied at commit'
# --- RENEW: same generation, extended lease, revision bump, spelling preserved.
$before = (Get-OrchestrationGoal -GoalId 'GKO-ACQ' -StoreDir $GKOStore).goal
$r = Renew-OrchestrationGoalOwnership -GoalId 'GKO-ACQ' -OwnerId 'exec-1' -Generation 1 -StoreDir $GKOStore -LeaseTtlMs 60000
Assert-GKOThat ([bool]$r.ok -and ([long]$r.ownership['generation'] -eq 1) -and ([string]$r.ownership['owner_id'] -ceq 'exec-1') -and ([long]$r.revision -eq 5)) 'RENEW keeps generation and identity, bumps revision'
Assert-GKOThat (([string]$r.ownership['acquired_at'] -ceq [string]$before['ownership']['acquired_at'])) 'RENEW preserves acquired_at'
$u3 = Update-OrchestrationGoal -GoalId 'GKO-ACQ' -ExpectedRevision 5 -Fields @{ objective = 'step 3' } -StoreDir $GKOStore -OwnerId 'exec-1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$u3.ok -and ([long]$u3.goal['revision'] -eq 6)) 'GATED update after renew ok'
# --- RENEW: wrong owner / stale generation denied without write.
$rW = Renew-OrchestrationGoalOwnership -GoalId 'GKO-ACQ' -OwnerId 'exec-2' -Generation 1 -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$rW.ok) -and ([string]$rW.reason -ceq 'owner-conflict')) 'RENEW rival denied'
$rS = Renew-OrchestrationGoalOwnership -GoalId 'GKO-ACQ' -OwnerId 'exec-1' -Generation 7 -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$rS.ok) -and ([string]$rS.reason -ceq 'owner-obsolete')) 'RENEW stale generation denied'
$d = Get-OrchestrationGoal -GoalId 'GKO-ACQ' -StoreDir $GKOStore
Assert-GKOThat ([long]$d.goal['revision'] -eq 6) 'RENEW denials wrote nothing'
# --- IDENTITY HOLD: canonically-equal but ordinally-divergent owner spelling holds.
New-GKOSeed -Id 'GKO-HOLD' | Out-Null
$h = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-HOLD' -OwnerId 'Hold-Owner' -ExpectedRevision 1 -StoreDir $GKOStore
Assert-GKOThat ([bool]$h.ok) 'HOLD seed acquire ok'
$hR = Renew-OrchestrationGoalOwnership -GoalId 'GKO-HOLD' -OwnerId 'hold-owner' -Generation 1 -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$hR.ok) -and ([string]$hR.reason -ceq 'identity-hold-case-divergence')) 'HOLD divergent spelling renew is HOLD, never merged'
$hU = Update-OrchestrationGoal -GoalId 'GKO-HOLD' -ExpectedRevision 2 -Fields @{ objective = 'x' } -StoreDir $GKOStore -OwnerId 'hold-owner' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$hU.ok) -and ([string]$hU.reason -ceq 'identity-hold-case-divergence')) 'HOLD divergent spelling commit is HOLD'
$d = Get-OrchestrationGoal -GoalId 'GKO-HOLD' -StoreDir $GKOStore
Assert-GKOThat (([string]$d.goal['ownership']['owner_id'] -ceq 'Hold-Owner') -and ([long]$d.goal['revision'] -eq 2)) 'HOLD preserved grafia and wrote nothing'
# --- EXPIRY + TAKEOVER: expired lease renews nothing, takeover allocates predecessor + 1.
New-GKOSeed -Id 'GKO-EXP' | Out-Null
$e = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-EXP' -OwnerId 'exec-1' -ExpectedRevision 1 -StoreDir $GKOStore -LeaseTtlMs 400
Assert-GKOThat ([bool]$e.ok) 'EXPIRY short-lease acquire ok'
Start-Sleep -Milliseconds 1200
$tE = Test-OrchestrationGoalOwnership -Goal (Get-OrchestrationGoal -GoalId 'GKO-EXP' -StoreDir $GKOStore).goal -OwnerId 'exec-1' -Generation 1
Assert-GKOThat (([bool]$tE.ok) -and (-not [bool]$tE.held) -and ([string]$tE.reason -ceq 'owner-lease-expired')) 'EXPIRY fencing lapses after ttl'
$rE = Renew-OrchestrationGoalOwnership -GoalId 'GKO-EXP' -OwnerId 'exec-1' -Generation 1 -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$rE.ok) -and ([string]$rE.reason -ceq 'owner-lease-expired')) 'EXPIRY renew after lapse denied'
$uE = Update-OrchestrationGoal -GoalId 'GKO-EXP' -ExpectedRevision 2 -Fields @{ objective = 'late' } -StoreDir $GKOStore -OwnerId 'exec-1' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$uE.ok) -and ([string]$uE.reason -ceq 'owner-lease-expired')) 'EXPIRY commit after lapse denied'
$tk = Takeover-OrchestrationGoalOwnership -GoalId 'GKO-EXP' -OwnerId 'exec-2' -StoreDir $GKOStore -LeaseTtlMs 60000
Assert-GKOThat ([bool]$tk.ok -and ([long]$tk.ownership['generation'] -eq 2) -and ([string]$tk.ownership['owner_id'] -ceq 'exec-2')) 'TAKEOVER allocates predecessor + 1'
$uOld = Update-OrchestrationGoal -GoalId 'GKO-EXP' -ExpectedRevision ([long]$tk.revision) -Fields @{ objective = 'stale holder' } -StoreDir $GKOStore -OwnerId 'exec-1' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$uOld.ok) -and (([string]$uOld.reason -ceq 'owner-conflict') -or ([string]$uOld.reason -ceq 'owner-obsolete'))) 'TAKEOVER superseded holder rejected'
$uNew = Update-OrchestrationGoal -GoalId 'GKO-EXP' -ExpectedRevision ([long]$tk.revision) -Fields @{ objective = 'new holder' } -StoreDir $GKOStore -OwnerId 'exec-2' -OwnershipGeneration 2
Assert-GKOThat ([bool]$uNew.ok) 'TAKEOVER new holder commits'
# --- TAKEOVER: live lease is a conflict; legacy record uses acquire.
New-GKOSeed -Id 'GKO-LIVE' | Out-Null
$l = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-LIVE' -OwnerId 'exec-1' -ExpectedRevision 1 -StoreDir $GKOStore -LeaseTtlMs 60000
Assert-GKOThat ([bool]$l.ok) 'TAKEOVER seed acquire ok'
$lT = Takeover-OrchestrationGoalOwnership -GoalId 'GKO-LIVE' -OwnerId 'exec-2' -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$lT.ok) -and ([string]$lT.reason -ceq 'owner-conflict')) 'TAKEOVER live lease denied'
New-GKOSeed -Id 'GKO-LEG' | Out-Null
$lT2 = Takeover-OrchestrationGoalOwnership -GoalId 'GKO-LEG' -OwnerId 'exec-9' -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$lT2.ok) -and ([string]$lT2.reason -ceq 'no-ownership-use-acquire')) 'TAKEOVER legacy record directs to acquire'
# --- LEGACY: no ownership means fail-closed fencing but intact compat path.
$gLeg = (Get-OrchestrationGoal -GoalId 'GKO-LEG' -StoreDir $GKOStore).goal
$tL = Test-OrchestrationGoalOwnership -Goal $gLeg -OwnerId 'exec-9' -Generation 1
Assert-GKOThat (([bool]$tL.ok) -and (-not [bool]$tL.held) -and ([string]$tL.reason -ceq 'no-ownership')) 'LEGACY fencing reports no-ownership'
$uLeg = Update-OrchestrationGoal -GoalId 'GKO-LEG' -ExpectedRevision 1 -Fields @{ objective = 'plain' } -StoreDir $GKOStore
Assert-GKOThat ([bool]$uLeg.ok -and ([long]$uLeg.goal['revision'] -eq 2) -and ($null -eq $uLeg.goal['ownership'])) 'LEGACY unmanaged update intact, no implicit ownership'
$uLegF = Update-OrchestrationGoal -GoalId 'GKO-LEG' -ExpectedRevision 2 -Fields @{ objective = 'fenced' } -StoreDir $GKOStore -OwnerId 'exec-9' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$uLegF.ok) -and ([string]$uLegF.reason -ceq 'no-ownership')) 'LEGACY fenced write without acquire denied (no implicit conversion)'
# --- INVALID LEASE: corrupt/missing lease in a managed record denies everything fail-closed.
New-GKOSeed -Id 'GKO-BAD' | Out-Null
$bA = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-BAD' -OwnerId 'exec-1' -ExpectedRevision 1 -StoreDir $GKOStore
Assert-GKOThat ([bool]$bA.ok) 'BADLEASE seed acquire ok'
$badPath = Get-GKGoalFilePath -StoreDir $GKOStore -GoalId 'GKO-BAD'
$badRaw = ConvertFrom-Json ([IO.File]::ReadAllText($badPath, [Text.Encoding]::UTF8))
$badRaw.ownership.expires_at = 'not-a-date'
[IO.File]::WriteAllText($badPath, (ConvertTo-Json -InputObject $badRaw -Depth 20 -Compress), [Text.Encoding]::UTF8)
$tB = Test-OrchestrationGoalOwnership -Goal (Get-OrchestrationGoal -GoalId 'GKO-BAD' -StoreDir $GKOStore).goal -OwnerId 'exec-1' -Generation 1
Assert-GKOThat (([bool]$tB.ok) -and (-not [bool]$tB.held) -and ([string]$tB.reason -ceq 'invalid-lease')) 'BADLEASE fencing reports invalid-lease'
$rB = Renew-OrchestrationGoalOwnership -GoalId 'GKO-BAD' -OwnerId 'exec-1' -Generation 1 -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$rB.ok) -and ([string]$rB.reason -ceq 'invalid-lease')) 'BADLEASE renew denied'
$kB = Takeover-OrchestrationGoalOwnership -GoalId 'GKO-BAD' -OwnerId 'exec-2' -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$kB.ok) -and ([string]$kB.reason -ceq 'invalid-lease')) 'BADLEASE takeover denied (expiry not provable)'
$uB = Update-OrchestrationGoal -GoalId 'GKO-BAD' -ExpectedRevision 2 -Fields @{ objective = 'x' } -StoreDir $GKOStore -OwnerId 'exec-1' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$uB.ok) -and ([string]$uB.reason -ceq 'invalid-lease')) 'BADLEASE commit denied'
# --- SAVE BYPASS BLOCKED: blind Save never writes a managed record, never mints ownership.
$heldGoal = (Get-OrchestrationGoal -GoalId 'GKO-HOLD' -StoreDir $GKOStore).goal
$sBypass = Save-OrchestrationGoal -Goal $heldGoal -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$sBypass.ok) -and ([string]$sBypass.reason -ceq 'managed-goal-use-update')) 'SAVE managed record via holder copy denied'
$craft = Copy-GKGoalRecord (Get-OrchestrationGoal -GoalId 'GKO-LEG' -StoreDir $GKOStore).goal
$craft['goal_id'] = 'GKO-HOLD'
$craft['objective'] = 'crafted overwrite'
$sCraft = Save-OrchestrationGoal -Goal $craft -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$sCraft.ok) -and ([string]$sCraft.reason -ceq 'managed-goal-use-update')) 'SAVE unmanaged copy over managed record denied'
$dHold = Get-OrchestrationGoal -GoalId 'GKO-HOLD' -StoreDir $GKOStore
Assert-GKOThat (([bool]$dHold.ok) -and ([long]$dHold.goal['revision'] -eq 2) -and ([string]$dHold.goal['objective'] -ceq 'owned work')) 'SAVE overwrite attempt wrote nothing'
$mint = Copy-GKGoalRecord (Get-OrchestrationGoal -GoalId 'GKO-LEG' -StoreDir $GKOStore).goal
$mint['ownership'] = [ordered]@{ owner_id = 'exec-9'; generation = [long]9; acquired_at = ''; expires_at = ''; lease_ttl_ms = [long]0; updated_at = '' }
$sMint = Save-OrchestrationGoal -Goal $mint -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$sMint.ok) -and ([string]$sMint.reason -ceq 'ownership-via-acquire')) 'SAVE crafted ownership on unmanaged disk denied'
$dLeg2 = Get-OrchestrationGoal -GoalId 'GKO-LEG' -StoreDir $GKOStore
Assert-GKOThat ($null -eq $dLeg2.goal['ownership']) 'SAVE crafted ownership wrote nothing'
# --- TERMINAL: no new ownership; reads still serve reconcile; new dispatch refused.
$tg = (New-OrchestrationGoal -GoalId 'GKO-TERM' -Objective 'terminal').goal
$tg = (Set-OrchestrationGoalState -Goal $tg -ToState 'ACTIVE').goal
$tg = (Set-OrchestrationGoalState -Goal $tg -ToState 'COMPLETED').goal
$svT = Save-OrchestrationGoal -Goal $tg -StoreDir $GKOStore
Assert-GKOThat ([bool]$svT.ok) 'TERMINAL unmanaged terminal seed saves ok'
$aT = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-TERM' -OwnerId 'exec-1' -ExpectedRevision ([long]$tg['revision']) -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$aT.ok) -and ([string]$aT.reason -ceq 'terminal-goal')) 'TERMINAL acquire denied'
$gT = Get-OrchestrationGoal -GoalId 'GKO-TERM' -StoreDir $GKOStore
Assert-GKOThat ([bool]$gT.ok -and ([string]$gT.goal['state'] -ceq 'COMPLETED')) 'TERMINAL read still serves reconcile'
$td = Add-OrchestrationGoalTask -Goal $gT.goal -TaskId 'GKO-DISPATCH-1'
Assert-GKOThat ((-not [bool]$td.ok) -and ([string]$td.reason -ceq 'terminal-goal')) 'TERMINAL new dispatch refused'
# --- RACE: concurrent acquires behind a barrier; exactly 1 win, N=20.
$GKORaceN = 20
$GKORaceClean = 0
$GKORaceLib = Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1'
for ($GKORaceIter = 1; $GKORaceIter -le $GKORaceN; $GKORaceIter++) {
    $GKORaceStore = Join-Path $GKOStore ('race-' + $GKORaceIter)
    [void][IO.Directory]::CreateDirectory($GKORaceStore)
    $GKORaceSeed = Save-OrchestrationGoal -Goal (New-OrchestrationGoal -GoalId 'GKO-RACE' -Objective 'race').goal -StoreDir $GKORaceStore
    Assert-GKOThat ([bool]$GKORaceSeed.ok) "RACE seed iter $GKORaceIter"
    $GKOGate = New-Object System.Threading.ManualResetEvent($false)
    $GKORacers = @()
    foreach ($GKOTag in @('A', 'B')) {
        $GKOPs = [powershell]::Create()
        [void]$GKOPs.AddScript({
            param($Lib, $Store, $Gate, $Tag)
            . $Lib
            [void]$Gate.WaitOne(15000)
            $r = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-RACE' -OwnerId ('racer-' + $Tag) -ExpectedRevision 1 -StoreDir $Store -LockTimeoutMs 15000
            if ([bool]$r.ok) { return 'ok' }
            return ('fail:' + [string]$r.reason)
        })
        [void]$GKOPs.AddParameters(@{ Lib = $GKORaceLib; Store = $GKORaceStore; Gate = $GKOGate; Tag = $GKOTag })
        $GKORacers += [pscustomobject]@{ Ps = $GKOPs; Handle = $GKOPs.BeginInvoke() }
    }
    Start-Sleep -Milliseconds 300
    [void]$GKOGate.Set()
    $GKOOutcomes = @()
    $GKOErrText = ''
    foreach ($GKORacer in $GKORacers) {
        if (-not $GKORacer.Handle.AsyncWaitHandle.WaitOne(60000)) { throw "FAIL: RACE iter $GKORaceIter timed out" }
        $GKORes = $GKORacer.Ps.EndInvoke($GKORacer.Handle)
        foreach ($GKOLine in @($GKORes)) { $GKOOutcomes += [string]$GKOLine }
        foreach ($GKOErr in @($GKORacer.Ps.Streams.Error)) { $GKOErrText += [string]$GKOErr + ';' }
        $GKORacer.Ps.Dispose()
    }
    [void]$GKOGate.Close()
    $GKOOOk = @($GKOOutcomes | Where-Object { $_ -ceq 'ok' }).Count
    $GKOConflict = @($GKOOutcomes | Where-Object { $_ -ceq 'fail:owner-conflict' }).Count
    if (($GKOOOk -eq 1) -and ($GKOConflict -eq 1)) { $GKORaceClean++ }
    else { throw "FAIL: RACE iter $GKORaceIter outcomes: $($GKOOutcomes -join ',') errors: $GKOErrText" }
}
Assert-GKOThat (($GKORaceClean -eq $GKORaceN)) "RACE barrier 1 win + 1 denial in all $GKORaceN iters"
# --- H1: canonical lease instants cross-engine (Save->Read->Update/Renew/Takeover).
New-GKOSeed -Id 'GKO-H1' | Out-Null
$h1Seed = (Get-OrchestrationGoal -GoalId 'GKO-H1' -StoreDir $GKOStore).goal
$h1jA = ConvertTo-Json -InputObject $h1Seed -Depth 20 -Compress
$h1Ld = (Get-OrchestrationGoal -GoalId 'GKO-H1' -StoreDir $GKOStore).goal
$h1jB = ConvertTo-Json -InputObject $h1Ld -Depth 20 -Compress
Assert-GKOThat ($h1jA -ceq $h1jB) 'H1 unmanaged save/read roundtrip byte-identical'
$h1a = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-H1' -OwnerId 'exec-h1' -ExpectedRevision 1 -StoreDir $GKOStore -LeaseTtlMs 60000
Assert-GKOThat ([bool]$h1a.ok) 'H1 acquire ok'
$h1off = Update-OrchestrationGoal -GoalId 'GKO-H1' -ExpectedRevision ([long]$h1a.revision) -Fields @{ progress = @{ satisfied = 0; total = 0; updated_at = '2026-10-08T12:00:00.0000000+02:00' } } -StoreDir $GKOStore -OwnerId 'exec-h1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$h1off.ok) 'H1 offset instant update ok'
$h1stored = [string]$h1off.goal['progress']['updated_at']
Assert-GKOThat ($h1stored -match 'Z$') 'H1 offset instant normalized to UTC ISO'
$h1exp = Get-GKGoalLeaseInstant $h1stored
$h1want = Get-GKGoalLeaseInstant '2026-10-08T12:00:00.0000000+02:00'
Assert-GKOThat (($null -ne $h1exp) -and ($null -ne $h1want) -and ($h1exp -eq $h1want)) 'H1 offset instant preserves the instant'
$h1bad = Update-OrchestrationGoal -GoalId 'GKO-H1' -ExpectedRevision ([long]$h1off.goal['revision']) -Fields @{ progress = @{ satisfied = 0; total = 0; updated_at = 'not-a-date' } } -StoreDir $GKOStore -OwnerId 'exec-h1' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$h1bad.ok) -and ([string]$h1bad.reason -ceq 'invalid-progress')) 'H1 invalid instant denied, never stored'
$h1craft = Copy-GKGoalRecord (Get-OrchestrationGoal -GoalId 'GKO-H1' -StoreDir $GKOStore).goal
$h1craft['created_at'] = 'not-a-date'
$h1sBad = Save-OrchestrationGoal -Goal $h1craft -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$h1sBad.ok) -and (([string]$h1sBad.reason -ceq 'invalid-goal') -or ([string]$h1sBad.reason -ceq 'managed-goal-use-update'))) 'H1 crafted invalid instant over managed record denied without write'
$h1plain = New-OrchestrationGoal -GoalId 'GKO-H1-PLAIN' -Objective 'plain h1'
$h1plain.goal['created_at'] = 'not-a-date'
$h1sPlain = Save-OrchestrationGoal -Goal $h1plain.goal -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$h1sPlain.ok)) 'H1 invalid instant on unmanaged save denied'
$h1r = Renew-OrchestrationGoalOwnership -GoalId 'GKO-H1' -OwnerId 'exec-h1' -Generation 1 -StoreDir $GKOStore -LeaseTtlMs 60000
Assert-GKOThat ([bool]$h1r.ok) 'H1 renew after canonical instants ok'
$h1disk = (Get-OrchestrationGoal -GoalId 'GKO-H1' -StoreDir $GKOStore).goal
$h1diskExp = Get-GKGoalLeaseInstant ([string]$h1disk['ownership']['expires_at'])
Assert-GKOThat (($null -ne $h1diskExp) -and ($h1diskExp -gt (Get-GKGoalNowUtc))) 'H1 persisted lease parses to a live instant'
# --- H1-DT: DateTime-hydrated lease (other engine) canonicalizes identically.
$h1dtNode = [ordered]@{ owner_id = 'exec-h1'; generation = [long]1; acquired_at = ([DateTime]::UtcNow); expires_at = ([DateTime]::UtcNow.AddMinutes(5)); lease_ttl_ms = [long]60000; updated_at = ([DateTime]::UtcNow) }
$h1dtCanon = ConvertTo-GKGoalOwnership $h1dtNode
Assert-GKOThat (($null -ne $h1dtCanon) -and ([string]$h1dtCanon['expires_at'] -match 'Z$')) 'H1-DT DateTime lease canonicalizes to UTC ISO'
$h1dtGoal = Copy-GKGoalRecord (Get-OrchestrationGoal -GoalId 'GKO-H1' -StoreDir $GKOStore).goal
$h1dtGoal['ownership'] = $h1dtNode
$h1dtCheck = Test-OrchestrationGoalOwnership -Goal $h1dtGoal -OwnerId 'exec-h1' -Generation 1
Assert-GKOThat (([bool]$h1dtCheck.ok) -and [bool]$h1dtCheck.held) 'H1-DT DateTime-hydrated fencing held'
$h1uGoal = Copy-GKGoalRecord (Get-OrchestrationGoal -GoalId 'GKO-H1' -StoreDir $GKOStore).goal
$h1uGoal['ownership'] = [ordered]@{ owner_id = 'exec-h1'; generation = [long]1; acquired_at = (New-Object DateTime(2026, 10, 8, 12, 0, 0)); expires_at = (New-Object DateTime(2026, 10, 8, 13, 0, 0)); lease_ttl_ms = [long]60000; updated_at = (New-Object DateTime(2026, 10, 8, 12, 0, 0)) }
$h1uCheck = Test-OrchestrationGoalOwnership -Goal $h1uGoal -OwnerId 'exec-h1' -Generation 1
Assert-GKOThat (([bool]$h1uCheck.ok) -and (-not [bool]$h1uCheck.held) -and ([string]$h1uCheck.reason -ceq 'invalid-lease')) 'H1-DT Unspecified-kind DateTime denied as invalid-lease'
# --- H2: Save fail-closed on unprovable existing record (no overwrite).
New-GKOSeed -Id 'GKO-H2J' | Out-Null
$h2jGoal = (New-OrchestrationGoal -GoalId 'GKO-H2J' -Objective 'h2 json').goal
$h2jPath = Get-GKGoalFilePath -StoreDir $GKOStore -GoalId 'GKO-H2J'
[IO.File]::WriteAllText($h2jPath, '{corrupt-json', [Text.Encoding]::UTF8)
$h2jBefore = [IO.File]::ReadAllText($h2jPath, [Text.Encoding]::UTF8)
$h2jSave = Save-OrchestrationGoal -Goal $h2jGoal -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$h2jSave.ok) -and ([string]$h2jSave.reason -ceq 'invalid-record')) 'H2 corrupt JSON denies save'
$h2jAfter = [IO.File]::ReadAllText($h2jPath, [Text.Encoding]::UTF8)
Assert-GKOThat ($h2jAfter -ceq $h2jBefore) 'H2 corrupt JSON wrote nothing'
New-GKOSeed -Id 'GKO-H2O' | Out-Null
$h2oGoal = (New-OrchestrationGoal -GoalId 'GKO-H2O' -Objective 'h2 own').goal
$h2oPath = Get-GKGoalFilePath -StoreDir $GKOStore -GoalId 'GKO-H2O'
$h2oRaw = ConvertFrom-Json ([IO.File]::ReadAllText($h2oPath, [Text.Encoding]::UTF8))
$h2oRaw | Add-Member -NotePropertyName 'ownership' -NotePropertyValue (@{ owner_id = 'exec-1'; generation = 0; acquired_at = ''; expires_at = ''; lease_ttl_ms = 0; updated_at = '' }) -Force
[IO.File]::WriteAllText($h2oPath, (ConvertTo-Json -InputObject $h2oRaw -Depth 20 -Compress), [Text.Encoding]::UTF8)
$h2oBefore = [IO.File]::ReadAllText($h2oPath, [Text.Encoding]::UTF8)
$h2oSave = Save-OrchestrationGoal -Goal $h2oGoal -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$h2oSave.ok) -and ([string]$h2oSave.reason -ceq 'invalid-record')) 'H2 structurally-invalid ownership denies save'
$h2oAfter = [IO.File]::ReadAllText($h2oPath, [Text.Encoding]::UTF8)
Assert-GKOThat ($h2oAfter -ceq $h2oBefore) 'H2 structurally-invalid ownership wrote nothing'
New-GKOSeed -Id 'GKO-H2I' | Out-Null
$h2iGoal = (New-OrchestrationGoal -GoalId 'GKO-H2I' -Objective 'h2 ident').goal
$h2iPath = Get-GKGoalFilePath -StoreDir $GKOStore -GoalId 'GKO-H2I'
$h2iText = [IO.File]::ReadAllText($h2iPath, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($h2iPath, ($h2iText -replace 'GKO-H2I', 'GKO-H2-OTHER'), [Text.Encoding]::UTF8)
$h2iBefore = [IO.File]::ReadAllText($h2iPath, [Text.Encoding]::UTF8)
$h2iSave = Save-OrchestrationGoal -Goal $h2iGoal -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$h2iSave.ok) -and ([string]$h2iSave.reason -ceq 'invalid-record')) 'H2 divergent identity denies save'
$h2iAfter = [IO.File]::ReadAllText($h2iPath, [Text.Encoding]::UTF8)
Assert-GKOThat ($h2iAfter -ceq $h2iBefore) 'H2 divergent identity wrote nothing'
# --- H2-LOCK: blocked read denies before any write (never reaches Move-Item).
New-GKOSeed -Id 'GKO-H2L' | Out-Null
$h2lAcq = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-H2L' -OwnerId 'exec-h2l' -ExpectedRevision 1 -StoreDir $GKOStore -LeaseTtlMs 60000
Assert-GKOThat ([bool]$h2lAcq.ok) 'H2-LOCK seed acquire ok'
$h2lRev = [long]$h2lAcq.revision
$h2lPath = Get-GKGoalFilePath -StoreDir $GKOStore -GoalId 'GKO-H2L'
$h2lBefore = [IO.File]::ReadAllText($h2lPath, [Text.Encoding]::UTF8)
$h2lCraft = Copy-GKGoalRecord (Get-OrchestrationGoal -GoalId 'GKO-H2L' -StoreDir $GKOStore).goal
$h2lCraft.Remove('ownership')
$h2lCraft['objective'] = 'crafted overwrite while locked'
$h2lHandle = [IO.File]::Open($h2lPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $h2lSave = Save-OrchestrationGoal -Goal $h2lCraft -StoreDir $GKOStore
    Assert-GKOThat ((-not [bool]$h2lSave.ok) -and ([string]$h2lSave.reason -ceq 'goal-write-failed')) 'H2-LOCK blocked read denies as goal-write-failed without reaching Move-Item'
}
finally { try { $h2lHandle.Dispose() } catch { } }
$h2lAfter = [IO.File]::ReadAllText($h2lPath, [Text.Encoding]::UTF8)
Assert-GKOThat ($h2lAfter -ceq $h2lBefore) 'H2-LOCK locked-then-unlocked wrote nothing'
$h2lDisk = Get-OrchestrationGoal -GoalId 'GKO-H2L' -StoreDir $GKOStore
Assert-GKOThat (([bool]$h2lDisk.ok) -and ([long]$h2lDisk.goal['revision'] -eq $h2lRev) -and ([string]$h2lDisk.goal['ownership']['owner_id'] -ceq 'exec-h2l') -and ([string]$h2lDisk.goal['objective'] -ceq 'owned work')) 'H2-LOCK ownership and content preserved after unlock'
# --- M1: full managed cycle persists via CAS (acquire->add->complete->state->terminal).
New-GKOSeed -Id 'GKO-M1' | Out-Null
$m1a = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-M1' -OwnerId 'exec-m1' -ExpectedRevision 1 -StoreDir $GKOStore -LeaseTtlMs 60000
Assert-GKOThat ([bool]$m1a.ok) 'M1 acquire ok'
$m1rev = [long]$m1a.revision
$m1noF = Add-OrchestrationGoalTaskPersisted -GoalId 'GKO-M1' -TaskId 'M1-TASK-1' -ExpectedRevision $m1rev -StoreDir $GKOStore
Assert-GKOThat ((-not [bool]$m1noF.ok) -and ([string]$m1noF.reason -ceq 'ownership-required')) 'M1 ungated persisted add denied'
$m1add = Add-OrchestrationGoalTaskPersisted -GoalId 'GKO-M1' -TaskId 'M1-TASK-1' -ExpectedRevision $m1rev -StoreDir $GKOStore -OwnerId 'exec-m1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$m1add.ok) 'M1 persisted add ok'
$m1dup = Add-OrchestrationGoalTaskPersisted -GoalId 'GKO-M1' -TaskId 'M1-TASK-1' -ExpectedRevision ([long]$m1add.goal['revision']) -StoreDir $GKOStore -OwnerId 'exec-m1' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$m1dup.ok) -and ([string]$m1dup.reason -ceq 'duplicate-task')) 'M1 duplicate persisted add denied'
$m1done = Complete-OrchestrationGoalTaskPersisted -GoalId 'GKO-M1' -TaskId 'M1-TASK-1' -ExpectedRevision ([long]$m1add.goal['revision']) -StoreDir $GKOStore -OwnerId 'exec-m1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$m1done.ok -and (@($m1done.goal['completed_tasks']).Count -eq 1) -and (@($m1done.goal['active_tasks']).Count -eq 0)) 'M1 persisted complete ok'
$m1st = Set-OrchestrationGoalStatePersisted -GoalId 'GKO-M1' -ToState 'ACTIVE' -ExpectedRevision ([long]$m1done.goal['revision']) -StoreDir $GKOStore -OwnerId 'exec-m1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$m1st.ok -and ([string]$m1st.goal['state'] -ceq 'ACTIVE')) 'M1 persisted DRAFT->ACTIVE ok'
$m1u = Update-OrchestrationGoal -GoalId 'GKO-M1' -ExpectedRevision ([long]$m1st.goal['revision']) -Fields @{ objective = 'managed progress' } -StoreDir $GKOStore -OwnerId 'exec-m1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$m1u.ok) 'M1 gated update mid-cycle ok'
$m1fin = Set-OrchestrationGoalStatePersisted -GoalId 'GKO-M1' -ToState 'COMPLETED' -ExpectedRevision ([long]$m1u.goal['revision']) -StoreDir $GKOStore -OwnerId 'exec-m1' -OwnershipGeneration 1
Assert-GKOThat ([bool]$m1fin.ok -and ([string]$m1fin.goal['state'] -ceq 'COMPLETED')) 'M1 persisted ACTIVE->COMPLETED terminal ok'
$m1post = Add-OrchestrationGoalTaskPersisted -GoalId 'GKO-M1' -TaskId 'M1-LATE' -ExpectedRevision ([long]$m1fin.goal['revision']) -StoreDir $GKOStore -OwnerId 'exec-m1' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$m1post.ok) -and ([string]$m1post.reason -ceq 'terminal-goal')) 'M1 terminal refuses new dispatch'
$m1disk = Get-OrchestrationGoal -GoalId 'GKO-M1' -StoreDir $GKOStore
Assert-GKOThat ([bool]$m1disk.ok -and ([string]$m1disk.goal['state'] -ceq 'COMPLETED') -and (@($m1disk.goal['completed_tasks']).Count -eq 1)) 'M1 full cycle persisted to disk'
# --- M2: expiry between preparation and persistence denies at the commit frontier.
New-GKOSeed -Id 'GKO-M2' | Out-Null
$m2a = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-M2' -OwnerId 'exec-m2' -ExpectedRevision 1 -StoreDir $GKOStore -LeaseTtlMs 400
Assert-GKOThat ([bool]$m2a.ok) 'M2 short-lease acquire ok'
Start-Sleep -Milliseconds 1200
$m2u = Update-OrchestrationGoal -GoalId 'GKO-M2' -ExpectedRevision ([long]$m2a.revision) -Fields @{ objective = 'late write' } -StoreDir $GKOStore -OwnerId 'exec-m2' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$m2u.ok) -and ([string]$m2u.reason -ceq 'owner-lease-expired')) 'M2 lapsed lease commit denied'
$m2t = Add-OrchestrationGoalTaskPersisted -GoalId 'GKO-M2' -TaskId 'M2-TASK-1' -ExpectedRevision ([long]$m2a.revision) -StoreDir $GKOStore -OwnerId 'exec-m2' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$m2t.ok) -and ([string]$m2t.reason -ceq 'owner-lease-expired')) 'M2 lapsed lease persisted-task commit denied'
$m2s = Set-OrchestrationGoalStatePersisted -GoalId 'GKO-M2' -ToState 'ACTIVE' -ExpectedRevision ([long]$m2a.revision) -StoreDir $GKOStore -OwnerId 'exec-m2' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$m2s.ok) -and ([string]$m2s.reason -ceq 'owner-lease-expired')) 'M2 lapsed lease persisted-state commit denied'
$m2disk = Get-OrchestrationGoal -GoalId 'GKO-M2' -StoreDir $GKOStore
Assert-GKOThat (([long]$m2disk.goal['revision'] -eq [long]$m2a.revision) -and ([string]$m2disk.goal['objective'] -ceq 'owned work')) 'M2 lapsed commits wrote nothing'
# --- M2-REGATE: expiry AFTER initial admission denies at the pre-write re-gate.
New-GKOSeed -Id 'GKO-M2R' | Out-Null
$m2rA = Acquire-OrchestrationGoalOwnership -GoalId 'GKO-M2R' -OwnerId 'exec-m2r' -ExpectedRevision 1 -StoreDir $GKOStore -LeaseTtlMs 400
Assert-GKOThat ([bool]$m2rA.ok) 'M2-REGATE short-lease acquire ok'
$m2rRev = [long]$m2rA.revision
$m2rLive = (Get-OrchestrationGoal -GoalId 'GKO-M2R' -StoreDir $GKOStore).goal
$m2rAdmit = Test-GKGoalCommitOwnership -Record $m2rLive -OwnerId 'exec-m2r' -OwnershipGeneration 1
Assert-GKOThat ([bool]$m2rAdmit.admitted) 'M2-REGATE initially admitted while lease live'
Start-Sleep -Milliseconds 1200
$m2rRe = Test-GKGoalCommitOwnership -Record $m2rLive -OwnerId 'exec-m2r' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$m2rRe.admitted) -and ([string]$m2rRe.reason -ceq 'owner-lease-expired')) 'M2-REGATE same record denied after expiry (pre-write re-gate frontier)'
$m2rU = Update-OrchestrationGoal -GoalId 'GKO-M2R' -ExpectedRevision $m2rRev -Fields @{ objective = 'late write' } -StoreDir $GKOStore -OwnerId 'exec-m2r' -OwnershipGeneration 1
Assert-GKOThat ((-not [bool]$m2rU.ok) -and ([string]$m2rU.reason -ceq 'owner-lease-expired')) 'M2-REGATE lapsed commit denied end-to-end'
$m2rDisk = Get-OrchestrationGoal -GoalId 'GKO-M2R' -StoreDir $GKOStore
Assert-GKOThat (([long]$m2rDisk.goal['revision'] -eq $m2rRev) -and ([string]$m2rDisk.goal['objective'] -ceq 'owned work')) 'M2-REGATE revision and content unaltered'
try { Remove-Item -LiteralPath $GKOStore -Recurse -Force -ErrorAction SilentlyContinue } catch { }
Write-Output "PASS OrchestrationGoalKernelOwnership: $passed assertions"
