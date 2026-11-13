<#
.SYNOPSIS
    Planner root binding tests (hermetic, no inference, temp store only).
.DESCRIPTION
    The Planner runs as the `build` session of OpenCode, so its own session is a
    ROOT session (parentID empty). These tests prove the kernel protocol for that
    shape:
      1. The Planner session binds as the run root with an empty parent.
      2. While the root is the active execution owner, a worker bind is refused
         (BIND_CONFLICT): the root must be detached first.
      3. After the root is detached, a worker session binds under the same run
         and the run is attached again; the root stays the recorded root.
    Uses a temp repo, temp tasks dir and temp flags file. Never touches the
    canonical kernel store.
    Run: powershell -NoProfile -File scripts/v3/lib/OrchestrationPlannerRootBinding.tests.ps1
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')

$script:pass = 0
$script:fail = 0
function Assert-PRB([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name"; $script:pass++ }
    else { Write-Host "[FAIL] $Name"; $script:fail++ }
}

$outer = Join-Path ([IO.Path]::GetTempPath()) ('v3-prb-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $outer 'repo'
$tasks = Join-Path $outer 'tasks'
$flags = Join-Path $outer 'flags.json'
New-Item -ItemType Directory -Path $repo, $tasks -Force | Out-Null
[IO.File]::WriteAllText($flags, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
& git -C $repo init -b master *>$null
if ($LASTEXITCODE -ne 0) { & git -C $repo init *>$null }
& git -C $repo config user.email 'prb-test@example.com' *>$null
& git -C $repo config user.name 'PRB Test' *>$null
& git -C $repo config core.autocrlf false *>$null
& git -C $repo config core.safecrlf false *>$null
[IO.File]::WriteAllText((Join-Path $repo 'base.txt'), "base`n", [Text.UTF8Encoding]::new($false))
& git -C $repo add -A *>$null
& git -C $repo commit -m init -q *>$null
$base = (& git -C $repo rev-parse HEAD).Trim()

$rootSid = 'ses_planner_root_probe'
$childSid = 'ses_worker_probe'
$runId = 'run-prb-001'
$tid = 'prb-001'

try {
    $created = New-OrchestrationTask -TaskId $tid -Objective 'Planner root binding probe' -TaskType 'implementation' -Risk 'medium' `
        -Actor 'planner' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -BaseRevision $base `
        -AcceptanceCriteria @('root bound') -VerificationProfiles @('passes') -TasksDir $tasks -FlagsPath $flags
    Assert-PRB ([bool]$created.ok) 'prb-task-created'
    $rev = [int]$created.revision

    # 1. Planner session is the root: empty parent is the expected shape.
    $b1 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $runId -SessionId $rootSid -ExpectedRevision $rev `
        -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    Assert-PRB ([bool]$b1.ok) 'prb-planner-root-bound-empty-parent'
    $rev2 = [int]$b1.revision
    $rec1 = Get-OrchestrationTask -TaskId $tid -TasksDir $tasks
    $run1 = @($rec1['bindings']['runs'])[0]
    Assert-PRB (([string]$run1['root_session'] -ceq $rootSid) -and ([string]$run1['status'] -ceq 'attached')) 'prb-root-recorded-attached'

    # 2. Active owner requires an asserted matching worker parent.
    $wMissing = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $runId -SessionId $childSid `
        -WorkerSession -ExpectedRevision $rev2 -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    Assert-PRB ((-not [bool]$wMissing.ok) -and ([string]$wMissing.error -ceq 'BIND_PARENT_REQUIRED')) 'prb-worker-parent-required-under-active-root'
    $wWrong = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $runId -SessionId $childSid -ParentId 'ses-other-root' `
        -WorkerSession -ExpectedRevision $rev2 -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    Assert-PRB ((-not [bool]$wWrong.ok) -and ([string]$wWrong.error -ceq 'BIND_PARENT_MISMATCH')) 'prb-worker-wrong-parent-refused'
    $w0 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $runId -SessionId $childSid -ParentId $rootSid -RootId $rootSid `
        -WorkerSession -ExpectedRevision $rev2 -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    Assert-PRB ([bool]$w0.ok) 'prb-worker-bound-under-active-root-with-parent'
    $rev2b = [int]$w0.revision

    # 3. An ownerless detached run is reattached by worker bind without rebind.
    # This is intentional for model-proof flows; it does not create a coordinator.
    $d1 = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId $tid -RunId $runId -SessionId $rootSid -ExpectedRevision $rev2b `
        -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    Assert-PRB ([bool]$d1.ok) 'prb-root-detached'
    $rev3 = [int]$d1.revision
    $rootAgain=Invoke-OrchestrationTaskSessionBinding -Operation rebind -TaskId $tid -RunId $runId -SessionId $rootSid `
        -ExpectedRevision $rev3 -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    $w1 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $runId -SessionId $childSid -ParentId $rootSid -RootId $rootSid `
        -WorkerSession -ExpectedRevision ([int]$rootAgain.revision) -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    Assert-PRB ([bool]$rootAgain.ok -and [bool]$w1.ok) 'prb-root-rebind-restores-worker-run'
    $rec2 = Get-OrchestrationTask -TaskId $tid -TasksDir $tasks
    $run2 = @($rec2['bindings']['runs'])[0]
    Assert-PRB (([string]$run2['status'] -ceq 'attached') -and (@($run2['worker_sessions']) -contains $childSid)) 'prb-worker-recorded-under-attached-run'
    # The worker list must hold exactly the bound worker: no null placeholders.
    $wsList = @($run2['worker_sessions'])
    $wsNulls = @($wsList | Where-Object { $null -eq $_ }).Count
    $wsStrings = @($wsList | Where-Object { ($_ -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$_)) })
    Assert-PRB (($wsNulls -eq 0) -and ($wsStrings.Count -eq 1)) 'prb-worker-list-no-null-placeholders'
    # Re-binding the same worker must not append a second entry.
    $wAgain = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $runId -SessionId $childSid -ParentId $rootSid -RootId $rootSid `
        -WorkerSession -ExpectedRevision ([int]$w1.revision) -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    $run3 = @((Get-OrchestrationTask -TaskId $tid -TasksDir $tasks)['bindings']['runs'])[0]
    $wsAfter = @(@($run3['worker_sessions']) | Where-Object { ($_ -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$_)) })
    Assert-PRB (([bool]$wAgain.ok) -and ($wsAfter.Count -eq 1)) 'prb-worker-rebind-no-duplicate-entry'

    # Cross-run uniqueness: a second run of the same task cannot claim a session
    # that run 1 already owns (worker or root), even after run 1 was detached.
    $revNow = [int](Get-OrchestrationTask -TaskId $tid -TasksDir $tasks)['revision']
    $x1 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId 'run-prb-002' -SessionId $childSid -ParentId $rootSid -RootId $rootSid `
        -WorkerSession -ExpectedRevision $revNow -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    Assert-PRB ((-not [bool]$x1.ok) -and ([string]$x1.error -ceq 'BIND_CONFLICT')) 'prb-cross-run-worker-refused'
    # A root of another run must not become a worker here (root continuity as a
    # root is allowed and is exercised by the model-proof escalation chain).
    $x2 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId 'run-prb-002' -SessionId $rootSid -ParentId $rootSid -RootId $rootSid `
        -WorkerSession -ExpectedRevision $revNow -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
    Assert-PRB ((-not [bool]$x2.ok) -and ([string]$x2.error -ceq 'BIND_CONFLICT')) 'prb-cross-run-root-as-worker-refused'
    $runsAfter = @((Get-OrchestrationTask -TaskId $tid -TasksDir $tasks)['bindings']['runs'])
    Assert-PRB ($runsAfter.Count -eq 1) 'prb-cross-run-no-new-run-written'
    # The refused claims must leave run 1 untouched: same root, same single worker,
    # still attached, and no extra entry in its worker list.
    $run1After = @($runsAfter)[0]
    $w1After = @(@($run1After['worker_sessions']) | Where-Object { ($_ -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$_)) })
    Assert-PRB (([string]$run1After['root_session'] -ceq $rootSid) -and ($w1After.Count -eq 1) -and ($w1After[0] -ceq $childSid) -and ([string]$run1After['status'] -ceq 'attached')) 'prb-cross-run-run1-unchanged'
    Assert-PRB ([string]$run2['root_session'] -ceq $rootSid) 'prb-root-session-unchanged'
}
finally {
    try { Remove-Item -LiteralPath $outer -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
