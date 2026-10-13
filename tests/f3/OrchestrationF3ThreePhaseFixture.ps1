<#!
.SYNOPSIS
    F3.2 fixture driver: one objective, three dependent phases, integrated
    Planner -> NativeDispatch -> TaskKernel -> GoalKernel path.
.DESCRIPTION
    Harness level only. No model provider, no subagent spawn, no network, no
    new endpoint, no new executor, no new authority. Every contract used here
    already exists in scripts/v3/lib and is reused verbatim:

      GoalKernel      New-OrchestrationGoal / Set-OrchestrationGoalState /
                      Save-OrchestrationGoal / Acquire-OrchestrationGoalOwnership /
                      Add-OrchestrationGoalTaskPersisted /
                      Complete-OrchestrationGoalTaskPersisted /
                      Update-OrchestrationGoal / Set-OrchestrationGoalStatePersisted
      TaskKernel      New-OrchestrationTask / Invoke-OrchestrationTaskTransition /
                      Set-OrchestrationTaskWorkerResult /
                      Set-OrchestrationTaskVerification /
                      Set-OrchestrationTaskReview / Complete-OrchestrationTask /
                      Get-OrchestrationEffectiveGrants
      NativeDispatch  New-OrchestrationNativeDispatchIntent /
                      Invoke-OrchestrationNativeDispatchPrepare / ...Claim /
                      ...Settle / ...Advance
      Controller      Get-OrchestrationNextMove (read only advisory)
      AutonomousLoop  Test-ObjectiveCompletionAllowed (progress gate)

    Phase order (fase1 -> fase2 -> fase3) is a HARNESS-side barrier
    convention, NOT a GoalKernel contract: Add-OrchestrationGoalTaskPersisted
    performs CAS + fencing but never checks predecessor state. This harness
    attaches a successor task to the goal record (active_tasks) only after
    its predecessor is settled AND verified AND reviewed AND DONE AND
    recorded as goal progress, and NativeDispatch live admission refuses
    any task that is not in the live goal active_tasks. A later phase is
    therefore not dispatchable before its barrier opens, because this
    harness never opens it early.
    DECLARED LIMITATION (not enforced): nothing in the kernel contract
    stops a caller from attaching a successor early; the barrier holds
    only by harness discipline. See the fixture report for the exact
    boundary.

    FACTS vs SIMULATION (kept apart on purpose):
      FACT       - anything this driver reads back from a kernel store
                   (receipt phase, task revision/state, goal revision/state,
                   effective grants, advance decision record).
      SIMULATION - the worker. There is no real provider here. The single
                   simulated event is one deterministic artifact file per
                   phase, written between CLAIM and SETTLE (the effect
                   boundary). Its content is what the verifier later reads
                   back to produce criterion evidence, so the criterion check
                   is a real file check over simulated output.
      The host call descriptor (session/message/call ids) is SHAPE only and is
      NOT proof of authorship: the native handoff contract says so
      explicitly, and this fixture does not claim otherwise.

    Dot-sourceable library. No execution on load. ASCII-only. Never throws on
    operational paths: every function returns an envelope with ok=$false and a
    machine readable reason.

    PS 5.1 compatible.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Ownership registry for exclusive cleanup: every environment created by
# New-F3Environment in this run registers its root here, and the suite
# teardown removes ONLY registered roots. Foreign temp directories
# (other runs, other checkouts) are never enumerated or touched.
$script:F3OwnedRoots = @()

function Register-F3OwnedRoot {
    [CmdletBinding()]
    param([string]$Root = '')
    try {
        $r = ([string]$Root).Trim()
        if ([string]::IsNullOrWhiteSpace($r)) { return }
        $known = @($script:F3OwnedRoots) | Where-Object { ([string]$_) -ceq $r }
        if (@($known).Count -eq 0) { $script:F3OwnedRoots = @(@($script:F3OwnedRoots) + @($r)) }
    }
    catch { }
}

function Unregister-F3OwnedRoot {
    [CmdletBinding()]
    param([string]$Root = '')
    try {
        $r = ([string]$Root).Trim()
        $script:F3OwnedRoots = @(@($script:F3OwnedRoots) | Where-Object { ([string]$_) -cne $r })
    }
    catch { }
}

function Remove-F3OwnedEnvironments {
    <#
    .SYNOPSIS Removes ONLY the environment roots created by this run
    (ownership registry). Never sweeps foreign f3-* temp directories.
    #>
    [CmdletBinding()]
    param()
    try {
        foreach ($r in @($script:F3OwnedRoots)) {
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$r)) {
                    if (Test-Path -LiteralPath ([string]$r)) {
                        Remove-Item -LiteralPath ([string]$r) -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            catch { }
        }
    }
    catch { }
    finally {
        try { $script:F3OwnedRoots = @() } catch { }
    }
}

try {
    $F3LibDir = Join-Path (Split-Path -Parent $PSCommandPath) '..\..\scripts\v3\lib'
    $F3LibDir = [IO.Path]::GetFullPath($F3LibDir)
    $F3Libs = @(
        'OrchestrationTaskKernel.ps1',
        'OrchestrationGoalKernel.ps1',
        'OrchestrationGoalCheckpoint.ps1',
        'OrchestrationObjectiveController.ps1',
        'OrchestrationEvidenceStore.ps1',
        'OrchestrationObjectiveRuntime.ps1',
        'OrchestrationNativeDispatch.ps1',
        'OrchestrationAutonomousLoop.ps1'
    )
    foreach ($F3Lib in $F3Libs) {
        $F3Path = Join-Path $F3LibDir $F3Lib
        if (Test-Path -LiteralPath $F3Path -PathType Leaf) { . $F3Path }
    }
}
catch { }

