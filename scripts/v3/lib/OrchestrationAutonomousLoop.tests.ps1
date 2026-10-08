<#!
.SYNOPSIS
    Tests for lib/OrchestrationAutonomousLoop.ps1 (passo unico + driver).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn.
    Covers: step CONTINUE produces intent (no Executor) for Planner
    subagent; dispatch with stub Executor (Gate C multiphase fase1->fase2);
    TASK_DONE != OBJECTIVE_DONE; resume without duplication; stale reuse
    never becomes DONE; bounded driver (no infinite loop).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationReuseWiring.ps1')

$script:passed = 0
$script:failed = 0

function Assert-AL {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-autoloop-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $goalDir = Join-Path $tempRoot 'goals'
    $ckptDir = Join-Path $tempRoot 'checkpoints'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $evDir = Join-Path $tempRoot 'evidence'
    foreach ($d in @($goalDir, $ckptDir, $receiptDir, $evDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

    try {
        # ---------- fixture: ACTIVE goal, 2 criteria, ownership ----------
        $g = New-OrchestrationGoal -GoalId 'al-goal-1' -Objective 'loop honesto' -Criteria @('criterio-a', 'criterio-b') -TotalPhases 2 -StoreDir $goalDir
        Assert-AL ([bool]$g.ok) '[F] goal created' ([string]$g.reason)
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        Assert-AL ([bool]$sv.ok) '[F] goal active+saved' ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId 'al-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
        Assert-AL ([bool]$own.ok) '[F] ownership acquired' ([string]$own.reason)
        $gen = [long]$own.ownership['generation']
        $authOk = @{ explicit_allow = $true; goal_id = 'al-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner' }
        $ph = Get-NativeDispatchHash32 'loop-prompt-material'

        $slot0 = Get-OrchestrationGoal -GoalId 'al-goal-1' -StoreDir $goalDir
        $goal0 = $slot0.goal
        $spec0 = @{
            task_id = 'al-task-1'; task_expected_revision = 1; agent = 'coder';
            prompt_hash = $ph; scope = @('src/a.ps1');
            acceptance_criteria = @('criterion:0');
            owner = 'planner-1'; ownership_generation = $gen; base_revision = 'rev-a'
        }

        # ---------- step CONTINUE produces intent when Executor absent ----------
        $s1 = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $spec0 -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -ReceiptDir $receiptDir
        Assert-AL (([string]$s1.action -ceq 'dispatch_intent')) '[C1] CONTINUE yields dispatch_intent for Planner' ([string]$s1.action)
        Assert-AL (($null -ne $s1.dispatch_intent)) '[C1] intent present for subagent execution' ''
        Assert-AL (([string]$s1.dispatch_intent.task_id -ceq 'al-task-1')) '[C1] intent binds the right task' ([string]$s1.dispatch_intent.task_id)
        Assert-AL ([bool]$s1.checkpoint_ok) '[C1] step persists checkpoint' ([string]$s1.checkpoint_id)

        # ---------- step with stub Executor dispatches ----------
        $state = @{ calls = 0 }
        $stub = { param($i) $state.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $s2 = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Executor $stub -Authorization $authOk -DispatchSpec $spec0 -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -ReceiptDir $receiptDir
        Assert-AL (([string]$s2.action -ceq 'dispatched')) '[C2] stub Executor dispatches' ([string]$s2.action)
        Assert-AL (([int]$state.calls -eq 1)) '[C2] executor called exactly once' ([string]$state.calls)

        # ---------- TASK_DONE != OBJECTIVE_DONE ----------
        $live1 = (Get-OrchestrationGoal -GoalId 'al-goal-1' -StoreDir $goalDir).goal
        Assert-AL (([string]$live1['state'] -cne 'COMPLETED')) '[O1] worker candidate_pass never completes the goal' ([string]$live1['state'])
        $gate1 = Test-ObjectiveCompletionAllowed -Goal $live1
        Assert-AL ((-not [bool]$gate1.allowed)) '[O1] completion gate closed while criteria unverified' ([string]$gate1.reason)
        $s3 = Invoke-OrchestrationObjectiveStep -Goal $live1 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $spec0 -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -ReceiptDir $receiptDir
        Assert-AL (([string]$s3.action -ceq 'dispatch_intent')) '[O1] next step still continues, never auto-completes' ([string]$s3.action)

        # ---------- Gate C: multiphase stub avanca fase1->fase2 sem intervencao ----------
        $g2 = New-OrchestrationGoal -GoalId 'al-goal-2' -Objective 'multifase' -Criteria @('fa', 'fb') -TotalPhases 2 -StoreDir $goalDir
        $a2 = Set-OrchestrationGoalState -Goal $g2.goal -ToState 'ACTIVE'
        $s2v = Save-OrchestrationGoal -Goal $a2.goal -StoreDir $goalDir
        $o2 = Acquire-OrchestrationGoalOwnership -GoalId 'al-goal-2' -OwnerId 'planner-1' -ExpectedRevision ([long]$s2v.revision) -StoreDir $goalDir
        $gen2 = [long]$o2.ownership['generation']
        $auth2 = @{ explicit_allow = $true; goal_id = 'al-goal-2'; owner = 'planner-1'; generation = $gen2; source = 'planner' }
        $multi = @{ calls = 0 }
        # GetNewClosure shares LOCAL references (hashtable) and copies
        # locals by value; $script: refs would NOT cross the closure
        # boundary, so every stub input is a plain local here.
        $advGoalDir = $goalDir
        $advGen = $gen2
        $advancer = {
            param($intent)
            $multi.calls++
            $slot = Get-OrchestrationGoal -GoalId 'al-goal-2' -StoreDir $advGoalDir
            $gv = $slot.goal
            $sat = [long]$gv['progress']['satisfied'] + 1
            $ph2 = [long]$gv['plan_progress']['phase'] + 1
            $upd = Update-OrchestrationGoal -GoalId 'al-goal-2' -ExpectedRevision ([long]$gv['revision']) -Fields @{ progress = @{ satisfied = $sat; total = 2 }; plan_progress = @{ phase = $ph2; total_phases = 2; done_tasks = $ph2 } } -StoreDir $advGoalDir -OwnerId 'planner-1' -OwnershipGeneration $advGen
            return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }
        }.GetNewClosure()
        $specPh = $ph
        $specGen = $gen2
        $specScript = {
            param($taken, $gv)
            $n = [int]$taken + 1
            return @{
                task_id = ('al-task-m' + [string]$n); task_expected_revision = 1; agent = 'coder';
                prompt_hash = $specPh; scope = @('src/a.ps1');
                acceptance_criteria = @('criterion:0');
                owner = 'planner-1'; ownership_generation = $specGen; base_revision = 'rev-a'
            }
        }.GetNewClosure()
        $loop = Invoke-OrchestrationAutonomousObjective -GoalId 'al-goal-2' -GoalStoreDir $goalDir -MaxSteps 2 -MaxDispatches 5 -CheckpointDir $ckptDir -Executor $advancer -Authorization $auth2 -DispatchSpec $specScript -EvidenceStoreDir $evDir -ReceiptDir $receiptDir
        Assert-AL (([int]$loop.dispatches -eq 2)) '[C3] two phases dispatched without intervention' ('dispatches=' + [string]$loop.dispatches)
        Assert-AL (([int]$multi.calls -eq 2)) '[C3] stub ran twice' ('calls=' + [string]$multi.calls)
        $final2 = (Get-OrchestrationGoal -GoalId 'al-goal-2' -StoreDir $goalDir).goal
        Assert-AL (([long]$final2['plan_progress']['phase'] -eq 2)) '[C3] plan advanced fase1->fase2' ('phase=' + [string]$final2['plan_progress']['phase'])
        Assert-AL (([string]$final2['state'] -cne 'COMPLETED')) '[C3] loop never self-completes the goal' ([string]$final2['state'])
        Assert-AL ((@($loop.checkpoints).Count -ge 2)) '[C3] every step checkpointed' ('checkpoints=' + [string](@($loop.checkpoints).Count))

        # ---------- resume does not duplicate effects ----------
        $r2 = Invoke-OrchestrationAutonomousObjective -GoalId 'al-goal-2' -GoalStoreDir $goalDir -MaxSteps 2 -MaxDispatches 5 -CheckpointDir $ckptDir -Executor $advancer -Authorization $auth2 -DispatchSpec $specScript -EvidenceStoreDir $evDir -ReceiptDir $receiptDir
        Assert-AL (([int]$multi.calls -eq 2)) '[R1] resume dispatches nothing new (receipts idempotent)' ('calls=' + [string]$multi.calls)

        # ---------- stale reuse never becomes DONE (and hits never verify) ----------
        $fpHit = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentBaseRevision 'rev-a' -StoreDir $evDir -ReuseClass 'content-fingerprint'
        Assert-AL (([bool]$fpHit.reused -and ([string]$fpHit.decision -ceq 'reuse-candidate'))) '[V1] matching evidence is a reuse candidate' ([string]$fpHit.decision)
        Assert-AL (((-not [bool]$fpHit.verified_pass) -and ([bool]$fpHit.planner_decides))) '[V1] even a hit never equals verification' ''
        $stillLive = (Get-OrchestrationGoal -GoalId 'al-goal-2' -StoreDir $goalDir).goal
        Assert-AL (([string]$stillLive['state'] -cne 'COMPLETED')) '[V1] reuse hit never completes the objective' ([string]$stillLive['state'])
        $fpStale = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentBaseRevision 'rev-changed' -StoreDir $evDir -ReuseClass 'content-fingerprint'
        Assert-AL (((-not [bool]$fpStale.reused) -and ([string]$fpStale.decision -ceq 'reexecute') -and (@($fpStale.reasons) -contains 'base-revision'))) '[V1] stale evidence reexecutes, never DONE' ((@($fpStale.reasons) -join ','))

        # ---------- hygiene ----------
        $alPath = Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1'
        $alText = [IO.File]::ReadAllText($alPath, [Text.UTF8Encoding]::new($false))
        Assert-AL ((($alText -notmatch 'Start-Process') -and ($alText -notmatch 'Invoke-WebRequest') -and ($alText -notmatch 'HttpClient') -and ($alText -notmatch 'while\s*\(\s*\$true'))) '[NET] no spawn/network/busy-loop' ''
        foreach ($p in @($alPath, (Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-AL ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
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
