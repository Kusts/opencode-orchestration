<#
.SYNOPSIS
    P2 idempotency/recovery coverage for Invoke-OrchestrationNativeResume (offline).
.DESCRIPTION
    Offline RED->GREEN matrix for the native resume adapter. No real
    `opencode run` is ever executed: every run path uses an injected
    RunExecutor mock with a shared call counter, and session listing uses
    .cmd fixtures plus temp dirs only.

    RED->GREEN MATRIX (condition => reason / action / run?):
      P2-01 session missing (empty list)            => session-not-found / blocked / no run
      P2-02 session of another project             => project-mismatch / blocked / no run
      P2-03 divergent directory                    => directory-mismatch / blocked / no run
      P2-04a stale generation                      => authorization-denied / blocked / no run
      P2-04b stale expected_generation             => authorization-denied / blocked / no run
      P2-04c stale lease_owner                     => authorization-denied / blocked / no run
      P2-04d stale expected_lease_owner            => authorization-denied / blocked / no run
      P2-04e expired lease_expires_utc (past)      => authorization-denied / blocked / no run
      P2-04f fresh fencing token (match + future)  => '' / proceed / exactly 1 run
      P2-04g generation case mismatch (GenA/gena)  => authorization-denied / blocked / no run
      P2-04h unparseable lease_expires_utc         => authorization-denied / blocked / no run (fail-closed)
      P2-05a unknown checkpoint id                 => checkpoint-not-found / blocked / no run
      P2-05b goal store without the goal            => resume-not-resumable / blocked / no run
      P2-06a interrupted before send (pre-check)   => blocked (session-not-found) / no run
      P2-06b interrupted after send (post diverge) => identity-diverged / reconcile / never proceed
      P2-06c session lost after send                => session-not-found-post / reconcile / never proceed
      P2-07 timeout with unknown outcome           => timeout-unknown / reconcile / never proceed, never blind resend
      P2-08 two invokes of the same wake           => each does exactly 1 run; after Task DONE => already-done / blocked / no run
      P2-09 second execution after settlement      => already-done / blocked / no run, no reexec
      P2-10a MODEL_UNAVAILABLE                     => resume-unproven / reconcile
      P2-10b CREDENTIAL_ABSENT                     => resume-unproven / reconcile
      P2-10c PROOF_ABSENT                          => resume-unproven / reconcile

    RED state (before the generation/lease fencing fix): P2-04a..04e, 04g, 04h
    proceeded to run (fencing absent). GREEN state (after the fix in
    OrchestrationNativeResume.ps1): they block with authorization-denied and
    the executor counter stays at 0. Reason stays authorization-denied for
    stability; stale generation/lease is documented in the adapter header.

    Exactly-once note: this adapter is stateless and NEVER marks
    dispatched/executed (envelope always carries dispatched=$false). Real
    exactly-once settlement lives in the caller-owned Claim-once marker
    (FileShare.None) plus the Claim+Settle path. The P2-08/P2-09 DONE gates
    prove the second half: once the Task is DONE, no second execution runs.

    PS 5.1 compatible. ASCII-only. Never throws: failures are FAIL lines.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationNativeResume.ps1')

