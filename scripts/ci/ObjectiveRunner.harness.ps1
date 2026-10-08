<#!
.SYNOPSIS
    TEST HARNESS - NOT PRODUCT: deterministic Objective loop driver (SPEC v0.1.0 Phase 15).
.DESCRIPTION
    TEST HARNESS - NOT PRODUCT. Dot-sourceable library (no execution on
    load beyond eager best-effort lib loading). Deterministic bounded
    driver over the REAL libs (OrchestrationGoalKernel,
    OrchestrationObjectiveController, OrchestrationGoalProgress,
    OrchestrationGoalCheckpoint). Fail-closed, PS 5.1 compatible,
    ASCII-only. Never throws on operational paths: every failure
    returns a fail-closed result envelope. No network, no process, no
    sleep, no grants, no leases, no prompts.

    TDR-F15-01: Invoke-OrchestrationObjectiveRunner -GoalId -StoreDir
    -Script @() drives one synthetic-outcome list iteration by iteration
    (one outcome per iteration: @{complete_tasks=@(); fail_task=$null or
    'recoverable'; add_finding=[bool]; satisfy=[long], -1 means no change}).
    BOUNDED loop (MaxIterations 20, fail-closed): each iteration re-reads
    the goal from disk exactly as a fresh session would, applies the
    script outcome (completes tasks, records failed_strategy on
    recoverable failure, scores progress via GoalProgress, snapshots a
    checkpoint per wave), then derives the controller status from the
    PERSISTED goal (last_failure recoverable with remaining work, or
    strategy_change from a finding / GoalProgress stagnation) and
    consumes the REAL move from Get-OrchestrationNextMove: RETRY,
    REPLAN, CONTINUE or COMPLETE. There are NO scripted moves: history
    carries move == controller_move on every entry (any divergence
    fails the run). Re-review at lib level is criteria revalidation
    (satisfy advanced to total) plus the recorded decision in history.
    The loop ends on COMPLETE consumed from the controller
    (OBJECTIVE_COMPLETED, persisted) or on iteration-cap EXHAUSTED
    (reason 'harness-iteration-cap', NEVER confused with COMPLETE).
    Terminal states (COMPLETED / EXHAUSTED) are only ever returned
    after Set + Save with ok=true AND a disk re-read confirming the
    terminal state; any persistence failure (including a failed budget
    update or checkpoint save) returns 'harness-persist-failed' (never
    a false terminal). Returns @{stop_reason; goal_state; iterations;
    prompts=0 (literal counter: this harness owns no prompt primitive -
    reported as a structural fact, not a measurement); history=@()}.

    Lib loading: the REAL libs are dot-sourced at the TOP of this file
    (script scope, outside any function, best-effort and never
    throwing), so a fresh process that dot-sources ONLY this harness
    drives the loop with no preload. Invoke- verifies every required
    command is present (lazy fallback included); when any is missing it
    returns 'harness-lib-missing' without throwing.
#>
[CmdletBinding()]
param()

try {
    $orhTopCiDir = $PSScriptRoot
    if (-not [string]::IsNullOrWhiteSpace($orhTopCiDir)) {
        $orhTopLibDir = Join-Path (Join-Path (Split-Path -Parent $orhTopCiDir) 'v3') 'lib'
        foreach ($orhTopFile in @('OrchestrationGoalKernel.ps1', 'OrchestrationObjectiveController.ps1', 'OrchestrationGoalProgress.ps1', 'OrchestrationGoalCheckpoint.ps1')) {
            try {
                $orhTopPath = Join-Path $orhTopLibDir $orhTopFile
                if (Test-Path -LiteralPath $orhTopPath -PathType Leaf) { . $orhTopPath }
            }
            catch { }
        }
    }
}
catch { }
try { Remove-Variable -Name orhTopPath -Scope Script -ErrorAction SilentlyContinue } catch { }
try { Remove-Variable -Name orhTopFile -Scope Script -ErrorAction SilentlyContinue } catch { }
try { Remove-Variable -Name orhTopLibDir -Scope Script -ErrorAction SilentlyContinue } catch { }
try { Remove-Variable -Name orhTopCiDir -Scope Script -ErrorAction SilentlyContinue } catch { }