function Get-F3Value {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function New-F3Envelope {
    param([bool]$Ok = $false, [string]$Reason = '', $Data = $null)
    return [pscustomobject][ordered]@{
        ok     = [bool]$Ok
        reason = ([string]$Reason)
        data   = $Data
    }
}

# ------------------------------------------------------------------
# Environment (temp dirs only; the repo tree is never written)
# ------------------------------------------------------------------

function New-F3Environment {
    <#
    .SYNOPSIS Hermetic environment: goals, receipts, evidence, tasks,
    artifacts, checkpoints, telemetry, leases + a temp flags file with
    task_kernel enabled (never the repo registry).
    #>
    [CmdletBinding()]
    param([string]$Label = 'f3')
    try {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('f3-fixture-' + $Label + '-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $env = [ordered]@{
            root        = $root
            goal_dir    = (Join-Path $root 'goals')
            ckpt_dir    = (Join-Path $root 'checkpoints')
            receipt_dir = (Join-Path $root 'receipts')
            ev_dir      = (Join-Path $root 'evidence')
            tasks_dir   = (Join-Path $root 'tasks')
            artifacts   = (Join-Path $root 'artifacts')
            leases_dir  = (Join-Path $root 'leases')
            telemetry   = (Join-Path $root 'telemetry')
            flags       = (Join-Path $root 'flags.json')
        }
        foreach ($k in @('goal_dir', 'ckpt_dir', 'receipt_dir', 'ev_dir', 'tasks_dir', 'artifacts', 'leases_dir', 'telemetry')) {
            New-Item -ItemType Directory -Path ([string]$env[$k]) -Force | Out-Null
        }
        [IO.File]::WriteAllText([string]$env['flags'], '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
        Register-F3OwnedRoot -Root ([string]$env['root'])
        return [pscustomobject]$env
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'environment-failed') }
}

function Remove-F3Environment {
    param($Environment = $null)
    try {
        $r = ([string](Get-F3Value $Environment 'root' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($r)) { return }
        if (-not (Test-Path -LiteralPath $r)) { Unregister-F3OwnedRoot -Root $r; return }
        Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
        Unregister-F3OwnedRoot -Root $r
    }
    catch { }
}

# ------------------------------------------------------------------
# Objective fixture
# ------------------------------------------------------------------

function New-F3Goal {
    <#
    .SYNOPSIS One ACTIVE objective with N criteria, TotalPhases = N, and a
    LIVE ownership lease allocated by the GoalKernel (generation 1).
    #>
    [CmdletBinding()]
    param(
        $Environment = $null,
        [string]$GoalId = 'f3-goal',
        [string]$Objective = 'three dependent phases',
        [string[]]$Criteria = @('phase-1-artifact', 'phase-2-artifact', 'phase-3-artifact'),
        [string]$OwnerId = 'planner-1',
        [long]$LeaseTtlMs = 300000
    )
    try {
        $goalDir = [string](Get-F3Value $Environment 'goal_dir' '')
        $g = New-OrchestrationGoal -GoalId $GoalId -Objective $Objective -Criteria @($Criteria) `
            -TotalPhases ([long]@($Criteria).Count) -StoreDir $goalDir
        if (-not [bool]$g.ok) { return (New-F3Envelope -Ok $false -Reason ('goal-create:' + [string]$g.reason)) }
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        if (-not [bool]$sv.ok) { return (New-F3Envelope -Ok $false -Reason ('goal-save:' + [string]$sv.reason)) }
        $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId $OwnerId `
            -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir -LeaseTtlMs $LeaseTtlMs
        if (-not [bool]$own.ok) { return (New-F3Envelope -Ok $false -Reason ('ownership:' + [string]$own.reason)) }
        $gen = [long]$own.ownership['generation']
        return (New-F3Envelope -Ok $true -Data ([pscustomobject][ordered]@{
                    goal_id  = $GoalId
                    owner_id = $OwnerId
                    gen      = $gen
                    criteria = [string[]]@($Criteria)
                    auth     = @{ explicit_allow = $true; goal_id = $GoalId; owner = $OwnerId; generation = $gen; source = 'planner' }
                }))
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'goal-fixture-exception') }
}

function Get-F3LiveGoal {
    param($Environment = $null, [string]$GoalId = '')
    try {
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir ([string](Get-F3Value $Environment 'goal_dir' ''))
        if ($null -eq $slot) { return $null }
        if (-not [bool](Get-F3Value $slot 'ok' $false)) { return $null }
        return (Get-F3Value $slot 'goal' $null)
    }
    catch { return $null }
}

# ------------------------------------------------------------------
# Grants (intersection, never union)
# ------------------------------------------------------------------

function Get-F3EffectiveGrants {
    <#
    .SYNOPSIS Effective grants = baseline INTERSECT task grants INTERSECT
    runtime capability grants INTERSECT environment authorization grants.
    Unknown role => empty set (fail closed).
    #>
    [CmdletBinding()]
    param(
        [string]$Role = 'coder',
        [string[]]$TaskGrants = @('fs.read', 'fs.write'),
        [string[]]$RuntimeGrants = @('fs.read', 'fs.write'),
        [string[]]$EnvironmentGrants = @('fs.read', 'fs.write')
    )
    try {
        return (Get-OrchestrationEffectiveGrants -Role $Role -TaskGrants @($TaskGrants) `
                -RuntimeCapabilityGrants @($RuntimeGrants) -EnvironmentAuthorizationGrants @($EnvironmentGrants))
    }
    catch { return ([string[]]@()) }
}

# ------------------------------------------------------------------
# Phase task (TaskKernel) + goal attachment (GoalKernel CAS)
# ------------------------------------------------------------------

function New-F3PhaseTask {
    <#
    .SYNOPSIS Creates the kernel task for one phase and drives it to
    IMPLEMENTING. NOT attached to the goal yet: attachment is the barrier
    that opens the phase (Add-OrchestrationGoalTaskPersisted).
    Acceptance criteria are verifiable by FILE: the phase writes one
    deterministic artifact whose content the verifier reads back.
    #>
    [CmdletBinding()]
    param(
        $Environment = $null,
        [string]$GoalId = '',
        [int]$PhaseIndex = 1,
        [int]$TotalPhases = 3,
        [string]$OwnerId = 'planner-1',
        [string]$Actor = 'planner-1',
        [int]$AttemptBudget = 3,
        [switch]$SkipToImplementing
    )
    try {
        $taskId = ('f3-p' + [string]$PhaseIndex)
        $artifactRel = ('artifacts/phase' + [string]$PhaseIndex + '.txt')
        $c = New-OrchestrationTask -TaskId $taskId -Objective ('phase ' + [string]$PhaseIndex + ' of ' + [string]$TotalPhases) `
            -TaskType 'implementation' -Risk 'low' -Actor $Actor `
            -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.0.18' `
            -BaseRevision 'f3-base-rev' -ReadScopes @($artifactRel) -WriteScopes @($artifactRel) `
            -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('artifact:' + $artifactRel + ':deterministic-content') `
            -ExpectedArtifacts @($artifactRel) -AttemptBudget $AttemptBudget `
            -TasksDir ([string](Get-F3Value $Environment 'tasks_dir' '')) `
            -FlagsPath ([string](Get-F3Value $Environment 'flags' '')) `
            -TelemetryRoot ([string](Get-F3Value $Environment 'telemetry' ''))
        if (-not [bool]$c.ok) { return (New-F3Envelope -Ok $false -Reason ('task-create:' + [string]$c.error)) }
        if (-not $SkipToImplementing) {
            $t1 = Invoke-OrchestrationTaskTransition -TaskId $taskId -ToState 'PLANNING' -Actor $Actor -ExpectedRevision 1 `
                -ActorIdentitySource 'explicit-cli' -TasksDir ([string](Get-F3Value $Environment 'tasks_dir' '')) `
                -FlagsPath ([string](Get-F3Value $Environment 'flags' '')) -TelemetryRoot ([string](Get-F3Value $Environment 'telemetry' ''))
            if (-not [bool]$t1.ok) { return (New-F3Envelope -Ok $false -Reason ('task-planning:' + [string]$t1.error)) }
            $t2 = Invoke-OrchestrationTaskTransition -TaskId $taskId -ToState 'IMPLEMENTING' -Actor $Actor -ExpectedRevision 2 `
                -ActorIdentitySource 'explicit-cli' -TasksDir ([string](Get-F3Value $Environment 'tasks_dir' '')) `
                -FlagsPath ([string](Get-F3Value $Environment 'flags' '')) -TelemetryRoot ([string](Get-F3Value $Environment 'telemetry' ''))
            if (-not [bool]$t2.ok) { return (New-F3Envelope -Ok $false -Reason ('task-implementing:' + [string]$t2.error)) }
        }
        $live = Get-OrchestrationTask -TaskId $taskId -TasksDir ([string](Get-F3Value $Environment 'tasks_dir' ''))
        if ($null -ne $live) {
            $err = [string](Get-F3Value $live 'error' '')
            if (-not [string]::IsNullOrWhiteSpace($err)) { return (New-F3Envelope -Ok $false -Reason ('task-read:' + $err)) }
        }
        return (New-F3Envelope -Ok $true -Data ([pscustomobject][ordered]@{
                    task_id      = $taskId
                    phase        = $PhaseIndex
                    revision     = [long](Get-F3Value $live 'revision' 0)
                    state        = [string](Get-F3Value $live 'state' '')
                    scope        = $artifactRel
                    artifact     = (Join-Path ([string](Get-F3Value $Environment 'artifacts' '')) ('phase' + [string]$PhaseIndex + '.txt'))
                    goal_id      = $GoalId
                    owner_id     = $OwnerId
                    attempt_budget = $AttemptBudget
                }))
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'task-fixture-exception') }
}

function Add-F3TaskToGoal {
    <#
    .SYNOPSIS Barrier opener: attaches the phase task to the live goal
    (GoalKernel CAS + ownership fencing). Until this succeeds, NativeDispatch
    admission refuses the task with task-not-in-goal.
    #>
    [CmdletBinding()]
    param($Environment = $null, [string]$GoalId = '', [string]$TaskId = '', [string]$OwnerId = 'planner-1', [long]$Gen = 0)
    try {
        $goalDir = [string](Get-F3Value $Environment 'goal_dir' '')
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $goalDir
        if ($null -eq $slot) { return (New-F3Envelope -Ok $false -Reason 'goal-unavailable') }
        if (-not [bool]$slot.ok) { return (New-F3Envelope -Ok $false -Reason 'goal-unavailable') }
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $TaskId `
            -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $goalDir -OwnerId $OwnerId -OwnershipGeneration $Gen
        return (New-F3Envelope -Ok ([bool]$add.ok) -Reason ([string]$add.reason) -Data $add)
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'attach-exception') }
}

function Complete-F3GoalTask {
    <#
    .SYNOPSIS GoalKernel CAS: moves the settled task from active_tasks to
    completed_tasks and advances the verified-criteria progress counter.
    Task completion alone never moves progress: the progress field is
    written here only after the verifier read the artifact back.
    GUARDS (fail closed, never promote on a broken chain): when the caller
    passes -Walk / -Settlement, both must be ok; independently of that,
    the live TaskKernel record must read back state DONE with
    verification.passed. The original progress.total / total_phases are
    preserved verbatim (never rewritten as 1/1, 2/2, ...).
    #>
    [CmdletBinding()]
    param($Environment = $null, [string]$GoalId = '', [string]$TaskId = '', [string]$OwnerId = 'planner-1', [long]$Gen = 0, [int]$PhaseIndex = 1, $Walk = $null, $Settlement = $null)
    try {
        if (($null -ne $Walk) -and (-not [bool](Get-F3Value $Walk 'ok' $false))) {
            return (New-F3Envelope -Ok $false -Reason 'walk-not-settled')
        }
        if (($null -ne $Settlement) -and (-not [bool](Get-F3Value $Settlement 'ok' $false))) {
            return (New-F3Envelope -Ok $false -Reason 'settlement-not-done')
        }
        $tasksDir = [string](Get-F3Value $Environment 'tasks_dir' '')
        $trec = $null
        try { $trec = Get-OrchestrationTask -TaskId $TaskId -TasksDir $tasksDir } catch { $trec = $null }
        if ($null -eq $trec) { return (New-F3Envelope -Ok $false -Reason 'task-unreadable') }
        $terr = [string](Get-F3Value $trec 'error' '')
        if (-not [string]::IsNullOrWhiteSpace($terr)) { return (New-F3Envelope -Ok $false -Reason ('task-unreadable:' + $terr)) }
        if (([string](Get-F3Value $trec 'state' '')) -cne 'DONE') {
            return (New-F3Envelope -Ok $false -Reason 'task-not-done')
        }
        $tver = Get-F3Value $trec 'verification' $null
        $verPassed = $false
        $verStatus = ''
        if ($null -ne $tver) {
            $verPassed = [bool](Get-F3Value $tver 'passed' $false)
            $verStatus = (([string](Get-F3Value $tver 'status' '')).Trim().ToLowerInvariant())
        }
        if ((-not $verPassed) -and ($verStatus -cne 'verified_pass')) {
            return (New-F3Envelope -Ok $false -Reason 'task-not-verified')
        }
        $goalDir = [string](Get-F3Value $Environment 'goal_dir' '')
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $goalDir
        if ((-not $slot) -or (-not [bool]$slot.ok)) { return (New-F3Envelope -Ok $false -Reason 'goal-unavailable') }
        $live = $slot.goal
        $done = Complete-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $TaskId `
            -ExpectedRevision ([long]$live['revision']) -StoreDir $goalDir -OwnerId $OwnerId -OwnershipGeneration $Gen
        if (-not [bool]$done.ok) { return (New-F3Envelope -Ok $false -Reason ([string]$done.reason)) }
        $prog = Get-F3Value $done.goal 'progress' $null
        $sat = ([long](Get-F3Value $prog 'satisfied' 0)) + 1
        $total = ([long](Get-F3Value $prog 'total' 3))
        $pp = Get-F3Value $done.goal 'plan_progress' $null
        $ph = ([long](Get-F3Value $pp 'phase' 0)) + 1
        $tph = ([long](Get-F3Value $pp 'total_phases' 3))
        $upd = Update-OrchestrationGoal -GoalId $GoalId -ExpectedRevision ([long]$done.goal['revision']) `
            -Fields @{ progress = @{ satisfied = $sat; total = $total }; `
            plan_progress = @{ phase = $ph; total_phases = $tph; done_tasks = $ph } } `
            -StoreDir $goalDir -OwnerId $OwnerId -OwnershipGeneration $Gen
        return (New-F3Envelope -Ok ([bool]$upd.ok) -Reason ([string]$upd.reason) -Data ([pscustomobject]@{ satisfied = $sat; total = $total; phase = $ph; revision = [long]$upd.goal['revision'] }))
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'goal-task-complete-exception') }
}

# ------------------------------------------------------------------
# Dispatch intent + the four receipt phases
# ------------------------------------------------------------------

function New-F3DispatchIntent {
    <#
    .SYNOPSIS Canonical intent for one phase (goal + work item + revision ->
    idempotency key). The key is derived, never invented ad hoc, so a replay
    of the same phase produces the same key.
    #>
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$TaskId = '',
        [long]$TaskExpectedRevision = 0,
        [string]$OwnerId = 'planner-1',
        [long]$Gen = 0,
        [string]$Scope = '',
        [string]$Agent = 'coder',
        [string]$BaseRevision = 'f3-base-rev',
        [switch]$ExternalIdempotent,
        [string]$ExternalIdempotencyProof = '',
        [int]$PhaseIndex = 1
    )
    try {
        $material = ('f3|' + $GoalId + '|' + $TaskId + '|' + [string]$TaskExpectedRevision + '|' + [string]$Gen + '|' + [string]$PhaseIndex + '|' + $ExternalIdempotencyProof)
        $key = Get-NativeDispatchHash32 $material
        $promptHash = Get-NativeDispatchHash32 ('f3-prompt|' + $GoalId + '|' + $TaskId + '|' + [string]$PhaseIndex)
        $i = New-OrchestrationNativeDispatchIntent -TaskId $TaskId -TaskExpectedRevision $TaskExpectedRevision `
            -Agent $Agent -PromptHash $promptHash -Scope @($Scope) `
            -AcceptanceCriteria @('criterion:0') -IdempotencyKey $key `
            -Owner $OwnerId -OwnershipGeneration $Gen -BaseRevision $BaseRevision `
            -ExternalIdempotent ([bool]$ExternalIdempotent) -ExternalIdempotencyProof $ExternalIdempotencyProof
        if (-not [bool](Get-F3Value $i 'ok' $false)) {
            return (New-F3Envelope -Ok $false -Reason ('intent:' + [string](Get-F3Value $i 'reason' 'invalid-intent')))
        }
        $intent = Get-F3Value $i 'intent' $null
        return (New-F3Envelope -Ok $true -Data ([pscustomobject][ordered]@{
                    key    = ([string](Get-F3Value $intent 'idempotency_key' ''))
                    intent = $intent
                    prompt_hash = $promptHash
                }))
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'intent-exception') }
}

