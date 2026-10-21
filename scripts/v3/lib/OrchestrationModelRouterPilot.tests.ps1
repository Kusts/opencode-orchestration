<#!
.SYNOPSIS
    F3 pilot envelope tests (issue #99, PLAN section 5).
.DESCRIPTION
    Dot-sourceable suite (no execution on load beyond the asserts below).
    Covers the opt-in F3-PILOT block in lib/OrchestrationAutonomousLoop.ps1,
    expanded by F4 to the full cheap matrix (SPEC section 5, PLAN section 6):
    OFF (absent or enabled:false) behaves exactly like baseline; ON applies
    ONLY for cheap-matrix pairs (coder/implementation+trivial, explorer/
    analysis+research, researcher/research, tester/testing+validation,
    docs-manager/documentation, database-engineer/migration+implementation,
    frontend/backend/ai/automation/infra-engineer implementation,
    requirements-analyst/engineering-advisor/skeptic+infra-engineer
    planning, product-designer/design) with a valid envelope
    (denied=false, fallback_used=false) and a matrix model ('cheap');
    every other case stays on baseline. Strong pool (reviewer, debugger,
    security-reviewer, architect) and infra_mutation (infra-engineer+
    migration) never route: silent baseline, no telemetry. The Intent
    contract is never extended (no 'model' field). Denied/fallback_used
    fixtures prove the exact gate signals the block consumes. Kill-switch
    confinement is checked statically: all pilot code lives between
    F3-PILOT-BEGIN/END except two marked no-op wrappers.
    PS 5.1 compatible, ASCII-only, no network, no spawn, no secrets.
    Hermetic: temp dirs, cleanup in finally, repo tree never written
    (registry is READ-ONLY here).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationReuseWiring.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationModelRouting.ps1')

$script:passed = 0
$script:failed = 0

function Assert-PL {
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

function Get-PLStepSpec {
    param([string]$TaskId, [string]$Agent, [string]$TaskClass, [string]$PromptHash, [long]$Gen)
    return @{
        task_id = $TaskId; task_expected_revision = 1; agent = $Agent;
        prompt_hash = $PromptHash; scope = @('src/a.ps1');
        acceptance_criteria = @('criterion:0');
        owner = 'planner-1'; ownership_generation = $Gen; base_revision = 'rev-a';
        task_class = $TaskClass
    }
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-modelpilot-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $goalDir = Join-Path $tempRoot 'goals'
    $ckptDir = Join-Path $tempRoot 'checkpoints'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $tasksDir = Join-Path $tempRoot 'tasks'
    $evOff = Join-Path $tempRoot 'ev-off'
    $evOn = Join-Path $tempRoot 'ev-on'
    $evOn2 = Join-Path $tempRoot 'ev-on2'
    foreach ($d in @($goalDir, $ckptDir, $receiptDir, $tasksDir, $evOff, $evOn, $evOn2)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $flagsOff = Join-Path $tempRoot 'flags-off.json'
    $flagsOffExplicit = Join-Path $tempRoot 'flags-off-explicit.json'
    $flagsOn = Join-Path $tempRoot 'flags-on.json'
    [IO.File]::WriteAllText($flagsOff, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($flagsOffExplicit, '{"task_kernel":{"enabled":true,"shadow":false},"model_router_pilot":{"enabled":false}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($flagsOn, '{"task_kernel":{"enabled":true,"shadow":false},"model_router_pilot":{"enabled":true}}', [Text.UTF8Encoding]::new($false))

    $g = New-OrchestrationGoal -GoalId 'pl-goal-1' -Objective 'pilot honesto' -Criteria @('criterio-a', 'criterio-b') -TotalPhases 2 -StoreDir $goalDir
    Assert-PL ([bool]$g.ok) '[F] goal created' ([string]$g.reason)
    $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
    $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
    Assert-PL ([bool]$sv.ok) '[F] goal active+saved' ([string]$sv.reason)
    $own = Acquire-OrchestrationGoalOwnership -GoalId 'pl-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
    Assert-PL ([bool]$own.ok) '[F] ownership acquired' ([string]$own.reason)
    $gen = [long]$own.ownership['generation']
    $authOk = @{ explicit_allow = $true; goal_id = 'pl-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner' }
    $ph = Get-NativeDispatchHash32 'pilot-prompt-material'

    $c = New-OrchestrationTask -TaskId 'pl-task-1' -Objective 'obj pl-task-1' -TaskType 'implementation' `
        -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
        -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
        -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsOff -TelemetryRoot $tempRoot
    Assert-PL ([bool]$c.ok) '[F] kernel task created' ([string]$c.error)
    $slot0 = Get-OrchestrationGoal -GoalId 'pl-goal-1' -StoreDir $goalDir
    $add = Add-OrchestrationGoalTaskPersisted -GoalId 'pl-goal-1' -TaskId 'pl-task-1' -ExpectedRevision ([long]$slot0.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
    Assert-PL ([bool]$add.ok) '[F] task attached' ([string]$add.reason)
    $slot1 = Get-OrchestrationGoal -GoalId 'pl-goal-1' -StoreDir $goalDir
    $goal0 = $slot1.goal

    function Get-PLIntentSig {
        param($Step)
        $i = $Step.dispatch_intent
        if ($null -eq $i) { return '' }
        return ([string]$i.task_id + '|' + [string]$i.agent + '|' + [string]$i.prompt_hash + '|' + (($i.scope) -join ',') + '|' + (($i.acceptance_criteria) -join ',') + '|' + [string]$i.idempotency_key)
    }

    # ---------- OFF: absent node behaves like baseline ----------
    $specTrivial = Get-PLStepSpec -TaskId 'pl-task-1' -Agent 'coder' -TaskClass 'trivial' -PromptHash $ph -Gen $gen
    $sOff = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specTrivial -GoalStoreDir $goalDir -EvidenceStoreDir $evOff -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOff
    Assert-PL (([string]$sOff.action -ceq 'dispatch_intent')) '[OFF-absent] action is dispatch_intent' ([string]$sOff.action)
    Assert-PL (($null -ne $sOff.dispatch_intent)) '[OFF-absent] intent present' ''
    Assert-PL (($sOff.dispatch_intent.PSObject.Properties.Name -notcontains 'model')) '[OFF-absent] intent has no model field' ''
    Assert-PL (($sOff.dispatch_intent.PSObject.Properties.Name -notcontains 'model_routing')) '[OFF-absent] intent has no model_routing field' ''
    Assert-PL (($sOff.PSObject.Properties.Name -notcontains 'model_routing')) '[OFF-absent] envelope has no model_routing note' ''
    Assert-PL ((-not (Test-Path -LiteralPath (Join-Path $evOff 'model-router-pilot.jsonl') -PathType Leaf))) '[OFF-absent] no pilot telemetry written' ''

    # ---------- OFF explicit (enabled:false) identical to absent ----------
    $sOffExp = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specTrivial -GoalStoreDir $goalDir -EvidenceStoreDir $evOff -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOffExplicit
    Assert-PL (([string]$sOffExp.action -ceq 'dispatch_intent')) '[OFF-explicit] action is dispatch_intent' ([string]$sOffExp.action)
    Assert-PL (($sOffExp.PSObject.Properties.Name -notcontains 'model_routing')) '[OFF-explicit] envelope has no model_routing note' ''
    Assert-PL (((Get-PLIntentSig $sOff) -ceq (Get-PLIntentSig $sOffExp))) '[OFF] absent node == enabled:false (identical intent)' ''

    # ---------- OFF ignores the new spec key entirely ----------
    $specNoClass = @{
        task_id = 'pl-task-1'; task_expected_revision = 1; agent = 'coder';
        prompt_hash = $ph; scope = @('src/a.ps1');
        acceptance_criteria = @('criterion:0');
        owner = 'planner-1'; ownership_generation = $gen; base_revision = 'rev-a'
    }
    $sOffPlain = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specNoClass -GoalStoreDir $goalDir -EvidenceStoreDir $evOff -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOff
    Assert-PL (((Get-PLIntentSig $sOff) -ceq (Get-PLIntentSig $sOffPlain))) '[OFF] task_class key changes nothing when pilot OFF' ''

    # ---------- ON + trivial/coder: applied ----------
    $sOn = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specTrivial -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (([string]$sOn.action -ceq 'dispatch_intent')) '[ON-trivial] action is dispatch_intent' ([string]$sOn.action)
    Assert-PL (((Get-PLIntentSig $sOn) -ceq (Get-PLIntentSig $sOff))) '[ON-trivial] intent bytes identical to baseline' ''
    Assert-PL (($sOn.dispatch_intent.PSObject.Properties.Name -notcontains 'model')) '[ON-trivial] intent still has no model field' ''
    Assert-PL (($sOn.PSObject.Properties.Name -contains 'model_routing')) '[ON-trivial] envelope carries model_routing note' ''
    Assert-PL (([bool]$sOn.model_routing.applied)) '[ON-trivial] applied is true' ''
    Assert-PL (([string]$sOn.model_routing.selected -ceq 'cheap')) '[ON-trivial] selected is cheap' ([string]$sOn.model_routing.selected)
    Assert-PL ((-not [bool]$sOn.model_routing.denied)) '[ON-trivial] not denied' ''
    Assert-PL ((-not [bool]$sOn.model_routing.fallback_used)) '[ON-trivial] not fallback' ''
    Assert-PL ((-not [bool]$sOn.model_routing.escalation_consumed)) '[ON-trivial] no escalation consumed' ''
    $logOn = Join-Path $evOn 'model-router-pilot.jsonl'
    Assert-PL ((Test-Path -LiteralPath $logOn -PathType Leaf)) '[ON-trivial] telemetry file written' ''
    $lines = @([IO.File]::ReadAllLines($logOn) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-PL (([int]$lines.Count -ge 1)) '[ON-trivial] telemetry has at least one line' ([string]$lines.Count)
    $entry = ($lines[0] | ConvertFrom-Json)
    Assert-PL (([string]$entry.goal_id -ceq 'pl-goal-1')) '[ON-trivial] telemetry goal_id sanitized id only' ([string]$entry.goal_id)
    Assert-PL (([string]$entry.task_class -ceq 'trivial')) '[ON-trivial] telemetry task_class' ([string]$entry.task_class)
    Assert-PL (([string]$entry.selected -ceq 'cheap')) '[ON-trivial] telemetry selected' ([string]$entry.selected)
    Assert-PL (([bool]$entry.applied)) '[ON-trivial] telemetry applied' ''
    Assert-PL ((-not [bool]$entry.escalation_consumed)) '[ON-trivial] telemetry no escalation' ''
    Assert-PL (([string]([IO.File]::ReadAllText($logOn)) -notmatch '"prompt_hash"|planner-1-secret|token')) '[ON-trivial] telemetry carries no secret material' ''

    # ---------- ON + research/explorer: applied ----------
    $specResearch = Get-PLStepSpec -TaskId 'pl-task-2' -Agent 'explorer' -TaskClass 'research' -PromptHash $ph -Gen $gen
    $sRes = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specResearch -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (([string]$sRes.action -ceq 'dispatch_intent')) '[ON-research] action is dispatch_intent' ([string]$sRes.action)
    Assert-PL (($sRes.PSObject.Properties.Name -contains 'model_routing')) '[ON-research] envelope carries model_routing note' ''
    Assert-PL (([bool]$sRes.model_routing.applied)) '[ON-research] applied is true' ''
    Assert-PL (([string]$sRes.model_routing.selected -ceq 'cheap')) '[ON-research] selected is cheap' ([string]$sRes.model_routing.selected)
    Assert-PL (($sRes.dispatch_intent.PSObject.Properties.Name -notcontains 'model')) '[ON-research] intent still has no model field' ''

    # ---------- ON + non-matrix class: baseline, silent ----------
    $specImplDenied = Get-PLStepSpec -TaskId 'pl-task-3' -Agent 'coder' -TaskClass 'review' -PromptHash $ph -Gen $gen
    $nBefore = 0
    if (Test-Path -LiteralPath $logOn -PathType Leaf) { $nBefore = ([int]@([IO.File]::ReadAllLines($logOn) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count) }
    $sImpl = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specImplDenied -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (([string]$sImpl.action -ceq 'dispatch_intent')) '[ON-review-class] action is dispatch_intent' ([string]$sImpl.action)
    Assert-PL (($sImpl.PSObject.Properties.Name -notcontains 'model_routing')) '[ON-review-class] no model_routing note (baseline)' ''
    $nAfter = ([int]@([IO.File]::ReadAllLines($logOn) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count)
    Assert-PL (([int]$nAfter -eq [int]$nBefore)) '[ON-review-class] no telemetry line for skipped class' ('' + $nBefore + '->' + $nAfter)

    # ---------- F4: expanded cheap matrix is eligible ----------
    $specF4Impl = Get-PLStepSpec -TaskId 'pl-task-5' -Agent 'coder' -TaskClass 'implementation' -PromptHash $ph -Gen $gen
    $sF4Impl = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Impl -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (([string]$sF4Impl.action -ceq 'dispatch_intent')) '[F4-impl] action is dispatch_intent' ([string]$sF4Impl.action)
    $sF4ImplOff = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Impl -GoalStoreDir $goalDir -EvidenceStoreDir $evOff -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOff
    Assert-PL (((Get-PLIntentSig $sF4Impl) -ceq (Get-PLIntentSig $sF4ImplOff))) '[F4-impl] intent bytes identical to baseline' ''
    Assert-PL (($sF4Impl.dispatch_intent.PSObject.Properties.Name -notcontains 'model')) '[F4-impl] intent still has no model field' ''
    Assert-PL (($sF4Impl.PSObject.Properties.Name -contains 'model_routing')) '[F4-impl] envelope carries model_routing note' ''
    Assert-PL (([bool]$sF4Impl.model_routing.applied)) '[F4-impl] applied is true' ''
    Assert-PL (([string]$sF4Impl.model_routing.selected -ceq 'cheap')) '[F4-impl] selected is cheap' ([string]$sF4Impl.model_routing.selected)

    $specF4Test = Get-PLStepSpec -TaskId 'pl-task-6' -Agent 'tester' -TaskClass 'testing' -PromptHash $ph -Gen $gen
    $sF4Test = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Test -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sF4Test.PSObject.Properties.Name -contains 'model_routing')) '[F4-testing] envelope carries note' ''
    Assert-PL (([bool]$sF4Test.model_routing.applied)) '[F4-testing] applied is true' ''
    Assert-PL (([string]$sF4Test.model_routing.selected -ceq 'cheap')) '[F4-testing] selected is cheap' ([string]$sF4Test.model_routing.selected)
    Assert-PL (($sF4Test.dispatch_intent.PSObject.Properties.Name -notcontains 'model')) '[F4-testing] intent still has no model field' ''

    $specF4Docs = Get-PLStepSpec -TaskId 'pl-task-7' -Agent 'docs-manager' -TaskClass 'documentation' -PromptHash $ph -Gen $gen
    $sF4Docs = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Docs -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sF4Docs.PSObject.Properties.Name -contains 'model_routing')) '[F4-docs] envelope carries note' ''
    Assert-PL (([bool]$sF4Docs.model_routing.applied)) '[F4-docs] applied is true' ''

    $specF4Plan = Get-PLStepSpec -TaskId 'pl-task-8' -Agent 'requirements-analyst' -TaskClass 'planning' -PromptHash $ph -Gen $gen
    $sF4Plan = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Plan -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sF4Plan.PSObject.Properties.Name -contains 'model_routing')) '[F4-planning] envelope carries note' ''
    Assert-PL (([bool]$sF4Plan.model_routing.applied)) '[F4-planning] applied is true' ''

    $specF4Design = Get-PLStepSpec -TaskId 'pl-task-9' -Agent 'product-designer' -TaskClass 'design' -PromptHash $ph -Gen $gen
    $sF4Design = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Design -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sF4Design.PSObject.Properties.Name -contains 'model_routing')) '[F4-design] envelope carries note' ''
    Assert-PL (([bool]$sF4Design.model_routing.applied)) '[F4-design] applied is true' ''

    $specF4Mig = Get-PLStepSpec -TaskId 'pl-task-10' -Agent 'database-engineer' -TaskClass 'migration' -PromptHash $ph -Gen $gen
    $sF4Mig = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Mig -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sF4Mig.PSObject.Properties.Name -contains 'model_routing')) '[F4-migration] envelope carries note' ''
    Assert-PL (([bool]$sF4Mig.model_routing.applied)) '[F4-migration] applied is true' ''

    $specF4Anal = Get-PLStepSpec -TaskId 'pl-task-11' -Agent 'explorer' -TaskClass 'analysis' -PromptHash $ph -Gen $gen
    $sF4Anal = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Anal -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sF4Anal.PSObject.Properties.Name -contains 'model_routing')) '[F4-analysis] envelope carries note' ''
    Assert-PL (([bool]$sF4Anal.model_routing.applied)) '[F4-analysis] applied is true' ''

    $specF4Front = Get-PLStepSpec -TaskId 'pl-task-12' -Agent 'frontend-engineer' -TaskClass 'implementation' -PromptHash $ph -Gen $gen
    $sF4Front = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Front -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sF4Front.PSObject.Properties.Name -contains 'model_routing')) '[F4-frontend] envelope carries note' ''
    Assert-PL (([bool]$sF4Front.model_routing.applied)) '[F4-frontend] applied is true' ''

    # ---------- F4 OFF: expanded class behaves like baseline when flag OFF ----------
    $sF4Off = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specF4Test -GoalStoreDir $goalDir -EvidenceStoreDir $evOff -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOff
    Assert-PL (($sF4Off.PSObject.Properties.Name -notcontains 'model_routing')) '[F4-OFF] expanded class has no note when flag OFF' ''

    # ---------- F4 prohibited: strong pool never routes ----------
    $specStrongDebug = Get-PLStepSpec -TaskId 'pl-task-13' -Agent 'debugger' -TaskClass 'debugging' -PromptHash $ph -Gen $gen
    $sStrongDebug = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specStrongDebug -GoalStoreDir $goalDir -EvidenceStoreDir $evOn2 -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (([string]$sStrongDebug.action -ceq 'dispatch_intent')) '[F4-debugger] action is dispatch_intent' ([string]$sStrongDebug.action)
    Assert-PL (($sStrongDebug.PSObject.Properties.Name -notcontains 'model_routing')) '[F4-debugger] strong pool never routed (baseline)' ''
    Assert-PL (($sStrongDebug.dispatch_intent.PSObject.Properties.Name -notcontains 'model')) '[F4-debugger] intent still has no model field' ''

    $specStrongArch = Get-PLStepSpec -TaskId 'pl-task-14' -Agent 'architect' -TaskClass 'planning' -PromptHash $ph -Gen $gen
    $sStrongArch = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specStrongArch -GoalStoreDir $goalDir -EvidenceStoreDir $evOn2 -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sStrongArch.PSObject.Properties.Name -notcontains 'model_routing')) '[F4-architect] strong pool never routed (baseline)' ''

    $specStrongSec = Get-PLStepSpec -TaskId 'pl-task-15' -Agent 'security-reviewer' -TaskClass 'review' -PromptHash $ph -Gen $gen
    $sStrongSec = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specStrongSec -GoalStoreDir $goalDir -EvidenceStoreDir $evOn2 -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sStrongSec.PSObject.Properties.Name -notcontains 'model_routing')) '[F4-security] strong pool never routed (baseline)' ''

    # ---------- F4 prohibited: infra_mutation never routes ----------
    $specInfraMut = Get-PLStepSpec -TaskId 'pl-task-16' -Agent 'infra-engineer' -TaskClass 'migration' -PromptHash $ph -Gen $gen
    $nMutBefore = ([int]@([IO.File]::ReadAllLines($logOn) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count)
    $sInfraMut = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specInfraMut -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (([string]$sInfraMut.action -ceq 'dispatch_intent')) '[F4-infra-mutation] action is dispatch_intent' ([string]$sInfraMut.action)
    Assert-PL (($sInfraMut.PSObject.Properties.Name -notcontains 'model_routing')) '[F4-infra-mutation] never routed (baseline)' ''
    $nMutAfter = ([int]@([IO.File]::ReadAllLines($logOn) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count)
    Assert-PL (([int]$nMutAfter -eq [int]$nMutBefore)) '[F4-infra-mutation] no telemetry line' ('' + $nMutBefore + '->' + $nMutAfter)

    # ---------- F4 prohibited: debugging class claimed by cheap agent stays baseline ----------
    $specCheapDebug = Get-PLStepSpec -TaskId 'pl-task-17' -Agent 'coder' -TaskClass 'debugging' -PromptHash $ph -Gen $gen
    $sCheapDebug = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specCheapDebug -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (($sCheapDebug.PSObject.Properties.Name -notcontains 'model_routing')) '[F4-cheap-debugging] non-matrix pair stays baseline' ''

    # ---------- ON + sensitive role: baseline, silent ----------
    $specSens = Get-PLStepSpec -TaskId 'pl-task-4' -Agent 'reviewer' -TaskClass 'trivial' -PromptHash $ph -Gen $gen
    $sSens = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Authorization $authOk -DispatchSpec $specSens -GoalStoreDir $goalDir -EvidenceStoreDir $evOn2 -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (([string]$sSens.action -ceq 'dispatch_intent')) '[ON-sensitive] action is dispatch_intent' ([string]$sSens.action)
    Assert-PL (($sSens.PSObject.Properties.Name -notcontains 'model_routing')) '[ON-sensitive] reviewer never routed (baseline)' ''
    Assert-PL (($sSens.dispatch_intent.PSObject.Properties.Name -notcontains 'model')) '[ON-sensitive] intent still has no model field' ''
    Assert-PL ((-not (Test-Path -LiteralPath (Join-Path $evOn2 'model-router-pilot.jsonl') -PathType Leaf))) '[ON-sensitive] no telemetry for skipped role' ''

    # ---------- ON + Executor path: dispatched with note, dispatch on baseline intent ----------
    $state = @{ calls = 0 }
    $stub = { param($i) $state.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $sExec = Invoke-OrchestrationObjectiveStep -Goal $goal0 -CheckpointDir $ckptDir -Executor $stub -Authorization $authOk -DispatchSpec $specTrivial -GoalStoreDir $goalDir -EvidenceStoreDir $evOn -ReceiptDir $receiptDir -TasksDir $tasksDir -FlagsPath $flagsOn
    Assert-PL (([string]$sExec.action -ceq 'dispatched')) '[ON-exec] stub Executor dispatches' ([string]$sExec.action)
    Assert-PL (([int]$state.calls -eq 1)) '[ON-exec] executor called exactly once' ([string]$state.calls)
    Assert-PL (($sExec.PSObject.Properties.Name -contains 'model_routing')) '[ON-exec] dispatched envelope carries note' ''
    Assert-PL (([bool]$sExec.model_routing.applied)) '[ON-exec] applied is true on dispatch path' ''
    Assert-PL (($sExec.dispatch_intent.PSObject.Properties.Name -notcontains 'model')) '[ON-exec] dispatched intent still has no model field' ''

    # ---------- envelope fixtures: the gate signals the pilot block consumes ----------
    $reqOk = New-ModelRoutingRequest -TaskId 'pl-gate-1' -Role 'coder' -TaskClass 'trivial' -Risk 'LOW' -Candidates @('cheap') -Fallback 'cheap'
    Assert-PL ([bool]$reqOk.is_valid) '[GATE] pilot request shape is valid' ''
    $propOk = New-ModelRoutingResult -Selected 'cheap' -Reason 'BASELINE_SUFFICIENT' -Confidence 0.9 -Fallback 'cheap' -PolicyRefs @('F3-PILOT') -EvidenceRefs @('NO_EVIDENCE_YET')
    $acc = Test-ModelRoutingEnvelope -Request $reqOk -Proposed $propOk -PlannerApproved $false -PaidAuthorized $false -QuotaExhausted $false -DeniedModels @()
    Assert-PL ((-not [bool]$acc.denied)) '[GATE] pilot proposal not denied' ''
    Assert-PL ((-not [bool]$acc.fallback_used)) '[GATE] pilot proposal not fallback' ''
    $propEsc = New-ModelRoutingResult -Selected 'cheap' -Reason 'ESCALATE_COMPLEXITY' -Confidence 0.9 -Fallback 'cheap' -PolicyRefs @('F3-PILOT') -EvidenceRefs @('NO_EVIDENCE_YET') -EscalationConsumed $true
    $den = Test-ModelRoutingEnvelope -Request $reqOk -Proposed $propEsc -PlannerApproved $false -PaidAuthorized $false -QuotaExhausted $true -DeniedModels @()
    Assert-PL ([bool]$den.denied) '[GATE] quota-exhausted escalation is denied' ''
    $gateDenied = ((-not [bool]$den.denied) -and (-not [bool]$den.fallback_used))
    Assert-PL ((-not [bool]$gateDenied)) '[GATE] denied envelope never applies (baseline)' ''
    $propEmpty = New-ModelRoutingResult -Selected '' -Reason 'FALLBACK_DETERMINISTIC' -Confidence 0.9 -Fallback 'cheap' -PolicyRefs @('F3-PILOT') -EvidenceRefs @('NO_EVIDENCE_YET')
    $fb = Test-ModelRoutingEnvelope -Request $reqOk -Proposed $propEmpty -PlannerApproved $false -PaidAuthorized $false -QuotaExhausted $false -DeniedModels @()
    Assert-PL ([bool]$fb.fallback_used) '[GATE] empty selection falls back' ''
    $gateFb = ((-not [bool]$fb.denied) -and (-not [bool]$fb.fallback_used))
    Assert-PL ((-not [bool]$gateFb)) '[GATE] fallback envelope never applies (baseline)' ''

    # ---------- kill switch: pilot code confined between markers ----------
    $alPath = Join-Path $PSScriptRoot 'OrchestrationAutonomousLoop.ps1'
    $alLines = @([IO.File]::ReadAllLines($alPath))
    $beginIdx = -1; $endIdx = -1
    for ($li = 0; $li -lt $alLines.Count; $li++) {
        if ($alLines[$li] -match 'F3-PILOT-BEGIN') { $beginIdx = $li }
        if ($alLines[$li] -match 'F3-PILOT-END') { $endIdx = $li }
    }
    Assert-PL (([int]$beginIdx -ge 0)) '[KILL] F3-PILOT-BEGIN marker present' ''
    Assert-PL (([int]$endIdx -gt [int]$beginIdx)) '[KILL] F3-PILOT-END after BEGIN' ''
    $beginCount = ([int]@($alLines | Where-Object { $_ -match 'F3-PILOT-BEGIN' }).Count)
    $endCount = ([int]@($alLines | Where-Object { $_ -match 'F3-PILOT-END' }).Count)
    Assert-PL (([int]$beginCount -eq 1)) '[KILL] single BEGIN marker' ([string]$beginCount)
    Assert-PL (([int]$endCount -eq 1)) '[KILL] single END marker' ([string]$endCount)
    $outside = New-Object System.Collections.Generic.List[string]
    for ($li = 0; $li -lt $alLines.Count; $li++) {
        if (($li -ge $beginIdx) -and ($li -le $endIdx)) { continue }
        if ($alLines[$li] -match '(?i)pilot') { $outside.Add(('L' + ($li + 1) + ':' + $alLines[$li].Trim())) | Out-Null }
    }
    $outsideOk = $true
    foreach ($o in $outside) {
        if ($o -notmatch 'F3-PILOT') { $outsideOk = $false }
        if ($o -notmatch '\$__pilotRouting') { $outsideOk = $false }
    }
    Assert-PL ([bool]$outsideOk) '[KILL] outside block only marked no-op wrappers' ([string]($outside -join ' | '))
    Assert-PL (([int]$outside.Count -eq 2)) '[KILL] exactly two wrapper lines' ([string]$outside.Count)
    Assert-PL (([IO.File]::ReadAllText($alPath) -notmatch 'New-OrchestrationNativeDispatchIntent[^;]*-Model\b')) '[KILL] Intent call site gains no model param' ''

    # ---------- registry: pilot ACTIVATED by explicit human gate (issue #99) ----------
    # Activation authorized 2026-10-21: pilot ON with same-tier effect only.
    # Kill switch = set enabled:false (or remove the F3-PILOT block).
    $regPath = Join-Path $PSScriptRoot '..\..\..\source\registry\capability-flags.json'
    $regPath = [IO.Path]::GetFullPath($regPath)
    Assert-PL ((Test-Path -LiteralPath $regPath -PathType Leaf)) '[REG] capability-flags.json found' ($regPath)
    $reg = ([IO.File]::ReadAllText($regPath) | ConvertFrom-Json)
    Assert-PL ((($null -ne $reg.model_router_pilot) -and ($reg.model_router_pilot.enabled -is [bool]) -and ([bool]$reg.model_router_pilot.enabled))) '[REG] model_router_pilot.enabled is true (activated)' ''

    # ---------- hygiene: ASCII only ----------
    foreach ($p in @($alPath, (Join-Path $PSScriptRoot 'OrchestrationModelRouterPilot.tests.ps1'), $regPath)) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bad = 0
        foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
        Assert-PL ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
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