function Get-ORHValue {
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

function Get-ORHLong {
    param($Value, [long]$Default = -1)
    try {
        if ($Value -is [long]) { return [long]$Value }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [short]) { return [long]$Value }
        return $Default
    }
    catch { return $Default }
}

function Get-ORHStringList {
    param($Value)
    try {
        if ($null -eq $Value) { return ,([string[]]@()) }
        if ($Value -is [string]) {
            if ([string]::IsNullOrWhiteSpace([string]$Value)) { return ,([string[]]@()) }
            return ,([string[]]@([string]$Value))
        }
        $out = New-Object System.Collections.ArrayList
        foreach ($item in @($Value)) {
            if ($item -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace([string]$item)) { [void]$out.Add([string]$item) }
            }
            else { return $null }
        }
        return ,([string[]]$out.ToArray())
    }
    catch { return $null }
}

function Get-ORHLibDir {
    try {
        $ci = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($ci)) { return '' }
        $scripts = Split-Path -Parent $ci
        if ([string]::IsNullOrWhiteSpace($scripts)) { return '' }
        return (Join-Path (Join-Path $scripts 'v3') 'lib')
    }
    catch { return '' }
}

function Import-ORHLib {
    param([string]$FileName, [string]$Command)
    try {
        $cmd = Get-Command $Command -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return $true }
        $dir = Get-ORHLibDir
        if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
        $path = Join-Path $dir $FileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        try { . $path } catch { return $false }
        $cmd = Get-Command $Command -ErrorAction SilentlyContinue
        return ($null -ne $cmd)
    }
    catch { return $false }
}

function New-ORHResult {
    param([string]$StopReason = '', [string]$GoalState = '', [long]$Iterations = 0, $History = $null)
    try {
        $h = @()
        if ($null -ne $History) { $h = @($History) }
        return [PSCustomObject][ordered]@{
            stop_reason = ([string]$StopReason)
            goal_state  = ([string]$GoalState)
            iterations  = ([long]$Iterations)
            prompts     = ([long]0)
            history     = $h
        }
    }
    catch {
        return [PSCustomObject][ordered]@{
            stop_reason = 'harness-internal'
            goal_state  = ''
            iterations  = ([long]0)
            prompts     = ([long]0)
            history     = @()
        }
    }
}

function Confirm-ORHTerminalState {
    param($Goal = $null, [string]$GoalId = '', [string]$StoreDir = '', [string]$ToState = '')
    try {
        $target = ([string]$ToState).Trim()
        if ([string]::IsNullOrWhiteSpace($target)) { return [pscustomobject]@{ ok = $false; goal = $null } }
        $tr = Set-OrchestrationGoalState -Goal $Goal -ToState $target
        if (($null -eq $tr) -or (-not [bool](Get-ORHValue $tr 'ok' $false))) {
            return [pscustomobject]@{ ok = $false; goal = $null }
        }
        $sv = Save-OrchestrationGoal -Goal (Get-ORHValue $tr 'goal' $null) -StoreDir $StoreDir
        if (($null -eq $sv) -or (-not [bool](Get-ORHValue $sv 'ok' $false))) {
            return [pscustomobject]@{ ok = $false; goal = $null }
        }
        $re = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $StoreDir
        if (($null -eq $re) -or (-not [bool](Get-ORHValue $re 'ok' $false))) {
            return [pscustomobject]@{ ok = $false; goal = $null }
        }
        $rg = Get-ORHValue $re 'goal' $null
        if ([string](Get-ORHValue $rg 'state' '') -cne $target) {
            return [pscustomobject]@{ ok = $false; goal = $null }
        }
        return [pscustomobject]@{ ok = $true; goal = $rg }
    }
    catch {
        return [pscustomobject]@{ ok = $false; goal = $null }
    }
}