function New-F3VerifierResultJson {
    <#
    .SYNOPSIS Verifier result built from a REAL read of the phase artifact.
    status=verified_pass only when the deterministic expected content is on
    disk; otherwise verification_failed. Never self-attested by the worker:
    the worker only claimed criterion:0, the evidence string below comes from
    the file read.
    #>
    [CmdletBinding()]
    param([string]$ArtifactPath = '', [string]$ExpectedContent = '', [int]$CriterionIndex = 0, [string]$Summary = '')
    try {
        $found = $false
        $actual = ''
        if ((-not [string]::IsNullOrWhiteSpace($ArtifactPath)) -and (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
            $actual = [IO.File]::ReadAllText($ArtifactPath, [Text.Encoding]::UTF8)
            $found = ($actual -ceq $ExpectedContent)
        }
        $status = 'verified_pass'
        if (-not $found) { $status = 'verification_failed' }
        $ev = @(
            ('criterion:' + [string]$CriterionIndex + ':artifact-bytes=' + [string][Text.Encoding]::UTF8.GetByteCount($actual) + ';expected-match=' + [string]$found),
            ('criterion:' + [string]$CriterionIndex + ':file=' + [IO.Path]::GetFileName($ArtifactPath))
        )
        $o = [ordered]@{
            ok               = [bool]$found
            task_id          = 'f3-verifier'
            status           = $status
            reason           = ([string]$Summary)
            scope            = $null
            profiles         = @()
            evidence         = $ev
            command_classes = @('test')
        }
        return (($o | ConvertTo-Json -Depth 8 -Compress))
    }
    catch { return '' }
}

function Get-F3PreparedKey {
    <#
    .SYNOPSIS The idempotency key a PREPARE envelope actually committed.
    The prepare envelope itself carries no key field; the committed key lives
    on the canonical intent the envelope returns.
    #>
    [CmdletBinding()]
    param($Prepare = $null)
    try {
        $intent = Get-F3Value $Prepare 'intent' $null
        if ($null -eq $intent) { return '' }
        return ([string](Get-F3Value $intent 'idempotency_key' ''))
    }
    catch { return '' }
}

function Get-F3ReceiptRaw {
    <#
    .SYNOPSIS Read one persisted receipt (FACT read-back, not an envelope).
    #>
    [CmdletBinding()]
    param($Environment = $null, [string]$GoalId = '', [string]$Key = '', [string]$ReceiptRoot = '')
    try {
        $root = ([string]$ReceiptRoot).Trim()
        if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-F3Value $Environment 'receipt_dir' '') }
        if ([string]::IsNullOrWhiteSpace($root)) { return $null }
        $sub = Get-NDGoalReceiptDir -RootDir $root -GoalId $GoalId
        if ([string]::IsNullOrWhiteSpace($sub)) { return $null }
        $p = Join-Path $sub ($Key + '.json')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)))
    }
    catch { return $null }
}

