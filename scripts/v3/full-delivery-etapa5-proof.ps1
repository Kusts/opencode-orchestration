<#!
.SYNOPSIS
    Etapa 5 REAL - prova com 2 processos reais, sem LLM/rede/GH real.
.DESCRIPTION
    Processo 1 (script filho via powershell -File): cria Goal+Tasks A/B em
    dirs temp compartilhados, completa Task A via cadeia canonica
    (transitions + worker_result + verification + review + completion),
    persiste checkpoint + wait simulando CI verde, ESCREVE marcador e ENCERRA.
    Processo 2 (este processo, apos detectar marcador): nova leitura do MESMO
    Goal do disco, chama Invoke-OrchestrationDurableResume SEM executor (le
    estado persistido), obtem next_task=B, reconcilia CI verde, despacha B via
    TaskExecutor real (completa B canonicamente em chamada separada que rele
    tudo do disco, sem estado em memoria do processo 1), verifica A nao
    reexecutada, completa Goal via CAS somente apos B DONE + criterios, e
    imprime PROOF_ETAPA5=REAL. Snapshots simulados, sem gh real.
    PS 5.1, ASCII-only. Sem nova maquina de estados, sem merge/deploy.
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = ''
)
$ErrorActionPreference = 'Stop'

function Write-E5Evidence {
    param($Dir, $Record)
    try {
        if ([string]::IsNullOrWhiteSpace([string]$Dir)) { return }
        try {
            if (-not (Test-Path -LiteralPath ([string]$Dir) -PathType Container)) {
                [void][System.IO.Directory]::CreateDirectory([string]$Dir)
            }
        } catch { return }
        $line = ($Record | ConvertTo-Json -Compress -Depth 8)
        [IO.File]::AppendAllText((Join-Path ([string]$Dir) 'etapa5-proof.jsonl'), ($line + [System.Environment]::NewLine), [System.Text.Encoding]::UTF8)
    } catch { }
}

function Fail-E5 {
    param([string]$Message, $Dir)
    Write-Host ('PROOF_ETAPA5=FAIL:' + [string]$Message)
    Write-E5Evidence -Dir $Dir -Record ([ordered]@{ timestamp = ([DateTime]::UtcNow.ToString('o')); status = 'FAIL'; reason = [string]$Message })
    exit 1
}

