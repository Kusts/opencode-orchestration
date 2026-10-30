<#!
.SYNOPSIS
    Etapa 1 FULL_DELIVERY - driver do piloto (runtime real).
.DESCRIPTION
    Executa a jornada completa Task A -> Task B no OpenCode V2 real, sem
    intervencao humana entre as tarefas, reusando o driver existente
    (Invoke-OrchestrationObjectiveStep) com um Executor real que chama
    `opencode run` para executar o subagent.

    Cadeia canonica por Task (ordem obrigatoria):
      1. Executar Task (dispatch via Executor)
      2. Confirmar settlement canonico (NativeDispatch: evidence + kernel write + receipt settled)
      3. Verificacao independente dos artefatos (conteudo, valores, derivacao)
      4. Review baseado em evidencias (scope check)
      5. Completar Task pelo Task Kernel (Complete-OrchestrationTask -> DONE)
      6. Reconciliar e persistir progresso por CAS
      7. Somente entao liberar a proxima Task

    O progresso avanca SOMENTE por Tasks em estado DONE (verificacao canonica),
    nao por contadores locais, dispatches ou candidate_pass.

    PS 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$SetupJson = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationNativeDispatch.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationTaskKernel.ps1')
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
$owner = [string]$ctx.owner
$gen = [long]$ctx.generation
$ph = Get-NativeDispatchHash32 'fd-pilot-prompt-material'
$baseRev = 'rev-pilot'

# Logging
$log = New-Object System.Collections.ArrayList
function Log { param([string]$m); [void]$log.Add((Get-Date).ToString('o') + ' ' + $m); Write-Host $m }

Log ('PILOT START goal=' + $goalId + ' work_root=' + $workRoot)
Log ('OpenCode: ' + (opencode --version 2>&1))