function Invoke-OrchestrationObjectiveRunner {
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$StoreDir = '',
        $Script = @(),
        [long]$MaxIterations = 20
    )
    try {
        $okKernel = Import-ORHLib 'OrchestrationGoalKernel.ps1' 'Get-OrchestrationGoal'
        $okCtrl = Import-ORHLib 'OrchestrationObjectiveController.ps1' 'Get-OrchestrationNextMove'
        $okProg = Import-ORHLib 'OrchestrationGoalProgress.ps1' 'Get-OrchestrationGoalProgressDelta'
        $okCk = Import-ORHLib 'OrchestrationGoalCheckpoint.ps1' 'New-OrchestrationGoalCheckpoint'
        $okLibs = ($okKernel -and $okCtrl -and $okProg -and $okCk)
        if ($okLibs) {
            foreach ($needCmd in @('Update-OrchestrationGoal', 'Save-OrchestrationGoal', 'Set-OrchestrationGoalState', 'Add-OrchestrationGoalTask', 'Complete-OrchestrationGoalTask', 'Save-OrchestrationGoalCheckpoint')) {
                if ($null -eq (Get-Command $needCmd -ErrorAction SilentlyContinue)) { $okLibs = $false }
            }
        }
        if (-not $okLibs) {
            return (New-ORHResult -StopReason 'harness-lib-missing' -GoalState '' -Iterations 0)
        }
        $gid = ([string]$GoalId).Trim()
        $dir = ([string]$StoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($gid) -or [string]::IsNullOrWhiteSpace($dir)) {
            return (New-ORHResult -StopReason 'harness-invalid-args' -GoalState '' -Iterations 0)
        }
        $cap = Get-ORHLong $MaxIterations 20
        if ($cap -lt 1) { $cap = 1 }
        if ($cap -gt 20) { $cap = 20 }
        $steps = @()
        if ($null -ne $Script) {
            if ($Script -is [System.Collections.IDictionary] -or ($Script -is [pscustomobject])) { $steps = @($Script) }
            else { $steps = @($Script) }
        }
        $ckDir = Join-Path $dir 'checkpoints'
        $history = New-Object System.Collections.ArrayList
        $prevSnap = $null
        $stag = [long]0
        $lastState = ''
        for ($i = [long]0; $i -lt $cap; $i++) {
            $got = Get-OrchestrationGoal -GoalId $gid -StoreDir $dir
            if (($null -eq $got) -or (-not [bool](Get-ORHValue $got 'ok' $false)) -or ($null -eq (Get-ORHValue $got 'goal' $null))) {
                return (New-ORHResult -StopReason 'harness-goal-unreadable' -GoalState $lastState -Iterations $i -History @($history.ToArray()))
            }
            $goal = Get-ORHValue $got 'goal' $null
            $state = [string](Get-ORHValue $goal 'state' '')
            $lastState = $state
            if ($state -ceq 'COMPLETED') {
                return (New-ORHResult -StopReason 'OBJECTIVE_COMPLETED' -GoalState 'COMPLETED' -Iterations $i -History @($history.ToArray()))
            }
            if ($state -ceq 'EXHAUSTED') {
                return (New-ORHResult -StopReason 'GOAL_HARD_BUDGET_EXHAUSTED' -GoalState 'EXHAUSTED' -Iterations $i -History @($history.ToArray()))
            }
            if ($state -ceq 'CANCELLED') {
                return (New-ORHResult -StopReason 'CANCELLED' -GoalState 'CANCELLED' -Iterations $i -History @($history.ToArray()))
            }
            $rawBudget = Get-ORHValue $goal 'budget' $null
            $hard = Get-ORHLong (Get-ORHValue $rawBudget 'hard_cap' $null) 0
            $soft = Get-ORHLong (Get-ORHValue $rawBudget 'soft_cap' $null) 0
            $spent = Get-ORHLong (Get-ORHValue $rawBudget 'spent' $null) 0
            if (($hard -gt 0) -and ($spent -ge $hard)) {
                $confB = Confirm-ORHTerminalState -Goal $goal -GoalId $gid -StoreDir $dir -ToState 'EXHAUSTED'
                if (($null -ne $confB) -and [bool](Get-ORHValue $confB 'ok' $false)) {
                    return (New-ORHResult -StopReason 'GOAL_HARD_BUDGET_EXHAUSTED' -GoalState 'EXHAUSTED' -Iterations ($i + 1) -History @($history.ToArray()))
                }
                return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
            }
            $step = $null
            if ($i -lt $steps.Count) { $step = $steps[$i] }
            $wantTasks = Get-ORHStringList (Get-ORHValue $step 'complete_tasks' @())
            if ($null -eq $wantTasks) { $wantTasks = ,([string[]]@()) }
            $failRaw = [string](Get-ORHValue $step 'fail_task' '')
            $isFail = ($failRaw.Trim().ToLowerInvariant() -ceq 'recoverable')
            $addFinding = $false
            try { $addFinding = [bool](Get-ORHValue $step 'add_finding' $false) } catch { $addFinding = $false }
            $satisfy = Get-ORHLong (Get-ORHValue $step 'satisfy' $null) -1
            $spentNext = $spent + 1
            if ($isFail) {
                $curF = Get-OrchestrationGoal -GoalId $gid -StoreDir $dir
                if (($null -eq $curF) -or (-not [bool](Get-ORHValue $curF 'ok' $false))) {
                    return (New-ORHResult -StopReason 'harness-goal-unreadable' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                }
                $wf = Get-ORHValue $curF 'goal' $null
                $lastState = [string](Get-ORHValue $wf 'state' $lastState)
                $oldFailed = Get-ORHStringList (Get-ORHValue $wf 'failed_strategies' @())
                if ($null -eq $oldFailed) { $oldFailed = ,([string[]]@()) }
                $tag = ('harness-recoverable-i' + [string]$i)
                $newFailed = @(@($oldFailed) + @($tag))
                $rawBF = Get-ORHValue $wf 'budget' $null
                $softF = Get-ORHLong (Get-ORHValue $rawBF 'soft_cap' $null) $soft
                $hardF = Get-ORHLong (Get-ORHValue $rawBF 'hard_cap' $null) $hard
                $updF = Update-OrchestrationGoal -GoalId $gid -ExpectedRevision ([long](Get-ORHValue $wf 'revision' 0)) -Fields @{ budget = @{ soft_cap = $softF; hard_cap = $hardF; spent = $spentNext }; failed_strategies = $newFailed } -StoreDir $dir
                if (($null -eq $updF) -or (-not [bool](Get-ORHValue $updF 'ok' $false))) {
                    return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                }
            }
            else {
                $cur = Get-OrchestrationGoal -GoalId $gid -StoreDir $dir
                if (($null -eq $cur) -or (-not [bool](Get-ORHValue $cur 'ok' $false))) {
                    return (New-ORHResult -StopReason 'harness-goal-unreadable' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                }
                $work = Get-ORHValue $cur 'goal' $null
                $lastState = [string](Get-ORHValue $work 'state' $lastState)
                $rawB2 = Get-ORHValue $work 'budget' $null
                $soft2 = Get-ORHLong (Get-ORHValue $rawB2 'soft_cap' $null) $soft
                $hard2 = Get-ORHLong (Get-ORHValue $rawB2 'hard_cap' $null) $hard
                $updB = Update-OrchestrationGoal -GoalId $gid -ExpectedRevision ([long](Get-ORHValue $work 'revision' 0)) -Fields @{ budget = @{ soft_cap = $soft2; hard_cap = $hard2; spent = $spentNext } } -StoreDir $dir
                if (($null -eq $updB) -or (-not [bool](Get-ORHValue $updB 'ok' $false))) {
                    return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                }
                $work = Get-ORHValue $updB 'goal' $work
                foreach ($tid in @($wantTasks)) {
                    $cc = Complete-OrchestrationGoalTask -Goal $work -TaskId ([string]$tid)
                    if (($null -ne $cc) -and [bool](Get-ORHValue $cc 'ok' $false)) { $work = Get-ORHValue $cc 'goal' $work }
                }
                $svW = Save-OrchestrationGoal -Goal $work -StoreDir $dir
                if (($null -eq $svW) -or (-not [bool](Get-ORHValue $svW 'ok' $false))) {
                    return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                }
                if ($satisfy -ge 0) {
                    $curP = Get-OrchestrationGoal -GoalId $gid -StoreDir $dir
                    if (($null -eq $curP) -or (-not [bool](Get-ORHValue $curP 'ok' $false))) {
                        return (New-ORHResult -StopReason 'harness-goal-unreadable' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                    }
                    $wp = Get-ORHValue $curP 'goal' $null
                    $rawPr = Get-ORHValue $wp 'progress' $null
                    $tot = Get-ORHLong (Get-ORHValue $rawPr 'total' $null) 0
                    $sat = $satisfy
                    if ($sat -gt $tot) { $sat = $tot }
                    $updP = Update-OrchestrationGoal -GoalId $gid -ExpectedRevision ([long](Get-ORHValue $wp 'revision' 0)) -Fields @{ progress = @{ satisfied = $sat; total = $tot } } -StoreDir $dir
                    if (($null -eq $updP) -or (-not [bool](Get-ORHValue $updP 'ok' $false))) {
                        return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                    }
                }
                if ($addFinding) {
                    $repairId = ('repair-' + [string]$i)
                    $curR = Get-OrchestrationGoal -GoalId $gid -StoreDir $dir
                    if (($null -eq $curR) -or (-not [bool](Get-ORHValue $curR 'ok' $false))) {
                        return (New-ORHResult -StopReason 'harness-goal-unreadable' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                    }
                    $wr = Get-ORHValue $curR 'goal' $null
                    $ad = Add-OrchestrationGoalTask -Goal $wr -TaskId $repairId
                    if (($null -ne $ad) -and [bool](Get-ORHValue $ad 'ok' $false)) {
                        $svR = Save-OrchestrationGoal -Goal (Get-ORHValue $ad 'goal' $null) -StoreDir $dir
                        if (($null -eq $svR) -or (-not [bool](Get-ORHValue $svR 'ok' $false))) {
                            return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                        }
                    }
                }
            }
            $post = Get-OrchestrationGoal -GoalId $gid -StoreDir $dir
            if (($null -eq $post) -or (-not [bool](Get-ORHValue $post 'ok' $false))) {
                return (New-ORHResult -StopReason 'harness-goal-unreadable' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
            }
            $wp2 = Get-ORHValue $post 'goal' $null
            $lastState = [string](Get-ORHValue $wp2 'state' $lastState)
            $rawPr2 = Get-ORHValue $wp2 'progress' $null
            $snap = @{
                satisfied    = (Get-ORHLong (Get-ORHValue $rawPr2 'satisfied' $null) 0)
                total        = (Get-ORHLong (Get-ORHValue $rawPr2 'total' $null) 0)
                failed_tests = [long]0
                open_p1      = [long]0
                blockers     = [long]0
            }
            if ($null -eq $prevSnap) {
                $prevSnap = @{
                    satisfied    = [long]0
                    total        = (Get-ORHLong (Get-ORHValue $rawPr2 'total' $null) 0)
                    failed_tests = [long]0
                    open_p1      = [long]0
                    blockers     = [long]0
                }
            }
            $delta = Get-OrchestrationGoalProgressDelta -Previous $prevSnap -Current $snap -StagnationCount $stag
            $meaningful = $false
            $scr = $false
            if ($null -eq $delta) {
                $stag = $stag + 1
            }
            else {
                try { $meaningful = [bool](Get-ORHValue $delta 'meaningful' $false) } catch { $meaningful = $false }
                try { $stag = Get-ORHLong (Get-ORHValue $delta 'stagnation_count' $stag) $stag } catch { }
                try { $scr = [bool](Get-ORHValue $delta 'strategy_change_required' $false) } catch { $scr = $false }
            }
            $prevSnap = $snap
            $ck = New-OrchestrationGoalCheckpoint -GoalRecord $wp2
            if ($null -eq $ck) {
                return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
            }
            $cks = Save-OrchestrationGoalCheckpoint -Checkpoint $ck -StoreDir $ckDir
            if (($null -eq $cks) -or (-not [bool](Get-ORHValue $cks 'ok' $false))) {
                return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
            }
            $actList = @((Get-ORHValue $wp2 'active_tasks' @()))
            $critRaw = @((Get-ORHValue $wp2 'criteria' @()))
            $rawPrW = Get-ORHValue $wp2 'progress' $null
            $satW = Get-ORHLong (Get-ORHValue $rawPrW 'satisfied' $null) 0
            $totW = Get-ORHLong (Get-ORHValue $rawPrW 'total' $null) 0
            if ($satW -lt 0) { $satW = 0 }
            if ($totW -lt 0) { $totW = 0 }
            if ($satW -gt $totW) { $satW = $totW }
            $remWork = New-Object System.Collections.ArrayList
            foreach ($at in $actList) { [void]$remWork.Add([string]$at) }
            for ($ci2 = $satW; $ci2 -lt $critRaw.Count; $ci2++) {
                if ($ci2 -lt $totW) { [void]$remWork.Add(('criterion:' + [string]$critRaw[$ci2])) }
            }
            $completedW = (($actList.Count -eq 0) -and ($totW -gt 0) -and ($satW -ge $totW))
            $authorizedW = (@('BLOCKED', 'CANCELLED', 'EXHAUSTED') -cnotcontains $lastState)
            $blockerKindW = ''
            if ($lastState -ceq 'BUDGET_LIMITED') { $blockerKindW = 'policy' }
            $progressPossibleW = ($lastState -ceq 'ACTIVE')
            $strategyW = ([bool]$addFinding -or [bool]$scr)
            $failSig = $null
            if ($isFail) { $failSig = 'recoverable' }
            $remArr = @($remWork.ToArray())
            $remStatus = $null
            if ($remArr.Count -gt 0) { $remStatus = [string[]]$remArr }
            $status = @{
                objective_completed     = [bool]$completedW
                remaining_work          = $remStatus
                authorized              = [bool]$authorizedW
                blocker_kind            = [string]$blockerKindW
                progress_possible       = [bool]$progressPossibleW
                strategy_change         = [bool]$strategyW
                context_degraded        = $false
                last_failure            = $failSig
                terminal_blocker        = $null
                consecutive_no_progress = ([long]$stag)
            }
            $mv = $null
            try { $mv = Get-OrchestrationNextMove -Status $status } catch { $mv = $null }
            if ($null -eq $mv) {
                return (New-ORHResult -StopReason 'harness-next-move-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
            }
            $move = [string](Get-ORHValue $mv 'move' '')
            $reason = [string](Get-ORHValue $mv 'reason' '')
            if ([string]::IsNullOrWhiteSpace($move)) {
                return (New-ORHResult -StopReason 'harness-next-move-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
            }
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'delegate-continue' }
            [void]$history.Add([PSCustomObject][ordered]@{
                    iteration       = ([long]$i)
                    move            = ([string]$move)
                    controller_move = ([string]$move)
                    reason          = ([string]$reason)
                    meaningful      = ([bool]$meaningful)
                })
            if ($move -ceq 'COMPLETE') {
                $sr = [string](Get-ORHValue $mv 'stop_reason' '')
                if ([string]::IsNullOrWhiteSpace($sr)) { $sr = 'POLICY_BLOCKED' }
                if ($sr -ceq 'OBJECTIVE_COMPLETED') {
                    $conf = Confirm-ORHTerminalState -Goal $wp2 -GoalId $gid -StoreDir $dir -ToState 'COMPLETED'
                    if (($null -ne $conf) -and [bool](Get-ORHValue $conf 'ok' $false)) {
                        return (New-ORHResult -StopReason 'OBJECTIVE_COMPLETED' -GoalState 'COMPLETED' -Iterations ($i + 1) -History @($history.ToArray()))
                    }
                    return (New-ORHResult -StopReason 'harness-persist-failed' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
                }
                return (New-ORHResult -StopReason 'harness-unexpected-complete' -GoalState $lastState -Iterations ($i + 1) -History @($history.ToArray()))
            }
        }
        $tail = Get-OrchestrationGoal -GoalId $gid -StoreDir $dir
        $tailState = $lastState
        if (($null -ne $tail) -and [bool](Get-ORHValue $tail 'ok' $false)) {
            $tailState = [string](Get-ORHValue (Get-ORHValue $tail 'goal' $null) 'state' $lastState)
        }
        return (New-ORHResult -StopReason 'harness-iteration-cap' -GoalState $tailState -Iterations $cap -History @($history.ToArray()))
    }
    catch {
        return (New-ORHResult -StopReason 'harness-internal' -GoalState '' -Iterations 0)
    }
}
