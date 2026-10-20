<#!
.SYNOPSIS
    Tests for S4 limited settled recovery (fixture-only).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written
    (the real validation-policy.json is only READ). Bracketed output the
    runner parses. Exit 0 all pass, 1 any fail. PS 5.1 compatible.
    ASCII-only. No network, no spawn, no Executor.
    Covers: prepared replay + deterministic re-entry (single successor),
    terminal REPLAN/BLOCKED replay (goal unmutated), COMPLETE valid
    (CAS, already-completed on re-entry) and refused (no criteria, honest
    record), auth/session/ownership refusals, valid external takeover,
    pending same+same manual (domain hashes unchanged) vs divergent
    intent unproven (no record), receipt prepared/claimed/pending manual,
    evidence missing/illegible manual-or-honest, worker superseded
    refusal, checkpoint rebuild success + honest failure, corrupt/
    divergent/crash records, two-process lock behavior, adversarial
    receipt removal/swap and advance downgrade, zero worker/CLAIM/
    SETTLE/PREPARE sentinel, and no-SettledKey compatibility.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationSettledRecovery.ps1')

$script:passed = 0
$script:failed = 0

function Assert-SR {
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

function Get-SRValue {
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
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-s4-' + [guid]::NewGuid().ToString('N'))
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
    $script:srEnv = $env
    $script:srSeq = 0

    function New-SRIds { param([string]$Tag)
        $script:srSeq++
        $n = [string]$script:srSeq
        return [pscustomobject]@{
            goal = ('s4-goal-' + $Tag + '-' + $n)
            task = ('s4-task-' + $Tag + '-' + $n)
            next = ('s4-next-' + $Tag + '-' + $n)
        }
    }

    function New-SRGoal {
        param([string]$GoalId, [string[]]$Criteria = @('s4-crit-a', 's4-crit-b'), [long]$LeaseTtlMs = 60000)
        $g = New-OrchestrationGoal -GoalId $GoalId -Objective ('s4 objective ' + $GoalId) -Criteria @($Criteria) -StoreDir $script:srEnv.goals
        Assert-SR ([bool]$g.ok) ('[F] goal created ' + $GoalId) ([string]$g.reason)
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $script:srEnv.goals
        Assert-SR ([bool]$sv.ok) ('[F] goal active ' + $GoalId) ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $script:srEnv.goals -LeaseTtlMs $LeaseTtlMs
        Assert-SR ([bool]$own.ok) ('[F] goal owned ' + $GoalId) ([string]$own.reason)
        $gen = [long]$own.ownership['generation']
        return [pscustomobject]@{ goal_id = $GoalId; gen = $gen; auth = @{ explicit_allow = $true; goal_id = $GoalId; owner = 'planner-1'; generation = $gen; source = 'planner' } }
    }

    function Get-SRLiveGoal { param([string]$GoalId)
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $script:srEnv.goals
        if (($null -eq $slot) -or (-not [bool](Get-SRValue $slot 'ok' $false))) { return $null }
        return (Get-SRValue $slot 'goal' $null)
    }

    function Get-SRTaskRev { param([string]$TaskId)
        $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $script:srEnv.tasks
        return [long](Get-SRValue $t 'revision' -1)
    }

    function New-SRTask {
        param([string]$TaskId, [string]$GoalId, [long]$Gen, [string]$Risk = 'low')
        $c = New-OrchestrationTask -TaskId $TaskId -Objective ('s4 obj ' + $TaskId) -TaskType 'implementation' `
            -Risk $Risk -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 's4-base' -ReadScopes @('s4/a.txt') -WriteScopes @('s4/a.txt') `
            -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 `
            -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -TelemetryRoot $script:srEnv.tele
        Assert-SR ([bool]$c.ok) ('[F] kernel task created ' + $TaskId) ([string]$c.error)
        $t1 = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner-1' -ExpectedRevision 1 `
            -ActorIdentitySource 'explicit-cli' -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -TelemetryRoot $script:srEnv.tele
        Assert-SR ([bool]$t1.ok) ('[F] task planning ' + $TaskId) ([string]$t1.error)
        $rev = Get-SRTaskRev -TaskId $TaskId
        $t2 = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'IMPLEMENTING' -Actor 'planner-1' -ExpectedRevision $rev `
            -ActorIdentitySource 'explicit-cli' -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -TelemetryRoot $script:srEnv.tele
        Assert-SR ([bool]$t2.ok) ('[F] task implementing ' + $TaskId) ([string]$t2.error)
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $script:srEnv.goals
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $TaskId -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $script:srEnv.goals -OwnerId 'planner-1' -OwnershipGeneration $Gen
        Assert-SR ([bool]$add.ok) ('[F] task attached ' + $TaskId) ([string]$add.reason)
    }

    function New-SRIntent {
        param([string]$TaskId, [long]$Rev, [string]$Key, [long]$Gen, [string]$Agent = 'coder')
        $ph = Get-NativeDispatchHash32 ('s4-prompt|' + $TaskId + '|' + $Key)
        $slot = New-OrchestrationNativeDispatchIntent -TaskId $TaskId -TaskExpectedRevision $Rev -Agent $Agent -PromptHash $ph `
            -Scope @('s4/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $Key `
            -Owner 'planner-1' -OwnershipGeneration $Gen -BaseRevision 's4-base'
        Assert-SR ([bool]$slot.ok) ('[F] intent built ' + $TaskId) ([string]$slot.reason)
        return (Get-SRValue $slot 'intent' $null)
    }

    function Invoke-SRWalk {
        param($Goal, $Intent, [string]$Agent = 'coder', $Result = $null, [string]$Child = 'ses_s4_child', [string]$Call = 'call_s4_1', [string]$Receipts = '')
        $rr = $Receipts
        if ([string]::IsNullOrWhiteSpace($rr)) { $rr = $script:srEnv.recs }
        $key = ([string](Get-SRValue $Intent 'idempotency_key' '')).Trim().ToLowerInvariant()
        $tid = ([string](Get-SRValue $Intent 'task_id' '')).Trim()
        $prep = Invoke-OrchestrationNativeDispatchPrepare -Intent $Intent -Authorization $Goal.auth -SessionId 'ses_s4_parent' `
            -ReceiptDir $rr -GoalStoreDir $script:srEnv.goals -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR ([bool]$prep.ok) ('[F] prepared ' + $tid) ([string]$prep.reason)
        $fp = ([string]$prep.prepared_fingerprint)
        $ref = ([string]$prep.reference)
        $claim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $key -Authorization $Goal.auth -SessionId 'ses_s4_parent' `
            -MessageId 'msg_s4_call' -CallId $Call -CallerAgent 'planner' -TargetAgent $Agent -PreparedFingerprint $fp `
            -ReceiptDir $rr -GoalStoreDir $script:srEnv.goals -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR (([bool]$claim.ok) -and ([bool]$claim.claimed)) ('[F] claimed ' + $tid) ([string]$claim.reason)
        $cand = $Result
        if ($null -eq $cand) { $cand = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }
        $settle = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $key -Authorization $Goal.auth -ChildSessionId $Child `
            -SessionId 'ses_s4_parent' -MessageId 'msg_s4_call' -CallId $Call -CallerAgent 'planner' -TargetAgent $Agent `
            -PreparedFingerprint $fp -Reference $ref -TaskId $tid -Result $cand -ReceiptDir $rr `
            -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR (([bool]$settle.ok) -and ([bool]$settle.settled)) ('[F] settled ' + $tid) ([string]$settle.reason)
        return [pscustomobject]@{ key = $key; task_id = $tid; evidence_id = ([string]$settle.evidence_id) }
    }

    function New-SRVerifierJson {
        param([string]$Status = 'verified_pass')
        $okFlag = ($Status -ceq 'verified_pass')
        $o = [ordered]@{
            ok = $okFlag; task_id = 's4-verifier'; status = $Status; reason = 's4 verifier read-back'
            scope = $null; profiles = @()
            evidence = @('criterion:0:artifact-bytes=12;expected-match=True', 'criterion:0:file=s4-a.txt')
            command_classes = @('test')
        }
        return (($o | ConvertTo-Json -Depth 8 -Compress))
    }

    function Invoke-SRToReviewing { param([string]$TaskId)
        $rev = Get-SRTaskRev -TaskId $TaskId
        $v = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'VALIDATING' -Actor 'planner-1' -ExpectedRevision $rev `
            -ActorIdentitySource 'explicit-cli' -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -TelemetryRoot $script:srEnv.tele
        Assert-SR ([bool]$v.ok) ('[F] validating ' + $TaskId) ([string]$v.error)
        $rev = Get-SRTaskRev -TaskId $TaskId
        $r = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'REVIEWING' -Actor 'planner-1' -ExpectedRevision $rev `
            -ActorIdentitySource 'explicit-cli' -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -TelemetryRoot $script:srEnv.tele
        Assert-SR ([bool]$r.ok) ('[F] reviewing ' + $TaskId) ([string]$r.error)
    }

    function Set-SRVerification { param([string]$TaskId, [string]$Status = 'verified_pass')
        $rev = Get-SRTaskRev -TaskId $TaskId
        $s = Set-OrchestrationTaskVerification -TaskId $TaskId -VerifierEvidenceJson (New-SRVerifierJson -Status $Status) `
            -ExpectedRevision ([int]$rev) -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR ([bool]$s.ok) ('[F] verification ' + $TaskId + ' ' + $Status) ([string]$s.error)
    }

    function Set-SRReview { param([string]$TaskId, [string]$Kind = 'reviewer', [string]$Status = 'approved', [string]$By = 'reviewer-1')
        $rev = Get-SRTaskRev -TaskId $TaskId
        $s = Set-OrchestrationTaskReview -TaskId $TaskId -Kind $Kind -Status $Status -By $By `
            -ExpectedRevision ([int]$rev) -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR ([bool]$s.ok) ('[F] review ' + $TaskId + ' ' + $Kind + '/' + $Status) ([string]$s.error)
    }

    function Invoke-SRComplete { param([string]$TaskId)
        $rev = Get-SRTaskRev -TaskId $TaskId
        $d = Complete-OrchestrationTask -TaskId $TaskId -Actor 'planner-1' -ExpectedRevision ([int]$rev) `
            -ResidualRisks @('s4-fixture-residual') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' `
            -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -TelemetryRoot $script:srEnv.tele
        Assert-SR ([bool]$d.ok) ('[F] done ' + $TaskId) ([string]$d.error)
    }

    function Update-SRProgress { param([string]$GoalId, [long]$Gen, [long]$Satisfied, [long]$Total)
        $live = Get-SRLiveGoal -GoalId $GoalId
        $u = Update-OrchestrationGoal -GoalId $GoalId -ExpectedRevision ([long]$live['revision']) `
            -Fields @{ progress = @{ satisfied = $Satisfied; total = $Total } } -StoreDir $script:srEnv.goals -OwnerId 'planner-1' -OwnershipGeneration $Gen
        Assert-SR ([bool]$u.ok) ('[F] progress ' + $GoalId) ([string]$u.reason)
    }

    function Get-SRReceipt { param([string]$GoalId, [string]$Key)
        $sub = Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $GoalId
        if ([string]::IsNullOrWhiteSpace($sub)) { return $null }
        $p = Join-Path $sub ($Key + '.json')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))) } catch { return $null }
    }

    function Get-SRReceiptPath { param([string]$GoalId, [string]$Key)
        $sub = Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $GoalId
        if ([string]::IsNullOrWhiteSpace($sub)) { return '' }
        return (Join-Path $sub ($Key + '.json'))
    }

    function Get-SRAdvanceRecord { param([string]$GoalId, [string]$Key)
        $st = Get-NDAdvanceDir -RootDir $script:srEnv.recs -GoalId $GoalId
        if (-not [bool](Get-SRValue $st 'ok' $false)) { return $null }
        $p = Join-Path ([string](Get-SRValue $st 'dir' '')) ($Key + '.advance.json')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))) } catch { return $null }
    }

    function Get-SRAdvanceDir { param([string]$GoalId)
        $st = Get-NDAdvanceDir -RootDir $script:srEnv.recs -GoalId $GoalId
        if (-not [bool](Get-SRValue $st 'ok' $false)) { return $null }
        return $st
    }

    function Get-SRRecoveryPath { param([string]$GoalId, [string]$Key)
        $st = Get-NDAdvanceDir -RootDir $script:srEnv.recs -GoalId $GoalId
        if (-not [bool](Get-SRValue $st 'ok' $false)) { return '' }
        return (Join-Path ([string](Get-SRValue $st 'dir' '')) ($Key + '.recovery.json'))
    }

    function Get-SRRecoveryRecord { param([string]$GoalId, [string]$Key)
        $p = Get-SRRecoveryPath -GoalId $GoalId -Key $Key
        if ([string]::IsNullOrWhiteSpace($p)) { return $null }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))) } catch { return $null }
    }

    function Get-SRFileHex { param([string]$Path)
        try {
            $bytes = [IO.File]::ReadAllBytes($Path)
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $h = $sha.ComputeHash($bytes)
                return (([BitConverter]::ToString($h)).Replace('-', '').ToLowerInvariant())
            }
            finally { try { $sha.Dispose() } catch { } }
        }
        catch { return '' }
    }

    function Get-SRSnapshot {
        $files = New-Object System.Collections.ArrayList
        foreach ($root in @($script:srEnv.recs, $script:srEnv.tasks, $script:srEnv.goals)) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)) {
                    $n = $f.Name
                    if (($n -like '*.recovery.json') -or ($n -like '*.lock') -or ($n -like '*.tmp') -or ($n -eq 'activations.jsonl')) { continue }
                    $h = Get-SRFileHex -Path $f.FullName
                    [void]$files.Add($f.FullName.Substring($script:srEnv.root.Length) + '|' + $h)
                }
            }
        }
        return ((@($files | Sort-Object)) -join "`n")
    }

    function Invoke-SRRecovery {
        param($GoalId, $Key, $Auth, [string]$Sub = 'ses_s4_sub', [string]$ReasonCode = 'substitute-timeout', $NextIntent = $null, [int]$LockTimeoutMs = 5000, [string]$CkptDir = '', [string]$Receipts = '', [string]$RepoRoot = '')
        $cd = $CkptDir
        if ([string]::IsNullOrWhiteSpace($cd)) { $cd = $script:srEnv.ckpts }
        $rr = $Receipts
        if ([string]::IsNullOrWhiteSpace($rr)) {
            # An explicitly forwarded RepoRoot with an omitted ReceiptDir
            # lets S4 resolve the namespace itself (F3); otherwise the
            # hermetic env default applies.
            if ((-not $PSBoundParameters.ContainsKey('Receipts')) -and (-not [string]::IsNullOrWhiteSpace($RepoRoot))) { $rr = '' }
            else { $rr = $script:srEnv.recs }
        }
        if ($null -eq $NextIntent) {
            $r = Invoke-OrchestrationSettledRecovery -GoalId $GoalId -SettledKey $Key -Authorization $Auth -SubstituteSessionId $Sub -ReasonCode $ReasonCode `
                -CheckpointDir $cd -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs -ReceiptDir $rr -RepoRoot $RepoRoot `
                -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -LockTimeoutMs $LockTimeoutMs
        }
        else {
            $r = Invoke-OrchestrationSettledRecovery -GoalId $GoalId -SettledKey $Key -Authorization $Auth -SubstituteSessionId $Sub -ReasonCode $ReasonCode -NextIntent $NextIntent `
                -CheckpointDir $cd -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs -ReceiptDir $rr -RepoRoot $RepoRoot `
                -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -LockTimeoutMs $LockTimeoutMs
        }
        Assert-SR (([int]$r.executor_calls -eq 0)) '[X] executor_calls is always 0' ('calls=' + [string]$r.executor_calls)
        return $r
    }

    function New-SRStatus { param([bool]$Completed = $false, [string[]]$Remaining = @('s4-work'))
        return @{
            objective_completed = [bool]$Completed; remaining_work = [string[]]$Remaining
            authorized = $true; blocker_kind = ''; progress_possible = $true; strategy_change = $false
            context_degraded = $false; last_failure = $null; terminal_blocker = $null; consecutive_no_progress = [long]0
        }
    }

    $script:srOrigMove = (Get-Item -Path 'function:Get-OrchestrationNextMove').ScriptBlock
    function Set-SRStubMove { param([string]$Move, [string]$Reason, [string]$Stop = '')
        $m = $Move; $r = $Reason; $s = $Stop
        Set-Item -Path 'function:Get-OrchestrationNextMove' -Value ({ param($Status) return [pscustomobject]@{ move = $m; reason = $r; stop_reason = $s; remaining_count = 1 } }.GetNewClosure())
    }
    function Restore-SRStubMove { Set-Item -Path 'function:Get-OrchestrationNextMove' -Value $script:srOrigMove }

    function Get-SRChildExe {
        try { return ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
        catch { return '' }
    }

    function Start-SRChildRecovery {
        <#
        .SYNOPSIS
            Runs one S4 recovery in a REAL external OS process.
        .DESCRIPTION
            Writes a small runner script into the hermetic temp root and
            spawns the current PowerShell executable with it. The child
            dot-sources the same libs, invokes the recovery once, and
            writes a JSON summary to its own out file. Returns the process
            handle plus paths; the caller waits via Wait-SRChildRecovery.
            Never throws: failures surface as $null result.
        #>
        [CmdletBinding()]
        param($GoalId, $Key, [string]$Owner = '', [long]$Gen = 0, [string]$Source = 'planner', [bool]$Allow = $true, [string]$Sub = 'ses_s4_sub', [string]$ReasonCode = 'substitute-timeout', [string]$Receipts = '', [int]$LockTimeoutMs = 25000, [string]$WrapMode = '', [string]$MarkDir = '', [string]$MarkTag = 'srchild')
        try {
            $tag = [guid]::NewGuid().ToString('N')
            $runner = Join-Path $script:srEnv.root ('sr-child-' + $tag + '.ps1')
            $out = Join-Path $script:srEnv.root ('sr-child-' + $tag + '.out.json')
            $allowFlag = '0'
            if ($Allow) { $allowFlag = '1' }
            $rr = $Receipts
            if ([string]::IsNullOrWhiteSpace($rr)) { $rr = $script:srEnv.recs }
            $runnerText = @'
param([string]$LibDir, [string]$GoalId, [string]$Key, [string]$Owner, [long]$Gen, [string]$Source, [string]$AllowFlag, [string]$Sub, [string]$Reason, [string]$Ckpt, [string]$Goals, [string]$Evs, [string]$Recs, [string]$Tasks, [string]$Flags, [int]$LockMs, [string]$Out)
$ErrorActionPreference = 'Stop'
. (Join-Path $LibDir 'OrchestrationGoalKernel.ps1')
. (Join-Path $LibDir 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $LibDir 'OrchestrationNativeDispatch.ps1')
. (Join-Path $LibDir 'OrchestrationTaskKernel.ps1')
. (Join-Path $LibDir 'OrchestrationAutonomousLoop.ps1')
. (Join-Path $LibDir 'OrchestrationSettledRecovery.ps1')
$script:srWrapN = 0
$wrapMode = ([string]$env:SR_WRAP_MODE).Trim().ToLowerInvariant()
if ($wrapMode -ceq 'successor') {
    $script:srOrigSucc = (Get-Item -Path 'function:Test-SRSuccessorBinding').ScriptBlock
    Set-Item -Path 'function:Test-SRSuccessorBinding' -Value {
        param([string]$ReceiptDir = '', [string]$Expected = '', [string]$GoalId = '', [string]$NextKey = '', [string]$NextTask = '', [string]$NextAgent = '', [string]$NextReference = '', [string]$IntentKey = '', [string]$IntentTask = '', [string]$IntentAgent = '', [string]$IntentFingerprint = '')
        $srR = $null
        try { $srR = & $script:srOrigSucc -ReceiptDir $ReceiptDir -Expected $Expected -GoalId $GoalId -NextKey $NextKey -NextTask $NextTask -NextAgent $NextAgent -NextReference $NextReference -IntentKey $IntentKey -IntentTask $IntentTask -IntentAgent $IntentAgent -IntentFingerprint $IntentFingerprint } catch { $srR = $null }
        $script:srWrapN++
        try {
            $srOk = 'False'
            if (($null -ne $srR) -and [bool]$srR.ok) { $srOk = 'True' }
            [IO.File]::WriteAllText((Join-Path ([string]$env:SR_MARK_DIR) ([string]$env:SR_MARK_TAG + '.succ.' + [string]$script:srWrapN)), ('ok=' + $srOk), [Text.Encoding]::UTF8)
        } catch { }
        return $srR
    }
}
if ($wrapMode -ceq 'auth') {
    $script:srOrigAuth = (Get-Item -Path 'function:Test-SRAuthorization').ScriptBlock
    Set-Item -Path 'function:Test-SRAuthorization' -Value {
        param($Authorization = $null, [string]$GoalId = '', [string]$GoalStoreDir = '')
        $arR = $null
        try { $arR = & $script:srOrigAuth -Authorization $Authorization -GoalId $GoalId -GoalStoreDir $GoalStoreDir } catch { $arR = $null }
        $script:srWrapN++
        try {
            $arOk = 'False'
            if (($null -ne $arR) -and [bool]$arR.ok) { $arOk = 'True' }
            [IO.File]::WriteAllText((Join-Path ([string]$env:SR_MARK_DIR) ([string]$env:SR_MARK_TAG + '.auth.' + [string]$script:srWrapN)), ('ok=' + $arOk), [Text.Encoding]::UTF8)
        } catch { }
        return $arR
    }
}
if ($wrapMode -ceq 'lock') {
    $script:srOrigLock = (Get-Item -Path 'function:Open-SRRecoveryLock').ScriptBlock
    Set-Item -Path 'function:Open-SRRecoveryLock' -Value {
        param([string]$AdvanceDir = '', [string]$Ident = '', [string]$Key = '', [int]$LockTimeoutMs = 5000, [ref]$RefusalReason)
        try { $lockMarkPath = Join-Path ([string]$env:SR_MARK_DIR) ([string]$env:SR_MARK_TAG + '.waiting'); [IO.File]::WriteAllText($lockMarkPath, 'waiting', [Text.Encoding]::UTF8) } catch { }
        $lrRef = [ref]''
        $lh = $null
        try { $lh = & $script:srOrigLock -AdvanceDir $AdvanceDir -Ident $Ident -Key $Key -LockTimeoutMs $LockTimeoutMs -RefusalReason $lrRef } catch { $lh = $null }
        try { if ($null -ne $RefusalReason) { $RefusalReason.Value = [string]$lrRef.Value } } catch { }
        return $lh
    }
}
try {
    $allow = ([string]$AllowFlag -ceq '1')
    $auth = @{ explicit_allow = $allow; goal_id = $GoalId; owner = $Owner; generation = [long]$Gen; source = $Source }
    $r = Invoke-OrchestrationSettledRecovery -GoalId $GoalId -SettledKey $Key -Authorization $auth -SubstituteSessionId $Sub -ReasonCode $Reason -CheckpointDir $Ckpt -GoalStoreDir $Goals -EvidenceStoreDir $Evs -ReceiptDir $Recs -TasksDir $Tasks -FlagsPath $Flags -LockTimeoutMs $LockMs
    $o = [pscustomobject]@{ ok = [bool]$r.ok; reason = ([string]$r.reason); cause = ([string]$r.cause_reason); action = ([string]$r.action); prepared = [bool]$r.prepared; fp = ([string]$r.assignment_fingerprint); next = ([string]$r.next_idempotency_key); calls = [int]$r.executor_calls }
    [IO.File]::WriteAllText($Out, ($o | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
    exit 0
}
catch {
    try { [IO.File]::WriteAllText($Out, '{"ok":false,"reason":"child-exception"}', [Text.Encoding]::UTF8) } catch { }
    exit 2
}
'@
            [IO.File]::WriteAllText($runner, $runnerText, ([Text.UTF8Encoding]::new($false)))
            $exe = Get-SRChildExe
            if ([string]::IsNullOrWhiteSpace($exe)) { return $null }
            $qArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, $PSScriptRoot, $GoalId, $Key, $Owner, ([string]$Gen), $Source, $allowFlag, $Sub, $ReasonCode, $script:srEnv.ckpts, $script:srEnv.goals, $script:srEnv.evs, $rr, $script:srEnv.tasks, $script:srEnv.flags, ([string]$LockTimeoutMs), $out)
            $flat = New-Object System.Collections.ArrayList
            foreach ($a in @($qArgs)) { [void]$flat.Add(('"' + ([string]$a).Replace('"', '""') + '"')) }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.Arguments = ($flat.ToArray() -join ' ')
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            try { [void]$psi.EnvironmentVariables.Remove('SR_WRAP_MODE') } catch { }
            try { [void]$psi.EnvironmentVariables.Remove('SR_MARK_DIR') } catch { }
            try { [void]$psi.EnvironmentVariables.Remove('SR_MARK_TAG') } catch { }
            if (-not [string]::IsNullOrWhiteSpace($WrapMode)) { $psi.EnvironmentVariables['SR_WRAP_MODE'] = ([string]$WrapMode).Trim().ToLowerInvariant() }
            if (-not [string]::IsNullOrWhiteSpace($MarkDir)) { $psi.EnvironmentVariables['SR_MARK_DIR'] = ([string]$MarkDir) }
            if (-not [string]::IsNullOrWhiteSpace($MarkTag)) { $psi.EnvironmentVariables['SR_MARK_TAG'] = ([string]$MarkTag) }
            $p = [System.Diagnostics.Process]::Start($psi)
            if ($null -eq $p) { return $null }
            return [pscustomobject]@{ process = $p; out = $out; runner = $runner }
        }
        catch { return $null }
    }

    function Wait-SRChildRecovery {
        [CmdletBinding()]
        param($Child = $null, [int]$TimeoutSec = 120)
        try {
            if ($null -eq $Child) { return $null }
            $done = $Child.process.WaitForExit([int]$TimeoutSec * 1000)
            if (-not $done) { try { $Child.process.Kill() } catch { }; return $null }
            if ($Child.process.ExitCode -ne 0) {
                if (-not (Test-Path -LiteralPath $Child.out -PathType Leaf)) { return $null }
            }
            if (-not (Test-Path -LiteralPath $Child.out -PathType Leaf)) { return $null }
            $res = $null
            try { $res = ConvertFrom-Json ([IO.File]::ReadAllText($Child.out, [Text.Encoding]::UTF8)) } catch { $res = $null }
            return $res
        }
        catch { return $null }
    }

    function Wait-SRMarker {
        <#
        .SYNOPSIS
            Barrier wait for an external process marker file (no proof by sleep).
        .DESCRIPTION
            Polls for a marker file up to a bounded timeout and returns its
            trimmed content, or $null on timeout. Ordering is proven by the
            FILE EXISTENCE (written by the other process at the intended
            program point), never by elapsed time: the poll interval is only
            latency, and expiry fails the test loudly instead of passing.
        #>
        [CmdletBinding()]
        param([string]$Path = '', [int]$TimeoutSec = 60)
        try {
            if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
            $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, [int]$TimeoutSec))
            do {
                try {
                    if (Test-Path -LiteralPath $Path -PathType Leaf) {
                        return (([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)).Trim())
                    }
                }
                catch { }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $deadline)
            return $null
        }
        catch { return $null }
    }

    try {
        # ---------- S1. prepared replay + deterministic re-entry ----------
        $ids1 = New-SRIds -Tag 'prep'
        $g1 = New-SRGoal -GoalId $ids1.goal
        New-SRTask -TaskId $ids1.task -GoalId $ids1.goal -Gen $g1.gen -Risk 'low'
        New-SRTask -TaskId $ids1.next -GoalId $ids1.goal -Gen $g1.gen -Risk 'low'
        # Crash-before-reserve: prepared stores exist, no recovery record yet.
        $key1 = Get-NativeDispatchHash32 ('s4-settled-' + $ids1.task)
        $intent1 = New-SRIntent -TaskId $ids1.task -Rev (Get-SRTaskRev -TaskId $ids1.task) -Key $key1 -Gen $g1.gen
        $walk1 = Invoke-SRWalk -Goal $g1 -Intent $intent1 -Call 'call_s4_c1'
        Invoke-SRToReviewing -TaskId $ids1.task
        Set-SRVerification -TaskId $ids1.task
        Set-SRReview -TaskId $ids1.task
        Invoke-SRComplete -TaskId $ids1.task
        Assert-SR ($null -eq (Get-SRRecoveryRecord -GoalId $ids1.goal -Key $key1)) '[S1] crash-before-reserve leaves no recovery record' ''
        $nextKey1 = Get-NativeDispatchHash32 ('s4-next-' + $ids1.next)
        $intentNext1 = New-SRIntent -TaskId $ids1.next -Rev (Get-SRTaskRev -TaskId $ids1.next) -Key $nextKey1 -Gen $g1.gen
        $sc1 = Invoke-OrchestrationSettledContinuation -GoalId $ids1.goal -SettledKey $key1 -Authorization $g1.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext1
        Assert-SR (([bool]$sc1.ok) -and [bool]$sc1.prepared) '[S1] setup continuation prepares' ([string]$sc1.reason)
        $r1 = Invoke-SRRecovery -GoalId $ids1.goal -Key $key1 -Auth $g1.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r1.ok) -and ([string]$r1.action -ceq 'replay-prepared') -and ([bool]$r1.prepared)) '[S1] prepared replay succeeds' ('action=' + [string]$r1.action + ' reason=' + [string]$r1.reason)
        Assert-SR (([string]$r1.next_idempotency_key -ceq $nextKey1) -and (-not [string]::IsNullOrWhiteSpace([string]$r1.next_reference))) '[S1] the replayed successor matches' ('key=' + [string]$r1.next_idempotency_key)
        Assert-SR (([string]$r1.cause_reason -ceq 'advance-record-replay')) '[S1] the S3a replay cause is preserved' ([string]$r1.cause_reason)
        Assert-SR (([bool]$r1.checkpoint_ok) -and (-not [string]::IsNullOrWhiteSpace([string]$r1.checkpoint_id))) '[S1] checkpoint reported' ([string]$r1.checkpoint_id)
        Assert-SR (([bool]$r1.effects.attribution_written) -and ([bool]$r1.effects.checkpoint_written) -and (-not [bool]$r1.effects.domain_mutated)) '[S1] effects account replay honestly' ''
        $rec1 = Get-SRRecoveryRecord -GoalId $ids1.goal -Key $key1
        Assert-SR (($null -ne $rec1) -and ([string]$rec1.phase -ceq 'recorded') -and ([string]$rec1.action -ceq 'replay-prepared')) '[S1] the recovery record is recorded' ''
        Assert-SR (([string]$rec1.assignment_fingerprint -ceq [string]$r1.assignment_fingerprint) -and ([string]$r1.assignment_fingerprint -match '^[a-f0-9]{32}$')) '[S1] the fingerprint is bound' ([string]$r1.assignment_fingerprint)
        Assert-SR (([string]$rec1.substitute_session_id -ceq 'ses_s4_sub_A') -and ([string]$rec1.reason_code -ceq 'substitute-timeout')) '[S1] the attribution names the substitute' ''
        Assert-SR (([string]$rec1.authorization_owner -ceq 'planner-1') -and ([long]$rec1.authorization_generation -eq $g1.gen) -and ([string]$rec1.authorization_source -ceq 'planner')) '[S1] the authorization is owner/gen/source only' ''
        $recText1 = [IO.File]::ReadAllText((Get-SRRecoveryPath -GoalId $ids1.goal -Key $key1), [Text.Encoding]::UTF8)
        Assert-SR (($recText1 -notmatch 'explicit_allow')) '[S1] no authorization secret is persisted' ''
        Assert-SR (([string]$rec1.proof_refs.evidence_id -ceq $walk1.evidence_id) -and ([string]$rec1.source_task_id -ceq $ids1.task)) '[S1] proof refs bind receipt and task' ''
        $r1b = Invoke-SRRecovery -GoalId $ids1.goal -Key $key1 -Auth $g1.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r1b.ok) -and ([string]$r1b.action -ceq 'replay-prepared') -and ([string]$r1b.assignment_fingerprint -ceq [string]$r1.assignment_fingerprint)) '[S1] the same attribution replays deterministically' ('action=' + [string]$r1b.action)
        $succCount1 = @(Get-ChildItem -LiteralPath (Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $ids1.goal) -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq ($nextKey1 + '.json') }).Count
        Assert-SR ($succCount1 -eq 1) '[S1] exactly one successor exists, no double PREPARE' ([string]$succCount1)
        $r1c = Invoke-SRRecovery -GoalId $ids1.goal -Key $key1 -Auth $g1.auth -Sub 'ses_s4_sub_B'
        Assert-SR (((-not [bool]$r1c.ok) -and ([string]$r1c.reason -ceq 'recovery-assignment-mismatch'))) '[S1] a divergent substitute is refused' ('reason=' + [string]$r1c.reason)
        $recText1b = [IO.File]::ReadAllText((Get-SRRecoveryPath -GoalId $ids1.goal -Key $key1), [Text.Encoding]::UTF8)
        Assert-SR ($recText1b -ceq $recText1) '[S1] the mismatch never overwrites' ''
        Assert-SR (($null -eq (Get-SRRecoveryPath -GoalId $ids1.goal -Key 'ffffffffffffffffffffffffffffffff') -or (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids1.goal -Key 'ffffffffffffffffffffffffffffffff'))))) '[S1] no stray record' ''

        # ---------- S2. terminal REPLAN replay, goal unmutated ----------
        $ids2 = New-SRIds -Tag 'replan'
        $g2 = New-SRGoal -GoalId $ids2.goal -Criteria @('s4-crit-a')
        New-SRTask -TaskId $ids2.task -GoalId $ids2.goal -Gen $g2.gen -Risk 'low'
        $key2 = Get-NativeDispatchHash32 ('s4-settled-' + $ids2.task)
        $intent2 = New-SRIntent -TaskId $ids2.task -Rev (Get-SRTaskRev -TaskId $ids2.task) -Key $key2 -Gen $g2.gen
        $null = Invoke-SRWalk -Goal $g2 -Intent $intent2 -Call 'call_s4_p1'
        $revBefore2 = [long]((Get-SRLiveGoal -GoalId $ids2.goal)['revision'])
        Set-SRStubMove -Move 'REPLAN' -Reason 's4-strategy-change'
        try {
            $sc2 = Invoke-OrchestrationSettledContinuation -GoalId $ids2.goal -SettledKey $key2 -Authorization $g2.auth `
                -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
                -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        }
        finally { Restore-SRStubMove }
        Assert-SR (([bool]$sc2.ok) -and ([string]$sc2.action -ceq 'replan_required')) '[S2] setup continuation records REPLAN' ([string]$sc2.reason)
        $r2 = Invoke-SRRecovery -GoalId $ids2.goal -Key $key2 -Auth $g2.auth -Sub 'ses_s4_sub_A' -ReasonCode 'operator-takeover'
        Assert-SR (([bool]$r2.ok) -and ([string]$r2.action -ceq 'replay-terminal')) '[S2] terminal REPLAN replays' ('action=' + [string]$r2.action + ' reason=' + [string]$r2.reason)
        Assert-SR (([string]$r2.cause_reason -ceq 'advance-record-replay') -and (-not [bool]$r2.prepared)) '[S2] the terminal replay cause is preserved' ([string]$r2.cause_reason)
        $liveAfter2 = Get-SRLiveGoal -GoalId $ids2.goal
        Assert-SR ((([string]$liveAfter2['state'] -ceq 'ACTIVE') -and ([long]$liveAfter2['revision'] -eq $revBefore2))) '[S2] the goal is not mutated' ([string]$liveAfter2['state'])
        $rec2 = Get-SRRecoveryRecord -GoalId $ids2.goal -Key $key2
        Assert-SR (($null -ne $rec2) -and ([string]$rec2.phase -ceq 'recorded') -and ([string]$rec2.action -ceq 'replay-terminal')) '[S2] the terminal replay is recorded' ''

        # ---------- S3. terminal BLOCKED replay ----------
        $ids3 = New-SRIds -Tag 'blocked'
        $g3 = New-SRGoal -GoalId $ids3.goal -Criteria @('s4-crit-a')
        New-SRTask -TaskId $ids3.task -GoalId $ids3.goal -Gen $g3.gen -Risk 'low'
        $key3 = Get-NativeDispatchHash32 ('s4-settled-' + $ids3.task)
        $intent3 = New-SRIntent -TaskId $ids3.task -Rev (Get-SRTaskRev -TaskId $ids3.task) -Key $key3 -Gen $g3.gen
        $null = Invoke-SRWalk -Goal $g3 -Intent $intent3 -Call 'call_s4_b1'
        $revBefore3 = [long]((Get-SRLiveGoal -GoalId $ids3.goal)['revision'])
        Set-SRStubMove -Move 'COMPLETE' -Reason 's4-human-needed' -Stop 'HUMAN_AUTHORITY_REQUIRED'
        try {
            $sc3 = Invoke-OrchestrationSettledContinuation -GoalId $ids3.goal -SettledKey $key3 -Authorization $g3.auth `
                -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
                -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        }
        finally { Restore-SRStubMove }
        $r3 = Invoke-SRRecovery -GoalId $ids3.goal -Key $key3 -Auth $g3.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r3.ok) -and ([string]$r3.action -ceq 'replay-terminal') -and (-not [bool]$r3.prepared)) '[S3] terminal BLOCKED replays' ('action=' + [string]$r3.action + ' reason=' + [string]$r3.reason)
        $liveAfter3 = Get-SRLiveGoal -GoalId $ids3.goal
        Assert-SR ((([string]$liveAfter3['state'] -ceq 'ACTIVE') -and ([long]$liveAfter3['revision'] -eq $revBefore3))) '[S3] the goal is not mutated' ([string]$liveAfter3['state'])

        # ---------- S4. COMPLETE valid via delegated CAS ----------
        $ids4 = New-SRIds -Tag 'complete'
        $g4 = New-SRGoal -GoalId $ids4.goal -Criteria @('s4-crit-a')
        New-SRTask -TaskId $ids4.task -GoalId $ids4.goal -Gen $g4.gen -Risk 'low'
        $key4 = Get-NativeDispatchHash32 ('s4-settled-' + $ids4.task)
        $intent4 = New-SRIntent -TaskId $ids4.task -Rev (Get-SRTaskRev -TaskId $ids4.task) -Key $key4 -Gen $g4.gen
        $null = Invoke-SRWalk -Goal $g4 -Intent $intent4 -Call 'call_s4_o1'
        Invoke-SRToReviewing -TaskId $ids4.task
        Set-SRVerification -TaskId $ids4.task
        Set-SRReview -TaskId $ids4.task
        Invoke-SRComplete -TaskId $ids4.task
        Update-SRProgress -GoalId $ids4.goal -Gen $g4.gen -Satisfied 1 -Total 1
        $a4 = Invoke-OrchestrationNativeDispatchAdvance -GoalId $ids4.goal -SettledKey $key4 -Authorization $g4.auth `
            -ObjectiveStatus (New-SRStatus -Completed $true -Remaining @()) -SessionId 'ses_s4_parent' `
            -ReceiptDir $script:srEnv.recs -GoalStoreDir $script:srEnv.goals -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR (([bool]$a4.ok) -and ([string]$a4.move -ceq 'COMPLETE')) '[S4] the COMPLETE decision is recorded without finalizing' ([string]$a4.reason)
        $revBefore4 = [long]((Get-SRLiveGoal -GoalId $ids4.goal)['revision'])
        $r4 = Invoke-SRRecovery -GoalId $ids4.goal -Key $key4 -Auth $g4.auth -Sub 'ses_s4_sub_A' -ReasonCode 'substitute-crash'
        Assert-SR (([bool]$r4.ok) -and ([string]$r4.action -ceq 'replay-terminal') -and ([string]$r4.reason -ceq 'objective-completed-verified')) '[S4] verified criteria complete via delegated CAS' ('reason=' + [string]$r4.reason)
        Assert-SR (([bool]$r4.effects.domain_mutated) -and ([bool]$r4.effects.attribution_written)) '[S4] the CAS effect is accounted' ''
        $liveAfter4 = Get-SRLiveGoal -GoalId $ids4.goal
        Assert-SR ((([string]$liveAfter4['state'] -ceq 'COMPLETED') -and ([long]$liveAfter4['revision'] -eq ($revBefore4 + 1)))) '[S4] a single CAS completes with revision+1' ([string]$liveAfter4['state'])
        $r4b = Invoke-SRRecovery -GoalId $ids4.goal -Key $key4 -Auth $g4.auth -Sub 'ses_s4_sub_A' -ReasonCode 'substitute-crash'
        Assert-SR (([bool]$r4b.ok) -and ([string]$r4b.action -ceq 'already-completed') -and ([string]$r4b.reason -ceq 'recovery-already-completed')) '[S4] re-entry recognizes COMPLETED without new CAS' ('action=' + [string]$r4b.action)
        $liveAfter4b = Get-SRLiveGoal -GoalId $ids4.goal
        Assert-SR ([long]$liveAfter4b['revision'] -eq ($revBefore4 + 1)) '[S4] no second succession happened' ([string]$liveAfter4b['revision'])

        # ---------- S5. COMPLETE refused without criteria, honest record ----------
        $ids5 = New-SRIds -Tag 'nounproven'
        $g5 = New-SRGoal -GoalId $ids5.goal -Criteria @('s4-crit-a')
        New-SRTask -TaskId $ids5.task -GoalId $ids5.goal -Gen $g5.gen -Risk 'low'
        $key5 = Get-NativeDispatchHash32 ('s4-settled-' + $ids5.task)
        $intent5 = New-SRIntent -TaskId $ids5.task -Rev (Get-SRTaskRev -TaskId $ids5.task) -Key $key5 -Gen $g5.gen
        $null = Invoke-SRWalk -Goal $g5 -Intent $intent5 -Call 'call_s4_u1'
        Invoke-SRToReviewing -TaskId $ids5.task
        Set-SRVerification -TaskId $ids5.task
        Set-SRReview -TaskId $ids5.task
        Invoke-SRComplete -TaskId $ids5.task
        $revBefore5 = [long]((Get-SRLiveGoal -GoalId $ids5.goal)['revision'])
        $a5 = Invoke-OrchestrationNativeDispatchAdvance -GoalId $ids5.goal -SettledKey $key5 -Authorization $g5.auth `
            -ObjectiveStatus (New-SRStatus -Completed $true -Remaining @()) -SessionId 'ses_s4_parent' `
            -ReceiptDir $script:srEnv.recs -GoalStoreDir $script:srEnv.goals -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR (([bool]$a5.ok) -and ([string]$a5.move -ceq 'COMPLETE')) '[S5] the COMPLETE decision is recorded' ([string]$a5.reason)
        $r5 = Invoke-SRRecovery -GoalId $ids5.goal -Key $key5 -Auth $g5.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$r5.ok) -and ([string]$r5.action -ceq 'blocked') -and ([string]$r5.reason -ceq 'continuation-completion-unproven'))) '[S5] unverified criteria never complete' ('reason=' + [string]$r5.reason + ' cause=' + [string]$r5.cause_reason)
        Assert-SR ((-not [bool]$r5.prepared) -and (-not [bool]$r5.effects.domain_mutated)) '[S5] the refusal has no domain effect' ''
        $liveAfter5 = Get-SRLiveGoal -GoalId $ids5.goal
        Assert-SR ((([string]$liveAfter5['state'] -ceq 'ACTIVE') -and ([long]$liveAfter5['revision'] -eq $revBefore5))) '[S5] the goal stays ACTIVE untouched' ([string]$liveAfter5['state'])
        $rec5 = Get-SRRecoveryRecord -GoalId $ids5.goal -Key $key5
        Assert-SR (($null -ne $rec5) -and ([string]$rec5.phase -ceq 'recorded') -and ([bool]$rec5.result.ok -eq $false)) '[S5] the honest refusal is recorded' ''
        Assert-SR (([string]$rec5.action -ceq 'blocked') -and ([string]$rec5.intended_action -ceq 'replay-terminal')) '[S5] the recorded action is the effective terminal envelope bound to its intent' ([string]$rec5.action + '/' + [string]$rec5.intended_action)
        $r5b = Invoke-SRRecovery -GoalId $ids5.goal -Key $key5 -Auth $g5.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$r5b.ok) -and ([string]$r5b.action -ceq 'blocked') -and ([string]$r5b.reason -ceq 'continuation-completion-unproven') -and ([string]$r5b.assignment_fingerprint -ceq [string]$r5.assignment_fingerprint))) '[S5] re-entry reproduces the recorded terminal result' ('action=' + [string]$r5b.action)

        # ---------- S6. auth/session/ownership refusals, zero write ----------
        $ids6 = New-SRIds -Tag 'auth'
        $g6 = New-SRGoal -GoalId $ids6.goal
        New-SRTask -TaskId $ids6.task -GoalId $ids6.goal -Gen $g6.gen -Risk 'low'
        $key6 = Get-NativeDispatchHash32 ('s4-settled-' + $ids6.task)
        $intent6 = New-SRIntent -TaskId $ids6.task -Rev (Get-SRTaskRev -TaskId $ids6.task) -Key $key6 -Gen $g6.gen
        $null = Invoke-SRWalk -Goal $g6 -Intent $intent6 -Call 'call_s4_a1'
        $recPath6 = Get-SRRecoveryPath -GoalId $ids6.goal -Key $key6
        $r6a = Invoke-SRRecovery -GoalId $ids6.goal -Key $key6 -Auth $null
        Assert-SR (((-not [bool]$r6a.ok) -and ([string]$r6a.reason -ceq 'recovery-authorization-denied') -and ([string]$r6a.cause_reason -ceq 'auth-goal-mismatch'))) '[S6a] absent auth is denied' ([string]$r6a.cause_reason)
        $authFalse6 = @{ explicit_allow = $false; goal_id = $ids6.goal; owner = 'planner-1'; generation = $g6.gen; source = 'planner' }
        $r6b = Invoke-SRRecovery -GoalId $ids6.goal -Key $key6 -Auth $authFalse6
        Assert-SR (((-not [bool]$r6b.ok) -and ([string]$r6b.reason -ceq 'recovery-authorization-denied'))) '[S6b] explicit_allow=false is denied' ([string]$r6b.cause_reason)
        $authCb6 = @{ explicit_allow = $true; goal_id = $ids6.goal; owner = 'planner-1'; generation = $g6.gen; source = 'test-callback' }
        $r6c = Invoke-SRRecovery -GoalId $ids6.goal -Key $key6 -Auth $authCb6
        Assert-SR (((-not [bool]$r6c.ok) -and ([string]$r6c.cause_reason -ceq 'test-callback-never-authorizes-production'))) '[S6c] test-callback never authorizes' ([string]$r6c.cause_reason)
        $authXg6 = @{ explicit_allow = $true; goal_id = 's4-other-goal'; owner = 'planner-1'; generation = $g6.gen; source = 'planner' }
        $r6d = Invoke-SRRecovery -GoalId $ids6.goal -Key $key6 -Auth $authXg6
        Assert-SR (((-not [bool]$r6d.ok) -and ([string]$r6d.reason -ceq 'recovery-authorization-denied') -and ([string]$r6d.cause_reason -ceq 'auth-goal-mismatch'))) '[S6d] cross-goal auth is denied before attribution' ([string]$r6d.cause_reason)
        $authStale6 = @{ explicit_allow = $true; goal_id = $ids6.goal; owner = 'planner-1'; generation = ($g6.gen + 99); source = 'planner' }
        $r6e = Invoke-SRRecovery -GoalId $ids6.goal -Key $key6 -Auth $authStale6
        Assert-SR (((-not [bool]$r6e.ok) -and ([string]$r6e.reason -ceq 'recovery-ownership-stale'))) '[S6e] stale generation is stale, not denied' ([string]$r6e.cause_reason)
        $r6f = Invoke-SRRecovery -GoalId $ids6.goal -Key $key6 -Auth $g6.auth -Sub ''
        Assert-SR (((-not [bool]$r6f.ok) -and ([string]$r6f.action -ceq 'invalid') -and ([string]$r6f.cause_reason -ceq 'substitute-session-invalid'))) '[S6f] an invalid substitute session is invalid' ([string]$r6f.cause_reason)
        $r6g = Invoke-SRRecovery -GoalId $ids6.goal -Key $key6 -Auth $g6.auth -ReasonCode 'force-complete'
        Assert-SR (((-not [bool]$r6g.ok) -and ([string]$r6g.cause_reason -ceq 'reason-code-unknown'))) '[S6g] an unknown reason code is invalid' ([string]$r6g.cause_reason)
        $r6h = Invoke-SRRecovery -GoalId 'INVALID GOAL!' -Key $key6 -Auth $g6.auth
        Assert-SR (((-not [bool]$r6h.ok) -and ([string]$r6h.action -ceq 'invalid'))) '[S6h] a malformed goal id is invalid' ([string]$r6h.cause_reason)
        Assert-SR (-not (Test-Path -LiteralPath $recPath6)) '[S6] no refusal wrote an attribution' ''
        $ids6x = New-SRIds -Tag 'lease'
        $g6x = New-SRGoal -GoalId $ids6x.goal
        New-SRTask -TaskId $ids6x.task -GoalId $ids6x.goal -Gen $g6x.gen -Risk 'low'
        $key6x = Get-NativeDispatchHash32 ('s4-settled-' + $ids6x.task)
        $intent6x = New-SRIntent -TaskId $ids6x.task -Rev (Get-SRTaskRev -TaskId $ids6x.task) -Key $key6x -Gen $g6x.gen
        $null = Invoke-SRWalk -Goal $g6x -Intent $intent6x -Call 'call_s4_a2'
        $renew6x = Renew-OrchestrationGoalOwnership -GoalId $ids6x.goal -OwnerId 'planner-1' -Generation $g6x.gen -StoreDir $script:srEnv.goals -LeaseTtlMs 120
        Assert-SR ([bool]$renew6x.ok) '[S6i] the lease is shortened while live' ([string]$renew6x.reason)
        Start-Sleep -Milliseconds 400
        $r6i = Invoke-SRRecovery -GoalId $ids6x.goal -Key $key6x -Auth $g6x.auth
        Assert-SR (((-not [bool]$r6i.ok) -and ([string]$r6i.reason -ceq 'recovery-ownership-stale'))) '[S6i] an expired lease is stale' ([string]$r6i.cause_reason)
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids6x.goal -Key $key6x))) '[S6i] the stale ownership wrote nothing' ''

        # ---------- S7. valid external takeover: attribution allowed ----------
        $ids7 = New-SRIds -Tag 'takeover'
        $g7 = New-SRGoal -GoalId $ids7.goal
        New-SRTask -TaskId $ids7.task -GoalId $ids7.goal -Gen $g7.gen -Risk 'low'
        New-SRTask -TaskId $ids7.next -GoalId $ids7.goal -Gen $g7.gen -Risk 'low'
        $key7 = Get-NativeDispatchHash32 ('s4-settled-' + $ids7.task)
        $intent7 = New-SRIntent -TaskId $ids7.task -Rev (Get-SRTaskRev -TaskId $ids7.task) -Key $key7 -Gen $g7.gen
        $null = Invoke-SRWalk -Goal $g7 -Intent $intent7 -Call 'call_s4_t1'
        Invoke-SRToReviewing -TaskId $ids7.task
        Set-SRVerification -TaskId $ids7.task
        Set-SRReview -TaskId $ids7.task
        Invoke-SRComplete -TaskId $ids7.task
        $nextKey7 = Get-NativeDispatchHash32 ('s4-next-' + $ids7.next)
        $intentNext7 = New-SRIntent -TaskId $ids7.next -Rev (Get-SRTaskRev -TaskId $ids7.next) -Key $nextKey7 -Gen $g7.gen
        $sc7 = Invoke-OrchestrationSettledContinuation -GoalId $ids7.goal -SettledKey $key7 -Authorization $g7.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext7
        Assert-SR (([bool]$sc7.ok) -and [bool]$sc7.prepared) '[S7] setup continuation prepares' ([string]$sc7.reason)
        $wrBefore7 = Get-OrchestrationTask -TaskId $ids7.task -TasksDir $script:srEnv.tasks
        $wrRevBefore7 = [long](Get-SRValue (Get-SRValue $wrBefore7 'worker_result' $null) 'revision' -1)
        $renew7 = Renew-OrchestrationGoalOwnership -GoalId $ids7.goal -OwnerId 'planner-1' -Generation $g7.gen -StoreDir $script:srEnv.goals -LeaseTtlMs 120
        Assert-SR ([bool]$renew7.ok) '[S7] the lease is shortened while live' ([string]$renew7.reason)
        Start-Sleep -Milliseconds 400
        $take7 = Takeover-OrchestrationGoalOwnership -GoalId $ids7.goal -OwnerId 'planner-2' -StoreDir $script:srEnv.goals
        Assert-SR ([bool]$take7.ok) '[S7] the external takeover is valid' ([string]$take7.reason)
        $gen7b = [long]$take7.ownership['generation']
        Assert-SR ($gen7b -eq ($g7.gen + 1)) '[S7] the takeover allocates predecessor+1' ([string]$gen7b)
        $auth7b = @{ explicit_allow = $true; goal_id = $ids7.goal; owner = 'planner-2'; generation = $gen7b; source = 'planner' }
        $r7 = Invoke-SRRecovery -GoalId $ids7.goal -Key $key7 -Auth $auth7b -Sub 'ses_s4_sub_take' -ReasonCode 'operator-takeover'
        Assert-SR (([bool]$r7.ok) -and ([string]$r7.action -ceq 'replay-prepared') -and ([bool]$r7.prepared)) '[S7] the new owner is attributed' ('action=' + [string]$r7.action + ' reason=' + [string]$r7.reason)
        $wrAfter7 = Get-OrchestrationTask -TaskId $ids7.task -TasksDir $script:srEnv.tasks
        Assert-SR (([long](Get-SRValue (Get-SRValue $wrAfter7 'worker_result' $null) 'revision' -1) -eq $wrRevBefore7) -and ([string](Get-SRValue $wrAfter7 'state' '') -ceq 'DONE')) '[S7] no implicit task transfer happened' ([string](Get-SRValue $wrAfter7 'state' ''))
        Assert-SR ([string]$r7.next_idempotency_key -ceq $nextKey7) '[S7] no implicit intent transfer happened' ([string]$r7.next_idempotency_key)
        $r7old = Invoke-SRRecovery -GoalId $ids7.goal -Key $key7 -Auth $g7.auth -Sub 'ses_s4_sub_take' -ReasonCode 'operator-takeover'
        Assert-SR (((-not [bool]$r7old.ok) -and ([string]$r7old.reason -ceq 'recovery-ownership-stale'))) '[S7] the predecessor token is stale after takeover' ([string]$r7old.cause_reason)

        # ---------- S8. pending advance: manual vs unproven ----------
        $ids8 = New-SRIds -Tag 'pend'
        $g8 = New-SRGoal -GoalId $ids8.goal
        New-SRTask -TaskId $ids8.task -GoalId $ids8.goal -Gen $g8.gen -Risk 'low'
        New-SRTask -TaskId $ids8.next -GoalId $ids8.goal -Gen $g8.gen -Risk 'low'
        $key8 = Get-NativeDispatchHash32 ('s4-settled-' + $ids8.task)
        $intent8 = New-SRIntent -TaskId $ids8.task -Rev (Get-SRTaskRev -TaskId $ids8.task) -Key $key8 -Gen $g8.gen
        $null = Invoke-SRWalk -Goal $g8 -Intent $intent8 -Call 'call_s4_d1'
        $nextKey8 = Get-NativeDispatchHash32 ('s4-next-' + $ids8.next)
        $advDir8 = Get-SRAdvanceDir -GoalId $ids8.goal
        $pending8 = [ordered]@{
            schema_version = 1; ok = $true; reason = ''; goal_id = $ids8.goal; settled_key = $key8
            move = 'CONTINUE'; move_reason = 's4-pending-fixture'; stop_reason = ''; prepared = $false
            next_idempotency_key = $nextKey8; next_reference = ''; next_task_id = $ids8.next; next_agent = 'coder'
            prepare_reason = ''; goal_state = 'ACTIVE'; goal_revision = 0; finalize_reason = ''
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }
        Assert-SR ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SRValue $advDir8 'dir' '')) -Ident ([string](Get-SRValue $advDir8 'ident' '')) -Key $key8 -Record $pending8)) '[S8] a pending record simulates the pre-PREPARE pause' ''
        $intentNext8 = New-SRIntent -TaskId $ids8.next -Rev (Get-SRTaskRev -TaskId $ids8.next) -Key $nextKey8 -Gen $g8.gen
        $snap8 = Get-SRSnapshot
        $r8 = Invoke-SRRecovery -GoalId $ids8.goal -Key $key8 -Auth $g8.auth -Sub 'ses_s4_sub_A' -NextIntent $intentNext8
        Assert-SR (([bool]$r8.ok) -and ([string]$r8.action -ceq 'blocked-manual') -and ([string]$r8.reason -ceq 'recovery-pending-manual-required')) '[S8] same key and same content is manual' ('reason=' + [string]$r8.reason + ' cause=' + [string]$r8.cause_reason)
        Assert-SR ((-not [bool]$r8.prepared) -and ([bool]$r8.manual_followup_required)) '[S8] manual followup is required, nothing prepared' ''
        Assert-SR (([bool]$r8.effects.attribution_written) -and (-not [bool]$r8.effects.domain_mutated) -and (-not [bool]$r8.effects.checkpoint_written)) '[S8] blocked-manual touches no domain' ''
        Assert-SR ((Get-SRSnapshot) -ceq $snap8) '[S8] domain hashes are unchanged' ''
        $rec8 = Get-SRRecoveryRecord -GoalId $ids8.goal -Key $key8
        Assert-SR (($null -ne $rec8) -and ([string]$rec8.phase -ceq 'recorded')) '[S8] the manual attribution is recorded' ''
        $ghostKey8 = Get-NativeDispatchHash32 ('s4-ghost-' + $ids8.next)
        $ghostTask8 = ('s4-ghost-task-8-' + [string]$script:srSeq)
        New-SRTask -TaskId $ghostTask8 -GoalId $ids8.goal -Gen $g8.gen -Risk 'low'
        $ghostIntent8 = New-SRIntent -TaskId $ghostTask8 -Rev (Get-SRTaskRev -TaskId $ghostTask8) -Key $ghostKey8 -Gen $g8.gen
        $r8b = Invoke-SRRecovery -GoalId $ids8.goal -Key $key8 -Auth $g8.auth -Sub 'ses_s4_sub_B' -NextIntent $ghostIntent8
        Assert-SR (((-not [bool]$r8b.ok) -and ([string]$r8b.reason -ceq 'recovery-intent-unproven'))) '[S8] same key with divergent content is unproven' ('reason=' + [string]$r8b.reason + ' cause=' + [string]$r8b.cause_reason)
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids8.goal -Key $ghostKey8))) '[S8] the divergent intent wrote no attribution' ''
        # Long suite ahead: renew the S8 goal lease while live so later
        # sections reusing this goal (S13b/S13c) test record readability,
        # not ownership expiry.
        $renewS8 = Renew-OrchestrationGoalOwnership -GoalId $ids8.goal -OwnerId 'planner-1' -Generation $g8.gen -StoreDir $script:srEnv.goals -LeaseTtlMs 600000
        Assert-SR ([bool]$renewS8.ok) '[S8] the fixture lease is renewed' ([string]$renewS8.reason)
        $ids8c = New-SRIds -Tag 'pendbare'
        $g8c = New-SRGoal -GoalId $ids8c.goal
        New-SRTask -TaskId $ids8c.task -GoalId $ids8c.goal -Gen $g8c.gen -Risk 'low'
        $key8c = Get-NativeDispatchHash32 ('s4-settled-' + $ids8c.task)
        $intent8c = New-SRIntent -TaskId $ids8c.task -Rev (Get-SRTaskRev -TaskId $ids8c.task) -Key $key8c -Gen $g8c.gen
        $null = Invoke-SRWalk -Goal $g8c -Intent $intent8c -Call 'call_s4_d2'
        $nextKey8c = Get-NativeDispatchHash32 ('s4-next-bare-' + $ids8c.task)
        $advDir8c = Get-SRAdvanceDir -GoalId $ids8c.goal
        $pending8c = [ordered]@{
            schema_version = 1; ok = $true; reason = ''; goal_id = $ids8c.goal; settled_key = $key8c
            move = 'RETRY'; move_reason = 's4-pending-bare'; stop_reason = ''; prepared = $false
            next_idempotency_key = $nextKey8c; next_reference = ''; next_task_id = ''; next_agent = ''
            prepare_reason = ''; goal_state = 'ACTIVE'; goal_revision = 0; finalize_reason = ''
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }
        Assert-SR ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SRValue $advDir8c 'dir' '')) -Ident ([string](Get-SRValue $advDir8c 'ident' '')) -Key $key8c -Record $pending8c)) '[S8] a bare pending record is stored' ''
        $r8c = Invoke-SRRecovery -GoalId $ids8c.goal -Key $key8c -Auth $g8c.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r8c.ok) -and ([string]$r8c.action -ceq 'blocked-manual') -and ([string]$r8c.cause_reason -ceq 'recovery-pending-manual-required')) '[S8] pending without NextIntent is manual' ([string]$r8c.cause_reason)
        $ids8d = New-SRIds -Tag 'nokey'
        $g8d = New-SRGoal -GoalId $ids8d.goal
        New-SRTask -TaskId $ids8d.task -GoalId $ids8d.goal -Gen $g8d.gen -Risk 'low'
        $key8d = Get-NativeDispatchHash32 ('s4-settled-' + $ids8d.task)
        $intent8d = New-SRIntent -TaskId $ids8d.task -Rev (Get-SRTaskRev -TaskId $ids8d.task) -Key $key8d -Gen $g8d.gen
        $null = Invoke-SRWalk -Goal $g8d -Intent $intent8d -Call 'call_s4_d3'
        $r8d = Invoke-SRRecovery -GoalId $ids8d.goal -Key $key8d -Auth $g8d.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$r8d.ok) -and ([string]$r8d.reason -ceq 'recovery-no-continuation') -and ([string]$r8d.action -ceq 'no-continuation'))) '[S8] an absent advance returns to the normal path' ([string]$r8d.reason)
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids8d.goal -Key $key8d))) '[S8] the normal path writes no record' ''

        # ---------- S9. receipt prepared/claimed/pending are manual ----------
        $ids9a = New-SRIds -Tag 'recprep'
        $g9a = New-SRGoal -GoalId $ids9a.goal
        New-SRTask -TaskId $ids9a.task -GoalId $ids9a.goal -Gen $g9a.gen -Risk 'low'
        $key9a = Get-NativeDispatchHash32 ('s4-settled-' + $ids9a.task)
        $intent9a = New-SRIntent -TaskId $ids9a.task -Rev (Get-SRTaskRev -TaskId $ids9a.task) -Key $key9a -Gen $g9a.gen
        $prep9a = Invoke-OrchestrationNativeDispatchPrepare -Intent $intent9a -Authorization $g9a.auth -SessionId 'ses_s4_parent' `
            -ReceiptDir $script:srEnv.recs -GoalStoreDir $script:srEnv.goals -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR ([bool]$prep9a.ok) '[S9a] handoff PREPARE lands a prepared receipt' ([string]$prep9a.reason)
        $snap9a = Get-SRSnapshot
        $r9a = Invoke-SRRecovery -GoalId $ids9a.goal -Key $key9a -Auth $g9a.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r9a.ok) -and ([string]$r9a.action -ceq 'blocked-manual') -and ([string]$r9a.cause_reason -ceq 'receipt-not-settled')) '[S9a] a prepared receipt is manual' ([string]$r9a.cause_reason)
        Assert-SR ((Get-SRSnapshot) -ceq $snap9a) '[S9a] domain hashes are unchanged' ''
        $ids9b = New-SRIds -Tag 'recclaim'
        $g9b = New-SRGoal -GoalId $ids9b.goal
        New-SRTask -TaskId $ids9b.task -GoalId $ids9b.goal -Gen $g9b.gen -Risk 'low'
        $key9b = Get-NativeDispatchHash32 ('s4-settled-' + $ids9b.task)
        $intent9b = New-SRIntent -TaskId $ids9b.task -Rev (Get-SRTaskRev -TaskId $ids9b.task) -Key $key9b -Gen $g9b.gen
        $prep9b = Invoke-OrchestrationNativeDispatchPrepare -Intent $intent9b -Authorization $g9b.auth -SessionId 'ses_s4_parent' `
            -ReceiptDir $script:srEnv.recs -GoalStoreDir $script:srEnv.goals -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR ([bool]$prep9b.ok) '[S9b] handoff PREPARE lands' ([string]$prep9b.reason)
        $claim9b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $key9b -Authorization $g9b.auth -SessionId 'ses_s4_parent' `
            -MessageId 'msg_s4_9' -CallId 'call_s4_9' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$prep9b.prepared_fingerprint) `
            -ReceiptDir $script:srEnv.recs -GoalStoreDir $script:srEnv.goals -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR (([bool]$claim9b.ok) -and ([bool]$claim9b.claimed)) '[S9b] handoff CLAIM lands' ([string]$claim9b.reason)
        $r9b = Invoke-SRRecovery -GoalId $ids9b.goal -Key $key9b -Auth $g9b.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r9b.ok) -and ([string]$r9b.action -ceq 'blocked-manual') -and ([string]$r9b.cause_reason -ceq 'receipt-claimed-ambiguous')) '[S9b] a claimed receipt is manual, never settled implicitly' ([string]$r9b.cause_reason)
        $rec9b = Get-SRRecoveryRecord -GoalId $ids9b.goal -Key $key9b
        Assert-SR (($null -ne $rec9b) -and ([string]$rec9b.result.reason -ceq 'recovery-settlement-ambiguous')) '[S9b] the ambiguous commit is recorded' ([string]$rec9b.result.reason)
        $ids9c = New-SRIds -Tag 'recpend'
        $g9c = New-SRGoal -GoalId $ids9c.goal
        New-SRTask -TaskId $ids9c.task -GoalId $ids9c.goal -Gen $g9c.gen -Risk 'low'
        $key9c = Get-NativeDispatchHash32 ('s4-settled-' + $ids9c.task)
        $intent9c = New-SRIntent -TaskId $ids9c.task -Rev (Get-SRTaskRev -TaskId $ids9c.task) -Key $key9c -Gen $g9c.gen
        $fp9c = Get-NDIntentFingerprint -Intent $intent9c
        $stuck9c = [ordered]@{ schema_version = 1; idempotency_key = $key9c; phase = 'pending'; task_id = $ids9c.task; agent = 'coder'; owner = 'planner-1'; goal_id = $ids9c.goal; ownership_generation = $g9c.gen; task_expected_revision = (Get-SRTaskRev -TaskId $ids9c.task); intent_fingerprint = $fp9c; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText((Get-SRReceiptPath -GoalId $ids9c.goal -Key $key9c), (ConvertTo-Json -InputObject $stuck9c -Compress), [Text.UTF8Encoding]::new($false))
        $r9c = Invoke-SRRecovery -GoalId $ids9c.goal -Key $key9c -Auth $g9c.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r9c.ok) -and ([string]$r9c.action -ceq 'blocked-manual') -and ([string]$r9c.cause_reason -ceq 'receipt-pending-confirm-manual')) '[S9c] a pending receipt points at manual Confirm' ([string]$r9c.cause_reason)
        $still9c = Get-SRReceipt -GoalId $ids9c.goal -Key $key9c
        Assert-SR (([string]$still9c.phase -ceq 'pending')) '[S9c] the pending receipt is untouched' ([string]$still9c.phase)

        # ---------- S10. evidence missing/illegible ----------
        $ids10a = New-SRIds -Tag 'noev'
        $g10a = New-SRGoal -GoalId $ids10a.goal
        New-SRTask -TaskId $ids10a.task -GoalId $ids10a.goal -Gen $g10a.gen -Risk 'low'
        New-SRTask -TaskId $ids10a.next -GoalId $ids10a.goal -Gen $g10a.gen -Risk 'low'
        $key10a = Get-NativeDispatchHash32 ('s4-settled-' + $ids10a.task)
        $intent10a = New-SRIntent -TaskId $ids10a.task -Rev (Get-SRTaskRev -TaskId $ids10a.task) -Key $key10a -Gen $g10a.gen
        $walk10a = Invoke-SRWalk -Goal $g10a -Intent $intent10a -Call 'call_s4_e1'
        $nextKey10a = Get-NativeDispatchHash32 ('s4-next-' + $ids10a.next)
        $intentNext10a = New-SRIntent -TaskId $ids10a.next -Rev (Get-SRTaskRev -TaskId $ids10a.next) -Key $nextKey10a -Gen $g10a.gen
        Invoke-SRToReviewing -TaskId $ids10a.task
        Set-SRVerification -TaskId $ids10a.task
        Set-SRReview -TaskId $ids10a.task
        Invoke-SRComplete -TaskId $ids10a.task
        $sc10a = Invoke-OrchestrationSettledContinuation -GoalId $ids10a.goal -SettledKey $key10a -Authorization $g10a.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext10a
        Assert-SR (([bool]$sc10a.ok) -and [bool]$sc10a.prepared) '[S10a] setup continuation prepares' ([string]$sc10a.reason)
        Remove-Item -LiteralPath (Join-Path $script:srEnv.evs ([string]$walk10a.evidence_id + '.json')) -Force -ErrorAction Stop
        $snap10a = Get-SRSnapshot
        $r10a = Invoke-SRRecovery -GoalId $ids10a.goal -Key $key10a -Auth $g10a.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r10a.ok) -and ([string]$r10a.action -ceq 'blocked-manual') -and ([string]$r10a.cause_reason -ceq 'evidence-file-missing')) '[S10a] missing evidence is manual' ([string]$r10a.cause_reason)
        Assert-SR ((Get-SRSnapshot) -ceq $snap10a) '[S10a] domain hashes are unchanged' ''
        $ids10b = New-SRIds -Tag 'badev'
        $g10b = New-SRGoal -GoalId $ids10b.goal
        New-SRTask -TaskId $ids10b.task -GoalId $ids10b.goal -Gen $g10b.gen -Risk 'low'
        New-SRTask -TaskId $ids10b.next -GoalId $ids10b.goal -Gen $g10b.gen -Risk 'low'
        $key10b = Get-NativeDispatchHash32 ('s4-settled-' + $ids10b.task)
        $intent10b = New-SRIntent -TaskId $ids10b.task -Rev (Get-SRTaskRev -TaskId $ids10b.task) -Key $key10b -Gen $g10b.gen
        $walk10b = Invoke-SRWalk -Goal $g10b -Intent $intent10b -Call 'call_s4_e2'
        $nextKey10b = Get-NativeDispatchHash32 ('s4-next-' + $ids10b.next)
        $intentNext10b = New-SRIntent -TaskId $ids10b.next -Rev (Get-SRTaskRev -TaskId $ids10b.next) -Key $nextKey10b -Gen $g10b.gen
        Invoke-SRToReviewing -TaskId $ids10b.task
        Set-SRVerification -TaskId $ids10b.task
        Set-SRReview -TaskId $ids10b.task
        Invoke-SRComplete -TaskId $ids10b.task
        $sc10b = Invoke-OrchestrationSettledContinuation -GoalId $ids10b.goal -SettledKey $key10b -Authorization $g10b.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext10b
        Assert-SR (([bool]$sc10b.ok) -and [bool]$sc10b.prepared) '[S10b] setup continuation prepares' ([string]$sc10b.reason)
        [IO.File]::AppendAllText((Join-Path $script:srEnv.evs ([string]$walk10b.evidence_id + '.json')), '}]TRAILER-CORROMPIDO', [Text.Encoding]::UTF8)
        $r10b = Invoke-SRRecovery -GoalId $ids10b.goal -Key $key10b -Auth $g10b.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r10b.ok) -and ([string]$r10b.action -ceq 'blocked-manual') -and ([string]$r10b.cause_reason -ceq 'evidence-unreadable')) '[S10b] illegible evidence is manual, never replayed' ('reason=' + [string]$r10b.reason + ' cause=' + [string]$r10b.cause_reason)
        Assert-SR (([bool]$r10b.manual_followup_required) -and (-not [bool]$r10b.effects.domain_mutated)) '[S10b] the manual attribution touches no domain' ''
        $rec10b = Get-SRRecoveryRecord -GoalId $ids10b.goal -Key $key10b
        Assert-SR (($null -ne $rec10b) -and ([string]$rec10b.phase -ceq 'recorded') -and ([bool]$rec10b.result.ok) -and ([string]$rec10b.result.reason -ceq 'recovery-settlement-ambiguous')) '[S10b] the manual attribution is recorded' ''
        $ids10c = New-SRIds -Tag 'evmm'
        $g10c = New-SRGoal -GoalId $ids10c.goal
        New-SRTask -TaskId $ids10c.task -GoalId $ids10c.goal -Gen $g10c.gen -Risk 'low'
        New-SRTask -TaskId $ids10c.next -GoalId $ids10c.goal -Gen $g10c.gen -Risk 'low'
        $key10c = Get-NativeDispatchHash32 ('s4-settled-' + $ids10c.task)
        $intent10c = New-SRIntent -TaskId $ids10c.task -Rev (Get-SRTaskRev -TaskId $ids10c.task) -Key $key10c -Gen $g10c.gen
        $walk10c = Invoke-SRWalk -Goal $g10c -Intent $intent10c -Call 'call_s4_e3'
        $nextKey10c = Get-NativeDispatchHash32 ('s4-next-' + $ids10c.next)
        $intentNext10c = New-SRIntent -TaskId $ids10c.next -Rev (Get-SRTaskRev -TaskId $ids10c.next) -Key $nextKey10c -Gen $g10c.gen
        Invoke-SRToReviewing -TaskId $ids10c.task
        Set-SRVerification -TaskId $ids10c.task
        Set-SRReview -TaskId $ids10c.task
        Invoke-SRComplete -TaskId $ids10c.task
        $sc10c = Invoke-OrchestrationSettledContinuation -GoalId $ids10c.goal -SettledKey $key10c -Authorization $g10c.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext10c
        Assert-SR (([bool]$sc10c.ok) -and [bool]$sc10c.prepared) '[S10c] setup continuation prepares' ([string]$sc10c.reason)
        $evPath10c = Join-Path $script:srEnv.evs ([string]$walk10c.evidence_id + '.json')
        $evRaw10c = ConvertFrom-Json ([IO.File]::ReadAllText($evPath10c, [Text.Encoding]::UTF8))
        $evRaw10c.run_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        [IO.File]::WriteAllText($evPath10c, (ConvertTo-Json -InputObject $evRaw10c -Depth 8 -Compress), [Text.Encoding]::UTF8)
        $r10c = Invoke-SRRecovery -GoalId $ids10c.goal -Key $key10c -Auth $g10c.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r10c.ok) -and ([string]$r10c.action -ceq 'blocked-manual') -and ([string]$r10c.cause_reason -ceq 'evidence-mismatch')) '[S10c] decorrelated evidence is manual with a precise cause' ([string]$r10c.cause_reason)

        # ---------- S11. superseded worker_result refuses, no inheritance ----------
        $ids11 = New-SRIds -Tag 'stale'
        $g11 = New-SRGoal -GoalId $ids11.goal
        New-SRTask -TaskId $ids11.task -GoalId $ids11.goal -Gen $g11.gen -Risk 'low'
        New-SRTask -TaskId $ids11.next -GoalId $ids11.goal -Gen $g11.gen -Risk 'low'
        $key11a = Get-NativeDispatchHash32 ('s4-settled-' + $ids11.task + '-k1')
        $intent11a = New-SRIntent -TaskId $ids11.task -Rev (Get-SRTaskRev -TaskId $ids11.task) -Key $key11a -Gen $g11.gen
        $null = Invoke-SRWalk -Goal $g11 -Intent $intent11a -Call 'call_s4_s1' -Result @{ status = 'failed'; claimed_evidence = @('criterion:0') }
        $nextKey11 = Get-NativeDispatchHash32 ('s4-next-' + $ids11.next)
        $intentNext11 = New-SRIntent -TaskId $ids11.next -Rev (Get-SRTaskRev -TaskId $ids11.next) -Key $nextKey11 -Gen $g11.gen
        $sc11 = Invoke-OrchestrationSettledContinuation -GoalId $ids11.goal -SettledKey $key11a -Authorization $g11.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext11
        Assert-SR (([bool]$sc11.ok) -and [bool]$sc11.prepared) '[S11] setup RETRY continuation prepares' ([string]$sc11.reason)
        $key11b = Get-NativeDispatchHash32 ('s4-settled-' + $ids11.task + '-k2')
        $intent11b = New-SRIntent -TaskId $ids11.task -Rev (Get-SRTaskRev -TaskId $ids11.task) -Key $key11b -Gen $g11.gen
        $null = Invoke-SRWalk -Goal $g11 -Intent $intent11b -Call 'call_s4_s2' -Result @{ status = 'failed'; claimed_evidence = @('criterion:0') }
        $snap11 = Get-SRSnapshot
        $r11 = Invoke-SRRecovery -GoalId $ids11.goal -Key $key11a -Auth $g11.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$r11.ok) -and ([string]$r11.reason -ceq 'recovery-settlement-ambiguous') -and ([string]$r11.cause_reason -ceq 'worker-result-superseded'))) '[S11] the old settlement never inherits the new approval' ('reason=' + [string]$r11.reason + ' cause=' + [string]$r11.cause_reason)
        Assert-SR ((Get-SRSnapshot) -ceq $snap11) '[S11] the refusal wrote nothing' ''
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids11.goal -Key $key11a))) '[S11] no attribution on superseded state' ''

        # ---------- S12. checkpoint rebuild: success and honest failure ----------
        $ids12 = New-SRIds -Tag 'ckpt'
        $g12 = New-SRGoal -GoalId $ids12.goal
        New-SRTask -TaskId $ids12.task -GoalId $ids12.goal -Gen $g12.gen -Risk 'low'
        New-SRTask -TaskId $ids12.next -GoalId $ids12.goal -Gen $g12.gen -Risk 'low'
        $key12 = Get-NativeDispatchHash32 ('s4-settled-' + $ids12.task)
        $intent12 = New-SRIntent -TaskId $ids12.task -Rev (Get-SRTaskRev -TaskId $ids12.task) -Key $key12 -Gen $g12.gen
        $null = Invoke-SRWalk -Goal $g12 -Intent $intent12 -Call 'call_s4_k1'
        Invoke-SRToReviewing -TaskId $ids12.task
        Set-SRVerification -TaskId $ids12.task
        Set-SRReview -TaskId $ids12.task
        Invoke-SRComplete -TaskId $ids12.task
        $nextKey12 = Get-NativeDispatchHash32 ('s4-next-' + $ids12.next)
        $intentNext12 = New-SRIntent -TaskId $ids12.next -Rev (Get-SRTaskRev -TaskId $ids12.next) -Key $nextKey12 -Gen $g12.gen
        $sc12 = Invoke-OrchestrationSettledContinuation -GoalId $ids12.goal -SettledKey $key12 -Authorization $g12.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext12
        Assert-SR (([bool]$sc12.ok) -and [bool]$sc12.prepared) '[S12] setup continuation prepares' ([string]$sc12.reason)
        Remove-Item -LiteralPath (Get-SRRecoveryPath -GoalId $ids12.goal -Key $key12) -Force -ErrorAction SilentlyContinue
        $script:srCkFails = 1
        $script:srCkOrig = (Get-Item -Path 'function:Save-SCContinuationCheckpoint').ScriptBlock
        Set-Item -Path 'function:Save-SCContinuationCheckpoint' -Value {
            param($Goal = $null, [string]$CheckpointDir = '', [string]$SettledKey = '', [string]$Move = '', [string]$StopReason = '', [string]$AdvanceRecordRef = '', [string]$NextIdempotencyKey = '', [string]$NextReference = '', [bool]$Prepared = $false)
            if ($script:srCkFails -gt 0) { $script:srCkFails--; return [pscustomobject][ordered]@{ ok = $false; checkpoint_id = ''; checkpoint_ok = $false } }
            return (& $script:srCkOrig -Goal $Goal -CheckpointDir $CheckpointDir -SettledKey $SettledKey -Move $Move -StopReason $StopReason -AdvanceRecordRef $AdvanceRecordRef -NextIdempotencyKey $NextIdempotencyKey -NextReference $NextReference -Prepared $Prepared)
        }
        try { $r12 = Invoke-SRRecovery -GoalId $ids12.goal -Key $key12 -Auth $g12.auth -Sub 'ses_s4_sub_A' }
        finally { Set-Item -Path 'function:Save-SCContinuationCheckpoint' -Value $script:srCkOrig }
        Assert-SR (([bool]$r12.ok) -and ([bool]$r12.prepared) -and ([bool]$r12.checkpoint_ok) -and (-not [string]::IsNullOrWhiteSpace([string]$r12.checkpoint_id))) '[S12] one rebuild from canonical records restores the checkpoint' ('ckpt=' + [string]$r12.checkpoint_id)
        $side12 = Join-Path $script:srEnv.ckpts ([string]$r12.checkpoint_id + '.settled-continuation.json')
        Assert-SR (Test-Path -LiteralPath $side12 -PathType Leaf) '[S12] the rebuild sidecar correlates' ''
        $ckptFile12 = Join-Path $tempRoot 'ckpt-is-a-file.json'
        [IO.File]::WriteAllText($ckptFile12, '{}', [Text.Encoding]::UTF8)
        $ids12b = New-SRIds -Tag 'ckptfail'
        $g12b = New-SRGoal -GoalId $ids12b.goal
        New-SRTask -TaskId $ids12b.task -GoalId $ids12b.goal -Gen $g12b.gen -Risk 'low'
        New-SRTask -TaskId $ids12b.next -GoalId $ids12b.goal -Gen $g12b.gen -Risk 'low'
        $key12b = Get-NativeDispatchHash32 ('s4-settled-' + $ids12b.task)
        $intent12b = New-SRIntent -TaskId $ids12b.task -Rev (Get-SRTaskRev -TaskId $ids12b.task) -Key $key12b -Gen $g12b.gen
        $null = Invoke-SRWalk -Goal $g12b -Intent $intent12b -Call 'call_s4_k2'
        Invoke-SRToReviewing -TaskId $ids12b.task
        Set-SRVerification -TaskId $ids12b.task
        Set-SRReview -TaskId $ids12b.task
        Invoke-SRComplete -TaskId $ids12b.task
        $nextKey12b = Get-NativeDispatchHash32 ('s4-next-' + $ids12b.next)
        $intentNext12b = New-SRIntent -TaskId $ids12b.next -Rev (Get-SRTaskRev -TaskId $ids12b.next) -Key $nextKey12b -Gen $g12b.gen
        $sc12b = Invoke-OrchestrationSettledContinuation -GoalId $ids12b.goal -SettledKey $key12b -Authorization $g12b.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext12b
        Assert-SR (([bool]$sc12b.ok) -and [bool]$sc12b.prepared) '[S12] setup continuation prepares' ([string]$sc12b.reason)
        Remove-Item -LiteralPath (Get-SRRecoveryPath -GoalId $ids12b.goal -Key $key12b) -Force -ErrorAction SilentlyContinue
        $r12b = Invoke-SRRecovery -GoalId $ids12b.goal -Key $key12b -Auth $g12b.auth -Sub 'ses_s4_sub_A' -CkptDir $ckptFile12
        Assert-SR (([bool]$r12b.ok) -and ([bool]$r12b.prepared) -and (-not [bool]$r12b.checkpoint_ok) -and ([string]$r12b.reason -ceq 'continuation-checkpoint-required')) '[S12] a failed rebuild is recorded honestly, never fabricated' ('reason=' + [string]$r12b.reason)

        # ---------- S13. corrupt and illegible records are preserved ----------
        $ids13a = New-SRIds -Tag 'corrupt'
        $g13a = New-SRGoal -GoalId $ids13a.goal
        New-SRTask -TaskId $ids13a.task -GoalId $ids13a.goal -Gen $g13a.gen -Risk 'low'
        $key13a = Get-NativeDispatchHash32 ('s4-settled-' + $ids13a.task)
        $intent13a = New-SRIntent -TaskId $ids13a.task -Rev (Get-SRTaskRev -TaskId $ids13a.task) -Key $key13a -Gen $g13a.gen
        $null = Invoke-SRWalk -Goal $g13a -Intent $intent13a -Call 'call_s4_g1'
        $advDir13a = Get-SRAdvanceDir -GoalId $ids13a.goal
        $advPath13a = Join-Path ([string](Get-SRValue $advDir13a 'dir' '')) ($key13a + '.advance.json')
        [IO.File]::WriteAllText($advPath13a, '{ truncado', [Text.Encoding]::UTF8)
        $r13a = Invoke-SRRecovery -GoalId $ids13a.goal -Key $key13a -Auth $g13a.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$r13a.ok) -and ([string]$r13a.reason -ceq 'recovery-record-uncertain') -and ([string]$r13a.cause_reason -ceq 'advance-record-unreadable'))) '[S13a] an unreadable advance record refuses' ('cause=' + [string]$r13a.cause_reason)
        Assert-SR (([IO.File]::ReadAllText($advPath13a, [Text.Encoding]::UTF8) -ceq '{ truncado')) '[S13a] the corrupted record was preserved' ''
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids13a.goal -Key $key13a))) '[S13a] no attribution on illegible state' ''
        $advPath13b = Join-Path ([string](Get-SRValue (Get-SRAdvanceDir -GoalId $ids8.goal) 'dir' '')) ($key8 + '.advance.json')
        Assert-SR (Test-Path -LiteralPath $advPath13b -PathType Leaf) '[S13b] setup holds the pending file' ''
        Remove-Item -LiteralPath $advPath13b -Force -ErrorAction Stop
        New-Item -ItemType Directory -Path $advPath13b -Force | Out-Null
        Assert-SR (Test-Path -LiteralPath $advPath13b -PathType Container) '[S13b] setup plants the directory' ''
        $r13b = Invoke-SRRecovery -GoalId $ids8.goal -Key $key8 -Auth $g8.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$r13b.ok) -and ([string]$r13b.reason -ceq 'recovery-record-uncertain'))) '[S13b] a directory at the advance path refuses' ('cause=' + [string]$r13b.cause_reason)
        Assert-SR (Test-Path -LiteralPath $advPath13b -PathType Container) '[S13b] the blocking directory was preserved' ''
        Remove-Item -LiteralPath $advPath13b -Force -ErrorAction SilentlyContinue
        $advDir8re = Get-SRAdvanceDir -GoalId $ids8.goal
        Assert-SR ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SRValue $advDir8re 'dir' '')) -Ident ([string](Get-SRValue $advDir8re 'ident' '')) -Key $key8 -Record $pending8)) '[S13b] the pending advance is restored' ''
        $recCorrupt13 = Get-SRRecoveryPath -GoalId $ids8.goal -Key $key8
        [IO.File]::WriteAllText($recCorrupt13, '{ recovery-truncado', [Text.Encoding]::UTF8)
        $r13c = Invoke-SRRecovery -GoalId $ids8.goal -Key $key8 -Auth $g8.auth -Sub 'ses_s4_sub_A' -NextIntent $intentNext8
        Assert-SR (((-not [bool]$r13c.ok) -and ([string]$r13c.reason -ceq 'recovery-record-uncertain') -and ([string]$r13c.cause_reason -ceq 'recovery-record-illegible'))) '[S13c] a corrupted recovery record refuses' ('cause=' + [string]$r13c.cause_reason)
        Assert-SR (([IO.File]::ReadAllText($recCorrupt13, [Text.Encoding]::UTF8) -ceq '{ recovery-truncado')) '[S13c] the corrupted attribution was preserved' ''
        # NOTE: $ids8/$key8 recovery record is left corrupted on purpose for
        # S13c; later sections use fresh keys only.
        $ids13d = New-SRIds -Tag 'recdir'
        $g13d = New-SRGoal -GoalId $ids13d.goal
        New-SRTask -TaskId $ids13d.task -GoalId $ids13d.goal -Gen $g13d.gen -Risk 'low'
        $key13d = Get-NativeDispatchHash32 ('s4-settled-' + $ids13d.task)
        $intent13d = New-SRIntent -TaskId $ids13d.task -Rev (Get-SRTaskRev -TaskId $ids13d.task) -Key $key13d -Gen $g13d.gen
        $null = Invoke-SRWalk -Goal $g13d -Intent $intent13d -Call 'call_s4_g2'
        $nextKey13d = Get-NativeDispatchHash32 ('s4-next-' + $ids13d.next)
        $advDir13d = Get-SRAdvanceDir -GoalId $ids13d.goal
        $pending13d = [ordered]@{
            schema_version = 1; ok = $true; reason = ''; goal_id = $ids13d.goal; settled_key = $key13d
            move = 'CONTINUE'; move_reason = 's4-recdir'; stop_reason = ''; prepared = $false
            next_idempotency_key = $nextKey13d; next_reference = ''; next_task_id = ''; next_agent = ''
            prepare_reason = ''; goal_state = 'ACTIVE'; goal_revision = 0; finalize_reason = ''
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }
        Assert-SR ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SRValue $advDir13d 'dir' '')) -Ident ([string](Get-SRValue $advDir13d 'ident' '')) -Key $key13d -Record $pending13d)) '[S13d] a pending record is stored' ''
        New-Item -ItemType Directory -Path (Get-SRRecoveryPath -GoalId $ids13d.goal -Key $key13d) -Force | Out-Null
        $r13d = Invoke-SRRecovery -GoalId $ids13d.goal -Key $key13d -Auth $g13d.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$r13d.ok) -and ([string]$r13d.reason -ceq 'recovery-record-uncertain') -and ([string]$r13d.cause_reason -ceq 'recovery-record-illegible'))) '[S13d] a blocked record path refuses without overwriting' ([string]$r13d.cause_reason)
        Assert-SR (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids13d.goal -Key $key13d) -PathType Container) '[S13d] the blocking directory was preserved' ''
        Remove-Item -LiteralPath (Get-SRRecoveryPath -GoalId $ids13d.goal -Key $key13d) -Force -ErrorAction SilentlyContinue

        # ---------- S13e. parseable-but-tampered records are rejected, never trusted ----------
        $ids13e = New-SRIds -Tag 'tamper'
        $g13e = New-SRGoal -GoalId $ids13e.goal
        New-SRTask -TaskId $ids13e.task -GoalId $ids13e.goal -Gen $g13e.gen -Risk 'low'
        New-SRTask -TaskId $ids13e.next -GoalId $ids13e.goal -Gen $g13e.gen -Risk 'low'
        $key13e = Get-NativeDispatchHash32 ('s4-settled-' + $ids13e.task)
        $intent13e = New-SRIntent -TaskId $ids13e.task -Rev (Get-SRTaskRev -TaskId $ids13e.task) -Key $key13e -Gen $g13e.gen
        $null = Invoke-SRWalk -Goal $g13e -Intent $intent13e -Call 'call_s4_g5'
        Invoke-SRToReviewing -TaskId $ids13e.task
        Set-SRVerification -TaskId $ids13e.task
        Set-SRReview -TaskId $ids13e.task
        Invoke-SRComplete -TaskId $ids13e.task
        $nextKey13e = Get-NativeDispatchHash32 ('s4-next-' + $ids13e.next)
        $intentNext13e = New-SRIntent -TaskId $ids13e.next -Rev (Get-SRTaskRev -TaskId $ids13e.next) -Key $nextKey13e -Gen $g13e.gen
        $sc13e = Invoke-OrchestrationSettledContinuation -GoalId $ids13e.goal -SettledKey $key13e -Authorization $g13e.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext13e
        Assert-SR (([bool]$sc13e.ok) -and [bool]$sc13e.prepared) '[S13e] setup continuation prepares' ([string]$sc13e.reason)
        $r13e = Invoke-SRRecovery -GoalId $ids13e.goal -Key $key13e -Auth $g13e.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r13e.ok) -and ([string]$r13e.action -ceq 'replay-prepared')) '[S13e] setup recovery records' ([string]$r13e.action)
        $recPath13e = Get-SRRecoveryPath -GoalId $ids13e.goal -Key $key13e
        $validBytes13e = [IO.File]::ReadAllText($recPath13e, [Text.Encoding]::UTF8)
        function Invoke-SRTamperCase { param([string]$Name, [scriptblock]$Mutate, [string]$Cause = 'recovery-record-illegible')
            $raw = ConvertFrom-Json $validBytes13e
            & $Mutate $raw
            $tampered = ($raw | ConvertTo-Json -Depth 12 -Compress)
            [IO.File]::WriteAllText($recPath13e, $tampered, ([Text.UTF8Encoding]::new($false)))
            $rt = Invoke-SRRecovery -GoalId $ids13e.goal -Key $key13e -Auth $g13e.auth -Sub 'ses_s4_sub_A'
            Assert-SR (((-not [bool]$rt.ok) -and ([string]$rt.reason -ceq 'recovery-record-uncertain') -and ([string]$rt.cause_reason -ceq $Cause))) ('[S13e] tampered record refused: ' + $Name) ('cause=' + [string]$rt.cause_reason)
            Assert-SR (([IO.File]::ReadAllText($recPath13e, [Text.Encoding]::UTF8) -ceq $tampered)) ('[S13e] tampered record preserved: ' + $Name) ''
            [IO.File]::WriteAllText($recPath13e, $validBytes13e, ([Text.UTF8Encoding]::new($false)))
        }
        Invoke-SRTamperCase -Name 'action-outside-closed-set' -Mutate { param($o) $o.action = 'completed' }
        Invoke-SRTamperCase -Name 'result-ok-wrong-type' -Mutate { param($o) $o.result.ok = 'yes' }
        Invoke-SRTamperCase -Name 'effects-array-collapse' -Mutate { param($o) $o.result.effects.domain_mutated = @($true) }
        Invoke-SRTamperCase -Name 'next-key-swapped' -Mutate { param($o) $o.proof_refs.next_key = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
        Invoke-SRTamperCase -Name 'fingerprint-replaced' -Mutate { param($o) $o.assignment_fingerprint = 'ffffffffffffffffffffffffffffffff' }
        Invoke-SRTamperCase -Name 'evidence-unbound' -Mutate { param($o) $o.proof_refs.evidence_id = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
        Invoke-SRTamperCase -Name 'action-swapped-to-permitted' -Mutate { param($o) $o.action = 'blocked-manual' }
        Invoke-SRTamperCase -Name 'intended-action-swapped' -Mutate { param($o) $o.intended_action = 'replay-terminal' }
        $r13eB = Invoke-SRRecovery -GoalId $ids13e.goal -Key $key13e -Auth $g13e.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r13eB.ok) -and ([string]$r13eB.action -ceq 'replay-prepared') -and ([string]$r13eB.assignment_fingerprint -ceq [string]$r13e.assignment_fingerprint)) '[S13e] the restored record replays deterministically' ('ok=' + [string]$r13eB.ok + ' action=' + [string]$r13eB.action + ' reason=' + [string]$r13eB.reason + ' cause=' + [string]$r13eB.cause_reason)

        # ---------- S13f. publish disambiguation: published vs uncertain vs absent ----------
        $advDir13f = Get-SRAdvanceDir -GoalId $ids13e.goal
        $advPath13f = ([string](Get-SRValue $advDir13f 'dir' ''))
        $advIdent13f = ([string](Get-SRValue $advDir13f 'ident' ''))
        $stored13f = ConvertFrom-Json $validBytes13e
        $storedFp13f = ([string](Get-SRValue $stored13f 'assignment_fingerprint' '')).Trim()
        $pubAgain13f = Publish-SRRecoveryRecord -AdvanceDir $advPath13f -Ident $advIdent13f -Key $key13e -Record $stored13f -ExpectedFingerprint $storedFp13f
        Assert-SR (($pubAgain13f -ceq 'published')) '[S13f] an already-effected publication reports published, never rewrites' ([string]$pubAgain13f)
        Assert-SR (([IO.File]::ReadAllText($recPath13e, [Text.Encoding]::UTF8) -ceq $validBytes13e)) '[S13f] the disambiguation proof left the record untouched' ''
        $divergent13f = ConvertFrom-Json $validBytes13e
        $divergent13f.assignment_fingerprint = 'dddddddddddddddddddddddddddddddd'
        $pubDiv13f = Publish-SRRecoveryRecord -AdvanceDir $advPath13f -Ident $advIdent13f -Key $key13e -Record $divergent13f -ExpectedFingerprint 'dddddddddddddddddddddddddddddddd'
        Assert-SR (($pubDiv13f -ceq 'uncertain')) '[S13f] a divergent fingerprint is uncertain, never presumed' ([string]$pubDiv13f)
        Assert-SR (([IO.File]::ReadAllText($recPath13e, [Text.Encoding]::UTF8) -ceq $validBytes13e)) '[S13f] the uncertain outcome preserved the stored record' ''
        $pubAbsent13f = Publish-SRRecoveryRecord -AdvanceDir (Join-Path $tempRoot 'adv-missing-13f') -Ident 'bogus-ident' -Key $key13e -Record $divergent13f -ExpectedFingerprint 'dddddddddddddddddddddddddddddddd'
        Assert-SR (($pubAbsent13f -ceq 'absent')) '[S13f] a failed publish with verified absence reports absent' ([string]$pubAbsent13f)

        # ---------- S14. crash window: reserved re-executes, divergent holds ----------
        $ids14 = New-SRIds -Tag 'crash'
        $g14 = New-SRGoal -GoalId $ids14.goal
        New-SRTask -TaskId $ids14.task -GoalId $ids14.goal -Gen $g14.gen -Risk 'low'
        New-SRTask -TaskId $ids14.next -GoalId $ids14.goal -Gen $g14.gen -Risk 'low'
        $key14 = Get-NativeDispatchHash32 ('s4-settled-' + $ids14.task)
        $intent14 = New-SRIntent -TaskId $ids14.task -Rev (Get-SRTaskRev -TaskId $ids14.task) -Key $key14 -Gen $g14.gen
        $walk14 = Invoke-SRWalk -Goal $g14 -Intent $intent14 -Call 'call_s4_r1'
        Invoke-SRToReviewing -TaskId $ids14.task
        Set-SRVerification -TaskId $ids14.task
        Set-SRReview -TaskId $ids14.task
        Invoke-SRComplete -TaskId $ids14.task
        $nextKey14 = Get-NativeDispatchHash32 ('s4-next-' + $ids14.next)
        $intentNext14 = New-SRIntent -TaskId $ids14.next -Rev (Get-SRTaskRev -TaskId $ids14.next) -Key $nextKey14 -Gen $g14.gen
        $sc14 = Invoke-OrchestrationSettledContinuation -GoalId $ids14.goal -SettledKey $key14 -Authorization $g14.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext14
        Assert-SR (([bool]$sc14.ok) -and [bool]$sc14.prepared) '[S14] setup continuation prepares' ([string]$sc14.reason)
        Remove-Item -LiteralPath (Get-SRRecoveryPath -GoalId $ids14.goal -Key $key14) -Force -ErrorAction SilentlyContinue
        $adv14 = Get-SRAdvanceRecord -GoalId $ids14.goal -Key $key14
        $rec14raw = Get-SRReceipt -GoalId $ids14.goal -Key $key14
        $rDir14 = Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $ids14.goal
        $origSess14 = ([string](Get-SRValue $rec14raw 'settle_session_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($origSess14)) { $origSess14 = ([string](Get-SRValue $rec14raw 'claim_session_id' '')).Trim() }
        $evId14 = ([string](Get-SRValue $rec14raw 'settle_evidence_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($evId14)) { $evId14 = ([string](Get-SRValue $rec14raw 'evidence_id' '')).Trim() }
        $recExp14 = [long](Get-SRValue $rec14raw 'task_expected_revision' -1)
        $fp14 = Get-SRAssignmentFingerprint -SubstituteSessionId 'ses_s4_sub_crash' -Owner 'planner-1' -Generation $g14.gen -Source 'planner' `
            -Action 'replay-prepared' -ReasonCode 'substitute-crash' -GoalId $ids14.goal -SettledKey $key14 -SourceTaskId $ids14.task `
            -ReceiptRef (Join-Path $rDir14 ($key14 + '.json')) -EvidenceId $evId14 -CandidateRevision $recExp14 `
            -NextKey ([string](Get-SRValue $adv14 'next_idempotency_key' '')) -NextIntentFingerprint '' -OriginalPrepareSessionId $origSess14
        Assert-SR ($fp14 -match '^[a-f0-9]{32}$') '[S14] the crash fingerprint derives deterministically' $fp14
        $advDir14 = Get-SRAdvanceDir -GoalId $ids14.goal
        $reserved14 = [ordered]@{
            schema_version = 1; goal_id = $ids14.goal; settled_key = $key14; source_task_id = $ids14.task
            assignment_fingerprint = $fp14; substitute_session_id = 'ses_s4_sub_crash'
            authorization_owner = 'planner-1'; authorization_generation = [long]$g14.gen; authorization_source = 'planner'
            reason_code = 'substitute-crash'; action = 'replay-prepared'; intended_action = 'replay-prepared'
            proof_refs = [ordered]@{ receipt = (Join-Path $rDir14 ($key14 + '.json')); advance = (Join-Path ([string](Get-SRValue $advDir14 'dir' '')) ($key14 + '.advance.json')); evidence_id = $evId14; candidate_revision = [long]$recExp14; next_key = ([string](Get-SRValue $adv14 'next_idempotency_key' '')); next_intent_fingerprint = ''; original_prepare_session_id = $origSess14 }
            phase = 'reserved'
            result = [ordered]@{ ok = $false; reason = 'recovery-reserved'; cause_reason = 'reserved-before-replay'; prepared = $false; next_idempotency_key = ''; next_reference = ''; checkpoint_id = ''; checkpoint_ok = $false; effects = [ordered]@{ domain_mutated = $false; attribution_written = $true; checkpoint_written = $false } }
            created_at = ([DateTime]::UtcNow.ToString('o')); recorded_at = ''
        }
        Assert-SR ([bool](Write-SRRecoveryRecord -AdvanceDir ([string](Get-SRValue $advDir14 'dir' '')) -Ident ([string](Get-SRValue $advDir14 'ident' '')) -Key $key14 -Record $reserved14)) '[S14] a reserved record simulates the crash' ''
        $r14 = Invoke-SRRecovery -GoalId $ids14.goal -Key $key14 -Auth $g14.auth -Sub 'ses_s4_sub_crash' -ReasonCode 'substitute-crash'
        Assert-SR (([bool]$r14.ok) -and ([string]$r14.action -ceq 'replay-prepared') -and ([string]$r14.assignment_fingerprint -ceq $fp14)) '[S14] reserved with the same attribution completes' ('action=' + [string]$r14.action)
        $rec14 = Get-SRRecoveryRecord -GoalId $ids14.goal -Key $key14
        Assert-SR (([string]$rec14.phase -ceq 'recorded')) '[S14] the crash resolves to recorded, never presumed' ''
        $fp14div = Get-SRAssignmentFingerprint -SubstituteSessionId 'ses_s4_sub_other' -Owner 'planner-1' -Generation $g14.gen -Source 'planner' `
            -Action 'replay-prepared' -ReasonCode 'substitute-crash' -GoalId $ids14.goal -SettledKey $key14 -SourceTaskId $ids14.task `
            -ReceiptRef (Join-Path $rDir14 ($key14 + '.json')) -EvidenceId $evId14 -CandidateRevision $recExp14 `
            -NextKey ([string](Get-SRValue $adv14 'next_idempotency_key' '')) -NextIntentFingerprint '' -OriginalPrepareSessionId $origSess14
        Assert-SR ($fp14div -cne $fp14) '[S14] a different substitute fingerprints differently' ''
        $reservedDiv = [ordered]@{
            schema_version = 1; goal_id = $ids14.goal; settled_key = $key14; source_task_id = $ids14.task
            assignment_fingerprint = $fp14div; substitute_session_id = 'ses_s4_sub_other'
            authorization_owner = 'planner-1'; authorization_generation = [long]$g14.gen; authorization_source = 'planner'
            reason_code = 'substitute-crash'; action = 'replay-prepared'
            proof_refs = [ordered]@{ receipt = (Join-Path $rDir14 ($key14 + '.json')); advance = ''; evidence_id = $evId14; candidate_revision = [long]$recExp14; next_key = ''; next_intent_fingerprint = ''; original_prepare_session_id = $origSess14 }
            phase = 'reserved'
            result = [ordered]@{ ok = $false; reason = 'recovery-reserved'; cause_reason = 'reserved-before-replay'; prepared = $false; next_reference = ''; checkpoint_id = ''; checkpoint_ok = $false; effects = [ordered]@{ domain_mutated = $false; attribution_written = $true; checkpoint_written = $false } }
            created_at = ([DateTime]::UtcNow.ToString('o')); recorded_at = ''
        }
        $textBeforeDiv = [IO.File]::ReadAllText((Get-SRRecoveryPath -GoalId $ids14.goal -Key $key14), [Text.Encoding]::UTF8)
        Assert-SR (-not (Write-SRRecoveryRecord -AdvanceDir ([string](Get-SRValue $advDir14 'dir' '')) -Ident ([string](Get-SRValue $advDir14 'ident' '')) -Key $key14 -Record $reservedDiv -AllowReservedUpdate -ExpectedFingerprint $fp14div)) '[S14] a divergent reserve never overwrites recorded' ''
        Assert-SR (([IO.File]::ReadAllText((Get-SRRecoveryPath -GoalId $ids14.goal -Key $key14), [Text.Encoding]::UTF8) -ceq $textBeforeDiv)) '[S14] the recorded result survives the divergent reserve' ''

        # ---------- S15. two processes: contention refuses busy ----------
        $ids15 = New-SRIds -Tag 'lock'
        $g15 = New-SRGoal -GoalId $ids15.goal
        New-SRTask -TaskId $ids15.task -GoalId $ids15.goal -Gen $g15.gen -Risk 'low'
        $key15 = Get-NativeDispatchHash32 ('s4-settled-' + $ids15.task)
        $intent15 = New-SRIntent -TaskId $ids15.task -Rev (Get-SRTaskRev -TaskId $ids15.task) -Key $key15 -Gen $g15.gen
        $null = Invoke-SRWalk -Goal $g15 -Intent $intent15 -Call 'call_s4_l1'
        Invoke-SRToReviewing -TaskId $ids15.task
        Set-SRVerification -TaskId $ids15.task
        Set-SRReview -TaskId $ids15.task
        Invoke-SRComplete -TaskId $ids15.task
        $nextKey15 = Get-NativeDispatchHash32 ('s4-next-' + $ids15.task + '-n')
        New-SRTask -TaskId ($ids15.task + '-n') -GoalId $ids15.goal -Gen $g15.gen -Risk 'low'
        $intentNext15 = New-SRIntent -TaskId ($ids15.task + '-n') -Rev (Get-SRTaskRev -TaskId ($ids15.task + '-n')) -Key $nextKey15 -Gen $g15.gen
        $sc15 = Invoke-OrchestrationSettledContinuation -GoalId $ids15.goal -SettledKey $key15 -Authorization $g15.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext15
        Assert-SR (([bool]$sc15.ok) -and [bool]$sc15.prepared) '[S15] setup continuation prepares' ([string]$sc15.reason)
        Remove-Item -LiteralPath (Get-SRRecoveryPath -GoalId $ids15.goal -Key $key15) -Force -ErrorAction SilentlyContinue
        $advDir15 = Get-SRAdvanceDir -GoalId $ids15.goal
        $lockPath15 = Join-Path ([string](Get-SRValue $advDir15 'dir' '')) ('.recovery-' + $key15 + '.lock')
        $held15 = $null
        try {
            $held15 = [IO.File]::Open($lockPath15, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $r15 = Invoke-SRRecovery -GoalId $ids15.goal -Key $key15 -Auth $g15.auth -Sub 'ses_s4_sub_A' -LockTimeoutMs 200
            Assert-SR (((-not [bool]$r15.ok) -and ([string]$r15.reason -ceq 'recovery-lock-busy'))) '[S15] a held recovery lock refuses busy' ([string]$r15.cause_reason)
            Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids15.goal -Key $key15))) '[S15] the busy contention wrote nothing' ''
        }
        finally { try { if ($null -ne $held15) { $held15.Dispose() } } catch { } }
        $r15b = Invoke-SRRecovery -GoalId $ids15.goal -Key $key15 -Auth $g15.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$r15b.ok) -and ([string]$r15b.action -ceq 'replay-prepared')) '[S15] after release the same attribution proceeds' ([string]$r15b.action)

        # ---------- S16. adversarial: removal, swap, downgrade ----------
        $ids16 = New-SRIds -Tag 'advers'
        $g16 = New-SRGoal -GoalId $ids16.goal
        New-SRTask -TaskId $ids16.task -GoalId $ids16.goal -Gen $g16.gen -Risk 'low'
        New-SRTask -TaskId $ids16.next -GoalId $ids16.goal -Gen $g16.gen -Risk 'low'
        $key16 = Get-NativeDispatchHash32 ('s4-settled-' + $ids16.task)
        $intent16 = New-SRIntent -TaskId $ids16.task -Rev (Get-SRTaskRev -TaskId $ids16.task) -Key $key16 -Gen $g16.gen
        $null = Invoke-SRWalk -Goal $g16 -Intent $intent16 -Call 'call_s4_v1'
        Invoke-SRToReviewing -TaskId $ids16.task
        Set-SRVerification -TaskId $ids16.task
        Set-SRReview -TaskId $ids16.task
        Invoke-SRComplete -TaskId $ids16.task
        $nextKey16 = Get-NativeDispatchHash32 ('s4-next-' + $ids16.next)
        $intentNext16 = New-SRIntent -TaskId $ids16.next -Rev (Get-SRTaskRev -TaskId $ids16.next) -Key $nextKey16 -Gen $g16.gen
        $sc16 = Invoke-OrchestrationSettledContinuation -GoalId $ids16.goal -SettledKey $key16 -Authorization $g16.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext16
        Assert-SR (([bool]$sc16.ok) -and [bool]$sc16.prepared) '[S16] setup continuation prepares' ([string]$sc16.reason)
        Remove-Item -LiteralPath (Get-SRRecoveryPath -GoalId $ids16.goal -Key $key16) -Force -ErrorAction SilentlyContinue
        $recPath16 = Get-SRReceiptPath -GoalId $ids16.goal -Key $key16
        $recCountBefore16 = @(Get-ChildItem -LiteralPath (Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $ids16.goal) -Filter '*.json' -ErrorAction SilentlyContinue).Count
        Remove-Item -LiteralPath $recPath16 -Force -ErrorAction Stop
        $r16 = Invoke-SRRecovery -GoalId $ids16.goal -Key $key16 -Auth $g16.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$r16.ok) -and ([string]$r16.reason -ceq 'recovery-record-uncertain') -and ([string]$r16.cause_reason -like 'advance-without-settlement*'))) '[S16] a removed receipt refuses without fallback creation' ([string]$r16.cause_reason)
        $recCountAfter16 = @(Get-ChildItem -LiteralPath (Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $ids16.goal) -Filter '*.json' -ErrorAction SilentlyContinue).Count
        Assert-SR ($recCountAfter16 -eq ($recCountBefore16 - 1)) '[S16] no receipt was created as fallback' ([string]$recCountAfter16)
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $ids16.goal -Key $key16))) '[S16] the removal wrote no attribution' ''
        $ids16d = New-SRIds -Tag 'donor'
        $g16d = New-SRGoal -GoalId $ids16d.goal
        New-SRTask -TaskId $ids16d.task -GoalId $ids16d.goal -Gen $g16d.gen -Risk 'low'
        $key16d = Get-NativeDispatchHash32 ('s4-settled-' + $ids16d.task)
        $intent16d = New-SRIntent -TaskId $ids16d.task -Rev (Get-SRTaskRev -TaskId $ids16d.task) -Key $key16d -Gen $g16d.gen
        $null = Invoke-SRWalk -Goal $g16d -Intent $intent16d -Call 'call_s4_v0'
        $donorPath16 = Get-SRReceiptPath -GoalId $ids16d.goal -Key $key16d
        $donorText16 = [IO.File]::ReadAllText($donorPath16, [Text.Encoding]::UTF8)
        $donorHash16 = Get-SRFileHex -Path $donorPath16
        $ids16b = New-SRIds -Tag 'swapp'
        $g16b = New-SRGoal -GoalId $ids16b.goal
        $key16b = Get-NativeDispatchHash32 ('s4-settled-' + $ids16b.task)
        # Isolated receipt root: the swapped file must never poison the
        # shared root scan (fail-closed CLAIM would refuse later fixtures).
        $recs16b = Join-Path $tempRoot 'recs-swap'
        New-Item -ItemType Directory -Path $recs16b -Force | Out-Null
        $sub16b = Get-NDGoalReceiptDir -RootDir $recs16b -GoalId $ids16b.goal
        $advDir16b = Get-NDAdvanceDir -RootDir $recs16b -GoalId $ids16b.goal
        [void](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SRValue $advDir16b 'dir' '')) -Ident ([string](Get-SRValue $advDir16b 'ident' '')) -Key $key16b -Record ([ordered]@{
            schema_version = 1; ok = $true; reason = ''; goal_id = $ids16b.goal; settled_key = $key16b
            move = 'CONTINUE'; move_reason = 's4-swap-target'; stop_reason = ''; prepared = $true
            next_idempotency_key = $nextKey16; next_reference = 'ref_s4_swap'; next_task_id = ''; next_agent = ''
            prepare_reason = ''; goal_state = 'ACTIVE'; goal_revision = 0; finalize_reason = ''
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }))
        $swapped16 = $donorText16.Replace($key16d, $key16b).Replace($ids16d.goal, $ids16b.goal)
        [IO.File]::WriteAllText((Join-Path $sub16b ($key16b + '.json')), $swapped16, [Text.Encoding]::UTF8)
        $r16b = Invoke-SRRecovery -GoalId $ids16b.goal -Key $key16b -Auth $g16b.auth -Sub 'ses_s4_sub_A' -Receipts $recs16b
        Assert-SR (((-not [bool]$r16b.ok) -and ([string]$r16b.reason -ceq 'recovery-record-uncertain') -and ([string]$r16b.cause_reason -ceq 'receipt-integrity-invalid'))) '[S16] a swapped receipt refuses on integrity' ('reason=' + [string]$r16b.reason + ' cause=' + [string]$r16b.cause_reason)
        $advState16b = Get-NDAdvanceDir -RootDir $recs16b -GoalId $ids16b.goal
        Assert-SR (-not (Test-Path -LiteralPath (Join-Path ([string](Get-SRValue $advState16b 'dir' '')) ($key16b + '.recovery.json')))) '[S16] the swap wrote no attribution in the target goal' ''
        Assert-SR ((Get-SRFileHex -Path $donorPath16) -ceq $donorHash16) '[S16] the donor goal is untouched' ''
        $ids16c = New-SRIds -Tag 'downgr'
        $g16c = New-SRGoal -GoalId $ids16c.goal
        New-SRTask -TaskId $ids16c.task -GoalId $ids16c.goal -Gen $g16c.gen -Risk 'low'
        New-SRTask -TaskId $ids16c.next -GoalId $ids16c.goal -Gen $g16c.gen -Risk 'low'
        $key16c = Get-NativeDispatchHash32 ('s4-settled-' + $ids16c.task)
        $intent16c = New-SRIntent -TaskId $ids16c.task -Rev (Get-SRTaskRev -TaskId $ids16c.task) -Key $key16c -Gen $g16c.gen
        $null = Invoke-SRWalk -Goal $g16c -Intent $intent16c -Call 'call_s4_v3'
        Invoke-SRToReviewing -TaskId $ids16c.task
        Set-SRVerification -TaskId $ids16c.task
        Set-SRReview -TaskId $ids16c.task
        Invoke-SRComplete -TaskId $ids16c.task
        $nextKey16c = Get-NativeDispatchHash32 ('s4-next-' + $ids16c.next)
        $intentNext16c = New-SRIntent -TaskId $ids16c.next -Rev (Get-SRTaskRev -TaskId $ids16c.next) -Key $nextKey16c -Gen $g16c.gen
        $sc16c = Invoke-OrchestrationSettledContinuation -GoalId $ids16c.goal -SettledKey $key16c -Authorization $g16c.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNext16c
        Assert-SR (([bool]$sc16c.ok) -and [bool]$sc16c.prepared) '[S16] setup continuation prepares' ([string]$sc16c.reason)
        Remove-Item -LiteralPath (Get-SRRecoveryPath -GoalId $ids16c.goal -Key $key16c) -Force -ErrorAction SilentlyContinue
        $succPath16c = Get-SRReceiptPath -GoalId $ids16c.goal -Key $nextKey16c
        $succHash16c = Get-SRFileHex -Path $succPath16c
        $advDir16c = Get-SRAdvanceDir -GoalId $ids16c.goal
        $downgraded16c = [ordered]@{
            schema_version = 1; ok = $true; reason = ''; goal_id = $ids16c.goal; settled_key = $key16c
            move = 'CONTINUE'; move_reason = 's4-downgrade-attack'; stop_reason = ''; prepared = $false
            next_idempotency_key = $nextKey16c; next_reference = ''; next_task_id = $ids16c.next; next_agent = 'coder'
            prepare_reason = ''; goal_state = 'ACTIVE'; goal_revision = 0; finalize_reason = ''
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }
        Assert-SR ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SRValue $advDir16c 'dir' '')) -Ident ([string](Get-SRValue $advDir16c 'ident' '')) -Key $key16c -Record $downgraded16c)) '[S16] a downgraded advance simulates tampering' ''
        $r16c = Invoke-SRRecovery -GoalId $ids16c.goal -Key $key16c -Auth $g16c.auth -Sub 'ses_s4_sub_A' -NextIntent $intentNext16c
        Assert-SR (([bool]$r16c.ok) -and ([string]$r16c.action -ceq 'blocked-manual') -and (-not [bool]$r16c.prepared)) '[S16] a downgraded advance is manual, never replayed as prepared' ([string]$r16c.reason)
        Assert-SR ((Get-SRFileHex -Path $succPath16c) -ceq $succHash16c) '[S16] the recorded successor is untouched' ''

        # ---------- F1a. post-lock takeover refuses without writes ----------
        $idsF1a = New-SRIds -Tag 'postlock'
        $gF1a = New-SRGoal -GoalId $idsF1a.goal
        New-SRTask -TaskId $idsF1a.task -GoalId $idsF1a.goal -Gen $gF1a.gen -Risk 'low'
        New-SRTask -TaskId $idsF1a.next -GoalId $idsF1a.goal -Gen $gF1a.gen -Risk 'low'
        $keyF1a = Get-NativeDispatchHash32 ('s4-settled-' + $idsF1a.task)
        $intentF1a = New-SRIntent -TaskId $idsF1a.task -Rev (Get-SRTaskRev -TaskId $idsF1a.task) -Key $keyF1a -Gen $gF1a.gen
        $null = Invoke-SRWalk -Goal $gF1a -Intent $intentF1a -Call 'call_s4_q1'
        Invoke-SRToReviewing -TaskId $idsF1a.task
        Set-SRVerification -TaskId $idsF1a.task
        Set-SRReview -TaskId $idsF1a.task
        Invoke-SRComplete -TaskId $idsF1a.task
        $nextKeyF1a = Get-NativeDispatchHash32 ('s4-next-' + $idsF1a.next)
        $intentNextF1a = New-SRIntent -TaskId $idsF1a.next -Rev (Get-SRTaskRev -TaskId $idsF1a.next) -Key $nextKeyF1a -Gen $gF1a.gen
        $scF1a = Invoke-OrchestrationSettledContinuation -GoalId $idsF1a.goal -SettledKey $keyF1a -Authorization $gF1a.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF1a
        Assert-SR (([bool]$scF1a.ok) -and [bool]$scF1a.prepared) '[F1a] setup continuation prepares' ([string]$scF1a.reason)
        $rF1a = Invoke-SRRecovery -GoalId $idsF1a.goal -Key $keyF1a -Auth $gF1a.auth -Sub 'ses_s4_sub_f1a'
        Assert-SR (([bool]$rF1a.ok) -and ([string]$rF1a.action -ceq 'replay-prepared')) '[F1a] first recovery replays while the lease is live' ([string]$rF1a.action)
        $recTextF1a = [IO.File]::ReadAllText((Get-SRRecoveryPath -GoalId $idsF1a.goal -Key $keyF1a), [Text.Encoding]::UTF8)
        $ckptCountF1a = @(Get-ChildItem -LiteralPath $script:srEnv.ckpts -File -ErrorAction SilentlyContinue).Count
        $renewF1a = Renew-OrchestrationGoalOwnership -GoalId $idsF1a.goal -OwnerId 'planner-1' -Generation $gF1a.gen -StoreDir $script:srEnv.goals -LeaseTtlMs 200
        Assert-SR ([bool]$renewF1a.ok) '[F1a] the lease is shortened while live' ([string]$renewF1a.reason)
        Start-Sleep -Milliseconds 600
        $takeF1a = Takeover-OrchestrationGoalOwnership -GoalId $idsF1a.goal -OwnerId 'planner-2' -StoreDir $script:srEnv.goals
        Assert-SR ([bool]$takeF1a.ok) '[F1a] an external takeover lands' ([string]$takeF1a.reason)
        $revAfterTakeF1a = [long]((Get-SRLiveGoal -GoalId $idsF1a.goal)['revision'])
        $rF1a2 = Invoke-SRRecovery -GoalId $idsF1a.goal -Key $keyF1a -Auth $gF1a.auth -Sub 'ses_s4_sub_f1a'
        Assert-SR (((-not [bool]$rF1a2.ok) -and ([string]$rF1a2.reason -ceq 'recovery-ownership-stale'))) '[F1a] post-lock revalidation refuses the stale token' ('cause=' + [string]$rF1a2.cause_reason)
        Assert-SR (([IO.File]::ReadAllText((Get-SRRecoveryPath -GoalId $idsF1a.goal -Key $keyF1a), [Text.Encoding]::UTF8) -ceq $recTextF1a)) '[F1a] the recorded result is byte-identical' ''
        Assert-SR (@(Get-ChildItem -LiteralPath $script:srEnv.ckpts -File -ErrorAction SilentlyContinue).Count -eq $ckptCountF1a) '[F1a] no checkpoint was written after the takeover' ''
        Assert-SR ([long]((Get-SRLiveGoal -GoalId $idsF1a.goal)['revision']) -eq $revAfterTakeF1a) '[F1a] the goal was not touched by the refused recovery' ''

        # ---------- F1b. admitted request waits on the lock while a takeover lands ----------
        $idsF1b = New-SRIds -Tag 'lockwait'
        $gF1b = New-SRGoal -GoalId $idsF1b.goal
        New-SRTask -TaskId $idsF1b.task -GoalId $idsF1b.goal -Gen $gF1b.gen -Risk 'low'
        New-SRTask -TaskId $idsF1b.next -GoalId $idsF1b.goal -Gen $gF1b.gen -Risk 'low'
        $keyF1b = Get-NativeDispatchHash32 ('s4-settled-' + $idsF1b.task)
        $intentF1b = New-SRIntent -TaskId $idsF1b.task -Rev (Get-SRTaskRev -TaskId $idsF1b.task) -Key $keyF1b -Gen $gF1b.gen
        $null = Invoke-SRWalk -Goal $gF1b -Intent $intentF1b -Call 'call_s4_q2'
        Invoke-SRToReviewing -TaskId $idsF1b.task
        Set-SRVerification -TaskId $idsF1b.task
        Set-SRReview -TaskId $idsF1b.task
        Invoke-SRComplete -TaskId $idsF1b.task
        $nextKeyF1b = Get-NativeDispatchHash32 ('s4-next-' + $idsF1b.next)
        $intentNextF1b = New-SRIntent -TaskId $idsF1b.next -Rev (Get-SRTaskRev -TaskId $idsF1b.next) -Key $nextKeyF1b -Gen $gF1b.gen
        $scF1b = Invoke-OrchestrationSettledContinuation -GoalId $idsF1b.goal -SettledKey $keyF1b -Authorization $gF1b.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF1b
        Assert-SR (([bool]$scF1b.ok) -and [bool]$scF1b.prepared) '[F1b] setup continuation prepares' ([string]$scF1b.reason)
        # Barrier-proven post-lock revalidation: the child proves its
        # entry admission with a marker BEFORE the parent mutates; the
        # mutation therefore lands strictly during the child's lock wait,
        # so only the post-lock revalidation can refuse it. No sleeps
        # prove ordering (marker files do); the short sleeps below only
        # let the shortened lease expire, which is physics, not proof.
        $advDirF1b = Get-SRAdvanceDir -GoalId $idsF1b.goal
        $lockPathF1b = Join-Path ([string](Get-SRValue $advDirF1b 'dir' '')) ('.recovery-' + $keyF1b + '.lock')
        $heldF1b = [IO.File]::Open($lockPathF1b, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $chF1b = $null
        try {
            $chF1b = Start-SRChildRecovery -GoalId $idsF1b.goal -Key $keyF1b -Owner 'planner-1' -Gen $gF1b.gen -Source 'planner' -Allow $true -Sub 'ses_s4_sub_f1b' -LockTimeoutMs 25000 -WrapMode 'auth' -MarkDir $script:srEnv.root -MarkTag 'f1b'
            Assert-SR ($null -ne $chF1b) '[F1b] an external recovery process starts and blocks on the held lock' ''
            $markF1b = Wait-SRMarker -Path (Join-Path $script:srEnv.root 'f1b.auth.1') -TimeoutSec 60
            Assert-SR (($null -ne $markF1b) -and ($markF1b -ceq 'ok=True')) '[F1b] the child proves its entry admission passed' ([string]$markF1b)
            $renewF1b = Renew-OrchestrationGoalOwnership -GoalId $idsF1b.goal -OwnerId 'planner-1' -Generation $gF1b.gen -StoreDir $script:srEnv.goals -LeaseTtlMs 200
            Assert-SR ([bool]$renewF1b.ok) '[F1b] the lease is shortened while the child waits' ([string]$renewF1b.reason)
            Start-Sleep -Milliseconds 600
            $takeF1b = Takeover-OrchestrationGoalOwnership -GoalId $idsF1b.goal -OwnerId 'planner-2' -StoreDir $script:srEnv.goals
            Assert-SR ([bool]$takeF1b.ok) '[F1b] the takeover lands while the child waits' ([string]$takeF1b.reason)
        }
        finally { try { if ($null -ne $heldF1b) { $heldF1b.Dispose() } } catch { }; $heldF1b = $null }
        # Snapshot AFTER the takeover and release: the goal file legitimately
        # moved; only the waiting child runs from here on.
        $snapF1b = Get-SRSnapshot
        $ckptCountF1b = @(Get-ChildItem -LiteralPath $script:srEnv.ckpts -File -ErrorAction SilentlyContinue).Count
        $jrF1b = Wait-SRChildRecovery -Child $chF1b -TimeoutSec 90
        Assert-SR (($null -ne $jrF1b) -and (-not [bool]$jrF1b.ok) -and ([string]$jrF1b.reason -ceq 'recovery-ownership-stale') -and ([int]$jrF1b.calls -eq 0)) '[F1b] the waited request refuses without writes' ('reason=' + [string]$jrF1b.reason + ' cause=' + [string]$jrF1b.cause)
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $idsF1b.goal -Key $keyF1b))) '[F1b] the refused wait attributed nothing' ''
        Assert-SR ((Get-SRSnapshot) -ceq $snapF1b) '[F1b] domain hashes are unchanged' ''
        Assert-SR (@(Get-ChildItem -LiteralPath $script:srEnv.ckpts -File -ErrorAction SilentlyContinue).Count -eq $ckptCountF1b) '[F1b] no checkpoint was written' ''

        # ---------- F1c. settlement proof mutated during the lock wait refuses ----------
        $idsF1c = New-SRIds -Tag 'setmut'
        $gF1c = New-SRGoal -GoalId $idsF1c.goal
        New-SRTask -TaskId $idsF1c.task -GoalId $idsF1c.goal -Gen $gF1c.gen -Risk 'low'
        New-SRTask -TaskId $idsF1c.next -GoalId $idsF1c.goal -Gen $gF1c.gen -Risk 'low'
        $keyF1c = Get-NativeDispatchHash32 ('s4-settled-' + $idsF1c.task)
        $intentF1c = New-SRIntent -TaskId $idsF1c.task -Rev (Get-SRTaskRev -TaskId $idsF1c.task) -Key $keyF1c -Gen $gF1c.gen
        $null = Invoke-SRWalk -Goal $gF1c -Intent $intentF1c -Call 'call_s4_q3'
        Invoke-SRToReviewing -TaskId $idsF1c.task
        Set-SRVerification -TaskId $idsF1c.task
        Set-SRReview -TaskId $idsF1c.task
        Invoke-SRComplete -TaskId $idsF1c.task
        $nextKeyF1c = Get-NativeDispatchHash32 ('s4-next-' + $idsF1c.next)
        $intentNextF1c = New-SRIntent -TaskId $idsF1c.next -Rev (Get-SRTaskRev -TaskId $idsF1c.next) -Key $nextKeyF1c -Gen $gF1c.gen
        $scF1c = Invoke-OrchestrationSettledContinuation -GoalId $idsF1c.goal -SettledKey $keyF1c -Authorization $gF1c.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF1c
        Assert-SR (([bool]$scF1c.ok) -and [bool]$scF1c.prepared) '[F1c] setup continuation prepares' ([string]$scF1c.reason)
        # Barrier-proven settlement revalidation: the child proves it blocks
        # on the held lock (classification already bound the intact proof);
        # only then the settled receipt bytes change. The post-lock snapshot
        # must refuse even though the advance record itself is unchanged.
        $recPathF1c = Get-SRReceiptPath -GoalId $idsF1c.goal -Key $keyF1c
        $validBytesF1c = [IO.File]::ReadAllText($recPathF1c, [Text.Encoding]::UTF8)
        $advDirF1c = Get-SRAdvanceDir -GoalId $idsF1c.goal
        $lockPathF1c = Join-Path ([string](Get-SRValue $advDirF1c 'dir' '')) ('.recovery-' + $keyF1c + '.lock')
        $heldF1c = [IO.File]::Open($lockPathF1c, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $chF1c = $null
        try {
            $chF1c = Start-SRChildRecovery -GoalId $idsF1c.goal -Key $keyF1c -Owner 'planner-1' -Gen $gF1c.gen -Source 'planner' -Allow $true -Sub 'ses_s4_sub_f1c' -LockTimeoutMs 25000 -WrapMode 'lock' -MarkDir $script:srEnv.root -MarkTag 'f1c'
            Assert-SR ($null -ne $chF1c) '[F1c] an external recovery process starts and blocks on the held lock' ''
            $markF1c = Wait-SRMarker -Path (Join-Path $script:srEnv.root 'f1c.waiting') -TimeoutSec 60
            Assert-SR ($null -ne $markF1c) '[F1c] the child proves it blocks on the held lock' ''
            [IO.File]::AppendAllText($recPathF1c, "`n ", [Text.Encoding]::UTF8)
        }
        finally { try { if ($null -ne $heldF1c) { $heldF1c.Dispose() } } catch { }; $heldF1c = $null }
        $snapF1c = Get-SRSnapshot
        $ckptCountF1c = @(Get-ChildItem -LiteralPath $script:srEnv.ckpts -File -ErrorAction SilentlyContinue).Count
        $rF1c = Wait-SRChildRecovery -Child $chF1c -TimeoutSec 90
        Assert-SR (($null -ne $rF1c) -and (-not [bool]$rF1c.ok) -and ([string]$rF1c.reason -ceq 'recovery-record-uncertain') -and ([string]$rF1c.cause -ceq 'settlement-changed-under-lock:settlement-receipt-changed') -and (-not [bool]$rF1c.prepared)) '[F1c] the mutated settlement refuses after the lock wait' ('cause=' + [string]$rF1c.cause)
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $idsF1c.goal -Key $keyF1c))) '[F1c] the refused wait attributed nothing' ''
        Assert-SR ((Get-SRSnapshot) -ceq $snapF1c) '[F1c] domain hashes are unchanged' ''
        Assert-SR (@(Get-ChildItem -LiteralPath $script:srEnv.ckpts -File -ErrorAction SilentlyContinue).Count -eq $ckptCountF1c) '[F1c] no checkpoint was written' ''
        [IO.File]::WriteAllText($recPathF1c, $validBytesF1c, ([Text.UTF8Encoding]::new($false)))

        # ---------- F2a. successor removed refuses without PREPARE ----------
        $idsF2a = New-SRIds -Tag 'nosucc'
        $gF2a = New-SRGoal -GoalId $idsF2a.goal
        New-SRTask -TaskId $idsF2a.task -GoalId $idsF2a.goal -Gen $gF2a.gen -Risk 'low'
        New-SRTask -TaskId $idsF2a.next -GoalId $idsF2a.goal -Gen $gF2a.gen -Risk 'low'
        $keyF2a = Get-NativeDispatchHash32 ('s4-settled-' + $idsF2a.task)
        $intentF2a = New-SRIntent -TaskId $idsF2a.task -Rev (Get-SRTaskRev -TaskId $idsF2a.task) -Key $keyF2a -Gen $gF2a.gen
        $null = Invoke-SRWalk -Goal $gF2a -Intent $intentF2a -Call 'call_s4_n1'
        Invoke-SRToReviewing -TaskId $idsF2a.task
        Set-SRVerification -TaskId $idsF2a.task
        Set-SRReview -TaskId $idsF2a.task
        Invoke-SRComplete -TaskId $idsF2a.task
        $nextKeyF2a = Get-NativeDispatchHash32 ('s4-next-' + $idsF2a.next)
        $intentNextF2a = New-SRIntent -TaskId $idsF2a.next -Rev (Get-SRTaskRev -TaskId $idsF2a.next) -Key $nextKeyF2a -Gen $gF2a.gen
        $scF2a = Invoke-OrchestrationSettledContinuation -GoalId $idsF2a.goal -SettledKey $keyF2a -Authorization $gF2a.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF2a
        Assert-SR (([bool]$scF2a.ok) -and [bool]$scF2a.prepared) '[F2a] setup continuation prepares' ([string]$scF2a.reason)
        $advTextF2a = [IO.File]::ReadAllText((Join-Path ([string](Get-SRValue (Get-SRAdvanceDir -GoalId $idsF2a.goal) 'dir' '')) ($keyF2a + '.advance.json')), [Text.Encoding]::UTF8)
        Remove-Item -LiteralPath (Get-SRReceiptPath -GoalId $idsF2a.goal -Key $nextKeyF2a) -Force -ErrorAction Stop
        $rF2a = Invoke-SRRecovery -GoalId $idsF2a.goal -Key $keyF2a -Auth $gF2a.auth -Sub 'ses_s4_sub_A'
        Assert-SR (((-not [bool]$rF2a.ok) -and ([string]$rF2a.reason -ceq 'recovery-successor-unproven') -and ([string]$rF2a.cause_reason -ceq 'successor-receipt-absent') -and (-not [bool]$rF2a.prepared))) '[F2a] a removed successor refuses without announcing prepared' ('cause=' + [string]$rF2a.cause_reason)
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $idsF2a.goal -Key $keyF2a))) '[F2a] the refusal attributed nothing' ''
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRReceiptPath -GoalId $idsF2a.goal -Key $nextKeyF2a))) '[F2a] no PREPARE recreated the successor' ''
        Assert-SR (([IO.File]::ReadAllText((Join-Path ([string](Get-SRValue (Get-SRAdvanceDir -GoalId $idsF2a.goal) 'dir' '')) ($keyF2a + '.advance.json')), [Text.Encoding]::UTF8) -ceq $advTextF2a)) '[F2a] the advance decision is untouched' ''

        # ---------- F2b. successor corrupted refuses ----------
        $idsF2b = New-SRIds -Tag 'succorr'
        $gF2b = New-SRGoal -GoalId $idsF2b.goal
        New-SRTask -TaskId $idsF2b.task -GoalId $idsF2b.goal -Gen $gF2b.gen -Risk 'low'
        New-SRTask -TaskId $idsF2b.next -GoalId $idsF2b.goal -Gen $gF2b.gen -Risk 'low'
        $keyF2b = Get-NativeDispatchHash32 ('s4-settled-' + $idsF2b.task)
        $intentF2b = New-SRIntent -TaskId $idsF2b.task -Rev (Get-SRTaskRev -TaskId $idsF2b.task) -Key $keyF2b -Gen $gF2b.gen
        $null = Invoke-SRWalk -Goal $gF2b -Intent $intentF2b -Call 'call_s4_n2'
        Invoke-SRToReviewing -TaskId $idsF2b.task
        Set-SRVerification -TaskId $idsF2b.task
        Set-SRReview -TaskId $idsF2b.task
        Invoke-SRComplete -TaskId $idsF2b.task
        $nextKeyF2b = Get-NativeDispatchHash32 ('s4-next-' + $idsF2b.next)
        $intentNextF2b = New-SRIntent -TaskId $idsF2b.next -Rev (Get-SRTaskRev -TaskId $idsF2b.next) -Key $nextKeyF2b -Gen $gF2b.gen
        $scF2b = Invoke-OrchestrationSettledContinuation -GoalId $idsF2b.goal -SettledKey $keyF2b -Authorization $gF2b.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF2b
        Assert-SR (([bool]$scF2b.ok) -and [bool]$scF2b.prepared) '[F2b] setup continuation prepares' ([string]$scF2b.reason)
        # Isolated root: the corrupted successor must never poison the
        # shared root scan (fail-closed CLAIM would refuse later fixtures).
        $recsF2b = Join-Path $tempRoot 'recs-f2b'
        New-Item -ItemType Directory -Path $recsF2b -Force | Out-Null
        $subSrcF2b = Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $idsF2b.goal
        $subDstF2b = Get-NDGoalReceiptDir -RootDir $recsF2b -GoalId $idsF2b.goal
        Copy-Item -Path (Join-Path $subSrcF2b '*') -Destination $subDstF2b -Recurse -Force
        [IO.File]::WriteAllText((Join-Path $subDstF2b ($nextKeyF2b + '.json')), '{ truncado', [Text.Encoding]::UTF8)
        $advIsoF2b = Get-NDAdvanceDir -RootDir $recsF2b -GoalId $idsF2b.goal
        $recPathIsoF2b = Join-Path ([string](Get-SRValue $advIsoF2b 'dir' '')) ($keyF2b + '.recovery.json')
        $rF2b = Invoke-SRRecovery -GoalId $idsF2b.goal -Key $keyF2b -Auth $gF2b.auth -Sub 'ses_s4_sub_A' -Receipts $recsF2b
        Assert-SR (((-not [bool]$rF2b.ok) -and ([string]$rF2b.reason -ceq 'recovery-successor-unproven') -and ([string]$rF2b.cause_reason -ceq 'successor-receipt-unreadable'))) '[F2b] a corrupted successor refuses' ('cause=' + [string]$rF2b.cause_reason)
        Assert-SR (-not (Test-Path -LiteralPath $recPathIsoF2b)) '[F2b] the refusal attributed nothing' ''

        # ---------- F2c. successor reference swapped refuses ----------
        $idsF2c = New-SRIds -Tag 'sucref'
        $gF2c = New-SRGoal -GoalId $idsF2c.goal
        New-SRTask -TaskId $idsF2c.task -GoalId $idsF2c.goal -Gen $gF2c.gen -Risk 'low'
        New-SRTask -TaskId $idsF2c.next -GoalId $idsF2c.goal -Gen $gF2c.gen -Risk 'low'
        $keyF2c = Get-NativeDispatchHash32 ('s4-settled-' + $idsF2c.task)
        $intentF2c = New-SRIntent -TaskId $idsF2c.task -Rev (Get-SRTaskRev -TaskId $idsF2c.task) -Key $keyF2c -Gen $gF2c.gen
        $null = Invoke-SRWalk -Goal $gF2c -Intent $intentF2c -Call 'call_s4_n3'
        Invoke-SRToReviewing -TaskId $idsF2c.task
        Set-SRVerification -TaskId $idsF2c.task
        Set-SRReview -TaskId $idsF2c.task
        Invoke-SRComplete -TaskId $idsF2c.task
        $nextKeyF2c = Get-NativeDispatchHash32 ('s4-next-' + $idsF2c.next)
        $intentNextF2c = New-SRIntent -TaskId $idsF2c.next -Rev (Get-SRTaskRev -TaskId $idsF2c.next) -Key $nextKeyF2c -Gen $gF2c.gen
        $scF2c = Invoke-OrchestrationSettledContinuation -GoalId $idsF2c.goal -SettledKey $keyF2c -Authorization $gF2c.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF2c
        Assert-SR (([bool]$scF2c.ok) -and [bool]$scF2c.prepared) '[F2c] setup continuation prepares' ([string]$scF2c.reason)
        # Isolated root: the decorrelated successor must never poison the
        # shared root scan (the prepared phase revalidates semantic
        # integrity on every CLAIM scan).
        $recsF2c = Join-Path $tempRoot 'recs-f2c'
        New-Item -ItemType Directory -Path $recsF2c -Force | Out-Null
        $subSrcF2c = Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $idsF2c.goal
        $subDstF2c = Get-NDGoalReceiptDir -RootDir $recsF2c -GoalId $idsF2c.goal
        Copy-Item -Path (Join-Path $subSrcF2c '*') -Destination $subDstF2c -Recurse -Force
        $succPathF2c = Join-Path $subDstF2c ($nextKeyF2c + '.json')
        $succRawF2c = ConvertFrom-Json ([IO.File]::ReadAllText($succPathF2c, [Text.Encoding]::UTF8))
        $succRawF2c.reference = 'ffffffffffffffffffffffffffffffff'
        [IO.File]::WriteAllText($succPathF2c, (ConvertTo-Json -InputObject $succRawF2c -Depth 8 -Compress), [Text.Encoding]::UTF8)
        $advIsoF2c = Get-NDAdvanceDir -RootDir $recsF2c -GoalId $idsF2c.goal
        $recPathIsoF2c = Join-Path ([string](Get-SRValue $advIsoF2c 'dir' '')) ($keyF2c + '.recovery.json')
        $rF2c = Invoke-SRRecovery -GoalId $idsF2c.goal -Key $keyF2c -Auth $gF2c.auth -Sub 'ses_s4_sub_A' -Receipts $recsF2c
        Assert-SR (((-not [bool]$rF2c.ok) -and ([string]$rF2c.reason -ceq 'recovery-successor-unproven') -and ([string]$rF2c.cause_reason -ceq 'successor-reference-mismatch'))) '[F2c] a swapped successor reference refuses' ('cause=' + [string]$rF2c.cause_reason)
        Assert-SR (-not (Test-Path -LiteralPath $recPathIsoF2c)) '[F2c] the refusal attributed nothing' ''

        # ---------- F2d. reserved crash + missing successor re-checks under the lock ----------
        $idsF2d = New-SRIds -Tag 'succcrash'
        $gF2d = New-SRGoal -GoalId $idsF2d.goal
        New-SRTask -TaskId $idsF2d.task -GoalId $idsF2d.goal -Gen $gF2d.gen -Risk 'low'
        New-SRTask -TaskId $idsF2d.next -GoalId $idsF2d.goal -Gen $gF2d.gen -Risk 'low'
        $keyF2d = Get-NativeDispatchHash32 ('s4-settled-' + $idsF2d.task)
        $intentF2d = New-SRIntent -TaskId $idsF2d.task -Rev (Get-SRTaskRev -TaskId $idsF2d.task) -Key $keyF2d -Gen $gF2d.gen
        $walkF2d = Invoke-SRWalk -Goal $gF2d -Intent $intentF2d -Call 'call_s4_n4'
        Invoke-SRToReviewing -TaskId $idsF2d.task
        Set-SRVerification -TaskId $idsF2d.task
        Set-SRReview -TaskId $idsF2d.task
        Invoke-SRComplete -TaskId $idsF2d.task
        $nextKeyF2d = Get-NativeDispatchHash32 ('s4-next-' + $idsF2d.next)
        $intentNextF2d = New-SRIntent -TaskId $idsF2d.next -Rev (Get-SRTaskRev -TaskId $idsF2d.next) -Key $nextKeyF2d -Gen $gF2d.gen
        $scF2d = Invoke-OrchestrationSettledContinuation -GoalId $idsF2d.goal -SettledKey $keyF2d -Authorization $gF2d.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF2d
        Assert-SR (([bool]$scF2d.ok) -and [bool]$scF2d.prepared) '[F2d] setup continuation prepares' ([string]$scF2d.reason)
        Remove-Item -LiteralPath (Get-SRRecoveryPath -GoalId $idsF2d.goal -Key $keyF2d) -Force -ErrorAction SilentlyContinue
        $advF2d = Get-SRAdvanceRecord -GoalId $idsF2d.goal -Key $keyF2d
        $recF2draw = Get-SRReceipt -GoalId $idsF2d.goal -Key $keyF2d
        $rDirF2d = Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $idsF2d.goal
        $origSessF2d = ([string](Get-SRValue $recF2draw 'settle_session_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($origSessF2d)) { $origSessF2d = ([string](Get-SRValue $recF2draw 'claim_session_id' '')).Trim() }
        $evIdF2d = ([string](Get-SRValue $recF2draw 'settle_evidence_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($evIdF2d)) { $evIdF2d = ([string](Get-SRValue $recF2draw 'evidence_id' '')).Trim() }
        $recExpF2d = [long](Get-SRValue $recF2draw 'task_expected_revision' -1)
        $fpF2d = Get-SRAssignmentFingerprint -SubstituteSessionId 'ses_s4_sub_f2d' -Owner 'planner-1' -Generation $gF2d.gen -Source 'planner' `
            -Action 'replay-prepared' -ReasonCode 'substitute-timeout' -GoalId $idsF2d.goal -SettledKey $keyF2d -SourceTaskId $idsF2d.task `
            -ReceiptRef (Join-Path $rDirF2d ($keyF2d + '.json')) -EvidenceId $evIdF2d -CandidateRevision $recExpF2d `
            -NextKey ([string](Get-SRValue $advF2d 'next_idempotency_key' '')) -NextIntentFingerprint '' -OriginalPrepareSessionId $origSessF2d
        $advDirF2d = Get-SRAdvanceDir -GoalId $idsF2d.goal
        $reservedF2d = [ordered]@{
            schema_version = 1; goal_id = $idsF2d.goal; settled_key = $keyF2d; source_task_id = $idsF2d.task
            assignment_fingerprint = $fpF2d; substitute_session_id = 'ses_s4_sub_f2d'
            authorization_owner = 'planner-1'; authorization_generation = [long]$gF2d.gen; authorization_source = 'planner'
            reason_code = 'substitute-timeout'; action = 'replay-prepared'; intended_action = 'replay-prepared'
            proof_refs = [ordered]@{ receipt = (Join-Path $rDirF2d ($keyF2d + '.json')); advance = (Join-Path ([string](Get-SRValue $advDirF2d 'dir' '')) ($keyF2d + '.advance.json')); evidence_id = $evIdF2d; candidate_revision = [long]$recExpF2d; next_key = ([string](Get-SRValue $advF2d 'next_idempotency_key' '')); next_intent_fingerprint = ''; original_prepare_session_id = $origSessF2d }
            phase = 'reserved'
            result = [ordered]@{ ok = $false; reason = 'recovery-reserved'; cause_reason = 'reserved-before-replay'; prepared = $false; next_idempotency_key = ''; next_reference = ''; checkpoint_id = ''; checkpoint_ok = $false; effects = [ordered]@{ domain_mutated = $false; attribution_written = $true; checkpoint_written = $false } }
            created_at = ([DateTime]::UtcNow.ToString('o')); recorded_at = ''
        }
        Assert-SR ([bool](Write-SRRecoveryRecord -AdvanceDir ([string](Get-SRValue $advDirF2d 'dir' '')) -Ident ([string](Get-SRValue $advDirF2d 'ident' '')) -Key $keyF2d -Record $reservedF2d)) '[F2d] a reserved record simulates the crash' ''
        # Barrier-proven under-lock re-check: the child proves its pre-lock
        # successor binding passed; only then the successor vanishes while
        # the child is blocked on the held lock. The refusal must come
        # from the post-lock revalidation, never from the pre-lock path.
        $lockPathF2d = Join-Path ([string](Get-SRValue $advDirF2d 'dir' '')) ('.recovery-' + $keyF2d + '.lock')
        $heldF2d = [IO.File]::Open($lockPathF2d, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $chF2d = $null
        try {
            $chF2d = Start-SRChildRecovery -GoalId $idsF2d.goal -Key $keyF2d -Owner 'planner-1' -Gen $gF2d.gen -Source 'planner' -Allow $true -Sub 'ses_s4_sub_f2d' -LockTimeoutMs 25000 -WrapMode 'successor' -MarkDir $script:srEnv.root -MarkTag 'f2d'
            Assert-SR ($null -ne $chF2d) '[F2d] an external recovery process starts and blocks on the held lock' ''
            $markF2d = Wait-SRMarker -Path (Join-Path $script:srEnv.root 'f2d.succ.1') -TimeoutSec 60
            Assert-SR (($null -ne $markF2d) -and ($markF2d -ceq 'ok=True')) '[F2d] the child proves its pre-lock successor check passed' ([string]$markF2d)
            Remove-Item -LiteralPath (Get-SRReceiptPath -GoalId $idsF2d.goal -Key $nextKeyF2d) -Force -ErrorAction Stop
        }
        finally { try { if ($null -ne $heldF2d) { $heldF2d.Dispose() } } catch { }; $heldF2d = $null }
        $snapF2d = Get-SRSnapshot
        $ckptCountF2d = @(Get-ChildItem -LiteralPath $script:srEnv.ckpts -File -ErrorAction SilentlyContinue).Count
        $rF2d = Wait-SRChildRecovery -Child $chF2d -TimeoutSec 90
        Assert-SR (($null -ne $rF2d) -and (-not [bool]$rF2d.ok) -and ([string]$rF2d.reason -ceq 'recovery-successor-unproven') -and ([string]$rF2d.cause -ceq 'successor-receipt-absent') -and (-not [bool]$rF2d.prepared)) '[F2d] the vanished successor refuses after the lock wait' ('cause=' + [string]$rF2d.cause)
        $recF2d = Get-SRRecoveryRecord -GoalId $idsF2d.goal -Key $keyF2d
        Assert-SR ((([string]$recF2d.phase -ceq 'reserved') -and ([string]$recF2d.assignment_fingerprint -ceq $fpF2d))) '[F2d] the reserved record is preserved, never presumed' ''
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRReceiptPath -GoalId $idsF2d.goal -Key $nextKeyF2d))) '[F2d] no fallback successor was prepared' ''
        Assert-SR ((Get-SRSnapshot) -ceq $snapF2d) '[F2d] no other domain writes happened' ''
        Assert-SR (@(Get-ChildItem -LiteralPath $script:srEnv.ckpts -File -ErrorAction SilentlyContinue).Count -eq $ckptCountF2d) '[F2d] no checkpoint was written' ''

        # ---------- F2e. valid successor still replays ----------
        $idsF2e = New-SRIds -Tag 'succok'
        $gF2e = New-SRGoal -GoalId $idsF2e.goal
        New-SRTask -TaskId $idsF2e.task -GoalId $idsF2e.goal -Gen $gF2e.gen -Risk 'low'
        New-SRTask -TaskId $idsF2e.next -GoalId $idsF2e.goal -Gen $gF2e.gen -Risk 'low'
        $keyF2e = Get-NativeDispatchHash32 ('s4-settled-' + $idsF2e.task)
        $intentF2e = New-SRIntent -TaskId $idsF2e.task -Rev (Get-SRTaskRev -TaskId $idsF2e.task) -Key $keyF2e -Gen $gF2e.gen
        $null = Invoke-SRWalk -Goal $gF2e -Intent $intentF2e -Call 'call_s4_n5'
        Invoke-SRToReviewing -TaskId $idsF2e.task
        Set-SRVerification -TaskId $idsF2e.task
        Set-SRReview -TaskId $idsF2e.task
        Invoke-SRComplete -TaskId $idsF2e.task
        $nextKeyF2e = Get-NativeDispatchHash32 ('s4-next-' + $idsF2e.next)
        $intentNextF2e = New-SRIntent -TaskId $idsF2e.next -Rev (Get-SRTaskRev -TaskId $idsF2e.next) -Key $nextKeyF2e -Gen $gF2e.gen
        $scF2e = Invoke-OrchestrationSettledContinuation -GoalId $idsF2e.goal -SettledKey $keyF2e -Authorization $gF2e.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF2e
        Assert-SR (([bool]$scF2e.ok) -and [bool]$scF2e.prepared) '[F2e] setup continuation prepares' ([string]$scF2e.reason)
        $rF2e = Invoke-SRRecovery -GoalId $idsF2e.goal -Key $keyF2e -Auth $gF2e.auth -Sub 'ses_s4_sub_A'
        Assert-SR (([bool]$rF2e.ok) -and ([string]$rF2e.action -ceq 'replay-prepared') -and ([bool]$rF2e.prepared) -and ([string]$rF2e.next_idempotency_key -ceq $nextKeyF2e)) '[F2e] a bound successor still replays' ('action=' + [string]$rF2e.action)

        # ---------- F2f. divergent NextIntent never steers a prepared replay ----------
        $idsF2f = New-SRIds -Tag 'succdiv'
        $gF2f = New-SRGoal -GoalId $idsF2f.goal
        New-SRTask -TaskId $idsF2f.task -GoalId $idsF2f.goal -Gen $gF2f.gen -Risk 'low'
        New-SRTask -TaskId $idsF2f.next -GoalId $idsF2f.goal -Gen $gF2f.gen -Risk 'low'
        $keyF2f = Get-NativeDispatchHash32 ('s4-settled-' + $idsF2f.task)
        $intentF2f = New-SRIntent -TaskId $idsF2f.task -Rev (Get-SRTaskRev -TaskId $idsF2f.task) -Key $keyF2f -Gen $gF2f.gen
        $null = Invoke-SRWalk -Goal $gF2f -Intent $intentF2f -Call 'call_s4_n6'
        Invoke-SRToReviewing -TaskId $idsF2f.task
        Set-SRVerification -TaskId $idsF2f.task
        Set-SRReview -TaskId $idsF2f.task
        Invoke-SRComplete -TaskId $idsF2f.task
        $nextKeyF2f = Get-NativeDispatchHash32 ('s4-next-' + $idsF2f.next)
        $intentNextF2f = New-SRIntent -TaskId $idsF2f.next -Rev (Get-SRTaskRev -TaskId $idsF2f.next) -Key $nextKeyF2f -Gen $gF2f.gen
        $scF2f = Invoke-OrchestrationSettledContinuation -GoalId $idsF2f.goal -SettledKey $keyF2f -Authorization $gF2f.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF2f
        Assert-SR (([bool]$scF2f.ok) -and [bool]$scF2f.prepared) '[F2f] setup continuation prepares' ([string]$scF2f.reason)
        $ghostF2f = ('s4-ghost-f2f-' + [string]$script:srSeq)
        New-SRTask -TaskId $ghostF2f -GoalId $idsF2f.goal -Gen $gF2f.gen -Risk 'low'
        $ghostKeyF2f = Get-NativeDispatchHash32 ('s4-ghost-next-' + $idsF2f.next)
        $ghostIntentF2f = New-SRIntent -TaskId $ghostF2f -Rev (Get-SRTaskRev -TaskId $ghostF2f) -Key $ghostKeyF2f -Gen $gF2f.gen
        $rF2f = Invoke-SRRecovery -GoalId $idsF2f.goal -Key $keyF2f -Auth $gF2f.auth -Sub 'ses_s4_sub_A' -NextIntent $ghostIntentF2f
        Assert-SR (((-not [bool]$rF2f.ok) -and ([string]$rF2f.reason -ceq 'recovery-intent-unproven') -and ([string]$rF2f.cause_reason -ceq 'successor-intent-divergent') -and (-not [bool]$rF2f.prepared))) '[F2f] a divergent NextIntent never steers the replay' ('cause=' + [string]$rF2f.cause_reason)
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $idsF2f.goal -Key $keyF2f))) '[F2f] the divergent intent attributed nothing' ''
        Assert-SR (-not (Test-Path -LiteralPath (Get-SRReceiptPath -GoalId $idsF2f.goal -Key $ghostKeyF2f))) '[F2f] the divergent intent prepared nothing' ''

        # ---------- F2g. successor scope tampered (nominal fields intact) refuses on integrity ----------
        $idsF2g = New-SRIds -Tag 'succscope'
        $gF2g = New-SRGoal -GoalId $idsF2g.goal
        New-SRTask -TaskId $idsF2g.task -GoalId $idsF2g.goal -Gen $gF2g.gen -Risk 'low'
        New-SRTask -TaskId $idsF2g.next -GoalId $idsF2g.goal -Gen $gF2g.gen -Risk 'low'
        $keyF2g = Get-NativeDispatchHash32 ('s4-settled-' + $idsF2g.task)
        $intentF2g = New-SRIntent -TaskId $idsF2g.task -Rev (Get-SRTaskRev -TaskId $idsF2g.task) -Key $keyF2g -Gen $gF2g.gen
        $null = Invoke-SRWalk -Goal $gF2g -Intent $intentF2g -Call 'call_s4_n7'
        Invoke-SRToReviewing -TaskId $idsF2g.task
        Set-SRVerification -TaskId $idsF2g.task
        Set-SRReview -TaskId $idsF2g.task
        Invoke-SRComplete -TaskId $idsF2g.task
        $nextKeyF2g = Get-NativeDispatchHash32 ('s4-next-' + $idsF2g.next)
        $intentNextF2g = New-SRIntent -TaskId $idsF2g.next -Rev (Get-SRTaskRev -TaskId $idsF2g.next) -Key $nextKeyF2g -Gen $gF2g.gen
        $scF2g = Invoke-OrchestrationSettledContinuation -GoalId $idsF2g.goal -SettledKey $keyF2g -Authorization $gF2g.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF2g
        Assert-SR (([bool]$scF2g.ok) -and [bool]$scF2g.prepared) '[F2g] setup continuation prepares' ([string]$scF2g.reason)
        # Isolated root: the tampered successor must never poison the
        # shared root scan. Nominal fields stay intact, so only the
        # recalculated semantic integrity can refuse.
        $recsF2g = Join-Path $tempRoot 'recs-f2g'
        New-Item -ItemType Directory -Path $recsF2g -Force | Out-Null
        $subSrcF2g = Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $idsF2g.goal
        $subDstF2g = Get-NDGoalReceiptDir -RootDir $recsF2g -GoalId $idsF2g.goal
        Copy-Item -Path (Join-Path $subSrcF2g '*') -Destination $subDstF2g -Recurse -Force
        $succPathF2g = Join-Path $subDstF2g ($nextKeyF2g + '.json')
        $succRawF2g = ConvertFrom-Json ([IO.File]::ReadAllText($succPathF2g, [Text.Encoding]::UTF8))
        $succRawF2g.scope = @('s4/tampered-scope.txt')
        [IO.File]::WriteAllText($succPathF2g, (ConvertTo-Json -InputObject $succRawF2g -Depth 8 -Compress), [Text.Encoding]::UTF8)
        $advIsoF2g = Get-NDAdvanceDir -RootDir $recsF2g -GoalId $idsF2g.goal
        $recPathIsoF2g = Join-Path ([string](Get-SRValue $advIsoF2g 'dir' '')) ($keyF2g + '.recovery.json')
        $rF2g = Invoke-SRRecovery -GoalId $idsF2g.goal -Key $keyF2g -Auth $gF2g.auth -Sub 'ses_s4_sub_A' -Receipts $recsF2g
        Assert-SR (((-not [bool]$rF2g.ok) -and ([string]$rF2g.reason -ceq 'recovery-successor-unproven') -and ([string]$rF2g.cause_reason -ceq 'successor-integrity-invalid'))) '[F2g] a scope-tampered successor refuses on semantic integrity' ('cause=' + [string]$rF2g.cause_reason)
        Assert-SR (-not (Test-Path -LiteralPath $recPathIsoF2g)) '[F2g] the refusal attributed nothing' ''

        # ---------- S15b. two external processes, same attribution ----------
        $idsMP1 = New-SRIds -Tag 'mpsame'
        $gMP1 = New-SRGoal -GoalId $idsMP1.goal
        New-SRTask -TaskId $idsMP1.task -GoalId $idsMP1.goal -Gen $gMP1.gen -Risk 'low'
        New-SRTask -TaskId $idsMP1.next -GoalId $idsMP1.goal -Gen $gMP1.gen -Risk 'low'
        $keyMP1 = Get-NativeDispatchHash32 ('s4-settled-' + $idsMP1.task)
        $intentMP1 = New-SRIntent -TaskId $idsMP1.task -Rev (Get-SRTaskRev -TaskId $idsMP1.task) -Key $keyMP1 -Gen $gMP1.gen
        $null = Invoke-SRWalk -Goal $gMP1 -Intent $intentMP1 -Call 'call_s4_m1'
        Invoke-SRToReviewing -TaskId $idsMP1.task
        Set-SRVerification -TaskId $idsMP1.task
        Set-SRReview -TaskId $idsMP1.task
        Invoke-SRComplete -TaskId $idsMP1.task
        $nextKeyMP1 = Get-NativeDispatchHash32 ('s4-next-' + $idsMP1.next)
        $intentNextMP1 = New-SRIntent -TaskId $idsMP1.next -Rev (Get-SRTaskRev -TaskId $idsMP1.next) -Key $nextKeyMP1 -Gen $gMP1.gen
        $scMP1 = Invoke-OrchestrationSettledContinuation -GoalId $idsMP1.goal -SettledKey $keyMP1 -Authorization $gMP1.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextMP1
        Assert-SR (([bool]$scMP1.ok) -and [bool]$scMP1.prepared) '[S15b] setup continuation prepares' ([string]$scMP1.reason)
        $revBeforeMP1 = [long]((Get-SRLiveGoal -GoalId $idsMP1.goal)['revision'])
        # Thundering herd with an observable barrier (F1-S4-FIX3 #5): the
        # Thundering herd with an observable barrier: the parent holds the
        # lock, both children prove they are blocked on it (*.waiting), and
        # only then the parent releases. Whoever wins records; the loser
        # deterministically replays the recorded result.
        $advDirMP1 = Get-SRAdvanceDir -GoalId $idsMP1.goal
        $lockPathMP1 = Join-Path ([string](Get-SRValue $advDirMP1 'dir' '')) ('.recovery-' + $keyMP1 + '.lock')
        $heldMP1 = [IO.File]::Open($lockPathMP1, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $chA = $null
        $chB = $null
        try {
            $chA = Start-SRChildRecovery -GoalId $idsMP1.goal -Key $keyMP1 -Owner 'planner-1' -Gen $gMP1.gen -Source 'planner' -Allow $true -Sub 'ses_s4_sub_mp' -LockTimeoutMs 20000 -WrapMode 'lock' -MarkDir $script:srEnv.root -MarkTag 't1a'
            $chB = Start-SRChildRecovery -GoalId $idsMP1.goal -Key $keyMP1 -Owner 'planner-1' -Gen $gMP1.gen -Source 'planner' -Allow $true -Sub 'ses_s4_sub_mp' -LockTimeoutMs 20000 -WrapMode 'lock' -MarkDir $script:srEnv.root -MarkTag 't1b'
            Assert-SR (($null -ne $chA) -and ($null -ne $chB)) '[S15b] two external recovery processes start' ''
            $wA = Wait-SRMarker -Path (Join-Path $script:srEnv.root 't1a.waiting') -TimeoutSec 60
            $wB = Wait-SRMarker -Path (Join-Path $script:srEnv.root 't1b.waiting') -TimeoutSec 60
            Assert-SR (($null -ne $wA) -and ($null -ne $wB)) '[S15b] both processes prove they block on the held lock' ''
        }
        finally { try { if ($null -ne $heldMP1) { $heldMP1.Dispose() } } catch { }; $heldMP1 = $null }
        $raMP1 = Wait-SRChildRecovery -Child $chA
        $rbMP1 = Wait-SRChildRecovery -Child $chB
        Assert-SR (($null -ne $raMP1) -and ($null -ne $rbMP1)) '[S15b] both external processes answer' ''
        Assert-SR (([bool]$raMP1.ok) -and ([bool]$rbMP1.ok) -and ([string]$raMP1.action -ceq 'replay-prepared') -and ([string]$rbMP1.action -ceq 'replay-prepared') -and ([string]$raMP1.fp -ceq [string]$rbMP1.fp) -and ([string]$raMP1.next -ceq $nextKeyMP1) -and ([string]$rbMP1.next -ceq $nextKeyMP1) -and ([int]$raMP1.calls -eq 0) -and ([int]$rbMP1.calls -eq 0)) '[S15b] concurrent same attributions replay deterministically' ('a=' + [string]$raMP1.action + '/' + [string]$rbMP1.action)
        $recMP1 = Get-SRRecoveryRecord -GoalId $idsMP1.goal -Key $keyMP1
        Assert-SR (($null -ne $recMP1) -and ([string]$recMP1.phase -ceq 'recorded') -and ([string]$recMP1.assignment_fingerprint -ceq [string]$raMP1.fp)) '[S15b] a single attribution record stands' ''
        $succCountMP1 = @(Get-ChildItem -LiteralPath (Get-NDGoalReceiptDir -RootDir $script:srEnv.recs -GoalId $idsMP1.goal) -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq ($nextKeyMP1 + '.json') }).Count
        Assert-SR ($succCountMP1 -eq 1) '[S15b] exactly one successor exists' ([string]$succCountMP1)
        $liveAfterMP1 = Get-SRLiveGoal -GoalId $idsMP1.goal
        Assert-SR ((([string]$liveAfterMP1['state'] -ceq 'ACTIVE') -and ([long]$liveAfterMP1['revision'] -eq $revBeforeMP1))) '[S15b] the goal is untouched by the concurrent replay' ([string]$liveAfterMP1['state'])

        # ---------- S15c. two external processes, divergent attributions ----------
        $idsMP2 = New-SRIds -Tag 'mpdiv'
        $gMP2 = New-SRGoal -GoalId $idsMP2.goal
        New-SRTask -TaskId $idsMP2.task -GoalId $idsMP2.goal -Gen $gMP2.gen -Risk 'low'
        New-SRTask -TaskId $idsMP2.next -GoalId $idsMP2.goal -Gen $gMP2.gen -Risk 'low'
        $keyMP2 = Get-NativeDispatchHash32 ('s4-settled-' + $idsMP2.task)
        $intentMP2 = New-SRIntent -TaskId $idsMP2.task -Rev (Get-SRTaskRev -TaskId $idsMP2.task) -Key $keyMP2 -Gen $gMP2.gen
        $null = Invoke-SRWalk -Goal $gMP2 -Intent $intentMP2 -Call 'call_s4_m2'
        Invoke-SRToReviewing -TaskId $idsMP2.task
        Set-SRVerification -TaskId $idsMP2.task
        Set-SRReview -TaskId $idsMP2.task
        Invoke-SRComplete -TaskId $idsMP2.task
        $nextKeyMP2 = Get-NativeDispatchHash32 ('s4-next-' + $idsMP2.next)
        $intentNextMP2 = New-SRIntent -TaskId $idsMP2.next -Rev (Get-SRTaskRev -TaskId $idsMP2.next) -Key $nextKeyMP2 -Gen $gMP2.gen
        $scMP2 = Invoke-OrchestrationSettledContinuation -GoalId $idsMP2.goal -SettledKey $keyMP2 -Authorization $gMP2.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $script:srEnv.recs -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextMP2
        Assert-SR (([bool]$scMP2.ok) -and [bool]$scMP2.prepared) '[S15c] setup continuation prepares' ([string]$scMP2.reason)
        $advDirMP2 = Get-SRAdvanceDir -GoalId $idsMP2.goal
        $lockPathMP2 = Join-Path ([string](Get-SRValue $advDirMP2 'dir' '')) ('.recovery-' + $keyMP2 + '.lock')
        $heldMP2 = [IO.File]::Open($lockPathMP2, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $chC = $null
        $chD = $null
        try {
            $chC = Start-SRChildRecovery -GoalId $idsMP2.goal -Key $keyMP2 -Owner 'planner-1' -Gen $gMP2.gen -Source 'planner' -Allow $true -Sub 'ses_s4_sub_mpC' -LockTimeoutMs 20000 -WrapMode 'lock' -MarkDir $script:srEnv.root -MarkTag 't2c'
            $chD = Start-SRChildRecovery -GoalId $idsMP2.goal -Key $keyMP2 -Owner 'planner-1' -Gen $gMP2.gen -Source 'planner' -Allow $true -Sub 'ses_s4_sub_mpD' -LockTimeoutMs 20000 -WrapMode 'lock' -MarkDir $script:srEnv.root -MarkTag 't2d'
            Assert-SR (($null -ne $chC) -and ($null -ne $chD)) '[S15c] two external recovery processes start' ''
            $wC = Wait-SRMarker -Path (Join-Path $script:srEnv.root 't2c.waiting') -TimeoutSec 60
            $wD = Wait-SRMarker -Path (Join-Path $script:srEnv.root 't2d.waiting') -TimeoutSec 60
            Assert-SR (($null -ne $wC) -and ($null -ne $wD)) '[S15c] both processes prove they block on the held lock' ''
        }
        finally { try { if ($null -ne $heldMP2) { $heldMP2.Dispose() } } catch { }; $heldMP2 = $null }
        $rcMP2 = Wait-SRChildRecovery -Child $chC
        $rdMP2 = Wait-SRChildRecovery -Child $chD
        Assert-SR (($null -ne $rcMP2) -and ($null -ne $rdMP2)) '[S15c] both external processes answer' ''
        $winC = ([bool]$rcMP2.ok -and ([string]$rcMP2.action -ceq 'replay-prepared'))
        $winD = ([bool]$rdMP2.ok -and ([string]$rdMP2.action -ceq 'replay-prepared'))
        Assert-SR ((($winC -and (-not $winD)) -or (($winD -and (-not $winC))))) '[S15c] exactly one attribution wins' ('c=' + [string]$rcMP2.action + '/' + [string]$rcMP2.reason + ' d=' + [string]$rdMP2.action + '/' + [string]$rdMP2.reason)
        $loserMP2 = $rdMP2
        $winnerMP2 = $rcMP2
        if ($winD) { $loserMP2 = $rcMP2; $winnerMP2 = $rdMP2 }
        Assert-SR ((([string]$loserMP2.reason -ceq 'recovery-assignment-mismatch') -and ([int]$loserMP2.calls -eq 0) -and ([int]$winnerMP2.calls -eq 0))) '[S15c] the divergent attribution is refused without writes' ([string]$loserMP2.reason)
        $recMP2 = Get-SRRecoveryRecord -GoalId $idsMP2.goal -Key $keyMP2
        Assert-SR (($null -ne $recMP2) -and ([string]$recMP2.phase -ceq 'recorded') -and ([string]$recMP2.assignment_fingerprint -ceq [string]$winnerMP2.fp) -and ([string]$recMP2.action -ceq 'replay-prepared')) '[S15c] the winner record stands, never overwritten' ''

        # ---------- S15d. external process times out on a held lock ----------
        $idsMP3 = New-SRIds -Tag 'mplock'
        $gMP3 = New-SRGoal -GoalId $idsMP3.goal
        New-SRTask -TaskId $idsMP3.task -GoalId $idsMP3.goal -Gen $gMP3.gen -Risk 'low'
        $keyMP3 = Get-NativeDispatchHash32 ('s4-settled-' + $idsMP3.task)
        $intentMP3 = New-SRIntent -TaskId $idsMP3.task -Rev (Get-SRTaskRev -TaskId $idsMP3.task) -Key $keyMP3 -Gen $gMP3.gen
        $null = Invoke-SRWalk -Goal $gMP3 -Intent $intentMP3 -Call 'call_s4_m3'
        $nextKeyMP3 = Get-NativeDispatchHash32 ('s4-next-mp-' + $idsMP3.task)
        $advDirMP3b = Get-SRAdvanceDir -GoalId $idsMP3.goal
        $pendingMP3 = [ordered]@{
            schema_version = 1; ok = $true; reason = ''; goal_id = $idsMP3.goal; settled_key = $keyMP3
            move = 'CONTINUE'; move_reason = 's4-mp3-pending'; stop_reason = ''; prepared = $false
            next_idempotency_key = $nextKeyMP3; next_reference = ''; next_task_id = ''; next_agent = ''
            prepare_reason = ''; goal_state = 'ACTIVE'; goal_revision = 0; finalize_reason = ''
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }
        Assert-SR ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-SRValue $advDirMP3b 'dir' '')) -Ident ([string](Get-SRValue $advDirMP3b 'ident' '')) -Key $keyMP3 -Record $pendingMP3)) '[S15d] a pending advance routes the waiter to the lock' ''
        $advDirMP3 = Get-SRAdvanceDir -GoalId $idsMP3.goal
        $lockPathMP3 = Join-Path ([string](Get-SRValue $advDirMP3 'dir' '')) ('.recovery-' + $keyMP3 + '.lock')
        $heldMP3 = [IO.File]::Open($lockPathMP3, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $chE = $null
        try {
            $chE = Start-SRChildRecovery -GoalId $idsMP3.goal -Key $keyMP3 -Owner 'planner-1' -Gen $gMP3.gen -Source 'planner' -Allow $true -Sub 'ses_s4_sub_mpE' -LockTimeoutMs 2000 -WrapMode 'lock' -MarkDir $script:srEnv.root -MarkTag 't3e'
            Assert-SR ($null -ne $chE) '[S15d] an external process starts against the held lock' ''
            $reMP3 = Wait-SRChildRecovery -Child $chE -TimeoutSec 60
            Assert-SR (($null -ne $reMP3) -and (-not [bool]$reMP3.ok) -and ([string]$reMP3.reason -ceq 'recovery-lock-busy') -and ([int]$reMP3.calls -eq 0)) '[S15d] the external waiter refuses busy' ('reason=' + [string]$reMP3.reason)
            Assert-SR (-not (Test-Path -LiteralPath (Get-SRRecoveryPath -GoalId $idsMP3.goal -Key $keyMP3))) '[S15d] the timed-out waiter wrote nothing' ''
            $wE = Wait-SRMarker -Path (Join-Path $script:srEnv.root 't3e.waiting') -TimeoutSec 60
            Assert-SR ($null -ne $wE) '[S15d] the waiter provably reached the held lock' ''
        }
        finally { try { if ($null -ne $heldMP3) { $heldMP3.Dispose() } } catch { }; $heldMP3 = $null }

        # ---------- F3. RepoRoot is forwarded to the S3a delegation ----------
        $fakeRepoF3 = Join-Path $tempRoot 'fakerepo'
        New-Item -ItemType Directory -Path $fakeRepoF3 -Force | Out-Null
        $recsF3 = Join-Path (Join-Path $fakeRepoF3 'cache') 'native-dispatch-receipts'
        New-Item -ItemType Directory -Path $recsF3 -Force | Out-Null
        $idsF3 = New-SRIds -Tag 'reporoot'
        $gF3 = New-SRGoal -GoalId $idsF3.goal
        New-SRTask -TaskId $idsF3.task -GoalId $idsF3.goal -Gen $gF3.gen -Risk 'low'
        New-SRTask -TaskId $idsF3.next -GoalId $idsF3.goal -Gen $gF3.gen -Risk 'low'
        $keyF3 = Get-NativeDispatchHash32 ('s4-settled-' + $idsF3.task)
        $intentF3 = New-SRIntent -TaskId $idsF3.task -Rev (Get-SRTaskRev -TaskId $idsF3.task) -Key $keyF3 -Gen $gF3.gen
        $null = Invoke-SRWalk -Goal $gF3 -Intent $intentF3 -Call 'call_s4_r1' -Receipts $recsF3
        Invoke-SRToReviewing -TaskId $idsF3.task
        Set-SRVerification -TaskId $idsF3.task
        Set-SRReview -TaskId $idsF3.task
        Invoke-SRComplete -TaskId $idsF3.task
        $nextKeyF3 = Get-NativeDispatchHash32 ('s4-next-' + $idsF3.next)
        $intentNextF3 = New-SRIntent -TaskId $idsF3.next -Rev (Get-SRTaskRev -TaskId $idsF3.next) -Key $nextKeyF3 -Gen $gF3.gen
        $scF3 = Invoke-OrchestrationSettledContinuation -GoalId $idsF3.goal -SettledKey $keyF3 -Authorization $gF3.auth `
            -SessionId 'ses_s4_parent' -CheckpointDir $script:srEnv.ckpts -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs `
            -ReceiptDir $recsF3 -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags -NextIntent $intentNextF3
        Assert-SR (([bool]$scF3.ok) -and [bool]$scF3.prepared) '[F3] setup continuation prepares under the explicit root' ([string]$scF3.reason)
        # NOTE: -Receipts is deliberately omitted here so the module
        # resolves the namespace from the forwarded RepoRoot (F3).
        $rF3 = Invoke-SRRecovery -GoalId $idsF3.goal -Key $keyF3 -Auth $gF3.auth -Sub 'ses_s4_sub_A' -RepoRoot $fakeRepoF3
        Assert-SR (([bool]$rF3.ok) -and ([string]$rF3.action -ceq 'replay-prepared') -and ([bool]$rF3.prepared) -and ([string]$rF3.next_idempotency_key -ceq $nextKeyF3)) '[F3] an omitted ReceiptDir resolves via the forwarded RepoRoot' ('action=' + [string]$rF3.action)
        $advIsoF3 = Get-NDAdvanceDir -RootDir $recsF3 -GoalId $idsF3.goal
        Assert-SR (Test-Path -LiteralPath (Join-Path ([string](Get-SRValue $advIsoF3 'dir' '')) ($keyF3 + '.recovery.json')) -PathType Leaf) '[F3] the attribution lands in the forwarded namespace' ''
        $defaultNativeRoot = Get-OrchestrationDispatchRepoRoot -RepoRoot ''
        Assert-SR (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $defaultNativeRoot 'cache') 'native-dispatch-receipts') (Get-NativeDispatchHash32 $idsF3.goal)))) '[F3] the default repo tree gained no goal namespace' ''

        # ---------- S17. sentinel: zero worker/CLAIM/SETTLE/PREPARE ----------
        $modPath = Join-Path $PSScriptRoot 'OrchestrationSettledRecovery.ps1'
        $modText = [IO.File]::ReadAllText($modPath, [Text.Encoding]::UTF8)
        Assert-SR (($modText -notmatch 'Invoke-OrchestrationNativeDispatch(Prepare|Claim|Settle|Advance)\b')) '[S17] no PREPARE/CLAIM/SETTLE/ADVANCE invocation' ''
        Assert-SR (($modText -notmatch 'Confirm-OrchestrationDispatchReconciliation')) '[S17] no Confirm invocation' ''
        Assert-SR (($modText -notmatch 'Start-OrchestrationTaskAttempt')) '[S17] no worker start' ''
        Assert-SR (($modText -notmatch 'Set-OrchestrationTask(WorkerResult|Verification|Review)')) '[S17] no task result/verification/review writes' ''
        Assert-SR (($modText -notmatch 'Complete-OrchestrationTask')) '[S17] no task completion' ''
        Assert-SR (($modText -notmatch 'Invoke-OrchestrationTaskTransition')) '[S17] no task transition' ''
        Assert-SR (($modText -notmatch 'New-OrchestrationTask\b')) '[S17] no task creation' ''
        Assert-SR (($modText -notmatch '(Acquire|Takeover|Renew)-OrchestrationGoalOwnership')) '[S17] no ownership acquire/takeover/renew' ''
        Assert-SR (($modText -notmatch 'Set-OrchestrationGoalStatePersisted')) '[S17] no goal CAS' ''
        Assert-SR (($modText -notmatch 'Update-OrchestrationGoal')) '[S17] no goal update' ''
        Assert-SR (($modText -notmatch 'Get-OrchestrationNextMove')) '[S17] no Controller call' ''
        Assert-SR (($modText -notmatch 'Invoke-OrchestrationObjectiveStep')) '[S17] no objective step' ''
        Assert-SR (($modText -notmatch 'Invoke-ALObjectiveCompletion')) '[S17] no completion helper' ''
        Assert-SR (($modText -notmatch 'Test-SCContinueGate')) '[S17] no continue gate' ''
        Assert-SR (($modText -notmatch 'Write-ND(Receipt|AdvanceRecord|AdmissionRecord)')) '[S17] no ND store writes' ''
        Assert-SR (($modText -match 'Invoke-OrchestrationSettledContinuation')) '[S17] replay delegates to S3a' ''
        Assert-SR (($modText -match 'Test-NativeDispatchAuthorization')) '[S17] auth uses the ND authority helper' ''
        Assert-SR (($modText -match 'Test-SRSettledSnapshot')) '[S17] post-lock settlement is revalidated' ''
        Assert-SR (($modText -match 'successor-integrity-invalid')) '[S17] successor semantic integrity is enforced' ''
        Assert-SR (($modText -match 'intended_action')) '[S17] the assigned intent is persisted and bound' ''
        Assert-SR (($modText -match 'record-unverified-after-replay|reserve-unverified')) '[S17] partial failures are distinguished from no-effect refusals' ''
        Assert-SR ((($modText -notmatch 'Start-Process') -and ($modText -notmatch 'Invoke-WebRequest') -and ($modText -notmatch 'HttpClient') -and ($modText -notmatch 'while\s*\(\s*\$true'))) '[S17] no spawn/network/busy-loop' ''

        # ---------- S18. compatibility without SettledKey ----------
        $ids18 = New-SRIds -Tag 'compat'
        $g18 = New-SRGoal -GoalId $ids18.goal
        New-SRTask -TaskId $ids18.task -GoalId $ids18.goal -Gen $g18.gen -Risk 'low'
        $live18 = Get-SRLiveGoal -GoalId $ids18.goal
        $ph18 = Get-NativeDispatchHash32 's4-compat-prompt'
        $spec18 = @{
            task_id = $ids18.task; task_expected_revision = (Get-SRTaskRev -TaskId $ids18.task); agent = 'coder'
            prompt_hash = $ph18; scope = @('s4/a.txt'); acceptance_criteria = @('criterion:0')
            owner = 'planner-1'; ownership_generation = $g18.gen; base_revision = 's4-base'
        }
        $s18 = Invoke-OrchestrationObjectiveStep -Goal $live18 -CheckpointDir $script:srEnv.ckpts -Authorization $g18.auth -DispatchSpec $spec18 `
            -GoalStoreDir $script:srEnv.goals -EvidenceStoreDir $script:srEnv.evs -ReceiptDir $script:srEnv.recs `
            -TasksDir $script:srEnv.tasks -FlagsPath $script:srEnv.flags
        Assert-SR (([string]$s18.action -ceq 'dispatch_intent')) '[S18] without SettledKey the legacy path is intact' ('action=' + [string]$s18.action + ' reason=' + [string]$s18.reason)
        Assert-SR ([bool]$s18.checkpoint_ok) '[S18] legacy step checkpoints' ([string]$s18.checkpoint_id)

        # ---------- hygiene ----------
        $selfPath = Join-Path $PSScriptRoot 'OrchestrationSettledRecovery.tests.ps1'
        foreach ($p in @($modPath, $selfPath)) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-SR ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
        $roots = @(Get-ChildItem -LiteralPath $script:srEnv.root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
        $knownRoots = @('checkpoints', 'evidence', 'fakerepo', 'goals', 'receipts', 'recs-f2b', 'recs-f2c', 'recs-f2g', 'recs-swap', 'tasks', 'telemetry')
        $extraRoots = @(Compare-Object -ReferenceObject $knownRoots -DifferenceObject @($roots) | Where-Object { $_.SideIndicator -ceq '=>' } | ForEach-Object { $_.InputObject })
        Assert-SR (@($extraRoots).Count -eq 0) '[HYG] no parallel store was created' (@($extraRoots) -join ',')
    }
    finally {
        try { Restore-SRStubMove } catch { }
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
