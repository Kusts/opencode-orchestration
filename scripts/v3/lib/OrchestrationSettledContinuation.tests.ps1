<#!
.SYNOPSIS
    Tests for S3a settled continuation (fixture-only).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written
    (the real validation-policy.json is only READ). Bracketed output the
    runner parses. Exit 0 all pass, 1 any fail. PS 5.1 compatible.
    ASCII-only. No network, no spawn, no Executor.
    Covers: CONTINUE happy (1 prepare, rev/next key, checkpoint sidecar),
    RETRY corrective (failed task never DONE), REPLAN (0 prepare, record),
    BLOCKED (0 prepare, goal unmutated), COMPLETE valid (gate + CAS),
    COMPLETE refused (missing criteria / policy stop never completes),
    missing/stale/negative review, L3 without security, manual and unknown
    profiles, prepared replay, pending/divergent recovery (uncertain),
    ND replay preserving the recorded decision, ND policy-stop finalize
    refusal, corrupted/uncertain records, checkpoint failure post-PREPARE,
    legacy compatibility without SettledKey.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1')

$script:passed = 0
$script:failed = 0

function Assert-SC {
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

function Get-SCValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-s3a-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $env = [ordered]@{
        root   = $tempRoot
        goals  = (Join-Path $tempRoot 'goals')
        ckpts  = (Join-Path $tempRoot 'checkpoints')
        recs   = (Join-Path $tempRoot 'receipts')
        evs    = (Join-Path $tempRoot 'evidence')
        tasks  = (Join-Path $tempRoot 'tasks')
        tele   = (Join-Path $tempRoot 'telemetry')
        flags  = (Join-Path $tempRoot 'flags.json')
    }
    foreach ($d in @($env.goals, $env.ckpts, $env.recs, $env.evs, $env.tasks, $env.tele)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($env.flags, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.Encoding]::UTF8)
    $script:scEnv = $env
    $script:scSeq = 0

    function New-SCIds { param([string]$Tag)
        $script:scSeq++
        $n = [string]$script:scSeq
        return [pscustomobject]@{
            goal = ('s3-goal-' + $Tag + '-' + $n)
            task = ('s3-task-' + $Tag + '-' + $n)
            next = ('s3-next-' + $Tag + '-' + $n)
        }
    }

    function New-SCGoal {
        param([string]$GoalId, [string[]]$Criteria = @('s3-crit-a', 's3-crit-b'))
        $g = New-OrchestrationGoal -GoalId $GoalId -Objective ('s3 objective ' + $GoalId) -Criteria @($Criteria) -StoreDir $script:scEnv.goals
        Assert-SC ([bool]$g.ok) ('[F] goal created ' + $GoalId) ([string]$g.reason)
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $script:scEnv.goals
        Assert-SC ([bool]$sv.ok) ('[F] goal active ' + $GoalId) ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $script:scEnv.goals
        Assert-SC ([bool]$own.ok) ('[F] goal owned ' + $GoalId) ([string]$own.reason)
        $gen = [long]$own.ownership['generation']
        return [pscustomobject]@{ goal_id = $GoalId; gen = $gen; auth = @{ explicit_allow = $true; goal_id = $GoalId; owner = 'planner-1'; generation = $gen; source = 'planner' } }
    }

    function Get-SCLiveGoal { param([string]$GoalId)
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $script:scEnv.goals
        if (($null -eq $slot) -or (-not [bool](Get-SCValue $slot 'ok' $false))) { return $null }
        return (Get-SCValue $slot 'goal' $null)
    }

    function Get-SCTaskRev { param([string]$TaskId)
        $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $script:scEnv.tasks
        return [long](Get-SCValue $t 'revision' -1)
    }

    function New-SCTask {
        param([string]$TaskId, [string]$GoalId, [long]$Gen, [string]$Risk = 'low', [string]$Objective = '')
        $obj = $Objective
        if ([string]::IsNullOrWhiteSpace($obj)) { $obj = ('s3 obj ' + $TaskId) }
        $c = New-OrchestrationTask -TaskId $TaskId -Objective $obj -TaskType 'implementation' `
            -Risk $Risk -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 's3-base' -ReadScopes @('s3/a.txt') -WriteScopes @('s3/a.txt') `
            -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 `
            -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -TelemetryRoot $script:scEnv.tele
        Assert-SC ([bool]$c.ok) ('[F] kernel task created ' + $TaskId) ([string]$c.error)
        $t1 = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner-1' -ExpectedRevision 1 `
            -ActorIdentitySource 'explicit-cli' -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -TelemetryRoot $script:scEnv.tele
        Assert-SC ([bool]$t1.ok) ('[F] task planning ' + $TaskId) ([string]$t1.error)
        $rev = Get-SCTaskRev -TaskId $TaskId
        $t2 = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'IMPLEMENTING' -Actor 'planner-1' -ExpectedRevision $rev `
            -ActorIdentitySource 'explicit-cli' -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -TelemetryRoot $script:scEnv.tele
        Assert-SC ([bool]$t2.ok) ('[F] task implementing ' + $TaskId) ([string]$t2.error)
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $script:scEnv.goals
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $TaskId -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $script:scEnv.goals -OwnerId 'planner-1' -OwnershipGeneration $Gen
        Assert-SC ([bool]$add.ok) ('[F] task attached ' + $TaskId) ([string]$add.reason)
    }

    function New-SCIntent {
        param([string]$TaskId, [long]$Rev, [string]$Key, [long]$Gen, [string]$Agent = 'coder')
        $ph = Get-NativeDispatchHash32 ('s3-prompt|' + $TaskId + '|' + $Key)
        $slot = New-OrchestrationNativeDispatchIntent -TaskId $TaskId -TaskExpectedRevision $Rev -Agent $Agent -PromptHash $ph `
            -Scope @('s3/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $Key `
            -Owner 'planner-1' -OwnershipGeneration $Gen -BaseRevision 's3-base'
        Assert-SC ([bool]$slot.ok) ('[F] intent built ' + $TaskId) ([string]$slot.reason)
        return (Get-SCValue $slot 'intent' $null)
    }

    function Invoke-SCWalk {
        param($Goal, $Intent, [string]$Agent = 'coder', $Result = $null, [string]$Child = 'ses_s3_child', [string]$Call = 'call_s3_1', [string]$Receipts = '')
        $recRoot = $Receipts
        if ([string]::IsNullOrWhiteSpace($recRoot)) { $recRoot = $script:scEnv.recs }
        $key = ([string](Get-SCValue $Intent 'idempotency_key' '')).Trim().ToLowerInvariant()
        $tid = ([string](Get-SCValue $Intent 'task_id' '')).Trim()
        $prep = Invoke-OrchestrationNativeDispatchPrepare -Intent $Intent -Authorization $Goal.auth -SessionId 'ses_s3_parent' `
            -ReceiptDir $recRoot -GoalStoreDir $script:scEnv.goals -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC ([bool]$prep.ok) ('[F] prepared ' + $tid) ([string]$prep.reason)
        $fp = ([string]$prep.prepared_fingerprint)
        $ref = ([string]$prep.reference)
        $claim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $key -Authorization $Goal.auth -SessionId 'ses_s3_parent' `
            -MessageId 'msg_s3_call' -CallId $Call -CallerAgent 'planner' -TargetAgent $Agent -PreparedFingerprint $fp `
            -ReceiptDir $recRoot -GoalStoreDir $script:scEnv.goals -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC (([bool]$claim.ok) -and ([bool]$claim.claimed)) ('[F] claimed ' + $tid) ([string]$claim.reason)
        $cand = $Result
        if ($null -eq $cand) { $cand = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }
        $settle = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $key -Authorization $Goal.auth -ChildSessionId $Child `
            -SessionId 'ses_s3_parent' -MessageId 'msg_s3_call' -CallId $Call -CallerAgent 'planner' -TargetAgent $Agent `
            -PreparedFingerprint $fp -Reference $ref -TaskId $tid -Result $cand -ReceiptDir $recRoot `
            -GoalStoreDir $script:scEnv.goals -EvidenceStoreDir $script:scEnv.evs -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC (([bool]$settle.ok) -and ([bool]$settle.settled)) ('[F] settled ' + $tid) ([string]$settle.reason)
        return [pscustomobject]@{ key = $key; task_id = $tid; evidence_id = ([string]$settle.evidence_id) }
    }

    function New-SCVerifierJson {
        param([string]$Status = 'verified_pass')
        $okFlag = ($Status -ceq 'verified_pass')
        $o = [ordered]@{
            ok = $okFlag; task_id = 's3-verifier'; status = $Status; reason = 's3 verifier read-back'
            scope = $null; profiles = @()
            evidence = @('criterion:0:artifact-bytes=12;expected-match=True', 'criterion:0:file=s3-a.txt')
            command_classes = @('test')
        }
        return (($o | ConvertTo-Json -Depth 8 -Compress))
    }

    function Invoke-SCToReviewing { param([string]$TaskId)
        $rev = Get-SCTaskRev -TaskId $TaskId
        $v = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'VALIDATING' -Actor 'planner-1' -ExpectedRevision $rev `
            -ActorIdentitySource 'explicit-cli' -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -TelemetryRoot $script:scEnv.tele
        Assert-SC ([bool]$v.ok) ('[F] validating ' + $TaskId) ([string]$v.error)
        $rev = Get-SCTaskRev -TaskId $TaskId
        $r = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'REVIEWING' -Actor 'planner-1' -ExpectedRevision $rev `
            -ActorIdentitySource 'explicit-cli' -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -TelemetryRoot $script:scEnv.tele
        Assert-SC ([bool]$r.ok) ('[F] reviewing ' + $TaskId) ([string]$r.error)
    }

    function Set-SCVerification { param([string]$TaskId, [string]$Status = 'verified_pass')
        $rev = Get-SCTaskRev -TaskId $TaskId
        $s = Set-OrchestrationTaskVerification -TaskId $TaskId -VerifierEvidenceJson (New-SCVerifierJson -Status $Status) `
            -ExpectedRevision ([int]$rev) -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC ([bool]$s.ok) ('[F] verification ' + $TaskId + ' ' + $Status) ([string]$s.error)
    }

    function Set-SCReview { param([string]$TaskId, [string]$Kind = 'reviewer', [string]$Status = 'approved', [string]$By = 'reviewer-1')
        $rev = Get-SCTaskRev -TaskId $TaskId
        $s = Set-OrchestrationTaskReview -TaskId $TaskId -Kind $Kind -Status $Status -By $By `
            -ExpectedRevision ([int]$rev) -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC ([bool]$s.ok) ('[F] review ' + $TaskId + ' ' + $Kind + '/' + $Status) ([string]$s.error)
    }

    function Invoke-SCComplete { param([string]$TaskId)
        $rev = Get-SCTaskRev -TaskId $TaskId
        $d = Complete-OrchestrationTask -TaskId $TaskId -Actor 'planner-1' -ExpectedRevision ([int]$rev) `
            -ResidualRisks @('s3-fixture-residual') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' `
            -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -TelemetryRoot $script:scEnv.tele
        Assert-SC ([bool]$d.ok) ('[F] done ' + $TaskId) ([string]$d.error)
    }

    function Update-SCProgress { param([string]$GoalId, [long]$Gen, [long]$Satisfied, [long]$Total)
        $live = Get-SCLiveGoal -GoalId $GoalId
        $u = Update-OrchestrationGoal -GoalId $GoalId -ExpectedRevision ([long]$live['revision']) `
            -Fields @{ progress = @{ satisfied = $Satisfied; total = $Total } } -StoreDir $script:scEnv.goals -OwnerId 'planner-1' -OwnershipGeneration $Gen
        Assert-SC ([bool]$u.ok) ('[F] progress ' + $GoalId) ([string]$u.reason)
    }

    function Get-SCReceipt { param([string]$GoalId, [string]$Key, [string]$Receipts = '')
        $rr = $Receipts
        if ([string]::IsNullOrWhiteSpace($rr)) { $rr = $script:scEnv.recs }
        $sub = Get-NDGoalReceiptDir -RootDir $rr -GoalId $GoalId
        if ([string]::IsNullOrWhiteSpace($sub)) { return $null }
        $p = Join-Path $sub ($Key + '.json')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))) } catch { return $null }
    }

    function Get-SCAdvanceRecord { param([string]$GoalId, [string]$Key)
        $st = Get-NDAdvanceDir -RootDir $script:scEnv.recs -GoalId $GoalId
        if (-not [bool](Get-SCValue $st 'ok' $false)) { return $null }
        $p = Join-Path ([string](Get-SCValue $st 'dir' '')) ($Key + '.advance.json')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))) } catch { return $null }
    }

    function Get-SCAdvancePath { param([string]$GoalId, [string]$Key)
        $st = Get-NDAdvanceDir -RootDir $script:scEnv.recs -GoalId $GoalId
        if (-not [bool](Get-SCValue $st 'ok' $false)) { return '' }
        return (Join-Path ([string](Get-SCValue $st 'dir' '')) ($Key + '.advance.json'))
    }

    function New-SCStatus { param([bool]$Completed = $false, [bool]$Authorized = $true, [string]$BlockerKind = '', [string[]]$Remaining = @('s3-work'))
        return @{
            objective_completed = [bool]$Completed; remaining_work = [string[]]$Remaining
            authorized = [bool]$Authorized; blocker_kind = ([string]$BlockerKind)
            progress_possible = $true; strategy_change = $false; context_degraded = $false
            last_failure = $null; terminal_blocker = $null; consecutive_no_progress = [long]0
        }
    }

    $script:scOrigMove = (Get-Item -Path 'function:Get-OrchestrationNextMove').ScriptBlock
    function Set-SCStubMove { param([string]$Move, [string]$Reason, [string]$Stop = '')
        $m = $Move; $r = $Reason; $s = $Stop
        Set-Item -Path 'function:Get-OrchestrationNextMove' -Value ({ param($Status) return [pscustomobject]@{ move = $m; reason = $r; stop_reason = $s; remaining_count = 1 } }.GetNewClosure())
    }
    function Restore-SCStubMove { Set-Item -Path 'function:Get-OrchestrationNextMove' -Value $script:scOrigMove }

    function Invoke-SCContinuation {
        param($Goal, [string]$Key, $NextIntent = $null, [string]$CkptDir = '', [string]$ControllerPath = '', [string]$Receipts = '')
        $cd = $CkptDir
        if ([string]::IsNullOrWhiteSpace($cd)) { $cd = $script:scEnv.ckpts }
        $rr = $Receipts
        if ([string]::IsNullOrWhiteSpace($rr)) { $rr = $script:scEnv.recs }
        if ($null -eq $NextIntent) {
            return (Invoke-OrchestrationSettledContinuation -GoalId $Goal.goal_id -SettledKey $Key -Authorization $Goal.auth `
                -SessionId 'ses_s3_parent' -CheckpointDir $cd -GoalStoreDir $script:scEnv.goals -EvidenceStoreDir $script:scEnv.evs `
                -ReceiptDir $rr -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -ControllerPath $ControllerPath)
        }
        return (Invoke-OrchestrationSettledContinuation -GoalId $Goal.goal_id -SettledKey $Key -Authorization $Goal.auth `
            -SessionId 'ses_s3_parent' -CheckpointDir $cd -GoalStoreDir $script:scEnv.goals -EvidenceStoreDir $script:scEnv.evs `
            -ReceiptDir $rr -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -ControllerPath $ControllerPath -NextIntent $NextIntent)
    }

    try {
        # ---------- 1. CONTINUE feliz ----------
        $ids1 = New-SCIds -Tag 'cont'
        $g1 = New-SCGoal -GoalId $ids1.goal
        New-SCTask -TaskId $ids1.task -GoalId $ids1.goal -Gen $g1.gen -Risk 'low'
        New-SCTask -TaskId $ids1.next -GoalId $ids1.goal -Gen $g1.gen -Risk 'low'
        $key1 = Get-NativeDispatchHash32 ('s3-settled-' + $ids1.task)
        $intent1 = New-SCIntent -TaskId $ids1.task -Rev (Get-SCTaskRev -TaskId $ids1.task) -Key $key1 -Gen $g1.gen
        $walk1 = Invoke-SCWalk -Goal $g1 -Intent $intent1 -Call 'call_s3_c1'
        Invoke-SCToReviewing -TaskId $ids1.task
        Set-SCVerification -TaskId $ids1.task
        Set-SCReview -TaskId $ids1.task
        Invoke-SCComplete -TaskId $ids1.task
        $nextKey1 = Get-NativeDispatchHash32 ('s3-next-' + $ids1.next)
        $intentNext1 = New-SCIntent -TaskId $ids1.next -Rev (Get-SCTaskRev -TaskId $ids1.next) -Key $nextKey1 -Gen $g1.gen
        $c1 = Invoke-SCContinuation -Goal $g1 -Key $key1 -NextIntent $intentNext1
        Assert-SC (([bool]$c1.ok) -and ([string]$c1.action -ceq 'prepared') -and ([bool]$c1.prepared)) '[S1] CONTINUE prepares exactly one successor' ('action=' + [string]$c1.action + ' reason=' + [string]$c1.reason)
        Assert-SC (([string]$c1.reason -ceq 'prepared') -and ([string]$c1.move -ceq 'CONTINUE')) '[S1] envelope carries the decided move' ('move=' + [string]$c1.move)
        Assert-SC (([string]$c1.next_idempotency_key -ceq $nextKey1) -and (-not [string]::IsNullOrWhiteSpace([string]$c1.next_reference))) '[S1] the next key is the PREPAREd one' ('key=' + [string]$c1.next_idempotency_key)
        Assert-SC (([int]$c1.executor_calls -eq 0)) '[S1] no worker ever executed' ('calls=' + [string]$c1.executor_calls)
        Assert-SC (([string]$c1.evidence_id -ceq $walk1.evidence_id)) '[S1] envelope carries the settled evidence id' ([string]$c1.evidence_id)
        $recNext1 = Get-SCReceipt -GoalId $ids1.goal -Key $nextKey1
        Assert-SC (($null -ne $recNext1) -and (([string]$recNext1.phase -ceq 'prepared'))) '[S1] the successor receipt exists in prepared phase' ''
        $advRec1 = Get-SCAdvanceRecord -GoalId $ids1.goal -Key $key1
        Assert-SC (($null -ne $advRec1) -and ([string]$advRec1.move -ceq 'CONTINUE') -and ([bool]$advRec1.prepared) -and ([string]$advRec1.next_idempotency_key -ceq $nextKey1)) '[S1] the advance decision is persisted' ''
        Assert-SC (([bool]$c1.checkpoint_ok) -and (-not [string]::IsNullOrWhiteSpace([string]$c1.checkpoint_id))) '[S1] checkpoint persisted' ([string]$c1.checkpoint_id)
        $side1 = Join-Path $script:scEnv.ckpts ([string]$c1.checkpoint_id + '.settled-continuation.json')
        Assert-SC (Test-Path -LiteralPath $side1 -PathType Leaf) '[S1] the correlation sidecar exists' ''
        $sideRec1 = ConvertFrom-Json ([IO.File]::ReadAllText($side1, [Text.Encoding]::UTF8))
        Assert-SC ((([string]$sideRec1.settled_key -ceq $key1) -and ([string]$sideRec1.next_idempotency_key -ceq $nextKey1) -and ([bool]$sideRec1.prepared) -and (-not [string]::IsNullOrWhiteSpace([string]$sideRec1.advance_record_ref)))) '[S1] the sidecar correlates settled key + advance ref + successor' ''
        $stillDone1 = Get-OrchestrationTask -TaskId $ids1.task -TasksDir $script:scEnv.tasks
        Assert-SC (([string](Get-SCValue $stillDone1 'state' '') -ceq 'DONE')) '[S1] the settled task stays DONE' ''

        # ---------- 2. RETRY corretivo ----------
        $ids2 = New-SCIds -Tag 'retry'
        $g2 = New-SCGoal -GoalId $ids2.goal
        New-SCTask -TaskId $ids2.task -GoalId $ids2.goal -Gen $g2.gen -Risk 'medium'
        New-SCTask -TaskId $ids2.next -GoalId $ids2.goal -Gen $g2.gen -Risk 'medium'
        $key2 = Get-NativeDispatchHash32 ('s3-settled-' + $ids2.task)
        $intent2 = New-SCIntent -TaskId $ids2.task -Rev (Get-SCTaskRev -TaskId $ids2.task) -Key $key2 -Gen $g2.gen
        $null = Invoke-SCWalk -Goal $g2 -Intent $intent2 -Call 'call_s3_r1' -Result @{ status = 'failed'; claimed_evidence = @('criterion:0') }
        $nextKey2 = Get-NativeDispatchHash32 ('s3-next-' + $ids2.next)
        $intentNext2 = New-SCIntent -TaskId $ids2.next -Rev (Get-SCTaskRev -TaskId $ids2.next) -Key $nextKey2 -Gen $g2.gen
        $c2 = Invoke-SCContinuation -Goal $g2 -Key $key2 -NextIntent $intentNext2
        Assert-SC (([bool]$c2.ok) -and ([string]$c2.action -ceq 'prepared') -and ([bool]$c2.prepared) -and ([string]$c2.move -ceq 'RETRY')) '[S2] RETRY prepares the correction' ('action=' + [string]$c2.action + ' move=' + [string]$c2.move + ' reason=' + [string]$c2.reason)
        Assert-SC (([string]$c2.next_idempotency_key -ceq $nextKey2) -and (-not [string]::IsNullOrWhiteSpace([string]$c2.next_reference))) '[S2] the correction key is the PREPAREd one' ('key=' + [string]$c2.next_idempotency_key)
        Assert-SC (([int]$c2.executor_calls -eq 0)) '[S2] no worker ever executed' ('calls=' + [string]$c2.executor_calls)
        $failedTask2 = Get-OrchestrationTask -TaskId $ids2.task -TasksDir $script:scEnv.tasks
        Assert-SC (([string](Get-SCValue $failedTask2 'state' '') -cne 'DONE')) '[S2] the failed attempt never becomes DONE' ([string](Get-SCValue $failedTask2 'state' ''))
        $advRec2 = Get-SCAdvanceRecord -GoalId $ids2.goal -Key $key2
        Assert-SC (($null -ne $advRec2) -and ([string]$advRec2.move -ceq 'RETRY') -and ([bool]$advRec2.prepared)) '[S2] the retry decision is persisted' ''
        Assert-SC (([bool]$c2.checkpoint_ok)) '[S2] checkpoint persisted' ([string]$c2.checkpoint_id)

        # ---------- 3. REPLAN ----------
        $ids3 = New-SCIds -Tag 'replan'
        $g3 = New-SCGoal -GoalId $ids3.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids3.task -GoalId $ids3.goal -Gen $g3.gen -Risk 'low'
        $key3 = Get-NativeDispatchHash32 ('s3-settled-' + $ids3.task)
        $intent3 = New-SCIntent -TaskId $ids3.task -Rev (Get-SCTaskRev -TaskId $ids3.task) -Key $key3 -Gen $g3.gen
        $null = Invoke-SCWalk -Goal $g3 -Intent $intent3 -Call 'call_s3_p1'
        Set-SCStubMove -Move 'REPLAN' -Reason 'strategy-change-test'
        try { $c3 = Invoke-SCContinuation -Goal $g3 -Key $key3 }
        finally { Restore-SCStubMove }
        Assert-SC (([bool]$c3.ok) -and ([string]$c3.action -ceq 'replan_required') -and (-not [bool]$c3.prepared)) '[S3] REPLAN persists the decision without preparing' ('action=' + [string]$c3.action + ' reason=' + [string]$c3.reason)
        Assert-SC ([string]::IsNullOrWhiteSpace([string]$c3.next_idempotency_key)) '[S3] no successor key is minted on REPLAN' ([string]$c3.next_idempotency_key)
        Assert-SC (([int]$c3.executor_calls -eq 0)) '[S3] no worker ever executed' ('calls=' + [string]$c3.executor_calls)
        $advRec3 = Get-SCAdvanceRecord -GoalId $ids3.goal -Key $key3
        Assert-SC (($null -ne $advRec3) -and ([string]$advRec3.move -ceq 'REPLAN') -and (-not [bool]$advRec3.prepared)) '[S3] the replan decision is marked in the advance record' ''
        Assert-SC (([bool]$c3.checkpoint_ok) -and (-not [string]::IsNullOrWhiteSpace([string]$c3.advance_record_ref))) '[S3] checkpoint references the advance record' ([string]$c3.checkpoint_id)
        $side3 = Join-Path $script:scEnv.ckpts ([string]$c3.checkpoint_id + '.settled-continuation.json')
        $sideRec3 = ConvertFrom-Json ([IO.File]::ReadAllText($side3, [Text.Encoding]::UTF8))
        Assert-SC ((([string]$sideRec3.settled_key -ceq $key3) -and ([string]$sideRec3.move -ceq 'REPLAN') -and (-not [bool]$sideRec3.prepared))) '[S3] the sidecar correlates the replan' ''

        # ---------- 4. BLOCKED ----------
        $ids4 = New-SCIds -Tag 'blocked'
        $g4 = New-SCGoal -GoalId $ids4.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids4.task -GoalId $ids4.goal -Gen $g4.gen -Risk 'low'
        $key4 = Get-NativeDispatchHash32 ('s3-settled-' + $ids4.task)
        $intent4 = New-SCIntent -TaskId $ids4.task -Rev (Get-SCTaskRev -TaskId $ids4.task) -Key $key4 -Gen $g4.gen
        $null = Invoke-SCWalk -Goal $g4 -Intent $intent4 -Call 'call_s3_b1'
        $revBefore4 = [long]((Get-SCLiveGoal -GoalId $ids4.goal)['revision'])
        Set-SCStubMove -Move 'COMPLETE' -Reason 'unauthorized-authority-test' -Stop 'HUMAN_AUTHORITY_REQUIRED'
        try { $c4 = Invoke-SCContinuation -Goal $g4 -Key $key4 }
        finally { Restore-SCStubMove }
        Assert-SC (([bool]$c4.ok) -and ([string]$c4.action -ceq 'blocked') -and (-not [bool]$c4.prepared)) '[S4] policy stop blocks without preparing' ('action=' + [string]$c4.action + ' reason=' + [string]$c4.reason)
        Assert-SC (([string]$c4.reason -ceq 'stop:HUMAN_AUTHORITY_REQUIRED')) '[S4] the stop reason is stable' ([string]$c4.reason)
        Assert-SC (([int]$c4.executor_calls -eq 0)) '[S4] no worker ever executed' ('calls=' + [string]$c4.executor_calls)
        $liveAfter4 = Get-SCLiveGoal -GoalId $ids4.goal
        Assert-SC ((([string]$liveAfter4['state'] -ceq 'ACTIVE') -and ([long]$liveAfter4['revision'] -eq $revBefore4))) '[S4] the goal is not mutated' ('state=' + [string]$liveAfter4['state'])
        $advRec4 = Get-SCAdvanceRecord -GoalId $ids4.goal -Key $key4
        Assert-SC (($null -ne $advRec4) -and (-not [bool]$advRec4.prepared)) '[S4] the blocked advance prepared nothing' ''

        # ---------- 5. COMPLETE valido ----------
        $ids5 = New-SCIds -Tag 'complete'
        $g5 = New-SCGoal -GoalId $ids5.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids5.task -GoalId $ids5.goal -Gen $g5.gen -Risk 'low'
        $key5 = Get-NativeDispatchHash32 ('s3-settled-' + $ids5.task)
        $intent5 = New-SCIntent -TaskId $ids5.task -Rev (Get-SCTaskRev -TaskId $ids5.task) -Key $key5 -Gen $g5.gen
        $null = Invoke-SCWalk -Goal $g5 -Intent $intent5 -Call 'call_s3_o1'
        Invoke-SCToReviewing -TaskId $ids5.task
        Set-SCVerification -TaskId $ids5.task
        Set-SCReview -TaskId $ids5.task
        Invoke-SCComplete -TaskId $ids5.task
        Update-SCProgress -GoalId $ids5.goal -Gen $g5.gen -Satisfied 1 -Total 1
        $revBefore5 = [long]((Get-SCLiveGoal -GoalId $ids5.goal)['revision'])
        $c5 = Invoke-SCContinuation -Goal $g5 -Key $key5
        Assert-SC (([bool]$c5.ok) -and ([string]$c5.action -ceq 'completed')) '[S5] verified criteria complete via persisted CAS' ('action=' + [string]$c5.action + ' reason=' + [string]$c5.reason)
        Assert-SC (([string]$c5.reason -ceq 'objective-completed-verified') -and (-not [bool]$c5.prepared)) '[S5] completion carries no prepare' ([string]$c5.reason)
        Assert-SC (([int]$c5.executor_calls -eq 0)) '[S5] no worker ever executed' ('calls=' + [string]$c5.executor_calls)
        $liveAfter5 = Get-SCLiveGoal -GoalId $ids5.goal
        Assert-SC ((([string]$liveAfter5['state'] -ceq 'COMPLETED') -and ([long]$liveAfter5['revision'] -eq ($revBefore5 + 1)))) '[S5] the store shows COMPLETED with CAS revision+1' ([string]$liveAfter5['state'])
        $advRec5 = Get-SCAdvanceRecord -GoalId $ids5.goal -Key $key5
        Assert-SC (($null -ne $advRec5) -and ([string]$advRec5.move -ceq 'COMPLETE') -and (-not [bool]$advRec5.prepared)) '[S5] the complete decision is recorded without preparing' ''
        Assert-SC (([bool]$c5.checkpoint_ok)) '[S5] checkpoint persisted' ([string]$c5.checkpoint_id)

        # ---------- 6. COMPLETE recusado ----------
        $ids6a = New-SCIds -Tag 'nounproven'
        $g6a = New-SCGoal -GoalId $ids6a.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids6a.task -GoalId $ids6a.goal -Gen $g6a.gen -Risk 'low'
        $key6a = Get-NativeDispatchHash32 ('s3-settled-' + $ids6a.task)
        $intent6a = New-SCIntent -TaskId $ids6a.task -Rev (Get-SCTaskRev -TaskId $ids6a.task) -Key $key6a -Gen $g6a.gen
        $null = Invoke-SCWalk -Goal $g6a -Intent $intent6a -Call 'call_s3_u1'
        Invoke-SCToReviewing -TaskId $ids6a.task
        Set-SCVerification -TaskId $ids6a.task
        Set-SCReview -TaskId $ids6a.task
        Invoke-SCComplete -TaskId $ids6a.task
        $revBefore6a = [long]((Get-SCLiveGoal -GoalId $ids6a.goal)['revision'])
        Set-SCStubMove -Move 'COMPLETE' -Reason 'stub-objective-completed' -Stop 'OBJECTIVE_COMPLETED'
        try { $c6a = Invoke-SCContinuation -Goal $g6a -Key $key6a }
        finally { Restore-SCStubMove }
        Assert-SC (((-not [bool]$c6a.ok) -and ([string]$c6a.action -ceq 'blocked') -and ([string]$c6a.reason -ceq 'continuation-completion-unproven'))) '[S6a] task DONE without global criteria never completes' ('reason=' + [string]$c6a.reason + ' cause=' + [string]$c6a.cause_reason)
        Assert-SC (((-not [bool]$c6a.prepared) -and ([string]::IsNullOrWhiteSpace([string]$c6a.advance_record_ref)))) '[S6a] the refusal happens before ADVANCE' ([string]$c6a.advance_record_ref)
        $liveAfter6a = Get-SCLiveGoal -GoalId $ids6a.goal
        Assert-SC ((([string]$liveAfter6a['state'] -ceq 'ACTIVE') -and ([long]$liveAfter6a['revision'] -eq $revBefore6a))) '[S6a] the goal stays ACTIVE untouched' ([string]$liveAfter6a['state'])
        $ids6b = New-SCIds -Tag 'polstop'
        $g6b = New-SCGoal -GoalId $ids6b.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids6b.task -GoalId $ids6b.goal -Gen $g6b.gen -Risk 'low'
        $key6b = Get-NativeDispatchHash32 ('s3-settled-' + $ids6b.task)
        $intent6b = New-SCIntent -TaskId $ids6b.task -Rev (Get-SCTaskRev -TaskId $ids6b.task) -Key $key6b -Gen $g6b.gen
        $null = Invoke-SCWalk -Goal $g6b -Intent $intent6b -Call 'call_s3_u2'
        Invoke-SCToReviewing -TaskId $ids6b.task
        Set-SCVerification -TaskId $ids6b.task
        Set-SCReview -TaskId $ids6b.task
        Invoke-SCComplete -TaskId $ids6b.task
        Update-SCProgress -GoalId $ids6b.goal -Gen $g6b.gen -Satisfied 1 -Total 1
        $revBefore6b = [long]((Get-SCLiveGoal -GoalId $ids6b.goal)['revision'])
        Set-SCStubMove -Move 'COMPLETE' -Reason 'stub-policy' -Stop 'POLICY_BLOCKED'
        try { $c6b = Invoke-SCContinuation -Goal $g6b -Key $key6b }
        finally { Restore-SCStubMove }
        Assert-SC (([string]$c6b.action -ceq 'blocked') -and ([string]$c6b.reason -ceq 'stop:POLICY_BLOCKED') -and (-not [bool]$c6b.prepared)) '[S6b] a policy stop never completes the goal' ('action=' + [string]$c6b.action + ' reason=' + [string]$c6b.reason)
        $liveAfter6b = Get-SCLiveGoal -GoalId $ids6b.goal
        Assert-SC ((([string]$liveAfter6b['state'] -ceq 'ACTIVE') -and ([long]$liveAfter6b['revision'] -eq $revBefore6b))) '[S6b] the goal stays ACTIVE untouched' ([string]$liveAfter6b['state'])

        # ---------- 7. review ausente, stale e negativo ----------
        $ids7a = New-SCIds -Tag 'noreview'
        $g7a = New-SCGoal -GoalId $ids7a.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids7a.task -GoalId $ids7a.goal -Gen $g7a.gen -Risk 'low'
        New-SCTask -TaskId $ids7a.next -GoalId $ids7a.goal -Gen $g7a.gen -Risk 'low'
        $key7a = Get-NativeDispatchHash32 ('s3-settled-' + $ids7a.task)
        $intent7a = New-SCIntent -TaskId $ids7a.task -Rev (Get-SCTaskRev -TaskId $ids7a.task) -Key $key7a -Gen $g7a.gen
        $null = Invoke-SCWalk -Goal $g7a -Intent $intent7a -Call 'call_s3_v1'
        Set-SCVerification -TaskId $ids7a.task
        $nextKey7a = Get-NativeDispatchHash32 ('s3-next-' + $ids7a.next)
        $intentNext7a = New-SCIntent -TaskId $ids7a.next -Rev (Get-SCTaskRev -TaskId $ids7a.next) -Key $nextKey7a -Gen $g7a.gen
        $c7a = Invoke-SCContinuation -Goal $g7a -Key $key7a -NextIntent $intentNext7a
        Assert-SC (((-not [bool]$c7a.ok) -and ([string]$c7a.reason -ceq 'continuation-review-required') -and ([string]$c7a.cause_reason -ceq 'review-missing') -and (-not [bool]$c7a.prepared))) '[S7a] missing review blocks without preparing' ('reason=' + [string]$c7a.reason)
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids7a.goal -Key $nextKey7a)) '[S7a] no successor was prepared' ''
        $ids7b = New-SCIds -Tag 'stalerev'
        $g7b = New-SCGoal -GoalId $ids7b.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids7b.task -GoalId $ids7b.goal -Gen $g7b.gen -Risk 'low'
        New-SCTask -TaskId $ids7b.next -GoalId $ids7b.goal -Gen $g7b.gen -Risk 'low'
        $key7b1 = Get-NativeDispatchHash32 ('s3-settled-' + $ids7b.task + '-w1')
        $intent7b1 = New-SCIntent -TaskId $ids7b.task -Rev (Get-SCTaskRev -TaskId $ids7b.task) -Key $key7b1 -Gen $g7b.gen
        $null = Invoke-SCWalk -Goal $g7b -Intent $intent7b1 -Call 'call_s3_v2' -Child 'ses_s3_child_v2'
        Set-SCReview -TaskId $ids7b.task
        $key7b2 = Get-NativeDispatchHash32 ('s3-settled-' + $ids7b.task + '-w2')
        $intent7b2 = New-SCIntent -TaskId $ids7b.task -Rev (Get-SCTaskRev -TaskId $ids7b.task) -Key $key7b2 -Gen $g7b.gen
        $null = Invoke-SCWalk -Goal $g7b -Intent $intent7b2 -Call 'call_s3_v3' -Child 'ses_s3_child_v3'
        Set-SCVerification -TaskId $ids7b.task
        $nextKey7b = Get-NativeDispatchHash32 ('s3-next-' + $ids7b.next)
        $intentNext7b = New-SCIntent -TaskId $ids7b.next -Rev (Get-SCTaskRev -TaskId $ids7b.next) -Key $nextKey7b -Gen $g7b.gen
        $c7b = Invoke-SCContinuation -Goal $g7b -Key $key7b2 -NextIntent $intentNext7b
        Assert-SC (((-not [bool]$c7b.ok) -and ([string]$c7b.reason -ceq 'continuation-review-required') -and ([string]$c7b.cause_reason -ceq 'review-stale') -and (-not [bool]$c7b.prepared))) '[S7b] stale review blocks without preparing' ('reason=' + [string]$c7b.reason + ' cause=' + [string]$c7b.cause_reason)
        $ids7c = New-SCIds -Tag 'negreview'
        $g7c = New-SCGoal -GoalId $ids7c.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids7c.task -GoalId $ids7c.goal -Gen $g7c.gen -Risk 'low'
        New-SCTask -TaskId $ids7c.next -GoalId $ids7c.goal -Gen $g7c.gen -Risk 'low'
        $key7c = Get-NativeDispatchHash32 ('s3-settled-' + $ids7c.task)
        $intent7c = New-SCIntent -TaskId $ids7c.task -Rev (Get-SCTaskRev -TaskId $ids7c.task) -Key $key7c -Gen $g7c.gen
        $null = Invoke-SCWalk -Goal $g7c -Intent $intent7c -Call 'call_s3_v4'
        Set-SCVerification -TaskId $ids7c.task
        Set-SCReview -TaskId $ids7c.task -Status 'changes_required'
        $nextKey7c = Get-NativeDispatchHash32 ('s3-next-' + $ids7c.next)
        $intentNext7c = New-SCIntent -TaskId $ids7c.next -Rev (Get-SCTaskRev -TaskId $ids7c.next) -Key $nextKey7c -Gen $g7c.gen
        $c7c = Invoke-SCContinuation -Goal $g7c -Key $key7c -NextIntent $intentNext7c
        Assert-SC (((-not [bool]$c7c.ok) -and ([string]$c7c.reason -ceq 'continuation-changes-required') -and (-not [bool]$c7c.prepared))) '[S7c] negative review blocks without preparing' ('reason=' + [string]$c7c.reason + ' cause=' + [string]$c7c.cause_reason)

        # ---------- 8. L3 sem security, manual e profile desconhecido ----------
        $ids8a = New-SCIds -Tag 'l3nosec'
        $g8a = New-SCGoal -GoalId $ids8a.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids8a.task -GoalId $ids8a.goal -Gen $g8a.gen -Risk 'high'
        New-SCTask -TaskId $ids8a.next -GoalId $ids8a.goal -Gen $g8a.gen -Risk 'high'
        $key8a = Get-NativeDispatchHash32 ('s3-settled-' + $ids8a.task)
        $intent8a = New-SCIntent -TaskId $ids8a.task -Rev (Get-SCTaskRev -TaskId $ids8a.task) -Key $key8a -Gen $g8a.gen
        $null = Invoke-SCWalk -Goal $g8a -Intent $intent8a -Call 'call_s3_w1'
        Invoke-SCToReviewing -TaskId $ids8a.task
        Set-SCVerification -TaskId $ids8a.task
        Set-SCReview -TaskId $ids8a.task
        $nextKey8a = Get-NativeDispatchHash32 ('s3-next-' + $ids8a.next)
        $intentNext8a = New-SCIntent -TaskId $ids8a.next -Rev (Get-SCTaskRev -TaskId $ids8a.next) -Key $nextKey8a -Gen $g8a.gen
        $c8a = Invoke-SCContinuation -Goal $g8a -Key $key8a -NextIntent $intentNext8a
        Assert-SC (((-not [bool]$c8a.ok) -and ([string]$c8a.reason -ceq 'continuation-review-required') -and ([string]$c8a.cause_reason -ceq 'security-review-missing') -and (-not [bool]$c8a.prepared))) '[S8a] L3 without security review blocks' ('reason=' + [string]$c8a.reason + ' cause=' + [string]$c8a.cause_reason)
        Set-SCReview -TaskId $ids8a.task -Kind 'security' -Status 'approved' -By 'security-1'
        Invoke-SCComplete -TaskId $ids8a.task
        $c8a2 = Invoke-SCContinuation -Goal $g8a -Key $key8a -NextIntent $intentNext8a
        Assert-SC (([bool]$c8a2.ok) -and ([string]$c8a2.action -ceq 'prepared') -and ([bool]$c8a2.prepared) -and ([string]$c8a2.next_idempotency_key -ceq $nextKey8a)) '[S8a] L3 with security review prepares' ('action=' + [string]$c8a2.action + ' reason=' + [string]$c8a2.reason)
        $ids8b = New-SCIds -Tag 'unknown'
        $g8b = New-SCGoal -GoalId $ids8b.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids8b.task -GoalId $ids8b.goal -Gen $g8b.gen -Risk 'unknown'
        New-SCTask -TaskId $ids8b.next -GoalId $ids8b.goal -Gen $g8b.gen -Risk 'unknown'
        $key8b = Get-NativeDispatchHash32 ('s3-settled-' + $ids8b.task)
        $intent8b = New-SCIntent -TaskId $ids8b.task -Rev (Get-SCTaskRev -TaskId $ids8b.task) -Key $key8b -Gen $g8b.gen
        $null = Invoke-SCWalk -Goal $g8b -Intent $intent8b -Call 'call_s3_w2'
        $nextKey8b = Get-NativeDispatchHash32 ('s3-next-' + $ids8b.next)
        $intentNext8b = New-SCIntent -TaskId $ids8b.next -Rev (Get-SCTaskRev -TaskId $ids8b.next) -Key $nextKey8b -Gen $g8b.gen
        $c8b = Invoke-SCContinuation -Goal $g8b -Key $key8b -NextIntent $intentNext8b
        Assert-SC (((-not [bool]$c8b.ok) -and ([string]$c8b.reason -ceq 'continuation-policy-unavailable') -and (-not [bool]$c8b.prepared))) '[S8b] unknown risk fails closed' ('reason=' + [string]$c8b.reason + ' cause=' + [string]$c8b.cause_reason)
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids8b.goal -Key $nextKey8b)) '[S8b] no successor was prepared' ''
        $ids8c = New-SCIds -Tag 'manual'
        $g8c = New-SCGoal -GoalId $ids8c.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids8c.task -GoalId $ids8c.goal -Gen $g8c.gen -Risk 'low'
        New-SCTask -TaskId $ids8c.next -GoalId $ids8c.goal -Gen $g8c.gen -Risk 'low'
        $key8c = Get-NativeDispatchHash32 ('s3-settled-' + $ids8c.task)
        $intent8c = New-SCIntent -TaskId $ids8c.task -Rev (Get-SCTaskRev -TaskId $ids8c.task) -Key $key8c -Gen $g8c.gen
        $null = Invoke-SCWalk -Goal $g8c -Intent $intent8c -Call 'call_s3_w3'
        Set-SCVerification -TaskId $ids8c.task -Status 'manual_verification_required'
        $nextKey8c = Get-NativeDispatchHash32 ('s3-next-' + $ids8c.next)
        $intentNext8c = New-SCIntent -TaskId $ids8c.next -Rev (Get-SCTaskRev -TaskId $ids8c.next) -Key $nextKey8c -Gen $g8c.gen
        $c8c = Invoke-SCContinuation -Goal $g8c -Key $key8c -NextIntent $intentNext8c
        Assert-SC (((-not [bool]$c8c.ok) -and ([string]$c8c.reason -ceq 'continuation-verification-required') -and (-not [bool]$c8c.prepared))) '[S8c] manual verification blocks without preparing' ('reason=' + [string]$c8c.reason + ' cause=' + [string]$c8c.cause_reason)

        # ---------- 9. replay e recuperacao ----------
        $ids9a = New-SCIds -Tag 'replay'
        $g9a = New-SCGoal -GoalId $ids9a.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids9a.task -GoalId $ids9a.goal -Gen $g9a.gen -Risk 'low'
        New-SCTask -TaskId $ids9a.next -GoalId $ids9a.goal -Gen $g9a.gen -Risk 'low'
        $key9a = Get-NativeDispatchHash32 ('s3-settled-' + $ids9a.task)
        $intent9a = New-SCIntent -TaskId $ids9a.task -Rev (Get-SCTaskRev -TaskId $ids9a.task) -Key $key9a -Gen $g9a.gen
        $null = Invoke-SCWalk -Goal $g9a -Intent $intent9a -Call 'call_s3_e1'
        Invoke-SCToReviewing -TaskId $ids9a.task
        Set-SCVerification -TaskId $ids9a.task
        Set-SCReview -TaskId $ids9a.task
        Invoke-SCComplete -TaskId $ids9a.task
        $nextKey9a = Get-NativeDispatchHash32 ('s3-next-' + $ids9a.next)
        $intentNext9a = New-SCIntent -TaskId $ids9a.next -Rev (Get-SCTaskRev -TaskId $ids9a.next) -Key $nextKey9a -Gen $g9a.gen
        $c9a1 = Invoke-SCContinuation -Goal $g9a -Key $key9a -NextIntent $intentNext9a
        Assert-SC (([bool]$c9a1.ok) -and ([bool]$c9a1.prepared)) '[S9a] first continuation prepares' ([string]$c9a1.reason)
        $c9a2 = Invoke-SCContinuation -Goal $g9a -Key $key9a -NextIntent $intentNext9a
        Assert-SC (([bool]$c9a2.ok) -and ([string]$c9a2.action -ceq 'prepared') -and ([bool]$c9a2.prepared) -and ([string]$c9a2.next_idempotency_key -ceq $nextKey9a) -and ([string]$c9a2.next_reference -ceq [string]$c9a1.next_reference)) '[S9a] replay returns the same successor without re-preparing' ('key=' + [string]$c9a2.next_idempotency_key)
        Assert-SC (([int]$c9a2.executor_calls -eq 0)) '[S9a] replay executes nothing' ('calls=' + [string]$c9a2.executor_calls)
        $ids9b = New-SCIds -Tag 'pending'
        $g9b = New-SCGoal -GoalId $ids9b.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids9b.task -GoalId $ids9b.goal -Gen $g9b.gen -Risk 'low'
        New-SCTask -TaskId $ids9b.next -GoalId $ids9b.goal -Gen $g9b.gen -Risk 'low'
        $key9b = Get-NativeDispatchHash32 ('s3-settled-' + $ids9b.task)
        $intent9b = New-SCIntent -TaskId $ids9b.task -Rev (Get-SCTaskRev -TaskId $ids9b.task) -Key $key9b -Gen $g9b.gen
        $null = Invoke-SCWalk -Goal $g9b -Intent $intent9b -Call 'call_s3_e2'
        $nextKey9b = Get-NativeDispatchHash32 ('s3-next-' + $ids9b.next)
        $intentNext9b = New-SCIntent -TaskId $ids9b.next -Rev (Get-SCTaskRev -TaskId $ids9b.next) -Key $nextKey9b -Gen $g9b.gen
        $advDir9b = Get-NDAdvanceDir -RootDir $script:scEnv.recs -GoalId $ids9b.goal
        $pending9b = [ordered]@{
            schema_version = 1; ok = $true; reason = ''; goal_id = $ids9b.goal; settled_key = $key9b
            move = 'CONTINUE'; move_reason = 'crashed-before-prepare'; stop_reason = ''; prepared = $false
            next_idempotency_key = $nextKey9b; next_reference = ''; next_task_id = ''; next_agent = ''
            prepare_reason = ''; goal_state = 'ACTIVE'; goal_revision = 0; finalize_reason = ''
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }
        Assert-SC ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SCValue $advDir9b 'dir' '')) -Ident ([string](Get-SCValue $advDir9b 'ident' '')) -Key $key9b -Record $pending9b)) '[S9b] a pending record simulates the pre-PREPARE crash' ''
        Set-SCStubMove -Move 'REPLAN' -Reason 'altered-controller-replan'
        try { $c9b = Invoke-SCContinuation -Goal $g9b -Key $key9b -NextIntent $intentNext9b }
        finally { Restore-SCStubMove }
        Assert-SC (((-not [bool]$c9b.ok) -and ([string]$c9b.reason -ceq 'continuation-settlement-uncertain') -and ([string]$c9b.cause_reason -ceq 'advance-record-pending') -and (-not [bool]$c9b.prepared))) '[S9b] pending with an altered controller stays uncertain' ('reason=' + [string]$c9b.reason)
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids9b.goal -Key $nextKey9b)) '[S9b] the altered controller prepared nothing' ''
        $otherKey9b = Get-NativeDispatchHash32 ('s3-divergent-' + $ids9b.next)
        $ghost9b = ('s3-ghost-' + $ids9b.next)
        New-SCTask -TaskId $ghost9b -GoalId $ids9b.goal -Gen $g9b.gen -Risk 'low'
        $ghostIntent9b = New-SCIntent -TaskId $ghost9b -Rev (Get-SCTaskRev -TaskId $ghost9b) -Key $otherKey9b -Gen $g9b.gen
        $c9c = Invoke-SCContinuation -Goal $g9b -Key $key9b -NextIntent $ghostIntent9b
        Assert-SC (((-not [bool]$c9c.ok) -and ([string]$c9c.reason -ceq 'continuation-settlement-uncertain') -and (-not [bool]$c9c.prepared))) '[S9c] pending with a divergent intent stays uncertain' ('reason=' + [string]$c9c.reason + ' cause=' + [string]$c9c.cause_reason)
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids9b.goal -Key $otherKey9b)) '[S9c] the divergent intent prepared no second successor' ''

        # ---------- 10. ND hardening: replay e finalize ----------
        $ids10a = New-SCIds -Tag 'ndreplay'
        $g10a = New-SCGoal -GoalId $ids10a.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids10a.task -GoalId $ids10a.goal -Gen $g10a.gen -Risk 'low'
        New-SCTask -TaskId $ids10a.next -GoalId $ids10a.goal -Gen $g10a.gen -Risk 'low'
        $key10a = Get-NativeDispatchHash32 ('s3-settled-' + $ids10a.task)
        $intent10a = New-SCIntent -TaskId $ids10a.task -Rev (Get-SCTaskRev -TaskId $ids10a.task) -Key $key10a -Gen $g10a.gen
        $null = Invoke-SCWalk -Goal $g10a -Intent $intent10a -Call 'call_s3_f1'
        $nextKey10a = Get-NativeDispatchHash32 ('s3-next-' + $ids10a.next)
        $intentNext10a = New-SCIntent -TaskId $ids10a.next -Rev (Get-SCTaskRev -TaskId $ids10a.next) -Key $nextKey10a -Gen $g10a.gen
        $advDir10a = Get-NDAdvanceDir -RootDir $script:scEnv.recs -GoalId $ids10a.goal
        $pending10a = [ordered]@{
            schema_version = 1; ok = $true; reason = ''; goal_id = $ids10a.goal; settled_key = $key10a
            move = 'CONTINUE'; move_reason = 'crashed-before-prepare'; stop_reason = ''; prepared = $false
            next_idempotency_key = $nextKey10a; next_reference = ''; next_task_id = ''; next_agent = ''
            prepare_reason = ''; goal_state = 'ACTIVE'; goal_revision = 0; finalize_reason = ''
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }
        Assert-SC ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SCValue $advDir10a 'dir' '')) -Ident ([string](Get-SCValue $advDir10a 'ident' '')) -Key $key10a -Record $pending10a)) '[S10a] a pending CONTINUE record is stored' ''
        Set-SCStubMove -Move 'REPLAN' -Reason 'altered-controller-replan'
        try {
            $a10a = Invoke-OrchestrationNativeDispatchAdvance -GoalId $ids10a.goal -SettledKey $key10a -Authorization $g10a.auth `
                -ObjectiveStatus (New-SCStatus) -NextIntent $intentNext10a -SessionId 'ses_s3_parent' -ReceiptDir $script:scEnv.recs `
                -GoalStoreDir $script:scEnv.goals -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        }
        finally { Restore-SCStubMove }
        Assert-SC (([bool]$a10a.ok) -and ([bool]$a10a.prepared) -and ([string]$a10a.move -ceq 'CONTINUE') -and ([string]$a10a.idempotency_key -ceq $nextKey10a)) '[S10a] replay preserves the recorded decision' ('move=' + [string]$a10a.move + ' reason=' + [string]$a10a.reason)
        Assert-SC (([int]$a10a.executor_calls -eq 0)) '[S10a] replay executes nothing' ('calls=' + [string]$a10a.executor_calls)
        $ids10b = New-SCIds -Tag 'ndpstop'
        $g10b = New-SCGoal -GoalId $ids10b.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids10b.task -GoalId $ids10b.goal -Gen $g10b.gen -Risk 'low'
        $key10b = Get-NativeDispatchHash32 ('s3-settled-' + $ids10b.task)
        $intent10b = New-SCIntent -TaskId $ids10b.task -Rev (Get-SCTaskRev -TaskId $ids10b.task) -Key $key10b -Gen $g10b.gen
        $null = Invoke-SCWalk -Goal $g10b -Intent $intent10b -Call 'call_s3_f2'
        $a10b = Invoke-OrchestrationNativeDispatchAdvance -GoalId $ids10b.goal -SettledKey $key10b -Authorization $g10b.auth `
            -ObjectiveStatus (New-SCStatus -Authorized $false -BlockerKind 'policy' -Remaining @()) -SessionId 'ses_s3_parent' `
            -ReceiptDir $script:scEnv.recs -GoalStoreDir $script:scEnv.goals -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -FinalizeGoalOnComplete
        Assert-SC (([bool]$a10b.ok) -and (-not [bool]$a10b.prepared) -and ([string]$a10b.move -ceq 'COMPLETE')) '[S10b] a policy stop records COMPLETE without preparing' ('move=' + [string]$a10b.move + ' reason=' + [string]$a10b.reason)
        $liveAfter10b = Get-SCLiveGoal -GoalId $ids10b.goal
        Assert-SC (([string]$liveAfter10b['state'] -ceq 'ACTIVE')) '[S10b] a policy stop never finalizes the goal' ([string]$liveAfter10b['state'])
        $rec10b = Get-SCAdvanceRecord -GoalId $ids10b.goal -Key $key10b
        Assert-SC (([string](Get-SCValue $rec10b 'finalize_reason' '') -ceq 'goal-finalize-refused:policy-stop')) '[S10b] the finalize refusal is recorded' ([string](Get-SCValue $rec10b 'finalize_reason' ''))
        $ids10c = New-SCIds -Tag 'ndfinal'
        $g10c = New-SCGoal -GoalId $ids10c.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids10c.task -GoalId $ids10c.goal -Gen $g10c.gen -Risk 'low'
        $key10c = Get-NativeDispatchHash32 ('s3-settled-' + $ids10c.task)
        $intent10c = New-SCIntent -TaskId $ids10c.task -Rev (Get-SCTaskRev -TaskId $ids10c.task) -Key $key10c -Gen $g10c.gen
        $null = Invoke-SCWalk -Goal $g10c -Intent $intent10c -Call 'call_s3_f3'
        Update-SCProgress -GoalId $ids10c.goal -Gen $g10c.gen -Satisfied 1 -Total 1
        $a10c = Invoke-OrchestrationNativeDispatchAdvance -GoalId $ids10c.goal -SettledKey $key10c -Authorization $g10c.auth `
            -ObjectiveStatus (New-SCStatus -Completed $true -Remaining @()) -SessionId 'ses_s3_parent' `
            -ReceiptDir $script:scEnv.recs -GoalStoreDir $script:scEnv.goals -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags -FinalizeGoalOnComplete
        Assert-SC (([bool]$a10c.ok) -and (-not [bool]$a10c.prepared) -and ([string]$a10c.move -ceq 'COMPLETE')) '[S10c] the legit finalize still records COMPLETE' ('reason=' + [string]$a10c.reason)
        $liveAfter10c = Get-SCLiveGoal -GoalId $ids10c.goal
        Assert-SC (([string]$liveAfter10c['state'] -ceq 'COMPLETED')) '[S10c] verified criteria finalize through CAS' ([string]$liveAfter10c['state'])

        # ---------- 11. registros corrompidos e incertos ----------
        $ids11a = New-SCIds -Tag 'corrupt'
        $g11a = New-SCGoal -GoalId $ids11a.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids11a.task -GoalId $ids11a.goal -Gen $g11a.gen -Risk 'low'
        New-SCTask -TaskId $ids11a.next -GoalId $ids11a.goal -Gen $g11a.gen -Risk 'low'
        $key11a = Get-NativeDispatchHash32 ('s3-settled-' + $ids11a.task)
        $intent11a = New-SCIntent -TaskId $ids11a.task -Rev (Get-SCTaskRev -TaskId $ids11a.task) -Key $key11a -Gen $g11a.gen
        $null = Invoke-SCWalk -Goal $g11a -Intent $intent11a -Call 'call_s3_g1'
        $nextKey11a = Get-NativeDispatchHash32 ('s3-next-' + $ids11a.next)
        $intentNext11a = New-SCIntent -TaskId $ids11a.next -Rev (Get-SCTaskRev -TaskId $ids11a.next) -Key $nextKey11a -Gen $g11a.gen
        $advPath11a = Get-SCAdvancePath -GoalId $ids11a.goal -Key $key11a
        [IO.File]::WriteAllText($advPath11a, '{ truncado', [Text.Encoding]::UTF8)
        $c11a = Invoke-SCContinuation -Goal $g11a -Key $key11a -NextIntent $intentNext11a
        Assert-SC (((-not [bool]$c11a.ok) -and ([string]$c11a.reason -ceq 'continuation-settlement-uncertain') -and ([string]$c11a.cause_reason -ceq 'advance-record-unreadable') -and (-not [bool]$c11a.prepared))) '[S11a] an unreadable advance record refuses' ('reason=' + [string]$c11a.reason)
        Assert-SC (([string]([IO.File]::ReadAllText($advPath11a, [Text.Encoding]::UTF8)) -ceq '{ truncado')) '[S11a] the corrupted record was preserved' ''
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids11a.goal -Key $nextKey11a)) '[S11a] no successor was prepared' ''
        $ids11b = New-SCIds -Tag 'noev'
        $g11b = New-SCGoal -GoalId $ids11b.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids11b.task -GoalId $ids11b.goal -Gen $g11b.gen -Risk 'low'
        New-SCTask -TaskId $ids11b.next -GoalId $ids11b.goal -Gen $g11b.gen -Risk 'low'
        $key11b = Get-NativeDispatchHash32 ('s3-settled-' + $ids11b.task)
        $intent11b = New-SCIntent -TaskId $ids11b.task -Rev (Get-SCTaskRev -TaskId $ids11b.task) -Key $key11b -Gen $g11b.gen
        $walk11b = Invoke-SCWalk -Goal $g11b -Intent $intent11b -Call 'call_s3_g2'
        $evPath11b = Join-Path $script:scEnv.evs ([string]$walk11b.evidence_id + '.json')
        Remove-Item -LiteralPath $evPath11b -Force -ErrorAction Stop
        $nextKey11b = Get-NativeDispatchHash32 ('s3-next-' + $ids11b.next)
        $intentNext11b = New-SCIntent -TaskId $ids11b.next -Rev (Get-SCTaskRev -TaskId $ids11b.next) -Key $nextKey11b -Gen $g11b.gen
        $c11b = Invoke-SCContinuation -Goal $g11b -Key $key11b -NextIntent $intentNext11b
        Assert-SC (((-not [bool]$c11b.ok) -and ([string]$c11b.reason -ceq 'continuation-settlement-unproven') -and ([string]$c11b.cause_reason -ceq 'evidence-file-missing') -and (-not [bool]$c11b.prepared))) '[S11b] missing evidence is unproven' ('reason=' + [string]$c11b.reason)
        $ids11c = New-SCIds -Tag 'badrec'
        $g11c = New-SCGoal -GoalId $ids11c.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids11c.task -GoalId $ids11c.goal -Gen $g11c.gen -Risk 'low'
        New-SCTask -TaskId $ids11c.next -GoalId $ids11c.goal -Gen $g11c.gen -Risk 'low'
        $key11c = Get-NativeDispatchHash32 ('s3-settled-' + $ids11c.task)
        $intent11c = New-SCIntent -TaskId $ids11c.task -Rev (Get-SCTaskRev -TaskId $ids11c.task) -Key $key11c -Gen $g11c.gen
        # Raiz isolada: o scan do claim varre a raiz inteira e recusa
        # fail-closed em registro ilegivel; o recibo corrompido de
        # proposito nao pode vazar para os outros cenarios.
        $recs11c = Join-Path $tempRoot 'recs-corrupt'
        New-Item -ItemType Directory -Path $recs11c -Force | Out-Null
        $null = Invoke-SCWalk -Goal $g11c -Intent $intent11c -Call 'call_s3_g3' -Receipts $recs11c
        $sub11c = Get-NDGoalReceiptDir -RootDir $recs11c -GoalId $ids11c.goal
        $recPath11c = Join-Path $sub11c ($key11c + '.json')
        [IO.File]::AppendAllText($recPath11c, '}]TRAILER-CORROMPIDO', [Text.Encoding]::UTF8)
        $nextKey11c = Get-NativeDispatchHash32 ('s3-next-' + $ids11c.next)
        $intentNext11c = New-SCIntent -TaskId $ids11c.next -Rev (Get-SCTaskRev -TaskId $ids11c.next) -Key $nextKey11c -Gen $g11c.gen
        $c11c = Invoke-SCContinuation -Goal $g11c -Key $key11c -NextIntent $intentNext11c -Receipts $recs11c
        Assert-SC (((-not [bool]$c11c.ok) -and ([string]$c11c.reason -ceq 'continuation-settlement-uncertain') -and (-not [bool]$c11c.prepared))) '[S11c] a corrupted receipt is uncertain' ('reason=' + [string]$c11c.reason + ' cause=' + [string]$c11c.cause_reason)
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids11c.goal -Key $nextKey11c -Receipts $recs11c)) '[S11c] no successor was prepared' ''
        $ids11d = New-SCIds -Tag 'ckptfail'
        $g11d = New-SCGoal -GoalId $ids11d.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids11d.task -GoalId $ids11d.goal -Gen $g11d.gen -Risk 'low'
        New-SCTask -TaskId $ids11d.next -GoalId $ids11d.goal -Gen $g11d.gen -Risk 'low'
        $key11d = Get-NativeDispatchHash32 ('s3-settled-' + $ids11d.task)
        $intent11d = New-SCIntent -TaskId $ids11d.task -Rev (Get-SCTaskRev -TaskId $ids11d.task) -Key $key11d -Gen $g11d.gen
        $null = Invoke-SCWalk -Goal $g11d -Intent $intent11d -Call 'call_s3_g4'
        Invoke-SCToReviewing -TaskId $ids11d.task
        Set-SCVerification -TaskId $ids11d.task
        Set-SCReview -TaskId $ids11d.task
        Invoke-SCComplete -TaskId $ids11d.task
        $nextKey11d = Get-NativeDispatchHash32 ('s3-next-' + $ids11d.next)
        $intentNext11d = New-SCIntent -TaskId $ids11d.next -Rev (Get-SCTaskRev -TaskId $ids11d.next) -Key $nextKey11d -Gen $g11d.gen
        $ckptFile11d = Join-Path $tempRoot 'ckpt-is-a-file.json'
        [IO.File]::WriteAllText($ckptFile11d, '{}', [Text.Encoding]::UTF8)
        $c11d = Invoke-SCContinuation -Goal $g11d -Key $key11d -NextIntent $intentNext11d -CkptDir $ckptFile11d
        Assert-SC (([bool]$c11d.ok) -and ([string]$c11d.action -ceq 'prepared') -and ([bool]$c11d.prepared) -and ([string]$c11d.reason -ceq 'continuation-checkpoint-required') -and (-not [bool]$c11d.checkpoint_ok)) '[S11d] post-PREPARE checkpoint failure keeps prepared' ('reason=' + [string]$c11d.reason)
        Assert-SC (([string]$c11d.next_idempotency_key -ceq $nextKey11d)) '[S11d] the prepared key is still returned' ('key=' + [string]$c11d.next_idempotency_key)
        $recNext11d = Get-SCReceipt -GoalId $ids11d.goal -Key $nextKey11d
        Assert-SC (($null -ne $recNext11d) -and (([string]$recNext11d.phase -ceq 'prepared'))) '[S11d] the successor was still prepared' ''
        $c11d2 = Invoke-SCContinuation -Goal $g11d -Key $key11d -NextIntent $intentNext11d
        Assert-SC (([bool]$c11d2.ok) -and ([bool]$c11d2.prepared) -and ([string]$c11d2.next_idempotency_key -ceq $nextKey11d) -and ([bool]$c11d2.checkpoint_ok)) '[S11d] replay recovers the checkpoint' ('reason=' + [string]$c11d2.reason)

        # ---------- 12. compatibilidade sem SettledKey ----------
        $ids12 = New-SCIds -Tag 'compat'
        $g12 = New-SCGoal -GoalId $ids12.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids12.task -GoalId $ids12.goal -Gen $g12.gen -Risk 'low'
        $live12 = Get-SCLiveGoal -GoalId $ids12.goal
        $ph12 = Get-NativeDispatchHash32 's3-compat-prompt'
        $spec12 = @{
            task_id = $ids12.task; task_expected_revision = (Get-SCTaskRev -TaskId $ids12.task); agent = 'coder'
            prompt_hash = $ph12; scope = @('s3/a.txt'); acceptance_criteria = @('criterion:0')
            owner = 'planner-1'; ownership_generation = $g12.gen; base_revision = 's3-base'
        }
        $s12 = Invoke-OrchestrationObjectiveStep -Goal $live12 -CheckpointDir $script:scEnv.ckpts -Authorization $g12.auth -DispatchSpec $spec12 `
            -GoalStoreDir $script:scEnv.goals -EvidenceStoreDir $script:scEnv.evs -ReceiptDir $script:scEnv.recs `
            -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC (([string]$s12.action -ceq 'dispatch_intent')) '[S12] without SettledKey the legacy path is intact' ('action=' + [string]$s12.action + ' reason=' + [string]$s12.reason)
        Assert-SC (($null -ne $s12.dispatch_intent) -and ([string]$s12.dispatch_intent.task_id -ceq $ids12.task)) '[S12] legacy intent binds the task' ''
        Assert-SC ([bool]$s12.checkpoint_ok) '[S12] legacy step checkpoints' ([string]$s12.checkpoint_id)

        # ---------- 13. F1: hard trigger eleva a L3 ----------
        $ids13 = New-SCIds -Tag 'trigger'
        $g13 = New-SCGoal -GoalId $ids13.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids13.task -GoalId $ids13.goal -Gen $g13.gen -Risk 'low' -Objective 'fix auth flow'
        New-SCTask -TaskId $ids13.next -GoalId $ids13.goal -Gen $g13.gen -Risk 'low' -Objective 'fix auth flow follow-up'
        $key13 = Get-NativeDispatchHash32 ('s3-settled-' + $ids13.task)
        $intent13 = New-SCIntent -TaskId $ids13.task -Rev (Get-SCTaskRev -TaskId $ids13.task) -Key $key13 -Gen $g13.gen
        $null = Invoke-SCWalk -Goal $g13 -Intent $intent13 -Call 'call_s3_h1'
        Invoke-SCToReviewing -TaskId $ids13.task
        Set-SCVerification -TaskId $ids13.task
        Set-SCReview -TaskId $ids13.task
        $nextKey13 = Get-NativeDispatchHash32 ('s3-next-' + $ids13.next)
        $intentNext13 = New-SCIntent -TaskId $ids13.next -Rev (Get-SCTaskRev -TaskId $ids13.next) -Key $nextKey13 -Gen $g13.gen
        $c13 = Invoke-SCContinuation -Goal $g13 -Key $key13 -NextIntent $intentNext13
        Assert-SC (((-not [bool]$c13.ok) -and ([string]$c13.reason -ceq 'continuation-review-required') -and ([string]$c13.cause_reason -ceq 'security-review-missing') -and (-not [bool]$c13.prepared))) '[S13] an auth trigger requires security review even at low risk' ('reason=' + [string]$c13.reason + ' cause=' + [string]$c13.cause_reason)
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids13.goal -Key $nextKey13)) '[S13] the trigger blocks without preparing' ''
        Set-SCReview -TaskId $ids13.task -Kind 'security' -Status 'approved' -By 'security-1'
        Invoke-SCComplete -TaskId $ids13.task
        $c13b = Invoke-SCContinuation -Goal $g13 -Key $key13 -NextIntent $intentNext13
        Assert-SC (([bool]$c13b.ok) -and ([string]$c13b.action -ceq 'prepared') -and ([bool]$c13b.prepared) -and ([string]$c13b.next_idempotency_key -ceq $nextKey13)) '[S13] the approved security review unlocks the continuation' ('action=' + [string]$c13b.action + ' reason=' + [string]$c13b.reason)
        Assert-SC (([int]$c13b.executor_calls -eq 0)) '[S13] no worker ever executed' ('calls=' + [string]$c13b.executor_calls)

        # ---------- 13b. F1: trigger no GOAL eleva a L3 ----------
        $ids13b = New-SCIds -Tag 'goaltrigger'
        $g13bGoal = New-SCGoal -GoalId $ids13b.goal -Criteria @('s3-crit-a', 's3-crit-b')
        # O goal vivo carrega o texto sensivel; a task e generica.
        $live13b = Get-SCLiveGoal -GoalId $ids13b.goal
        $upd13b = Update-OrchestrationGoal -GoalId $ids13b.goal -ExpectedRevision ([long]$live13b['revision']) `
            -Fields @{ objective = 'payments migration' } -StoreDir $script:scEnv.goals -OwnerId 'planner-1' -OwnershipGeneration $g13bGoal.gen
        Assert-SC ([bool]$upd13b.ok) '[S13b] the goal carries a sensitive objective' ([string]$upd13b.reason)
        New-SCTask -TaskId $ids13b.task -GoalId $ids13b.goal -Gen $g13bGoal.gen -Risk 'low'
        New-SCTask -TaskId $ids13b.next -GoalId $ids13b.goal -Gen $g13bGoal.gen -Risk 'low'
        $key13b = Get-NativeDispatchHash32 ('s3-settled-' + $ids13b.task)
        $intent13b = New-SCIntent -TaskId $ids13b.task -Rev (Get-SCTaskRev -TaskId $ids13b.task) -Key $key13b -Gen $g13bGoal.gen
        $null = Invoke-SCWalk -Goal $g13bGoal -Intent $intent13b -Call 'call_s3_h8'
        Invoke-SCToReviewing -TaskId $ids13b.task
        Set-SCVerification -TaskId $ids13b.task
        Set-SCReview -TaskId $ids13b.task
        $nextKey13b = Get-NativeDispatchHash32 ('s3-next-' + $ids13b.next)
        $intentNext13b = New-SCIntent -TaskId $ids13b.next -Rev (Get-SCTaskRev -TaskId $ids13b.next) -Key $nextKey13b -Gen $g13bGoal.gen
        $c13c = Invoke-SCContinuation -Goal $g13bGoal -Key $key13b -NextIntent $intentNext13b
        Assert-SC (((-not [bool]$c13c.ok) -and ([string]$c13c.reason -ceq 'continuation-review-required') -and ([string]$c13c.cause_reason -ceq 'security-review-missing') -and (-not [bool]$c13c.prepared))) '[S13b] a goal trigger requires security review with a generic task' ('reason=' + [string]$c13c.reason + ' cause=' + [string]$c13c.cause_reason)
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids13b.goal -Key $nextKey13b)) '[S13b] the goal trigger blocks without preparing' ''
        Set-SCReview -TaskId $ids13b.task -Kind 'security' -Status 'approved' -By 'security-1'
        Invoke-SCComplete -TaskId $ids13b.task
        $c13d = Invoke-SCContinuation -Goal $g13bGoal -Key $key13b -NextIntent $intentNext13b
        Assert-SC (([bool]$c13d.ok) -and ([string]$c13d.action -ceq 'prepared') -and ([bool]$c13d.prepared) -and ([string]$c13d.next_idempotency_key -ceq $nextKey13b)) '[S13b] the approved security review unlocks the goal trigger' ('action=' + [string]$c13d.action + ' reason=' + [string]$c13d.reason)

        # ---------- 14. F2: diretorio no path do advance e zero-efeito ----------
        # Um diretorio no path do advance record nao vira ausencia: o
        # proprio ADVANCE recusa em advance-intent-unknown antes de
        # consultar o Controller, admitir ou preparar (corrupcao nunca e
        # ausencia). A S3a propaga a recusa com zero-efeito. (O ramo F2 de
        # falha pos-PREPARE com prepared=true exige troca de FS no meio do
        # ADVANCE e nao e deterministicamente reproduzivel sem ganchos no
        # ND: ver notas do plano.)
        $ids14 = New-SCIds -Tag 'recfail'
        $g14 = New-SCGoal -GoalId $ids14.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids14.task -GoalId $ids14.goal -Gen $g14.gen -Risk 'low'
        New-SCTask -TaskId $ids14.next -GoalId $ids14.goal -Gen $g14.gen -Risk 'low'
        $key14 = Get-NativeDispatchHash32 ('s3-settled-' + $ids14.task)
        $intent14 = New-SCIntent -TaskId $ids14.task -Rev (Get-SCTaskRev -TaskId $ids14.task) -Key $key14 -Gen $g14.gen
        $null = Invoke-SCWalk -Goal $g14 -Intent $intent14 -Call 'call_s3_h2'
        Invoke-SCToReviewing -TaskId $ids14.task
        Set-SCVerification -TaskId $ids14.task
        Set-SCReview -TaskId $ids14.task
        Invoke-SCComplete -TaskId $ids14.task
        $nextKey14 = Get-NativeDispatchHash32 ('s3-next-' + $ids14.next)
        $intentNext14 = New-SCIntent -TaskId $ids14.next -Rev (Get-SCTaskRev -TaskId $ids14.next) -Key $nextKey14 -Gen $g14.gen
        $advPath14 = Get-SCAdvancePath -GoalId $ids14.goal -Key $key14
        New-Item -ItemType Directory -Path $advPath14 -Force | Out-Null
        $c14 = Invoke-SCContinuation -Goal $g14 -Key $key14 -NextIntent $intentNext14
        Assert-SC (((-not [bool]$c14.ok) -and ([string]$c14.reason -ceq 'advance-intent-unknown') -and (-not [bool]$c14.prepared))) '[S14] a directory at the advance path is zero-effect' ('reason=' + [string]$c14.reason + ' cause=' + [string]$c14.cause_reason)
        Assert-SC (([string]::IsNullOrWhiteSpace([string]$c14.next_idempotency_key))) '[S14] no successor key is returned' ([string]$c14.next_idempotency_key)
        Assert-SC ((Test-Path -LiteralPath $advPath14 -PathType Container)) '[S14] the blocking directory was preserved' ''
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids14.goal -Key $nextKey14)) '[S14] the blocked record prepared no successor' ''
        Assert-SC (([string]::IsNullOrWhiteSpace([string]$c14.checkpoint_id) -and (-not [bool]$c14.checkpoint_ok))) '[S14] no checkpoint on the refused path' ''

        # ---------- 14b. F2: unit do envelope prepared+!ok ----------
        # Teste unitario do tratamento do envelope ND: o S14 honesto prova
        # a recusa real do ND antes do PREPARE; aqui o ADVANCE e substituido
        # no escopo do teste (mesmo padrao de Set-SCStubMove) por um double
        # que devolve prepared=true com ok=false, e a S3a deve preservar o
        # efeito em vez de colapsar em recusa sem efeito.
        $ids14b = New-SCIds -Tag 'prepeff'
        $g14b = New-SCGoal -GoalId $ids14b.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids14b.task -GoalId $ids14b.goal -Gen $g14b.gen -Risk 'low'
        New-SCTask -TaskId $ids14b.next -GoalId $ids14b.goal -Gen $g14b.gen -Risk 'low'
        $key14b = Get-NativeDispatchHash32 ('s3-settled-' + $ids14b.task)
        $intent14b = New-SCIntent -TaskId $ids14b.task -Rev (Get-SCTaskRev -TaskId $ids14b.task) -Key $key14b -Gen $g14b.gen
        $null = Invoke-SCWalk -Goal $g14b -Intent $intent14b -Call 'call_s3_h9'
        Invoke-SCToReviewing -TaskId $ids14b.task
        Set-SCVerification -TaskId $ids14b.task
        Set-SCReview -TaskId $ids14b.task
        Invoke-SCComplete -TaskId $ids14b.task
        $nextKey14b = Get-NativeDispatchHash32 ('s3-next-' + $ids14b.next)
        $intentNext14b = New-SCIntent -TaskId $ids14b.next -Rev (Get-SCTaskRev -TaskId $ids14b.next) -Key $nextKey14b -Gen $g14b.gen
        # Sem GetNewClosure: o bloco precisa enxergar $script: da suite
        # (closure criaria modulo dinamico proprio e o contador nao seria
        # observado aqui); ref fixo no corpo, sem captura de local.
        $script:scAdvCalls = 0
        $script:scAdvOrig = (Get-Item -Path 'function:Invoke-OrchestrationNativeDispatchAdvance').ScriptBlock
        Set-Item -Path 'function:Invoke-OrchestrationNativeDispatchAdvance' -Value {
            param([string]$GoalId = '', [string]$SettledKey = '', $Authorization = $null, $ObjectiveStatus = $null, $NextIntent = $null,
                [string]$SessionId = '', [string]$ReceiptDir = '', [string]$RepoRoot = '', [string]$GoalStoreDir = '',
                [string]$TasksDir = '', [string]$FlagsPath = '', [int]$LockTimeoutMs = 60000)
            $script:scAdvCalls++
            $nk = ''
            try {
                $rn = $NextIntent
                if ($null -ne $rn) {
                    if ($rn -is [System.Collections.IDictionary]) { if ($rn.Contains('intent')) { $rn = $rn['intent'] } }
                    else { $pp = $rn.PSObject.Properties['intent']; if ($null -ne $pp) { $rn = $pp.Value } }
                }
                if ($null -eq $rn) { $rn = $NextIntent }
                if ($rn -is [System.Collections.IDictionary]) { $nk = ([string]$rn['idempotency_key']) }
                else { $ep = $rn.PSObject.Properties['idempotency_key']; if ($null -ne $ep) { $nk = ([string]$ep.Value) } }
            }
            catch { $nk = '' }
            return [pscustomobject][ordered]@{
                ok = $false; reason = 'advance-record-write-failed'; move = 'CONTINUE'; move_reason = 'progress-continue'
                stop_reason = 'CONTINUE'; goal_id = ([string]$GoalId); settled_key = ([string]$SettledKey)
                prepared = $true; idempotency_key = ([string]$nk).Trim().ToLowerInvariant(); reference = 'ref_s14b_stub'
                task_id = ''; agent = ''; record_path = ''; executor_calls = 0
            }
        }
        try { $c14b = Invoke-SCContinuation -Goal $g14b -Key $key14b -NextIntent $intentNext14b }
        finally { Set-Item -Path 'function:Invoke-OrchestrationNativeDispatchAdvance' -Value $script:scAdvOrig }
        Assert-SC (((-not [bool]$c14b.ok) -and ([string]$c14b.action -ceq 'prepared') -and ([bool]$c14b.prepared))) '[S14b] the prepared effect is preserved on advance failure' ('action=' + [string]$c14b.action + ' reason=' + [string]$c14b.reason)
        Assert-SC ((([string]$c14b.reason -ceq 'continuation-settlement-uncertain') -and ([string]$c14b.cause_reason -ceq 'advance-record-write-failed'))) '[S14b] the failure cause is explicit' ('cause=' + [string]$c14b.cause_reason)
        Assert-SC ((([string]$c14b.next_idempotency_key -ceq $nextKey14b) -and ([string]$c14b.next_reference -ceq 'ref_s14b_stub'))) '[S14b] the prepared key and reference survive' ('key=' + [string]$c14b.next_idempotency_key)
        Assert-SC ([bool]$c14b.checkpoint_ok) '[S14b] the prepared checkpoint is written' ([string]$c14b.checkpoint_id)
        Assert-SC (([int]$script:scAdvCalls -eq 1)) '[S14b] the advance ran exactly once' ('calls=' + [string]$script:scAdvCalls)

        # ---------- 15. F3: evidencia ilegivel e uncertain ----------
        $ids15 = New-SCIds -Tag 'badev'
        $g15 = New-SCGoal -GoalId $ids15.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids15.task -GoalId $ids15.goal -Gen $g15.gen -Risk 'low'
        New-SCTask -TaskId $ids15.next -GoalId $ids15.goal -Gen $g15.gen -Risk 'low'
        $key15 = Get-NativeDispatchHash32 ('s3-settled-' + $ids15.task)
        $intent15 = New-SCIntent -TaskId $ids15.task -Rev (Get-SCTaskRev -TaskId $ids15.task) -Key $key15 -Gen $g15.gen
        $walk15 = Invoke-SCWalk -Goal $g15 -Intent $intent15 -Call 'call_s3_h3'
        $evPath15 = Join-Path $script:scEnv.evs ([string]$walk15.evidence_id + '.json')
        [IO.File]::WriteAllText($evPath15, '{ evidencia-invalida', [Text.Encoding]::UTF8)
        $nextKey15 = Get-NativeDispatchHash32 ('s3-next-' + $ids15.next)
        $intentNext15 = New-SCIntent -TaskId $ids15.next -Rev (Get-SCTaskRev -TaskId $ids15.next) -Key $nextKey15 -Gen $g15.gen
        $c15 = Invoke-SCContinuation -Goal $g15 -Key $key15 -NextIntent $intentNext15
        Assert-SC (((-not [bool]$c15.ok) -and ([string]$c15.reason -ceq 'continuation-settlement-uncertain') -and ([string]$c15.cause_reason -ceq 'evidence-unreadable') -and (-not [bool]$c15.prepared))) '[S15] an unreadable evidence file is uncertain' ('reason=' + [string]$c15.reason + ' cause=' + [string]$c15.cause_reason)
        Assert-SC ($null -eq (Get-SCReceipt -GoalId $ids15.goal -Key $nextKey15)) '[S15] the unreadable evidence prepared nothing' ''

        # ---------- 16. F4: replay COMPLETE exige autorizacao viva ----------
        $ids16 = New-SCIds -Tag 'noauth'
        $g16 = New-SCGoal -GoalId $ids16.goal -Criteria @('s3-crit-a')
        New-SCTask -TaskId $ids16.task -GoalId $ids16.goal -Gen $g16.gen -Risk 'low'
        $key16 = Get-NativeDispatchHash32 ('s3-settled-' + $ids16.task)
        $intent16 = New-SCIntent -TaskId $ids16.task -Rev (Get-SCTaskRev -TaskId $ids16.task) -Key $key16 -Gen $g16.gen
        $null = Invoke-SCWalk -Goal $g16 -Intent $intent16 -Call 'call_s3_h4'
        Update-SCProgress -GoalId $ids16.goal -Gen $g16.gen -Satisfied 1 -Total 1
        $a16 = Invoke-OrchestrationNativeDispatchAdvance -GoalId $ids16.goal -SettledKey $key16 -Authorization $g16.auth `
            -ObjectiveStatus (New-SCStatus -Completed $true -Remaining @()) -SessionId 'ses_s3_parent' `
            -ReceiptDir $script:scEnv.recs -GoalStoreDir $script:scEnv.goals -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC (([bool]$a16.ok) -and ([string]$a16.move -ceq 'COMPLETE') -and (-not [bool]$a16.prepared)) '[S16] the COMPLETE decision is recorded without finalizing' ('reason=' + [string]$a16.reason)
        $liveBefore16 = Get-SCLiveGoal -GoalId $ids16.goal
        $revBefore16 = [long]$liveBefore16['revision']
        $authDeny16 = @{ explicit_allow = $false; goal_id = $ids16.goal; owner = 'planner-1'; generation = $g16.gen; source = 'planner' }
        $c16a = Invoke-OrchestrationSettledContinuation -GoalId $ids16.goal -SettledKey $key16 -Authorization $authDeny16 `
            -SessionId 'ses_s3_parent' -CheckpointDir $script:scEnv.ckpts -GoalStoreDir $script:scEnv.goals -EvidenceStoreDir $script:scEnv.evs `
            -ReceiptDir $script:scEnv.recs -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC (((-not [bool]$c16a.ok) -and ([string]$c16a.action -ceq 'blocked') -and ([string]$c16a.reason -ceq 'continuation-completion-unproven') -and ([string]$c16a.cause_reason -ceq 'authorization:explicit-allow-required'))) '[S16] denied auth blocks the replayed completion' ('reason=' + [string]$c16a.reason + ' cause=' + [string]$c16a.cause_reason)
        $liveAfter16a = Get-SCLiveGoal -GoalId $ids16.goal
        Assert-SC ((([string]$liveAfter16a['state'] -ceq 'ACTIVE') -and ([long]$liveAfter16a['revision'] -eq $revBefore16))) '[S16] the denied replay performs zero CAS' ([string]$liveAfter16a['state'])
        $authCb16 = @{ explicit_allow = $true; goal_id = $ids16.goal; owner = 'planner-1'; generation = $g16.gen; source = 'test-callback' }
        $c16b = Invoke-OrchestrationSettledContinuation -GoalId $ids16.goal -SettledKey $key16 -Authorization $authCb16 `
            -SessionId 'ses_s3_parent' -CheckpointDir $script:scEnv.ckpts -GoalStoreDir $script:scEnv.goals -EvidenceStoreDir $script:scEnv.evs `
            -ReceiptDir $script:scEnv.recs -TasksDir $script:scEnv.tasks -FlagsPath $script:scEnv.flags
        Assert-SC (((-not [bool]$c16b.ok) -and ([string]$c16b.reason -ceq 'continuation-completion-unproven') -and ([string]$c16b.cause_reason -ceq 'authorization:test-callback-never-authorizes-production'))) '[S16] a test-callback source never authorizes completion' ('cause=' + [string]$c16b.cause_reason)
        $liveAfter16b = Get-SCLiveGoal -GoalId $ids16.goal
        Assert-SC ((([string]$liveAfter16b['state'] -ceq 'ACTIVE') -and ([long]$liveAfter16b['revision'] -eq $revBefore16))) '[S16] the callback replay performs zero CAS' ([string]$liveAfter16b['state'])
        $c16c = Invoke-SCContinuation -Goal $g16 -Key $key16
        Assert-SC (([bool]$c16c.ok) -and ([string]$c16c.action -ceq 'completed')) '[S16] the valid auth completes via replayed CAS' ('action=' + [string]$c16c.action + ' reason=' + [string]$c16c.reason)
        $liveAfter16c = Get-SCLiveGoal -GoalId $ids16.goal
        Assert-SC ([string]$liveAfter16c['state'] -ceq 'COMPLETED') '[S16] the goal is COMPLETED' ([string]$liveAfter16c['state'])

        # ---------- 17. F5: settlement antigo nao herda aprovacao ----------
        $ids17 = New-SCIds -Tag 'stalek'
        $g17 = New-SCGoal -GoalId $ids17.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids17.task -GoalId $ids17.goal -Gen $g17.gen -Risk 'low'
        New-SCTask -TaskId $ids17.next -GoalId $ids17.goal -Gen $g17.gen -Risk 'low'
        New-SCTask -TaskId ($ids17.next + '-b') -GoalId $ids17.goal -Gen $g17.gen -Risk 'low'
        $key17a = Get-NativeDispatchHash32 ('s3-settled-' + $ids17.task + '-k1')
        $intent17a = New-SCIntent -TaskId $ids17.task -Rev (Get-SCTaskRev -TaskId $ids17.task) -Key $key17a -Gen $g17.gen
        $null = Invoke-SCWalk -Goal $g17 -Intent $intent17a -Call 'call_s3_h5'
        $key17b = Get-NativeDispatchHash32 ('s3-settled-' + $ids17.task + '-k2')
        $intent17b = New-SCIntent -TaskId $ids17.task -Rev (Get-SCTaskRev -TaskId $ids17.task) -Key $key17b -Gen $g17.gen
        $null = Invoke-SCWalk -Goal $g17 -Intent $intent17b -Call 'call_s3_h6'
        Invoke-SCToReviewing -TaskId $ids17.task
        Set-SCVerification -TaskId $ids17.task
        Set-SCReview -TaskId $ids17.task
        Invoke-SCComplete -TaskId $ids17.task
        $nextKey17a = Get-NativeDispatchHash32 ('s3-next-' + $ids17.next)
        $intentNext17a = New-SCIntent -TaskId $ids17.next -Rev (Get-SCTaskRev -TaskId $ids17.next) -Key $nextKey17a -Gen $g17.gen
        $c17a = Invoke-SCContinuation -Goal $g17 -Key $key17a -NextIntent $intentNext17a
        Assert-SC (((-not [bool]$c17a.ok) -and ([string]$c17a.reason -ceq 'continuation-task-result-mismatch') -and ([string]$c17a.cause_reason -ceq 'worker-result-superseded') -and (-not [bool]$c17a.prepared))) '[S17] the old settlement never inherits the new approval' ('reason=' + [string]$c17a.reason + ' cause=' + [string]$c17a.cause_reason)
        Assert-SC (($null -eq (Get-SCAdvanceRecord -GoalId $ids17.goal -Key $key17a)) -and ($null -eq (Get-SCReceipt -GoalId $ids17.goal -Key $nextKey17a))) '[S17] the old key reserves no successor' ''
        $nextKey17b = Get-NativeDispatchHash32 ('s3-next-' + $ids17.next + '-b')
        $intentNext17b = New-SCIntent -TaskId ($ids17.next + '-b') -Rev (Get-SCTaskRev -TaskId ($ids17.next + '-b')) -Key $nextKey17b -Gen $g17.gen
        $c17b = Invoke-SCContinuation -Goal $g17 -Key $key17b -NextIntent $intentNext17b
        Assert-SC (([bool]$c17b.ok) -and ([string]$c17b.action -ceq 'prepared') -and ([bool]$c17b.prepared) -and ([string]$c17b.next_idempotency_key -ceq $nextKey17b)) '[S17] the current settlement prepares exactly one successor' ('action=' + [string]$c17b.action)
        Assert-SC (([int]$c17b.executor_calls -eq 0)) '[S17] no worker ever executed' ('calls=' + [string]$c17b.executor_calls)

        # ---------- 18. F7: goal nao-ACTIVE ----------
        $ids18 = New-SCIds -Tag 'paused'
        $g18 = New-SCGoal -GoalId $ids18.goal -Criteria @('s3-crit-a', 's3-crit-b')
        New-SCTask -TaskId $ids18.task -GoalId $ids18.goal -Gen $g18.gen -Risk 'low'
        New-SCTask -TaskId $ids18.next -GoalId $ids18.goal -Gen $g18.gen -Risk 'low'
        $key18 = Get-NativeDispatchHash32 ('s3-settled-' + $ids18.task)
        $intent18 = New-SCIntent -TaskId $ids18.task -Rev (Get-SCTaskRev -TaskId $ids18.task) -Key $key18 -Gen $g18.gen
        $null = Invoke-SCWalk -Goal $g18 -Intent $intent18 -Call 'call_s3_h7'
        $live18 = Get-SCLiveGoal -GoalId $ids18.goal
        $paused18 = Set-OrchestrationGoalStatePersisted -GoalId $ids18.goal -ToState 'PAUSED' -ExpectedRevision ([long]$live18['revision']) -StoreDir $script:scEnv.goals -OwnerId 'planner-1' -OwnershipGeneration $g18.gen
        Assert-SC ([bool]$paused18.ok) '[S18] the fixture goal is paused' ([string]$paused18.reason)
        $nextKey18 = Get-NativeDispatchHash32 ('s3-next-' + $ids18.next)
        $intentNext18 = New-SCIntent -TaskId $ids18.next -Rev (Get-SCTaskRev -TaskId $ids18.next) -Key $nextKey18 -Gen $g18.gen
        $c18 = Invoke-SCContinuation -Goal $g18 -Key $key18 -NextIntent $intentNext18
        Assert-SC (((-not [bool]$c18.ok) -and ([string]$c18.reason -ceq 'advance-stale-goal') -and ([string]$c18.cause_reason -ceq 'goal-not-active:PAUSED') -and (-not [bool]$c18.prepared))) '[S18] a paused goal refuses without reactivating' ('reason=' + [string]$c18.reason)
        $liveAfter18 = Get-SCLiveGoal -GoalId $ids18.goal
        Assert-SC ([string]$liveAfter18['state'] -ceq 'PAUSED') '[S18] the goal stays paused' ([string]$liveAfter18['state'])
        Assert-SC (($null -eq (Get-SCAdvanceRecord -GoalId $ids18.goal -Key $key18)) -and ($null -eq (Get-SCReceipt -GoalId $ids18.goal -Key $nextKey18))) '[S18] the paused goal prepares nothing' ''

        # ---------- F6: contencao do evidence_id (unit do guard) ----------
        Assert-SC ([bool](Test-SCEvidenceIdContained -EvidenceId 'a07f42c1bcedfb255e127d71c666491e')) '[F6] a plain evidence id is contained' ''
        Assert-SC ((-not [bool](Test-SCEvidenceIdContained -EvidenceId '../escape'))) '[F6] parent traversal is rejected' ''
        Assert-SC ((-not [bool](Test-SCEvidenceIdContained -EvidenceId '/abs/path'))) '[F6] an absolute path is rejected' ''
        Assert-SC ((-not [bool](Test-SCEvidenceIdContained -EvidenceId 'sub/dir'))) '[F6] a subpath is rejected' ''
        Assert-SC ((-not [bool](Test-SCEvidenceIdContained -EvidenceId ''))) '[F6] an empty id is rejected' ''

        # ---------- hygiene ----------
        $s3aPath = Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1'
        $s3aText = [IO.File]::ReadAllText($s3aPath, [Text.Encoding]::UTF8)
        Assert-SC ((($s3aText -notmatch 'Start-Process') -and ($s3aText -notmatch 'Invoke-WebRequest') -and ($s3aText -notmatch 'HttpClient') -and ($s3aText -notmatch 'while\s*\(\s*\$true'))) '[NET] no spawn/network/busy-loop' ''
        foreach ($p in @($s3aPath, (Join-Path $PSScriptRoot 'OrchestrationSettledContinuation.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-SC ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
    }
    finally {
        try { Restore-SCStubMove } catch { }
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
