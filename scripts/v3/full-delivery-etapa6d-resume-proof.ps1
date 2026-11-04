<#!
.SYNOPSIS
    Etapa 6D resume proof: native session resume in a disposable harness.
.DESCRIPTION
    Single-shot proof that Invoke-OrchestrationNativeResume can proceed over
    an EXISTING native session and that a second call after settlement lands
    on already-done without a new run (no duplication).

    Offline (default): no LLM, no network beyond a local read-only
    `session list` used ONLY to discover a binding (never creates a
    session). The session identity pre-check is stubbed to the discovered
    (or synthetic fallback) binding and the run is a MOCK RunExecutor that
    returns minimal native JSON and counts invocations. Settlement below
    is KERNEL-ONLY (Task B BLOCKED -> IMPLEMENTING -> DONE via the
    task kernel): NOT a NativeDispatch settlement, never dispatched.
    WORKER_DISPATCH_SETTLED (real subagent identified, execution
    evidence, settled NativeDispatch receipt via
    Set-GHWakeDispatchSettlement) is proven mechanically by
    scripts/v3/github-wake-controller.tests.ps1 with an attested child
    session id, never by this harness. Two logical phases
    run sequentially in this process: Phase A builds goal + task A DONE +
    task B BLOCKED + checkpoint + marker, then clears its variables to
    simulate termination; Phase B re-reads everything from disk, never
    re-executes A, resumes B, settles B via the task kernel, and re-invokes
    to prove already-done. Claim taxonomy (never conflated):
    NATIVE_SESSION_RESUMED = existing session resumed by a new process
    with a bound native response observed (Live only);
    WORKER_DISPATCH_SETTLED = real subagent identified, execution
    evidence plus a settled NativeDispatch receipt (controller suite,
    not this harness). INTEGRATED (both in the same live jornada) is
    NOT claimed here.

    Live (opt-in, -Mode Live): same flow but the run is REAL
    (`opencode run --session <id> --format json <prompt>` with the child
    working directory set to <dir>, plus --model from
    OPENCODE_RESUME_MODEL). Never uses --continue/--fork.
    Consumes quota and requires an operator. Missing model/credential or a
    timeout records resume-unproven/timeout-unknown honestly with exit 2
    and NEVER claims NATIVE_SESSION_RESUMED (Offline proves only
    NATIVE_RESUME_AVAILABLE).

    Never touches GitHub, PRs, CI, scheduler, merge, or deploy. Never
    declares ETAPA_6D_READY. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param(
    [ValidateSet('Offline', 'Live')][string]$Mode = 'Offline',
    [string]$SessionId = '',
    [string]$TempRoot = '',
    [int]$TimeoutMs = 60000
)
$ErrorActionPreference = 'Stop'

function Protect-RPDiag {
    param([string]$Text = '')
    try {
        if ([string]::IsNullOrWhiteSpace([string]$Text)) { return '' }
        $t = ([string]$Text).Trim()
        if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
        return $t
    }
    catch { return '' }
}

function Get-RPStderrCode {
    param([string]$Text = '')
    try {
        $t = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { return 'none' }
        if ($t -match 'Session not found|NotFoundError|starts_with|Expected a string') { return 'session-missing' }
        if ($t -match 'TIMEOUT|timed out|timed_out') { return 'timeout' }
        if ($t -match 'MODEL_UNAVAILABLE|CREDENTIAL_ABSENT|no model|missing token') { return 'model-unavailable' }
        return 'other'
    }
    catch { return 'other' }
}

