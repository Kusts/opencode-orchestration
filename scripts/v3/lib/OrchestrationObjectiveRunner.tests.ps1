<#!
.SYNOPSIS
    V3 Objective Runner harness suite: loop-level scenarios over the real libs (SPEC v0.1.0 Phase 15, PR-M).
.DESCRIPTION
    Dot-sourceable test suite (no execution on load beyond the asserts
    below). Uses the REAL libraries through the TEST HARNESS
    (scripts/ci/ObjectiveRunner.harness.ps1, NOT PRODUCT) plus TEMP
    stores. PS 5.1 compatible, ASCII-only. Fails closed via throw on the
    first violated assert; prints one PASS line with the assert count.
    S6 (Jev fallback) is covered by GW-06 in OrchestrationGoldenWorkflows
    (SPEC Sec24 item 24) and is only mapped here, never duplicated.
    Mapping: S1 => SPEC Sec24 itens 7/9 (happy loop ate COMPLETE, zero
    prompts por construcao); S2 => item 8 (finding => repair => re-review
    => COMPLETE, com REPLAN/CONTINUE/COMPLETE reais consumidos do
    controller e re-review em nivel lib = criterios revalidados
    (satisfy ate total) + decisao registrada no history); S3 => itens
    13/21 (failure recoverable => RETRY real 2x, estagnacao =>
    strategy_change_required => REPLAN real, depois recovery com
    progresso => CONTINUE real => COMPLETE, failed_strategy registrada);
    S4 => item 12 (session loss: estado descartado e re-lido do disco
    preserva campos e continua ate COMPLETE); S5 => item budget (hard
    cap => EXHAUSTED + GOAL_HARD_BUDGET_EXHAUSTED, nunca COMPLETED;
    reforce GW-15 em nivel loop); S6 => item 24 via GW-06
    (mapeamento-comentario no golden); S7 => terminais com persistencia
    confirmada (arquivo no lugar do diretorio de checkpoints =>
    harness-persist-failed, nunca terminal falso); S8 => load em escopo
    (processo powershell fresco que dot-sourceia SOMENTE o harness, sem
    preload, dirige o loop ate COMPLETE).
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalProgress.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'ci') 'ObjectiveRunner.harness.ps1')
$passed = 0
function Assert-ORThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-ORTempDir {
    param([string]$Prefix)
    $t = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($t)
    return $t
}
function New-ORGoalWithTasks {
    param([string]$StoreDir, [string]$GoalId, [string[]]$Tasks, [string[]]$Criteria, [long]$HardCap = 0)
    $crit = @($Criteria)
    if ($crit.Count -eq 0) { $crit = @($Tasks | ForEach-Object { ('crit-' + [string]$_) }) }
    $n = New-OrchestrationGoal -GoalId $GoalId -Objective ('harness objective ' + $GoalId) -Criteria $crit -HardCap $HardCap -StoreDir $StoreDir
    if (-not [bool]$n.ok) { throw ('FAIL: setup new goal ' + $GoalId) }
    $sv = Save-OrchestrationGoal -Goal $n.goal -StoreDir $StoreDir
    if (-not [bool]$sv.ok) { throw ('FAIL: setup save goal ' + $GoalId) }
    $act = Set-OrchestrationGoalState -Goal $n.goal -ToState 'ACTIVE'
    if (-not [bool]$act.ok) { throw ('FAIL: setup activate goal ' + $GoalId) }
    $work = $act.goal
    foreach ($t in @($Tasks)) {
        $ad = Add-OrchestrationGoalTask -Goal $work -TaskId ([string]$t)
        if (-not [bool]$ad.ok) { throw ('FAIL: setup add task ' + [string]$t) }
        $work = $ad.goal
    }
    $sv2 = Save-OrchestrationGoal -Goal $work -StoreDir $StoreDir
    if (-not [bool]$sv2.ok) { throw ('FAIL: setup save tasks ' + $GoalId) }
    return $sv2
}
# --- S1: happy 3 tasks => COMPLETE/OBJECTIVE_COMPLETED, iterations>=3, zero prompts.
$s1dir = New-ORTempDir 'or-s1-'
[void](New-ORGoalWithTasks $s1dir 'ORs1goal1' @('ORs1t1', 'ORs1t2', 'ORs1t3') @('c1', 'c2', 'c3'))
$s1 = Invoke-OrchestrationObjectiveRunner -GoalId 'ORs1goal1' -StoreDir $s1dir -Script @(
    @{ complete_tasks = @('ORs1t1'); fail_task = $null; add_finding = $false; satisfy = 1 },
    @{ complete_tasks = @('ORs1t2'); fail_task = $null; add_finding = $false; satisfy = 2 },
    @{ complete_tasks = @('ORs1t3'); fail_task = $null; add_finding = $false; satisfy = 3 }
)
Assert-ORThat (([string]$s1.stop_reason -ceq 'OBJECTIVE_COMPLETED')) 'S1 happy loop stops OBJECTIVE_COMPLETED'
Assert-ORThat (([string]$s1.goal_state -ceq 'COMPLETED')) 'S1 goal state is COMPLETED'
Assert-ORThat (([long]$s1.iterations -ge 3)) 'S1 iterations cover all 3 waves'
Assert-ORThat (([long]$s1.prompts -eq 0)) 'S1 zero prompts by construction'
$s1got = Get-OrchestrationGoal -GoalId 'ORs1goal1' -StoreDir $s1dir
Assert-ORThat (([bool]$s1got.ok) -and ([string]$s1got.goal['state'] -ceq 'COMPLETED')) 'S1 persisted goal is COMPLETED'
Assert-ORThat ((@($s1got.goal['completed_tasks']).Count -eq 3)) 'S1 all 3 tasks completed'
# --- S2: finding mid-loop => repair task => re-review (criteria revalidated) => COMPLETE, all moves real.
$s2dir = New-ORTempDir 'or-s2-'
[void](New-ORGoalWithTasks $s2dir 'ORs2goal1' @('ORs2t1', 'ORs2t2', 'ORs2t3') @('c1', 'c2', 'c3'))
$s2 = Invoke-OrchestrationObjectiveRunner -GoalId 'ORs2goal1' -StoreDir $s2dir -Script @(
    @{ complete_tasks = @('ORs2t1'); fail_task = $null; add_finding = $false; satisfy = 1 },
    @{ complete_tasks = @('ORs2t2'); fail_task = $null; add_finding = $true; satisfy = 2 },
    @{ complete_tasks = @('ORs2t3', 'repair-1'); fail_task = $null; add_finding = $false; satisfy = 3 }
)
Assert-ORThat (([string]$s2.stop_reason -ceq 'OBJECTIVE_COMPLETED')) 'S2 finding loop still stops OBJECTIVE_COMPLETED'
Assert-ORThat (([string]$s2.goal_state -ceq 'COMPLETED')) 'S2 goal state is COMPLETED'
$s2got = Get-OrchestrationGoal -GoalId 'ORs2goal1' -StoreDir $s2dir
Assert-ORThat (([bool]$s2got.ok) -and (@($s2got.goal['completed_tasks']) -contains 'repair-1')) 'S2 repair task completed after finding'
Assert-ORThat ((@($s2got.goal['completed_tasks']).Count -eq 4)) 'S2 wave plus repair all completed'
Assert-ORThat (([long]$s2got.goal['progress']['satisfied'] -eq 3) -and ([long]$s2got.goal['progress']['total'] -eq 3)) 'S2 re-review revalidated all criteria (satisfy to total)'
$s2replans = @($s2.history | Where-Object { [string]$_.move -ceq 'REPLAN' })
Assert-ORThat (($s2replans.Count -ge 1)) 'S2 history records a finding REPLAN'
foreach ($rp in $s2replans) {
    Assert-ORThat (([string]$rp.controller_move -ceq 'REPLAN')) 'S2 every REPLAN is the real controller move, never scripted'
}
$s2continues = @($s2.history | Where-Object { [string]$_.move -ceq 'CONTINUE' })
Assert-ORThat (($s2continues.Count -ge 1)) 'S2 history records a real CONTINUE after the finding wave'
foreach ($ct in $s2continues) {
    Assert-ORThat (([string]$ct.controller_move -ceq 'CONTINUE')) 'S2 every CONTINUE is the real controller move, never scripted'
}
$s2last = $s2.history[$s2.history.Count - 1]
Assert-ORThat (([string]$s2last.move -ceq 'COMPLETE') -and ([string]$s2last.controller_move -ceq 'COMPLETE')) 'S2 final move is COMPLETE consumed from the controller'
Assert-ORThat (([string]$s2last.reason -ceq 'objective-completed')) 'S2 final reason is the controller objective-completed'
foreach ($ent in @($s2.history)) {
    Assert-ORThat (([string]$ent.move -ceq [string]$ent.controller_move)) 'S2 no fabricated moves: move equals controller_move on every entry'
}
# --- S3: 2x recoverable failure => real RETRY pair, stagnation => real REPLAN, recovery => real CONTINUE => COMPLETE.
$s3dir = New-ORTempDir 'or-s3-'
[void](New-ORGoalWithTasks $s3dir 'ORs3goal1' @('ORs3t1', 'ORs3t2') @('c1', 'c2'))
$s3 = Invoke-OrchestrationObjectiveRunner -GoalId 'ORs3goal1' -StoreDir $s3dir -Script @(
    @{ complete_tasks = @(); fail_task = 'recoverable'; add_finding = $false; satisfy = -1 },
    @{ complete_tasks = @(); fail_task = 'recoverable'; add_finding = $false; satisfy = -1 },
    @{ complete_tasks = @(); fail_task = $null; add_finding = $false; satisfy = -1 },
    @{ complete_tasks = @('ORs3t1'); fail_task = $null; add_finding = $false; satisfy = 1 },
    @{ complete_tasks = @('ORs3t2'); fail_task = $null; add_finding = $false; satisfy = 2 }
)
Assert-ORThat (([string]$s3.stop_reason -ceq 'OBJECTIVE_COMPLETED')) 'S3 recovered loop stops OBJECTIVE_COMPLETED'
$retries = @($s3.history | Where-Object { [string]$_.move -ceq 'RETRY' })
Assert-ORThat (($retries.Count -eq 2)) 'S3 history records exactly 2 RETRY moves'
foreach ($rt in $retries) {
    Assert-ORThat (([string]$rt.controller_move -ceq 'RETRY')) 'S3 every RETRY is the real controller move (last_failure recoverable + remaining)'
}
Assert-ORThat (([string]$retries[0].reason -ceq 'recoverable-failure-retry')) 'S3 RETRY reason comes from the controller rule'
$lastRetryIter = [long]$retries[$retries.Count - 1].iteration
$s3replans = @($s3.history | Where-Object { ([string]$_.move -ceq 'REPLAN') -and ([long]$_.iteration -gt $lastRetryIter) })
Assert-ORThat (($s3replans.Count -ge 1)) 'S3 stagnation after the failures yields a real REPLAN'
foreach ($rp3 in $s3replans) {
    Assert-ORThat (([string]$rp3.controller_move -ceq 'REPLAN')) 'S3 every REPLAN is the real controller move (stagnation strategy_change)'
}
$lastReplanIter = [long]$s3replans[$s3replans.Count - 1].iteration
$s3rec = @($s3.history | Where-Object { ([long]$_.iteration -gt $lastReplanIter) -and ([string]$_.move -ceq 'CONTINUE') -and ([bool]$_.meaningful) })
Assert-ORThat (($s3rec.Count -ge 1)) 'S3 recovery with progress yields a real meaningful CONTINUE after the REPLAN'
foreach ($rc in $s3rec) {
    Assert-ORThat (([string]$rc.controller_move -ceq 'CONTINUE')) 'S3 every recovery CONTINUE is the real controller move'
}
foreach ($ent3 in @($s3.history)) {
    Assert-ORThat (([string]$ent3.move -ceq [string]$ent3.controller_move)) 'S3 no fabricated moves: move equals controller_move on every entry'
}
$s3got = Get-OrchestrationGoal -GoalId 'ORs3goal1' -StoreDir $s3dir
Assert-ORThat (([bool]$s3got.ok) -and (@($s3got.goal['failed_strategies']).Count -ge 2)) 'S3 failed strategies recorded twice'
Assert-ORThat ((@($s3got.goal['completed_tasks']).Count -eq 2)) 'S3 both wave tasks completed after retries'
# --- S4: session loss after wave 1 => discard memory, re-read disk => preserved => COMPLETE.
$s4dir = New-ORTempDir 'or-s4-'
[void](New-ORGoalWithTasks $s4dir 'ORs4goal1' @('ORs4t1', 'ORs4t2', 'ORs4t3') @('c1', 'c2', 'c3'))
$s4part = Invoke-OrchestrationObjectiveRunner -GoalId 'ORs4goal1' -StoreDir $s4dir -MaxIterations 1 -Script @(
    @{ complete_tasks = @('ORs4t1'); fail_task = $null; add_finding = $false; satisfy = 1 }
)
Assert-ORThat (([string]$s4part.stop_reason -ceq 'harness-iteration-cap')) 'S4 wave 1 stops at the cap, not COMPLETE'
Assert-ORThat (([string]$s4part.goal_state -cne 'COMPLETED')) 'S4 wave 1 goal is not COMPLETED yet'
$s4pre = Get-OrchestrationGoal -GoalId 'ORs4goal1' -StoreDir $s4dir
$s4preRev = [long]$s4pre.goal['revision']
$s4preCompleted = @($s4pre.goal['completed_tasks'])
$s4preSat = [long]$s4pre.goal['progress']['satisfied']
$s4ckDir = Join-Path $s4dir 'checkpoints'
$s4ckFiles = @(Get-ChildItem -File (Join-Path $s4ckDir '*.json') -ErrorAction SilentlyContinue)
Assert-ORThat (($s4ckFiles.Count -ge 1)) 'S4 wave 1 left a checkpoint on disk'
$s4pre = $null
$s4ckFiles = $null
$s4post = Get-OrchestrationGoal -GoalId 'ORs4goal1' -StoreDir $s4dir
Assert-ORThat (([bool]$s4post.ok) -and ([long]$s4post.goal['revision'] -eq $s4preRev)) 'S4 re-read preserves revision after loss'
Assert-ORThat ((@($s4post.goal['completed_tasks']) -contains 'ORs4t1')) 'S4 re-read preserves completions after loss'
Assert-ORThat (([long]$s4post.goal['progress']['satisfied'] -eq $s4preSat)) 'S4 re-read preserves progress after loss'
Assert-ORThat ((@($s4post.goal['active_tasks']) -contains 'ORs4t2')) 'S4 re-read preserves remaining work after loss'
$s4ckReload = @(Get-ChildItem -File (Join-Path $s4ckDir '*.json') -ErrorAction SilentlyContinue)
$reloaded = $null
foreach ($f in $s4ckReload) {
    $raw = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName))
    if ([string]$raw.goal_id -ceq 'ORs4goal1') { $reloaded = $raw }
}
Assert-ORThat (($null -ne $reloaded)) 'S4 checkpoint re-read from disk after loss'
$s4 = Invoke-OrchestrationObjectiveRunner -GoalId 'ORs4goal1' -StoreDir $s4dir -Script @(
    @{ complete_tasks = @('ORs4t2'); fail_task = $null; add_finding = $false; satisfy = 2 },
    @{ complete_tasks = @('ORs4t3'); fail_task = $null; add_finding = $false; satisfy = 3 }
)
Assert-ORThat (([string]$s4.stop_reason -ceq 'OBJECTIVE_COMPLETED') -and ([string]$s4.goal_state -ceq 'COMPLETED')) 'S4 resumed loop reaches COMPLETED'
Assert-ORThat ((@((Get-OrchestrationGoal -GoalId 'ORs4goal1' -StoreDir $s4dir).goal['completed_tasks']).Count -eq 3)) 'S4 all 3 tasks completed after resume'
# --- S5: low hard cap => EXHAUSTED + GOAL_HARD_BUDGET_EXHAUSTED, never COMPLETED.
$s5dir = New-ORTempDir 'or-s5-'
[void](New-ORGoalWithTasks $s5dir 'ORs5goal1' @('ORs5t1', 'ORs5t2', 'ORs5t3', 'ORs5t4', 'ORs5t5') @('c1', 'c2', 'c3', 'c4', 'c5') -HardCap 2)
$s5 = Invoke-OrchestrationObjectiveRunner -GoalId 'ORs5goal1' -StoreDir $s5dir -Script @(
    @{ complete_tasks = @('ORs5t1'); fail_task = $null; add_finding = $false; satisfy = 1 },
    @{ complete_tasks = @('ORs5t2'); fail_task = $null; add_finding = $false; satisfy = 2 },
    @{ complete_tasks = @('ORs5t3'); fail_task = $null; add_finding = $false; satisfy = 3 },
    @{ complete_tasks = @('ORs5t4'); fail_task = $null; add_finding = $false; satisfy = 4 },
    @{ complete_tasks = @('ORs5t5'); fail_task = $null; add_finding = $false; satisfy = 5 }
)
Assert-ORThat (([string]$s5.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED')) 'S5 budget loop stops on hard budget exhaustion'
Assert-ORThat (([string]$s5.goal_state -ceq 'EXHAUSTED')) 'S5 goal state is EXHAUSTED'
Assert-ORThat (([string]$s5.goal_state -cne 'COMPLETED')) 'S5 exhausted goal is never COMPLETED'
Assert-ORThat (([string]$s5.stop_reason -cne 'harness-iteration-cap')) 'S5 exhaustion is a budget stop, not the iteration cap'
$s5got = Get-OrchestrationGoal -GoalId 'ORs5goal1' -StoreDir $s5dir
Assert-ORThat (([bool]$s5got.ok) -and ([string]$s5got.goal['state'] -ceq 'EXHAUSTED')) 'S5 persisted goal is EXHAUSTED'
# --- S6 mapping only: Jev fallback stays covered by GW-06 (SPEC Sec24 item 24); no duplicate test here.
Assert-ORThat ($true) 'S6 Jev fallback mapped to GW-06 (no duplicate probe test)'
# --- S7: persistence failure (file where the checkpoints dir belongs) => harness-persist-failed, never a false terminal.
$s7dir = New-ORTempDir 'or-s7-'
[void](New-ORGoalWithTasks $s7dir 'ORs7goal1' @('ORs7t1') @('c1'))
[void][IO.File]::WriteAllText((Join-Path $s7dir 'checkpoints'), 'block')
$s7 = Invoke-OrchestrationObjectiveRunner -GoalId 'ORs7goal1' -StoreDir $s7dir -Script @(
    @{ complete_tasks = @('ORs7t1'); fail_task = $null; add_finding = $false; satisfy = 1 }
)
Assert-ORThat (([string]$s7.stop_reason -ceq 'harness-persist-failed')) 'S7 unpersistable checkpoint stops harness-persist-failed'
Assert-ORThat (([string]$s7.goal_state -cne 'COMPLETED')) 'S7 persistence failure never reports a false COMPLETED'
Assert-ORThat (([string]$s7.goal_state -cne 'EXHAUSTED')) 'S7 persistence failure never reports a false EXHAUSTED'
# --- S8: fresh process dot-sourcing ONLY the harness (no preload) drives the loop to COMPLETE.
$s8dir = New-ORTempDir 'or-s8-'
[void](New-ORGoalWithTasks $s8dir 'ORs8goal1' @('ORs8t1', 'ORs8t2') @('c1', 'c2'))
$s8harness = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'ci') 'ObjectiveRunner.harness.ps1'
$s8child = Join-Path ([IO.Path]::GetTempPath()) ('or-s8-child-' + [Guid]::NewGuid().ToString('N') + '.ps1')
$s8lines = @(
    (". '" + ($s8harness -replace "'", "''") + "'"),
    (("`$r = Invoke-OrchestrationObjectiveRunner -GoalId 'ORs8goal1' -StoreDir '" + ($s8dir -replace "'", "''") + "' -Script @(")),
    ("    @{ complete_tasks = @('ORs8t1'); fail_task = `$null; add_finding = `$false; satisfy = 1 },"),
    ("    @{ complete_tasks = @('ORs8t2'); fail_task = `$null; add_finding = `$false; satisfy = 2 }"),
    (')'),
    ('Write-Output ([string]$r.stop_reason)'),
    ("if ([string]`$r.stop_reason -ceq 'OBJECTIVE_COMPLETED') { exit 0 } else { exit 1 }")
)
[void][IO.File]::WriteAllText($s8child, ($s8lines -join "`r`n"))
$s8exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
& $s8exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $s8child
$s8exit = [int]$LASTEXITCODE
Remove-Item -LiteralPath $s8child -Force -ErrorAction SilentlyContinue
Assert-ORThat (($s8exit -eq 0)) 'S8 fresh process with only the harness reaches OBJECTIVE_COMPLETED'
$s8got = Get-OrchestrationGoal -GoalId 'ORs8goal1' -StoreDir $s8dir
Assert-ORThat (([bool]$s8got.ok) -and ([string]$s8got.goal['state'] -ceq 'COMPLETED')) 'S8 fresh-process run persisted COMPLETED on disk'
Remove-Item -LiteralPath $s1dir -Recurse -Force
Remove-Item -LiteralPath $s2dir -Recurse -Force
Remove-Item -LiteralPath $s3dir -Recurse -Force
Remove-Item -LiteralPath $s4dir -Recurse -Force
Remove-Item -LiteralPath $s5dir -Recurse -Force
Remove-Item -LiteralPath $s7dir -Recurse -Force
Remove-Item -LiteralPath $s8dir -Recurse -Force
Write-Output ("OrchestrationObjectiveRunner: PASS ($passed assertions, S1-S5/S7-S8 plus S6 mapping)")
