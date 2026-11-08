<#!
.SYNOPSIS
    PR181 Fatia A: Planner root-session binding (Phase 32 CAS) + GitHub Wait.
.DESCRIPTION
    Single entrypoint Invoke-OrchestrationPlannerWaitBinding composes two
    existing canonical operations, in order, with fail-closed validation:

      1. Invoke-OrchestrationTaskSessionBinding -Operation bind
         (Phase 32 root-session CAS, never -WorkerSession), then
      2. Register-OrchestrationGitHubWait.

    Validation before any write: task exists and is not terminal, goal
    exists + ACTIVE with the Task explicitly listed in active_tasks,
    ownership held (owner+generation+lease-expiry derived from the stored
    Goal ownership record when the caller omits them; the canonical owner
    is the wait lease owner and the canonical Goal expires_at is the wait
    lease expiry), session not bound on another task, Run
    selection (active Run adopted when uniquely bound and RunId omitted;
    otherwise the canonical first-binding operation under the supplied
    RunId; explicit conflicts fail), and CAS revision fencing. Task/Goal
    /flags paths resolve via kernel defaults tied to the repo root;
    WaitsDir defaults to cache/runtime/github-waits when omitted.

    Idempotent replay: same session replays the bind (kernel idempotent),
    the canonical binding is re-read and verified (Task/Run/session +
    attached + active owner) before any wait work, and a stored wait is
    reused only when it carries the same Task/Run plus every registration
    field (dedup, identity, checks, review, cursor, deadline, retry
    budget, lease owner/expiry, owner); divergence is an explicit
    wait-divergent conflict. A wait failure after a successful bind
    returns binding:'bound' with ok:false so a retry reconciles (recover).

    No daemon, no network, no gh, no spawn, no sleep, no loops that wait.
    grants_authority and done_approved are always false.
#>
function Get-OrchestrationPlannerWaitVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{ schema_version = 1; phase = 'PR181-A' }
}

function Get-PlannerWaitDefaultWaitsDir {
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    try {
        $root = ([string]$RepoRoot).Trim()
        if ([string]::IsNullOrWhiteSpace($root)) {
            $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        }
        if ([string]::IsNullOrWhiteSpace($root)) { return '' }
        return (Join-Path (Join-Path (Join-Path ([string]$root) 'cache') 'runtime') 'github-waits')
    }
    catch { return '' }
}

function Get-PWValue {
    param($Object, [string]$Name = '', $Default = $null)
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

function Test-PWBindingId {
    [CmdletBinding()]
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return ($Value.Length -le 128 -and $Value -cmatch '^[A-Za-z0-9._-]+$')
}

function Test-PWTerminalTaskState {
    [CmdletBinding()]
    param([string]$State)
    try {
        $cmd = Get-Command Test-TaskKernelTerminalState -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return [bool](Test-TaskKernelTerminalState -State $State) }
    }
    catch { }
    $s = ([string]$State).Trim().ToUpperInvariant()
    return ($s -ceq 'COMPLETED' -or $s -ceq 'EXHAUSTED' -or $s -ceq 'CANCELLED')
}

