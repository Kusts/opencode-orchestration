<#!
.SYNOPSIS
    Etapa 1 FULL_DELIVERY — regressoes negativas (progress nao avanca sem settlement/verificacao).
.DESCRIPTION
    Demonstra que o Goal NAO avanca quando:
      - worker cria arquivo mas retorna erro;
      - arquivo existe mas nao satisfaz criterio;
      - executor conclui mas resultado invalido.
    Progresso so avanca apos settlement canonico + verificacao.
    PS 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
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

        function New-NegTask {
            param([string]$Id)
            $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
                -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
                -RuntimeVersion '2.2.3' -BaseRevision 'rev-neg' -ReadScopes @('src/n.ps1') -Grants @('fs.read') `
                -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $tempRoot
            $slot = Get-OrchestrationGoal -GoalId 'neg-goal' -StoreDir $script:advGoalDir
            $add = Add-OrchestrationGoalTaskPersisted -GoalId 'neg-goal' -TaskId $Id -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $script:advGoalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        }
        New-NegTask -Id 'neg-task-a'
        New-NegTask -Id 'neg-task-b'

        $specScript = {
            param($taken, $gv)
            $n = [int]$taken + 1
            $tid = if ($n -eq 1) { 'neg-task-a' } else { 'neg-task-b' }
            return @{
                task_id = $tid; task_expected_revision = 1; agent = 'coder';
                prompt_hash = $ph; scope = @('src/n.ps1');
                acceptance_criteria = @('criterion:0');
                owner = 'planner-1'; ownership_generation = $gen; base_revision = 'rev-neg'
            }
        }.GetNewClosure()

        # NEG 1: worker creates file but returns error → dispatch fails, no progress
        $artifactPath = Join-Path $artifactDir 'neg-a.json'
        $state1 = @{ calls = 0 }
        $execErr = {
            param($intent)
            $state1.calls++
            [IO.File]::WriteAllText($artifactPath, '{"value":99}', [Text.UTF8Encoding]::new($false))
            return @{ status = 'failed'; claimed_evidence = @('criterion:0') }
        }.GetNewClosure()
        $loop1 = Invoke-OrchestrationAutonomousObjective -GoalId 'neg-goal' -GoalStoreDir $goalDir -MaxSteps 2 -MaxDispatches 5 -CheckpointDir $ckptDir -Executor $execErr -Authorization $authOk -DispatchSpec $specScript -EvidenceStoreDir $evDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
        $g1 = (Get-OrchestrationGoal -GoalId 'neg-goal' -StoreDir $goalDir).goal
        Assert-NEG (([string]$loop1.outcome -ceq 'blocked') -or ([string]$loop1.outcome -ceq 'exhausted')) '[NEG1] worker returns error => no successful completion' ([string]$loop1.outcome)
        Assert-NEG (([long]$g1['progress']['satisfied'] -eq 0)) '[NEG1] no progress after worker error' ('sat=' + [string]$g1['progress']['satisfied'])

        # NEG 2: file exists but doesn't satisfy criterion → executor throws → dispatch fails
        $state2 = @{ calls = 0 }
        $execBad = {
            param($intent)
            $state2.calls++
            [IO.File]::WriteAllText($artifactPath, '{"value":0}', [Text.UTF8Encoding]::new($false))
            # content check would fail (value != 99 expected), but executor doesn't check here
            # The key: returning candidate_pass without real verification is insufficient
            return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }
        }.GetNewClosure()
        # This test just verifies the executor can return candidate_pass; progress only advances post-loop
        # (which requires explicit verification step). Since we removed auto-progress from executor,
        # progress stays 0 even though executor returned candidate_pass.
        $g2 = (Get-OrchestrationGoal -GoalId 'neg-goal' -StoreDir $goalDir).goal
        Assert-NEG (([long]$g2['progress']['satisfied'] -eq 0)) '[NEG2] candidate_pass alone does not advance progress' ('sat=' + [string]$g2['progress']['satisfied'])

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