$passed = 0; $failed = 0
function Assert-S($cond, $name, $detail) {
    if ($cond) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
    else { $script:failed++; Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}

function New-FixtureCmd($dir, $name, $content) {
    $p = Join-Path $dir ($name + '.cmd')
    [IO.File]::WriteAllText($p, $content, [Text.Encoding]::ASCII)
    return $p
}

function New-SessionListCmd($dir, $name, $jsonArray) {
    return (New-FixtureCmd $dir $name ("@echo off`r`necho " + $jsonArray + "`r`n"))
}

function Write-JsonFile($path, $obj) {
    $j = (ConvertTo-Json -InputObject $obj -Depth 20 -Compress)
    [IO.File]::WriteAllText($path, $j, ([Text.UTF8Encoding]::new($false)))
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('nr-p2-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
$tasksDir = Join-Path $base 'tasks'
$goalDir = Join-Path $base 'goals'
$ckptDir = Join-Path $base 'ckpts'
$emptyGoalDir = Join-Path $base 'goals-empty'
$workDir = Join-Path $base 'work'
$otherDir = Join-Path $base 'other'
foreach ($d in @($tasksDir, $goalDir, $ckptDir, $emptyGoalDir, $workDir, $otherDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$goalId = 'goal-1'
$cid = 'abcdef0123456789'
$taskId = 'wake-task-1'
$flipTaskId = 'wake-flip-1'
$doneTaskId = 'wake-done-1'
$key = '0123456789abcdef0123456789abcdef'
$sid = 'ses_abc123'

$ckpt = [ordered]@{
    checkpoint_id = $cid
    goal_id = $goalId
    goal_revision = 3
    objective = 'resume ci wait'
    progress = [ordered]@{ satisfied = 1; total = 2; updated_at = '2026-10-31T00:00:00Z' }
    plan_progress = [ordered]@{ phase = 1; total_phases = 3; done_tasks = 1 }
    decision_refs = @()
    evidence_refs = @()
    failed_strategies = @()
    blockers = @()
    risks = @()
    waits = @()
    next_move = [ordered]@{}
    resume_preconditions = [ordered]@{ base_revision = 'r1'; goal_exists = $false; store_readable = $false }
    base_revision = 'r1'
    created_at = '2026-10-31T00:00:00Z'
}
Write-JsonFile (Join-Path $ckptDir ($cid + '.json')) $ckpt
Write-JsonFile (Join-Path $goalDir ($goalId + '.json')) ([ordered]@{ goal_id = $goalId; revision = 3; base_revision = 'r1' })
Write-JsonFile (Join-Path $tasksDir ($taskId + '.json')) ([ordered]@{ revision = 1; state = 'BLOCKED' })
Write-JsonFile (Join-Path $tasksDir ($flipTaskId + '.json')) ([ordered]@{ revision = 1; state = 'BLOCKED' })
Write-JsonFile (Join-Path $tasksDir ($doneTaskId + '.json')) ([ordered]@{ revision = 5; state = 'DONE' })

$workEsc = (([string]$workDir) -replace '\\', '\\')
$otherEsc = (([string]$otherDir) -replace '\\', '\\')
$goodJson = ('[{"id":"' + $sid + '","title":"t","created":1000,"updated":2000,"directory":"' + $workEsc + '","projectId":"proj1"}]')
$otherProjJson = ('[{"id":"' + $sid + '","title":"t","created":1000,"updated":2000,"directory":"' + $workEsc + '","projectId":"other-proj"}]')
$otherDirJson = ('[{"id":"' + $sid + '","title":"t","created":1000,"updated":2000,"directory":"' + $otherEsc + '","projectId":"proj1"}]')

$goodCmd = New-SessionListCmd $base 'good' $goodJson
$emptyCmd = New-SessionListCmd $base 'emptylist' '[]'
$otherProjCmd = New-SessionListCmd $base 'otherproj' $otherProjJson
$otherDirCmd = New-SessionListCmd $base 'otherdir' $otherDirJson

$okEvidence = '{"sessionId":"ses_abc123","role":"assistant"}'

function New-BaseArgs($binaryCmd) {
    return @{
        SessionId = $sid
        ExpectedDirectory = $workDir
        ExpectedProjectId = 'proj1'
        GoalId = $goalId
        TaskId = $taskId
        CheckpointId = $cid
        CheckpointDir = $ckptDir
        GoalStoreDir = $goalDir
        TasksDir = $tasksDir
        RepoRoot = $base
        IdempotencyKey = $key
        PromptText = 'resume kernel next move'
        BinaryCommand = $binaryCmd
        TimeoutMs = 5000
    }
}

function Invoke-Resume($ArgMap, $mock) {
    $a = @{} + $ArgMap
    if ($null -ne $mock) { $a['RunExecutor'] = $mock }
    return (Invoke-OrchestrationNativeResume @a)
}

try {
    # --- P2-01 session missing => blocked session-not-found, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $emptyCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'session-not-found') -and ($r.action -ceq 'blocked')) 'P2-01-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-01-no-run' ("calls=$($st.n)")

    # --- P2-02 session of another project => blocked project-mismatch, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $otherProjCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'project-mismatch') -and ($r.action -ceq 'blocked')) 'P2-02-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-02-no-run' ("calls=$($st.n)")

    # --- P2-03 divergent directory => blocked directory-mismatch, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $otherDirCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'directory-mismatch') -and ($r.action -ceq 'blocked')) 'P2-03-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-03-no-run' ("calls=$($st.n)")

    # --- P2-04a stale generation => blocked authorization-denied, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['Generation'] = '7'
    $a['Authorization'] = @{ explicit_allow = $true; generation = '9' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04a-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04a-no-run' ("calls=$($st.n)")

    # --- P2-04b stale expected_generation => blocked authorization-denied, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['Generation'] = '7'
    $a['Authorization'] = @{ explicit_allow = $true; expected_generation = '8' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04b-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04b-no-run' ("calls=$($st.n)")

    # --- P2-04c stale lease_owner => blocked authorization-denied, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['LeaseOwner'] = 'owner1'
    $a['Authorization'] = @{ explicit_allow = $true; lease_owner = 'owner2' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04c-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04c-no-run' ("calls=$($st.n)")

    # --- P2-04d stale expected_lease_owner => blocked authorization-denied, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['LeaseOwner'] = 'owner1'
    $a['Authorization'] = @{ explicit_allow = $true; expected_lease_owner = 'owner9' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04d-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04d-no-run' ("calls=$($st.n)")

    # --- P2-04e expired lease_expires_utc => blocked authorization-denied, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd
    $a['Authorization'] = @{ explicit_allow = $true; lease_expires_utc = '2000-01-01T00:00:00Z' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04e-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04e-no-run' ("calls=$($st.n)")

    # --- P2-04f fresh fencing token (match + future lease) => proceed, exactly 1 run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['Generation'] = '7'; $a['LeaseOwner'] = 'owner1'
    $a['Authorization'] = @{ explicit_allow = $true; generation = '7'; lease_owner = 'owner1'; lease_expires_utc = '2099-01-01T00:00:00Z' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $true) -and ($r.action -ceq 'proceed') -and ([string]::IsNullOrWhiteSpace($r.reason))) 'P2-04f-proceed' ($r.action + '/' + $r.reason)
    Assert-S ($st.n -eq 1) 'P2-04f-one-run' ("calls=$($st.n)")
    Assert-S (($r.dispatched -eq $false) -and ($r.executed -eq $false)) 'P2-04f-stateless' 'never marks dispatched/executed'

    # --- P2-04g generation case mismatch => blocked authorization-denied, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['Generation'] = 'gena'
    $a['Authorization'] = @{ explicit_allow = $true; generation = 'GenA' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04g-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04g-no-run' ("calls=$($st.n)")

    # --- P2-04h unparseable lease_expires_utc => blocked authorization-denied, no run (fail-closed) ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd
    $a['Authorization'] = @{ explicit_allow = $true; lease_expires_utc = 'not-a-date' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04h-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04h-no-run' ("calls=$($st.n)")

    # --- P2-04i Generation set + Auth null => blocked authorization-denied, no run (mandatory fencing) ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['Generation'] = '7'
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04i-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04i-no-run' ("calls=$($st.n)")

    # --- P2-04j LeaseOwner set + Auth null => blocked authorization-denied, no run (mandatory fencing) ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['LeaseOwner'] = 'owner1'
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04j-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04j-no-run' ("calls=$($st.n)")

    # --- P2-04k LeaseOwner set + Auth without lease_owner field => blocked authorization-denied, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['LeaseOwner'] = 'owner1'
    $a['Authorization'] = @{ explicit_allow = $true; generation = '7' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04k-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04k-no-run' ("calls=$($st.n)")

    # --- P2-04l Generation set + Auth without generation field => blocked authorization-denied, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['Generation'] = '7'
    $a['Authorization'] = @{ explicit_allow = $true; lease_owner = 'owner1' }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'P2-04l-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-04l-no-run' ("calls=$($st.n)")

    # --- P2-05a unknown checkpoint id => blocked checkpoint-not-found, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['CheckpointId'] = 'ffffffffffffffff'
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'checkpoint-not-found') -and ($r.action -ceq 'blocked')) 'P2-05a-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-05a-no-run' ("calls=$($st.n)")

    # --- P2-05b goal store without the goal => blocked resume-not-resumable, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['GoalStoreDir'] = $emptyGoalDir
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'resume-not-resumable') -and ($r.action -ceq 'blocked')) 'P2-05b-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-05b-no-run' ("calls=$($st.n)")

    # --- P2-06a interrupted before send (pre-check fails) => blocked, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $emptyCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.action -ceq 'blocked')) 'P2-06a-blocked' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-06a-no-run' ("calls=$($st.n)")

    # --- P2-06c session lost after send => reconcile session-not-found-post, never proceed ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 1; stdout = ''; stderr = 'Session not found: ses_abc123'; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'session-not-found-post') -and ($r.action -ceq 'reconcile')) 'P2-06c-reconcile' ($r.reason + '/' + $r.action)
    Assert-S (($r.dispatched -eq $false) -and ($r.executed -eq $false)) 'P2-06c-stateless' 'never dispatched/executed on reconcile'
    Assert-S ($st.n -eq 1) 'P2-06c-sent-once' ("calls=$($st.n)")

    # --- P2-07 timeout with unknown outcome => reconcile timeout-unknown, never proceed/resend ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = -1; stdout = ''; stderr = 'TIMEOUT'; timedOut = $true } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'timeout-unknown') -and ($r.action -ceq 'reconcile')) 'P2-07-reconcile' ($r.reason + '/' + $r.action)
    Assert-S (($r.dispatched -eq $false) -and ($r.executed -eq $false)) 'P2-07-no-blind-resend' 'envelope never carries dispatched=true; caller must reconcile'
    Assert-S ($r.ok -eq $false) 'P2-07-never-proceed' 'timeout must never yield proceed'

    # --- P2-10a MODEL_UNAVAILABLE => reconcile resume-unproven ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 2; stdout = ''; stderr = 'MODEL_UNAVAILABLE: no model configured'; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'resume-unproven') -and ($r.action -ceq 'reconcile')) 'P2-10a-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 1) 'P2-10a-ran' ("calls=$($st.n)")

    # --- P2-10b CREDENTIAL_ABSENT => reconcile resume-unproven ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 3; stdout = ''; stderr = 'CREDENTIAL_ABSENT: missing token'; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'resume-unproven') -and ($r.action -ceq 'reconcile')) 'P2-10b-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 1) 'P2-10b-ran' ("calls=$($st.n)")

    # --- P2-10c PROOF_ABSENT => reconcile resume-unproven ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 1; stdout = ''; stderr = 'PROOF_ABSENT: no evidence pointer'; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'resume-unproven') -and ($r.action -ceq 'reconcile')) 'P2-10c-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 1) 'P2-10c-ran' ("calls=$($st.n)")

    # --- P2-08 two invokes of the same wake (shared counter), then DONE blocks duplicates ---
    $st = @{ n = 0 }
    $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['TaskId'] = $flipTaskId
    $before = $st.n
    $r1 = Invoke-Resume $a $mk
    Assert-S (($r1.ok -eq $true) -and ($r1.action -ceq 'proceed')) 'P2-08-first-proceed' ($r1.action + '/' + $r1.reason)
    Assert-S (($st.n - $before) -eq 1) 'P2-08-first-one-run' ("delta=" + ($st.n - $before))
    $before = $st.n
    $r2 = Invoke-Resume $a $mk
    Assert-S (($r2.ok -eq $true) -and ($r2.action -ceq 'proceed')) 'P2-08-second-proceed' ($r2.action + '/' + $r2.reason)
    Assert-S (($st.n - $before) -eq 1) 'P2-08-second-one-run' ("delta=" + ($st.n - $before))
    Assert-S (($r1.dispatched -eq $false) -and ($r2.dispatched -eq $false) -and ($r1.executed -eq $false) -and ($r2.executed -eq $false)) 'P2-08-stateless' 'adapter never marks dispatched/executed'
    Write-JsonFile (Join-Path $tasksDir ($flipTaskId + '.json')) ([ordered]@{ revision = 2; state = 'DONE' })
    $before = $st.n
    $r3 = Invoke-Resume $a $mk
    Assert-S (($r3.ok -eq $false) -and ($r3.reason -ceq 'already-done') -and ($r3.action -ceq 'blocked')) 'P2-08-done-blocks' ($r3.reason + '/' + $r3.action)
    Assert-S (($st.n - $before) -eq 0) 'P2-08-done-no-run' ("delta=" + ($st.n - $before))

    # --- P2-09 second execution after settlement (Task DONE) => blocked already-done ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd; $a['TaskId'] = $doneTaskId
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'already-done') -and ($r.action -ceq 'blocked')) 'P2-09-reason' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'P2-09-no-run' ("calls=$($st.n)")
    Assert-S (($r.dispatched -eq $false) -and ($r.executed -eq $false)) 'P2-09-no-reexec' 'settlement DONE implies no reexecution'

    # --- P2-06b interrupted after send: post identity diverges => reconcile identity-diverged ---
    $script:NRP2IdentN = @{ n = 0 }
    $script:NRP2WorkCanon = $workDir
    function Get-NativeSessionIdentity {
        param([string]$SessionId = '', [string]$ExpectedDirectory = '', [string]$ExpectedProjectId = '', [int]$MaxCount = 100, [string]$BinaryCommand = '', [int]$TimeoutMs = 30000)
        $script:NRP2IdentN.n++
        if (($script:NRP2IdentN.n % 2) -eq 1) {
            $sess = [pscustomobject]@{ id = $SessionId; title = 't'; created = 1000; updated = 2000; directory = $script:NRP2WorkCanon; projectId = 'proj1' }
        }
        else {
            $sess = [pscustomobject]@{ id = $SessionId; title = 't'; created = 1000; updated = 2000; directory = $script:NRP2WorkCanon; projectId = 'projX-diverged' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; session = $sess }
    }
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = $okEvidence; stderr = ''; timedOut = $false } }.GetNewClosure()
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'identity-diverged') -and ($r.action -ceq 'reconcile')) 'P2-06b-reconcile' ($r.reason + '/' + $r.action)
    Assert-S (($r.dispatched -eq $false) -and ($r.executed -eq $false)) 'P2-06b-stateless' 'post failure never yields proceed/dispatched'
    Assert-S ($st.n -eq 1) 'P2-06b-sent-once' ("calls=$($st.n)")
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