function Get-F3AdvanceRecord {
    <#
    .SYNOPSIS Read the persisted causal-advance decision for one settlement.
    #>
    [CmdletBinding()]
    param($Environment = $null, [string]$GoalId = '', [string]$SettledKey = '', [string]$ReceiptRoot = '')
    try {
        $root = ([string]$ReceiptRoot).Trim()
        if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-F3Value $Environment 'receipt_dir' '') }
        $st = Get-NDAdvanceDir -RootDir $root -GoalId $GoalId
        if (-not [bool](Get-F3Value $st 'ok' $false)) { return $null }
        $p = Join-Path ([string](Get-F3Value $st 'dir' '')) ($SettledKey + '.advance.json')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)))
    }
    catch { return $null }
}

function New-F3ObjectiveStatus {
    <#
    .SYNOPSIS Objective status snapshot in the shape the Advance operation
    consumes (same fields the GoalKernel next-move snapshot carries).
    #>
    [CmdletBinding()]
    param(
        [bool]$Completed = $false,
        [bool]$Authorized = $true,
        [bool]$ProgressPossible = $true,
        [string[]]$Remaining = @(),
        [string]$BlockerKind = '',
        [string]$TerminalBlocker = '',
        $LastFailure = $null
    )
    try {
        $tb = ([string]$TerminalBlocker).Trim()
        if ([string]::IsNullOrWhiteSpace($tb)) { $tb = $null }
        return @{
            objective_completed     = [bool]$Completed
            remaining_work          = [string[]]@($Remaining)
            authorized              = [bool]$Authorized
            blocker_kind            = ([string]$BlockerKind)
            progress_possible       = [bool]$ProgressPossible
            strategy_change         = $false
            context_degraded        = $false
            last_failure            = $LastFailure
            terminal_blocker        = $tb
            consecutive_no_progress = [long]0
        }
    }
    catch { return $null }
}

