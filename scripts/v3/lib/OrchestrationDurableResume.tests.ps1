<#!
.SYNOPSIS
    Etapa 5 INTEGRATED — interrupcao e retomada real apos CI/PR, sem duplicacao.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationDurableResume.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')

$script:passed = 0; $script:failed = 0
function Assert-DR { param([bool]$Condition,[string]$Name,[string]$Detail='')
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name); $script:passed++ }
    else { if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) } else { Write-Host ("[FAIL] {0} -- {1}" -f $Name,$Detail) }; $script:failed++ } }

$SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$REPO = 'acme/widgets'
$NOW = '2026-10-10T12:02:00Z'
$FUTURE = '2026-10-11T00:00:00Z'
$PolicyPath = Join-Path $PSScriptRoot '..\..\..\source\registry\delivery-policy.json'
$policy = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($PolicyPath)))

function New-TCheck { param([string]$Name,[string]$Status,$Conclusion,[string]$Sha)
    return [pscustomobject]@{ name = $Name; head_sha = $Sha; status = $Status; conclusion = $Conclusion } }
function New-TGreen { param([string]$Sha)
    $out = New-Object System.Collections.ArrayList
    foreach ($n in @($policy.required_checks)) { [void]$out.Add((New-TCheck ([string]$n) 'COMPLETED' 'success' $Sha)) }
    return @($out.ToArray()) }
function New-TSnap { param($Head,$Commit,[string]$State='OPEN',[string]$Merge='MERGEABLE',[string]$Review='APPROVED',$Checks=@(),[bool]$Complete=$true)
    return [pscustomobject]@{ repository = $script:REPO; pr_number = 42; head_sha = $Head; commit_sha = $Commit; observed_at = $script:NOW; pr_state = $State; mergeable = $Merge; review_decision = $Review; checks_complete = $Complete; checks = @($Checks) } }