function Test-PWSessionBoundElsewhere {
    [CmdletBinding()]
    param([string]$TasksDir, [string]$SkipTaskId, [string]$SessionId)
    $out = { param([bool]$Ok, [bool]$Bound, [string]$Why) return [pscustomobject]@{ ok = $Ok; boundElsewhere = $Bound; reason = $Why } }
    try {
        if ([string]::IsNullOrWhiteSpace($TasksDir)) { return (& $out $false $false 'session-scan-dir-missing') }
        if (-not (Test-Path -LiteralPath $TasksDir -PathType Container)) { return (& $out $false $false 'session-scan-dir-missing') }
        $files = $null
        try { $files = @(Get-ChildItem -LiteralPath $TasksDir -File -Filter '*.json' -ErrorAction Stop) }
        catch { return (& $out $false $false 'session-scan-unreadable') }
        foreach ($f in @($files)) {
            if ([string]$f.BaseName -ceq [string]$SkipTaskId) { continue }
            if ([long]$f.Length -gt 1048576) { return (& $out $false $false 'session-scan-record-oversized') }
            $text = $null
            try { $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) }
            catch { return (& $out $false $false 'session-scan-record-unreadable') }
            if ([string]::IsNullOrWhiteSpace($text)) { return (& $out $false $false 'session-scan-record-malformed') }
            $doc = $null
            try { $doc = ConvertFrom-Json $text }
            catch { return (& $out $false $false 'session-scan-record-malformed') }
            if ($null -eq $doc) { return (& $out $false $false 'session-scan-record-malformed') }
            $bindings = Get-PWValue $doc 'bindings' $null
            if ($null -eq $bindings) { continue }
            if ([string](Get-PWValue $bindings 'active_execution_owner' '') -ceq [string]$SessionId) { return (& $out $true $true '') }
            foreach ($run in @(Get-PWValue $bindings 'runs' @())) {
                if ([string](Get-PWValue $run 'root_session' '') -ceq [string]$SessionId) { return (& $out $true $true '') }
                foreach ($ws in @(Get-PWValue $run 'worker_sessions' @())) {
                    if ([string]$ws -ceq [string]$SessionId) { return (& $out $true $true '') }
                }
            }
        }
        return (& $out $true $false '')
    }
    catch { return (& $out $false $false 'session-scan-unreadable') }
}

function Test-PWBindingVerified {
    [CmdletBinding()]
    param([string]$TaskId = '', [string]$RunId = '', [string]$SessionId = '', [string]$TasksDir = '', [string]$RepoRoot = '')
    try {
        $tid = ([string]$TaskId).Trim()
        $rid = ([string]$RunId).Trim()
        $sid = ([string]$SessionId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid) -or [string]::IsNullOrWhiteSpace($rid) -or [string]::IsNullOrWhiteSpace($sid)) { return $false }
        $b = $null
        try { $b = Get-OrchestrationTaskBindings -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { return $false }
        if ($null -eq $b) { return $false }
        try { if ($null -ne $b.PSObject.Properties['error']) { return $false } } catch { return $false }
        $bindings = Get-PWValue $b 'bindings' $null
        if ($null -eq $bindings) { return $false }
        if ([string](Get-PWValue $bindings 'active_execution_owner' '') -cne $sid) { return $false }
        $found = $false
        foreach ($e in @(Get-PWValue $bindings 'runs' @())) {
            if ([string](Get-PWValue $e 'run_id' '') -ceq $rid) {
                $found = $true
                if ([string](Get-PWValue $e 'root_session' '') -cne $sid) { return $false }
                if ([string](Get-PWValue $e 'status' '') -cne 'attached') { return $false }
            }
        }
        return $found
    }
    catch { return $false }
}