# ------------------------------------------------------------------
# SIMULATED worker (the single effect between CLAIM and SETTLE)
# ------------------------------------------------------------------

function Get-F3ExpectedArtifactContent {
    <#
    .SYNOPSIS The deterministic content contract of one phase artifact.
    Derived from the dispatch identity, so a phase whose artifact does not
    carry exactly this content fails verification.
    #>
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$TaskId = '', [int]$PhaseIndex = 1)
    return ('goal=' + $GoalId + "`n" + 'task=' + $TaskId + "`n" + 'phase=' + [string]$PhaseIndex + "`n" + 'content=deterministic' + "`n")
}

function Invoke-F3SimulatedWorkerEffect {
    <#
    .SYNOPSIS The ONLY simulated piece of this fixture: one deterministic
    artifact write standing in for a real worker execution. It counts its own
    invocations so the suite can prove there is no double execution, and it
    never runs outside a CLAIMed handoff.
    #>
    [CmdletBinding()]
    param($Counter = $null, [string]$ArtifactPath = '', [string]$TaskId = '', [int]$PhaseIndex = 1, [string]$GoalId = '')
    try {
        $expected = Get-F3ExpectedArtifactContent -GoalId $GoalId -TaskId $TaskId -PhaseIndex $PhaseIndex
        $dir = Split-Path -Parent $ArtifactPath
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($dir)
        }
        [IO.File]::WriteAllText($ArtifactPath, $expected, [Text.UTF8Encoding]::new($false))
        if ($null -ne $Counter) { $Counter.executions = ([int]$Counter.executions) + 1 }
        return (New-F3Envelope -Ok $true -Data ([pscustomobject]@{
                    path     = $ArtifactPath
                    expected = $expected
                    bytes    = [Text.Encoding]::UTF8.GetByteCount($expected)
                    sha256   = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash
                }))
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'simulated-effect-failed') }
}