$root = Join-Path ([IO.Path]::GetTempPath()) ('v3-dr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'; $tasksDir = Join-Path $root 'tasks'
    $waitsDir = Join-Path $root 'waits'; $flagsPath = Join-Path $root 'flags.json'
    foreach ($d in @($goalDir,$ckptDir,$tasksDir,$waitsDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

    # Goal inicia e conclui Task A (DONE canonico simplificado via transicoes)
    $g = New-OrchestrationGoal -GoalId 'dr-goal-1' -Objective 'retomar apos CI' -Criteria @('a','b') -TotalPhases 2 -StoreDir $goalDir
    Assert-DR ([bool]$g.ok) '[DR0] goal criado' ([string]$g.reason)
    $null = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE').goal -StoreDir $goalDir

    . (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')
    $ph = Get-NativeDispatchHash32 'dr-material'
    $slot0 = Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir
    $own0 = Acquire-OrchestrationGoalOwnership -GoalId 'dr-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$slot0.goal['revision']) -StoreDir $goalDir
    $gen0 = [long]$own0.ownership['generation']
    foreach ($tid in @('dr-task-a','dr-task-b')) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj '+$tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-dr' -ReadScopes @('src/dr.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $root
        Assert-DR ([bool]$c.ok) ('[DR0] task '+$tid) ([string]$c.error)
        $curRev = [long](Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir).goal['revision']
        $add = Add-OrchestrationGoalTaskPersisted -GoalId 'dr-goal-1' -TaskId $tid -ExpectedRevision $curRev -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen0
        Assert-DR ([bool]$add.ok) ('[DR0] attach '+$tid) ([string]$add.reason)
    }
    # Task A -> DONE via cadeia canonica minima (worker_result primeiro)
    $rev = [long](Get-OrchestrationTask -TaskId 'dr-task-a' -TasksDir $tasksDir).revision
    foreach ($st in @('PLANNING','IMPLEMENTING')) {
        $tr = Invoke-OrchestrationTaskTransition -TaskId 'dr-task-a' -ToState $st -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $root
        $rev = [long]$tr.revision
    }
    $wr = Set-OrchestrationTaskWorkerResult -TaskId 'dr-task-a' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision $rev -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $root
    $rev = [long]$wr.revision
    foreach ($st in @('VALIDATING','REVIEWING')) {
        $actor = if ($st -ceq 'VALIDATING') { 'coder' } else { 'tester' }
        $tr = Invoke-OrchestrationTaskTransition -TaskId 'dr-task-a' -ToState $st -Actor $actor -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $root
        $rev = [long]$tr.revision
    }
    $vr = Set-OrchestrationTaskVerification -TaskId 'dr-task-a' -VerifierEvidenceJson '{"ok":true,"task_id":"dr","status":"verified_pass","reason":"","scope":null,"profiles":[],"evidence":["criterion:0:verified"],"command_classes":["test"]}' -ExpectedRevision $rev -TasksDir $tasksDir -FlagsPath $flagsPath
    $rev = [long]$vr.revision
    $rw = Set-OrchestrationTaskReview -TaskId 'dr-task-a' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision $rev -TasksDir $tasksDir -FlagsPath $flagsPath
    $rev = [long]$rw.revision
    $gate = Test-OrchestrationTaskCompletion -TaskId 'dr-task-a' -TasksDir $tasksDir -RepoRoot $root -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
    Assert-DR ([bool]$gate.complete) '[DR1] Task A elegivel' (($gate.reasons -join ','))
    $dn = Complete-OrchestrationTask -TaskId 'dr-task-a' -Actor 'planner' -ExpectedRevision $rev -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $root
    Assert-DR ([bool]$dn.ok) '[DR1] Task A DONE' ([string]$dn.error)

    # Checkpoint apos Task A (estado persistido antes da interrupcao)
    $liveG = (Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $liveG
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $ckptDir
    Assert-DR ([bool]$sv.ok) '[DR2] checkpoint persistido' ([string]$sv.reason)
    $cid = [string]$sv.checkpoint_id

    # Registra espera de CI/PR (nova sessao lera este estado)
    . (Join-Path $PSScriptRoot 'OrchestrationGitHubResume.ps1')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $waitsDir -ObjectiveId 'dr-goal-1' -TaskId 'dr-task-b' -RunId 'run-dr' -Generation 1 -Repository $REPO -PrNumber 42 -Branch 'fix/dr' -ExpectedHeadSha $SHA_A -RequiredChecks @($policy.required_checks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $FUTURE -Owner 'planner-1'
    Assert-DR ([bool]$reg.ok) '[DR2] wait registrado' ([string]$reg.reason)
    $wait = $reg.wait

    $bindings = @(@{ run_id = 'run-dr'; root_session = 'ses_root'; worker_sessions = @('ses_b') })
    $obsRunning = @(@{ session_id = 'ses_b'; observed = 'running'; binding_session_id = 'ses_b'; last_seen = $NOW })

    # 1. CI verde => RESUME + avanca para Task B (A nao reexecutada)
    $snapGreen = New-TSnap $SHA_A $SHA_A 'OPEN' 'MERGEABLE' 'APPROVED' (New-TGreen $SHA_A) $true
    $r1 = Invoke-OrchestrationDurableResume -GoalId 'dr-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid -CheckpointDir $ckptDir -Bindings $bindings -Observations $obsRunning -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapGreen -Policy $policy -NowUtc $NOW -MandatoryTasks @('dr-task-a','dr-task-b') -TasksDir $tasksDir
    Assert-DR (([string]$r1.action -ceq 'advance') -and ([string]$r1.next_task -ceq 'dr-task-b')) '[DR3] CI verde retoma em B sem duplicar A' ([string]$r1.reason)

    # 2. CI vermelho recuperavel => TERMINAL diagnostic (sem auto-merge)
    $badChecks = @(New-TCheck ([string]$policy.required_checks[0]) 'COMPLETED' 'failure' $SHA_A)
    $snapRed = New-TSnap $SHA_A $SHA_A 'OPEN' 'MERGEABLE' 'APPROVED' $badChecks $true
    $r2 = Invoke-OrchestrationDurableResume -GoalId 'dr-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid -CheckpointDir $ckptDir -Bindings $bindings -Observations $obsRunning -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapRed -Policy $policy -NowUtc $NOW -MandatoryTasks @('dr-task-a','dr-task-b') -TasksDir $tasksDir
    Assert-DR (([string]$r2.action -ceq 'terminal')) '[DR4] CI vermelho => TERMINAL' ([string]$r2.reason)

    # 3. Resultado atrasado => KEEP_WAITING (wait, sem dispatch)
    $pendChecks = @(New-TCheck ([string]$policy.required_checks[0]) 'IN_PROGRESS' $null $SHA_A)
    $snapPend = New-TSnap $SHA_A $SHA_A 'OPEN' 'MERGEABLE' 'APPROVED' $pendChecks $false
    $r3 = Invoke-OrchestrationDurableResume -GoalId 'dr-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid -CheckpointDir $ckptDir -Bindings $bindings -Observations $obsRunning -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapPend -Policy $policy -NowUtc $NOW -MandatoryTasks @('dr-task-a','dr-task-b') -TasksDir $tasksDir
    Assert-DR (([string]$r3.action -ceq 'wait')) '[DR5] CI pendente => wait' ([string]$r3.reason)

    # 4. CAS stale => checkpoint nao resume (goal avancou em outra sessao)
    $livePre = (Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir).goal
    $ren = Renew-OrchestrationGoalOwnership -GoalId 'dr-goal-1' -OwnerId 'planner-1' -Generation $gen0 -StoreDir $goalDir -LeaseTtlMs 120000
    $gen1 = if ([bool]$ren.ok) { [long]$ren.ownership['generation'] } else { $gen0 }
    $upd = Update-OrchestrationGoal -GoalId 'dr-goal-1' -ExpectedRevision ([long]$livePre['revision']) -Fields @{ risks = @('r1') } -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen1
    $r4 = Invoke-OrchestrationDurableResume -GoalId 'dr-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid -CheckpointDir $ckptDir -Bindings $bindings -Observations $obsRunning -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapGreen -Policy $policy -NowUtc $NOW -MandatoryTasks @('dr-task-a','dr-task-b') -TasksDir $tasksDir
    Assert-DR ((-not [bool]$r4.resumable) -or ([string]$r4.action -ceq 'blocked')) '[DR6] CAS stale bloqueia resume' ([string]$r4.reason)

    # Novo checkpoint do estado vivo para DR8/DR9 (executor injetado)
    $liveG2 = (Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir).goal
    $ckpt2 = New-OrchestrationGoalCheckpoint -GoalRecord $liveG2
    $sv2 = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt2 -StoreDir $ckptDir
    Assert-DR ([bool]$sv2.ok) '[DR8] re-checkpoint apos CAS' ([string]$sv2.reason)
    $cid2 = [string]$sv2.checkpoint_id

    # DR8: executor injetado chamado 1x para B, nunca para A
    $script:drCalls = @()
    $execOk = { param($TaskId) $script:drCalls += [string]$TaskId; return [pscustomobject]@{ ok = $true; reason = 'dispatched-test'; task_id = [string]$TaskId } }
    $r8 = Invoke-OrchestrationDurableResume -GoalId 'dr-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid2 -CheckpointDir $ckptDir -Bindings $bindings -Observations $obsRunning -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapGreen -Policy $policy -NowUtc $NOW -MandatoryTasks @('dr-task-a','dr-task-b') -TasksDir $tasksDir -TaskExecutor $execOk
    $r8dis = $null; try { $r8dis = $r8.dispatch } catch { $r8dis = $null }
    $r8ok = (([string]$r8.action -ceq 'advance') -and ([string]$r8.next_task -ceq 'dr-task-b') -and ($null -ne $r8dis) -and ([string]$r8dis.task_id -ceq 'dr-task-b') -and ([bool]$r8dis.ok) -and (@($script:drCalls).Count -eq 1) -and ([string]$script:drCalls[0] -ceq 'dr-task-b'))
    Assert-DR $r8ok '[DR8] executor chamado 1x para B, nunca A' ('calls=' + (@($script:drCalls) -join ','))
    $aRevAfter8 = [long](Get-OrchestrationTask -TaskId 'dr-task-a' -TasksDir $tasksDir).revision
    Assert-DR (([string](Get-OrchestrationTask -TaskId 'dr-task-a' -TasksDir $tasksDir).state -ceq 'DONE')) '[DR8] A nao reexecutada' ''

    # DR9 negativo: executor falha => dispatch.ok=false mas action permanece advance, sem COMPLETE, sem duplicar A
    $execFail = { param($TaskId) return [pscustomobject]@{ ok = $false; reason = 'simulated-failure'; task_id = [string]$TaskId } }
    $aRevBefore9 = [long](Get-OrchestrationTask -TaskId 'dr-task-a' -TasksDir $tasksDir).revision
    $r9 = Invoke-OrchestrationDurableResume -GoalId 'dr-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid2 -CheckpointDir $ckptDir -Bindings $bindings -Observations $obsRunning -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapGreen -Policy $policy -NowUtc $NOW -MandatoryTasks @('dr-task-a','dr-task-b') -TasksDir $tasksDir -TaskExecutor $execFail
    $r9dis = $null; try { $r9dis = $r9.dispatch } catch { $r9dis = $null }
    $aRevAfter9 = [long](Get-OrchestrationTask -TaskId 'dr-task-a' -TasksDir $tasksDir).revision
    $r9ok = (([string]$r9.action -ceq 'advance') -and ([string]$r9.next_task -ceq 'dr-task-b') -and ($null -ne $r9dis) -and (-not [bool]$r9dis.ok) -and ($aRevAfter9 -eq $aRevBefore9) -and ([string](Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir).goal['state'] -cne 'COMPLETED'))
    Assert-DR $r9ok '[DR9] falha do executor nao completa nem duplica' ([string]$r9.reason)

    # DR10: lista mandatoria vazia nunca completa, mesmo com progresso total
    $curG10 = Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir
    $curRev10 = [long]$curG10.goal['revision']
    $upd10 = Update-OrchestrationGoal -GoalId 'dr-goal-1' -ExpectedRevision $curRev10 -Fields @{ progress = @{ satisfied = 2; total = 2; updated_at = $NOW } } -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen1
    Assert-DR ([bool]$upd10.ok) '[DR10] progresso total registrado' ([string]$upd10.reason)
    $liveG10 = (Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir).goal
    $ckpt10 = New-OrchestrationGoalCheckpoint -GoalRecord $liveG10
    $sv10 = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt10 -StoreDir $ckptDir
    Assert-DR ([bool]$sv10.ok) '[DR10] checkpoint apos progresso total' ([string]$sv10.reason)
    $cid10 = [string]$sv10.checkpoint_id
    $r10 = Invoke-OrchestrationDurableResume -GoalId 'dr-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid10 -CheckpointDir $ckptDir -Bindings $bindings -Observations $obsRunning -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapGreen -Policy $policy -NowUtc $NOW -MandatoryTasks @() -TasksDir $tasksDir
    Assert-DR (([string]$r10.action -ceq 'blocked') -and ([string]$r10.reason -ceq 'no-mandatory-tasks')) '[DR10] lista vazia nunca completa' ([string]$r10.reason)

    # 5. Goal so COMPLETED com criterios verificados (nunca por task done isolada)
    Assert-DR (([string](Get-OrchestrationTask -TaskId 'dr-task-a' -TasksDir $tasksDir).state -ceq 'DONE') -and ([string](Get-OrchestrationGoal -GoalId 'dr-goal-1' -StoreDir $goalDir).goal['state'] -cne 'COMPLETED')) '[DR7] task DONE nao completa goal' ''

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }; exit 0
} catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace)
    $script:failed++
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed); exit 1
} finally {
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
