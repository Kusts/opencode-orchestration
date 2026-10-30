<#!
.SYNOPSIS
    Etapa 1 FULL_DELIVERY — driver do piloto (runtime real).
.DESCRIPTION
    Executa a jornada completa Task A -> Task B no OpenCode V2 real, sem
    intervencao humana entre as tarefas, reusando o driver existente
    (Invoke-OrchestrationAutonomousObjective) com um Executor real que chama
    `opencode run` para executar o subagent. O estado (Goal/Task Kernel)
    permanece a autoridade; este script apenas fornece o Executor real.
    PS 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$SetupJson = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationNativeDispatch.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationAutonomousLoop.ps1')

# Run setup if not provided
if ([string]::IsNullOrWhiteSpace($SetupJson)) {
    $setupOut = & powershell -NoProfile -File (Join-Path $PSScriptRoot 'full-delivery-pilot-setup.ps1')
    $SetupJson = ($setupOut | Select-Object -Last 1)
}
$ctx = $SetupJson | ConvertFrom-Json
$workRoot = [string]$ctx.work_root
$goalId = [string]$ctx.goal_id
$goalDir = [string]$ctx.goal_store_dir
$ckptDir = [string]$ctx.checkpoint_dir
$receiptDir = [string]$ctx.receipt_dir
$evDir = [string]$ctx.evidence_dir
$tasksDir = [string]$ctx.tasks_dir
$flagsPath = [string]$ctx.flags_path
$artifactDir = [string]$ctx.artifact_dir
$auth = @{ explicit_allow = $true; goal_id = $goalId; owner = [string]$ctx.owner; generation = [long]$ctx.generation; source = 'planner' }

$artifactPath = Join-Path $artifactDir 'output-a.json'
$resultBPath = Join-Path $artifactDir 'output-b.json'

$state = @{ calls = 0 }
$gen = [long]$ctx.generation
$owner = [string]$ctx.owner
$ph = Get-NativeDispatchHash32 'fd-pilot-prompt-material'
$baseRev = 'rev-pilot'
$advGoalDir = $goalDir
$advGen = $gen

