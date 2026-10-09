<#!
.SYNOPSIS
    Integration test for the DispatchIntent symbol contract (R1/REV4).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn.

    Two libraries define a constructor called DispatchIntent:
      - OrchestrationObjectiveRuntime.ps1  (OLD contract:
        GoalId/WorkItemId/ActionRevision), consumed by its own runtime;
      - OrchestrationNativeDispatch.ps1  (NEW contract: TaskId/agent/
        scopes), consumed by the autonomous loop.
    A single name for both collides whenever a session loads both
    libraries. This suite dot-sources the pair in BOTH orders and proves
    that, in each order:
      - the OLD constructor still resolves and still builds the OLD
        contract, and the OLD consumer (ObjectiveRuntime store) still
        persists/reads it;
      - the NEW constructor resolves under its exclusive name and still
        builds the NEW contract, and the NEW consumer (autonomous loop
        step) still emits it for the Planner.
    No HOLD is removed and no flag is activated: this is a naming and
    regression contract only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0

function Assert-SX {
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

$script:LibDir = $PSScriptRoot
$script:RuntimeLib = Join-Path $script:LibDir 'OrchestrationObjectiveRuntime.ps1'
$script:NativeLib = Join-Path $script:LibDir 'OrchestrationNativeDispatch.ps1'
$script:LoopLib = Join-Path $script:LibDir 'OrchestrationAutonomousLoop.ps1'

function Invoke-SXOrder {
    <#
    Runs the whole contract under ONE dot-source order. Executed twice
    (old-first and new-first) so a redefinition in either direction is
    caught. Runs in a child scope: the two orders must not interfere.
    #>
    param([string]$Order)
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-dispatchintent-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $goalDir = Join-Path $tempRoot 'goals'
        $ckptDir = Join-Path $tempRoot 'checkpoints'
        $orStore = Join-Path $tempRoot 'or-dispatch-store'
        $evalDir = Join-Path $tempRoot 'evidence'
        $receiptDir = Join-Path $tempRoot 'receipts'
        $tasksDir = Join-Path $tempRoot 'tasks'
        $flagsPath = Join-Path $tempRoot 'flags.json'
        foreach ($d in @($goalDir, $ckptDir, $orStore, $evalDir, $receiptDir, $tasksDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

        # ---------- load order under test ----------
        if ($Order -ceq 'old-first') {
            . $script:RuntimeLib
            . $script:NativeLib
            . $script:LoopLib
        }
        else {
            . $script:NativeLib
            . $script:LoopLib
            . $script:RuntimeLib
        }

        # ---------- both constructors exist, with distinct names ----------
        $oldCmd = Get-Command New-OrchestrationDispatchIntent -ErrorAction SilentlyContinue
        $newCmd = Get-Command New-OrchestrationNativeDispatchIntent -ErrorAction SilentlyContinue
        Assert-SX (($null -ne $oldCmd) -and ($null -ne $newCmd)) ('[' + $Order + '][R1] both constructors resolve without collision') ('old=' + $(if ($null -eq $oldCmd) { 'missing' } else { 'ok' }) + ' new=' + $(if ($null -eq $newCmd) { 'missing' } else { 'ok' }))
        Assert-SX (($null -ne $oldCmd) -and ($oldCmd.Parameters.ContainsKey('GoalId')) -and ($oldCmd.Parameters.ContainsKey('WorkItemId')) -and ($oldCmd.Parameters.ContainsKey('ActionRevision')) -and (-not $oldCmd.Parameters.ContainsKey('TaskId'))) ('[' + $Order + '][R1] old name keeps the OLD runtime parameter contract') ''
        Assert-SX (($null -ne $newCmd) -and ($newCmd.Parameters.ContainsKey('TaskId')) -and ($newCmd.Parameters.ContainsKey('Agent')) -and ($newCmd.Parameters.ContainsKey('Scope')) -and (-not $newCmd.Parameters.ContainsKey('WorkItemId'))) ('[' + $Order + '][R1] new exclusive name keeps the NEW parameter contract') ''
        # structural guard: neither library defines the other constructor name
        $runtimeText = [IO.File]::ReadAllText($script:RuntimeLib, [Text.UTF8Encoding]::new($false))
        $nativeText = [IO.File]::ReadAllText($script:NativeLib, [Text.UTF8Encoding]::new($false))
        Assert-SX (($runtimeText -notmatch 'function\s+New-OrchestrationNativeDispatchIntent') -and ($nativeText -notmatch 'function\s+New-OrchestrationDispatchIntent')) ('[' + $Order + '][R1] neither library defines the other constructor name') ''

        # ---------- OLD contract still builds under its own name ----------
        $oldSlot = New-OrchestrationDispatchIntent -GoalId 'sx-goal-1' -WorkItemId 'sx-work-1' -ActionRevision 1
        Assert-SX ([bool]$oldSlot.ok) ('[' + $Order + '][R1] old constructor still builds') ([string]$oldSlot.reason)
        $oldIntent = $oldSlot.intent
        Assert-SX (($null -ne $oldIntent) -and ([string]$oldIntent.goal_id -ceq 'sx-goal-1') -and ([string]$oldIntent.work_item_id -ceq 'sx-work-1') -and ([long]$oldIntent.action_revision -eq 1) -and ([string]$oldIntent.state -ceq 'intended')) ('[' + $Order + '][R1] old contract shape preserved (goal/workitem/revision)') ''
        Assert-SX (($null -eq $oldIntent.PSObject.Properties['task_id']) -and ($null -eq $oldIntent.PSObject.Properties['agent'])) ('[' + $Order + '][R1] old contract carries no NEW-contract fields') ''

        # ---------- OLD consumer (ObjectiveRuntime store) still works ----------
        $oldSave = Save-OrchestrationDispatchIntent -Intent $oldIntent -StoreDir $orStore
        Assert-SX ([bool]$oldSave.ok) ('[' + $Order + '][R1] old consumer persists the old contract') ([string]$oldSave.reason)
        $oldRead = Get-OrchestrationDispatchIntent -GoalId 'sx-goal-1' -WorkItemId 'sx-work-1' -ActionRevision 1 -StoreDir $orStore
        Assert-SX (([bool]$oldRead.ok) -and ([string]$oldRead.intent.key -ceq [string]$oldIntent.key)) ('[' + $Order + '][R1] old consumer reads back what it persisted') ([string]$oldRead.reason)
        $oldDup = Save-OrchestrationDispatchIntent -Intent $oldIntent -StoreDir $orStore
        Assert-SX ([bool]$oldDup.duplicate) ('[' + $Order + '][R1] old consumer keeps idempotent duplicate semantics') ([string]$oldDup.reason)

        # ---------- NEW contract builds under the exclusive name ----------
        $ph = Get-NativeDispatchHash32 'symbol-contract-prompt-material'
        $g = New-OrchestrationGoal -GoalId 'sx-goal-loop' -Objective 'contrato de simbolo' -Criteria @('criterio-a', 'criterio-b') -TotalPhases 2 -StoreDir $goalDir
        Assert-SX ([bool]$g.ok) ('[' + $Order + '][F] goal created') ([string]$g.reason)
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        Assert-SX ([bool]$sv.ok) ('[' + $Order + '][F] goal active+saved') ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId 'sx-goal-loop' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
        Assert-SX ([bool]$own.ok) ('[' + $Order + '][F] ownership acquired') ([string]$own.reason)
        $gen = [long]$own.ownership['generation']
        $auth = @{ explicit_allow = $true; goal_id = 'sx-goal-loop'; owner = 'planner-1'; generation = $gen; source = 'planner' }

        $newSlot = New-OrchestrationNativeDispatchIntent -TaskId 'sx-task-1' -TaskExpectedRevision 1 -Agent 'coder' `
            -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') `
            -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-SX ([bool]$newSlot.ok) ('[' + $Order + '][R1] new constructor builds under the exclusive name') ([string]$newSlot.reason)
        $newIntent = $newSlot.intent
        Assert-SX (($null -ne $newIntent) -and ([string]$newIntent.task_id -ceq 'sx-task-1') -and ([string]$newIntent.agent -ceq 'coder') -and ([string]$newIntent.idempotency_key -cmatch '^[a-f0-9]{32}$')) ('[' + $Order + '][R1] new contract shape preserved (task/agent/key)') ''
        Assert-SX (($null -eq $newIntent.PSObject.Properties['work_item_id']) -and ($null -eq $newIntent.PSObject.Properties['action_revision'])) ('[' + $Order + '][R1] new contract carries no OLD-contract fields') ''
        Assert-SX (($null -eq $newIntent.PSObject.Properties['prompt'])) ('[' + $Order + '][R1] new contract still carries no raw prompt') ''

        # ---------- NEW consumer (autonomous loop step) still emits it ----------
        $spec = @{
            task_id = 'sx-task-1'; task_expected_revision = 1; agent = 'coder'
            prompt_hash = $ph; scope = @('src/a.ps1')
            acceptance_criteria = @('criterion:0')
            owner = 'planner-1'; ownership_generation = $gen; base_revision = 'rev-a'
        }
        $live = (Get-OrchestrationGoal -GoalId 'sx-goal-loop' -StoreDir $goalDir).goal
        $step = Invoke-OrchestrationObjectiveStep -Goal $live -CheckpointDir $ckptDir -Authorization $auth -DispatchSpec $spec `
            -GoalStoreDir $goalDir -EvidenceStoreDir $evalDir -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-SX (([string]$step.action -ceq 'dispatch_intent')) ('[' + $Order + '][R1] new consumer still yields dispatch_intent') ([string]$step.action + '/' + [string]$step.reason)
        $emitted = $step.dispatch_intent
        if ($null -eq $emitted) { $emitted = $step.intent }
        Assert-SX (($null -ne $emitted) -and ([string]$emitted.task_id -ceq 'sx-task-1') -and ([string]$emitted.agent -ceq 'coder')) ('[' + $Order + '][R1] emitted intent uses the NEW contract') ''
        Assert-SX (($null -ne $emitted) -and ($null -eq $emitted.PSObject.Properties['work_item_id'])) ('[' + $Order + '][R1] emitted intent is not the OLD contract') ''
        Assert-SX ([bool]$step.checkpoint_ok) ('[' + $Order + '][R1] step persists checkpoint while both libs are loaded') ([string]$step.checkpoint_id)

        # ---------- the two contracts stay distinguishable in one session ----------
        Assert-SX (([string]$oldIntent.key -cne [string]$newIntent.idempotency_key)) ('[' + $Order + '][R1] old and new keys are computed by their own contracts') ''
    }
    finally {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

try {
    Assert-SX ((Test-Path -LiteralPath $script:RuntimeLib -PathType Leaf) -and (Test-Path -LiteralPath $script:NativeLib -PathType Leaf) -and (Test-Path -LiteralPath $script:LoopLib -PathType Leaf)) '[F] both libraries present' ''
    Invoke-SXOrder -Order 'old-first'
    Invoke-SXOrder -Order 'new-first'
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
}

# ---------- hygiene ----------
try {
    $thisFile = Join-Path $script:LibDir 'OrchestrationDispatchIntentSymbol.tests.ps1'
    $bytes = [IO.File]::ReadAllBytes($thisFile)
    $bad = 0
    foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
    Assert-SX ($bad -eq 0) '[ASCII] OrchestrationDispatchIntentSymbol.tests.ps1' ([string]$bad)
    Assert-SX (($thisFile -notmatch 'Start-Process') -and ($thisFile -notmatch 'Invoke-WebRequest')) '[NET] no spawn/network in this suite' ''
}
catch { }

Write-Host ''
Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
if ($script:failed -ne 0) { exit 1 }
exit 0
