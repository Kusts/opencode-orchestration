<#
.SYNOPSIS
    Thin CLI harness for the P0 autonomy proof; manages GoalKernel state only.
.DESCRIPTION
    No product implementation, implementation tests, scheduler, or controller.
    PowerShell 5.1/7 compatible, ASCII-only, no network.
#>
[CmdletBinding()]
param(
    [string]$Action = '',
    [string]$StoreDir = 'evidence/evolution-2026-11-10/p0-autonomy/goals',
    [string]$GoalId = 'p0-autonomy-20261111',
    [string]$TaskId = '',
    [string]$EvidencePath = '',
    [string]$Summary = '',
    [string]$Reason = '',
    [string]$Severity = 'medium',
    [int]$Attempts = 0,
    [string]$OwnerId = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationGoalKernel.ps1')

function Stop-P0Proof {
    param([string]$Message, [int]$Code)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Write-P0ProofJson {
    param($Value)
    Write-Output (ConvertTo-Json -InputObject $Value -Depth 12 -Compress)
}

function Get-P0ProofGoal {
    $loaded = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $StoreDir
    if (-not [bool]$loaded.ok) { Stop-P0Proof ('Goal read failed: ' + [string]$loaded.reason) 1 }
    return $loaded.goal
}

function Get-P0ProofOwnership {
    param($Goal, [switch]$AllowTakeover)
    $ownership = $Goal['ownership']
    if ($null -eq $ownership) { Stop-P0Proof 'Goal has no persisted ownership.' 1 }
    $storedOwner = [string]$ownership['owner_id']
    $storedGeneration = [long]$ownership['generation']
    $requestedOwner = $storedOwner
    if (-not [string]::IsNullOrWhiteSpace($OwnerId)) { $requestedOwner = $OwnerId.Trim() }
    if ($requestedOwner -cne $storedOwner) {
        if (-not $AllowTakeover) { Stop-P0Proof 'Requested owner does not match persisted Goal owner.' 1 }
        $takeover = Takeover-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId $requestedOwner -StoreDir $StoreDir
        if (-not [bool]$takeover.ok) { Stop-P0Proof ('Goal ownership takeover failed: ' + [string]$takeover.reason) 1 }
        $Goal = Get-P0ProofGoal
        $ownership = $Goal['ownership']
        return [pscustomobject]@{ Goal = $Goal; OwnerId = [string]$ownership['owner_id']; Generation = [long]$ownership['generation'] }
    }
    $expires = [DateTime]::MinValue
    $expiryValid = [DateTime]::TryParse([string]$ownership['expires_at'], [ref]$expires)
    if (-not $expiryValid) { Stop-P0Proof 'Persisted ownership lease is invalid.' 1 }
    if ([DateTime]::UtcNow -ge $expires.ToUniversalTime()) {
        if (-not $AllowTakeover) { Stop-P0Proof 'Persisted ownership lease expired.' 1 }
        $takeover = Takeover-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId $requestedOwner -StoreDir $StoreDir
        if (-not [bool]$takeover.ok) { Stop-P0Proof ('Goal ownership takeover failed: ' + [string]$takeover.reason) 1 }
        $Goal = Get-P0ProofGoal
        $ownership = $Goal['ownership']
        return [pscustomobject]@{ Goal = $Goal; OwnerId = [string]$ownership['owner_id']; Generation = [long]$ownership['generation'] }
    }
    return [pscustomobject]@{ Goal = $Goal; OwnerId = $storedOwner; Generation = $storedGeneration }
}

function Get-P0ProofNextMove {
    param($Goal)
    $result = Get-OrchestrationGoalNextMove -Goal $Goal
    if (-not [bool]$result.ok) { Stop-P0Proof ('Next-move lookup failed: ' + [string]$result.reason) 1 }
    return $result.next_move
}

$actionValue = $Action.Trim().ToLowerInvariant()
if (@('init', 'record-task', 'record-failure', 'next', 'resume', 'complete', 'status') -cnotcontains $actionValue) {
    Stop-P0Proof 'Usage: p0-autonomy-proof.ps1 -Action init|record-task|record-failure|next|resume|complete|status' 2
}
if ([string]::IsNullOrWhiteSpace($GoalId) -or [string]::IsNullOrWhiteSpace($StoreDir)) {
    Stop-P0Proof '-GoalId and -StoreDir must be non-empty.' 2
}

switch ($actionValue) {
    'init' {
        $existing = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $StoreDir
        if ([bool]$existing.ok) {
            $current = $existing.goal
            $ownership = $current['ownership']
            Write-P0ProofJson ([ordered]@{
                ok = $true; goal_id = [string]$current['goal_id']; revision = [long]$current['revision']
                owner_id = [string]$ownership['owner_id']; generation = [long]$ownership['generation']; active_tasks = @($current['active_tasks'])
            })
            exit 0
        }
        if ([string]$existing.reason -cne 'goal-not-found') { Stop-P0Proof ('Goal read failed: ' + [string]$existing.reason) 1 }
        $created = New-OrchestrationGoal -GoalId $GoalId -Objective 'P0 autonomy proof: three Tasks, real failure and replan, process resume, Goal completion.' `
            -Criteria @('task1-artifact-verified', 'task2-failure-replanned', 'task3-independent-validation') -TotalPhases 3 -StoreDir $StoreDir
        if (-not [bool]$created.ok) { Stop-P0Proof ('Goal create failed: ' + [string]$created.reason) 1 }
        $saved = Save-OrchestrationGoal -Goal $created.goal -StoreDir $StoreDir
        if (-not [bool]$saved.ok) { Stop-P0Proof ('Goal save failed: ' + [string]$saved.reason) 1 }
        $owner = $OwnerId
        if ([string]::IsNullOrWhiteSpace($owner)) { $owner = 'p0-planner' }
        $acquired = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId $owner -ExpectedRevision ([long]$saved.revision) -StoreDir $StoreDir
        if (-not [bool]$acquired.ok) { Stop-P0Proof ('Goal ownership acquire failed: ' + [string]$acquired.reason) 1 }
        $goal = Get-P0ProofGoal
        $active = Set-OrchestrationGoalStatePersisted -GoalId $GoalId -ToState 'ACTIVE' -ExpectedRevision ([long]$goal['revision']) `
            -StoreDir $StoreDir -OwnerId $owner -OwnershipGeneration ([long]$acquired.ownership['generation'])
        if (-not [bool]$active.ok) { Stop-P0Proof ('Goal activation failed: ' + [string]$active.reason) 1 }
        $goal = $active.goal
        foreach ($task in @('T1', 'T2', 'T3')) {
            $added = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $task -ExpectedRevision ([long]$goal['revision']) `
                -StoreDir $StoreDir -OwnerId $owner -OwnershipGeneration ([long]$acquired.ownership['generation'])
            if (-not [bool]$added.ok) { Stop-P0Proof ('Adding ' + $task + ' failed: ' + [string]$added.reason) 1 }
            $goal = $added.goal
        }
        Write-P0ProofJson ([ordered]@{
            ok = $true; goal_id = [string]$goal['goal_id']; revision = [long]$goal['revision']; owner_id = $owner
            generation = [long]$acquired.ownership['generation']; active_tasks = @($goal['active_tasks'])
        })
        exit 0
    }
    'record-task' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($EvidencePath)) { Stop-P0Proof 'record-task requires -TaskId and -EvidencePath.' 2 }
        if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) { Stop-P0Proof 'EvidencePath must identify an existing file.' 2 }
        $goal = Get-P0ProofGoal
        $activeTasks = @($goal['active_tasks'])
        if ($activeTasks -cnotcontains $TaskId) { Stop-P0Proof 'Task is not active in this Goal.' 1 }
        $completed = @($goal['completed_tasks'])
        $ordered = @('T1', 'T2', 'T3')
        $nextTask = ''
        foreach ($orderedTask in $ordered) { if ($completed -cnotcontains $orderedTask) { $nextTask = $orderedTask; break } }
        if ($TaskId -cne $nextTask) { Stop-P0Proof ('Out of order: next pending task is ' + $nextTask + '.') 1 }
        $identity = Get-P0ProofOwnership -Goal $goal -AllowTakeover
        $goal = $identity.Goal
        $completion = Complete-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $TaskId -ExpectedRevision ([long]$goal['revision']) `
            -StoreDir $StoreDir -OwnerId $identity.OwnerId -OwnershipGeneration $identity.Generation
        if (-not [bool]$completion.ok) { Stop-P0Proof ('Task completion failed: ' + [string]$completion.reason) 1 }
        $goal = Get-P0ProofGoal
        $progress = $goal['progress']
        $evidenceRefs = @($goal['evidence_refs']) + @($TaskId + ':' + (Resolve-Path -LiteralPath $EvidencePath).Path)
        $decisionRefs = @($goal['decision_refs'])
        if (-not [string]::IsNullOrWhiteSpace($Summary)) { $decisionRefs += ($TaskId + ':summary:' + $Summary) }
        $fields = [ordered]@{
            progress = [ordered]@{ satisfied = ([long]$progress['satisfied'] + 1); total = [long]$progress['total']; updated_at = [string]$progress['updated_at'] }
            evidence_refs = $evidenceRefs
            decision_refs = $decisionRefs
        }
        $updated = Update-OrchestrationGoal -GoalId $GoalId -ExpectedRevision ([long]$goal['revision']) -Fields $fields `
            -StoreDir $StoreDir -OwnerId $identity.OwnerId -OwnershipGeneration $identity.Generation
        if (-not [bool]$updated.ok) { Stop-P0Proof ('Task completed but Goal evidence/progress update failed: ' + [string]$updated.reason) 1 }
        $final = $updated.goal
        Write-P0ProofJson ([ordered]@{ ok = $true; task_id = $TaskId; completed_tasks = @($final['completed_tasks']); satisfied = [long]$final['progress']['satisfied']; revision = [long]$final['revision'] })
        exit 0
    }
    'record-failure' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Reason)) { Stop-P0Proof 'record-failure requires -TaskId and -Reason.' 2 }
        if (@('low', 'medium', 'high', 'critical') -cnotcontains $Severity.ToLowerInvariant()) { Stop-P0Proof '-Severity must be low, medium, high, or critical.' 2 }
        if ($Attempts -lt 0) { Stop-P0Proof '-Attempts must be >= 0.' 2 }
        $goal = Get-P0ProofGoal
        if (@($goal['active_tasks']) -cnotcontains $TaskId) { Stop-P0Proof 'Task is not active in this Goal.' 1 }
        $identity = Get-P0ProofOwnership -Goal $goal -AllowTakeover
        $goal = $identity.Goal
        $entry = [ordered]@{ task_id = $TaskId; reason = $Reason; severity = $Severity.ToLowerInvariant(); attempts = $Attempts; at = [DateTime]::UtcNow.ToString('o') }
        $failed = @($goal['failed_strategies']) + @((ConvertTo-Json -InputObject $entry -Depth 5 -Compress))
        $updated = Update-OrchestrationGoal -GoalId $GoalId -ExpectedRevision ([long]$goal['revision']) -Fields @{ failed_strategies = $failed } `
            -StoreDir $StoreDir -OwnerId $identity.OwnerId -OwnershipGeneration $identity.Generation
        if (-not [bool]$updated.ok) { Stop-P0Proof ('Failure record failed: ' + [string]$updated.reason) 1 }
        $final = $updated.goal
        Write-P0ProofJson ([ordered]@{ ok = $true; task_id = $TaskId; completed_tasks = @($final['completed_tasks']); failed_strategies = @($final['failed_strategies']); revision = [long]$final['revision'] })
        exit 0
    }
    'next' {
        $goal = Get-P0ProofGoal
        $next = Get-P0ProofNextMove -Goal $goal
        Write-P0ProofJson ([ordered]@{ ok = $true; state = [string]$goal['state']; remaining_tasks = @($goal['active_tasks']); satisfied = [long]$goal['progress']['satisfied']; total = [long]$goal['progress']['total']; next_move = $next })
        exit 0
    }
    'resume' {
        $goal = Get-P0ProofGoal
        $next = Get-P0ProofNextMove -Goal $goal
        Write-P0ProofJson ([ordered]@{ ok = $true; state = [string]$goal['state']; revision = [long]$goal['revision']; completed_tasks = @($goal['completed_tasks']); active_tasks = @($goal['active_tasks']); next_move = $next; resume_source = 'goal-store' })
        exit 0
    }
    'complete' {
        $goal = Get-P0ProofGoal
        if (@('T1', 'T2', 'T3') | Where-Object { @($goal['completed_tasks']) -cnotcontains $_ }) { Stop-P0Proof 'Cannot complete Goal: T1, T2, and T3 must all be completed.' 1 }
        if ([long]$goal['progress']['satisfied'] -ne 3) { Stop-P0Proof 'Cannot complete Goal: progress.satisfied must equal 3.' 1 }
        $identity = Get-P0ProofOwnership -Goal $goal -AllowTakeover
        $goal = $identity.Goal
        $result = Set-OrchestrationGoalStatePersisted -GoalId $GoalId -ToState 'COMPLETED' -ExpectedRevision ([long]$goal['revision']) `
            -StoreDir $StoreDir -OwnerId $identity.OwnerId -OwnershipGeneration $identity.Generation
        if (-not [bool]$result.ok) { Stop-P0Proof ('Goal completion failed: ' + [string]$result.reason) 1 }
        Write-P0ProofJson ([ordered]@{ ok = $true; state = [string]$result.goal['state']; revision = [long]$result.goal['revision'] })
        exit 0
    }
    'status' {
        $goal = Get-P0ProofGoal
        Write-P0ProofJson ([ordered]@{ ok = $true; state = [string]$goal['state']; revision = [long]$goal['revision']; tasks = [ordered]@{ active = @($goal['active_tasks']); completed = @($goal['completed_tasks']) }; progress = $goal['progress'] })
        exit 0
    }
}
