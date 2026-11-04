<#!
.SYNOPSIS
    Tests for lib/OrchestrationPlannerWait.ps1 (PR181 Fatia A).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for tasks/goals/waits stores,
    cleanup in finally; the repo tree is never written. Offline only (no
    network, no gh, no spawn, no daemon). Covers the single Fatia A
    entrypoint Invoke-OrchestrationPlannerWaitBinding: Planner root-session
    binding via Phase 32 CAS (Invoke-OrchestrationTaskSessionBinding) then
    Register-OrchestrationGitHubWait, with active-Run adoption, first-binding
    path, explicit conflicts, idempotent replay validation and
    binding-without-wait recovery.
    Custom PS 5.1 / PS7 suite, no Pester. ASCII only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGitHubResume.ps1')

function Assert-PW {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if (-not $Condition) { throw ("FAIL: " + $Name + " :: " + $Detail) }
    $script:passed++
}
$script:passed = 0

$libPath = Join-Path $PSScriptRoot 'OrchestrationPlannerWait.ps1'
Assert-PW (Test-Path -LiteralPath $libPath -PathType Leaf) 'lib file exists'
. $libPath

$libText = [IO.File]::ReadAllText($libPath, [Text.Encoding]::UTF8)
foreach ($bad in @('Start-Sleep', 'System.Timers', 'Register-ObjectEvent', 'Register-Scheduled', 'Start-Job', 'New-Service', 'Start-Service', 'FileSystemWatcher', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Start-Process', 'while\s*\(', 'for\s*\(', 'gh pr merge', 'gh pr create', 'gh pr comment', 'gh pr edit', 'GH_TOKEN', 'GITHUB_TOKEN', 'C:\\Users', 'grants_authority = \$true', 'done_approved = \$true', 'kernel_mutated = \$true')) {
    Assert-PW ($libText -cnotmatch $bad) ('lib has no daemon/mutation/secret pattern: ' + $bad)
}
Assert-PW ($null -ne (Get-Command Invoke-OrchestrationPlannerWaitBinding -ErrorAction SilentlyContinue)) 'dot-source exposes Invoke-OrchestrationPlannerWaitBinding'
Assert-PW ($null -ne (Get-Command Get-OrchestrationPlannerWaitVersion -ErrorAction SilentlyContinue)) 'dot-source exposes Get-OrchestrationPlannerWaitVersion'
$v = Get-OrchestrationPlannerWaitVersion
Assert-PW (([long]$v.schema_version -eq 1) -and ([string]$v.phase -ceq 'PR181-A')) 'version schema 1 phase PR181-A'

$SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$SHA_C = 'cccccccccccccccccccccccccccccccccccccccc'
$SHA_D = 'dddddddddddddddddddddddddddddddddddddddd'
$SHA_E = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
$SHA_F = 'ffffffffffffffffffffffffffffffffffffffff'
$REPO = 'acme/widgets'
$FUTURE = '2026-10-11T00:00:00Z'
$PolicyPath = Join-Path $PSScriptRoot '..\..\..\source\registry\delivery-policy.json'
$policy = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($PolicyPath)))

function New-PWTask {
    param([string]$Id, [string]$TasksDir, [string]$FlagsPath, [string]$Repo)
    return (New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' -Risk 'low' `
        -Actor 'planner' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
        -AcceptanceCriteria @('criterion:0') -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $Repo)
}
function New-PWGoal {
    param([string]$Id, [string]$StoreDir, [string]$Owner = 'planner-1')
    $g = New-OrchestrationGoal -GoalId $Id -Objective ('goal ' + $Id) -Criteria @('a') -StoreDir $StoreDir
    if (-not [bool]$g.ok) { throw ("FAIL: goal create " + $Id + " :: " + [string]$g.reason) }
    $null = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE').goal -StoreDir $StoreDir
    $slot = Get-OrchestrationGoal -GoalId $Id -StoreDir $StoreDir
    $own = Acquire-OrchestrationGoalOwnership -GoalId $Id -OwnerId $Owner -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $StoreDir -LeaseTtlMs 60000
    if (-not [bool]$own.ok) { throw ("FAIL: goal acquire " + $Id + " :: " + [string]$own.reason) }
    return [long]$own.ownership['generation']
}
function Add-PWTaskToGoal {
    param([string]$GoalId, [string]$TaskId, [string]$StoreDir, [string]$Owner = 'planner-1', [long]$Generation = 1)
    $cur = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $StoreDir).goal['revision']
    $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $TaskId -ExpectedRevision $cur -StoreDir $StoreDir -OwnerId $Owner -OwnershipGeneration $Generation
    if (-not [bool]$add.ok) { throw ("FAIL: goal attach " + $TaskId + " :: " + [string]$add.reason) }
}
function Invoke-PWBind {
    param([string]$TaskId, [string]$GoalId, [string]$RunId, [string]$SessionId, [string]$TasksDir, [string]$FlagsPath, [string]$GoalDir, [string]$WaitsDir,
        [string]$Head = $script:SHA_A, [long]$Generation = 1, [string]$Owner = 'planner-1', [long]$OwnershipGeneration = 1, [int]$ExpectedRevision = -1)
    return (Invoke-OrchestrationPlannerWaitBinding -TaskId $TaskId -GoalId $GoalId -RunId $RunId -SessionId $SessionId `
        -OwnerId $Owner -OwnershipGeneration $OwnershipGeneration -GoalStoreDir $GoalDir -TasksDir $TasksDir -WaitsDir $WaitsDir `
        -Repository $script:REPO -PrNumber 42 -Branch 'fix/pw' -ExpectedHeadSha $Head -RequiredChecks @($script:policy.required_checks) `
        -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:FUTURE -RetryBudgetMax 5 `
        -ExpectedRevision $ExpectedRevision -FlagsPath $FlagsPath)
}

