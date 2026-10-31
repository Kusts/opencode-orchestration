<#!
.SYNOPSIS
    Etapa 6D REAL - prova com 2 processos reais, sem LLM, sem rede obrigatoria.
.DESCRIPTION
    Processo 1 (script filho via powershell -File): cria Goal+Tasks A..F em
    dirs temp compartilhados, completa Task A via cadeia canonica
    (transitions + worker_result + verification + review + completion),
    bloqueia B..F com typed wait (external_dependency/revalidate-github-ci),
    registra um ghwait por task (PRs 42..47), persiste checkpoint, ESCREVE
    marcador e ENCERRA.
    Processo 2 (este processo, sem estado do processo 1): sonda o transporte
    live real (gh api graphql viewer via Invoke-GHAChildTransport; honesto:
    registra probe_ok/probe-failed sem fabricar observacao live de PR),
    valida cada fixture RAW pelo normalizer real (Convert-GHARawToSnapshot),
    e invoca scripts/v3/github-wake.ps1 como o agendador faria (novo
    processo por cenario, via -ConfigFile persistido por
    New-GitHubWakeConfig): READY observavel, already-done, RESUME +
    CAS + unblock, duplicata suprimida, SHA obsoleto TERMINAL, PR fechado
    TERMINAL, CI vermelho diagnostico sem unblock, CI pendente KEEP_WAITING.
    Verifica A/DONE nunca reexecutadas e imprime PROOF_ETAPA6D=REAL ou FAIL.
    PS 5.1, ASCII-only. Sem Planner/Kernel novo, sem merge/deploy/DONE.
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = ''
)
$ErrorActionPreference = 'Stop'

function Write-E6Evidence {
    param($Dir, $Record)
    try {
        if ([string]::IsNullOrWhiteSpace([string]$Dir)) { return }
        try {
            if (-not (Test-Path -LiteralPath ([string]$Dir) -PathType Container)) {
                [void][System.IO.Directory]::CreateDirectory([string]$Dir)
            }
        } catch { return }
        $line = ($Record | ConvertTo-Json -Compress -Depth 8)
        [IO.File]::AppendAllText((Join-Path ([string]$Dir) 'etapa6d-proof.jsonl'), ($line + [System.Environment]::NewLine), [System.Text.Encoding]::UTF8)
    } catch { }
}

function Fail-E6 {
    param([string]$Message, $Dir)
    Write-Host ('PROOF_ETAPA6D=FAIL:' + [string]$Message)
    Write-E6Evidence -Dir $Dir -Record ([ordered]@{ timestamp = ([DateTime]::UtcNow.ToString('o')); status = 'FAIL'; reason = [string]$Message })
    exit 1
}