# ------------------------------------------------------------------
# The integrated phase walk
# ------------------------------------------------------------------

function Invoke-F3ReceiptWalk {
    <#
    .SYNOPSIS Walks the native receipt phases for one work item:
    PREPARE -> CLAIM -> (simulated 1-event executor) -> SETTLE.
    Settle-only: this walk NEVER attaches a successor task and NEVER runs
    the causal advance. The caller opens the barrier (attach + advance)
    only after verification + review + DONE + goal progress, via
    Invoke-F3CausalAdvance. Reuses the native handoff contract verbatim;
    no endpoint, no executor, no authority added.

    -SkipExecutor simulates the crash BEFORE the acknowledgement: the
    claimed receipt is left DISPATCH_UNCERTAIN on purpose.
    -Result overrides the candidate result (used by the negative scenarios).
    #>
    [CmdletBinding()]
    param(
        $Environment = $null,
        $Goal = $null,
        $Authorization = $null,
        $Intent = $null,
        [string]$SessionId = 'ses_f3_parent',
        [string]$ChildSessionId = 'ses_f3_child',
        [string]$MessageId = 'msg_f3_call',
        [string]$CallId = 'call_f3_1',
        [string]$CallerAgent = 'planner',
        [string]$TargetAgent = 'coder',
        [string]$TaskId = '',
        [string]$ArtifactPath = '',
        [int]$PhaseIndex = 1,
        $Counter = $null,
        [switch]$SkipExecutor,
        [switch]$SkipSettle,
        $Result = $null,
        [string]$ReceiptRoot = ''
    )
    try {
        $goalDir = [string](Get-F3Value $Environment 'goal_dir' '')
        $tasksDir = [string](Get-F3Value $Environment 'tasks_dir' '')
        $flags = [string](Get-F3Value $Environment 'flags' '')
        $evDir = [string](Get-F3Value $Environment 'ev_dir' '')
        $receiptDir = ([string]$ReceiptRoot).Trim()
        if ([string]::IsNullOrWhiteSpace($receiptDir)) { $receiptDir = [string](Get-F3Value $Environment 'receipt_dir' '') }

        $step = [ordered]@{}
        $prepare = Invoke-OrchestrationNativeDispatchPrepare -Intent $Intent -Authorization $Authorization `
            -SessionId $SessionId -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flags
        $step['prepare'] = $prepare
        if (-not [bool](Get-F3Value $prepare 'ok' $false)) { return (New-F3Envelope -Ok $false -Reason ('prepare:' + [string](Get-F3Value $prepare 'reason' '')) -Data $step) }

        $key = [string](Get-F3Value $prepare 'idempotency_key' ([string](Get-F3Value (Get-F3Value $Intent 'intent' $Intent) 'idempotency_key' '')))
        $fp = [string](Get-F3Value $prepare 'prepared_fingerprint' '')
        $reference = [string](Get-F3Value $prepare 'reference' '')

        $claim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $key -Authorization $Authorization `
            -SessionId $SessionId -MessageId $MessageId -CallId $CallId -CallerAgent $CallerAgent -TargetAgent $TargetAgent `
            -PreparedFingerprint $fp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flags
        $step['claim'] = $claim
        if (-not [bool](Get-F3Value $claim 'ok' $false)) { return (New-F3Envelope -Ok $false -Reason ('claim:' + [string](Get-F3Value $claim 'reason' '')) -Data $step) }

        $effect = $null
        if (-not $SkipExecutor) {
            $effect = Invoke-F3SimulatedWorkerEffect -Counter $Counter -ArtifactPath $ArtifactPath -TaskId $TaskId `
                -PhaseIndex $PhaseIndex -GoalId ([string](Get-F3Value $Goal 'goal_id' ''))
            $step['effect'] = $effect
            if (-not [bool](Get-F3Value $effect 'ok' $false)) { return (New-F3Envelope -Ok $false -Reason 'effect-failed' -Data $step) }
        }

        $cand = $Result
        if ($null -eq $cand) { $cand = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }
        if ($SkipSettle) {
            # Simulated crash AFTER the effect and BEFORE the acknowledgement:
            # the receipt stays claimed/DISPATCH_UNCERTAIN on purpose. Nothing
            # else in this fixture may settle it implicitly.
            return (New-F3Envelope -Ok $true -Reason 'ack-withheld' -Data ([pscustomobject]@{
                        key      = $key
                        prepared_fingerprint = $fp
                        reference = $reference
                        step      = ([pscustomobject]$step)
                        settled   = $false
                    }))
        }
        $settle = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $key -Authorization $Authorization `
            -ChildSessionId $ChildSessionId -SessionId $SessionId -MessageId $MessageId -CallId $CallId `
            -CallerAgent $CallerAgent -TargetAgent $TargetAgent -PreparedFingerprint $fp -Reference $reference `
            -TaskId $TaskId -Result $cand -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir `
            -TasksDir $tasksDir -FlagsPath $flags
        $step['settle'] = $settle

        $settledOk = [bool](Get-F3Value $settle 'ok' $false)
        $why = ''
        if (-not $settledOk) { $why = 'settle:' + [string](Get-F3Value $settle 'reason' '') }
        return (New-F3Envelope -Ok $settledOk -Reason $why -Data ([pscustomobject]@{
                    key      = $key
                    prepared_fingerprint = $fp
                    reference = $reference
                    step      = ([pscustomobject]$step)
                    settled   = $settledOk
                }))
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'receipt-walk-exception') }
}