$v3dir = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $v3dir)
$root = Join-Path ([IO.Path]::GetTempPath()) ('v3-pw-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $tasksDir = Join-Path $root 'tasks'
    $goalDir = Join-Path $root 'goals'
    $waitsDir = Join-Path $root 'waits'
    $flagsPath = Join-Path $root 'flags.json'
    foreach ($d in @($tasksDir, $goalDir, $waitsDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', (New-Object Text.UTF8Encoding $false))

    # --- valid Planner root first binding + wait registration.
    $t = New-PWTask -Id 'pw-task-1' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t.ok) '[PW1] task created' ([string]$t.error)
    $gen1 = New-PWGoal -Id 'pw-goal-1' -StoreDir $goalDir
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-1' -StoreDir $goalDir -Generation $gen1
    $r1 = Invoke-PWBind -TaskId 'pw-task-1' -GoalId 'pw-goal-1' -RunId 'run-1' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ([bool]$r1.ok) '[PW1] first binding succeeds' ([string]$r1.reason)
    Assert-PW (([string]$r1.run_id -ceq 'run-1') -and ([string]$r1.binding -ceq 'bound')) '[PW1] run selected + bound' ([string]$r1.run_id)
    Assert-PW ((-not [bool]$r1.wait_reused) -and (Test-Path -LiteralPath ([string]$r1.wait_file) -PathType Leaf)) '[PW1] wait registered on disk' ([string]$r1.wait_file)
    Assert-PW ((-not [bool]$r1.grants_authority) -and (-not [bool]$r1.done_approved)) '[PW1] zero authority' ''
    $b1 = Get-OrchestrationTaskBindings -TaskId 'pw-task-1' -TasksDir $tasksDir
    Assert-PW (([string]@($b1.bindings['runs'])[0]['root_session'] -ceq 'ses-root-1') -and ([string]$b1.bindings['active_execution_owner'] -ceq 'ses-root-1')) '[PW1] root session canonical' ''

    # --- repeat: idempotent, no duplicates.
    $filesBefore = @(Get-ChildItem -LiteralPath $waitsDir -File -Filter 'ghwait-*.json').Count
    $revBefore = [long](Get-OrchestrationTask -TaskId 'pw-task-1' -TasksDir $tasksDir).revision
    $r1b = Invoke-PWBind -TaskId 'pw-task-1' -GoalId 'pw-goal-1' -RunId 'run-1' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW (([bool]$r1b.ok) -and ([bool]$r1b.wait_reused) -and ([string]$r1b.binding -ceq 'already-bound')) '[PW1] replay reuses' ([string]$r1b.reason)
    $filesAfter = @(Get-ChildItem -LiteralPath $waitsDir -File -Filter 'ghwait-*.json').Count
    Assert-PW ($filesAfter -eq $filesBefore) '[PW1] replay adds no wait file' ($filesBefore.ToString() + ' vs ' + $filesAfter.ToString())
    $revAfter = [long](Get-OrchestrationTask -TaskId 'pw-task-1' -TasksDir $tasksDir).revision
    Assert-PW ($revAfter -eq $revBefore) '[PW1] replay bumps no revision' ($revBefore.ToString() + ' vs ' + $revAfter.ToString())

    # --- active-Run adoption when RunId omitted and exactly one run bound.
    $t2 = New-PWTask -Id 'pw-task-2' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t2.ok) '[PW2] task created' ([string]$t2.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-2' -StoreDir $goalDir -Generation $gen1
    $pre = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'pw-task-2' -RunId 'run-adopt' -SessionId 'ses-root-2' -ExpectedRevision ([long](Get-OrchestrationTask -TaskId 'pw-task-2' -TasksDir $tasksDir).revision) -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-PW ([bool]$pre.ok) '[PW2] kernel pre-bind ok' ([string]$pre.error)
    $r2 = Invoke-PWBind -TaskId 'pw-task-2' -GoalId 'pw-goal-1' -RunId '' -SessionId 'ses-root-2' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1 -Head $SHA_B
    Assert-PW (([bool]$r2.ok) -and ([string]$r2.run_id -ceq 'run-adopt')) '[PW2] active Run adopted' ([string]$r2.run_id)

    # --- divergent run denied.
    $r3 = Invoke-PWBind -TaskId 'pw-task-1' -GoalId 'pw-goal-1' -RunId 'run-other' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r3.ok) -and ([string]$r3.reason -ceq 'run-divergent')) '[PW3] divergent run denied' ([string]$r3.reason)

    # --- session on another Task denied.
    $t4 = New-PWTask -Id 'pw-task-4' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t4.ok) '[PW4] task created' ([string]$t4.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-4' -StoreDir $goalDir -Generation $gen1
    $r4 = Invoke-PWBind -TaskId 'pw-task-4' -GoalId 'pw-goal-1' -RunId 'run-4' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r4.ok) -and ([string]$r4.reason -ceq 'session-bound-elsewhere')) '[PW4] session on another Task denied' ([string]$r4.reason)
    Assert-PW (([string](Get-OrchestrationTaskBindings -TaskId 'pw-task-4' -TasksDir $tasksDir).bindings['active_execution_owner'] -ceq '')) '[PW4] denied bind wrote nothing' ''

    # --- binding-without-wait is recoverable: bad sha binds, fixed sha reconciles.
    $t5 = New-PWTask -Id 'pw-task-5' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t5.ok) '[PW5] task created' ([string]$t5.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-5' -StoreDir $goalDir -Generation $gen1
    $bad5 = Invoke-OrchestrationPlannerWaitBinding -TaskId 'pw-task-5' -GoalId 'pw-goal-1' -RunId 'run-5' -SessionId 'ses-root-5' `
        -OwnerId 'planner-1' -OwnershipGeneration $gen1 -GoalStoreDir $goalDir -TasksDir $tasksDir -WaitsDir $waitsDir `
        -Repository $REPO -PrNumber 42 -Branch 'fix/pw' -ExpectedHeadSha 'zzz' -RequiredChecks @($policy.required_checks) `
        -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 `
        -FlagsPath $flagsPath
    Assert-PW ((-not [bool]$bad5.ok) -and ([string]$bad5.binding -ceq 'bound')) '[PW5] bad wait keeps binding' ([string]$bad5.reason)
    Assert-PW (([string]@((Get-OrchestrationTaskBindings -TaskId 'pw-task-5' -TasksDir $tasksDir).bindings['runs'])[0]['root_session'] -ceq 'ses-root-5')) '[PW5] root session persisted' ''
    $r5 = Invoke-PWBind -TaskId 'pw-task-5' -GoalId 'pw-goal-1' -RunId 'run-5' -SessionId 'ses-root-5' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1 -Head $SHA_C
    Assert-PW (([bool]$r5.ok) -and ([string]$r5.binding -ceq 'already-bound') -and (-not [bool]$r5.wait_reused)) '[PW5] retry reconciles wait' ([string]$r5.reason)
    Assert-PW ((@(Get-ChildItem -LiteralPath $waitsDir -File -Filter 'ghwait-*.json' | Where-Object { $_.FullName -cne [string]$r1.wait_file -and $_.FullName -cne [string]$r2.wait_file }).Count -eq 1)) '[PW5] exactly one new wait file' ''

    # --- wait replay with divergent Task/Run is an explicit conflict
    # (same repo/pr/head/generation dedup, different task).
    $t6 = New-PWTask -Id 'pw-task-6' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t6.ok) '[PW6] task created' ([string]$t6.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-6' -StoreDir $goalDir -Generation $gen1
    $r6 = Invoke-PWBind -TaskId 'pw-task-6' -GoalId 'pw-goal-1' -RunId 'run-6' -SessionId 'ses-root-6' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1 -Head $SHA_A
    Assert-PW ((-not [bool]$r6.ok) -and ([string]$r6.reason -ceq 'wait-divergent')) '[PW6] same dedup other task is wait-divergent' ([string]$r6.reason)
    Assert-PW (([string]$r6.binding -ceq 'bound')) '[PW6] divergent replay keeps its binding' ([string]$r6.binding)

    # --- negatives: unknown task/goal, ownership, terminal, stale revision.
    $n1 = Invoke-PWBind -TaskId 'pw-nope' -GoalId 'pw-goal-1' -RunId 'run-x' -SessionId 'ses-x' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$n1.ok) -and ([string]$n1.reason -ceq 'task-not-found')) '[PWN] unknown task' ([string]$n1.reason)
    $n2 = Invoke-PWBind -TaskId 'pw-task-1' -GoalId 'pw-goal-nope' -RunId 'run-1' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$n2.ok) -and ([string]$n2.reason -ceq 'goal-read-failed')) '[PWN] unknown goal' ([string]$n2.reason)
    $n3 = Invoke-PWBind -TaskId 'pw-task-1' -GoalId 'pw-goal-1' -RunId 'run-1' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration 99 -Owner 'planner-1'
    Assert-PW ((-not [bool]$n3.ok) -and ([string]$n3.reason -ceq 'ownership-not-held')) '[PWN] stale generation denied' ([string]$n3.reason)
    $n4 = Invoke-PWBind -TaskId 'pw-task-1' -GoalId 'pw-goal-1' -RunId 'run-1' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1 -Owner 'rival-1'
    Assert-PW ((-not [bool]$n4.ok) -and ([string]$n4.reason -ceq 'ownership-not-held')) '[PWN] rival owner denied' ([string]$n4.reason)
    $live6 = Get-OrchestrationTask -TaskId 'pw-task-1' -TasksDir $tasksDir
    $n5 = Invoke-PWBind -TaskId 'pw-task-1' -GoalId 'pw-goal-1' -RunId 'run-1' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1 -ExpectedRevision ([long]$live6.revision - 1)
    Assert-PW ((-not [bool]$n5.ok) -and ([string]$n5.reason -ceq 'cas-conflict')) '[PWN] stale revision CAS conflict' ([string]$n5.reason)
    $n6 = Invoke-PWBind -TaskId 'pw-task-1' -GoalId 'pw-goal-1' -RunId '' -SessionId 'ses-root-1' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ([bool]$n6.ok) '[PWN] same-session empty-RunId adopts' ([string]$n6.reason)

    # --- run selection edges: required / ambiguous / detached.
    $t7 = New-PWTask -Id 'pw-task-7' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t7.ok) '[PW7] task created' ([string]$t7.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-7' -StoreDir $goalDir -Generation $gen1
    $r7a = Invoke-PWBind -TaskId 'pw-task-7' -GoalId 'pw-goal-1' -RunId '' -SessionId 'ses-root-7' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r7a.ok) -and ([string]$r7a.reason -ceq 'run-required')) '[PW7] first binding needs explicit Run' ([string]$r7a.reason)
    $rev7 = [long](Get-OrchestrationTask -TaskId 'pw-task-7' -TasksDir $tasksDir).revision
    $k7a = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'pw-task-7' -RunId 'run-7a' -SessionId 'ses-7a' -ExpectedRevision $rev7 -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-PW ([bool]$k7a.ok) '[PW7] kernel run A bound' ([string]$k7a.error)
    $rev7b = [long](Get-OrchestrationTask -TaskId 'pw-task-7' -TasksDir $tasksDir).revision
    $rdetB = Detach-OrchestrationTaskSession -TaskId 'pw-task-7' -RunId 'run-7a' -SessionId 'ses-7a' -ExpectedRevision $rev7b -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-PW ([bool]$rdetB.ok) '[PW7] run A detached' ([string]$rdetB.error)
    $rev7c = [long](Get-OrchestrationTask -TaskId 'pw-task-7' -TasksDir $tasksDir).revision
    $k7b = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'pw-task-7' -RunId 'run-7b' -SessionId 'ses-7b' -ExpectedRevision $rev7c -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-PW ([bool]$k7b.ok) '[PW7] kernel run B bound' ([string]$k7b.error)
    $r7b = Invoke-PWBind -TaskId 'pw-task-7' -GoalId 'pw-goal-1' -RunId '' -SessionId 'ses-7b' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r7b.ok) -and ([string]$r7b.reason -ceq 'run-ambiguous')) '[PW7] two runs need explicit Run' ([string]$r7b.reason)
    $r7c = Invoke-PWBind -TaskId 'pw-task-7' -GoalId 'pw-goal-1' -RunId 'run-7a' -SessionId 'ses-7a' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r7c.ok) -and ([string]$r7c.reason -ceq 'run-detached')) '[PW7] detached run refused' ([string]$r7c.reason)

    # --- goal/task eligibility edges.
    $t8 = New-PWTask -Id 'pw-task-8' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t8.ok) '[PW8] task created' ([string]$t8.error)
    $r8a = Invoke-PWBind -TaskId 'pw-task-8' -GoalId 'pw-goal-1' -RunId 'run-8' -SessionId 'ses-root-8' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r8a.ok) -and ([string]$r8a.reason -ceq 'task-not-in-goal')) '[PW8] unattached task refused' ([string]$r8a.reason)
    $gDraft = New-OrchestrationGoal -GoalId 'pw-goal-draft' -Objective 'draft goal' -Criteria @('a') -StoreDir $goalDir
    Assert-PW ([bool]$gDraft.ok) '[PW8] draft goal created' ([string]$gDraft.reason)
    $null = Save-OrchestrationGoal -Goal $gDraft.goal -StoreDir $goalDir
    $r8b = Invoke-PWBind -TaskId 'pw-task-8' -GoalId 'pw-goal-draft' -RunId 'run-8' -SessionId 'ses-root-8' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation 0 -OwnershipGeneration 0 -Owner 'anyone'
    Assert-PW ((-not [bool]$r8b.ok) -and (([string]$r8b.reason -ceq 'goal-not-active') -or ([string]$r8b.reason -ceq 'ownership-not-held'))) '[PW8] draft/unowned goal refused' ([string]$r8b.reason)
    $cx = Cancel-OrchestrationTask -TaskId 'pw-task-8' -Actor 'planner' -ExpectedRevision ([long](Get-OrchestrationTask -TaskId 'pw-task-8' -TasksDir $tasksDir).revision) -Reason 'pw probe' -TasksDir $tasksDir -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-PW ([bool]$cx.ok) '[PW8] task cancelled' ([string]$cx.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-8' -StoreDir $goalDir -Generation $gen1
    $r8c = Invoke-PWBind -TaskId 'pw-task-8' -GoalId 'pw-goal-1' -RunId 'run-8' -SessionId 'ses-root-8' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r8c.ok) -and ([string]$r8c.reason -ceq 'task-terminal')) '[PW8] terminal task refused' ([string]$r8c.reason)

    # --- PW9: cross-task scan is fail-closed (no silent skip, no missing-dir pass).
    $tasksBad = Join-Path $root 'tasks-bad'
    New-Item -ItemType Directory -Path $tasksBad -Force | Out-Null
    $t9 = New-PWTask -Id 'pw-task-9' -TasksDir $tasksBad -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t9.ok) '[PW9] bad-dir task created' ([string]$t9.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-9' -StoreDir $goalDir -Generation $gen1
    [IO.File]::WriteAllText((Join-Path $tasksBad 'zz-bad.json'), '{not json', (New-Object Text.UTF8Encoding $false))
    $r9a = Invoke-PWBind -TaskId 'pw-task-9' -GoalId 'pw-goal-1' -RunId 'run-9' -SessionId 'ses-root-9' -TasksDir $tasksBad -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r9a.ok) -and ([string]$r9a.reason -ceq 'session-scan-record-malformed')) '[PW9] malformed candidate denies' ([string]$r9a.reason)
    $big = New-Object byte[] (2 * 1024 * 1024)
    [IO.File]::WriteAllBytes((Join-Path $tasksBad 'zz-big.json'), $big)
    Remove-Item -LiteralPath (Join-Path $tasksBad 'zz-bad.json') -Force
    $r9b = Invoke-PWBind -TaskId 'pw-task-9' -GoalId 'pw-goal-1' -RunId 'run-9' -SessionId 'ses-root-9' -TasksDir $tasksBad -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r9b.ok) -and ([string]$r9b.reason -ceq 'session-scan-record-oversized')) '[PW9] oversized candidate denies' ([string]$r9b.reason)
    [IO.File]::WriteAllText((Join-Path $tasksBad 'zz-empty.json'), '', (New-Object Text.UTF8Encoding $false))
    Remove-Item -LiteralPath (Join-Path $tasksBad 'zz-big.json') -Force
    $r9c = Invoke-PWBind -TaskId 'pw-task-9' -GoalId 'pw-goal-1' -RunId 'run-9' -SessionId 'ses-root-9' -TasksDir $tasksBad -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1
    Assert-PW ((-not [bool]$r9c.ok) -and ([string]$r9c.reason -ceq 'session-scan-record-malformed')) '[PW9] empty candidate denies' ([string]$r9c.reason)
    $s9d = Test-PWSessionBoundElsewhere -TasksDir (Join-Path $root 'no-such-dir') -SkipTaskId 'x' -SessionId 'ses-x'
    Assert-PW (((-not [bool]$s9d.ok) -and ([string]$s9d.reason -ceq 'session-scan-dir-missing')) -or (([string]$s9d.reason -ceq 'session-scan-unreadable'))) '[PW9] missing scan dir denies' ([string]$s9d.reason)

    # --- PW10: replay compares every registration field (same dedup, divergent fields).
    foreach ($pair in @(@('pw-task-10a', 'run-10a'), @('pw-task-10b', 'run-10b'), @('pw-task-10c', 'run-10c'), @('pw-task-10d', 'run-10d'))) {
        $tt = New-PWTask -Id $pair[0] -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
        Assert-PW ([bool]$tt.ok) ('[PW10] task created ' + $pair[0]) ([string]$tt.error)
        Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId $pair[0] -StoreDir $goalDir -Generation $gen1
    }
    $r10a = Invoke-OrchestrationPlannerWaitBinding -TaskId 'pw-task-10a' -GoalId 'pw-goal-1' -RunId 'run-10a' -SessionId 'ses-10a' `
        -OwnerId 'planner-1' -OwnershipGeneration $gen1 -GoalStoreDir $goalDir -TasksDir $tasksDir -WaitsDir $waitsDir `
        -Repository $REPO -PrNumber 42 -Branch 'fix/pw' -ExpectedHeadSha $SHA_A -RequiredChecks @($policy.required_checks) `
        -ReviewExpectation 'APPROVED' -Cursor 'cursor-2' -DeadlineUtc $FUTURE -RetryBudgetMax 5 `
        -FlagsPath $flagsPath
    Assert-PW ((-not [bool]$r10a.ok) -and ([string]$r10a.reason -ceq 'wait-divergent')) '[PW10] cursor change diverges' ([string]$r10a.reason)
    $r10b = Invoke-OrchestrationPlannerWaitBinding -TaskId 'pw-task-10b' -GoalId 'pw-goal-1' -RunId 'run-10b' -SessionId 'ses-10b' `
        -OwnerId 'planner-1' -OwnershipGeneration $gen1 -GoalStoreDir $goalDir -TasksDir $tasksDir -WaitsDir $waitsDir `
        -Repository $REPO -PrNumber 42 -Branch 'fix/pw' -ExpectedHeadSha $SHA_A -RequiredChecks @($policy.required_checks) `
        -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc '2026-10-12T00:00:00Z' -RetryBudgetMax 5 `
        -FlagsPath $flagsPath
    Assert-PW ((-not [bool]$r10b.ok) -and ([string]$r10b.reason -ceq 'wait-divergent')) '[PW10] deadline change diverges' ([string]$r10b.reason)
    $r10c = Invoke-OrchestrationPlannerWaitBinding -TaskId 'pw-task-10c' -GoalId 'pw-goal-1' -RunId 'run-10c' -SessionId 'ses-10c' `
        -OwnerId 'planner-1' -OwnershipGeneration $gen1 -GoalStoreDir $goalDir -TasksDir $tasksDir -WaitsDir $waitsDir `
        -Repository $REPO -PrNumber 42 -Branch 'fix/pw' -ExpectedHeadSha $SHA_A -RequiredChecks @($policy.required_checks) `
        -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 3 `
        -FlagsPath $flagsPath
    Assert-PW ((-not [bool]$r10c.ok) -and ([string]$r10c.reason -ceq 'wait-divergent')) '[PW10] retry-budget change diverges' ([string]$r10c.reason)
    # Lease expiry is canonical (Goal ownership), never model-supplied: same
    # dedup on another task still diverges via task/run identity even with
    # the canonical lease. Lease-specific divergence is covered directly
    # against the canonical expiry below (PW10d-lease).
    $r10d = Invoke-OrchestrationPlannerWaitBinding -TaskId 'pw-task-10d' -GoalId 'pw-goal-1' -RunId 'run-10d' -SessionId 'ses-10d' `
        -OwnerId 'planner-1' -OwnershipGeneration $gen1 -GoalStoreDir $goalDir -TasksDir $tasksDir -WaitsDir $waitsDir `
        -Repository $REPO -PrNumber 42 -Branch 'fix/pw' -ExpectedHeadSha $SHA_A -RequiredChecks @($policy.required_checks) `
        -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 `
        -FlagsPath $flagsPath
    Assert-PW ((-not [bool]$r10d.ok) -and ([string]$r10d.reason -ceq 'wait-divergent')) '[PW10] same dedup other task diverges (lease canonical)' ([string]$r10d.reason)
    $canonOwn10 = Get-PWValue (Get-PWValue (Get-OrchestrationGoal -GoalId 'pw-goal-1' -StoreDir $goalDir).goal 'ownership' $null) 'expires_at' ''
    $stored10 = ConvertFrom-Json ([IO.File]::ReadAllText([string]$r1.wait_file, [Text.Encoding]::UTF8))
    $dk10 = Get-OrchestrationGitHubResumeDedupKey -Repository $REPO -PrNumber 42 -HeadSha $SHA_A -Generation $gen1
    $dk10s = ([string](Get-PWValue $dk10 'dedup_key' '')).Trim()
    $base10 = @{ Wait = $stored10; GoalId = 'pw-goal-1'; TaskId = 'pw-task-1'; RunId = 'run-1'; Generation = $gen1; Repository = $REPO; PrNumber = 42; Branch = 'fix/pw'; ExpectedHeadSha = $SHA_A; ReviewExpectation = 'APPROVED'; RequiredChecks = @($policy.required_checks); Owner = 'planner-1'; LeaseOwner = 'planner-1'; Cursor = ''; DeadlineUtc = $FUTURE; RetryBudgetMax = 5; LeaseExpiresUtc = [string]$canonOwn10; DedupKey = $dk10s }
    Assert-PW ([bool](Test-PWWaitReplayConsistent @base10)) '[PW10] canonical lease replays consistent' ''
    $bad10 = @{ Wait = $stored10; GoalId = 'pw-goal-1'; TaskId = 'pw-task-1'; RunId = 'run-1'; Generation = $gen1; Repository = $REPO; PrNumber = 42; Branch = 'fix/pw'; ExpectedHeadSha = $SHA_A; ReviewExpectation = 'APPROVED'; RequiredChecks = @($policy.required_checks); Owner = 'planner-1'; LeaseOwner = 'planner-1'; Cursor = ''; DeadlineUtc = $FUTURE; RetryBudgetMax = 5; LeaseExpiresUtc = '2099-01-01T00:00:00Z'; DedupKey = $dk10s }
    Assert-PW (-not [bool](Test-PWWaitReplayConsistent @bad10)) '[PW10] tampered lease-expiry diverges' ''

    # --- PW11: canonical binding verified after bind (re-read Task/Run/session).
    Assert-PW ($null -ne (Get-Command Test-PWBindingVerified -ErrorAction SilentlyContinue)) '[PW11] verifier exposed' ''
    Assert-PW ([bool](Test-PWBindingVerified -TaskId 'pw-task-1' -RunId 'run-1' -SessionId 'ses-root-1' -TasksDir $tasksDir -RepoRoot $repoRoot)) '[PW11] canonical binding verifies' ''
    Assert-PW (-not [bool](Test-PWBindingVerified -TaskId 'pw-task-1' -RunId 'run-1' -SessionId 'ses-nope' -TasksDir $tasksDir -RepoRoot $repoRoot)) '[PW11] wrong session does not verify' ''
    Assert-PW (-not [bool](Test-PWBindingVerified -TaskId 'pw-task-1' -RunId 'run-nope' -SessionId 'ses-root-1' -TasksDir $tasksDir -RepoRoot $repoRoot)) '[PW11] wrong run does not verify' ''

    # --- PW12: owner+generation derived from stored Goal record (no model auth inputs).
    $t12 = New-PWTask -Id 'pw-task-12' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t12.ok) '[PW12] task created' ([string]$t12.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-12' -StoreDir $goalDir -Generation $gen1
    $r12 = Invoke-OrchestrationPlannerWaitBinding -TaskId 'pw-task-12' -GoalId 'pw-goal-1' -RunId 'run-12' -SessionId 'ses-root-12' `
        -GoalStoreDir $goalDir -TasksDir $tasksDir -WaitsDir $waitsDir `
        -Repository $REPO -PrNumber 42 -Branch 'fix/pw' -ExpectedHeadSha $SHA_D -RequiredChecks @($policy.required_checks) `
        -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 `
        -FlagsPath $flagsPath
    Assert-PW ([bool]$r12.ok) '[PW12] derived owner succeeds' ([string]$r12.reason)
    $w12 = ConvertFrom-Json ([IO.File]::ReadAllText([string]$r12.wait_file, [Text.Encoding]::UTF8))
    Assert-PW (([string](Get-PWValue $w12 'owner' '') -ceq 'planner-1') -and ([string](Get-PWValue $w12 'lease_owner' '') -ceq 'planner-1')) '[PW12] canonical owner as wait/lease owner' ''
    $own12 = Get-PWValue (Get-PWValue (Get-OrchestrationGoal -GoalId 'pw-goal-1' -StoreDir $goalDir).goal 'ownership' $null) 'expires_at' ''
    $wExp12 = $null; $gExp12 = $null
    try { $wExp12 = Convert-GHRSUtc -Value (Get-PWValue $w12 'lease_expires_utc' $null) } catch { $wExp12 = $null }
    try { $gExp12 = Convert-GHRSUtc -Value $own12 } catch { $gExp12 = $null }
    Assert-PW ((($null -ne $wExp12) -and ($null -ne $gExp12)) -and ($wExp12.ToUniversalTime().Ticks -eq $gExp12.ToUniversalTime().Ticks)) '[PW12] persisted wait expiry is canonical Goal expiry' ''

    # --- PW13: explicit Task membership required (empty active_tasks ineligible).
    $gen13 = New-PWGoal -Id 'pw-goal-13' -StoreDir $goalDir
    $t13 = New-PWTask -Id 'pw-task-13' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t13.ok) '[PW13] task created' ([string]$t13.error)
    $r13 = Invoke-PWBind -TaskId 'pw-task-13' -GoalId 'pw-goal-13' -RunId 'run-13' -SessionId 'ses-root-13' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen13 -OwnershipGeneration $gen13 -Head $SHA_D
    Assert-PW ((-not [bool]$r13.ok) -and ([string]$r13.reason -ceq 'task-not-in-goal')) '[PW13] empty membership refused' ([string]$r13.reason)

    # --- PW14: tampered stored wait (same dedup) diverges on replay, binding kept.
    $t14 = New-PWTask -Id 'pw-task-14' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t14.ok) '[PW14] task created' ([string]$t14.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-14' -StoreDir $goalDir -Generation $gen1
    $r14 = Invoke-PWBind -TaskId 'pw-task-14' -GoalId 'pw-goal-1' -RunId 'run-14' -SessionId 'ses-root-14' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1 -Head $SHA_E
    Assert-PW ([bool]$r14.ok) '[PW14] wait registered' ([string]$r14.reason)
    $w14doc = ConvertFrom-Json ([IO.File]::ReadAllText([string]$r14.wait_file, [Text.Encoding]::UTF8))
    $w14doc.task_id = 'pw-task-tampered'
    [IO.File]::WriteAllText([string]$r14.wait_file, (ConvertTo-Json $w14doc -Depth 10 -Compress), (New-Object Text.UTF8Encoding $false))
    $r14b = Invoke-PWBind -TaskId 'pw-task-14' -GoalId 'pw-goal-1' -RunId 'run-14' -SessionId 'ses-root-14' -TasksDir $tasksDir -FlagsPath $flagsPath -GoalDir $goalDir -WaitsDir $waitsDir -Generation $gen1 -OwnershipGeneration $gen1 -Head $SHA_E
    Assert-PW ((-not [bool]$r14b.ok) -and ([string]$r14b.reason -ceq 'wait-divergent')) '[PW14] tampered wait diverges' ([string]$r14b.reason)
    Assert-PW (([string]$r14b.binding -ceq 'already-bound')) '[PW14] binding kept on divergent replay' ([string]$r14b.binding)

    # --- PW15: replay compares stored dedup_key against the canonical requested key.
    $dk15 = Get-OrchestrationGitHubResumeDedupKey -Repository $REPO -PrNumber 42 -HeadSha $SHA_E -Generation $gen1
    Assert-PW ([bool]$dk15.ok) '[PW15] canonical dedup computable' ([string]$dk15.reason)
    $w15base = [pscustomobject][ordered]@{
        schema_version = 1; wait_kind = 'github-ci-resume'; dedup_key = [string]$dk15.dedup_key
        objective_id = 'pw-goal-1'; task_id = 'pw-task-14'; run_id = 'run-14'; generation = $gen1
        repository = 'acme/widgets'; pr_number = [long]42; branch = 'fix/pw'; expected_head_sha = $SHA_E
        required_checks = @('a'); review_expectation = 'APPROVED'; cursor = ''
        deadline_utc = $FUTURE; retry_budget_max = [long]5
        lease_owner = 'planner-1'; lease_expires_utc = $FUTURE; owner = 'planner-1'
    }
    $pw15args = @{ Wait = $w15base; GoalId = 'pw-goal-1'; TaskId = 'pw-task-14'; RunId = 'run-14'; Generation = $gen1; Repository = $REPO; PrNumber = 42; Branch = 'fix/pw'; ExpectedHeadSha = $SHA_E; ReviewExpectation = 'APPROVED'; RequiredChecks = @('a'); Owner = 'planner-1'; LeaseOwner = 'planner-1'; Cursor = ''; DeadlineUtc = $FUTURE; RetryBudgetMax = 5; LeaseExpiresUtc = $FUTURE; DedupKey = [string]$dk15.dedup_key }
    Assert-PW ([bool](Test-PWWaitReplayConsistent @pw15args)) '[PW15] intact replay consistent' ''
    $w15bad = [pscustomobject][ordered]@{
        schema_version = 1; wait_kind = 'github-ci-resume'; dedup_key = 'github-resume:v1:acme/widgets:42:ffffffffffffffffffffffffffffffffffffffff:1'
        objective_id = 'pw-goal-1'; task_id = 'pw-task-14'; run_id = 'run-14'; generation = $gen1
        repository = 'acme/widgets'; pr_number = [long]42; branch = 'fix/pw'; expected_head_sha = $SHA_E
        required_checks = @('a'); review_expectation = 'APPROVED'; cursor = ''
        deadline_utc = $FUTURE; retry_budget_max = [long]5
        lease_owner = 'planner-1'; lease_expires_utc = $FUTURE; owner = 'planner-1'
    }
    $pw15badArgs = @{ Wait = $w15bad; GoalId = 'pw-goal-1'; TaskId = 'pw-task-14'; RunId = 'run-14'; Generation = $gen1; Repository = $REPO; PrNumber = 42; Branch = 'fix/pw'; ExpectedHeadSha = $SHA_E; ReviewExpectation = 'APPROVED'; RequiredChecks = @('a'); Owner = 'planner-1'; LeaseOwner = 'planner-1'; Cursor = ''; DeadlineUtc = $FUTURE; RetryBudgetMax = 5; LeaseExpiresUtc = $FUTURE; DedupKey = [string]$dk15.dedup_key }
    Assert-PW (-not [bool](Test-PWWaitReplayConsistent @pw15badArgs)) '[PW15] tampered dedup diverges' ''

    # --- PW16: default waits dir under cache/runtime when WaitsDir omitted.
    $tRepo = Join-Path $root 'fakeroot'
    $t16 = New-PWTask -Id 'pw-task-16' -TasksDir $tasksDir -FlagsPath $flagsPath -Repo $repoRoot
    Assert-PW ([bool]$t16.ok) '[PW16] task created' ([string]$t16.error)
    Add-PWTaskToGoal -GoalId 'pw-goal-1' -TaskId 'pw-task-16' -StoreDir $goalDir -Generation $gen1
    $r16 = Invoke-OrchestrationPlannerWaitBinding -TaskId 'pw-task-16' -GoalId 'pw-goal-1' -RunId 'run-16' -SessionId 'ses-root-16' `
        -OwnerId 'planner-1' -OwnershipGeneration $gen1 -GoalStoreDir $goalDir -TasksDir $tasksDir `
        -Repository $REPO -PrNumber 42 -Branch 'fix/pw' -ExpectedHeadSha $SHA_F -RequiredChecks @($policy.required_checks) `
        -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 `
        -FlagsPath $flagsPath -RepoRoot $tRepo
    Assert-PW ([bool]$r16.ok) '[PW16] default waits dir succeeds' ([string]$r16.reason)
    $wd16 = Join-Path (Join-Path (Join-Path $tRepo 'cache') 'runtime') 'github-waits'
    Assert-PW (([string]$r16.wait_file).StartsWith($wd16, [System.StringComparison]::OrdinalIgnoreCase)) '[PW16] wait under default dir' ([string]$r16.wait_file)

    # --- PW17: bridge rejects extra/unrecognized request fields (dot-sourced, no spawn).
    . (Join-Path $PSScriptRoot 'OrchestrationPlannerWaitBridge.ps1')
    Assert-PW ($null -ne (Get-Command Test-PWBridgeRequestShape -ErrorAction SilentlyContinue)) '[PW17] bridge shape check exposed' ''
    $shGood = [pscustomobject]@{ task_id = 't'; goal_id = 'g'; run_id = 'r'; session_id = 's'; repository = $REPO; pr_number = 42; branch = 'b'; expected_head_sha = $SHA_A; required_checks = @(); review_expectation = 'APPROVED'; cursor = ''; deadline_utc = $FUTURE; retry_budget_max = 5 }
    $shOk = Test-PWBridgeRequestShape -Request $shGood
    Assert-PW ([bool](Get-PWValue $shOk 'ok' $false)) '[PW17] clean request passes shape' ([string](Get-PWValue $shOk 'reason' ''))
    foreach ($extra in @('tasks_dir', 'owner', 'ownership_generation', 'lease_owner', 'lease_expires_utc', 'goal_store_dir', 'waits_dir', 'flags_path', 'repo_root', 'whatever')) {
        $shBad = [pscustomobject]@{ task_id = 't'; goal_id = 'g'; run_id = 'r'; session_id = 's'; repository = $REPO; pr_number = 42; branch = 'b'; expected_head_sha = $SHA_A; required_checks = @(); review_expectation = 'APPROVED'; cursor = ''; deadline_utc = $FUTURE; retry_budget_max = 5 }
        $shBad | Add-Member -NotePropertyName $extra -NotePropertyValue 'x' -Force
        $shBadRes = Test-PWBridgeRequestShape -Request $shBad
        Assert-PW (((-not [bool](Get-PWValue $shBadRes 'ok' $true)) -and ([string](Get-PWValue $shBadRes 'reason' '') -ceq 'bridge-request-unexpected-field'))) ("[PW17] extra key rejected: " + $extra) ([string](Get-PWValue $shBadRes 'reason' ''))
    }
    # --- PW18: model-supplied lease_expires_utc (later/earlier) never crosses
    # the bridge: strict shape rejects it even with an otherwise-clean shape.
    foreach ($probe in @('2099-01-01T00:00:00Z', '2000-01-01T00:00:00Z')) {
        $shLease = [pscustomobject]@{ task_id = 't'; goal_id = 'g'; run_id = 'r'; session_id = 's'; repository = $REPO; pr_number = 42; branch = 'b'; expected_head_sha = $SHA_A; required_checks = @(); review_expectation = 'APPROVED'; cursor = ''; deadline_utc = $FUTURE; retry_budget_max = 5 }
        $shLease | Add-Member -NotePropertyName 'lease_expires_utc' -NotePropertyValue $probe -Force
        $shLeaseRes = Test-PWBridgeRequestShape -Request $shLease
        Assert-PW (((-not [bool](Get-PWValue $shLeaseRes 'ok' $true)) -and ([string](Get-PWValue $shLeaseRes 'reason' '') -ceq 'bridge-request-unexpected-field'))) ("[PW18] model lease rejected: " + $probe) ([string](Get-PWValue $shLeaseRes 'reason' ''))
    }
}
finally {
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ("OrchestrationPlannerWait: {0} / {0} tests passed" -f $script:passed)