# Helper: canonical completion chain for one task
function Complete-TaskCanonically {
    param([string]$TaskId, [string]$ArtifactPath, [string]$ArtifactContentPattern, [string]$ConsumedPattern)

    Log ('--- CANONICAL CHAIN: ' + $TaskId + ' ---')

    # Step 0: Resume check — if already DONE, recognize without repeating effects
    $task = Get-OrchestrationTask -TaskId $TaskId -TasksDir $tasksDir -RepoRoot $workRoot
    if ($null -eq $task -or $task.PSObject.Properties['error']) {
        throw ('task-not-found: ' + $TaskId)
    }
    $taskState = [string]$task.state
    if ($taskState -ceq 'DONE') {
        Log ('  ' + $TaskId + ': already DONE (resume, no effects repeated)')
        return $true
    }
    $taskRev = [long]$task.revision
    Log ('  state=' + $taskState + ' rev=' + $taskRev)

    # Step 2: Transition to VALIDATING (if needed)
    if ($taskState -in @('DISCOVERING','PLANNING','IMPLEMENTING')) {
        if ($taskState -ceq 'DISCOVERING') {
            $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $taskRev -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $workRoot
            if (-not [bool]$tr.ok) { throw ('PLANNING transition failed: ' + [string]$tr.error) }
            $taskRev = [long]$tr.revision; $taskState = 'PLANNING'
        }
        if ($taskState -ceq 'PLANNING') {
            $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision $taskRev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $workRoot
            if (-not [bool]$tr.ok) { throw ('IMPLEMENTING transition failed: ' + [string]$tr.error) }
            $taskRev = [long]$tr.revision; $taskState = 'IMPLEMENTING'
        }
        if ($taskState -ceq 'IMPLEMENTING') {
            $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $taskRev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $workRoot
            if (-not [bool]$tr.ok) { throw ('VALIDATING transition failed: ' + [string]$tr.error) }
            $taskRev = [long]$tr.revision; $taskState = 'VALIDATING'
        }
    }

    # Step 3: Transition to REVIEWING
    if ($taskState -ceq 'VALIDATING') {
        $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $taskRev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $workRoot
        if (-not [bool]$tr.ok) { throw ('REVIEWING transition failed: ' + [string]$tr.error) }
        $taskRev = [long]$tr.revision; $taskState = 'REVIEWING'
    }

    # Step 4: Independent verification (semantic JSON parsing + value check + scope)
    $verifyPassed = $false
    $verifyEvidence = @()
    $artifactContent = ''
    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        $verifyPassed = $false
    } else {
        $artifactContent = [IO.File]::ReadAllText($ArtifactPath, [Text.UTF8Encoding]::new($false))
        # Semantic JSON parsing (not regex)
        $parsed = $null
        try { $parsed = $artifactContent | ConvertFrom-Json } catch { $parsed = $null }
        if ($null -ne $parsed) {
            # Validate expected values based on task
            if ($TaskId -ceq 'fd-task-a') {
                $verifyPassed = ([int]$parsed.value -eq 42) -and ([string]$parsed.from -ceq 'task-a')
            } elseif ($TaskId -ceq 'fd-task-b') {
                $verifyPassed = ([int]$parsed.derived -eq 84)
                # Verify B consumed A's artifact (semantic, not regex)
                if ($verifyPassed -and $null -ne $parsed.source) {
                    $src = $parsed.source
                    if ($src -is [string]) {
                        try { $srcObj = $src | ConvertFrom-Json; $verifyPassed = ([int]$srcObj.value -eq 42) } catch { $verifyPassed = $false }
                    } elseif ($src -is [PSCustomObject]) {
                        $verifyPassed = ([int]$src.value -eq 42)
                    }
                }
            }
            if ($verifyPassed) { $verifyEvidence = @('criterion:0:verified') }
        } else {
            # Strict JSON required: non-JSON artifacts fail verification
            $verifyPassed = $false
            $verifyEvidence = @()
        }
    }

    # Construct verifier result from REAL verification (status reflects actual evaluation)
    $verifyStatus = if ($verifyPassed) { 'verified_pass' } else { 'unverified' }
    $verifyResult = @{ status = $verifyStatus; evidence = $verifyEvidence }
    $verJson = ConvertTo-Json -InputObject $verifyResult -Depth 3 -Compress
    $vr = Set-OrchestrationTaskVerification -TaskId $TaskId -VerifierEvidenceJson $verJson -ExpectedRevision $taskRev -TasksDir $tasksDir -FlagsPath $flagsPath
    if (-not [bool]$vr.ok) { throw ('verification failed: ' + [string]$vr.error) }
    $taskRev = [long]$vr.revision
    Log ('  ' + $TaskId + ': verification set (' + $verifyStatus + ') - content evaluated')

    if (-not $verifyPassed) {
        throw ('verification-not-passed: artifact content invalid for ' + $TaskId)
    }

    # Step 5: Review based on real evidence (scope check)
    # Scope check: artifact exists, content valid, no scope creep
    $reviewApproved = $false
    # Evaluate scope: artifact must exist and be within expected dir
    if (Test-Path -LiteralPath $ArtifactPath -PathType Leaf) {
        # Check no unexpected files in artifact dir (scope check)
        $artifactDirFiles = @(Get-ChildItem -LiteralPath $artifactDir -File -ErrorAction SilentlyContinue)
        $expectedArtifacts = if ($TaskId -ceq 'fd-task-a') { @('output-a.json') } else { @('output-a.json','output-b.json') }
        $unexpectedFiles = @($artifactDirFiles | Where-Object { $expectedArtifacts -notcontains $_.Name })
        if ($unexpectedFiles.Count -eq 0 -and $verifyPassed) {
            $reviewApproved = $true
        }
    }
    $reviewStatus = if ($reviewApproved) { 'approved' } else { 'changes_required' }
    $rv = Set-OrchestrationTaskReview -TaskId $TaskId -Kind 'reviewer' -Status $reviewStatus -By 'reviewer' -ExpectedRevision $taskRev -TasksDir $tasksDir -FlagsPath $flagsPath
    if (-not [bool]$rv.ok) { throw ('review failed: ' + [string]$rv.error) }
    $taskRev = [long]$rv.revision
    Log ('  ' + $TaskId + ': review set (' + $reviewStatus + ') - scope evaluated')

    if ($reviewStatus -cne 'approved') {
        throw ('review-not-approved: scope check failed for ' + $TaskId)
    }

    # Step 6: Check completion eligibility
    $comp = Test-OrchestrationTaskCompletion -TaskId $TaskId -TasksDir $tasksDir -RepoRoot $workRoot -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
    if (-not [bool]$comp.complete) {
        throw ('completion gate failed: ' + ($comp.reasons -join ', '))
    }

    # Step 7: Complete task (DONE)
    $done = Complete-OrchestrationTask -TaskId $TaskId -Actor 'planner' -ExpectedRevision $taskRev -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $workRoot
    if (-not [bool]$done.ok) { throw ('Complete-OrchestrationTask failed: ' + [string]$done.error) }
    Log ('  ' + $TaskId + ': DONE (canonical)')

    return $true
}