try {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $libDir = Join-Path $PSScriptRoot 'lib'
    $policyPath = Join-Path $repoRoot 'source\registry\delivery-policy.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) { Fail-E5 'policy-missing' $EvidenceDir }
    $policy = ConvertFrom-Json ([IO.File]::ReadAllText($policyPath, [Text.Encoding]::UTF8))
    if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { $EvidenceDir = Join-Path $repoRoot 'evidence\v3\etapa5-proof' }
    try { if (-not (Test-Path -LiteralPath $EvidenceDir -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($EvidenceDir) } } catch { }

    $SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $NOW = '2026-10-10T12:02:00Z'
    $FUTURE = '2026-10-11T00:00:00Z'

    $shared = Join-Path ([IO.Path]::GetTempPath()) ('v3-e5-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $shared 'goals'; $ckptDir = Join-Path $shared 'ckpts'
    $tasksDir = Join-Path $shared 'tasks'; $waitsDir = Join-Path $shared 'waits'
    foreach ($d in @($shared, $goalDir, $ckptDir, $tasksDir, $waitsDir)) { [void][System.IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $shared 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    $markerPath = Join-Path $shared 'process1-done.json'
    $childPath = Join-Path $shared 'child-e5.ps1'

    $childCode = @'
[CmdletBinding()]
param(
    [string]$GoalDir = '',
    [string]$CkptDir = '',
    [string]$TasksDir = '',
    [string]$WaitsDir = '',
    [string]$FlagsPath = '',
    [string]$TelemetryRoot = '',
    [string]$MarkerPath = '',
    [string]$LibDir = '',
    [string]$PolicyPath = ''
)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $LibDir 'OrchestrationGoalKernel.ps1')
    . (Join-Path $LibDir 'OrchestrationTaskKernel.ps1')
    . (Join-Path $LibDir 'OrchestrationGoalCheckpoint.ps1')
    . (Join-Path $LibDir 'OrchestrationGitHubResume.ps1')
    $policy = ConvertFrom-Json ([IO.File]::ReadAllText($PolicyPath, [Text.Encoding]::UTF8))
    $SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $FUTURE = '2026-10-11T00:00:00Z'
    $REPO = 'acme/widgets'
    $g = New-OrchestrationGoal -GoalId 'e5-goal-1' -Objective 'etapa5 dois processos' -Criteria @('a','b') -TotalPhases 2 -StoreDir $GoalDir
    if (-not [bool]$g.ok) { throw ('goal-create:' + [string]$g.reason) }
    $null = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE').goal -StoreDir $GoalDir
    $slot0 = Get-OrchestrationGoal -GoalId 'e5-goal-1' -StoreDir $GoalDir
    $own0 = Acquire-OrchestrationGoalOwnership -GoalId 'e5-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$slot0.goal['revision']) -StoreDir $GoalDir
    if (-not [bool]$own0.ok) { throw ('ownership:' + [string]$own0.reason) }
    $gen0 = [long]$own0.ownership['generation']
    foreach ($tid in @('e5-task-a','e5-task-b')) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-e5' -ReadScopes @('src/e5.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
        if (-not [bool]$c.ok) { throw ('task-create:' + $tid + ':' + [string]$c.error) }
        $curRev = [long](Get-OrchestrationGoal -GoalId 'e5-goal-1' -StoreDir $GoalDir).goal['revision']
        $add = Add-OrchestrationGoalTaskPersisted -GoalId 'e5-goal-1' -TaskId $tid -ExpectedRevision $curRev -StoreDir $GoalDir -OwnerId 'planner-1' -OwnershipGeneration $gen0
        if (-not [bool]$add.ok) { throw ('attach:' + $tid + ':' + [string]$add.reason) }
    }
    $rev = [long](Get-OrchestrationTask -TaskId 'e5-task-a' -TasksDir $TasksDir).revision
    foreach ($st in @('PLANNING','IMPLEMENTING')) {
        $tr = Invoke-OrchestrationTaskTransition -TaskId 'e5-task-a' -ToState $st -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
        if (-not [bool]$tr.ok) { throw ('transition:' + $st) }
        $rev = [long]$tr.revision
    }
    $wr = Set-OrchestrationTaskWorkerResult -TaskId 'e5-task-a' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
    if (-not [bool]$wr.ok) { throw 'worker-result' }
    $rev = [long]$wr.revision
    $tr = Invoke-OrchestrationTaskTransition -TaskId 'e5-task-a' -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
    $rev = [long]$tr.revision
    $tr = Invoke-OrchestrationTaskTransition -TaskId 'e5-task-a' -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
    $rev = [long]$tr.revision
    $vr = Set-OrchestrationTaskVerification -TaskId 'e5-task-a' -VerifierEvidenceJson '{"ok":true,"task_id":"e5","status":"verified_pass","reason":"","scope":null,"profiles":[],"evidence":["criterion:0:verified"],"command_classes":["test"]}' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath
    if (-not [bool]$vr.ok) { throw 'verification' }
    $rev = [long]$vr.revision
    $rw = Set-OrchestrationTaskReview -TaskId 'e5-task-a' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath
    if (-not [bool]$rw.ok) { throw 'review' }
    $rev = [long]$rw.revision
    $gate = Test-OrchestrationTaskCompletion -TaskId 'e5-task-a' -TasksDir $TasksDir -RepoRoot $TelemetryRoot -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
    if (-not [bool]$gate.complete) { throw ('gate:' + ($gate.reasons -join ',')) }
    $dn = Complete-OrchestrationTask -TaskId 'e5-task-a' -Actor 'planner' -ExpectedRevision $rev -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
    if (-not [bool]$dn.ok) { throw ('done:' + [string]$dn.error) }
    $liveG = (Get-OrchestrationGoal -GoalId 'e5-goal-1' -StoreDir $GoalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $liveG
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $CkptDir
    if (-not [bool]$sv.ok) { throw ('checkpoint:' + [string]$sv.reason) }
    $reg = Register-OrchestrationGitHubWait -WaitsDir $WaitsDir -ObjectiveId 'e5-goal-1' -TaskId 'e5-task-b' -RunId 'run-e5' -Generation 1 -Repository $REPO -PrNumber 42 -Branch 'fix/e5' -ExpectedHeadSha $SHA_A -RequiredChecks @($policy.required_checks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $FUTURE -Owner 'planner-1'
    if (-not [bool]$reg.ok) { throw ('wait:' + [string]$reg.reason) }
    $marker = [ordered]@{ checkpoint_id = [string]$sv.checkpoint_id; generation = $gen0; goal_id = 'e5-goal-1' }
    [IO.File]::WriteAllText($MarkerPath, (($marker | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    exit 0
} catch {
    try { [IO.File]::WriteAllText(($MarkerPath + '.err'), ([string]$_.Exception.Message), [Text.UTF8Encoding]::new($false)) } catch { }
    exit 1
}
'@
    [IO.File]::WriteAllText($childPath, $childCode, [Text.UTF8Encoding]::new($false))

    # Processo 1: filho real em processo separado
    $cargs = @('-NoProfile','-File',$childPath,'-GoalDir',$goalDir,'-CkptDir',$ckptDir,'-TasksDir',$tasksDir,'-WaitsDir',$waitsDir,'-FlagsPath',$flagsPath,'-TelemetryRoot',$shared,'-MarkerPath',$markerPath,'-LibDir',$libDir,'-PolicyPath',$policyPath)
    $proc = Start-Process -FilePath 'powershell' -ArgumentList $cargs -Wait -PassThru -NoNewWindow
    if ([int]$proc.ExitCode -ne 0) { Fail-E5 ('child-exit=' + [string]$proc.ExitCode) $EvidenceDir }
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { Fail-E5 'marker-missing' $EvidenceDir }
    $marker = ConvertFrom-Json ([IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8))
    $cid = [string]$marker.checkpoint_id
    $genChild = [long]$marker.generation
    if ([string]::IsNullOrWhiteSpace($cid)) { Fail-E5 'marker-no-checkpoint' $EvidenceDir }

    # Processo 2: nova leitura do MESMO Goal do disco (sem estado do processo 1)
    . (Join-Path $libDir 'OrchestrationGoalKernel.ps1')
    . (Join-Path $libDir 'OrchestrationTaskKernel.ps1')
    . (Join-Path $libDir 'OrchestrationGoalCheckpoint.ps1')
    . (Join-Path $libDir 'OrchestrationGitHubResume.ps1')
    . (Join-Path $libDir 'OrchestrationDurableResume.ps1')

    $waitFiles = @(Get-ChildItem -LiteralPath $waitsDir -File -Filter 'ghwait-*.json' -ErrorAction Stop)
    if (@($waitFiles).Count -lt 1) { Fail-E5 'wait-not-persisted' $EvidenceDir }
    $wait = ConvertFrom-Json ([IO.File]::ReadAllText($waitFiles[0].FullName, [Text.Encoding]::UTF8))

    $checks = @($policy.required_checks)
    $greenChecks = @()
    foreach ($n in @($checks)) {
        $greenChecks += [pscustomobject]@{ name = [string]$n; head_sha = $SHA_A; status = 'COMPLETED'; conclusion = 'success' }
    }
    $snapGreen = [pscustomobject]@{ repository = 'acme/widgets'; pr_number = 42; head_sha = $SHA_A; commit_sha = $SHA_A; observed_at = $NOW; pr_state = 'OPEN'; mergeable = 'MERGEABLE'; review_decision = 'APPROVED'; checks_complete = $true; checks = @($greenChecks) }
    $bindings = @(@{ run_id = 'run-e5'; root_session = 'ses_root'; worker_sessions = @('ses_b') })
    $obs = @(@{ session_id = 'ses_b'; observed = 'running'; binding_session_id = 'ses_b'; last_seen = $NOW })

    $aBefore = Get-OrchestrationTask -TaskId 'e5-task-a' -TasksDir $tasksDir -RepoRoot $shared
    $aRevBefore = [long]$aBefore.revision
    $aStateBefore = [string]$aBefore.state
    if ($aStateBefore -cne 'DONE') { Fail-E5 ('a-not-done-after-p1:' + $aStateBefore) $EvidenceDir }

    # Resume SEM executor: le estado persistido, decide next_task (nao executa)
    $r1 = Invoke-OrchestrationDurableResume -GoalId 'e5-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid -CheckpointDir $ckptDir -Bindings $bindings -Observations $obs -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapGreen -Policy $policy -NowUtc $NOW -MandatoryTasks @('e5-task-a','e5-task-b') -TasksDir $tasksDir -RepoRoot $shared -EvidenceDir $EvidenceDir
    if ([string]$r1.action -cne 'advance') { Fail-E5 ('resume-not-advance:' + [string]$r1.reason) $EvidenceDir }
    $nextTask = [string]$r1.next_task
    if ($nextTask -cne 'e5-task-b') { Fail-E5 ('wrong-next-task:' + $nextTask) $EvidenceDir }

    # TaskExecutor real: completa B canonicamente relendo tudo do disco
    $tasksDirL = $tasksDir; $flagsPathL = $flagsPath; $sharedL = $shared
    $realExec = {
        param($TaskId)
        try {
            $t = Get-OrchestrationTask -TaskId ([string]$TaskId) -TasksDir $tasksDirL -RepoRoot $sharedL
            if (($null -ne $t) -and ([string]$t.state -ceq 'DONE')) {
                return [pscustomobject]@{ ok = $true; reason = 'already-done'; task_id = [string]$TaskId }
            }
            $rv = [long]$t.revision
            foreach ($st in @('PLANNING','IMPLEMENTING')) {
                $tr = Invoke-OrchestrationTaskTransition -TaskId ([string]$TaskId) -ToState $st -Actor 'planner' -ExpectedRevision $rv -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDirL -FlagsPath $flagsPathL -TelemetryRoot $sharedL
                if (-not [bool]$tr.ok) { return [pscustomobject]@{ ok = $false; reason = ('transition:' + $st); task_id = [string]$TaskId } }
                $rv = [long]$tr.revision
            }
            $wr = Set-OrchestrationTaskWorkerResult -TaskId ([string]$TaskId) -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision $rv -TasksDir $tasksDirL -FlagsPath $flagsPathL -TelemetryRoot $sharedL
            if (-not [bool]$wr.ok) { return [pscustomobject]@{ ok = $false; reason = 'worker-result'; task_id = [string]$TaskId } }
            $rv = [long]$wr.revision
            $tr = Invoke-OrchestrationTaskTransition -TaskId ([string]$TaskId) -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $rv -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDirL -FlagsPath $flagsPathL -TelemetryRoot $sharedL
            $rv = [long]$tr.revision
            $tr = Invoke-OrchestrationTaskTransition -TaskId ([string]$TaskId) -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $rv -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDirL -FlagsPath $flagsPathL -TelemetryRoot $sharedL
            $rv = [long]$tr.revision
            $vr = Set-OrchestrationTaskVerification -TaskId ([string]$TaskId) -VerifierEvidenceJson '{"ok":true,"task_id":"e5","status":"verified_pass","reason":"","scope":null,"profiles":[],"evidence":["criterion:0:verified"],"command_classes":["test"]}' -ExpectedRevision $rv -TasksDir $tasksDirL -FlagsPath $flagsPathL
            if (-not [bool]$vr.ok) { return [pscustomobject]@{ ok = $false; reason = 'verification'; task_id = [string]$TaskId } }
            $rv = [long]$vr.revision
            $rw = Set-OrchestrationTaskReview -TaskId ([string]$TaskId) -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision $rv -TasksDir $tasksDirL -FlagsPath $flagsPathL
            if (-not [bool]$rw.ok) { return [pscustomobject]@{ ok = $false; reason = 'review'; task_id = [string]$TaskId } }
            $rv = [long]$rw.revision
            $gate = Test-OrchestrationTaskCompletion -TaskId ([string]$TaskId) -TasksDir $tasksDirL -RepoRoot $sharedL -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
            if (-not [bool]$gate.complete) { return [pscustomobject]@{ ok = $false; reason = ('gate:' + ($gate.reasons -join ',')); task_id = [string]$TaskId } }
            $dn = Complete-OrchestrationTask -TaskId ([string]$TaskId) -Actor 'planner' -ExpectedRevision $rv -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDirL -FlagsPath $flagsPathL -TelemetryRoot $sharedL
            if (-not [bool]$dn.ok) { return [pscustomobject]@{ ok = $false; reason = ('done:' + [string]$dn.error); task_id = [string]$TaskId } }
            return [pscustomobject]@{ ok = $true; reason = 'dispatched-canonical'; task_id = [string]$TaskId }
        } catch {
            return [pscustomobject]@{ ok = $false; reason = ('executor-threw:' + [string]$_.Exception.Message); task_id = [string]$TaskId }
        }
    }.GetNewClosure()

    # Despacho via resume COM executor (chamada separada, rele estado do disco)
    $r2 = Invoke-OrchestrationDurableResume -GoalId 'e5-goal-1' -GoalStoreDir $goalDir -CheckpointId $cid -CheckpointDir $ckptDir -Bindings $bindings -Observations $obs -StaleAfterSeconds 300 -Wait $wait -Snapshot $snapGreen -Policy $policy -NowUtc $NOW -MandatoryTasks @('e5-task-a','e5-task-b') -TasksDir $tasksDir -RepoRoot $shared -EvidenceDir $EvidenceDir -TaskExecutor $realExec
    $d2 = $null; try { $d2 = $r2.dispatch } catch { $d2 = $null }
    if ([string]$r2.action -cne 'advance') { Fail-E5 ('dispatch-not-advance:' + [string]$r2.reason) $EvidenceDir }
    if (($null -eq $d2) -or (-not [bool]$d2.ok) -or ([string]$d2.task_id -cne 'e5-task-b')) { Fail-E5 'dispatch-failed' $EvidenceDir }

    # A nao reexecutada: revisao/estado intactos, sem nova transicao
    $aAfter = Get-OrchestrationTask -TaskId 'e5-task-a' -TasksDir $tasksDir -RepoRoot $shared
    if (([string]$aAfter.state -cne 'DONE') -or ([long]$aAfter.revision -ne $aRevBefore)) { Fail-E5 'a-rerun-detected' $EvidenceDir }
    $bAfter = Get-OrchestrationTask -TaskId 'e5-task-b' -TasksDir $tasksDir -RepoRoot $shared
    if ([string]$bAfter.state -cne 'DONE') { Fail-E5 ('b-not-done:' + [string]$bAfter.state) $EvidenceDir }

    # Completa Goal via CAS somente apos B DONE + criterios
    $ren = Renew-OrchestrationGoalOwnership -GoalId 'e5-goal-1' -OwnerId 'planner-1' -Generation $genChild -StoreDir $goalDir -LeaseTtlMs 120000
    $genNow = if ([bool]$ren.ok) { [long]$ren.ownership['generation'] } else { $genChild }
    $liveRev = [long](Get-OrchestrationGoal -GoalId 'e5-goal-1' -StoreDir $goalDir).goal['revision']
    $upd = Update-OrchestrationGoal -GoalId 'e5-goal-1' -ExpectedRevision $liveRev -Fields @{ progress = @{ satisfied = 2; total = 2 }; plan_progress = @{ phase = 2; total_phases = 2; done_tasks = 2 } } -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $genNow
    if (-not [bool]$upd.ok) { Fail-E5 ('progress-cas:' + [string]$upd.reason) $EvidenceDir }
    $liveRev2 = [long](Get-OrchestrationGoal -GoalId 'e5-goal-1' -StoreDir $goalDir).goal['revision']
    $fin = Set-OrchestrationGoalStatePersisted -GoalId 'e5-goal-1' -ToState 'COMPLETED' -ExpectedRevision $liveRev2 -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $genNow
    if (-not [bool]$fin.ok) { Fail-E5 ('goal-complete:' + [string]$fin.reason) $EvidenceDir }
    $finalState = [string](Get-OrchestrationGoal -GoalId 'e5-goal-1' -StoreDir $goalDir).goal['state']
    if ($finalState -cne 'COMPLETED') { Fail-E5 ('goal-not-completed:' + $finalState) $EvidenceDir }

    Write-E5Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = ([DateTime]::UtcNow.ToString('o')); status = 'REAL'; next_task = $nextTask; a_not_rerun = $true; goal = $finalState })
    Write-Host ('PROOF_ETAPA5=REAL:{next_task=' + $nextTask + ',a_not_rerun:true,goal:COMPLETED}')
    try { Remove-Item -LiteralPath $shared -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    exit 0
} catch {
    try {
        $msg = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'harness-exception' }
        Write-Host ('PROOF_ETAPA5=FAIL:' + $msg)
    } catch { }
    exit 1
}
