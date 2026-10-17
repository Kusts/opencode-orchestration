<#!
.SYNOPSIS
    F2 corrective drills F+G: ambiguous result and incorrect completion.
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; the repo tree is never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn, no model provider.

    Reuses the F3 fixture driver verbatim (tests/f3) plus the pure
    reconciler (scripts/v3/lib); no endpoint, no executor, no authority
    added. FACTS are read back from kernel stores (receipt phase, task
    revision/state, goal progress); the only SIMULATION is the worker
    effect (one deterministic artifact between CLAIM and the withheld
    acknowledgement, exactly like F3 [N2]).

    Drill F (ambiguous result, criterion:1): claim without settle leaves
    the receipt claimed/DISPATCH_UNCERTAIN; a substitute revalidates live
    ownership, reconciles WITHOUT replay (pure reconciler over divergent
    observations stays ambiguous with zero actions), re-prepare and
    second-key claim are refused with zero effects, a divergent-lineage
    settlement is refused, and only the exact original lineage settles -
    with no second execution. Drill F2 (same criterion, independent
    objective): after CLAIM the fencing token is revoked through the real
    kernel path (short-lease Renew, wait past expiry, kernel Takeover to
    a rival owner); a SETTLE with the EXACT original host lineage is then
    refused with the specific ownership-not-held reason and the receipt
    stays claimed (never SETTLED). The positive control stays
    independent: settle with live ownership plus the exact lineage
    settles and the receipt is read back as settled.

    Drill G (incorrect completion, criterion:2): a worker-declared
    done/verified_pass is refused by the result shape gate AND by the
    TaskKernel (STATUS_NOT_ALLOWED_FROM_WORKER); completion outside
    REVIEWING is refused; verification without a verifier status is
    refused (never self-attested); after EVERY refusal the task is read
    back and must stay IMPLEMENTING with revision and file bytes
    unchanged. Every refusal envelope is recorded as the refusal
    receipt: 6 in G, 10 aggregate (F=3, F2=1, G=6).

    Fail-closed (criterion:3): any doubt denies the transition; the suite
    counts illegal DONE outcomes and asserts zero.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationF3ThreePhaseFixture.ps1')
$fgReconciler = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\v3\lib\OrchestrationSessionReconciler.ps1'))
. $fgReconciler

$script:passed = 0
$script:failed = 0
$script:illegalDone = 0
$script:refusals = New-Object System.Collections.ArrayList