function Write-RPJsonl {
    param($Dir, $Record)
    try {
        if ([string]::IsNullOrWhiteSpace([string]$Dir)) { return }
        if (-not (Test-Path -LiteralPath ([string]$Dir) -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory([string]$Dir)
        }
        $line = ($Record | ConvertTo-Json -Compress -Depth 8)
        [IO.File]::AppendAllText(
            (Join-Path ([string]$Dir) 'resume-proof.jsonl'),
            ($line + [System.Environment]::NewLine),
            [System.Text.Encoding]::UTF8)
    }
    catch { }
}

function Fail-RP {
    param([string]$Message, $Dir, $RunId, [int]$Code = 1)
    try {
        Write-Host ('PROOF_RESUME=FAIL:' + [string]$Message)
        Write-RPJsonl -Dir $Dir -Record ([ordered]@{
            timestamp = ([DateTime]::UtcNow.ToString('o')); run_id = [string]$RunId
            status = 'FAIL'; reason = [string]$Message
        })
    }
    catch { }
    exit $Code
}

try {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $libDir = Join-Path $PSScriptRoot 'lib'
    $evidenceDir = Join-Path $repoRoot 'evidence\v3\etapa6d-resume'
    try {
        if (-not (Test-Path -LiteralPath $evidenceDir -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($evidenceDir)
        }
    }
    catch { }
    $runId = ([guid]::NewGuid().ToString('N'))
    $isLive = ($Mode -ceq 'Live')

    # Libs: adapter first (real session list for binding discovery), then
    # goal/task/checkpoint kernels. NativeResume is loaded LAST because in
    # Offline mode our stub identity shadows the real one.
    . (Join-Path $libDir 'OrchestrationNativeSessionAdapter.ps1')
    . (Join-Path $libDir 'OrchestrationGoalKernel.ps1')
    . (Join-Path $libDir 'OrchestrationTaskKernel.ps1')
    . (Join-Path $libDir 'OrchestrationGoalCheckpoint.ps1')

    # ---- binding: read-only discovery, never creates a session ----
    $bindId = ([string]$SessionId).Trim()
    $bindDir = ''
    $bindProject = ''
    $bindingSource = 'explicit'
    if ([string]::IsNullOrWhiteSpace($bindId)) {
        $bindingSource = 'live-list-first'
        $found = $false
        try {
            $list = Get-NativeSessionList -MaxCount 5 -TimeoutMs $TimeoutMs
            if (($null -ne $list) -and [bool]$list.ok -and (@($list.sessions)).Count -gt 0) {
                $first = @($list.sessions)[0]
                $bindId = ([string]$first.id).Trim()
                $bindDir = ([string]$first.directory).Trim()
                $bindProject = ([string]$first.projectId).Trim()
                $found = $true
            }
        }
        catch { $found = $false }
        if (-not $found -or [string]::IsNullOrWhiteSpace($bindId)) {
            $bindId = ''
            $bindingSource = 'synthetic-local'
        }
    }
    else {
        if ($bindId -cmatch 'continue') { Fail-RP 'session-id-continue-rejected' $evidenceDir $runId 2 }
        if ($bindId -cnotmatch '^ses_[A-Za-z0-9]+$') { Fail-RP 'session-id-invalid' $evidenceDir $runId 2 }
        try {
            $list = Get-NativeSessionList -MaxCount 100 -TimeoutMs $TimeoutMs
            if (($null -ne $list) -and [bool]$list.ok) {
                foreach ($s in @($list.sessions)) {
                    if (([string]$s.id) -ceq $bindId) {
                        $bindDir = ([string]$s.directory).Trim()
                        $bindProject = ([string]$s.projectId).Trim()
                        break
                    }
                }
            }
        }
        catch { }
    }

    # ---- disposable dirs under TempRoot ----
    $base = ([string]$TempRoot).Trim()
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = ([string]$env:TEMP).Trim()
        if ([string]::IsNullOrWhiteSpace($base)) { $base = ([IO.Path]::GetTempPath()) }
    }
    $shared = Join-Path $base ('v3-resume-proof-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $shared 'goals'
    $tasksDir = Join-Path $shared 'tasks'
    $ckptDir = Join-Path $shared 'ckpts'
    $receiptDir = Join-Path $shared 'receipts'
    foreach ($d in @($shared, $goalDir, $tasksDir, $ckptDir, $receiptDir)) {
        [void][System.IO.Directory]::CreateDirectory($d)
    }
    if ([string]::IsNullOrWhiteSpace($bindDir)) {
        # Synthetic fallback ONLY when no live session was discovered.
        # Directory points at the disposable harness dir (never a repo).
        $bindDir = $shared
        if ($bindingSource -ceq 'live-list-first') { $bindingSource = 'synthetic-local' }
        elseif ($bindingSource -ceq 'explicit') { $bindingSource = 'explicit-unlisted' }
    }
    if ($isLive -and (($bindingSource -like 'synthetic*') -or ($bindingSource -ceq 'explicit-unlisted'))) {
        Fail-RP 'live-requires-listed-session' $evidenceDir $runId 2
    }
    if ([string]::IsNullOrWhiteSpace($bindId) -or ($bindId -cnotmatch '^ses_[A-Za-z0-9]+$')) {
        # Deterministic synthetic id for a fully offline box (documented).
        $bindId = ('ses_resumeproof' + $runId.Substring(0, 12))
        if ($bindingSource -ceq 'live-list-first') { $bindingSource = 'synthetic-local' }
    }

    $flagsPath = Join-Path $shared 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    $markerPath = Join-Path $shared 'phase-a-done.json'
    $goalId = 'resume-proof-goal'
    $taskA = 'resume-task-a'
    $taskB = 'resume-task-b'
    $key = ([guid]::NewGuid().ToString('N'))

    if (-not $isLive) {
        # Offline stub: echoes the discovered binding without spawning any
        # process. Keeps fail-closed mismatch semantics. The real adapter
        # stays untouched for Live mode.
        $script:RPBindId = $bindId
        $script:RPBindDir = $bindDir
        $script:RPBindProject = $bindProject
        function Get-NativeSessionIdentity {
            [CmdletBinding()]
            param(
                [string]$SessionId = '',
                [string]$ExpectedDirectory = '',
                [string]$ExpectedProjectId = '',
                [int]$MaxCount = 100,
                [string]$BinaryCommand = 'opencode',
                [int]$TimeoutMs = 30000
            )
            try {
                $sid = (([string]$SessionId).Trim())
                if (($sid -cnotmatch '^ses_[A-Za-z0-9]+$') -or ($sid -match 'continue')) {
                    return [pscustomobject]@{ ok = $false; reason = 'session-id-invalid'; detail = ''; session = $null }
                }
                if ($sid -cne $script:RPBindId) {
                    return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:unknown-id'; session = $null }
                }
                if ((-not [string]::IsNullOrWhiteSpace([string]$ExpectedProjectId)) -and ([string]$ExpectedProjectId -cne $script:RPBindProject) -and (-not [string]::IsNullOrWhiteSpace($script:RPBindProject))) {
                    return [pscustomobject]@{ ok = $false; reason = 'project-mismatch'; detail = 'stub:project-mismatch'; session = $null }
                }
                if ((-not [string]::IsNullOrWhiteSpace([string]$ExpectedDirectory)) -and ([string]$ExpectedDirectory -ine $script:RPBindDir)) {
                    return [pscustomobject]@{ ok = $false; reason = 'directory-mismatch'; detail = 'stub:directory-mismatch'; session = $null }
                }
                $sess = [pscustomobject]@{
                    id = $script:RPBindId; title = 'resume-proof-binding'
                    created = 0; updated = 0
                    directory = $script:RPBindDir; projectId = $script:RPBindProject
                }
                return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; session = $sess }
            }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:error'; session = $null }
            }
        }
    }
    . (Join-Path $libDir 'OrchestrationNativeResume.ps1')

    $promptText = ('Resume kernel next move for session ' + $bindId + ' minimal JSON')

    # ============ PHASE A (logical process A: build, then terminate) ============
    function Invoke-RPPhaseA {
        param($GoalDir, $TasksDir, $CkptDir, $FlagsPath, $Shared, $MarkerPath, $GoalId, $TaskA, $TaskB, $BindId, $Key, $BindingSource)
        $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'native resume proof harness' -Criteria @('a', 'b') -TotalPhases 2 -StoreDir $GoalDir
        if (-not [bool]$g.ok) { throw ('goal-create:' + [string]$g.reason) }
        $sv = Save-OrchestrationGoal -Goal $g.goal -StoreDir $GoalDir
        if (-not [bool]$sv.ok) { throw 'goal-save' }
        $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $GoalDir
        $null = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $slot0.goal -ToState 'ACTIVE').goal -StoreDir $GoalDir
        $live0 = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $GoalDir).goal
        $own0 = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live0['revision']) -StoreDir $GoalDir
        if (-not [bool]$own0.ok) { throw ('ownership:' + [string]$own0.reason) }
        $gen0 = [long]$own0.ownership['generation']
        foreach ($tid in @($TaskA, $TaskB)) {
            $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-resume-proof' -ReadScopes @('src/resume-proof.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Shared
            if (-not [bool]$c.ok) { throw ('task-create:' + $tid + ':' + [string]$c.error) }
            $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $GoalDir).goal['revision']
            $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $GoalDir -OwnerId 'planner-1' -OwnershipGeneration $gen0
            if (-not [bool]$add.ok) { throw ('attach:' + $tid + ':' + [string]$add.reason) }
        }
        # Task A: full canonical chain to DONE.
        $t = Get-OrchestrationTask -TaskId $TaskA -TasksDir $TasksDir -RepoRoot $Shared
        $rev = [long]$t.revision
        foreach ($st in @('PLANNING', 'IMPLEMENTING')) {
            $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskA -ToState $st -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Shared
            if (-not [bool]$tr.ok) { throw ('a-transition:' + $st) }
            $rev = [long]$tr.revision
        }
        $wr = Set-OrchestrationTaskWorkerResult -TaskId $TaskA -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Shared
        if (-not [bool]$wr.ok) { throw 'a-worker-result' }
        $rev = [long]$wr.revision
        $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskA -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Shared
        $rev = [long]$tr.revision
        $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskA -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Shared
        $rev = [long]$tr.revision
        $vr = Set-OrchestrationTaskVerification -TaskId $TaskA -VerifierEvidenceJson '{"ok":true,"task_id":"resume","status":"verified_pass","reason":"","scope":null,"profiles":[],"evidence":["criterion:0:verified"],"command_classes":["test"]}' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath
        if (-not [bool]$vr.ok) { throw 'a-verification' }
        $rev = [long]$vr.revision
        $rw = Set-OrchestrationTaskReview -TaskId $TaskA -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath
        if (-not [bool]$rw.ok) { throw 'a-review' }
        $rev = [long]$rw.revision
        $gate = Test-OrchestrationTaskCompletion -TaskId $TaskA -TasksDir $TasksDir -RepoRoot $Shared -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
        if (-not [bool]$gate.complete) { throw 'a-gate' }
        $dn = Complete-OrchestrationTask -TaskId $TaskA -Actor 'planner' -ExpectedRevision $rev -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Shared
        if (-not [bool]$dn.ok) { throw ('a-done:' + [string]$dn.error) }
        # Task B: BLOCKED with a typed wait (external dependency).
        $tt = Get-OrchestrationTask -TaskId $TaskB -TasksDir $TasksDir -RepoRoot $Shared
        $rv2 = [long]$tt.revision
        $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskB -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rv2 -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Shared
        if (-not [bool]$tr.ok) { throw 'b-planning' }
        $rv2 = [long]$tr.revision
        $dep = ('native-session:v1:' + $BindId)
        $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskB -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rv2 -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Shared -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-native-resume' -WaitDependencyId $dep
        if (-not [bool]$tr.ok) { throw ('b-block:' + [string]$tr.error) }
        # Checkpoint AFTER A DONE + B BLOCKED so revision matches at resume.
        $liveG = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $GoalDir).goal
        $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $liveG
        if ($null -eq $ckpt) { throw 'checkpoint-new' }
        $svC = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $CkptDir
        if (-not [bool]$svC.ok) { throw ('checkpoint:' + [string]$svC.reason) }
        $aAfter = Get-OrchestrationTask -TaskId $TaskA -TasksDir $TasksDir -RepoRoot $Shared
        $bAfter = Get-OrchestrationTask -TaskId $TaskB -TasksDir $TasksDir -RepoRoot $Shared
        $marker = [ordered]@{
            checkpoint_id = [string]$svC.checkpoint_id; generation = $gen0
            goal_id = $GoalId; task_a = $TaskA; task_b = $TaskB
            session_id = $BindId; idempotency_key = $Key
            binding_source = $BindingSource
            a_revision = [long]$aAfter.revision; a_state = [string]$aAfter.state
            b_revision = [long]$bAfter.revision; b_state = [string]$bAfter.state
        }
        [IO.File]::WriteAllText($MarkerPath, (($marker | ConvertTo-Json -Compress -Depth 4)), [Text.UTF8Encoding]::new($false))
    }

    try {
        Invoke-RPPhaseA -GoalDir $goalDir -TasksDir $tasksDir -CkptDir $ckptDir -FlagsPath $flagsPath -Shared $shared -MarkerPath $markerPath -GoalId $goalId -TaskA $taskA -TaskB $taskB -BindId $bindId -Key $key -BindingSource $bindingSource
    }
    catch {
        Fail-RP ('phase-a:' + (Protect-RPDiag $_.Exception.Message)) $evidenceDir $runId 1
    }
    # Phase A locals lived inside Invoke-RPPhaseA and vanished on return;
    # only the marker file + dirs on disk survive (the cross-phase channel).
    # This best-effort cleanup documents the logical A/B split.
    Remove-Variable -Name g, sv, slot0, live0, own0 -ErrorAction SilentlyContinue
    $marker = ConvertFrom-Json ([IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8))
    $cid = [string]$marker.checkpoint_id
    if ([string]::IsNullOrWhiteSpace($cid)) { Fail-RP 'marker-no-checkpoint' $evidenceDir $runId 1 }
    if ([string]$marker.a_state -cne 'DONE') { Fail-RP 'a-not-done-after-p1' $evidenceDir $runId 1 }
    if ([string]$marker.b_state -cne 'BLOCKED') { Fail-RP 'b-not-blocked-after-p1' $evidenceDir $runId 1 }
    Write-RPJsonl -Dir $evidenceDir -Record ([ordered]@{
        timestamp = ([DateTime]::UtcNow.ToString('o')); run_id = $runId; mode = $Mode
        status = 'PHASE_A'; binding_source = $bindingSource; session_id = $bindId
        task_a_state = 'DONE'; task_b_state = 'BLOCKED'; checkpoint_id = $cid
    })

    # ============ PHASE B (fresh state: re-read from disk only) ============
    $aCheck = Get-OrchestrationTask -TaskId $taskA -TasksDir $tasksDir -RepoRoot $shared
    if (([string]$aCheck.state -cne 'DONE') -or ([long]$aCheck.revision -ne [long]$marker.a_revision)) {
        Fail-RP 'a-rerun-detected' $evidenceDir $runId 1
    }
    $bCheck = Get-OrchestrationTask -TaskId $taskB -TasksDir $tasksDir -RepoRoot $shared
    if ([string]$bCheck.state -cne 'BLOCKED') { Fail-RP 'b-not-blocked-at-resume' $evidenceDir $runId 1 }

    $callCount = @{ n = 0 }
    # NOTE: the closure executors above capture this LOCAL hashtable by
    # reference, so increments persist here. ($script: scope must NOT be
    # used: a .GetNewClosure() block runs in its own module scope and
    # would increment a detached copy, hiding real runs.)
    if (-not $isLive) {
        $mockStdout = ('[{"role":"assistant","sessionId":"' + $bindId + '"}]')
        $runExecutor = { param($spec) $callCount.n++; return [pscustomobject]@{ exit = 0; stdout = $mockStdout; stderr = ''; timedOut = $false } }.GetNewClosure()
    }
    else {
        $model = ([string]$env:OPENCODE_RESUME_MODEL).Trim()
        if ([string]::IsNullOrWhiteSpace($model)) { $model = 'opencode-go/muse-spark-1.3-contributor' }
        $liveModel = $model
        $liveTimeout = $TimeoutMs
        # Real runner: ONE `opencode run --session` (with --model), no
        # --continue/--fork. Mirrors Invoke-NRRealResumeRun arg handling.
        # Locals (not $script:) so .GetNewClosure() captures live values.
        $runExecutor = {
            param($spec)
            $callCount.n++
            try {
                $sid = ([string]$spec.session_id)
                $dir = ([string]$spec.directory)
                $pr = ([string]$spec.prompt)
                $to = [int]$liveTimeout
                if ($to -lt 100) { $to = 100 }
                $argList = New-Object System.Collections.ArrayList
                [void]$argList.Add('run')
                [void]$argList.Add('--model'); [void]$argList.Add($liveModel)
                [void]$argList.Add('--session'); [void]$argList.Add($sid)
                [void]$argList.Add('--format'); [void]$argList.Add('json')
                # NOTE: `opencode run` (v2.2.5) has no --dir flag; the
                # session project resolves from the child working
                # directory (set below). Never re-add --dir here.
                [void]$argList.Add($pr)
                $quoted = New-Object System.Collections.ArrayList
                foreach ($a in $argList) {
                    $s = ([string]$a)
                    if ($s -match '[\s"]') { [void]$quoted.Add(('"' + ($s -replace '"', '\"') + '"')) }
                    else { [void]$quoted.Add($s) }
                }
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                # Resolve without a shell: bare 'opencode' does not spawn
                # via Process.Start (.cmd shim). Prefer a .ps1 sibling
                # under a PowerShell host; anything else fails closed.
                $binFile = 'opencode'
                try {
                    $rc = Get-Command opencode.ps1 -ErrorAction SilentlyContinue
                    if ($rc) { $binFile = ([string]$rc.Source) }
                } catch { }
                if ($binFile -like '*.ps1') {
                    $ph = Get-Command powershell.exe -ErrorAction SilentlyContinue
                    if (-not $ph) { $ph = Get-Command pwsh.exe -ErrorAction SilentlyContinue }
                    if ($ph) {
                        $psi.FileName = ([string]$ph.Source)
                        $escBin = ($binFile -replace '"', '""')
                        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + $escBin + '" ' + ([string[]]$quoted.ToArray() -join ' '))
                    } else {
                        $psi.FileName = $binFile
                        $psi.Arguments = ([string[]]$quoted.ToArray() -join ' ')
                    }
                } else {
                    $psi.FileName = $binFile
                    $psi.Arguments = ([string[]]$quoted.ToArray() -join ' ')
                }
                if (-not [string]::IsNullOrWhiteSpace($dir)) {
                    $dirOk = $false
                    try { $dirOk = (Test-Path -LiteralPath $dir -PathType Container) } catch { $dirOk = $false }
                    if (-not $dirOk) {
                        return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = 'LAUNCH_ERROR:working-directory-missing' }
                    }
                    try { $psi.WorkingDirectory = $dir } catch {
                        return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = ('LAUNCH_ERROR:' + $_.Exception.Message) }
                    }
                }
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.RedirectStandardInput = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $proc = $null
                try { $proc = [System.Diagnostics.Process]::Start($psi) }
                catch {
                    return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = ('LAUNCH_ERROR:' + $_.Exception.Message) }
                }
                try { $proc.StandardInput.Close() } catch { }
                $oT = $proc.StandardOutput.ReadToEndAsync()
                $eT = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit($to)) {
                    try { $proc.Kill() } catch { }
                    return [pscustomobject]@{ ok = $true; timedOut = $true; exit = -1; stdout = ''; stderr = 'TIMEOUT' }
                }
                $so = ''; $se = ''
                try { $so = [string]$oT.Result } catch { $so = '' }
                try { $se = [string]$eT.Result } catch { $se = '' }
                return [pscustomobject]@{ ok = $true; timedOut = $false; exit = [int]$proc.ExitCode; stdout = $so; stderr = $se }
            }
            catch {
                return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = 'RUNNER_ERROR' }
            }
        }.GetNewClosure()
    }

    $resumeAuth = @{ explicit_allow = $true; generation = '1'; lease_owner = 'planner-1' }
    $resume1 = Invoke-OrchestrationNativeResume -SessionId $bindId -ExpectedDirectory $bindDir -ExpectedProjectId $bindProject -GoalId $goalId -TaskId $taskB -CheckpointId $cid -CheckpointDir $ckptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -RepoRoot $shared -IdempotencyKey $key -Generation '1' -LeaseOwner 'planner-1' -Authorization $resumeAuth -PromptText $promptText -MaxCount 100 -BinaryCommand 'opencode' -TimeoutMs $TimeoutMs -RunExecutor $runExecutor
    $runsAfterFirst = [int]$callCount.n
    $proceedOk = ([bool]$resume1.ok -and ([string]$resume1.action -ceq 'proceed') -and ([string]$resume1.reason -ceq ''))
    $rpStderrRaw = ([string]$resume1.run.stderr_diag)
    $rpStderrCode = (Get-RPStderrCode $rpStderrRaw)
    $rpStderrLen = $rpStderrRaw.Length
    Write-RPJsonl -Dir $evidenceDir -Record ([ordered]@{
        timestamp = ([DateTime]::UtcNow.ToString('o')); run_id = $runId; mode = $Mode
        status = 'RESUME_FIRST'; binding_source = $bindingSource; session_id = $bindId
        task_a_state = [string](Get-OrchestrationTask -TaskId $taskA -TasksDir $tasksDir -RepoRoot $shared).state
        task_b_state = [string](Get-OrchestrationTask -TaskId $taskB -TasksDir $tasksDir -RepoRoot $shared).state
        proceed_ok = $proceedOk; action = [string]$resume1.action; reason = [string]$resume1.reason
        runs_count = $runsAfterFirst
        stdout_len = [int]$resume1.evidence_summary.stdout_len
        stderr_code = $rpStderrCode
        stderr_len = $rpStderrLen
    })
    try {
        $rpProofPath = (Join-Path ([string]$evidenceDir) 'resume-proof.jsonl')
        $rpLines = @([IO.File]::ReadAllLines($rpProofPath, [Text.Encoding]::UTF8)) | Where-Object { $_ -like ('*' + $runId + '*') }
        foreach ($rpL in $rpLines) {
            if ($rpL -match 'stderr_diag') { Fail-RP 'proof-leaks-stderr-diag' $evidenceDir $runId 1 }
        }
    }
    catch {
        $rpMsg = ([string]$_.Exception.Message)
        if ($rpMsg -match 'proof-leaks-stderr-diag') { exit 1 }
    }
    if ($isLive -and (-not $proceedOk)) {
        # Honest Live failure: never claim INTEGRATED, never resend blindly.
        Write-Host ('PROOF_RESUME=UNPROVEN:reason=' + [string]$resume1.reason + ',action=' + [string]$resume1.action)
        exit 2
    }
    if (-not $proceedOk) { Fail-RP ('resume-not-proceed:' + [string]$resume1.reason) $evidenceDir $runId 1 }

    # ---- kernel-only settlement (B BLOCKED -> IMPLEMENTING -> DONE).
    # This is the task kernel chain, NOT a NativeDispatch settlement:
    # no worker dispatch, no Set-GHWakeDispatchSettlement, nothing is
    # ever marked dispatched/executed here. ----
    $bLive = Get-OrchestrationTask -TaskId $taskB -TasksDir $tasksDir -RepoRoot $shared
    $fp = ''
    try { $fp = ([string]$bLive.active_wait.fingerprint) } catch { $fp = '' }
    if ([string]::IsNullOrWhiteSpace($fp)) {
        try { $fp = ([string]$bLive.active_wait['fingerprint']) } catch { $fp = '' }
    }
    $bRev = [long]$bLive.revision
    if (-not [string]::IsNullOrWhiteSpace($fp)) {
        $un = Invoke-OrchestrationTaskTransition -TaskId $taskB -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision $bRev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $shared -WaitFingerprint $fp
    }
    else {
        $un = Invoke-OrchestrationTaskTransition -TaskId $taskB -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision $bRev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $shared -UnblockAction 'resume-proof-settle'
    }
    if (-not [bool]$un.ok) { Fail-RP ('settle-unblock:' + [string]$un.error) $evidenceDir $runId 1 }
    $bRev = [long]$un.revision
    $wr = Set-OrchestrationTaskWorkerResult -TaskId $taskB -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision $bRev -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $shared
    if (-not [bool]$wr.ok) { Fail-RP 'settle-worker-result' $evidenceDir $runId 1 }
    $bRev = [long]$wr.revision
    $tr = Invoke-OrchestrationTaskTransition -TaskId $taskB -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $bRev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $shared
    $bRev = [long]$tr.revision
    $tr = Invoke-OrchestrationTaskTransition -TaskId $taskB -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $bRev -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $shared
    $bRev = [long]$tr.revision
    $vr = Set-OrchestrationTaskVerification -TaskId $taskB -VerifierEvidenceJson '{"ok":true,"task_id":"resume","status":"verified_pass","reason":"","scope":null,"profiles":[],"evidence":["criterion:0:verified"],"command_classes":["test"]}' -ExpectedRevision $bRev -TasksDir $tasksDir -FlagsPath $flagsPath
    if (-not [bool]$vr.ok) { Fail-RP 'settle-verification' $evidenceDir $runId 1 }
    $bRev = [long]$vr.revision
    $rw = Set-OrchestrationTaskReview -TaskId $taskB -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision $bRev -TasksDir $tasksDir -FlagsPath $flagsPath
    if (-not [bool]$rw.ok) { Fail-RP 'settle-review' $evidenceDir $runId 1 }
    $bRev = [long]$rw.revision
    $gate = Test-OrchestrationTaskCompletion -TaskId $taskB -TasksDir $tasksDir -RepoRoot $shared -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
    if (-not [bool]$gate.complete) { Fail-RP 'settle-gate' $evidenceDir $runId 1 }
    $dn = Complete-OrchestrationTask -TaskId $taskB -Actor 'planner' -ExpectedRevision $bRev -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $shared
    if (-not [bool]$dn.ok) { Fail-RP ('settle-done:' + [string]$dn.error) $evidenceDir $runId 1 }
    Write-RPJsonl -Dir $evidenceDir -Record ([ordered]@{
        timestamp = ([DateTime]::UtcNow.ToString('o')); run_id = $runId; mode = $Mode
        status = 'KERNEL_SETTLED'; settle_scope = 'kernel-only'
        binding_source = $bindingSource; session_id = $bindId
        task_a_state = 'DONE'; task_b_state = 'DONE'; runs_count = [int]$callCount.n
    })

    # ---- repetition: same key after B DONE => already-done, no new run ----
    $resume2Auth = @{ explicit_allow = $true; generation = '1'; lease_owner = 'planner-1' }
    $resume2 = Invoke-OrchestrationNativeResume -SessionId $bindId -ExpectedDirectory $bindDir -ExpectedProjectId $bindProject -GoalId $goalId -TaskId $taskB -CheckpointId $cid -CheckpointDir $ckptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -RepoRoot $shared -IdempotencyKey $key -Generation '1' -LeaseOwner 'planner-1' -Authorization $resume2Auth -PromptText $promptText -MaxCount 100 -BinaryCommand 'opencode' -TimeoutMs $TimeoutMs -RunExecutor $runExecutor
    $runsAfterSecond = [int]$callCount.n
    $alreadyDone = (([string]$resume2.reason -ceq 'already-done') -and ([string]$resume2.action -ceq 'blocked') -and (-not [bool]$resume2.ok))
    Write-RPJsonl -Dir $evidenceDir -Record ([ordered]@{
        timestamp = ([DateTime]::UtcNow.ToString('o')); run_id = $runId; mode = $Mode
        status = 'RESUME_SECOND'; binding_source = $bindingSource; session_id = $bindId
        task_a_state = 'DONE'; task_b_state = 'DONE'
        proceed_ok = $false; action = [string]$resume2.action; reason = [string]$resume2.reason
        runs_count = $runsAfterSecond; already_done_second = $alreadyDone
    })
    if ((-not $alreadyDone) -or ($runsAfterSecond -ne $runsAfterFirst)) {
        Fail-RP 'second-not-already-done' $evidenceDir $runId 1
    }

    $claim = 'NATIVE_RESUME_AVAILABLE'
    if ($isLive) { $claim = 'NATIVE_SESSION_RESUMED' }
    Write-RPJsonl -Dir $evidenceDir -Record ([ordered]@{
        timestamp = ([DateTime]::UtcNow.ToString('o')); run_id = $runId; mode = $Mode
        status = 'PROOF_OK'; binding_source = $bindingSource; session_id = $bindId
        task_a_state = 'DONE'; task_b_state = 'DONE'
        proceed_ok = $true; runs_count = $runsAfterSecond; already_done_second = $true
        claim = $claim
    })
    $summary = [ordered]@{
        status = 'PROOF_RESUME_OK'; mode = $Mode; run_id = $runId
        binding_source = $bindingSource; session_id = $bindId
        task_a_state = 'DONE'; task_b_state = 'DONE'
        proceed_ok = $true; runs_count = $runsAfterSecond; already_done_second = $true
        evidence_file = (Join-Path $evidenceDir 'resume-proof.jsonl'); claim = $claim
    }
    Write-Host ('PROOF_RESUME=OK:' + (($summary | ConvertTo-Json -Compress -Depth 4)))
    try { Remove-Item -LiteralPath $shared -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    exit 0
}
catch {
    try {
        $msg = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'harness-exception' }
        Write-Host ('PROOF_RESUME=FAIL:' + (Protect-RPDiag $msg))
    }
    catch { }
    exit 1
}