function Invoke-F3CausalAdvance {
    <#
    .SYNOPSIS Causal advance for one settlement, run ONLY after the
    predecessor chain is verified + reviewed + DONE + recorded as goal
    progress AND the successor task is already attached to the live goal.
    This function NEVER attaches: attachment is the barrier and belongs to
    the caller. Returns the native advance envelope verbatim (FACT read:
    ok / prepared / move / executor_calls / reason).
    #>
    [CmdletBinding()]
    param(
        $Environment = $null,
        $Goal = $null,
        $Authorization = $null,
        $NextIntent = $null,
        [string]$SettledKey = '',
        [string]$SessionId = 'ses_f3_parent',
        [string]$ReceiptRoot = ''
    )
    try {
        if ($null -eq $NextIntent) { return $null }
        $goalDir = [string](Get-F3Value $Environment 'goal_dir' '')
        $tasksDir = [string](Get-F3Value $Environment 'tasks_dir' '')
        $flags = [string](Get-F3Value $Environment 'flags' '')
        $receiptDir = ([string]$ReceiptRoot).Trim()
        if ([string]::IsNullOrWhiteSpace($receiptDir)) { $receiptDir = [string](Get-F3Value $Environment 'receipt_dir' '') }
        return (Invoke-OrchestrationNativeDispatchAdvance -GoalId ([string](Get-F3Value $Goal 'goal_id' '')) `
            -SettledKey $SettledKey -Authorization $Authorization -ObjectiveStatus (New-F3ObjectiveStatus -Remaining @('next-phase')) `
            -NextIntent $NextIntent -SessionId $SessionId -ReceiptDir $receiptDir -GoalStoreDir $goalDir `
            -TasksDir $tasksDir -FlagsPath $flags)
    }
    catch { return $null }
}

function Invoke-F3TaskSettlement {
    <#
    .SYNOPSIS TaskKernel settlement authority for one phase: VALIDATING ->
    REVIEWING, then verification (verifier result derived from the artifact
    read-back), then review, then Complete-OrchestrationTask. This is the only
    writer of task state DONE, and it refuses to write DONE without
    verification + review + criterion evidence + compliance verdict.
    #>
    [CmdletBinding()]
    param(
        $Environment = $null,
        [string]$TaskId = '',
        [string]$ArtifactPath = '',
        [int]$PhaseIndex = 1,
        [int]$CriterionIndex = 0,
        [string]$Actor = 'planner-1',
        [string]$Reviewer = 'reviewer',
        [string]$Verifier = 'tester',
        [string]$ResidualRisk = 'fixture-harness-residual',
        [string]$ExpectedContent = ''
    )
    try {
        $tasksDir = [string](Get-F3Value $Environment 'tasks_dir' '')
        $flags = [string](Get-F3Value $Environment 'flags' '')
        $tel = [string](Get-F3Value $Environment 'telemetry' '')
        $out = [ordered]@{}
        $live = Get-OrchestrationTask -TaskId $TaskId -TasksDir $tasksDir
        $rev = [long](Get-F3Value $live 'revision' 0)

        $v = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'VALIDATING' -Actor $Verifier -ExpectedRevision $rev `
            -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flags -TelemetryRoot $tel
        $out['validating'] = $v
        if (-not [bool]$v.ok) { return (New-F3Envelope -Ok $false -Reason ('validating:' + [string]$v.error) -Data ([pscustomobject]$out)) }
        $rev = $rev + 1

        $r = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'REVIEWING' -Actor $Verifier -ExpectedRevision $rev `
            -ActorIdentitySource 'explicit-cli' -TasksDir $tasksDir -FlagsPath $flags -TelemetryRoot $tel
        $out['reviewing'] = $r
        if (-not [bool]$r.ok) { return (New-F3Envelope -Ok $false -Reason ('reviewing:' + [string]$r.error) -Data ([pscustomobject]$out)) }
        $rev = $rev + 1

        # The verifier reads the artifact back and compares it against the
        # deterministic content the phase contract requires. Both sides come
        # from the file/dispatch spec, never from the worker's claim.
        $vjson = New-F3VerifierResultJson -ArtifactPath $ArtifactPath -ExpectedContent $ExpectedContent -CriterionIndex $CriterionIndex `
            -Summary ('artifact read-back for phase ' + [string]$PhaseIndex)
        $ver = Set-OrchestrationTaskVerification -TaskId $TaskId -VerifierEvidenceJson $vjson -ExpectedRevision ([int]$rev) `
            -TasksDir $tasksDir -FlagsPath $flags
        $out['verification'] = $ver
        if (-not [bool](Get-F3Value $ver 'ok' $false)) {
            return (New-F3Envelope -Ok $false -Reason ('verification:' + [string](Get-F3Value $ver 'error' 'refused')) -Data ([pscustomobject]$out))
        }
        $rev = $rev + 1

        $revw = Set-OrchestrationTaskReview -TaskId $TaskId -Kind 'reviewer' -Status 'approved' -By $Reviewer `
            -ExpectedRevision ([int]$rev) -TasksDir $tasksDir -FlagsPath $flags
        $out['review'] = $revw
        if (-not [bool](Get-F3Value $revw 'ok' $false)) {
            return (New-F3Envelope -Ok $false -Reason ('review:' + [string](Get-F3Value $revw 'error' 'refused')) -Data ([pscustomobject]$out))
        }
        $rev = $rev + 1

        $done = Complete-OrchestrationTask -TaskId $TaskId -Actor $Actor -ExpectedRevision ([int]$rev) `
            -ResidualRisks @($ResidualRisk) -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' `
            -TasksDir $tasksDir -FlagsPath $flags -TelemetryRoot $tel
        $out['complete'] = $done
        if (-not [bool](Get-F3Value $done 'ok' $false)) {
            return (New-F3Envelope -Ok $false -Reason ('complete:' + [string](Get-F3Value $done 'error' 'refused')) -Data ([pscustomobject]$out))
        }
        return (New-F3Envelope -Ok $true -Data ([pscustomobject]@{ steps = ([pscustomobject]$out); final_revision = $rev + 1 }))
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'task-settlement-exception') }
}

