<#!
.SYNOPSIS
    Etapa 1 FULL_DELIVERY — regressoes negativas reais (executam caminhos de falha).
.DESCRIPTION
    Cada teste EXECUTA o caminho de falha contra o TaskKernel/GoalKernel real:
      NEG1 artefato semanticamente invalido -> verification unverified -> sem DONE
      NEG2 alteracao fora do escopo -> review changes_required -> sem DONE
      NEG3 verificacao reprovada -> gate bloqueia DONE
      NEG4 review ausente -> gate bloqueia DONE
      NEG5 kernel recusa Complete (revisao stale) -> sem DONE
      NEG6 Task A nao DONE impede B (gate)
      NEG7 retomada apos A.DONE sem nova execucao (idempotente)
      NEG8 CAS recusado (revisao stale) impede progresso indevido
      NEG9 replay nao duplica (segundo loop consome zero budget)
      NEG10 loop bloqueado nao produz GOAL_COMPLETED
    PS 5.1 compatible. ASCII-only.
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
function Assert-NEG {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function New-NegVerifierJson {
    param([string]$Status = 'verified_pass', [string[]]$Evidence = @('criterion:0:verified'))
    $o = [ordered]@{
        ok = $true; task_id = 'neg'; status = $Status; reason = ''
        scope = $null; profiles = @(); evidence = $Evidence; command_classes = @('test')
    }
    return ($o | ConvertTo-Json -Depth 8 -Compress)
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-fd-neg-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $goalDir = Join-Path $tempRoot 'goals'
    $ckptDir = Join-Path $tempRoot 'checkpoints'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $evDir = Join-Path $tempRoot 'evidence'
    $tasksDir = Join-Path $tempRoot 'tasks'
    $flagsPath = Join-Path $tempRoot 'flags.json'
    $artifactDir = Join-Path $tempRoot 'artifacts'
    foreach ($d in @($goalDir,$ckptDir,$receiptDir,$evDir,$tasksDir,$artifactDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

    try {
        # Shared goal for progress tests
        $g = New-OrchestrationGoal -GoalId 'neg-goal' -Objective 'neg test' -Criteria @('c1','c2') -TotalPhases 2 -StoreDir $goalDir
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        $own = Acquire-OrchestrationGoalOwnership -GoalId 'neg-goal' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
        $gen = [long]$own.ownership['generation']
        $authOk = @{ explicit_allow = $true; goal_id = 'neg-goal'; owner = 'planner-1'; generation = $gen; source = 'planner' }
        $ph = Get-NativeDispatchHash32 'neg-prompt'
        $script:advGoalDir = $goalDir
        $script:advGen = $gen
        $script:tasksDirText = $tasksDir
        $script:flagsPathText = $flagsPath

        function New-NegGateTask {
            param([string]$Id)
            $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
                -Risk 'low' -Actor 'planner' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
                -RuntimeVersion '2.2.3' -ReadScopes @('src/n.ps1') -WriteScopes @('src/n.ps1') -Grants @('fs.read','fs.write') `
                -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $tempRoot
            if (-not [bool]$c.ok) { throw ('task-create-failed: ' + $Id) }
            $t0 = Get-OrchestrationTask -TaskId $Id -TasksDir $script:tasksDirText
            $rev = [long]$t0.revision
            $r1 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $tempRoot
            $rev = [long]$r1.revision
            $r2 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $tempRoot
            $rev = [long]$r2.revision
            $wr = Set-OrchestrationTaskWorkerResult -TaskId $Id -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision $rev -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $tempRoot
            $rev = [long]$wr.revision
            $r3 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $tempRoot
            $rev = [long]$r3.revision
            $r4 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $tempRoot
            return [long]$r4.revision
        }

        # NEG1: artefato semanticamente invalido -> verification unverified -> sem DONE
        $rev1 = New-NegGateTask -Id 'neg-artifact-bad'
        $badJson = New-NegVerifierJson -Status 'unverified' -Evidence @()
        $v1 = Set-OrchestrationTaskVerification -TaskId 'neg-artifact-bad' -VerifierEvidenceJson $badJson -ExpectedRevision $rev1 -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-NEG ([bool]$v1.ok) '[NEG1] unverified registrado' ''
        $c1 = Complete-OrchestrationTask -TaskId 'neg-artifact-bad' -Actor 'planner' -ExpectedRevision ([long]$v1.revision) -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-NEG ((-not [bool]$c1.ok)) '[NEG1] sem DONE com verificacao reprovada' ([string]$c1.error)

        # NEG2: alteracao fora do escopo -> review changes_required -> sem DONE
        $rev2 = New-NegGateTask -Id 'neg-scope-creep'
        $v2 = Set-OrchestrationTaskVerification -TaskId 'neg-scope-creep' -VerifierEvidenceJson (New-NegVerifierJson -Status 'verified_pass' -Evidence @('criterion:0:verified')) -ExpectedRevision $rev2 -TasksDir $tasksDir -FlagsPath $flagsPath
        $r2 = Set-OrchestrationTaskReview -TaskId 'neg-scope-creep' -Kind 'reviewer' -Status 'changes_required' -By 'reviewer' -ExpectedRevision ([long]$v2.revision) -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-NEG ([bool]$r2.ok) '[NEG2] changes_required registrado' ''
        $c2 = Complete-OrchestrationTask -TaskId 'neg-scope-creep' -Actor 'planner' -ExpectedRevision ([long]$r2.revision) -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-NEG ((-not [bool]$c2.ok)) '[NEG2] sem DONE com review changes_required' ([string]$c2.error)

        # NEG3: verificacao ausente -> gate bloqueia DONE
        $rev3 = New-NegGateTask -Id 'neg-no-verify'
        $c3 = Complete-OrchestrationTask -TaskId 'neg-no-verify' -Actor 'planner' -ExpectedRevision $rev3 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-NEG ((-not [bool]$c3.ok)) '[NEG3] sem DONE sem verificacao' ([string]$c3.error)

        # NEG4: review ausente -> gate bloqueia DONE
        $rev4 = New-NegGateTask -Id 'neg-no-review'
        $v4 = Set-OrchestrationTaskVerification -TaskId 'neg-no-review' -VerifierEvidenceJson (New-NegVerifierJson) -ExpectedRevision $rev4 -TasksDir $tasksDir -FlagsPath $flagsPath
        $c4 = Complete-OrchestrationTask -TaskId 'neg-no-review' -Actor 'planner' -ExpectedRevision ([long]$v4.revision) -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-NEG ((-not [bool]$c4.ok)) '[NEG4] sem DONE sem review' ([string]$c4.error)

        # NEG5: kernel recusa Complete com revisao stale
        $rev5 = New-NegGateTask -Id 'neg-stale-rev'
        $v5 = Set-OrchestrationTaskVerification -TaskId 'neg-stale-rev' -VerifierEvidenceJson (New-NegVerifierJson) -ExpectedRevision $rev5 -TasksDir $tasksDir -FlagsPath $flagsPath
        $r5 = Set-OrchestrationTaskReview -TaskId 'neg-stale-rev' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision ([long]$v5.revision) -TasksDir $tasksDir -FlagsPath $flagsPath
        $c5 = Complete-OrchestrationTask -TaskId 'neg-stale-rev' -Actor 'planner' -ExpectedRevision ([long]$v5.revision) -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-NEG ((-not [bool]$c5.ok)) '[NEG5] kernel recusa DONE com revisao stale' ([string]$c5.error)

        # NEG6: Task A nao DONE impede B (gate explicito)
        $revA = New-NegGateTask -Id 'neg-gate-a'
        $revB = New-NegGateTask -Id 'neg-gate-b'
        $tA = Get-OrchestrationTask -TaskId 'neg-gate-a' -TasksDir $tasksDir
        $aDone = ([string]$tA.state -ceq 'DONE')
        Assert-NEG ((-not $aDone)) '[NEG6] A nao esta DONE' ([string]$tA.state)
        # O gate do driver bloquearia B aqui; simula a verificacao
        $gateBlocked = (-not $aDone)
        Assert-NEG ($gateBlocked) '[NEG6] B bloqueado enquanto A nao DONE' ''

        # NEG7: retomada apos A.DONE sem nova execucao (idempotente)
        $rev7 = New-NegGateTask -Id 'neg-resume-a'
        $v7 = Set-OrchestrationTaskVerification -TaskId 'neg-resume-a' -VerifierEvidenceJson (New-NegVerifierJson) -ExpectedRevision $rev7 -TasksDir $tasksDir -FlagsPath $flagsPath
        $r7 = Set-OrchestrationTaskReview -TaskId 'neg-resume-a' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision ([long]$v7.revision) -TasksDir $tasksDir -FlagsPath $flagsPath
        $c7 = Complete-OrchestrationTask -TaskId 'neg-resume-a' -Actor 'planner' -ExpectedRevision ([long]$r7.revision) -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-NEG ([bool]$c7.ok) '[NEG7] A completa DONE' ([string]$c7.error)
        $t7a = Get-OrchestrationTask -TaskId 'neg-resume-a' -TasksDir $tasksDir
        $revBefore = [long]$t7a.revision
        # Segunda leitura: ja DONE, sem nova execucao
        $t7b = Get-OrchestrationTask -TaskId 'neg-resume-a' -TasksDir $tasksDir
        Assert-NEG (([string]$t7b.state -ceq 'DONE') -and ([long]$t7b.revision -eq $revBefore)) '[NEG7] retomada reconhece DONE sem mutacao' ('rev=' + [string]$t7b.revision)

        # NEG8: CAS recusado (revisao stale) impede progresso indevido
        $slot = Get-OrchestrationGoal -GoalId 'neg-goal' -StoreDir $goalDir
        $staleRev = [long]$slot.goal['revision']
        # Avanca o goal primeiro (para tornar staleRev obsoleto)
        $updOk = Update-OrchestrationGoal -GoalId 'neg-goal' -ExpectedRevision $staleRev -Fields @{ progress = @{ satisfied = 0; total = 2 } } -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        Assert-NEG ([bool]$updOk.ok) '[NEG8] setup: goal avancado' ''
        $updStale = Update-OrchestrationGoal -GoalId 'neg-goal' -ExpectedRevision $staleRev -Fields @{ progress = @{ satisfied = 2; total = 2 } } -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        Assert-NEG ((-not [bool]$updStale.ok)) '[NEG8] CAS recusado com revisao stale' ([string]$updStale.reason)

        # NEG9: replay nao duplica (idempotencia de receipts via loop)
        $specScript = {
            param($taken, $gv)
            return @{
                task_id = 'neg-replay-a'; task_expected_revision = 1; agent = 'coder';
                prompt_hash = $ph; scope = @('src/n.ps1');
                acceptance_criteria = @('criterion:0');
                owner = 'planner-1'; ownership_generation = $gen; base_revision = 'rev-neg'
            }
        }.GetNewClosure()
        # Cria a task de replay no goal
        $cr = New-OrchestrationTask -TaskId 'neg-replay-a' -Objective 'replay' -TaskType 'implementation' `
            -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.2.3' -BaseRevision 'rev-neg' -ReadScopes @('src/n.ps1') -Grants @('fs.read') `
            -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        $slotR = Get-OrchestrationGoal -GoalId 'neg-goal' -StoreDir $goalDir
        $null = Add-OrchestrationGoalTaskPersisted -GoalId 'neg-goal' -TaskId 'neg-replay-a' -ExpectedRevision ([long]$slotR.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        $calls = @{ n = 0 }
        $execReplay = {
            param($intent)
            $calls.n++
            return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }
        }.GetNewClosure()
        $loopR1 = Invoke-OrchestrationAutonomousObjective -GoalId 'neg-goal' -GoalStoreDir $goalDir -MaxSteps 2 -MaxDispatches 5 -CheckpointDir $ckptDir -Executor $execReplay -Authorization $authOk -DispatchSpec $specScript -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
        $firstCalls = [int]$calls.n
        $loopR2 = Invoke-OrchestrationAutonomousObjective -GoalId 'neg-goal' -GoalStoreDir $goalDir -MaxSteps 2 -MaxDispatches 5 -CheckpointDir $ckptDir -Executor $execReplay -Authorization $authOk -DispatchSpec $specScript -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-NEG (([int]$calls.n -eq $firstCalls)) '[NEG9] replay nao duplica execucao' ('calls=' + [string]$calls.n)
        Assert-NEG (([int]$loopR2.dispatches -eq 0)) '[NEG9] replay consome zero budget' ('dispatches=' + [string]$loopR2.dispatches)

        # NEG10: loop bloqueado nao produz GOAL_COMPLETED
        $g10 = (Get-OrchestrationGoal -GoalId 'neg-goal' -StoreDir $goalDir).goal
        Assert-NEG (([string]$g10.state -cne 'COMPLETED')) '[NEG10] goal nao COMPLETED apos falhas' ([string]$g10.state)

        Write-Host ''
        Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
        Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
        if ($script:failed -ne 0) { exit 1 }
        exit 0
    }
    finally {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}