function Test-PWWaitReplayConsistent {
    [CmdletBinding()]
    param($Wait, [string]$GoalId, [string]$TaskId, [string]$RunId, [long]$Generation,
        [string]$Repository, [long]$PrNumber, [string]$Branch, [string]$ExpectedHeadSha,
        [string]$ReviewExpectation, $RequiredChecks, [string]$Owner, [string]$LeaseOwner,
        [string]$Cursor = '', $DeadlineUtc = $null, $RetryBudgetMax = $null, $LeaseExpiresUtc = $null,
        [string]$DedupKey = '')
    try {
        # Only registration-defining fields are compared. Runtime-evolved
        # fields (wait_state, retry_used, applied_events, created_at,
        # updated_at, wait_file) are intentionally excluded.
        if ([long](Get-PWValue $Wait 'schema_version' -1) -ne 1) { return $false }
        if ([string](Get-PWValue $Wait 'wait_kind' '') -cne 'github-ci-resume') { return $false }
        # The stored dedup key must equal the canonical requested key. This
        # is the identity of the registration: a stored record whose dedup
        # was tampered (or written for other fields) must never replay.
        if ([string]::IsNullOrWhiteSpace($DedupKey)) { return $false }
        if ([string](Get-PWValue $Wait 'dedup_key' '') -cne [string]$DedupKey) { return $false }
        if ([string](Get-PWValue $Wait 'objective_id' '') -cne [string]$GoalId) { return $false }
        if ([string](Get-PWValue $Wait 'task_id' '') -cne [string]$TaskId) { return $false }
        if ([string](Get-PWValue $Wait 'run_id' '') -cne [string]$RunId) { return $false }
        if ([long](Get-PWValue $Wait 'generation' -1) -ne [long]$Generation) { return $false }
        if ([string](Get-PWValue $Wait 'repository' '') -cne ([string]$Repository).Trim().ToLowerInvariant()) { return $false }
        if ([long](Get-PWValue $Wait 'pr_number' -1) -ne [long]$PrNumber) { return $false }
        if ([string](Get-PWValue $Wait 'branch' '') -cne ([string]$Branch).Trim()) { return $false }
        if ([string](Get-PWValue $Wait 'expected_head_sha' '') -cne ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()) { return $false }
        if ([string](Get-PWValue $Wait 'review_expectation' '') -cne ([string]$ReviewExpectation).Trim().ToUpperInvariant()) { return $false }
        if ([string](Get-PWValue $Wait 'owner' '') -cne [string]$Owner) { return $false }
        if ([string](Get-PWValue $Wait 'lease_owner' '') -cne [string]$LeaseOwner) { return $false }
        if ([string](Get-PWValue $Wait 'cursor' '') -cne [string]$Cursor) { return $false }
        if ([long](Get-PWValue $Wait 'retry_budget_max' -1) -ne [long]$RetryBudgetMax) { return $false }
        $want = @()
        foreach ($c in @($RequiredChecks)) { $want += ([string]$c).Trim() }
        $got = @()
        foreach ($c in @(Get-PWValue $Wait 'required_checks' @())) { $got += ([string]$c) }
        $ws = (@($want | Sort-Object) -join "`n")
        $gs = (@($got | Sort-Object) -join "`n")
        if ($ws -cne $gs) { return $false }
        foreach ($pair in @(@('deadline_utc', $DeadlineUtc), @('lease_expires_utc', $LeaseExpiresUtc))) {
            $storedRaw = Get-PWValue $Wait ([string]$pair[0]) $null
            $stored = $null
            $wanted = $null
            try { $stored = Convert-GHRSUtc -Value $storedRaw } catch { $stored = $null }
            try { $wanted = Convert-GHRSUtc -Value $pair[1] } catch { $wanted = $null }
            if (($null -eq $stored) -or ($null -eq $wanted)) { return $false }
            if ($stored.ToUniversalTime().Ticks -ne $wanted.ToUniversalTime().Ticks) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Invoke-OrchestrationPlannerWaitBinding {
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$GoalId = '',
        [string]$RunId = '',
        [string]$SessionId = '',
        [string]$OwnerId = '',
        [long]$OwnershipGeneration = 0,
        [string]$GoalStoreDir = '',
        [string]$TasksDir = '',
        [string]$WaitsDir = '',
        [string]$Repository = '',
        $PrNumber = $null,
        [string]$Branch = '',
        [string]$ExpectedHeadSha = '',
        $RequiredChecks = @(),
        [string]$ReviewExpectation = 'APPROVED',
        [string]$Cursor = '',
        $DeadlineUtc = $null,
        $RetryBudgetMax = $null,
        [int]$ExpectedRevision = -1,
        [string]$FlagsPath = '',
        [string]$RepoRoot = ''
    )
    try {
        foreach ($lib in @('OrchestrationTaskKernel.ps1', 'OrchestrationGoalKernel.ps1', 'OrchestrationGitHubResume.ps1')) {
            $p = Join-Path $PSScriptRoot $lib
            if (Test-Path -LiteralPath $p -PathType Leaf) { . $p }
        }
        $fail = {
            param([string]$Why, [string]$Binding = '', [string]$Run = '')
            return [pscustomobject]@{
                ok = $false; reason = $Why; run_id = $Run; revision = [long]-1
                binding = $Binding; wait_reused = $false; wait_file = ''; dedup_key = ''
                task_mutated = $false; grants_authority = $false; done_approved = $false
            }
        }
        $tid = ([string]$TaskId).Trim()
        $gid = ([string]$GoalId).Trim()
        $sid = ([string]$SessionId).Trim()
        $rid = ([string]$RunId).Trim()
        if (-not (Test-TaskKernelId -TaskId $tid)) { return (& $fail 'invalid-task-id') }
        if ([string]::IsNullOrWhiteSpace($gid)) { return (& $fail 'invalid-goal') }
        if (-not (Test-PWBindingId -Value $sid)) { return (& $fail 'invalid-session') }
        if (-not [string]::IsNullOrWhiteSpace($rid)) {
            if (-not (Test-PWBindingId -Value $rid)) { return (& $fail 'invalid-run') }
        }
        # OwnerId/OwnershipGeneration are hermetic-fixture parameters only:
        # the production bridge never sends them. When absent they derive
        # from the stored Goal ownership record (canonical owner + fencing
        # generation); explicit values keep kernel fencing semantics. The
        # lease expiry ALWAYS derives from the live Goal ownership
        # expires_at (no parameter, no model override).
        $ownIn = ([string]$OwnerId).Trim()
        $genIn = 0
        try { $genIn = [long]$OwnershipGeneration } catch { $genIn = 0 }

        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { $task = $null }
        if ($null -eq $task) { return (& $fail 'task-not-found') }
        if ($null -ne $task.PSObject.Properties['error']) {
            $code = ([string]$task.error).Trim().ToLowerInvariant()
            if ($code -ceq 'malformed') { return (& $fail 'task-malformed') }
            return (& $fail 'task-not-found')
        }
        if (Test-PWTerminalTaskState -State ([string](Get-PWValue $task 'state' ''))) { return (& $fail 'task-terminal') }

        $goalSlot = $null
        try { $goalSlot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir } catch { $goalSlot = $null }
        $goalOk = $false
        try { $goalOk = [bool](Get-PWValue $goalSlot 'ok' $false) } catch { $goalOk = $false }
        if (-not $goalOk) { return (& $fail 'goal-read-failed') }
        $live = Get-PWValue $goalSlot 'goal' $null
        if ($null -eq $live) { return (& $fail 'goal-read-failed') }
        if (([string](Get-PWValue $live 'state' '')).Trim().ToUpperInvariant() -cne 'ACTIVE') { return (& $fail 'goal-not-active') }
        $own = $ownIn
        $genArg = $genIn
        if ([string]::IsNullOrWhiteSpace($own)) {
            $ownNode = Get-PWValue $live 'ownership' $null
            $own = ([string](Get-PWValue $ownNode 'owner_id' '')).Trim()
            try { $genArg = [long](Get-PWValue $ownNode 'generation' -1) } catch { $genArg = -1 }
        }
        if ([string]::IsNullOrWhiteSpace($own) -or ([long]$genArg -lt 1)) { return (& $fail 'ownership-not-held') }
        $fence = $null
        try { $fence = Test-OrchestrationGoalOwnership -Goal $live -OwnerId $own -Generation ([long]$genArg) } catch { $fence = $null }
        $held = $false
        try { $held = [bool](Get-PWValue $fence 'held' $false) } catch { $held = $false }
        if (-not $held) { return (& $fail 'ownership-not-held') }
        # Canonical lease expiry: read from the SAME live Goal ownership
        # node validated above. No model override exists: the tool schema,
        # the TS allowlist and the bridge shape all reject lease_expires_utc,
        # so Register + replay always use the Goal lease liveness. The
        # canonical owner stays the wait lease owner (GH-WAKE contract).
        $canonLeaseExpires = ''
        try {
            $ownNodeCanon = Get-PWValue $live 'ownership' $null
            $canonLeaseExpires = ([string](Get-PWValue $ownNodeCanon 'expires_at' '')).Trim()
        }
        catch { $canonLeaseExpires = '' }
        if ([string]::IsNullOrWhiteSpace($canonLeaseExpires)) { return (& $fail 'ownership-not-held') }
        try {
            if ($null -eq (Convert-GHRSUtc -Value $canonLeaseExpires)) { return (& $fail 'ownership-not-held') }
        }
        catch { return (& $fail 'ownership-not-held') }
        # Cover the durable wait with the goal lease via the existing
        # Renew mechanism. The canonical lease used to be the 60 s acquire
        # default, so any wait longer than 60 s expired before the
        # scheduler fired and Prepare later refused
        # ownership-not-held:owner-lease-expired. Derive the renewal TTL
        # from the wait deadline (never arbitrary): renew only when the
        # deadline outlives the current goal lease, same holder/generation.
        try {
            $ddlObj = $null
            try { $ddlObj = Convert-GHRSUtc -Value $DeadlineUtc } catch { $ddlObj = $null }
            $leaseObj = $null
            try { $leaseObj = Convert-GHRSUtc -Value $canonLeaseExpires } catch { $leaseObj = $null }
            if (($null -ne $ddlObj) -and ($null -ne $leaseObj) -and ($ddlObj -gt $leaseObj)) {
                $ttlMs = [long](($ddlObj - [datetime]::UtcNow).TotalMilliseconds)
                if ($ttlMs -gt 0) {
                    $ren = $null
                    try { $ren = Renew-OrchestrationGoalOwnership -GoalId $gid -OwnerId $own -Generation ([long]$genArg) -StoreDir $GoalStoreDir -LeaseTtlMs $ttlMs } catch { $ren = $null }
                    if (($null -eq $ren) -or (-not [bool](Get-PWValue $ren 'ok' $false))) { return (& $fail 'ownership-not-held') }
                    try {
                        $goalSlot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir
                        if (($null -eq $goalSlot) -or (-not [bool](Get-PWValue $goalSlot 'ok' $false))) { return (& $fail 'ownership-not-held') }
                        $live = Get-PWValue $goalSlot 'goal' $null
                        if ($null -eq $live) { return (& $fail 'ownership-not-held') }
                        $canonLeaseExpires = ([string](Get-PWValue (Get-PWValue $live 'ownership' $null) 'expires_at' '')).Trim()
                        if ([string]::IsNullOrWhiteSpace($canonLeaseExpires)) { return (& $fail 'ownership-not-held') }
                    }
                    catch { return (& $fail 'ownership-not-held') }
                }
            }
        }
        catch { return (& $fail 'ownership-not-held') }
        # Explicit Task membership is mandatory: an empty or missing
        # active_tasks list never authorizes the binding.
        $tracked = @()
        try {
            if ($live -is [System.Collections.IDictionary]) {
                if ($live.Contains('active_tasks')) { $tracked = @($live['active_tasks']) }
            }
            else {
                $pp = $live.PSObject.Properties['active_tasks']
                if ($null -ne $pp) { $tracked = @($pp.Value) }
            }
        }
        catch { $tracked = @() }
        $tracked = @(@($tracked) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if (@($tracked).Count -eq 0) { return (& $fail 'task-not-in-goal') }
        $member = $false
        foreach ($t in @($tracked)) { if ($tid -ceq ([string]$t)) { $member = $true; break } }
        if (-not $member) { return (& $fail 'task-not-in-goal') }

        $scanDir = ([string]$TasksDir).Trim()
        if ([string]::IsNullOrWhiteSpace($scanDir)) {
            try { $scanDir = Get-TaskKernelDefaultTasksDir -RepoRoot $RepoRoot } catch { $scanDir = '' }
        }
        $scan = $null
        try { $scan = Test-PWSessionBoundElsewhere -TasksDir $scanDir -SkipTaskId $tid -SessionId $sid } catch { $scan = $null }
        if (($null -eq $scan) -or (-not [bool](Get-PWValue $scan 'ok' $false))) {
            $whyScan = 'session-scan-unavailable'
            try {
                $rs = ([string](Get-PWValue $scan 'reason' '')).Trim()
                if (-not [string]::IsNullOrWhiteSpace($rs)) { $whyScan = $rs }
            }
            catch { }
            return (& $fail $whyScan)
        }
        if ([bool](Get-PWValue $scan 'boundElsewhere' $false)) {
            return (& $fail 'session-bound-elsewhere')
        }

        $bindings = $null
        try { $bindings = Get-OrchestrationTaskBindings -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { $bindings = $null }
        $runs = @()
        try { $runs = @(Get-PWValue (Get-PWValue $bindings 'bindings' $null) 'runs' @()) } catch { $runs = @() }
        $selected = $rid
        if ([string]::IsNullOrWhiteSpace($selected)) {
            if (@($runs).Count -eq 1) { $selected = [string](Get-PWValue $runs[0] 'run_id' '') }
            elseif (@($runs).Count -eq 0) { return (& $fail 'run-required') }
            else { return (& $fail 'run-ambiguous') }
        }
        if (-not (Test-PWBindingId -Value $selected)) { return (& $fail 'invalid-run') }
        $matched = $null
        foreach ($e in @($runs)) {
            if ([string](Get-PWValue $e 'run_id' '') -ceq $selected) { $matched = $e; break }
        }
        if ($null -eq $matched) {
            if (@($runs).Count -gt 0) { return (& $fail 'run-divergent' '' $selected) }
        }
        else {
            if ([string](Get-PWValue $matched 'status' '') -ceq 'detached') { return (& $fail 'run-detached' '' $selected) }
        }

        $rev = [int]$ExpectedRevision
        if ($rev -lt 0) {
            try { $rev = [int](Get-PWValue $task 'revision' -1) } catch { $rev = -1 }
            if ($rev -lt 0) { return (& $fail 'task-malformed') }
        }
        $bind = $null
        try {
            $bind = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $selected -SessionId $sid `
                -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        }
        catch { $bind = $null }
        $bindOk = $false
        try { $bindOk = [bool](Get-PWValue $bind 'ok' $false) } catch { $bindOk = $false }
        if (-not $bindOk) {
            $code = ''
            try { $code = ([string](Get-PWValue $bind 'error' '')).Trim().ToLowerInvariant() } catch { $code = '' }
            if ($code -ceq '') { $code = 'internal-error' }
            $map = @{
                'not_found' = 'task-not-found'; 'malformed' = 'task-malformed'; 'kernel_disabled' = 'kernel-disabled'
                'lock_timeout' = 'lock-timeout'; 'cas_conflict' = 'cas-conflict'; 'bind_conflict' = 'bind-conflict'
                'bind_invalid_id' = 'bind-invalid-id'
            }
            $reason = $code -replace '_', '-'
            if ($map.ContainsKey($code)) { $reason = [string]$map[$code] }
            return (& $fail $reason '' $selected)
        }
        $newRev = [long]-1
        try { $newRev = [long](Get-PWValue $bind 'revision' -1) } catch { $newRev = [long]-1 }
        $bindIdle = $false
        try { $bindIdle = [bool](Get-PWValue $bind 'idempotent' $false) } catch { $bindIdle = $false }
        $bindState = 'bound'
        if ($bindIdle) { $bindState = 'already-bound' }
        $verified = $false
        try { $verified = [bool](Test-PWBindingVerified -TaskId $tid -RunId $selected -SessionId $sid -TasksDir $TasksDir -RepoRoot $RepoRoot) } catch { $verified = $false }
        if (-not $verified) {
            return [pscustomobject]@{
                ok = $false; reason = 'binding-verify-failed'; run_id = $selected; revision = $newRev
                binding = $bindState; wait_reused = $false; wait_file = ''; dedup_key = ''
                task_mutated = (-not $bindIdle); grants_authority = $false; done_approved = $false
            }
        }

        $waitsResolved = ([string]$WaitsDir).Trim()
        if ([string]::IsNullOrWhiteSpace($waitsResolved)) {
            $waitsResolved = Get-PlannerWaitDefaultWaitsDir -RepoRoot $RepoRoot
        }
        $reg = $null
        try {
            $reg = Register-OrchestrationGitHubWait -WaitsDir $waitsResolved -ObjectiveId $gid -TaskId $tid -RunId $selected `
                -Generation ([long]$genArg) -Repository $Repository -PrNumber $PrNumber -Branch $Branch `
                -ExpectedHeadSha $ExpectedHeadSha -RequiredChecks $RequiredChecks -ReviewExpectation $ReviewExpectation `
                -Cursor $Cursor -DeadlineUtc $DeadlineUtc -RetryBudgetMax $RetryBudgetMax `
                -LeaseOwner $own -LeaseExpiresUtc $canonLeaseExpires -Owner $own
        }
        catch { $reg = $null }
        $regOk = $false
        try { $regOk = [bool](Get-PWValue $reg 'ok' $false) } catch { $regOk = $false }
        if (-not $regOk) {
            $why = 'wait-register-failed'
            try {
                $r = ([string](Get-PWValue $reg 'reason' '')).Trim()
                if (-not [string]::IsNullOrWhiteSpace($r)) { $why = $r }
            }
            catch { }
            return [pscustomobject]@{
                ok = $false; reason = $why; run_id = $selected; revision = $newRev
                binding = $bindState; wait_reused = $false; wait_file = ''; dedup_key = ([string](Get-PWValue $reg 'dedup_key' ''))
                task_mutated = (-not $bindIdle); grants_authority = $false; done_approved = $false
            }
        }
        $reused = $false
        try { $reused = [bool](Get-PWValue $reg 'reused' $false) } catch { $reused = $false }
        if ($reused) {
            $stored = Get-PWValue $reg 'wait' $null
            $canonDk = $null
            try { $canonDk = Get-OrchestrationGitHubResumeDedupKey -Repository $Repository -PrNumber $PrNumber -HeadSha $ExpectedHeadSha -Generation ([long]$genArg) } catch { $canonDk = $null }
            $canonDedup = ''
            try { $canonDedup = ([string](Get-PWValue $canonDk 'dedup_key' '')).Trim() } catch { $canonDedup = '' }
            $consistent = $false
            try {
                if (-not [string]::IsNullOrWhiteSpace($canonDedup)) {
                    $consistent = Test-PWWaitReplayConsistent -Wait $stored -GoalId $gid -TaskId $tid -RunId $selected `
                        -Generation ([long]$genArg) -Repository $Repository -PrNumber ([long]$PrNumber) -Branch ([string]$Branch).Trim() `
                        -ExpectedHeadSha $ExpectedHeadSha -ReviewExpectation $ReviewExpectation -RequiredChecks $RequiredChecks `
                        -Owner $own -LeaseOwner $own -Cursor $Cursor -DeadlineUtc $DeadlineUtc `
                        -RetryBudgetMax $RetryBudgetMax -LeaseExpiresUtc $canonLeaseExpires -DedupKey $canonDedup
                }
            }
            catch { $consistent = $false }
            if (-not $consistent) {
                return [pscustomobject]@{
                    ok = $false; reason = 'wait-divergent'; run_id = $selected; revision = $newRev
                    binding = $bindState; wait_reused = $true; wait_file = ([string](Get-PWValue $reg 'wait_file' ''))
                    dedup_key = ([string](Get-PWValue $reg 'dedup_key' ''))
                    task_mutated = (-not $bindIdle); grants_authority = $false; done_approved = $false
                }
            }
        }
        $whyDone = 'registered'
        if ($reused) { $whyDone = 'already-registered' }
        return [pscustomobject]@{
            ok = $true; reason = $whyDone; run_id = $selected; revision = $newRev
            binding = $bindState; wait_reused = $reused; wait_file = ([string](Get-PWValue $reg 'wait_file' ''))
            dedup_key = ([string](Get-PWValue $reg 'dedup_key' ''))
            task_mutated = (-not $bindIdle); grants_authority = $false; done_approved = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false; reason = 'internal-error'; run_id = ''; revision = [long]-1
            binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
            task_mutated = $false; grants_authority = $false; done_approved = $false
        }
    }
}
