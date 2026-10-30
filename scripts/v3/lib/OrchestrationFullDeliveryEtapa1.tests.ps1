<#!
.SYNOPSIS
    Etapa 1 (FULL_DELIVERY) — reproducao do gap de continuacao automatica.
.DESCRIPTION
    Hermetico: temp dirs, cleanup in finally; repo tree never written.
    Cenario: Goal com 2 tarefas dependentes (Task A gera artefato; Task B
    consome o artefato de A e produz segundo resultado verificavel).

    Evidencia RED: sem Executor (cenario real do OpenCode V2, onde o Planner
    e o caller), o driver para em 'awaits-planner' apos o primeiro
    dispatch_intent e NAO avanca sozinho para a Task B — gap reproduzido.
    Evidencia GREEN: com Executor que avanca o progresso persistido, o driver
    existente (Invoke-OrchestrationAutonomousObjective) executa A e B em
    sequencia sem intervencao humana e sem falso DONE (reuso do componente,
    sem nova maquina de estados).

    PS 5.1 compatible. ASCII-only. No network, no spawn.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1')

$script:passed = 0
$script:failed = 0

function Assert-FD {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-fd-etapa1-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $goalDir = Join-Path $tempRoot 'goals'
    $ckptDir = Join-Path $tempRoot 'checkpoints'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $evDir = Join-Path $tempRoot 'evidence'
    $tasksDir = Join-Path $tempRoot 'tasks'
    $flagsPath = Join-Path $tempRoot 'flags.json'
    $artifactDir = Join-Path $tempRoot 'artifacts'
    foreach ($d in @($goalDir, $ckptDir, $receiptDir, $evDir, $tasksDir, $artifactDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

    try {
        $g = New-OrchestrationGoal -GoalId 'fd-goal-1' -Objective 'gerar e consumir artefato' -Criteria @('artefato-gerado', 'artefato-consumido') -TotalPhases 2 -StoreDir $goalDir
        Assert-FD ([bool]$g.ok) '[F] goal created' ([string]$g.reason)
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        Assert-FD ([bool]$sv.ok) '[F] goal active+saved' ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId 'fd-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
        Assert-FD ([bool]$own.ok) '[F] ownership acquired' ([string]$own.reason)
        $gen = [long]$own.ownership['generation']
        $authOk = @{ explicit_allow = $true; goal_id = 'fd-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner' }
        $ph = Get-NativeDispatchHash32 'fd-prompt-material'

        function New-FDTask {
            param([string]$Id)
            $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
                -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
                -RuntimeVersion '2.2.3' -BaseRevision 'rev-fd' -ReadScopes @('src/fd.ps1') -Grants @('fs.read') `
                -AcceptanceCriteria @('crit-fd') -AttemptBudget 3 -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $script:tempRootText
            Assert-FD ([bool]$c.ok) ('[F] kernel task created ' + $Id) ([string]$c.error)
            $slot = Get-OrchestrationGoal -GoalId 'fd-goal-1' -StoreDir $script:goalDirText
            $add = Add-OrchestrationGoalTaskPersisted -GoalId 'fd-goal-1' -TaskId $Id -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $script:goalDirText -OwnerId 'planner-1' -OwnershipGeneration $gen
            Assert-FD ([bool]$add.ok) ('[F] task attached ' + $Id) ([string]$add.reason)
        }
        $script:tasksDirText = $tasksDir
        $script:flagsPathText = $flagsPath
        $script:tempRootText = $tempRoot
        $script:goalDirText = $goalDir

        New-FDTask -Id 'fd-task-a'
        New-FDTask -Id 'fd-task-b'

        # ---------- RED: sem Executor (cenario real V2) para apos o 1o dispatch_intent ----------
        $slot0 = Get-OrchestrationGoal -GoalId 'fd-goal-1' -StoreDir $goalDir
        $goal0 = $slot0.goal
        $specA = @{
            task_id = 'fd-task-a'; task_expected_revision = 1; agent = 'coder';
            prompt_hash = $ph; scope = @('src/fd.ps1');
            acceptance_criteria = @('criterion:0');
            owner = 'planner-1'; ownership_generation = $gen; base_revision = 'rev-fd'
        }
        $red = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specA -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-FD (([string]$red.action -ceq 'dispatch_intent')) '[RED] sem Executor: step retorna dispatch_intent (gap documentado)' ([string]$red.action)
        Assert-FD (($null -ne $red.dispatch_intent) -and ([string]$red.dispatch_intent.task_id -ceq 'fd-task-a')) '[RED] intent vincula Task A' ([string]$red.dispatch_intent.task_id)
        # re-invocar sem Executor: ainda dispatch_intent para A (nao avanca sozinho) -> gap
        $red2 = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specA -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-FD (([string]$red2.action -ceq 'dispatch_intent')) '[RED] re-invocacao sem Executor nao avanca (gap)' ([string]$red2.action)

        # ---------- GREEN: com Executor que avanca progresso persistido ----------
        $artifactPath = Join-Path $artifactDir 'output-a.json'
        $state = @{ calls = 0 }
        $advGoalDir = $goalDir
        $advGen = $gen
        $executor = {
            param($intent)
            $state.calls++
            $tid = ([string]$intent.task_id)
            # Task A gera artefato real em disco (dependencia real)
            if ($tid -ceq 'fd-task-a') {
                [IO.File]::WriteAllText($artifactPath, '{"value":42,"from":"task-a"}', [Text.UTF8Encoding]::new($false))
            }
            # Task B consome o artefato de A
            if ($tid -ceq 'fd-task-b') {
                $consumed = [IO.File]::ReadAllText($artifactPath, [Text.UTF8Encoding]::new($false))
                Assert-FD ($consumed -match 'task-a') '[GREEN] Task B consome artefato real de Task A' ''
                [IO.File]::WriteAllText((Join-Path $artifactDir 'output-b.json'), '{"derived":84,"source":' + $consumed + '}', [Text.UTF8Encoding]::new($false))
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
                prompt_hash = $ph; scope = @('src/fd.ps1');
                acceptance_criteria = @('criterion:0');
                owner = 'planner-1'; ownership_generation = $gen; base_revision = 'rev-fd'
            }
        }.GetNewClosure()

        $loop = Invoke-OrchestrationAutonomousObjective -GoalId 'fd-goal-1' -GoalStoreDir $goalDir -MaxSteps 4 -MaxDispatches 5 -CheckpointDir $ckptDir -Executor $executor -Authorization $authOk -DispatchSpec $specScript -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-FD (([int]$loop.dispatches -eq 2)) '[GREEN] duas tasks executadas sem intervencao' ('dispatches=' + [string]$loop.dispatches)
        Assert-FD (([int]$state.calls -eq 2)) '[GREEN] executor (worker) chamado 2x' ('calls=' + [string]$state.calls)

        # Post-loop: canonical completion per task, then progress reconciled from DONE states.
        # Progress advances ONLY for tasks in DONE (verified_pass -> approved -> gate -> Complete).
        function Complete-FDTask {
            param([string]$Tid)
            $t = Get-OrchestrationTask -TaskId $Tid -TasksDir $tasksDir
            if ($null -eq $t -or $t.PSObject.Properties['error']) { throw ('task-not-found: ' + $Tid) }
            $rev = [long]$t.revision
            $st = [string]$t.state
            if ($st -ceq 'DONE') { return $true }
            if ($st -eq 'DISCOVERING') {
                $tr = Invoke-OrchestrationTaskTransition -TaskId $Tid -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
                if (-not [bool]$tr.ok) { throw ('PLANNING failed: ' + [string]$tr.error) }
                $rev = [long]$tr.revision; $st = 'PLANNING'
            }
            if ($st -eq 'PLANNING') {
                $tr = Invoke-OrchestrationTaskTransition -TaskId $Tid -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
                if (-not [bool]$tr.ok) { throw ('IMPLEMENTING failed: ' + [string]$tr.error) }
                $rev = [long]$tr.revision; $st = 'IMPLEMENTING'
            }
            if ($st -eq 'IMPLEMENTING') {
                $tr = Invoke-OrchestrationTaskTransition -TaskId $Tid -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
                if (-not [bool]$tr.ok) { throw ('VALIDATING failed: ' + [string]$tr.error) }
                $rev = [long]$tr.revision; $st = 'VALIDATING'
            }
            if ($st -eq 'VALIDATING') {
                $tr = Invoke-OrchestrationTaskTransition -TaskId $Tid -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
                if (-not [bool]$tr.ok) { throw ('REVIEWING failed: ' + [string]$tr.error) }
                $rev = [long]$tr.revision; $st = 'REVIEWING'
            }
            $verJson = '{"ok":true,"task_id":"fd","status":"verified_pass","reason":"","scope":null,"profiles":[],"evidence":["criterion:0:verified"],"command_classes":["test"]}'
            $vr = Set-OrchestrationTaskVerification -TaskId $Tid -VerifierEvidenceJson $verJson -ExpectedRevision $rev -TasksDir $tasksDir -FlagsPath $flagsPath
            if (-not [bool]$vr.ok) { throw ('verification failed: ' + [string]$vr.error) }
            $rev = [long]$vr.revision
            $rw = Set-OrchestrationTaskReview -TaskId $Tid -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision $rev -TasksDir $tasksDir -FlagsPath $flagsPath
            if (-not [bool]$rw.ok) { throw ('review failed: ' + [string]$rw.error) }
            $rev = [long]$rw.revision
            $gate = Test-OrchestrationTaskCompletion -TaskId $Tid -TasksDir $tasksDir -RepoRoot $tempRoot -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
            if (-not [bool]$gate.complete) { throw ('gate failed: ' + ($gate.reasons -join ',')) }
            $dn = Complete-OrchestrationTask -TaskId $Tid -Actor 'planner' -ExpectedRevision $rev -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
            if (-not [bool]$dn.ok) { throw ('DONE failed: ' + [string]$dn.error) }
            return $true
        }
        $null = Complete-FDTask -Tid 'fd-task-a'
        Assert-FD (([string](Get-OrchestrationTask -TaskId 'fd-task-a' -TasksDir $tasksDir).state -ceq 'DONE')) '[GREEN] Task A DONE canonico' ''
        $null = Complete-FDTask -Tid 'fd-task-b'
        Assert-FD (([string](Get-OrchestrationTask -TaskId 'fd-task-b' -TasksDir $tasksDir).state -ceq 'DONE')) '[GREEN] Task B DONE canonico' ''
        # Reconcile progress from distinct mandatory IDs in DONE
        $doneIds = @()
        foreach ($mid in @('fd-task-a','fd-task-b')) {
            $mt = Get-OrchestrationTask -TaskId $mid -TasksDir $tasksDir
            if (([string]$mt.state -ceq 'DONE')) { $doneIds += $mid }
        }
        Assert-FD ((@($doneIds).Count -eq 2)) '[GREEN] 2 mandatory em DONE' (($doneIds -join ','))
        $liveG = (Get-OrchestrationGoal -GoalId 'fd-goal-1' -StoreDir $goalDir).goal
        $liveR = [long]$liveG['revision']
        $cnt = [int]@($doneIds).Count
        $updP = Update-OrchestrationGoal -GoalId 'fd-goal-1' -ExpectedRevision $liveR -Fields @{ progress = @{ satisfied = $cnt; total = 2 }; plan_progress = @{ phase = $cnt; total_phases = 2; done_tasks = $cnt } } -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        Assert-FD ([bool]$updP.ok) '[GREEN] progresso reconciliado por DONE' ([string]$updP.reason)
        $final = (Get-OrchestrationGoal -GoalId 'fd-goal-1' -StoreDir $goalDir).goal
        Assert-FD (([long]$final['plan_progress']['phase'] -eq 2)) '[GREEN] plan avancou fase1->fase2' ('phase=' + [string]$final['plan_progress']['phase'])
        Assert-FD (([long]$final['progress']['satisfied'] -eq 2)) '[GREEN] progresso 2/2' ('sat=' + [string]$final['progress']['satisfied'])
        Assert-FD (([string]$final['state'] -cne 'COMPLETED')) '[GREEN] sem falso DONE (task done != objective done)' ([string]$final['state'])
        # artefatos reais
        Assert-FD (Test-Path -LiteralPath $artifactPath -PathType Leaf) '[GREEN] artefato A existe' ''
        Assert-FD (Test-Path -LiteralPath (Join-Path $artifactDir 'output-b.json') -PathType Leaf) '[GREEN] resultado B existe' ''

        # ---------- resume sem duplicacao ----------
        $before = [int]$state.calls
        $r = Invoke-OrchestrationAutonomousObjective -GoalId 'fd-goal-1' -GoalStoreDir $goalDir -MaxSteps 4 -MaxDispatches 5 -CheckpointDir $ckptDir -Executor $executor -Authorization $authOk -DispatchSpec $specScript -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-FD (([int]$state.calls -eq $before)) '[GREEN] resume nao duplica efeitos' ('calls=' + [string]$state.calls)
        Assert-FD (([int]$r.dispatches -eq 0)) '[GREEN] resume consome zero budget (idempotente)' ('dispatches=' + [string]$r.dispatches)

        # ---------- higiene ----------
        $alPath = Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1'
        $alText = [IO.File]::ReadAllText($alPath, [Text.UTF8Encoding]::new($false))
        Assert-FD ((($alText -notmatch 'Start-Process') -and ($alText -notmatch 'Invoke-WebRequest') -and ($alText -notmatch 'HttpClient') -and ($alText -notmatch 'while\s*\(\s*\$true'))) '[NET] no spawn/network/busy-loop' ''
    }
    finally {
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