# Executor: calls opencode run + validates output
$executor = {
    param($intent)
    $tid = [string]$intent.task_id
    $artifactPathL = if ($tid -ceq 'fd-task-a') { $artifactPath } else { $resultBPath }
    $artifactDirL = $artifactDir

    $prompt = if ($tid -ceq 'fd-task-a') {
        "You are a coding agent. Create the file '$artifactPath' with exact strict-JSON content (double quotes required): {`"value`":42,`"from`":`"task-a`"}. Reply with ONLY this strict JSON and nothing else: {`"status`":`"candidate_pass`",`"claimed_evidence`":[`"criterion:0`"]}"
    } else {
        "You are a coding agent. Read '$artifactPath'. Create '$resultBPath' with strict-JSON content (double quotes required): {`"derived`":84,`"source`":<contents of output-a.json>}. Reply with ONLY this strict JSON and nothing else: {`"status`":`"candidate_pass`",`"claimed_evidence`":[`"criterion:0`"]}"
    }

    $raw = opencode run --format json $prompt 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw ('opencode-run-failed: exit=' + $exitCode) }

    $textOutput = ''
    $parsedEvents = 0
    foreach ($line in $raw) {
        try {
            $evt = $line | ConvertFrom-Json
            $parsedEvents++
            if ($evt.type -eq 'text') { $textOutput += [string]$evt.part.text }
        } catch { }
    }
    if ($parsedEvents -eq 0) { throw 'opencode-output-unparseable' }

    # Parse subagent result
    $subStatus = ''
    $subEvidence = @()
    $parsed = $false
    try {
        $m = [regex]::Match($textOutput, '\{[^{}]*\}')
        if ($m.Success) {
            $subResult = $m.Value | ConvertFrom-Json
            $subStatus = [string]$subResult.status
            $subEvidence = @($subResult.claimed_evidence)
            $parsed = $true
        }
    } catch { $parsed = $false }
    if (-not $parsed) {
        $m2 = [regex]::Match($textOutput, 'status\s*[:=]\s*["'']?(\w+)["'']?')
        if ($m2.Success) { $subStatus = $m2.Groups[1].Value; $parsed = $true }
        $m3 = [regex]::Match($textOutput, 'claimed_evidence\s*[:=]\s*\[([^\]]*)\]')
        if ($m3.Success) {
            $evStr = $m3.Groups[1].Value
            $subEvidence = @($evStr -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }
    if (-not $parsed) { throw 'subagent-result-not-parseable' }
    if ($subStatus -cne 'candidate_pass') { throw ('subagent-status-invalid: ' + $subStatus) }
    if ($subEvidence.Count -lt 1) { throw 'subagent-evidence-missing' }

    # Verify artifact exists and has valid content (semantic JSON parsing, strict first)
    if ($tid -ceq 'fd-task-a') {
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw 'artifact-a-not-created' }
        $contentA = [IO.File]::ReadAllText($artifactPath, [Text.UTF8Encoding]::new($false))
        $parsedA = $null
        try { $parsedA = $contentA | ConvertFrom-Json } catch { $parsedA = $null }
        if ($null -eq $parsedA) { throw 'artifact-a-not-json' }
        if (([int]$parsedA.value -ne 42) -or ([string]$parsedA.from -cne 'task-a')) { throw 'artifact-a-invalid-content' }
    }
    if ($tid -ceq 'fd-task-b') {
        if (-not (Test-Path -LiteralPath $resultBPath -PathType Leaf)) { throw 'result-b-not-created' }
        $contentB = [IO.File]::ReadAllText($resultBPath, [Text.UTF8Encoding]::new($false))
        $parsedB = $null
        try { $parsedB = $contentB | ConvertFrom-Json } catch { $parsedB = $null }
        if ($null -eq $parsedB) { throw 'result-b-not-json' }
        if ([int]$parsedB.derived -ne 84) { throw 'result-b-invalid-content' }
        $srcB = $parsedB.source
        $consumedOk = $false
        if ($srcB -is [string]) {
            $srcObj = $null
            try { $srcObj = $srcB | ConvertFrom-Json } catch { $srcObj = $null }
            if ($null -eq $srcObj) { throw 'result-b-source-not-json' }
            $consumedOk = (([int]$srcObj.value -eq 42) -and ([string]$srcObj.from -ceq 'task-a'))
        } elseif ($null -ne $srcB) {
            try { $consumedOk = (([int]$srcB.value -eq 42) -and ([string]$srcB.from -ceq 'task-a')) } catch { $consumedOk = $false }
        }
        if (-not $consumedOk) { throw 'result-b-did-not-consume-a' }
    }

    Log ('  EXECUTOR: ' + $tid + ' completed, artifact verified')
    # Return the VALIDATED result (not a reconstructed constant)
    return @{ status = $subStatus; claimed_evidence = @($subEvidence) }
}.GetNewClosure()

# Spec for Task A
$specA = @{
    task_id = 'fd-task-a'; task_expected_revision = 1; agent = 'coder';
    prompt_hash = $ph; scope = @('src/pilot.ps1');
    acceptance_criteria = @('criterion:0');
    owner = $owner; ownership_generation = $gen; base_revision = $baseRev
}

# Spec for Task B
$specB = @{
    task_id = 'fd-task-b'; task_expected_revision = 1; agent = 'coder';
    prompt_hash = $ph; scope = @('src/pilot.ps1');
    acceptance_criteria = @('criterion:0');
    owner = $owner; ownership_generation = $gen; base_revision = $baseRev
}

# Goal COMPLETED idempotence: recognize without new dispatch
$goalNow = (Get-OrchestrationGoal -GoalId $goalId -StoreDir $goalDir).goal
if ([string]$goalNow.state -ceq 'COMPLETED') {
    Log '  Goal already COMPLETED (resume, no effects repeated)'
} else {

# Helper: count distinct mandatory tasks in DONE (canonical states only)
function Get-DoneCount {
    param([string[]]$Mandatory = @())
    $n = 0
    $doneIds = @()
    foreach ($mid in $Mandatory) {
        $mt = Get-OrchestrationTask -TaskId $mid -TasksDir $tasksDir -RepoRoot $workRoot
        if (($null -ne $mt) -and (-not $mt.PSObject.Properties['error']) -and ([string]$mt.state -ceq 'DONE')) {
            $n++
            $doneIds += $mid
        }
    }
    return @{ count = $n; ids = $doneIds }
}

function Sync-GoalProgress {
    param([string[]]$Mandatory = @(), [int]$Total = 2)
    $dc = Get-DoneCount -Mandatory $Mandatory
    $cnt = [int]$dc.count
    $liveG = (Get-OrchestrationGoal -GoalId $goalId -StoreDir $goalDir).goal
    $curSat = [long]$liveG.progress.satisfied
    $curPhase = [long]$liveG.plan_progress.phase
    if (($curSat -eq $cnt) -and ($curPhase -eq $cnt)) {
        Log ('  Progress already reconciled: ' + $cnt + '/' + $Total + ' (' + ($dc.ids -join ', ') + ')')
        return $cnt
    }
    $liveRev = [long]$liveG.revision
    $upd = Update-OrchestrationGoal -GoalId $goalId -ExpectedRevision $liveRev -Fields @{ progress = @{ satisfied = $cnt; total = $Total }; plan_progress = @{ phase = $cnt; total_phases = $Total; done_tasks = $cnt } } -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration $gen
    Log ('  Progress reconciled to ' + $cnt + '/' + $Total + ' (' + ($dc.ids -join ', ') + '): ok=' + [bool]$upd.ok + ' reason=' + [string]$upd.reason)
    if (-not [bool]$upd.ok) { throw ('progress-sync-failed: ' + [string]$upd.reason) }
    return $cnt
}

$mandatory = @('fd-task-a','fd-task-b')

# --- Task A: full canonical chain ---
Log '=== TASK A ==='
# Resume check: if Task A is already DONE, skip dispatch (BEFORE any new dispatch)
$taskA = Get-OrchestrationTask -TaskId 'fd-task-a' -TasksDir $tasksDir -RepoRoot $workRoot
$taskADone = ($null -ne $taskA -and -not $taskA.PSObject.Properties['error'] -and [string]$taskA.state -ceq 'DONE')
if ($taskADone) {
    Log '  Task A already DONE (resume, skipping dispatch)'
} else {
    $stepA = Invoke-OrchestrationObjectiveStep -Goal (Get-OrchestrationGoal -GoalId $goalId -StoreDir $goalDir).goal -CheckpointDir $ckptDir -Executor $executor -Authorization $auth -DispatchSpec $specA -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Log ('  Step A: action=' + [string]$stepA.action + ' reason=' + [string]$stepA.reason)
    if ([string]$stepA.action -ne 'dispatched' -or -not [bool]$stepA.dispatch.ok) {
        throw ('Task A dispatch failed: ' + [string]$stepA.reason)
    }
}
# Canonical completion for Task A (handles resume internally)
$null = Complete-TaskCanonically -TaskId 'fd-task-a' -ArtifactPath $artifactPath -ArtifactContentPattern 'value.*42.*task-a' -ConsumedPattern ''

# Progress reconciled from canonical DONE states (distinct mandatory IDs)
$null = Sync-GoalProgress -Mandatory $mandatory -Total 2

# Gate: B only starts after A is DONE (canonical)
$taskACheck = Get-OrchestrationTask -TaskId 'fd-task-a' -TasksDir $tasksDir -RepoRoot $workRoot
if ([string]$taskACheck.state -cne 'DONE') {
    throw 'gate-blocked: Task A is not DONE, Task B cannot start'
}

# --- Task B: full canonical chain (only after A is DONE) ---
Log '=== TASK B ==='
# Resume check: if Task B is already DONE, skip dispatch
$taskB = Get-OrchestrationTask -TaskId 'fd-task-b' -TasksDir $tasksDir -RepoRoot $workRoot
$taskBDone = ($null -ne $taskB -and -not $taskB.PSObject.Properties['error'] -and [string]$taskB.state -ceq 'DONE')
if ($taskBDone) {
    Log '  Task B already DONE (resume, skipping dispatch)'
} else {
    $stepB = Invoke-OrchestrationObjectiveStep -Goal (Get-OrchestrationGoal -GoalId $goalId -StoreDir $goalDir).goal -CheckpointDir $ckptDir -Executor $executor -Authorization $auth -DispatchSpec $specB -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Log ('  Step B: action=' + [string]$stepB.action + ' reason=' + [string]$stepB.reason)
    if ([string]$stepB.action -ne 'dispatched' -or -not [bool]$stepB.dispatch.ok) {
        throw ('Task B dispatch failed: ' + [string]$stepB.reason)
    }
}

# Canonical completion for Task B
$null = Complete-TaskCanonically -TaskId 'fd-task-b' -ArtifactPath $resultBPath -ArtifactContentPattern 'derived.*84' -ConsumedPattern 'task-a|42'

# Progress reconciled from canonical DONE states (distinct mandatory IDs)
$null = Sync-GoalProgress -Mandatory $mandatory -Total 2

# Complete goal via CAS only when all mandatory tasks are DONE and progress reconciled
$dcFinal = Get-DoneCount -Mandatory $mandatory
if ((@($dcFinal.ids).Count -eq 2) -and ($dcFinal.ids -contains 'fd-task-a') -and ($dcFinal.ids -contains 'fd-task-b')) {
    Log 'COMPLETING GOAL via CAS...'
    $renew = Renew-OrchestrationGoalOwnership -GoalId $goalId -OwnerId $owner -Generation $gen -StoreDir $goalDir -LeaseTtlMs 120000
    $finalSlot2 = & powershell -NoProfile -Command ". '$PSScriptRoot\lib\OrchestrationGoalKernel.ps1'; (Get-OrchestrationGoal -GoalId '$goalId' -StoreDir '$goalDir').goal | ConvertTo-Json -Depth 8 -Compress" 2>&1
    $final2 = ($finalSlot2 | Select-Object -Last 1) | ConvertFrom-Json
    $liveRev = [long]$final2.revision
    $fin = Set-OrchestrationGoalStatePersisted -GoalId $goalId -ToState 'COMPLETED' -ExpectedRevision $liveRev -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration $gen
    Log ('COMPLETE: ok=' + [bool]$fin.ok + ' reason=' + [string]$fin.reason)
} else {
    Log ('  Goal NOT completed: DONE tasks = ' + ($dcFinal.ids -join ', '))
}

} # end Goal COMPLETED idempotence else

# Final state
$finalSlot = & powershell -NoProfile -Command ". '$PSScriptRoot\lib\OrchestrationGoalKernel.ps1'; (Get-OrchestrationGoal -GoalId '$goalId' -StoreDir '$goalDir').goal | ConvertTo-Json -Depth 8 -Compress" 2>&1
$final = ($finalSlot | Select-Object -Last 1) | ConvertFrom-Json
Log ('FINAL STATE: ' + [string]$final.state + ' progress=' + [string]$final.progress.satisfied + '/' + [string]$final.progress.total + ' phase=' + [string]$final.plan_progress.phase)

# Write log
$logPath = Join-Path $workRoot 'pilot-log.txt'
[IO.File]::WriteAllLines($logPath, $log, [Text.UTF8Encoding]::new($false))
Write-Host ''
Write-Host ('PILOT LOG: ' + $logPath)
Write-Host ('FINAL STATE: ' + [string]$final.state)
Write-Host ('PROGRESS: ' + [string]$final.progress.satisfied + '/' + [string]$final.progress.total)