try {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $libDir = Join-Path $PSScriptRoot 'lib'
    $wakeCli = Join-Path $PSScriptRoot 'github-wake.ps1'
    if (-not (Test-Path -LiteralPath $wakeCli -PathType Leaf)) { Fail-E6 'wake-missing' $EvidenceDir }
    $policyPath = Join-Path $repoRoot 'source\registry\delivery-policy.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) { Fail-E6 'policy-missing' $EvidenceDir }
    $policy = ConvertFrom-Json ([IO.File]::ReadAllText($policyPath, [Text.Encoding]::UTF8))
    $reqChecks = @($policy.required_checks)
    if (@($reqChecks).Count -eq 0) { Fail-E6 'policy-no-checks' $EvidenceDir }
    if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { $EvidenceDir = Join-Path $repoRoot 'evidence\v3\etapa6d-proof' }
    try { if (-not (Test-Path -LiteralPath $EvidenceDir -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($EvidenceDir) } } catch { }

    $SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $NOW = '2026-10-10T12:02:00Z'
    $FUTURE = '2026-10-11T00:00:00Z'
    $REPO = 'acme/widgets'

    $E6_SavedPolicyPath = $policyPath
    $E6_SavedFlagsPath = $null
    . (Join-Path $PSScriptRoot 'github-wake.ps1')
    . (Join-Path $PSScriptRoot 'github-await.ps1')
    $policyPath = $E6_SavedPolicyPath
    Remove-Variable -Name E6_SavedPolicyPath, E6_SavedFlagsPath -ErrorAction SilentlyContinue

    $shared = Join-Path ([IO.Path]::GetTempPath()) ('v3-e6d-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $shared 'goals'; $ckptDir = Join-Path $shared 'ckpts'
    $tasksDir = Join-Path $shared 'tasks'; $waitsDir = Join-Path $shared 'waits'
    $caseDir = Join-Path $shared 'cases'
    foreach ($d in @($shared, $goalDir, $ckptDir, $tasksDir, $waitsDir, $caseDir)) { [void][System.IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $shared 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    $markerPath = Join-Path $shared 'process1-done.json'
    $childPath = Join-Path $shared 'child-e6d.ps1'

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
    $tasks = @('e6d-task-a', 'e6d-task-b', 'e6d-task-c', 'e6d-task-d', 'e6d-task-e', 'e6d-task-f')
    $prs = @{ 'e6d-task-a' = 42; 'e6d-task-b' = 43; 'e6d-task-c' = 44; 'e6d-task-d' = 45; 'e6d-task-e' = 46; 'e6d-task-f' = 47 }
    $g = New-OrchestrationGoal -GoalId 'e6d-goal-1' -Objective 'etapa 6d wake real' -Criteria @('a', 'b') -TotalPhases 2 -StoreDir $GoalDir
    if (-not [bool]$g.ok) { throw ('goal-create:' + [string]$g.reason) }
    $svNew = Save-OrchestrationGoal -Goal $g.goal -StoreDir $GoalDir
    if (-not [bool]$svNew.ok) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId 'e6d-goal-1' -StoreDir $GoalDir
    $null = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $slot0.goal -ToState 'ACTIVE').goal -StoreDir $GoalDir
    $live0 = (Get-OrchestrationGoal -GoalId 'e6d-goal-1' -StoreDir $GoalDir).goal
    $own0 = Acquire-OrchestrationGoalOwnership -GoalId 'e6d-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$live0['revision']) -StoreDir $GoalDir
    if (-not [bool]$own0.ok) { throw ('ownership:' + [string]$own0.reason) }
    $gen0 = [long]$own0.ownership['generation']
    foreach ($tid in @($tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-e6d' -ReadScopes @('src/e6d.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
        if (-not [bool]$c.ok) { throw ('task-create:' + $tid + ':' + [string]$c.error) }
        $curRev = [long](Get-OrchestrationGoal -GoalId 'e6d-goal-1' -StoreDir $GoalDir).goal['revision']
        $add = Add-OrchestrationGoalTaskPersisted -GoalId 'e6d-goal-1' -TaskId $tid -ExpectedRevision $curRev -StoreDir $GoalDir -OwnerId 'planner-1' -OwnershipGeneration $gen0
        if (-not [bool]$add.ok) { throw ('attach:' + $tid + ':' + [string]$add.reason) }
    }
    $t = Get-OrchestrationTask -TaskId 'e6d-task-a' -TasksDir $TasksDir -RepoRoot $TelemetryRoot
    $rev = [long]$t.revision
    foreach ($st in @('PLANNING', 'IMPLEMENTING')) {
        $tr = Invoke-OrchestrationTaskTransition -TaskId 'e6d-task-a' -ToState $st -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
        if (-not [bool]$tr.ok) { throw ('transition:' + $st) }
        $rev = [long]$tr.revision
    }
    $wr = Set-OrchestrationTaskWorkerResult -TaskId 'e6d-task-a' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
    if (-not [bool]$wr.ok) { throw 'worker-result' }
    $rev = [long]$wr.revision
    $tr = Invoke-OrchestrationTaskTransition -TaskId 'e6d-task-a' -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
    $rev = [long]$tr.revision
    $tr = Invoke-OrchestrationTaskTransition -TaskId 'e6d-task-a' -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
    $rev = [long]$tr.revision
    $vr = Set-OrchestrationTaskVerification -TaskId 'e6d-task-a' -VerifierEvidenceJson '{"ok":true,"task_id":"e6d","status":"verified_pass","reason":"","scope":null,"profiles":[],"evidence":["criterion:0:verified"],"command_classes":["test"]}' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath
    if (-not [bool]$vr.ok) { throw 'verification' }
    $rev = [long]$vr.revision
    $rw = Set-OrchestrationTaskReview -TaskId 'e6d-task-a' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath
    if (-not [bool]$rw.ok) { throw 'review' }
    $rev = [long]$rw.revision
    $gate = Test-OrchestrationTaskCompletion -TaskId 'e6d-task-a' -TasksDir $TasksDir -RepoRoot $TelemetryRoot -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
    if (-not [bool]$gate.complete) { throw ('gate:' + ($gate.reasons -join ',')) }
    $dn = Complete-OrchestrationTask -TaskId 'e6d-task-a' -Actor 'planner' -ExpectedRevision $rev -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
    if (-not [bool]$dn.ok) { throw ('done:' + [string]$dn.error) }
    foreach ($tid in @('e6d-task-b', 'e6d-task-c', 'e6d-task-d', 'e6d-task-e', 'e6d-task-f')) {
        $pr = [long]$prs[$tid]
        $dep = ('github-ci:v1:' + $REPO + ':' + [string]$pr + ':' + $SHA_A)
        $tt = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir -RepoRoot $TelemetryRoot
        $rv2 = [long]$tt.revision
        $tr = Invoke-OrchestrationTaskTransition -TaskId $tid -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rv2 -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot
        if (-not [bool]$tr.ok) { throw ('pre:' + $tid) }
        $rv2 = [long]$tr.revision
        $tr = Invoke-OrchestrationTaskTransition -TaskId $tid -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rv2 -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
        if (-not [bool]$tr.ok) { throw ('block:' + $tid + ':' + [string]$tr.error) }
    }
    $liveG = (Get-OrchestrationGoal -GoalId 'e6d-goal-1' -StoreDir $GoalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $liveG
    if ($null -eq $ckpt) { throw 'checkpoint-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $CkptDir
    if (-not [bool]$sv.ok) { throw ('checkpoint:' + [string]$sv.reason) }
    foreach ($tid in @($tasks)) {
        $pr = [long]$prs[$tid]
        $reg = Register-OrchestrationGitHubWait -WaitsDir $WaitsDir -ObjectiveId 'e6d-goal-1' -TaskId $tid -RunId 'run-e6d' -Generation 1 -Repository $REPO -PrNumber $pr -Branch 'fix/e6d' -ExpectedHeadSha $SHA_A -RequiredChecks @($policy.required_checks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $FUTURE -Owner 'planner-1'
        if (-not [bool]$reg.ok) { throw ('wait:' + $tid + ':' + [string]$reg.reason) }
    }
    $aAfter = Get-OrchestrationTask -TaskId 'e6d-task-a' -TasksDir $TasksDir -RepoRoot $TelemetryRoot
    $marker = [ordered]@{ checkpoint_id = [string]$sv.checkpoint_id; generation = $gen0; goal_id = 'e6d-goal-1'; a_revision = [long]$aAfter.revision; a_state = [string]$aAfter.state }
    [IO.File]::WriteAllText($MarkerPath, (($marker | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    exit 0
} catch {
    try { [IO.File]::WriteAllText(($MarkerPath + '.err'), ([string]$_.Exception.Message), [Text.UTF8Encoding]::new($false)) } catch { }
    exit 1
}
'@
    [IO.File]::WriteAllText($childPath, $childCode, [Text.UTF8Encoding]::new($false))

    # Processo 1: filho real em processo separado
    $cargs = @('-NoProfile', '-File', $childPath, '-GoalDir', $goalDir, '-CkptDir', $ckptDir, '-TasksDir', $tasksDir, '-WaitsDir', $waitsDir, '-FlagsPath', $flagsPath, '-TelemetryRoot', $shared, '-MarkerPath', $markerPath, '-LibDir', $libDir, '-PolicyPath', $policyPath)
    $proc = Start-Process -FilePath 'powershell' -ArgumentList $cargs -Wait -PassThru -NoNewWindow
    if ([int]$proc.ExitCode -ne 0) { Fail-E6 ('child-exit=' + [string]$proc.ExitCode) $EvidenceDir }
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { Fail-E6 'marker-missing' $EvidenceDir }
    $marker = ConvertFrom-Json ([IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8))
    $cid = [string]$marker.checkpoint_id
    $aRevP1 = [long]$marker.a_revision
    if ([string]::IsNullOrWhiteSpace($cid)) { Fail-E6 'marker-no-checkpoint' $EvidenceDir }
    if ([string]$marker.a_state -cne 'DONE') { Fail-E6 'a-not-done-after-p1' $EvidenceDir }

    # Processo 2: sonda live honesta do transporte real (sem fabricar PR live).
    $ghExe = $null
    try { $ghExe = Get-Command gh -ErrorAction SilentlyContinue } catch { $ghExe = $null }
    $ghPresent = (($null -ne $ghExe) -and (-not [string]::IsNullOrWhiteSpace([string]$ghExe.Source)))
    $probeOk = $false
    $probeDetail = 'gh-not-found'
    if ([bool]$ghPresent) {
        try {
            $probeChild = Invoke-GHAChildTransport -FilePath ([string]$ghExe.Source) -ArgumentList @('api', 'graphql', '-f', 'query=query{viewer{login}}') -TimeoutMs 10000 -OutputCapChars 262144
            if (($null -ne $probeChild) -and [bool]$probeChild.Started -and (-not [bool]$probeChild.TimedOut) -and ([int]$probeChild.ExitCode -eq 0) -and (-not [string]::IsNullOrWhiteSpace([string]$probeChild.Stdout))) {
                $probeRaw = ConvertFrom-Json ([string]$probeChild.Stdout)
                if (($null -ne $probeRaw) -and ($null -ne $probeRaw.data)) { $probeOk = $true; $probeDetail = 'viewer-ok' }
                else { $probeDetail = 'probe-no-data' }
            }
            else { $probeDetail = 'probe-transport-failed' }
        }
        catch { $probeDetail = 'probe-exception' }
    }
    Write-E6Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = ([DateTime]::UtcNow.ToString('o')); status = 'TRANSPORT_PROBE'; gh_present = [bool]$ghPresent; probe_ok = [bool]$probeOk; detail = $probeDetail })

    # Fixtures RAW (resposta GraphQL bruta); wake normaliza pelo caminho real.
    function New-E6Node {
        param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
        return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
    }
    function New-E6Raw {
        param($Nodes, [string]$Head, [string]$Commit, [long]$Pr, [string]$State = 'OPEN', $Merge = 'MERGEABLE', $Review = 'APPROVED')
        $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
        $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $REPO; pullRequest = [pscustomobject]@{ number = $Pr; state = $State; headRefOid = $Head; mergeable = $Merge; reviewDecision = $Review; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
        return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
    }
    function New-E6GreenNodes {
        param([string]$Sha)
        $out = @()
        foreach ($n in @($reqChecks)) { $out += @(New-E6Node $n 'COMPLETED' 'SUCCESS' $Sha) }
        return $out
    }
    function Write-E6Fixture {
        param($Raw, [string]$Name)
        $p = Join-Path $caseDir $Name
        [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
        return $p
    }
    $fxGreen43 = Write-E6Fixture -Raw (New-E6Raw -Nodes (New-E6GreenNodes $SHA_A) -Head $SHA_A -Commit $SHA_A -Pr 43) -Name 'green-43.graphql.json'
    $fxGreen42 = Write-E6Fixture -Raw (New-E6Raw -Nodes (New-E6GreenNodes $SHA_A) -Head $SHA_A -Commit $SHA_A -Pr 42) -Name 'green-42.graphql.json'
    $fxStale = Write-E6Fixture -Raw (New-E6Raw -Nodes (New-E6GreenNodes $SHA_B) -Head $SHA_B -Commit $SHA_B -Pr 44) -Name 'stale-44.graphql.json'
    $fxClosed = Write-E6Fixture -Raw (New-E6Raw -Nodes (New-E6GreenNodes $SHA_A) -Head $SHA_A -Commit $SHA_A -Pr 45 -State 'CLOSED') -Name 'closed-45.graphql.json'
    $redNodes = New-E6GreenNodes $SHA_A
    $redNodes[0] = New-E6Node $reqChecks[0] 'COMPLETED' 'FAILURE' $SHA_A
    $fxRed = Write-E6Fixture -Raw (New-E6Raw -Nodes $redNodes -Head $SHA_A -Commit $SHA_A -Pr 46) -Name 'red-46.graphql.json'
    $pendNodes = New-E6GreenNodes $SHA_A
    $pendNodes[0] = New-E6Node $reqChecks[0] 'IN_PROGRESS' $null $SHA_A
    $fxPend = Write-E6Fixture -Raw (New-E6Raw -Nodes $pendNodes -Head $SHA_A -Commit $SHA_A -Pr 47) -Name 'pending-47.graphql.json'
    # Valida cada fixture pelo normalizer real antes de invocar o wake.
    foreach ($pair in @(@($fxGreen43, 43), @($fxGreen42, 42), @($fxStale, 44), @($fxClosed, 45), @($fxRed, 46), @($fxPend, 47))) {
        $rawDoc = ConvertFrom-Json ([IO.File]::ReadAllText([string]$pair[0], [Text.Encoding]::UTF8))
        $norm = Convert-GHARawToSnapshot -Raw $rawDoc -Repository $REPO -PrNumber ([long]$pair[1]) -ObservedAt $NOW
        if (-not [bool]$norm.ok) { Fail-E6 ('fixture-normalizer-rejected:' + [string]$pair[0]) $EvidenceDir }
    }

    $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    function Invoke-E6Wake {
        param([string]$Fixture = '', [bool]$Auth = $false, [bool]$Exec = $false)
        $cfgPath = Join-Path $caseDir ('wake-' + [guid]::NewGuid().ToString('N') + '.json')
        $cfg = New-GitHubWakeConfig -Path $cfgPath -WaitsDir $waitsDir -TasksDir $tasksDir -GoalStoreDir $goalDir -CheckpointDir $ckptDir -FlagsPath $flagsPath -GraphQLSnapshotFile $Fixture -NowUtc $NOW
        if (-not [bool]$cfg.ok) { throw ('config:' + [string]$cfg.reason) }
        $wargs = @('-NoProfile', '-File', $wakeCli, '-ConfigFile', $cfgPath)
        if ([bool]$Auth) { $wargs += @('-AuthorizationAlive') }
        if ([bool]$Exec) { $wargs += @('-ExecutorPresent') }
        $out = & $psExe @wargs 2>$null
        $code = $LASTEXITCODE
        $text = ''
        if ($null -ne $out) { $text = ($out -join "`n").Trim() }
        $env = $null
        try { if (-not [string]::IsNullOrWhiteSpace($text)) { $env = ConvertFrom-Json $text } } catch { $env = $null }
        return @{ code = $code; env = $env }
    }
    function Get-E6Item {
        param($Env, [string]$TaskId = '')
        foreach ($it in @($Env.items)) {
            if ([string]$it.task_id -ceq $TaskId) { return $it }
        }
        return $null
    }

    # 1. READY observavel: B verde sem executor => sem unblock, ainda BLOCKED.
    $r = Invoke-E6Wake -Fixture $fxGreen43 -Auth $true -Exec $false
    if ([int]$r.code -ne 0) { Fail-E6 'ready-exit' $EvidenceDir }
    $itB = Get-E6Item -Env $r.env -TaskId 'e6d-task-b'
    if (($null -eq $itB) -or ([string]$itB.decision -cne 'READY')) { Fail-E6 'ready-not-observed' $EvidenceDir }
    . (Join-Path $libDir 'OrchestrationTaskKernel.ps1')
    $stB = [string](Get-OrchestrationTask -TaskId 'e6d-task-b' -TasksDir $tasksDir -RepoRoot $shared).state
    if ($stB -cne 'BLOCKED') { Fail-E6 'ready-mutated' $EvidenceDir }

    # 2. DONE nunca reexecutada: A => HOLD already-done.
    $r = Invoke-E6Wake -Fixture $fxGreen42 -Auth $true -Exec $true
    $itA = Get-E6Item -Env $r.env -TaskId 'e6d-task-a'
    if (($null -eq $itA) -or ([string]$itA.decision -cne 'HOLD') -or ([string]$itA.reason -cne 'already-done')) { Fail-E6 'done-not-held' $EvidenceDir }

    # 3. RESUME: B verde com executor => CAS + unblock + proxima acao.
    $r = Invoke-E6Wake -Fixture $fxGreen43 -Auth $true -Exec $true
    $itB = Get-E6Item -Env $r.env -TaskId 'e6d-task-b'
    if (($null -eq $itB) -or ([string]$itB.decision -cne 'RESUME')) { Fail-E6 'resume-missing' $EvidenceDir }
    if ([string]$itB.kernel -cne 'unblocked' -or (-not [bool]$itB.confirmed)) { Fail-E6 'resume-not-applied' $EvidenceDir }
    $nx = $r.env.next_action
    if (($null -eq $nx) -or ([string]$nx.task_id -cne 'e6d-task-b')) { Fail-E6 'next-action-missing' $EvidenceDir }
    if ([bool]$r.env.grants_authority -or [bool]$r.env.merge_authority -or [bool]$r.env.done_approved) { Fail-E6 'authority-leak' $EvidenceDir }
    $revB = [long](Get-OrchestrationTask -TaskId 'e6d-task-b' -TasksDir $tasksDir -RepoRoot $shared).revision
    $stB = [string](Get-OrchestrationTask -TaskId 'e6d-task-b' -TasksDir $tasksDir -RepoRoot $shared).state
    if ($stB -cne 'IMPLEMENTING') { Fail-E6 'unblock-missing' $EvidenceDir }

    # 4. Duplicata suprimida: mesmo evento => DUPLICATE_NOOP, kernel intacto.
    $r = Invoke-E6Wake -Fixture $fxGreen43 -Auth $true -Exec $true
    $itB = Get-E6Item -Env $r.env -TaskId 'e6d-task-b'
    if (($null -eq $itB) -or ([string]$itB.decision -cne 'DUPLICATE_NOOP')) { Fail-E6 'duplicate-not-suppressed' $EvidenceDir }
    $revB2 = [long](Get-OrchestrationTask -TaskId 'e6d-task-b' -TasksDir $tasksDir -RepoRoot $shared).revision
    if ($revB2 -ne $revB) { Fail-E6 'duplicate-mutated' $EvidenceDir }

    # 5. SHA obsoleto => TERMINAL head-superseded, ainda BLOCKED.
    $r = Invoke-E6Wake -Fixture $fxStale -Auth $true -Exec $true
    $itC = Get-E6Item -Env $r.env -TaskId 'e6d-task-c'
    if (($null -eq $itC) -or ([string]$itC.decision -cne 'TERMINAL') -or ([string]$itC.reason -cne 'head-superseded')) { Fail-E6 'stale-not-terminal' $EvidenceDir }
    if ([string](Get-OrchestrationTask -TaskId 'e6d-task-c' -TasksDir $tasksDir -RepoRoot $shared).state -cne 'BLOCKED') { Fail-E6 'stale-mutated' $EvidenceDir }

    # 6. PR fechado => TERMINAL pr-terminal, ainda BLOCKED.
    $r = Invoke-E6Wake -Fixture $fxClosed -Auth $true -Exec $true
    $itD = Get-E6Item -Env $r.env -TaskId 'e6d-task-d'
    if (($null -eq $itD) -or ([string]$itD.decision -cne 'TERMINAL') -or ([string]$itD.reason -cne 'pr-terminal')) { Fail-E6 'closed-not-terminal' $EvidenceDir }
    if ([string](Get-OrchestrationTask -TaskId 'e6d-task-d' -TasksDir $tasksDir -RepoRoot $shared).state -cne 'BLOCKED') { Fail-E6 'closed-mutated' $EvidenceDir }

    # 7. CI vermelho => diagnostico TERMINAL, sem unblock, sem confirm.
    $r = Invoke-E6Wake -Fixture $fxRed -Auth $true -Exec $true
    $itE = Get-E6Item -Env $r.env -TaskId 'e6d-task-e'
    if (($null -eq $itE) -or ([string]$itE.decision -cne 'TERMINAL') -or ([string]$itE.reason -cne 'diagnostic')) { Fail-E6 'red-not-diagnostic' $EvidenceDir }
    if (([string](Get-OrchestrationTask -TaskId 'e6d-task-e' -TasksDir $tasksDir -RepoRoot $shared).state -cne 'BLOCKED') -or [bool]$itE.confirmed) { Fail-E6 'red-mutated' $EvidenceDir }

    # 8. CI pendente => KEEP_WAITING, ainda BLOCKED.
    $r = Invoke-E6Wake -Fixture $fxPend -Auth $true -Exec $true
    $itF = Get-E6Item -Env $r.env -TaskId 'e6d-task-f'
    if (($null -eq $itF) -or ([string]$itF.decision -cne 'KEEP_WAITING')) { Fail-E6 'pending-not-waiting' $EvidenceDir }
    if ([string](Get-OrchestrationTask -TaskId 'e6d-task-f' -TasksDir $tasksDir -RepoRoot $shared).state -cne 'BLOCKED') { Fail-E6 'pending-mutated' $EvidenceDir }

    # A intacta: DONE nunca reexecutada.
    $aFinal = Get-OrchestrationTask -TaskId 'e6d-task-a' -TasksDir $tasksDir -RepoRoot $shared
    if (([string]$aFinal.state -cne 'DONE') -or ([long]$aFinal.revision -ne $aRevP1)) { Fail-E6 'a-rerun-detected' $EvidenceDir }

    # Scheduler: dry-run prova o XML sem mutar o sistema.
    $schedCfg = New-GitHubWakeConfig -Path (Join-Path $caseDir 'sched.json') -WaitsDir $waitsDir -TasksDir $tasksDir -GoalStoreDir $goalDir -CheckpointDir $ckptDir -FlagsPath $flagsPath -AuthorizationAlive $true -ExecutorPresent $false
    if (-not [bool]$schedCfg.ok) { Fail-E6 'sched-config' $EvidenceDir }
    $dry = Register-GitHubWakeSchedule -TaskName 'e6d-gh-wake-proof' -WakeScript $wakeCli -ConfigFile ([string]$schedCfg.path) -IntervalMinutes 5 -DurationHours 12 -ExecutionTimeLimitMinutes 5 -DryRun
    if ((-not [bool]$dry.ok) -or ([string]$dry.xml -cnotmatch 'PT5M') -or ([string]$dry.xml -cnotmatch 'ExecutionTimeLimit')) { Fail-E6 'sched-xml' $EvidenceDir }

    $liveNote = 'fixture-real-normalizer+live-transport-probe'
    if ([bool]$probeOk) { $liveNote = 'fixture-real-normalizer+live-probe-ok' }
    Write-E6Evidence -Dir $EvidenceDir -Record ([ordered]@{ timestamp = ([DateTime]::UtcNow.ToString('o')); status = 'REAL'; next_task = 'e6d-task-b'; a_not_rerun = $true; transport_probe = $probeDetail; live_note = $liveNote })
    Write-Host ('PROOF_ETAPA6D=REAL:{next_task:e6d-task-b,a_not_rerun:true,transport_probe:' + $probeDetail + ',live:' + $liveNote + '}')
    try { Remove-Item -LiteralPath $shared -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    exit 0
} catch {
    try {
        $msg = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'harness-exception' }
        Write-Host ('PROOF_ETAPA6D=FAIL:' + $msg)
    } catch { }
    exit 1
}
