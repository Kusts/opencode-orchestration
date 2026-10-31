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

$base = Join-Path ([IO.Path]::GetTempPath()) ('nr-herm-' + [guid]::NewGuid().ToString('N'))
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
$doneTaskId = 'wake-done-1'
$planTaskId = 'wake-plan-1'
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
Write-JsonFile (Join-Path $tasksDir ($doneTaskId + '.json')) ([ordered]@{ revision = 5; state = 'DONE' })
Write-JsonFile (Join-Path $tasksDir ($planTaskId + '.json')) ([ordered]@{ revision = 2; state = 'PLANNING' })

$workEsc = (([string]$workDir) -replace '\\', '\\')
$otherEsc = (([string]$otherDir) -replace '\\', '\\')
$goodJson = ('[{"id":"' + $sid + '","title":"t","created":1000,"updated":2000,"directory":"' + $workEsc + '","projectId":"proj1"}]')
$otherProjJson = ('[{"id":"' + $sid + '","title":"t","created":1000,"updated":2000,"directory":"' + $workEsc + '","projectId":"other-proj"}]')
$otherDirJson = ('[{"id":"' + $sid + '","title":"t","created":1000,"updated":2000,"directory":"' + $otherEsc + '","projectId":"proj1"}]')

$goodCmd = New-SessionListCmd $base 'good' $goodJson
$emptyCmd = New-SessionListCmd $base 'emptylist' '[]'
$otherProjCmd = New-SessionListCmd $base 'otherproj' $otherProjJson
$otherDirCmd = New-SessionListCmd $base 'otherdir' $otherDirJson

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
    # --- pure validators ---
    Assert-S ((Test-NativeResumeSessionId -SessionId 'ses_abc123') -eq $true) 'sid-valid' 'expected true'
    Assert-S ((Test-NativeResumeSessionId -SessionId '') -eq $false) 'sid-empty' 'expected false'
    Assert-S ((Test-NativeResumeSessionId -SessionId 'abc123') -eq $false) 'sid-no-prefix' 'expected false'
    Assert-S ((Test-NativeResumeSessionId -SessionId 'ses_abc123 --continue') -eq $false) 'sid-continue-flag' 'expected false'
    Assert-S ((Test-NativeResumeSessionId -SessionId '--continue') -eq $false) 'sid-bare-continue' 'expected false'
    Assert-S ((Resolve-NativeResumeDirectory -Path '') -eq '') 'dir-empty' 'expected empty'
    Assert-S (-not [string]::IsNullOrWhiteSpace((Resolve-NativeResumeDirectory -Path $workDir))) 'dir-work' 'expected canon'
    Assert-S ((Test-NativeResumeEvidence -Stdout '{"sessionId":"ses_1","role":"assistant"}' -Stderr '') -eq $true) 'ev-role' 'expected true'
    Assert-S ((Test-NativeResumeEvidence -Stdout '[{"sessionId":"ses_1"}]' -Stderr '') -eq $true) 'ev-sessid' 'expected true'
    Assert-S ((Test-NativeResumeEvidence -Stdout 'all done, plain text' -Stderr '') -eq $false) 'ev-plaintext' 'expected false'
    Assert-S ((Test-NativeResumeEvidence -Stdout '' -Stderr '') -eq $false) 'ev-empty' 'expected false'

    # --- B1 invalid idempotency key ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['IdempotencyKey'] = 'not-hex'
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'invalid-idempotency-key') -and ($r.action -ceq 'blocked')) 'B1-bad-key' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B1-no-run' ("calls=$($st.n)")

    # --- B2 invalid prompt ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['PromptText'] = ''
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'invalid-prompt') -and ($r.action -ceq 'blocked')) 'B2-bad-prompt' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B2-no-run' ("calls=$($st.n)")

    # --- B3 session not found ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $emptyCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'session-not-found') -and ($r.action -ceq 'blocked')) 'B3-notfound' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B3-no-run' ("calls=$($st.n)")

    # --- B4 project mismatch ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $otherProjCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'project-mismatch') -and ($r.action -ceq 'blocked')) 'B4-projmismatch' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B4-no-run' ("calls=$($st.n)")

    # --- B5 directory mismatch ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $otherDirCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'directory-mismatch') -and ($r.action -ceq 'blocked')) 'B5-dirmismatch' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B5-no-run' ("calls=$($st.n)")

    # --- B6 checkpoint not found ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['CheckpointId'] = 'ffffffffffffffff'
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'checkpoint-not-found') -and ($r.action -ceq 'blocked')) 'B6-ckpt' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B6-no-run' ("calls=$($st.n)")

    # --- B7 resume not resumable (goal store without the goal) ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['GoalStoreDir'] = $emptyGoalDir
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'resume-not-resumable') -and ($r.action -ceq 'blocked')) 'B7-notresumable' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B7-no-run' ("calls=$($st.n)")

    # --- B8 already done (second call after settlement) ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['TaskId'] = $doneTaskId
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'already-done') -and ($r.action -ceq 'blocked')) 'B8-done' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B8-no-run' ("calls=$($st.n)")

    # --- B9 kernel not ready (PLANNING state) ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['TaskId'] = $planTaskId
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'kernel-not-ready') -and ($r.action -ceq 'blocked')) 'B9-notready' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B9-no-run' ("calls=$($st.n)")

    # --- B10 timeout unknown ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = -1; stdout = ''; stderr = 'TIMEOUT'; timedOut = $true } }
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'timeout-unknown')) 'B10-timeout' ($r.reason)
    Assert-S (($r.action -ceq 'reconcile') -and ($r.dispatched -eq $false) -and ($r.executed -eq $false)) 'B10-reconcile' ($r.action)

    # --- B11 model unavailable / credential absent ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 2; stdout = ''; stderr = 'MODEL_UNAVAILABLE: no model configured'; timedOut = $false } }
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'resume-unproven')) 'B11-unproven' ($r.reason)
    Assert-S (($r.action -ceq 'reconcile') -and ($st.n -eq 1)) 'B11-reconcile' ($r.action + " calls=$($st.n)")

    # --- B12 session not found post-run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 1; stdout = ''; stderr = 'Session not found: ses_abc123'; timedOut = $false } }
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'session-not-found-post')) 'B12-post' ($r.reason)
    Assert-S ($r.action -ceq 'reconcile') 'B12-reconcile' ($r.action)

    # --- B13 happy path proceeds, never dispatched/executed ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{"sessionId":"ses_abc123","role":"assistant"}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $true) -and ($r.action -ceq 'proceed') -and ([string]::IsNullOrWhiteSpace($r.reason))) 'B13-proceed' ($r.action + '/' + $r.reason)
    Assert-S (($r.dispatched -eq $false) -and ($r.executed -eq $false)) 'B13-noexec' 'must never mark dispatched/executed'
    Assert-S ((($r.evidence_summary).stdout_len -gt 0) -and (($r.run).exit -eq 0) -and ($st.n -eq 1)) 'B13-evidence' 'summary/run/calls'
    Assert-S (([string]($r.idempotency_key) -ceq $key)) 'B13-key' 'idempotency echo'

    # --- B14 authorization denied (stale/invalid fencing token) ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd
    $a['Authorization'] = [pscustomobject]@{ explicit_allow = $false; goal_id = $goalId; owner = 'op'; generation = 1 }
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'authorization-denied') -and ($r.action -ceq 'blocked')) 'B14-authz' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B14-no-run' ("calls=$($st.n)")

    # --- B15 prompt with shell metachar (no space) => invalid-prompt, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['PromptText'] = 'x&whoami'
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'invalid-prompt') -and ($r.action -ceq 'blocked')) 'B15-prompt-amp' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B15-no-run' ("calls=$($st.n)")

    # --- B16 prompt with double quote => invalid-prompt, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['PromptText'] = 'resume "kernel" next move'
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'invalid-prompt') -and ($r.action -ceq 'blocked')) 'B16-prompt-quote' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B16-no-run' ("calls=$($st.n)")

    # --- B17 prompt with backtick / semicolon / dollar => invalid-prompt, no run ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 0; stdout = '{}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd; $a['PromptText'] = 'resume`kernel'
    $r = Invoke-Resume $a $mk
    Assert-S (($r.ok -eq $false) -and ($r.reason -ceq 'invalid-prompt') -and ($r.action -ceq 'blocked')) 'B17-prompt-backtick' ($r.reason + '/' + $r.action)
    Assert-S ($st.n -eq 0) 'B17-no-run' ("calls=$($st.n)")
    # Note: valid prompt still proceeds (B13-proceed above covers the GREEN side).

    # --- B18 stderr redaction: Bearer token never leaks via envelope ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 2; stdout = ''; stderr = 'auth failed Bearer abc123'; timedOut = $false } }
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    $diag18 = ([string]$r.run.stderr_diag)
    Assert-S ((($diag18 -match '\[redacted\]') -and ($diag18 -notmatch 'abc123')) -and ($diag18.Length -le 200)) 'B18-bearer-redacted' $diag18

    # --- B19 stderr redaction: sk- secret never leaks via envelope ---
    $st = @{ n = 0 }; $mk = { param($s) $st.n++; return [pscustomobject]@{ exit = 2; stdout = ''; stderr = 'key sk-fake123 leaked'; timedOut = $false } }
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    $diag19 = ([string]$r.run.stderr_diag)
    Assert-S ((($diag19 -match '\[redacted\]') -and ($diag19 -notmatch 'sk-fake123')) -and ($diag19.Length -le 200)) 'B19-sk-redacted' $diag19

    # --- B20 run carries no --dir flag (v2.2.5 unrecognized-flag RED) ---
    $cap = @{ spec = $null }
    $mk = { param($s) $cap.spec = $s; return [pscustomobject]@{ exit = 0; stdout = '{"sessionId":"ses_abc123","role":"assistant"}'; stderr = ''; timedOut = $false } }
    $a = New-BaseArgs $goodCmd
    $r = Invoke-Resume $a $mk
    $noDir = $false
    try { $noDir = (-not ((@($cap.spec.args)) -contains '--dir')) } catch { $noDir = $false }
    Assert-S (($r.action -ceq 'proceed') -and $noDir) 'B20-no-dir-flag' ('args=' + ((@($cap.spec.args)) -join ','))
    Assert-S (([string]$cap.spec.directory) -ceq ([string](Resolve-NativeResumeDirectory -Path $workDir))) 'B20-workdir-contract' ([string]$cap.spec.directory)

    # --- B21 JSONL event stream (real `run --format json` shape) is evidence ---
    $stream = ('{"type":"step_start","sessionID":"ses_abc123"}' + "`r`n" + '{"type":"text","sessionID":"ses_abc123","text":"hi"}')
    Assert-S ((Test-NativeResumeEvidence -Stdout $stream -Stderr '') -eq $true) 'B21-jsonl-stream' 'expected true'

    # --- B22 multi-line plain text is NEVER evidence ---
    Assert-S ((Test-NativeResumeEvidence -Stdout ("line one`r`nline two") -Stderr '') -eq $false) 'B22-multiline-text' 'expected false'
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