function Assert-FG {
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

function Register-FGRefusal {
    param([string]$Code = '')
    [void]$script:refusals.Add([string]$Code)
}

function Assert-FGNotDone {
    param($TaskRec, [string]$Name)
    $st = [string](Get-F3Value $TaskRec 'state' '')
    if ($st -ceq 'DONE') { $script:illegalDone++ }
    Assert-FG ($st -cne 'DONE') $Name ('state=' + $st)
}

function Assert-FGTaskUnchanged {
    param([string]$Name, [string]$TasksDir, [string]$FilePath, [int]$ExpectedRevision, [string]$ExpectedHash)
    $live = $null
    try { $live = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir $TasksDir } catch { $live = $null }
    $st = [string](Get-F3Value $live 'state' '')
    $rv = [int](Get-F3Value $live 'revision' -1)
    $hh = ''
    try { $hh = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash } catch { $hh = '' }
    Assert-FG ((($st -ceq 'IMPLEMENTING') -and ($rv -eq $ExpectedRevision) -and ($hh -ceq $ExpectedHash))) $Name ('state=' + $st + ' rev=' + [string]$rv)
}

$tempRoot = ''
try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('fg-suite-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Register-F3OwnedRoot -Root $tempRoot

    # ================= [F] ambiguous result: claim without settle =================
    $eF = New-F3Environment -Label 'fg-f'
    $gF = New-F3Goal -Environment $eF -GoalId 'fg-goal-f' -Criteria @('crit-f1')
    Assert-FG ([bool](Get-F3Value $gF 'ok' $false)) '[F] drill-f objective ready' ([string](Get-F3Value $gF 'reason' ''))
    $gidF = [string](Get-F3Value (Get-F3Value $gF 'data' $null) 'goal_id' '')
    $genF = [long](Get-F3Value (Get-F3Value $gF 'data' $null) 'gen' 0)
    $authF = Get-F3Value (Get-F3Value $gF 'data' $null) 'auth' $null
    $tF = New-F3PhaseTask -Environment $eF -GoalId $gidF -PhaseIndex 1 -TotalPhases 1
    Assert-FG ([bool](Get-F3Value $tF 'ok' $false)) '[F] drill-f phase task ready' ([string](Get-F3Value $tF 'reason' ''))
    $tdF = Get-F3Value $tF 'data' $null
    $null = Add-F3TaskToGoal -Environment $eF -GoalId $gidF -TaskId 'f3-p1' -Gen $genF
    $liveF = Get-F3LiveGoal -Environment $eF -GoalId $gidF
    $intentF = (New-F3DispatchIntent -GoalId $gidF -TaskId 'f3-p1' -TaskExpectedRevision ([long](Get-F3Value $tdF 'revision' 0)) -Gen $genF -Scope ([string](Get-F3Value $tdF 'scope' '')) -PhaseIndex 1).data.intent
    $ctrF = @{ executions = 0 }

    $crash = Invoke-F3ReceiptWalk -Environment $eF -Goal $liveF -Authorization $authF -Intent $intentF `
        -TaskId 'f3-p1' -ArtifactPath ([string](Get-F3Value $tdF 'artifact' '')) -PhaseIndex 1 -Counter $ctrF `
        -CallId 'call_fg_f' -MessageId 'msg_fg_f' -ChildSessionId 'ses_fg_f_child' -SkipSettle
    Assert-FG (([bool](Get-F3Value $crash 'ok' $false)) -and ([string](Get-F3Value $crash 'reason' '') -ceq 'ack-withheld') -and ([int]$ctrF.executions -eq 1)) '[F] claim ran the effect once and the acknowledgement was withheld' ([string](Get-F3Value $crash 'reason' ''))
    $rcF = Get-F3ReceiptRaw -Environment $eF -GoalId $gidF -Key ([string](Get-F3Value (Get-F3Value $crash 'data' $null) 'key' ''))
    Assert-FG (([string](Get-F3Value $rcF 'phase' '') -ceq 'claimed') -and ([string](Get-F3Value $rcF 'handoff_state' '') -ceq 'DISPATCH_UNCERTAIN')) '[F] the receipt stays claimed/DISPATCH_UNCERTAIN (ambiguous, not settled)' ('phase=' + [string](Get-F3Value $rcF 'phase' '') + ' handoff=' + [string](Get-F3Value $rcF 'handoff_state' ''))

    # The substitute revalidates live ownership before touching anything.
    $liveAgain = Get-F3LiveGoal -Environment $eF -GoalId $gidF
    Assert-FG (([string](Get-F3Value $liveAgain 'state' '') -ceq 'ACTIVE')) '[F] the substitute re-reads a live ACTIVE objective' ([string](Get-F3Value $liveAgain 'state' ''))
    $fenceLive = Test-NDPostLockFencing -GoalId $gidF -Owner 'planner-1' -Generation $genF -GoalStoreDir ([string](Get-F3Value $eF 'goal_dir' ''))
    Assert-FG ([bool](Get-F3Value $fenceLive 'ok' $false)) '[F] the substitute fencing token is the live one' ([string](Get-F3Value $fenceLive 'reason' ''))
    $fenceStale = Test-NDPostLockFencing -GoalId $gidF -Owner 'planner-1' -Generation ($genF + 99) -GoalStoreDir ([string](Get-F3Value $eF 'goal_dir' ''))
    Assert-FG (((-not [bool](Get-F3Value $fenceStale 'ok' $false)) -and ([string](Get-F3Value $fenceStale 'reason' '') -like 'post-lock-fencing-changed*'))) '[F] a superseded generation fails the fencing revalidation' ([string](Get-F3Value $fenceStale 'reason' ''))

    # Reconciliation is pure and replays nothing: divergent observations
    # stay ambiguous with zero recommended actions.
    $recF = Get-OrchestrationSessionReconciliation `
        -Bindings @(@{ run_id = 'fg-f-run'; root_session = 'ses_fg_f_child'; worker_sessions = @() }) `
        -Observations @(@{ session_id = 'ses_fg_f_child'; observed = 'completed'; output_ref = 'artifact-ref' }, @{ session_id = 'ses_fg_f_child'; observed = 'missing' }) `
        -StaleAfterSeconds 60 -TimestampUtc '2026-10-06T12:00:00Z'
    $rowF = @($recF.runs | Where-Object { $_.session_id -ceq 'ses_fg_f_child' })
    Assert-FG ((@($rowF).Count -eq 1) -and ([string]$rowF[0].status -ceq 'stale') -and ([string]$rowF[0].detail -ceq 'ambiguous_observations') -and ([string]::IsNullOrWhiteSpace([string]$rowF[0].output_ref))) '[F] divergent observations reconcile as ambiguous, never last-wins' ([string]$rowF[0].status)
    Assert-FG ((@($recF.recommended_actions | Where-Object { $_.session_id -ceq 'ses_fg_f_child' }).Count -eq 0)) '[F] the ambiguous reconciliation recommends zero actions (no replay)' ''
    Assert-FG ((-not [bool](Get-F3Value $recF 'probed' $true))) '[F] the reconciliation probed nothing' ''

    # No replay through the dispatch path either.
    $replaySame = Invoke-OrchestrationNativeDispatchPrepare -Intent $intentF -Authorization $authF -SessionId 'ses_f3_parent' `
        -ReceiptDir ([string](Get-F3Value $eF 'receipt_dir' '')) -GoalStoreDir ([string](Get-F3Value $eF 'goal_dir' '')) -TasksDir ([string](Get-F3Value $eF 'tasks_dir' '')) -FlagsPath ([string](Get-F3Value $eF 'flags' ''))
    Assert-FG (((-not [bool](Get-F3Value $replaySame 'ok' $false)) -and ([string](Get-F3Value $replaySame 'reason' '') -ceq 'prepare-already-claimed') -and ([int](Get-F3Value $replaySame 'executor_calls' -1) -eq 0))) '[F] the ambiguous claim is never re-prepared automatically' ([string](Get-F3Value $replaySame 'reason' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $replaySame 'reason' ''))
    $otherIntent = (New-F3DispatchIntent -GoalId $gidF -TaskId 'f3-p1' -TaskExpectedRevision ([long](Get-F3Value $tdF 'revision' 0)) -Gen $genF -Scope ([string](Get-F3Value $tdF 'scope' '')) -PhaseIndex 7).data.intent
    $otherPrep = Invoke-OrchestrationNativeDispatchPrepare -Intent $otherIntent -Authorization $authF -SessionId 'ses_f3_parent' `
        -ReceiptDir ([string](Get-F3Value $eF 'receipt_dir' '')) -GoalStoreDir ([string](Get-F3Value $eF 'goal_dir' '')) -TasksDir ([string](Get-F3Value $eF 'tasks_dir' '')) -FlagsPath ([string](Get-F3Value $eF 'flags' ''))
    $otherClaim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey (Get-F3PreparedKey -Prepare $otherPrep) -Authorization $authF `
        -SessionId 'ses_f3_parent' -MessageId 'msg_fg_f_other' -CallId 'call_fg_f_other' -CallerAgent 'planner' -TargetAgent 'coder' `
        -PreparedFingerprint ([string](Get-F3Value $otherPrep 'prepared_fingerprint' '')) -ReceiptDir ([string](Get-F3Value $eF 'receipt_dir' '')) `
        -GoalStoreDir ([string](Get-F3Value $eF 'goal_dir' '')) -TasksDir ([string](Get-F3Value $eF 'tasks_dir' '')) -FlagsPath ([string](Get-F3Value $eF 'flags' ''))
    Assert-FG (((-not [bool](Get-F3Value $otherClaim 'ok' $false)) -and ([string](Get-F3Value $otherClaim 'reason' '') -ceq 'claim-task-already-claimed') -and ([int](Get-F3Value $otherClaim 'executor_calls' -1) -eq 0))) '[F] a second key on the same task is refused at the effect boundary' ([string](Get-F3Value $otherClaim 'reason' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $otherClaim 'reason' ''))
    Assert-FG (([int]$ctrF.executions -eq 1)) '[F] every refused replay executed zero additional effects (counter still 1)' ([string]$ctrF.executions)

    # No transition to SETTLED without revalidation: divergent lineage
    # refuses, the claim stays unresolved, and only the exact original
    # lineage settles - without re-running the effect.
    $crashKey = [string](Get-F3Value (Get-F3Value $crash 'data' $null) 'key' '')
    $crashFp = [string](Get-F3Value (Get-F3Value $crash 'data' $null) 'prepared_fingerprint' '')
    $crashRef = [string](Get-F3Value (Get-F3Value $crash 'data' $null) 'reference' '')
    $wrongLineage = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $crashKey -Authorization $authF `
        -ChildSessionId 'ses_fg_f_child' -SessionId 'ses_f3_parent' -MessageId 'msg_fg_f' -CallId 'call_never_made' `
        -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $crashFp `
        -Reference $crashRef -TaskId 'f3-p1' -Result @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } `
        -ReceiptDir ([string](Get-F3Value $eF 'receipt_dir' '')) -GoalStoreDir ([string](Get-F3Value $eF 'goal_dir' '')) -EvidenceStoreDir ([string](Get-F3Value $eF 'ev_dir' '')) `
        -TasksDir ([string](Get-F3Value $eF 'tasks_dir' '')) -FlagsPath ([string](Get-F3Value $eF 'flags' ''))
    Assert-FG (((-not [bool](Get-F3Value $wrongLineage 'ok' $false)) -and ([int](Get-F3Value $wrongLineage 'executor_calls' -1) -eq 0))) '[F] a settlement with a divergent host call lineage is refused' ([string](Get-F3Value $wrongLineage 'reason' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $wrongLineage 'reason' ''))
    $rcStill = Get-F3ReceiptRaw -Environment $eF -GoalId $gidF -Key $crashKey
    Assert-FG (([string](Get-F3Value $rcStill 'phase' '') -ceq 'claimed')) '[F] the refused settlement left the claim unresolved (never SETTLED)' ([string](Get-F3Value $rcStill 'phase' ''))
    $rightLineage = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $crashKey -Authorization $authF `
        -ChildSessionId 'ses_fg_f_child' -SessionId 'ses_f3_parent' -MessageId 'msg_fg_f' -CallId 'call_fg_f' `
        -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $crashFp `
        -Reference $crashRef -TaskId 'f3-p1' -Result @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } `
        -ReceiptDir ([string](Get-F3Value $eF 'receipt_dir' '')) -GoalStoreDir ([string](Get-F3Value $eF 'goal_dir' '')) -EvidenceStoreDir ([string](Get-F3Value $eF 'ev_dir' '')) `
        -TasksDir ([string](Get-F3Value $eF 'tasks_dir' '')) -FlagsPath ([string](Get-F3Value $eF 'flags' ''))
    Assert-FG (([bool](Get-F3Value $rightLineage 'ok' $false)) -and ([bool](Get-F3Value $rightLineage 'settled' $false))) '[F] the exact original lineage settles the ambiguous claim' ([string](Get-F3Value $rightLineage 'reason' ''))
    Assert-FG (([int]$ctrF.executions -eq 1)) '[F] settling the ambiguous claim re-ran no effect (counter still 1)' ([string]$ctrF.executions)
    $rcSettled = Get-F3ReceiptRaw -Environment $eF -GoalId $gidF -Key $crashKey
    Assert-FG (([string](Get-F3Value $rcSettled 'phase' '') -ceq 'settled')) '[F] the successful settle is read back as settled' ([string](Get-F3Value $rcSettled 'phase' ''))
    $taskF = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir ([string](Get-F3Value $eF 'tasks_dir' ''))
    Assert-FGNotDone -TaskRec $taskF -Name '[F] the ambiguous drill never produced a DONE'
    Remove-F3Environment -Environment $eF | Out-Null

    # ================= [F2] settle revalidates live ownership =================
    # Independent hermetic objective: after CLAIM, the fencing token is
    # revoked through the REAL kernel path (short-lease Renew, wait past
    # expiry, kernel Takeover to a rival owner). A SETTLE with the EXACT
    # original host lineage must then refuse with the specific
    # ownership-not-held reason and leave the receipt claimed. No mock:
    # the refusal comes from the live store read on the settle path.
    # Limit declared: the expiry itself is time travel (1ms lease plus a
    # 250ms wait, both far from any boundary); the revocation is the real
    # kernel Takeover API and the refusal is the real settle-path gate.
    $eF2 = New-F3Environment -Label 'fg-f2'
    $gF2 = New-F3Goal -Environment $eF2 -GoalId 'fg-goal-f2' -Criteria @('crit-f2')
    Assert-FG ([bool](Get-F3Value $gF2 'ok' $false)) '[F2] drill-f2 objective ready' ([string](Get-F3Value $gF2 'reason' ''))
    $gidF2 = [string](Get-F3Value (Get-F3Value $gF2 'data' $null) 'goal_id' '')
    $genF2 = [long](Get-F3Value (Get-F3Value $gF2 'data' $null) 'gen' 0)
    $authF2 = Get-F3Value (Get-F3Value $gF2 'data' $null) 'auth' $null
    $tF2 = New-F3PhaseTask -Environment $eF2 -GoalId $gidF2 -PhaseIndex 1 -TotalPhases 1
    Assert-FG ([bool](Get-F3Value $tF2 'ok' $false)) '[F2] drill-f2 phase task ready' ([string](Get-F3Value $tF2 'reason' ''))
    $tdF2 = Get-F3Value $tF2 'data' $null
    $null = Add-F3TaskToGoal -Environment $eF2 -GoalId $gidF2 -TaskId 'f3-p1' -Gen $genF2
    $liveF2 = Get-F3LiveGoal -Environment $eF2 -GoalId $gidF2
    $intentF2 = (New-F3DispatchIntent -GoalId $gidF2 -TaskId 'f3-p1' -TaskExpectedRevision ([long](Get-F3Value $tdF2 'revision' 0)) -Gen $genF2 -Scope ([string](Get-F3Value $tdF2 'scope' '')) -PhaseIndex 1).data.intent
    $ctrF2 = @{ executions = 0 }
    $crash2 = Invoke-F3ReceiptWalk -Environment $eF2 -Goal $liveF2 -Authorization $authF2 -Intent $intentF2 `
        -TaskId 'f3-p1' -ArtifactPath ([string](Get-F3Value $tdF2 'artifact' '')) -PhaseIndex 1 -Counter $ctrF2 `
        -CallId 'call_fg_f2' -MessageId 'msg_fg_f2' -ChildSessionId 'ses_fg_f2_child' -SkipSettle
    Assert-FG (([bool](Get-F3Value $crash2 'ok' $false)) -and ([string](Get-F3Value $crash2 'reason' '') -ceq 'ack-withheld') -and ([int]$ctrF2.executions -eq 1)) '[F2] claim ran the effect once and the acknowledgement was withheld' ([string](Get-F3Value $crash2 'reason' ''))
    $keyF2 = [string](Get-F3Value (Get-F3Value $crash2 'data' $null) 'key' '')
    $rcF2 = Get-F3ReceiptRaw -Environment $eF2 -GoalId $gidF2 -Key $keyF2
    Assert-FG (([string](Get-F3Value $rcF2 'phase' '') -ceq 'claimed')) '[F2] the receipt is claimed before ownership is revoked' ([string](Get-F3Value $rcF2 'phase' ''))
    $renewF2 = Renew-OrchestrationGoalOwnership -GoalId $gidF2 -OwnerId 'planner-1' -Generation $genF2 -StoreDir ([string](Get-F3Value $eF2 'goal_dir' '')) -LeaseTtlMs 1
    Assert-FG ([bool](Get-F3Value $renewF2 'ok' $false)) '[F2] the lease is shortened through the kernel renew path' ([string](Get-F3Value $renewF2 'reason' ''))
    Start-Sleep -Milliseconds 250
    $takeF2 = Takeover-OrchestrationGoalOwnership -GoalId $gidF2 -OwnerId 'planner-2' -StoreDir ([string](Get-F3Value $eF2 'goal_dir' '')) -LeaseTtlMs 300000
    Assert-FG (([bool](Get-F3Value $takeF2 'ok' $false)) -and ([long](Get-F3Value (Get-F3Value $takeF2 'ownership' $null) 'generation' 0) -eq ($genF2 + 1))) '[F2] a rival takes over after provable expiry (generation advances)' ([string](Get-F3Value $takeF2 'reason' ''))
    $fpF2 = [string](Get-F3Value (Get-F3Value $crash2 'data' $null) 'prepared_fingerprint' '')
    $refF2 = [string](Get-F3Value (Get-F3Value $crash2 'data' $null) 'reference' '')
    $staleSettle = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $keyF2 -Authorization $authF2 `
        -ChildSessionId 'ses_fg_f2_child' -SessionId 'ses_f3_parent' -MessageId 'msg_fg_f2' -CallId 'call_fg_f2' `
        -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $fpF2 `
        -Reference $refF2 -TaskId 'f3-p1' -Result @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } `
        -ReceiptDir ([string](Get-F3Value $eF2 'receipt_dir' '')) -GoalStoreDir ([string](Get-F3Value $eF2 'goal_dir' '')) -EvidenceStoreDir ([string](Get-F3Value $eF2 'ev_dir' '')) `
        -TasksDir ([string](Get-F3Value $eF2 'tasks_dir' '')) -FlagsPath ([string](Get-F3Value $eF2 'flags' ''))
    Assert-FG (((-not [bool](Get-F3Value $staleSettle 'ok' $false)) -and ([string](Get-F3Value $staleSettle 'reason' '') -ceq 'ownership-not-held:owner-conflict') -and ([int](Get-F3Value $staleSettle 'executor_calls' -1) -eq 0))) '[F2] exact-lineage settle with revoked ownership is refused (live revalidation)' ([string](Get-F3Value $staleSettle 'reason' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $staleSettle 'reason' ''))
    $rcF2Still = Get-F3ReceiptRaw -Environment $eF2 -GoalId $gidF2 -Key $keyF2
    Assert-FG (([string](Get-F3Value $rcF2Still 'phase' '') -ceq 'claimed')) '[F2] the refused settle left the claim unresolved (never SETTLED)' ([string](Get-F3Value $rcF2Still 'phase' ''))
    Assert-FG (([int]$ctrF2.executions -eq 1)) '[F2] the refused settle re-ran no effect (counter still 1)' ([string]$ctrF2.executions)
    Remove-F3Environment -Environment $eF2 | Out-Null

    # ================= [G] incorrect completion: worker-declared done =================
    $eG = New-F3Environment -Label 'fg-g'
    $gG = New-F3Goal -Environment $eG -GoalId 'fg-goal-g' -Criteria @('crit-g1')
    Assert-FG ([bool](Get-F3Value $gG 'ok' $false)) '[G] drill-g objective ready' ([string](Get-F3Value $gG 'reason' ''))
    $gidG = [string](Get-F3Value (Get-F3Value $gG 'data' $null) 'goal_id' '')
    $genG = [long](Get-F3Value (Get-F3Value $gG 'data' $null) 'gen' 0)
    $tG = New-F3PhaseTask -Environment $eG -GoalId $gidG -PhaseIndex 1 -TotalPhases 1
    Assert-FG ([bool](Get-F3Value $tG 'ok' $false)) '[G] drill-g phase task ready' ([string](Get-F3Value $tG 'reason' ''))
    $null = Add-F3TaskToGoal -Environment $eG -GoalId $gidG -TaskId 'f3-p1' -Gen $genG
    $tasksG = [string](Get-F3Value $eG 'tasks_dir' '')
    $flagsG = [string](Get-F3Value $eG 'flags' '')
    $teleG = [string](Get-F3Value $eG 'telemetry' '')
    $liveG = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir $tasksG
    Assert-FG (([string](Get-F3Value $liveG 'state' '') -ceq 'IMPLEMENTING')) '[G] the drill task starts IMPLEMENTING' ([string](Get-F3Value $liveG 'state' ''))
    $revG = [int](Get-F3Value $liveG 'revision' 0)
    $fileG = Join-Path $tasksG 'f3-p1.json'
    $hashBefore = (Get-FileHash -LiteralPath $fileG -Algorithm SHA256).Hash

    $shapePass = Test-OrchestrationDispatchResultShape -Result @{ status = 'verified_pass'; claimed_evidence = @('criterion:0') }
    Assert-FG (((-not [bool](Get-F3Value $shapePass 'ok' $false)) -and ([string](Get-F3Value $shapePass 'reason' '') -ceq 'status-not-allowed-from-worker'))) '[G] a worker-declared verified_pass is rejected by the result shape gate' ([string](Get-F3Value $shapePass 'reason' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $shapePass 'reason' ''))
    Assert-FGTaskUnchanged -Name '[G] refused verified_pass shape leaves IMPLEMENTING/revision/bytes unchanged' -TasksDir $tasksG -FilePath $fileG -ExpectedRevision $revG -ExpectedHash $hashBefore
    $shapeDone = Test-OrchestrationDispatchResultShape -Result @{ status = 'done'; claimed_evidence = @('criterion:0') }
    Assert-FG ((-not [bool](Get-F3Value $shapeDone 'ok' $false))) '[G] a worker-declared done is rejected by the result shape gate' ([string](Get-F3Value $shapeDone 'reason' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $shapeDone 'reason' ''))
    Assert-FGTaskUnchanged -Name '[G] refused done shape leaves IMPLEMENTING/revision/bytes unchanged' -TasksDir $tasksG -FilePath $fileG -ExpectedRevision $revG -ExpectedHash $hashBefore

    $rjPass = Set-OrchestrationTaskWorkerResult -TaskId 'f3-p1' -Status 'verified_pass' -ProducedBy 'coder' -ExpectedRevision $revG -TasksDir $tasksG -FlagsPath $flagsG -TelemetryRoot $teleG
    Assert-FG (((-not [bool](Get-F3Value $rjPass 'ok' $false)) -and ([string](Get-F3Value $rjPass 'error' '') -ceq 'STATUS_NOT_ALLOWED_FROM_WORKER'))) '[G] the kernel refuses verified_pass from a worker' ([string](Get-F3Value $rjPass 'error' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $rjPass 'error' ''))
    Assert-FGTaskUnchanged -Name '[G] refused kernel verified_pass leaves IMPLEMENTING/revision/bytes unchanged' -TasksDir $tasksG -FilePath $fileG -ExpectedRevision $revG -ExpectedHash $hashBefore
    $rjDone = Set-OrchestrationTaskWorkerResult -TaskId 'f3-p1' -Status 'done' -ProducedBy 'coder' -ExpectedRevision $revG -TasksDir $tasksG -FlagsPath $flagsG -TelemetryRoot $teleG
    Assert-FG (((-not [bool](Get-F3Value $rjDone 'ok' $false)) -and ([string](Get-F3Value $rjDone 'error' '') -ceq 'STATUS_NOT_ALLOWED_FROM_WORKER'))) '[G] the kernel refuses done from a worker' ([string](Get-F3Value $rjDone 'error' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $rjDone 'error' ''))
    Assert-FGTaskUnchanged -Name '[G] refused kernel done leaves IMPLEMENTING/revision/bytes unchanged' -TasksDir $tasksG -FilePath $fileG -ExpectedRevision $revG -ExpectedHash $hashBefore
    $afterRj = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir $tasksG
    Assert-FG ((([string](Get-F3Value $afterRj 'state' '') -ceq 'IMPLEMENTING') -and ([int](Get-F3Value $afterRj 'revision' -1) -eq $revG))) '[G] refused injections leave the task IMPLEMENTING at the same revision' ('state=' + [string](Get-F3Value $afterRj 'state' '') + ' rev=' + [string](Get-F3Value $afterRj 'revision' ''))
    Assert-FG ((((Get-FileHash -LiteralPath $fileG -Algorithm SHA256).Hash) -ceq $hashBefore)) '[G] refused injections changed zero task bytes' ''

    $earlyDone = Complete-OrchestrationTask -TaskId 'f3-p1' -Actor 'planner-1' -ExpectedRevision $revG `
        -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' `
        -TasksDir $tasksG -FlagsPath $flagsG -TelemetryRoot $teleG
    Assert-FG (((-not [bool](Get-F3Value $earlyDone 'ok' $false)) -and ([string](Get-F3Value $earlyDone 'error' '') -ceq 'ILLEGAL_COMPLETION_STATE'))) '[G] completion outside REVIEWING is refused' ([string](Get-F3Value $earlyDone 'error' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $earlyDone 'error' ''))
    Assert-FGTaskUnchanged -Name '[G] refused early completion leaves IMPLEMENTING/revision/bytes unchanged' -TasksDir $tasksG -FilePath $fileG -ExpectedRevision $revG -ExpectedHash $hashBefore
    $badVerify = Set-OrchestrationTaskVerification -TaskId 'f3-p1' -VerifierEvidenceJson '{"ok":true,"no_status_here":1}' -ExpectedRevision $revG -TasksDir $tasksG -FlagsPath $flagsG
    Assert-FG ((-not [bool](Get-F3Value $badVerify 'ok' $false))) '[G] verification without a verifier status is refused (never self-attested)' ([string](Get-F3Value $badVerify 'error' ''))
    Register-FGRefusal -Code ([string](Get-F3Value $badVerify 'error' ''))
    Assert-FGTaskUnchanged -Name '[G] refused self-attested verification leaves IMPLEMENTING/revision/bytes unchanged' -TasksDir $tasksG -FilePath $fileG -ExpectedRevision $revG -ExpectedHash $hashBefore
    $taskG = Get-OrchestrationTask -TaskId 'f3-p1' -TasksDir $tasksG
    Assert-FGNotDone -TaskRec $taskG -Name '[G] the incorrect-completion drill never produced a DONE'
    $lgG = Get-F3LiveGoal -Environment $eG -GoalId $gidG
    Assert-FG (([string](Get-F3Value $lgG 'state' '') -ceq 'ACTIVE') -and ([long](Get-F3Value (Get-F3Value $lgG 'progress' $null) 'satisfied' -1) -eq 0)) '[G] the objective records no verified progress' ('sat=' + [string](Get-F3Value (Get-F3Value $lgG 'progress' $null) 'satisfied' ''))
    Remove-F3Environment -Environment $eG | Out-Null

    # ================= [C] fail-closed totals =================
    # Refusal receipts: [F] 3 + [F2] 1 + [G] 6 = 10 aggregate (6 in G).
    Assert-FG (($script:illegalDone -eq 0)) '[C] illegal transitions produced zero DONE outcomes' ([string]$script:illegalDone)
    Assert-FG ((@($script:refusals).Count -ge 10)) '[C] every refusal receipt was recorded with a machine-readable code (10 aggregate: F=3 F2=1 G=6)' ([string]@($script:refusals).Count)
    $emptyCodes = @(@($script:refusals) | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) })
    Assert-FG ((@($emptyCodes).Count -eq 0)) '[C] no refusal receipt is empty' ([string]@($emptyCodes).Count)

    # ================= [H] hygiene =================
    $meFile = Join-Path $PSScriptRoot 'OrchestrationF3CorrectiveDrillsFG.tests.ps1'
    $meBytes = [IO.File]::ReadAllBytes($meFile)
    $meBad = 0
    foreach ($by in $meBytes) { if ([int]$by -gt 127) { $meBad++ } }
    Assert-FG (($meBad -eq 0)) '[H] ASCII-only OrchestrationF3CorrectiveDrillsFG.tests.ps1' ([string]$meBad)
    $meText = [IO.File]::ReadAllText($meFile, [Text.UTF8Encoding]::new($false))
    $spawnPat = ('Start-' + 'Process')
    $netPat1 = ('Invoke-' + 'WebRequest')
    $netPat2 = ('Invoke-' + 'RestMethod')
    $netPat3 = ('Http' + 'Client')
    Assert-FG ((($meText -notmatch $spawnPat) -and ($meText -notmatch $netPat1) -and ($meText -notmatch $netPat2) -and ($meText -notmatch $netPat3))) '[H] no spawn and no network in the drill suite' ''

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Unregister-F3OwnedRoot -Root $tempRoot
}
finally {
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