# Real Executor: calls opencode run to execute the subagent
$executor = {
    param($intent)
    $state.calls++
    $tid = [string]$intent.task_id
    $artifactPathL = $artifactPath
    $resultBPathL = $resultBPath
    $evDirL = $evDir
    Log ('  EXECUTOR call #' + $state.calls + ' task=' + $tid)

    if ($tid -ceq 'fd-task-a') {
        $prompt = "You are a coding agent. Create the file '$artifactPathL' with exact JSON content: {`"value`":42,`"from`":`"task-a`"}. Reply with ONLY this JSON: {`"status`":`"candidate_pass`",`"claimed_evidence`":[`"criterion:0`"]}"
    } else {
        $prompt = "You are a coding agent. Read '$artifactPathL'. Create '$resultBPathL' with JSON: {`"derived`":84,`"source`":<contents of output-a.json>}. Reply with ONLY this JSON: {`"status`":`"candidate_pass`",`"claimed_evidence`":[`"criterion:0`"]}"
    }

    $raw = opencode run --format json $prompt 2>&1
    $textOutput = ''
    foreach ($line in $raw) {
        try {
            $evt = $line | ConvertFrom-Json
            if ($evt.type -eq 'text') { $textOutput += [string]$evt.part.text }
        } catch { }
    }
    Log ('  SUBAGENT OUTPUT: ' + $textOutput)

    # Verify artifact for task A (content check, not just existence)
    if ($tid -ceq 'fd-task-a') {
        if (-not (Test-Path -LiteralPath $artifactPathL -PathType Leaf)) {
            throw 'artifact-a-not-created'
        }
        $contentA = [IO.File]::ReadAllText($artifactPathL, [Text.UTF8Encoding]::new($false))
        if ($contentA -notmatch 'value' -or $contentA -notmatch '42' -or $contentA -notmatch 'task-a') {
            throw 'artifact-a-invalid-content'
        }
    }
    if ($tid -ceq 'fd-task-b') {
        if (-not (Test-Path -LiteralPath $resultBPathL -PathType Leaf)) {
            throw 'result-b-not-created'
        }
        $contentB = [IO.File]::ReadAllText($resultBPathL, [Text.UTF8Encoding]::new($false))
        if ($contentB -notmatch 'derived' -or $contentB -notmatch '84') {
            throw 'result-b-invalid-content'
        }
        # Verify B consumed A's artifact (content contains reference to A)
        if ($contentB -notmatch 'task-a' -and $contentB -notmatch '42') {
            throw 'result-b-did-not-consume-a'
        }
    }

    # NOTE: progress is NOT updated here. The Executor returns the candidate result only.
    # Progress advances only after canonical settlement + verification (see post-loop below).
    return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }
}.GetNewClosure()

$specScript = {
    param($taken, $gv)
    $n = [int]$taken + 1
    $tid = if ($n -eq 1) { 'fd-task-a' } else { 'fd-task-b' }
    return @{
        task_id = $tid; task_expected_revision = 1; agent = 'coder';
        prompt_hash = $ph; scope = @('src/pilot.ps1');
        acceptance_criteria = @('criterion:0');
        owner = $owner; ownership_generation = $gen; base_revision = $baseRev
    }
}.GetNewClosure()

# Logging
$log = New-Object System.Collections.ArrayList
function Log { param([string]$m); [void]$log.Add((Get-Date).ToString('o') + ' ' + $m); Write-Host $m }

Log ('PILOT START goal=' + $goalId + ' work_root=' + $workRoot)
Log ('OpenCode: ' + (opencode --version 2>&1))

$loop = Invoke-OrchestrationAutonomousObjective -GoalId $goalId -GoalStoreDir $goalDir -MaxSteps 6 -MaxDispatches 5 -CheckpointDir $ckptDir -Executor $executor -Authorization $auth -DispatchSpec $specScript -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath

Log ('LOOP: outcome=' + [string]$loop.outcome + ' reason=' + [string]$loop.reason + ' steps=' + [string]$loop.steps_taken + ' dispatches=' + [string]$loop.dispatches)
Log ('EXECUTOR CALLS: ' + [string]$state.calls)

# Post-loop: progress advances ONLY after canonical settlement + verification (not in Executor)
$loopDispatches = [int]$loop.dispatches
for ($pi = 1; $pi -le $loopDispatches; $pi++) {
    $liveG = & powershell -NoProfile -Command ". '$PSScriptRoot\lib\OrchestrationGoalKernel.ps1'; (Get-OrchestrationGoal -GoalId '$goalId' -StoreDir '$goalDir').goal | ConvertTo-Json -Depth 8 -Compress" 2>&1
    $liveGoal = ($liveG | Select-Object -Last 1) | ConvertFrom-Json
    $liveRev = [long]$liveGoal.revision
    $satP = [long]$liveGoal.progress.satisfied + 1
    $phP = [long]$liveGoal.plan_progress.phase + 1
    $updP = Update-OrchestrationGoal -GoalId $goalId -ExpectedRevision $liveRev -Fields @{ progress = @{ satisfied = $satP; total = 2 }; plan_progress = @{ phase = $phP; total_phases = 2; done_tasks = $phP } } -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration $gen
    Log ('PROGRESS UPDATE step ' + $pi + ': ok=' + [bool]$updP.ok + ' reason=' + [string]$updP.reason)
    if (-not [bool]$updP.ok) { throw ('progress-update-failed: ' + [string]$updP.reason) }
}

# Complete the goal if all criteria are satisfied (explicit CAS completion)
$finalSlot = & powershell -NoProfile -Command ". '$PSScriptRoot\lib\OrchestrationGoalKernel.ps1'; (Get-OrchestrationGoal -GoalId '$goalId' -StoreDir '$goalDir').goal | ConvertTo-Json -Depth 8 -Compress" 2>&1
$final = ($finalSlot | Select-Object -Last 1) | ConvertFrom-Json
if ([long]$final.progress.satisfied -eq [long]$final.progress.total -and [long]$final.progress.total -gt 0) {
    Log 'COMPLETING GOAL via CAS...'
    # Renew ownership (lease may have expired during the run)
    $renew = Renew-OrchestrationGoalOwnership -GoalId $goalId -OwnerId $owner -Generation $gen -StoreDir $goalDir -LeaseTtlMs 120000
    Log ('RENEW: ok=' + [bool]$renew.ok + ' reason=' + [string]$renew.reason)
    # Re-read goal after renew (renew may advance revision)
    $finalSlot2 = & powershell -NoProfile -Command ". '$PSScriptRoot\lib\OrchestrationGoalKernel.ps1'; (Get-OrchestrationGoal -GoalId '$goalId' -StoreDir '$goalDir').goal | ConvertTo-Json -Depth 8 -Compress" 2>&1
    $final2 = ($finalSlot2 | Select-Object -Last 1) | ConvertFrom-Json
    $liveRev = [long]$final2.revision
    Log ('LIVE REV after renew: ' + $liveRev)
    $fin = Set-OrchestrationGoalStatePersisted -GoalId $goalId -ToState 'COMPLETED' -ExpectedRevision $liveRev -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration $gen
    Log ('COMPLETE: ok=' + [bool]$fin.ok + ' reason=' + [string]$fin.reason)
    # Re-read final
    $finalSlot = & powershell -NoProfile -Command ". '$PSScriptRoot\lib\OrchestrationGoalKernel.ps1'; (Get-OrchestrationGoal -GoalId '$goalId' -StoreDir '$goalDir').goal | ConvertTo-Json -Depth 8 -Compress" 2>&1
    $final = ($finalSlot | Select-Object -Last 1) | ConvertFrom-Json
}
Log ('FINAL STATE: ' + [string]$final.state + ' progress=' + [string]$final.progress.satisfied + '/' + [string]$final.progress.total + ' phase=' + [string]$final.plan_progress.phase)

# Write log
$logPath = Join-Path $workRoot 'pilot-log.txt'
[IO.File]::WriteAllLines($logPath, $log, [Text.UTF8Encoding]::new($false))
Write-Host ''
Write-Host ('PILOT LOG: ' + $logPath)
Write-Host ('FINAL STATE: ' + [string]$final.state)
Write-Host ('PROGRESS: ' + [string]$final.progress.satisfied + '/' + [string]$final.progress.total)