function Invoke-F3ObjectiveCasComplete {
    <#
    .SYNOPSIS The ONLY objective completion path in this fixture:
    progress gate (Test-ObjectiveCompletionAllowed) + GoalKernel CAS
    (Set-OrchestrationGoalStatePersisted with ExpectedRevision + owner +
    generation). No in-memory transition, no shortcut, no CAS bypass.
    #>
    [CmdletBinding()]
    param($Environment = $null, [string]$GoalId = '', [string]$OwnerId = 'planner-1', [long]$Gen = 0)
    try {
        $goalDir = [string](Get-F3Value $Environment 'goal_dir' '')
        $live = Get-F3LiveGoal -Environment $Environment -GoalId $GoalId
        if ($null -eq $live) { return (New-F3Envelope -Ok $false -Reason 'goal-unavailable') }
        $gate = Test-ObjectiveCompletionAllowed -Goal $live
        if (-not [bool](Get-F3Value $gate 'allowed' $false)) {
            return (New-F3Envelope -Ok $false -Reason ('completion-gate:' + [string](Get-F3Value $gate 'reason' 'closed')))
        }
        $cas = Set-OrchestrationGoalStatePersisted -GoalId $GoalId -ToState 'COMPLETED' `
            -ExpectedRevision ([long]$live['revision']) -StoreDir $goalDir -OwnerId $OwnerId -OwnershipGeneration $Gen
        return (New-F3Envelope -Ok ([bool](Get-F3Value $cas 'ok' $false)) -Reason ([string](Get-F3Value $cas 'reason' '')) -Data $cas)
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'objective-cas-exception') }
}

function Get-F3NextMove {
    <#
    .SYNOPSIS Read-only advisory snapshot: what the pure controller says the
    objective should do next. Never an authority: it cannot write state.
    #>
    [CmdletBinding()]
    param($Environment = $null, [string]$GoalId = '')
    try {
        $live = Get-F3LiveGoal -Environment $Environment -GoalId $GoalId
        if ($null -eq $live) { return (New-F3Envelope -Ok $false -Reason 'goal-unavailable') }
        $slot = Get-OrchestrationGoalNextMove -Goal $live
        if (-not [bool](Get-F3Value $slot 'ok' $false)) { return (New-F3Envelope -Ok $false -Reason 'next-move-unavailable') }
        return (New-F3Envelope -Ok $true -Data $slot.next_move)
    }
    catch { return (New-F3Envelope -Ok $false -Reason 'next-move-exception') }
}